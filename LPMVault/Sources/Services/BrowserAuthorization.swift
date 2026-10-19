import CryptoKit
import Foundation

enum BrowserConnectError: Error, Equatable, Sendable {
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
	/// The platform refused the token it had just granted.
	case tokenRejected
	/// The platform didn't say whose the token it had just granted is.
	case accountUnreadable
	/// The person approved LPM Vault for no account it can reach.
	case noAccounts
	/// The platform was limiting requests when the new connection was read,
	/// until the time it said, when it did.
	case platformRateLimited(until: Date?)
	case transport
	case invalidResponse

	func message(for platform: BrowserPlatform, now: Date = Date()) -> String {
		let name = platform.displayName
		return switch self {
		case .signedOut: "Sign in to LPM to connect \(name)."
		case .forbidden: "This LPM sign-in can't connect platforms. Sign in again from the Account page."
		case .unavailable: "Connecting \(name) isn't available right now. Try again later."
		case .rateLimited: "Too many connection attempts. Wait a minute, then try again."
		case .tooManyOpen: "Finish or cancel the platform connections already open in your browser first."
		case .listenerUnavailable: "LPM Vault couldn't listen for your browser. Try again."
		case .timedOut: "The connection expired before your browser came back. Connect again."
		case .cancelled: "Connecting \(name) was cancelled."
		case .platform(let failure): failure.message(for: platform)
		case .proofRejected: "Your browser came back with a connection LPM Vault didn't start. Connect again."
		case .expired: "This connection expired. Connect again."
		case .tokenRejected: "\(name) didn't accept the new connection. Connect again."
		case .accountUnreadable: "\(name) didn't say which account was connected. Connect again."
		case .noAccounts: "\(name) gave LPM Vault no account to reach. Connect again, and choose the accounts whose Workers it publishes to."
		case .platformRateLimited(let reset?) where reset.timeIntervalSince(now) > 90:
			"\(name) is limiting requests until \(reset.formatted(date: .omitted, time: .shortened)). Connect again then."
		// GitHub backs off for minutes from limits it doesn't time; Netlify's window is a minute.
		case .platformRateLimited(nil) where platform == .github: "\(name) is limiting requests. Wait a few minutes, then connect again."
		case .platformRateLimited: "\(name) is limiting requests. Wait a minute, then connect again."
		case .transport: "The connection couldn't reach lpm.dev or \(name). Check your network and try again."
		case .invalidResponse: "lpm.dev returned an answer LPM Vault couldn't verify. Try again."
		}
	}
}

/// A grant a browser connection collected.
struct BrowserGrant<Grant: PlatformGrant>: Sendable {
	let grant: Grant
	/// How many seconds before it was collected the Registry completed it,
	/// which its tokens' lifetimes count from.
	let age: Int
	/// The platform's page the person approved it on, as the Registry gave it.
	let pageURL: URL
	/// The connection was cancelled after the browser came back, so the grant
	/// was collected only to be revoked.
	let wasCancelled: Bool
}

/// Connects a platform account in the browser through the Registry, up to
/// the grant it seals for this Mac. The Registry only exchanges the
/// platform's code: the grant comes back encrypted to a key that exists only
/// in this connection, and only after the browser returns to this Mac with
/// the one-time proof, so a link that reaches someone else never hands this
/// Mac their token.
struct BrowserAuthorization: Sendable {
	typealias ListenerFactory = @Sendable (BrowserPlatform) async throws -> PlatformConnectionListener

	/// How often a result still pending is asked for again.
	static let pendingRetries = 3
	static let maximumWait: TimeInterval = 15 * 60
	/// How long after an authorization expires the browser can still come
	/// back: the Registry finishes exchanging a code it claimed before the
	/// expiry within this window (`AUTHORIZATION_EXCHANGE_WINDOW_MS`).
	static let exchangeWindow: TimeInterval = 2 * 60

	let authorizations: any PlatformAuthorizationClientProtocol
	let listen: ListenerFactory
	var pendingDelay: Duration = .milliseconds(500)

	init(
		authorizations: any PlatformAuthorizationClientProtocol = PlatformAuthorizationClient(),
		listen: @escaping ListenerFactory = { try await PlatformConnectionListener.start(for: $0) }
	) {
		self.authorizations = authorizations
		self.listen = listen
	}

