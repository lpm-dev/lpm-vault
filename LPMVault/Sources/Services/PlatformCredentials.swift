import Foundation

/// Why a connection's access token can't be used now.
enum PlatformCredentialError: Error, Equatable, Sendable {
	case store(PlatformConnectionStoreError)
	/// Renewing the token needs an LPM sign-in.
	case signedOut
	/// The LPM account signed in isn't the one the platform was connected with,
	/// which alone can renew its token.
	case otherAccount
	/// The token can't be renewed any more, so the platform must be connected again.
	case expired
	/// lpm.dev or the platform couldn't be reached, or another request is
	/// still renewing the token. Asking again later finishes the renewal.
	case unavailable
	/// The platform refused lpm.dev's request to renew, not the token; asking again later can work.
	case refused
	case rateLimited
	/// lpm.dev answered in a way LPM Vault couldn't verify.
	case invalidResponse

	func message(for platform: PublishPlatform) -> String {
		let name = platform.displayName
		return switch self {
		case .store(let error): "The connection's token can't be read. \(error)"
		case .signedOut: "Sign in to LPM to keep publishing to \(name). Its connection renews through lpm.dev."
		case .otherAccount: "\(name) was connected while signed in to another LPM account. Sign in with that account, or connect \(name) again on the Platforms page."
		case .expired: "The \(name) connection expired. Connect \(name) again on the Platforms page."
		case .unavailable: "The \(name) connection couldn't be renewed right now. Check your network and try again."
		case .refused: "\(name) refused to renew the connection right now. Try again later."
		case .rateLimited: "The \(name) connection was renewed too often. Wait a minute, then try again."
		case .invalidResponse: "lpm.dev returned an answer LPM Vault couldn't verify. Try again."
		}
	}
}

