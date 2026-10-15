import CryptoKit
import Foundation

enum VercelConnectError: Error, Equatable, Sendable {
	case signedOut
	case forbidden
	case unavailable
	case rateLimited
	case tooManyOpen
	/// This Mac couldn't listen for the browser's return.
	case listenerUnavailable
	/// The browser didn't come back before the connection expired.
	case timedOut
	case cancelled
	case platform(PlatformConnectFailure)
	/// The Registry didn't accept the proof the browser brought back.
	case proofRejected
	case expired
	/// Vercel refused the token it had just granted.
	case tokenRejected
	case transport
	case invalidResponse

	var message: String {
		switch self {
		case .signedOut: "Sign in to LPM to connect Vercel."
		case .forbidden: "This LPM sign-in can't connect platforms. Sign in again from Settings."
		case .unavailable: "Connecting Vercel isn't available right now. Try again later."
		case .rateLimited: "Too many connection attempts. Wait a minute, then try again."
		case .tooManyOpen: "Finish or cancel the Vercel connections already open in your browser first."
		case .listenerUnavailable: "LPM Vault couldn't listen for your browser. Try again."
		case .timedOut: "The connection expired before your browser came back. Connect again."
		case .cancelled: "Connecting Vercel was cancelled."
		case .platform(let failure): failure.message
		case .proofRejected: "Your browser came back with a connection LPM Vault didn't start. Connect again."
		case .expired: "This connection expired. Connect again."
		case .tokenRejected: "Vercel didn't accept the new connection. Connect again."
		case .transport: "The connection couldn't reach lpm.dev or Vercel. Check your network and try again."
		case .invalidResponse: "lpm.dev returned an answer LPM Vault couldn't verify. Try again."
		}
	}
}

/// Connects a Vercel account in the browser through the LPM Vault
/// integration. The Registry only exchanges Vercel's code: the token comes
/// back encrypted to a key that exists only in this connection, and only
/// after the browser returns to this Mac with the one-time proof, so an
/// install link that reaches someone else never hands this Mac their token.
struct VercelConnector: Sendable {
	typealias ListenerFactory = @Sendable () async throws -> PlatformConnectionListener
	typealias ClientFactory = @Sendable (String) -> any VercelClientProtocol

	/// How often a result still pending is asked for again.
	static let pendingRetries = 3
	static let maximumWait: TimeInterval = 15 * 60

	let authorizations: any PlatformAuthorizationClientProtocol
	let listen: ListenerFactory
	let client: ClientFactory
	var pendingDelay: Duration = .milliseconds(500)

	init(
		authorizations: any PlatformAuthorizationClientProtocol = PlatformAuthorizationClient(),
		listen: @escaping ListenerFactory = { try await PlatformConnectionListener.start() },
		client: @escaping ClientFactory = { VercelClient(token: $0) }
	) {
		self.authorizations = authorizations
		self.listen = listen
		self.client = client
	}

	/// Runs one connection: `open` shows Vercel's install page, then this
	/// waits for the browser, collects the grant and checks it with Vercel.
	func connect(
		session: PlatformSession,
		open: @escaping @Sendable (URL) async -> Void
	) async -> Result<(grant: VercelGrant, account: VercelAccount), VercelConnectError> {
		let key = P256.KeyAgreement.PrivateKey()
		let listener: PlatformConnectionListener
		do {
			listener = try await listen()
		} catch {
			return .failure(Task.isCancelled ? .cancelled : .listenerUnavailable)
		}
		defer { listener.stop() }

		let started: StartedPlatformAuthorization
		switch await authorizations.startVercel(
			clientPublicKey: key.publicKey.x963Representation, loopbackPort: listener.port, session: session)
		{
		case .success(let value): started = value
		case .failure(let error): return .failure(Self.connectError(error))
		}
		var collected = false
		defer {
			if !collected {
				let authorizations = authorizations
				Task.detached { await authorizations.cancel(started.id, session: session) }
			}
		}

		listener.expect(started.id, from: session.baseURL)
		guard !Task.isCancelled else { return .failure(.cancelled) }
		await open(started.installURL)

		let completion: PlatformConnectionListener.Completion
		do {
			completion = try await listener.completion(until: min(started.expiresAt, Date(timeIntervalSinceNow: Self.maximumWait)))
		} catch PlatformConnectionListener.ListenerError.timedOut {
			return .failure(.timedOut)
		} catch PlatformConnectionListener.ListenerError.unavailable {
			return .failure(.listenerUnavailable)
		} catch {
			return .failure(.cancelled)
		}
		let proof: String
		switch completion {
		case .failure(let failure): return .failure(.platform(failure))
		case .proof(let value): proof = value
		}

		var sealed: PlatformAuthorizationEnvelope.Sealed?
		for attempt in 0...Self.pendingRetries {
			switch await authorizations.redeem(started.id, proof: proof, session: session) {
			case .success(.ready(let value)):
				collected = true
				sealed = value
			case .success(.pending) where attempt < Self.pendingRetries:
				do { try await Task.sleep(for: pendingDelay) } catch { return .failure(.cancelled) }
				continue
			case .success(.pending): return .failure(.invalidResponse)
			case .success(.failed(let code)): return .failure(.platform(PlatformConnectFailure(code: code)))
			case .success(.expired), .success(.missing): return .failure(.expired)
			case .success(.proofMismatch): return .failure(.proofRejected)
			case .failure(let error): return .failure(Self.connectError(error))
			}
			break
		}
		guard let sealed else { return .failure(.invalidResponse) }

		let grant: VercelGrant
		switch PlatformAuthorizationEnvelope.openVercelGrant(sealed, authorizationID: started.id, clientKey: key) {
		case .success(let value): grant = value
		case .failure: return .failure(.invalidResponse)
		}

		switch await client(grant.accessToken).account(teamID: grant.teamID) {
		case .success(let account):
			return .success((grant, account))
		case .failure(.unauthorized), .failure(.forbidden):
			return .failure(.tokenRejected)
		case .failure(.cancelled):
			return .failure(.cancelled)
		case .failure:
			// The grant is good but its name couldn't be read now; it can't be collected again.
			return .success((grant, VercelAccount(name: grant.teamID == nil ? "Personal account" : "Vercel team", slug: nil)))
		}
	}

	private static func connectError(_ error: PlatformAuthorizationError) -> VercelConnectError {
		switch error {
		case .signedOut: .signedOut
		case .forbidden: .forbidden
		case .unavailable: .unavailable
		case .rateLimited: .rateLimited
		case .tooManyOpen: .tooManyOpen
		case .transport: .transport
		case .cancelled: .cancelled
		case .invalidResponse, .server: .invalidResponse
		}
	}
}