	/// Runs one connection: `open` shows the platform's page, then this
	/// waits for the browser and collects the grant, once. An authorization
	/// that ends without being collected is cancelled on the Registry.
	///
	/// With `collectsAfterReturn`, for a platform whose grant LPM Vault can
	/// revoke, a connection cancelled once the browser has come back still
	/// collects its grant, marked as cancelled: the platform has issued its
	/// tokens by then, and only whoever holds them can end them.
	///
	/// `acceptsPage` checks the page the Registry gave before it's opened; a
	/// page it refuses is never opened, and the connection ends.
	func grant<Grant: PlatformGrant>(
		_: Grant.Type,
		session: PlatformSession,
		collectsAfterReturn: Bool = false,
		acceptsPage: @escaping @Sendable (URL) -> Bool = { _ in true },
		open: @escaping @Sendable (URL) async -> Void
	) async -> Result<BrowserGrant<Grant>, BrowserConnectError> {
		let platform = Grant.platform
		let key = P256.KeyAgreement.PrivateKey()
		let listener: PlatformConnectionListener
		do {
			listener = try await listen(platform)
		} catch {
			return .failure(Task.isCancelled ? .cancelled : .listenerUnavailable)
		}
		defer { listener.stop() }

		let started: StartedPlatformAuthorization
		switch await authorizations.start(
			platform, clientPublicKey: key.publicKey.x963Representation, loopbackPort: listener.port, session: session)
		{
		case .success(let value): started = value
		case .failure(let error): return .failure(Self.connectError(error))
		}
		var collected = false
		defer {
			if !collected {
				let authorizations = authorizations
				Task.detached { await authorizations.cancel(started.id, on: platform, session: session) }
			}
		}

		guard acceptsPage(started.pageURL) else { return .failure(.invalidResponse) }
		listener.expect(started.id, from: session.baseURL)
		guard !Task.isCancelled else { return .failure(.cancelled) }
		await open(started.pageURL)

		let completion: PlatformConnectionListener.Completion
		do {
			completion = try await listener.completion(
				until: min(started.expiresAt.addingTimeInterval(Self.exchangeWindow), Date(timeIntervalSinceNow: Self.maximumWait)))
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

		let redeeming = redeem(started.id, on: platform, proof: proof, session: session)
		let redeemed: Result<(PlatformAuthorizationEnvelope.Sealed, age: Int), BrowserConnectError>
		if collectsAfterReturn {
			// Its own task, so cancelling the connection doesn't abandon a grant the platform already issued.
			redeemed = await Task { await redeeming() }.value
		} else {
			redeemed = await redeeming()
		}
		let sealed: PlatformAuthorizationEnvelope.Sealed
		let age: Int
		switch redeemed {
		case .success(let value):
			collected = true
			(sealed, age) = value
		case .failure(let error):
			return .failure(error)
		}

		switch PlatformAuthorizationEnvelope.open(sealed, as: Grant.self, authorizationID: started.id, clientKey: key) {
		case .success(let grant):
			return .success(BrowserGrant(grant: grant, age: age, pageURL: started.pageURL, wasCancelled: Task.isCancelled))
		case .failure: return .failure(.invalidResponse)
		}
	}

	/// Collects the grant with the browser's proof, asking again while it's pending.
	private func redeem(
		_ id: String,
		on platform: BrowserPlatform,
		proof: String,
		session: PlatformSession
	) -> @Sendable () async -> Result<(PlatformAuthorizationEnvelope.Sealed, age: Int), BrowserConnectError> {
		{ [authorizations, pendingDelay] in
			for attempt in 0...Self.pendingRetries {
				switch await authorizations.redeem(id, on: platform, proof: proof, session: session) {
				case .success(.ready(let sealed, let age)):
					return .success((sealed, age))
				case .success(.pending) where attempt < Self.pendingRetries:
					do { try await Task.sleep(for: pendingDelay) } catch { return .failure(.cancelled) }
				case .success(.pending): return .failure(.invalidResponse)
				case .success(.failed(let code)): return .failure(.platform(PlatformConnectFailure(code: code)))
				case .success(.expired), .success(.missing): return .failure(.expired)
				case .success(.proofMismatch): return .failure(.proofRejected)
				case .failure(let error): return .failure(Self.connectError(error))
				}
			}
			return .failure(.invalidResponse)
		}
	}

	private static func connectError(_ error: PlatformAuthorizationError) -> BrowserConnectError {
		switch error {
		case .signedOut: .signedOut
		case .forbidden: .forbidden
		case .unavailable, .platformRefused: .unavailable
		case .rateLimited: .rateLimited
		case .tooManyOpen: .tooManyOpen
		case .transport: .transport
		case .cancelled: .cancelled
		case .invalidResponse, .server: .invalidResponse
		}
	}
}
