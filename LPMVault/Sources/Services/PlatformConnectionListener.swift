import Foundation
import Network

/// Why the Registry or the platform ended a connection, by the Registry's code.
enum PlatformConnectFailure: Equatable, Sendable {
	case cancelledOnPlatform
	case differentInstallation
	case alreadyUsed
	case platformUnavailable
	case platformRefused
	case other

	init(code: String) {
		switch code {
		case "authorization_cancelled": self = .cancelledOnPlatform
		case "installation_mismatch": self = .differentInstallation
		case "authorization_used": self = .alreadyUsed
		case "platform_unavailable": self = .platformUnavailable
		case "platform_rejected", "invalid_code", "invalid_platform_response": self = .platformRefused
		default: self = .other
		}
	}

	var message: String {
		switch self {
		case .cancelledOnPlatform: "The connection was cancelled on Vercel."
		case .differentInstallation: "Vercel answered for a different installation. Connect again."
		case .alreadyUsed: "This connection link was already used. Connect again from LPM Vault."
		case .platformUnavailable: "Vercel isn't reachable right now. Try again later."
		case .platformRefused: "Vercel didn't accept the connection. Connect again."
		case .other: "Vercel couldn't be connected. Try again."
		}
	}
}

/// Listens on 127.0.0.1 for the browser's return from connecting Vercel,
/// which the Registry's callback redirects to
/// `/platforms/vercel/complete?authorization=…&proof=…` (or `&error=…`).
/// Only the authorization this Mac started counts; any other request gets a
/// page and is otherwise ignored, so a page elsewhere can't end the wait.
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
		/// Vercel's page to continue on, when it gave one.
		let next: URL?
	}

	static let path = "/platforms/vercel/complete"
	private static let maximumConcurrentConnections = 16

	let port: UInt16
	private let listener: NWListener
	private let lock = NSLock()
	private var expectedAuthorizationID: String?
	private var outcome: Result<Completion, Error>?
	private var waiter: CheckedContinuation<Completion, Error>?
	private var activeConnections = 0

	private init(listener: NWListener, port: UInt16) {
		self.listener = listener
		self.port = port
	}

	/// A listener on a free port of 127.0.0.1, ready for connections.
	static func start() async throws -> PlatformConnectionListener {
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
		let started = PlatformConnectionListener(listener: listener, port: port)
		listener.stateUpdateHandler = { [weak started] state in
			if case .failed = state { started?.finish(.failure(ListenerError.unavailable)) }
		}
		listener.newConnectionHandler = { [weak started] connection in
			guard let started else { return connection.cancel() }
			started.handle(connection)
		}
		return started
	}

	/// Accepts returns for `authorizationID` only.
	func expect(_ authorizationID: String) {
		lock.withLock { expectedAuthorizationID = authorizationID }
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
			let request = data.flatMap(Self.parse)
			let expected = lock.withLock {
				activeConnections -= 1
				return expectedAuthorizationID
			}
			if let request, request.authorizationID == expected {
				LoopbackHTTP.send(Self.page(for: request.completion, next: request.next), on: connection)
				finish(.success(request.completion))
			} else {
				LoopbackHTTP.send(Self.page(for: nil, next: nil), on: connection)
			}
		}
	}

	/// The return the request describes, or nil when it isn't one.
	static func parse(_ request: Data) -> Request? {
		guard let (method, target, _, _) = LoopbackHTTP.split(request), method == "GET" else { return nil }
		let parts = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
		guard parts.first == path[...], parts.count == 2 else { return nil }
		let fields = LoopbackHTTP.parseForm(String(parts[1]))
		guard let authorizationID = fields["authorization"],
			PlatformAuthorizationClient.isCanonicalUUID(authorizationID)
		else { return nil }
		let completion: Completion
		switch (fields["proof"], fields["error"]) {
		case (let proof?, nil) where PlatformAuthorizationClient.isOneTimeValue(proof):
			completion = .proof(proof)
		case (nil, let code?) where PlatformAuthorizationClient.isFailureCode(code):
			completion = .failure(PlatformConnectFailure(code: code))
		default:
			return nil
		}
		return Request(
			authorizationID: authorizationID,
			completion: completion,
			next: fields["next"].flatMap(validatedVercelPage)
		)
	}

	/// A page on vercel.com over https, or nil.
	static func validatedVercelPage(_ text: String) -> URL? {
		guard text.utf8.count <= 2_048,
			let components = URLComponents(string: text),
			components.scheme == "https", components.host == "vercel.com",
			components.user == nil, components.password == nil, components.port == nil
		else { return nil }
		return components.url
	}

	static func page(for completion: Completion?, next: URL?) -> String {
		let link = next.map { LoopbackPage.Link(title: "Continue on Vercel", url: $0) }
		switch completion {
		case .proof:
			return LoopbackPage.response(
				success: true,
				title: "Return to LPM Vault",
				label: "Vercel approved",
				detail: "LPM Vault will finish connecting Vercel on this Mac. Check the app to see it connected.",
				link: link)
		case .failure(let failure):
			return LoopbackPage.response(
				success: false,
				title: "Vercel wasn't connected",
				label: "Connection stopped",
				detail: "\(failure.message) Return to LPM Vault to try again.",
				link: link)
		case nil:
			return LoopbackPage.response(
				success: false,
				title: "Start from LPM Vault",
				label: "Not recognized",
				detail: "This page didn't come from a connection LPM Vault started. Connect Vercel from LPM Vault's Platforms page.")
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
