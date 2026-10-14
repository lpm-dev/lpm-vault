import AppKit
import CryptoKit
import Foundation
import Network
import Security

final class LoginAttemptLimiter: @unchecked Sendable {
	private let lock = NSLock()
	private var lastAttempt: TimeInterval?

	func reserve(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
		lock.lock()
		defer { lock.unlock() }
		if let lastAttempt {
			let elapsed = now - lastAttempt
			if elapsed >= 0, elapsed < 5 { return false }
		}
		lastAttempt = now
		return true
	}
}

enum LoginService {
	private final class CallbackState: @unchecked Sendable {
		private let lock = NSLock()
		private var completed = false
		private var activeConnections = 0

		func reserveConnection(limit: Int) -> Bool {
			lock.lock()
			defer { lock.unlock() }
			guard !completed, activeConnections < limit else { return false }
			activeConnections += 1
			return true
		}

		func releaseConnection() {
			lock.lock()
			activeConnections = max(activeConnections - 1, 0)
			lock.unlock()
		}

		func markCompleted() -> Bool {
			lock.lock()
			defer { lock.unlock() }
			guard !completed else { return false }
			completed = true
			return true
		}
	}

	enum LoginError: LocalizedError {
		case listenerFailed(String)
		case timeout
		case invalidCallback
		case stateMismatch
		case exchangeFailed(String)
		case rateLimited

		var errorDescription: String? {
			switch self {
			case .listenerFailed(let message): "Login server failed: \(message)"
			case .timeout: "Login timed out after 2 minutes. Try again."
			case .invalidCallback: "The browser returned an invalid authorization code."
			case .stateMismatch: "Login state mismatch — possible CSRF attack. Try again."
			case .exchangeFailed(let message): "Login exchange failed: \(message)"
			case .rateLimited: "Too many login attempts. Please wait a few seconds before trying again."
			}
		}
	}

	private static let maximumExchangeResponseBytes = 64 * 1024
	private static let maximumConcurrentCallbacks = 16
	private static let loginAttempts = LoginAttemptLimiter()

	static func login(
		registryURL: String = "https://lpm.dev",
		baseURL: URL? = nil
	) async throws -> AuthSessionCredentials {
		guard loginAttempts.reserve() else {
			throw LoginError.rateLimited
		}

		let state = randomHex(byteCount: 16)
		let verifier = randomBase64URL(byteCount: 32)
		let challenge = base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
		let deviceFingerprint = try AuthSessionStore.deviceFingerprint()
		let parameters = NWParameters.tcp
		parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
		let listener = try NWListener(using: parameters, on: .any)
		let callbackCode = try await waitForCallback(
			listener: listener,
			registryURL: registryURL,
			state: state,
			codeChallenge: challenge,
			deviceFingerprint: deviceFingerprint
		)
		let resolvedBaseURL = baseURL ?? URL(string: registryURL)!
		return try await exchange(
			code: callbackCode,
			codeVerifier: verifier,
			baseURL: resolvedBaseURL
		)
	}

	static func writeAuthSession(
		_ credentials: AuthSessionCredentials,
		registryURL: String
	) async throws {
		try await AuthSessionStore.persist(credentials, registryURL: registryURL)
	}

	static func clearAuthSession(registryURL: String = "https://lpm.dev") async throws {
		try await AuthSessionStore.clear(registryURL: registryURL)
	}