/// The access tokens publishing uses, renewed through the Registry for a
/// platform whose tokens expire. One connection's token is renewed by one
/// request at a time, however many reviews and publishes ask for it, and each
/// step is saved before the next: the request before it's sent, and the new
/// tokens as soon as they arrive. The platform replaces a refresh token as
/// soon as it's used, so a request whose answer was lost, or the app quit
/// during, is sent again and collects the same tokens.
actor PlatformCredentials {
	typealias SessionProvider = @Sendable () async -> PlatformSession?

	/// How many more times a request still pending at the Registry is asked again.
	static let pendingRetries = 10
	/// How long pending answers are waited out in all, as one can take the
	/// Registry's whole deadline when its database is slow: no request starts
	/// after it, its backoff included.
	static let pendingPatience: Duration = .seconds(40)
	/// How long either side of a refresh token's arrival the Registry may not
	/// know it yet: when keeping the renewal that issued it failed, the
	/// Registry records the token within its refresh's five minutes. A clock
	/// set back further than this leaves no grace.
	static let unknownTokenGrace: TimeInterval = 10 * 60

	private let store: PlatformConnectionStore
	private let refresher: any PlatformTokenRefreshing
	private let session: SessionProvider
	private let now: @Sendable () -> Date
	private let pendingDelay: Duration
	/// A clock no change to the wall clock moves, which pending answers are waited out by.
	private let uptime: @Sendable () -> ContinuousClock.Instant
	private let sleep: @Sendable (Duration) async throws -> Void
	private var running: [PlatformConnection.ID: Task<Result<String, PlatformCredentialError>, Never>] = [:]
	/// How many callers have shared a read, with any renewal, another caller started; it only grows.
	private(set) var sharedReads = 0

	init(
		store: PlatformConnectionStore,
		refresher: any PlatformTokenRefreshing = PlatformAuthorizationClient(),
		session: @escaping SessionProvider,
		now: @escaping @Sendable () -> Date = { Date() },
		pendingDelay: Duration = .seconds(1),
		uptime: @escaping @Sendable () -> ContinuousClock.Instant = { .now },
		sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
	) {
		self.store = store
		self.refresher = refresher
		self.session = session
		self.now = now
		self.pendingDelay = pendingDelay
		self.uptime = uptime
		self.sleep = sleep
	}

	/// The connection's access token, renewed first when it's about to expire
	/// or a renewal is unfinished. Callers asking while a renewal runs share it.
	///
	/// `rejected` is a token the platform just refused. Its connection's token
	/// is renewed even when it looks current, as when the clock is wrong; a
	/// refused token already replaced, as by another renewal, is answered with
	/// its replacement, renewed first as any token is when that's due. A
	/// refused token that doesn't renew means connecting again.
	func accessToken(for connectionID: PlatformConnection.ID, replacing rejected: String? = nil) async -> Result<String, PlatformCredentialError> {
		if let task = running[connectionID] {
			sharedReads += 1
			let result = await task.value
			// A read that ended with the refused token itself can't answer this caller.
			guard let rejected, case .success(rejected) = result else { return result }
		}
		let task = Task { await self.resolve(connectionID, replacing: rejected) }
		running[connectionID] = task
		let result = await task.value
		if running[connectionID] == task { running[connectionID] = nil }
		return result
	}

	private enum Step {
		case done(Result<String, PlatformCredentialError>)
		/// The connection changed meanwhile, as when it was connected again: read it once more.
		case again
	}

	private func resolve(_ connectionID: PlatformConnection.ID, replacing rejected: String?) async -> Result<String, PlatformCredentialError> {
		for _ in 0..<3 {
			switch await step(connectionID, replacing: rejected) {
			case .done(let result): return result
			case .again: continue
			}
		}
		return .failure(.unavailable)
	}

	private func step(_ connectionID: PlatformConnection.ID, replacing rejected: String?) async -> Step {
		let record: PlatformConnectionStore.Record
		switch await store.record(for: connectionID) {
		case .success(let value): record = value
		case .failure(let error): return .done(.failure(.store(error)))
		}
		// Only the refused token itself is renewed for the refusal; a replacement is read as any token is.
		let refused = rejected == record.accessToken
		guard let refresh = record.refresh else {
			return .done(refused ? .failure(.expired) : .success(record.accessToken))
		}
		guard !refresh.isRejected else { return .done(.failure(.expired)) }
		let date = now()
		guard refused || refresh.isDue(at: date) else { return .done(.success(record.accessToken)) }
		// A request already sent may have renewed the token, so it's finished even past the refresh token's expiry.
		guard refresh.attempt != nil || date < refresh.expiresAt,
			let platform = BrowserPlatform(record.connection.platform)
		else { return .done(.failure(.expired)) }
		guard let session = await session() else { return .done(.failure(.signedOut)) }
		guard session.principalID == refresh.principalID else { return .done(.failure(.otherAccount)) }

		let attempt: PlatformTokenRefresh.Attempt
		if let pending = refresh.attempt {
			attempt = pending
		} else {
			let made = PlatformTokenRefresh.Attempt.make(at: date)
			switch await store.beginRefresh(of: connectionID, token: refresh.token, attempt: made) {
			case .success(true): attempt = made
			case .success(false): return .again
			case .failure(let error): return .done(.failure(.store(error)))
			}
		}
		return await renew(
			connectionID, on: platform, token: refresh.token, receivedAt: refresh.obtainedAt, attempt: attempt, session: session)
	}

	private func renew(
		_ connectionID: PlatformConnection.ID,
		on platform: BrowserPlatform,
		token: String,
		receivedAt: Date,
		attempt: PlatformTokenRefresh.Attempt,
		session: PlatformSession
	) async -> Step {
		guard let key = attempt.privateKey else { return .done(.failure(.store(.unreadable))) }
		let patience = uptime() + Self.pendingPatience
		for round in 0...Self.pendingRetries {
			let answer = await refresher.refresh(
				platform, refreshToken: token, clientPublicKey: key.publicKey.x963Representation,
				refreshID: attempt.id, session: session)
			switch answer {
			case .success(.ready(let sealed, let age)):
				let opened = PlatformAuthorizationEnvelope.open(
					sealed, id: attempt.id, clientKey: key, domain: PlatformAuthorizationEnvelope.refreshDomain
				) { payload in
					payload["platform"] as? String == platform.rawValue ? PlatformTokens(payload: payload) : nil
				}
				guard case .success(let tokens) = opened else { return .done(.failure(.invalidResponse)) }
				let date = now()
				let issued = date.addingTimeInterval(-TimeInterval(age))
				switch await store.completeRefresh(of: connectionID, attempt: attempt.id, with: tokens, at: issued) {
				case .success(true):
					// Tokens a retry collected late may be due already; their refresh token renews them.
					let due = tokens.refresh(receivedAt: issued, principalID: session.principalID)?.isDue(at: date) ?? false
					return due ? .again : .done(.success(tokens.accessToken))
				case .success(false): return .again
				case .failure(let error): return .done(.failure(.store(error)))
				}
			case .success(.pending):
				// Backing off, up to eight times the delay: a pending answer can mean the Registry's database is slow.
				let delay = pendingDelay * (1 << min(round, 3))
				guard round < Self.pendingRetries, uptime() + delay < patience else { return .done(.failure(.unavailable)) }
				do { try await sleep(delay) } catch { return .done(.failure(.unavailable)) }
			case .success(.unknown) where abs(now().timeIntervalSince(receivedAt)) < Self.unknownTokenGrace:
				// A connection connected again meanwhile has a token of its own to give.
				switch await store.record(for: connectionID) {
				case .success(let record) where record.refresh?.attempt?.id == attempt.id: return .done(.failure(.unavailable))
				case .success: return .again
				case .failure(let error): return .done(.failure(.store(error)))
				}
			case .success(.failed), .success(.expired), .success(.unknown):
				switch await store.rejectRefresh(of: connectionID, attempt: attempt.id) {
				// The connection was connected again meanwhile; the refusal was of its old token.
				case .success(false): return .again
				case .success(true), .failure: return .done(.failure(.expired))
				}
			case .failure(.signedOut), .failure(.forbidden):
				return .done(.failure(.signedOut))
			case .failure(.rateLimited):
				return .done(.failure(.rateLimited))
			case .failure(.platformRefused):
				return .done(.failure(.refused))
			case .failure(.invalidResponse):
				return .done(.failure(.invalidResponse))
			case .failure(.unavailable), .failure(.transport), .failure(.server), .failure(.tooManyOpen), .failure(.cancelled):
				return .done(.failure(.unavailable))
			}
		}
		return .done(.failure(.unavailable))
	}
}
