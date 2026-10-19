import Foundation
import Network

/// Why the Registry or the platform ended a connection, by the Registry's code.
enum PlatformConnectFailure: Equatable, Sendable {
	case cancelledOnPlatform
	case differentInstallation
	case alreadyUsed
	/// The platform's approval expired, or was used, before the Registry exchanged it.
	case approvalExpired
	case platformUnavailable
	case platformRefused
	/// The platform's answer to the code exchange was lost, so whether it
	/// granted anything isn't known; a new approval starts over.
	case exchangeUncertain
	/// The platform granted less access than LPM Vault needs.
	case insufficientScope
	case other

	init(code: String) {
		switch code {
		case "authorization_cancelled": self = .cancelledOnPlatform
		case "installation_mismatch": self = .differentInstallation
		case "authorization_used": self = .alreadyUsed
		case "authorization_expired": self = .approvalExpired
		case "platform_unavailable": self = .platformUnavailable
		case "platform_rejected", "invalid_code", "invalid_platform_response": self = .platformRefused
		case "exchange_uncertain": self = .exchangeUncertain
		case "insufficient_scope": self = .insufficientScope
		default: self = .other
		}
	}

	func message(for platform: BrowserPlatform) -> String {
		let name = platform.displayName
		return switch self {
		case .cancelledOnPlatform: "The connection was cancelled on \(name)."
		case .differentInstallation: "\(name) answered for a different installation. Connect again."
		case .alreadyUsed: "This connection link was already used. Connect again from LPM Vault."
		case .approvalExpired: "Your approval on \(name) expired before it could be used. Connect again."
		case .platformUnavailable: "\(name) isn't reachable right now. Try again later."
		case .platformRefused: "\(name) didn't accept the connection. Connect again."
		case .exchangeUncertain: "\(name)'s answer didn't come back, so the connection couldn't be finished. Connect again."
		case .insufficientScope: "\(name) didn't grant all the access LPM Vault needs. Connect again, and approve every permission it asks for."
		case .other: "\(name) couldn't be connected. Try again."
		}
	}
}

/// Listens on 127.0.0.1 for the browser's return from connecting a
/// platform, which the Registry's callback redirects to
/// `/platforms/{platform}/complete?authorization=…&proof=…` (or `&error=…`),
/// signed with its response-signing key. Only a signed return for the
/// authorization this Mac started counts; any other request gets a page and
/// is otherwise ignored, so someone who learns the authorization can't end
/// the wait with a made-up failure or proof.
final class PlatformConnectionListener: @unchecked Sendable {
	enum Completion: Equatable, Sendable {
		/// The one-time proof the Registry gave the browser to bring here.
		case proof(String)
		case failure(PlatformConnectFailure)
	}

	enum ListenerError: Error, Equatable, Sendable {
		case unavailable
		case timedOut
	}

	struct Request: Equatable, Sendable {
		let authorizationID: String
		let completion: Completion
		/// The platform's page to continue on, when it gave one.
		let next: URL?
		/// The Registry's signature over what the return says, and the key it used.
		let keyID: String
		let signature: String
		/// The bytes the signature covers; see `signedMessage`.
		let signedMessage: Data
	}

	private struct Expected {
		let authorizationID: String
		let registry: URL
	}

	private static let maximumConcurrentConnections = 16

	let platform: BrowserPlatform
	let port: UInt16
	private let listener: NWListener
	private let lock = NSLock()
	private var expected: Expected?
	private var outcome: Result<Completion, Error>?
	private var waiter: CheckedContinuation<Completion, Error>?
	private var activeConnections = 0

	private init(listener: NWListener, platform: BrowserPlatform, port: UInt16) {
		self.listener = listener
		self.platform = platform
		self.port = port
	}

	/// The path the browser returns to after connecting `platform`.
	static func path(for platform: BrowserPlatform) -> String {
		"/platforms/\(platform.rawValue)/complete"
	}

