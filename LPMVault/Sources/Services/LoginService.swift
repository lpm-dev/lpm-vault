import AppKit
import CryptoKit
import Foundation
import Network
import Security

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

	private final class LoginAttemptState: @unchecked Sendable {
		private let lock = NSLock()
		private var lastAttempt: Date?

		func reserve(now: Date = Date()) -> Bool {
			lock.lock()
			defer { lock.unlock() }
			if let lastAttempt, now.timeIntervalSince(lastAttempt) < 5 { return false }
			lastAttempt = now
			return true
		}
	}

	private final class RequestBuffer: @unchecked Sendable {
		private let lock = NSLock()
		private var data = Data()
		private var completed = false

		func append(_ chunk: Data, limit: Int) -> Data? {
			lock.lock()
			defer { lock.unlock() }
			guard !completed else { return nil }
			data.append(chunk)
			return data.count <= limit ? data : nil
		}

		func claimCompletion() -> Bool {
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

	private static let maximumRequestBytes = 8 * 1024
	private static let maximumExchangeResponseBytes = 64 * 1024
	private static let maximumConcurrentCallbacks = 16
	private static let callbackReadTimeout: TimeInterval = 10
	private static let loginAttempts = LoginAttemptState()

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
		let parameters = NWParameters.tcp
		parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
		let listener = try NWListener(using: parameters, on: .any)
		let callbackCode = try await waitForCallback(
			listener: listener,
			registryURL: registryURL,
			state: state,
			codeChallenge: challenge
		)
		let resolvedBaseURL = baseURL ?? URL(string: registryURL)!
		return try await exchange(
			code: callbackCode,
			codeVerifier: verifier,
			baseURL: resolvedBaseURL
		)
	}

	static func writeAuthSession(_ credentials: AuthSessionCredentials, registryURL: String) throws {
		try AuthSessionStore.persist(credentials, registryURL: registryURL)
	}

	static func clearAuthSession(registryURL: String = "https://lpm.dev") {
		AuthSessionStore.clear(registryURL: registryURL)
	}

	static func parseCallbackRequest(_ request: Data) -> (code: String, state: String)? {
		guard request.count <= maximumRequestBytes,
			let rawRequest = String(data: request, encoding: .utf8),
			let headerEnd = rawRequest.range(of: "\r\n\r\n")
		else { return nil }

		let header = String(rawRequest[..<headerEnd.lowerBound])
		guard let requestLine = header.components(separatedBy: "\r\n").first else { return nil }
		let requestParts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
		guard requestParts.count >= 2 else { return nil }
		let method = String(requestParts[0])
		let target = String(requestParts[1])
		guard target.split(separator: "?", maxSplits: 1).first == "/callback" else { return nil }

		let encoded: String
		switch method {
		case "POST":
			guard contentType(from: header) == "application/x-www-form-urlencoded",
				let contentLength = contentLength(from: header),
				contentLength >= 0,
				contentLength <= maximumRequestBytes
			else { return nil }
			let body = String(rawRequest[headerEnd.upperBound...])
			guard body.utf8.count == contentLength else { return nil }
			encoded = body
		case "GET":
			encoded = target.split(separator: "?", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
		default:
			return nil
		}

		let fields = parseForm(encoded)
		guard let code = fields["code"], isValidExchangeCode(code),
			let state = fields["state"], !state.isEmpty
		else { return nil }
		return (code, state)
	}

	private static func waitForCallback(
		listener: NWListener,
		registryURL: String,
		state: String,
		codeChallenge: String
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
							codeChallenge: codeChallenge
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
		readHTTPRequest(connection) { data in
			guard let data, let callback = parseCallbackRequest(data) else {
				sendResponse(connection, success: false)
				completion(.failure(LoginError.invalidCallback))
				return
			}
			guard callback.state == expectedState else {
				sendResponse(connection, success: false)
				completion(.failure(LoginError.stateMismatch))
				return
			}
			sendResponse(connection, success: true)
			completion(.success(callback.code))
		}
	}

	private static func readHTTPRequest(
		_ connection: NWConnection,
		completion: @escaping @Sendable (Data?) -> Void
	) {
		let buffer = RequestBuffer()
		DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + callbackReadTimeout) {
			guard buffer.claimCompletion() else { return }
			connection.cancel()
			completion(nil)
		}
		@Sendable func receive() {
			connection.receive(minimumIncompleteLength: 1, maximumLength: 2048) { data, _, complete, error in
				guard error == nil, let data else {
					if buffer.claimCompletion() { completion(nil) }
					return
				}
				guard let request = buffer.append(data, limit: maximumRequestBytes) else {
					if buffer.claimCompletion() { completion(nil) }
					return
				}
				if requestIsComplete(request) || complete {
					if buffer.claimCompletion() { completion(request) }
				} else {
					receive()
				}
			}
		}
		receive()
	}

	private static func requestIsComplete(_ data: Data) -> Bool {
		guard let request = String(data: data, encoding: .utf8),
			let headerEnd = request.range(of: "\r\n\r\n")
		else { return false }
		let header = String(request[..<headerEnd.lowerBound])
		let expectedBody = contentLength(from: header) ?? 0
		return request[headerEnd.upperBound...].utf8.count >= expectedBody
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
			configuration: .ephemeral,
			delegate: PinnedSessionDelegate(),
			delegateQueue: nil
		)
		let (data, response) = try await session.data(for: request)
		guard data.count <= maximumExchangeResponseBytes,
			let http = response as? HTTPURLResponse
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
		codeChallenge: String
	) -> URL? {
		guard var components = URLComponents(string: registryURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))) else {
			return nil
		}
		components.path = "/cli/login"
		components.queryItems = [
			URLQueryItem(name: "port", value: String(port)),
			URLQueryItem(name: "state", value: state),
			URLQueryItem(name: "fp", value: AuthSessionStore.deviceFingerprint()),
			URLQueryItem(name: "dn", value: Host.current().localizedName ?? "LPM Vault"),
			URLQueryItem(name: "code_challenge", value: codeChallenge),
			URLQueryItem(name: "code_challenge_method", value: "S256"),
		]
		return components.url
	}

	private static func parseForm(_ form: String) -> [String: String] {
		var components = URLComponents()
		components.query = form
		var values: [String: String] = [:]
		for item in components.queryItems ?? [] where values[item.name] == nil {
			values[item.name] = item.value ?? ""
		}
		return values
	}

	private static func contentType(from headers: String) -> String? {
		headerValue(named: "content-type", in: headers)?
			.split(separator: ";", maxSplits: 1)
			.first
			.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
	}

	private static func contentLength(from headers: String) -> Int? {
		guard let value = headerValue(named: "content-length", in: headers) else { return nil }
		return Int(value.trimmingCharacters(in: .whitespaces))
	}

	private static func headerValue(named name: String, in headers: String) -> String? {
		for line in headers.components(separatedBy: "\r\n").dropFirst() {
			guard let separator = line.firstIndex(of: ":") else { continue }
			if line[..<separator].lowercased() == name {
				return String(line[line.index(after: separator)...])
			}
		}
		return nil
	}

	private static func isValidExchangeCode(_ code: String) -> Bool {
		code.utf8.count == 64 && code.utf8.allSatisfy { byte in
			(byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 102)
		}
	}

	private static func sendResponse(_ connection: NWConnection, success: Bool) {
		let status = success ? "200 OK" : "400 Bad Request"
		let title = success ? "Access Granted" : "Login Failed"
		let detail = success
			? "Return to LPM Vault to continue."
			: "Return to LPM Vault and try again."
		let body = "<!doctype html><html><body><h1>\(title)</h1><p>\(detail)</p></body></html>"
		let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nConnection: close\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
		connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
			connection.cancel()
		})
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