	static func parseCallbackRequest(_ request: Data) -> (code: String, state: String)? {
		guard let (method, target, header, body) = LoopbackHTTP.split(request),
			target.split(separator: "?", maxSplits: 1).first == "/callback"
		else { return nil }

		let encoded: String
		switch method {
		case "POST":
			guard LoopbackHTTP.contentType(from: header) == "application/x-www-form-urlencoded",
				let contentLength = LoopbackHTTP.contentLength(from: header),
				contentLength >= 0,
				contentLength <= LoopbackHTTP.maximumRequestBytes,
				body.utf8.count == contentLength
			else { return nil }
			encoded = String(body)
		case "GET":
			encoded = target.split(separator: "?", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
		default:
			return nil
		}

		let fields = LoopbackHTTP.parseForm(encoded)
		guard let code = fields["code"], isValidExchangeCode(code),
			let state = fields["state"], !state.isEmpty
		else { return nil }
		return (code, state)
	}

	private static func waitForCallback(
		listener: NWListener,
		registryURL: String,
		state: String,
		codeChallenge: String,
		deviceFingerprint: String
	) async throws -> String {
		let callbackState = CallbackState()

		return try await withCheckedThrowingContinuation { continuation in
			let finish: @Sendable (Result<String, Error>) -> Void = { result in
				guard callbackState.markCompleted() else { return }
				listener.cancel()
				continuation.resume(with: result)
			}

			listener.stateUpdateHandler = { listenerState in
				switch listenerState {
				case .ready:
					guard let port = listener.port?.rawValue,
						let url = loginURL(
							registryURL: registryURL,
							port: port,
							state: state,
							codeChallenge: codeChallenge,
							deviceFingerprint: deviceFingerprint
						)
					else {
						finish(.failure(LoginError.listenerFailed("no callback port assigned")))
						return
					}
					DispatchQueue.main.async { NSWorkspace.shared.open(url) }
				case .failed(let error):
					finish(.failure(LoginError.listenerFailed(error.localizedDescription)))
				default:
					break
				}
			}

			listener.newConnectionHandler = { connection in
				guard callbackState.reserveConnection(limit: maximumConcurrentCallbacks) else {
					connection.cancel()
					return
				}

				handleConnection(connection, expectedState: state) { result in
					callbackState.releaseConnection()
					if case .success = result { finish(result) }
				}
			}

			listener.start(queue: .global(qos: .userInitiated))
			DispatchQueue.global().asyncAfter(deadline: .now() + 120) {
				finish(.failure(LoginError.timeout))
			}
		}
	}

	private static func handleConnection(
		_ connection: NWConnection,
		expectedState: String,
		completion: @escaping @Sendable (Result<String, Error>) -> Void
	) {
		connection.start(queue: .global(qos: .userInitiated))
		LoopbackHTTP.readRequest(connection) { data in
			guard let data, let callback = parseCallbackRequest(data) else {
				LoopbackHTTP.send(callbackResponse(success: false), on: connection)
				completion(.failure(LoginError.invalidCallback))
				return
			}
			guard callback.state == expectedState else {
				LoopbackHTTP.send(callbackResponse(success: false), on: connection)
				completion(.failure(LoginError.stateMismatch))
				return
			}
			LoopbackHTTP.send(callbackResponse(success: true), on: connection)
			completion(.success(callback.code))
		}
	}

	private static func exchange(
		code: String,
		codeVerifier: String,
		baseURL: URL
	) async throws -> AuthSessionCredentials {
		guard let url = URL(string: "/api/cli/exchange", relativeTo: baseURL) else {
			throw LoginError.exchangeFailed("invalid server URL")
		}
		var request = URLRequest(url: url)
		request.httpMethod = "POST"
		request.setValue("application/json", forHTTPHeaderField: "Content-Type")
		request.httpBody = try exchangeRequestBody(code: code, codeVerifier: codeVerifier)

		let session = URLSession(
			configuration: BoundedHTTPResponse.ephemeralConfiguration(
				requestTimeout: 15,
				resourceTimeout: 30
			),
			delegate: PinnedSessionDelegate(),
			delegateQueue: nil
		)
		let data: Data
		let response: URLResponse
		do {
			(data, response) = try await BoundedHTTPResponse.load(
				for: request,
				using: session,
				maximumBytes: maximumExchangeResponseBytes
			)
		} catch is BoundedHTTPResponse.LoadError {
			throw LoginError.exchangeFailed("response exceeded the size limit")
		}
		guard let http = response as? HTTPURLResponse
		else { throw LoginError.exchangeFailed("invalid response") }
		guard (200..<300).contains(http.statusCode) else {
			let error = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
			throw LoginError.exchangeFailed(error ?? "HTTP \(http.statusCode)")
		}

		let credentials = try JSONDecoder().decode(AuthSessionCredentials.self, from: data)
		guard credentials.isComplete else {
			throw LoginError.exchangeFailed("server returned an incomplete refresh session")
		}
		return credentials
	}

	static func exchangeRequestBody(code: String, codeVerifier: String) throws -> Data {
		try JSONSerialization.data(withJSONObject: [
			"code": code,
			"code_verifier": codeVerifier,
		])
	}

	private static func loginURL(
		registryURL: String,
		port: UInt16,
		state: String,
		codeChallenge: String,
		deviceFingerprint: String
	) -> URL? {
		guard var components = URLComponents(string: registryURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))) else {
			return nil
		}
		components.path = "/cli/login"
		components.queryItems = [
			URLQueryItem(name: "port", value: String(port)),
			URLQueryItem(name: "state", value: state),
			URLQueryItem(name: "fp", value: deviceFingerprint),
			URLQueryItem(name: "dn", value: Host.current().localizedName ?? "LPM Vault"),
			URLQueryItem(name: "code_challenge", value: codeChallenge),
			URLQueryItem(name: "code_challenge_method", value: "S256"),
		]
		return components.url
	}

	private static func isValidExchangeCode(_ code: String) -> Bool {
		code.utf8.count == 64 && code.utf8.allSatisfy { byte in
			(byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 102)
		}
	}

	static func callbackResponse(success: Bool) -> String {
		success
			? LoopbackPage.response(
				success: true,
				title: "Return to LPM Vault",
				label: "Authorization received",
				detail: "LPM Vault will finish signing in on this Mac. Check the app for your connection status.")
			: LoopbackPage.response(
				success: false,
				title: "Sign-in could not continue",
				label: "Verification unsuccessful",
				detail: "This browser response could not be verified. Return to LPM Vault and start sign-in again.")
	}

	private static func randomHex(byteCount: Int) -> String {
		var bytes = [UInt8](repeating: 0, count: byteCount)
		guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
			return UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
		}
		return bytes.map { String(format: "%02x", $0) }.joined()
	}

	private static func randomBase64URL(byteCount: Int) -> String {
		var bytes = [UInt8](repeating: 0, count: byteCount)
		guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
			return base64URL(Data(UUID().uuidString.utf8))
		}
		return base64URL(Data(bytes))
	}

	private static func base64URL(_ data: Data) -> String {
		data.base64EncodedString()
			.replacingOccurrences(of: "+", with: "-")
			.replacingOccurrences(of: "/", with: "_")
			.replacingOccurrences(of: "=", with: "")
	}
}