	/// A listener on a free port of 127.0.0.1 for returns from connecting
	/// `platform`, ready for connections.
	static func start(for platform: BrowserPlatform) async throws -> PlatformConnectionListener {
		let parameters = NWParameters.tcp
		parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
		let listener = try NWListener(using: parameters, on: .any)
		let port = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
			let once = ResumeOnce(continuation)
			listener.stateUpdateHandler = { state in
				switch state {
				case .ready:
					once.resume(with: listener.port.map { .success($0.rawValue) } ?? .failure(ListenerError.unavailable))
				case .failed, .cancelled:
					once.resume(with: .failure(ListenerError.unavailable))
				default:
					break
				}
			}
			listener.newConnectionHandler = { $0.cancel() }
			listener.start(queue: .global(qos: .userInitiated))
		}
		let started = PlatformConnectionListener(listener: listener, platform: platform, port: port)
		listener.stateUpdateHandler = { [weak started] state in
			if case .failed = state { started?.finish(.failure(ListenerError.unavailable)) }
		}
		listener.newConnectionHandler = { [weak started] connection in
			guard let started else { return connection.cancel() }
			started.handle(connection)
		}
		return started
	}

	/// Accepts returns for `authorizationID` only, signed by `registry`.
	func expect(_ authorizationID: String, from registry: URL) {
		lock.withLock { expected = Expected(authorizationID: authorizationID, registry: registry) }
	}

	/// The browser's return, waiting at most until `deadline`.
	func completion(until deadline: Date) async throws -> Completion {
		let delay = max(0, deadline.timeIntervalSinceNow)
		DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) { [weak self] in
			self?.finish(.failure(ListenerError.timedOut))
		}
		return try await withTaskCancellationHandler {
			try await withCheckedThrowingContinuation { continuation in
				let ready: Result<Completion, Error>? = lock.withLock {
					if let outcome { return outcome }
					waiter = continuation
					return nil
				}
				if let ready { continuation.resume(with: ready) }
			}
		} onCancel: {
			finish(.failure(CancellationError()))
		}
	}

	/// Whether a caller is waiting for the browser's return.
	var isWaiting: Bool { lock.withLock { waiter != nil } }

	func stop() {
		finish(.failure(CancellationError()))
	}

	/// Ends the wait once; connections already accepted still get their page.
	private func finish(_ result: Result<Completion, Error>) {
		let (first, pending): (Bool, CheckedContinuation<Completion, Error>?) = lock.withLock {
			guard outcome == nil else { return (false, nil) }
			outcome = result
			defer { waiter = nil }
			return (true, waiter)
		}
		guard first else { return }
		listener.cancel()
		pending?.resume(with: result)
	}

	private func handle(_ connection: NWConnection) {
		let accepted = lock.withLock {
			guard outcome == nil, activeConnections < Self.maximumConcurrentConnections else { return false }
			activeConnections += 1
			return true
		}
		guard accepted else { return connection.cancel() }
		connection.start(queue: .global(qos: .userInitiated))
		LoopbackHTTP.readRequest(connection) { [weak self] data in
			guard let self else { return connection.cancel() }
			let request = data.flatMap { Self.parse($0, for: platform) }
			let expected = lock.withLock {
				activeConnections -= 1
				return self.expected
			}
			if let request, let expected, request.authorizationID == expected.authorizationID,
				PinnedSessionDelegate.verifyRegistrySignature(
					request.signature, keyID: request.keyID, message: request.signedMessage, registry: expected.registry)
			{
				LoopbackHTTP.send(Self.page(for: request.completion, on: platform, next: request.next), on: connection)
				finish(.success(request.completion))
			} else {
				LoopbackHTTP.send(Self.page(for: nil, on: platform, next: nil), on: connection)
			}
		}
	}

	/// The return from connecting `platform` the request describes, or nil
	/// when it isn't one. Whether the Registry signed it is checked against
	/// the authorization expected.
	static func parse(_ request: Data, for platform: BrowserPlatform) -> Request? {
		guard let (method, target, _, _) = LoopbackHTTP.split(request), method == "GET" else { return nil }
		let parts = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
		guard parts.first == path(for: platform)[...], parts.count == 2 else { return nil }
		let fields = LoopbackHTTP.parseForm(String(parts[1]))
		guard let authorizationID = fields["authorization"],
			PlatformAuthorizationClient.isCanonicalUUID(authorizationID),
			let keyID = fields["key"], let signature = fields["signature"]
		else { return nil }
		let completion: Completion
		let outcome: Outcome
		switch (fields["proof"], fields["error"]) {
		case (let proof?, nil) where PlatformAuthorizationClient.isOneTimeValue(proof):
			completion = .proof(proof)
			outcome = .proof(proof)
		case (nil, let code?) where PlatformAuthorizationClient.isFailureCode(code):
			completion = .failure(PlatformConnectFailure(code: code))
			outcome = .error(code)
		default:
			return nil
		}
		let next = fields["next"]
		guard let message = signedMessage(authorizationID: authorizationID, outcome: outcome, next: next, keyID: keyID) else {
			return nil
		}
		return Request(
			authorizationID: authorizationID,
			completion: completion,
			next: next.flatMap { validatedNextPage($0, for: platform) },
			keyID: keyID,
			signature: signature,
			signedMessage: message
		)
	}

	/// What a return says, as the Registry signs it.
	enum Outcome: Equatable, Sendable {
		case proof(String)
		/// The failure's code, as the Registry sent it.
		case error(String)
	}

	private static let signatureDomain = Data("lpm-vault:platform-return\0".utf8)

	/// The bytes the Registry signs a return over, as its
	/// `loopbackCompletionUrl` documents: the domain, the frame's version and
	/// key ID, then the authorization, the outcome and the platform's link,
	/// each text length-prefixed. Nil when the key ID isn't one, or a field is too long.
	static func signedMessage(authorizationID: String, outcome: Outcome, next: String?, keyID: String) -> Data? {
		guard let keyIDLength = UInt8(exactly: keyID.utf8.count), keyIDLength > 0,
			keyID.utf8.allSatisfy({ byte in
				(65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte) || byte == 45 || byte == 95
			})
		else { return nil }
		let (kind, value): (UInt8, String) = switch outcome {
		case .proof(let proof): (1, proof)
		case .error(let code): (2, code)
		}
		var message = signatureDomain
		func append(_ text: String) -> Bool {
			guard let length = UInt16(exactly: text.utf8.count) else { return false }
			message.append(UInt8(length >> 8))
			message.append(UInt8(length & 0xff))
			message.append(contentsOf: text.utf8)
			return true
		}
		message.append(1)
		message.append(keyIDLength)
		message.append(contentsOf: keyID.utf8)
		guard append(authorizationID) else { return nil }
		message.append(kind)
		guard append(value), append(next ?? "") else { return nil }
		return message
	}

	/// The platform's page to continue on: one on vercel.com over https, as
	/// Vercel names after an install. Netlify names none, so nil.
	static func validatedNextPage(_ text: String, for platform: BrowserPlatform) -> URL? {
		guard platform == .vercel, text.utf8.count <= 2_048,
			let components = URLComponents(string: text),
			components.scheme == "https", components.host == "vercel.com",
			components.user == nil, components.password == nil, components.port == nil
		else { return nil }
		return components.url
	}

	static func page(for completion: Completion?, on platform: BrowserPlatform, next: URL?) -> String {
		let name = platform.displayName
		let link = next.map { LoopbackPage.Link(title: "Continue on \(name)", url: $0) }
		switch completion {
		case .proof:
			return LoopbackPage.response(
				success: true,
				title: "Return to LPM Vault",
				label: "\(name) approved",
				detail: "LPM Vault will finish connecting \(name) on this Mac. Check the app to see it connected.",
				link: link)
		case .failure(let failure):
			return LoopbackPage.response(
				success: false,
				title: "\(name) wasn't connected",
				label: "Connection stopped",
				detail: "\(failure.message(for: platform)) Return to LPM Vault to try again.",
				link: link)
		case nil:
			return LoopbackPage.response(
				success: false,
				title: "Start from LPM Vault",
				label: "Not recognized",
				detail: "This page didn't come from a connection LPM Vault started. Connect \(name) from LPM Vault's Platforms page.")
		}
	}
}

/// Resumes a continuation the first time only, from whichever callback fires first.
private final class ResumeOnce<Value: Sendable>: @unchecked Sendable {
	private let lock = NSLock()
	private var continuation: CheckedContinuation<Value, Error>?

	init(_ continuation: CheckedContinuation<Value, Error>) {
		self.continuation = continuation
	}

	func resume(with result: Result<Value, Error>) {
		let pending = lock.withLock {
			defer { continuation = nil }
			return continuation
		}
		pending?.resume(with: result)
	}
}
