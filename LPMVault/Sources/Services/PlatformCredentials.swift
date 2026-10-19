import CryptoKit
import Foundation

/// Why a connection's access token can't be used now.
enum PlatformCredentialError: Error, Equatable, Sendable {
	case store(PlatformConnectionStoreError)
	/// Renewing the token needs an LPM sign-in.
	case signedOut
	/// The LPM account signed in isn't the one the platform was connected with,
	/// which alone can renew its token.
	case otherAccount
	/// The connection was made through the other LPM environment's Registry,
	/// which alone renews its token.
	case otherRegistry
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
	/// The connection is being disconnected or replaced, so its token isn't used any more.
	case retired
	/// The platform was connected again since the token was asked for by its
	/// generation, so what that token was chosen for no longer holds.
	case replaced

	func message(for platform: PublishPlatform) -> String {
		let name = platform.displayName
		return switch self {
		case .store(.retired), .retired: "The \(name) connection is being disconnected. Connect \(name) again on the Platforms page."
		case .store(let error): "The connection's token can't be read. \(error)"
		case .signedOut: "Sign in to LPM to keep publishing to \(name). Its connection renews through lpm.dev."
		case .otherAccount: "\(name) was connected while signed in to another LPM account. Sign in with that account, or connect \(name) again on the Platforms page."
		case .otherRegistry: "\(name) was connected through the other LPM environment, which alone renews its connection. Switch to it, or connect \(name) again here."
		case .expired where platform == .cloudflare:
			"The \(name) connection no longer works, as when LPM Vault was removed under Connected Applications on Cloudflare. Connect \(name) again on the Platforms page."
		case .expired: "The \(name) connection expired. Connect \(name) again on the Platforms page."
		case .unavailable: "The \(name) connection couldn't be renewed right now. Check your network and try again."
		case .refused: "\(name) refused to renew the connection right now. Try again later."
		case .rateLimited: "The \(name) connection was renewed too often. Wait a minute, then try again."
		case .invalidResponse: "lpm.dev returned an answer LPM Vault couldn't verify. Try again."
		case .replaced: "The \(name) connection changed since this review. Review again."
		}
	}
}

/// What became of a new grant LPM Vault won't keep.
enum PlatformGrantDiscard: Equatable, Sendable {
	/// The platform ended its tokens.
	case revoked
	/// A cleanup entry goes on revoking its tokens.
	case pending
	/// Its tokens may still work: their revocation couldn't be confirmed, nor saved to try again.
	case unconfirmed
}

/// The access tokens publishing uses, renewed through the Registry for a
/// platform whose tokens expire. One connection's token is renewed by one
/// request at a time, however many reviews and publishes ask for it, and each
/// step is saved before the next: the request before it's sent, and the new
/// tokens as soon as they arrive. The platform replaces a refresh token as
/// soon as it's used, so a request whose answer was lost, or the app quit
/// during, is sent again and collects the same tokens.
///
/// A Cloudflare connection's renewals, retirement and cleanup all go through
/// here, so retiring a generation waits for a renewal of it in flight, and
/// its cleanup entry holds the tokens that renewal left. Cleanup entries are
/// revoked in the background, and wait as long as they have to.
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
	/// How soon a cleanup that couldn't finish is tried again, doubling each
	/// time up to `longestCleanupDelay`.
	static let firstCleanupDelay: Duration = .seconds(5)
	static let longestCleanupDelay: Duration = .seconds(5 * 60)
	/// How often cleanups waiting for a sign-in to their Registry look again.
	static let sessionCleanupDelay: Duration = .seconds(10 * 60)
	/// The Registry's code for a renewal the platform refused for good, which ended the token's family.
	static let familyEndedCode = "refresh_rejected"

	private let store: PlatformConnectionStore
	private let refresher: any PlatformTokenRefreshing
	private let revoker: any PlatformTokenRevoking
	private let session: SessionProvider
	private let now: @Sendable () -> Date
	private let pendingDelay: Duration
	/// A clock no change to the wall clock moves, which pending answers and cleanups are waited out by.
	private let uptime: @Sendable () -> ContinuousClock.Instant
	private let sleep: @Sendable (Duration) async throws -> Void
	private let productionClientID: String?
	/// Called after a cleanup changed what the Platforms page shows.
	private let cleanupChanged: @Sendable () -> Void
	private var running: [PlatformConnection.ID: Task<Result<String, PlatformCredentialError>, Never>] = [:]
	/// Connections a retirement is waiting on, whose tokens nobody reads meanwhile.
	private var retiring: [PlatformConnection.ID: Int] = [:]
	/// How many callers have shared a read, with any renewal, another caller started; it only grows.
	private(set) var sharedReads = 0

	private var cleanupTask: Task<Void, Never>?
	/// Cleanup was asked for while it ran, so it looks at the entries once more.
	private var cleanupWanted = false
	/// When each waiting cleanup is due, and how long it waits next time, by generation.
	private var cleanupDue: [String: ContinuousClock.Instant] = [:]
	private var cleanupDelays: [String: Duration] = [:]
	/// Generations whose cleanup is running now, which nothing else starts meanwhile.
	private var cleaning: Set<String> = []

	init(
		store: PlatformConnectionStore,
		refresher: any PlatformTokenRefreshing = PlatformAuthorizationClient(),
		revoker: any PlatformTokenRevoking = PlatformAuthorizationClient(),
		session: @escaping SessionProvider,
		now: @escaping @Sendable () -> Date = { Date() },
		pendingDelay: Duration = .seconds(1),
		uptime: @escaping @Sendable () -> ContinuousClock.Instant = { .now },
		sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
		productionClientID: String? = CloudflareOAuth.productionClientID,
		cleanupChanged: @escaping @Sendable () -> Void = {}
	) {
		self.store = store
		self.refresher = refresher
		self.revoker = revoker
		self.session = session
		self.now = now
		self.pendingDelay = pendingDelay
		self.uptime = uptime
		self.sleep = sleep
		self.productionClientID = productionClientID
		self.cleanupChanged = cleanupChanged
	}

	/// The connection's access token, renewed first when it's about to expire
	/// or a renewal is unfinished. Callers asking while a renewal runs share it.
	///
	/// `rejected` is a token the platform just refused. Its connection's token
	/// is renewed even when it looks current, as when the clock is wrong; a
	/// refused token already replaced, as by another renewal, is answered with
	/// its replacement, renewed first as any token is when that's due. A
	/// refused token that doesn't renew means connecting again.
	///
	/// With `generation`, the token is given only while the connection holds
	/// that generation: one connected again since fails as `replaced`.
	func accessToken(
		for connectionID: PlatformConnection.ID,
		replacing rejected: String? = nil,
		generation: String? = nil
	) async -> Result<String, PlatformCredentialError> {
		guard retiring[connectionID] == nil else { return .failure(.retired) }
		while let task = running[connectionID] {
			sharedReads += 1
			let result = await task.value
			if running[connectionID] == task { running[connectionID] = nil }
			// A read that ended with the refused token itself can't answer this caller, nor
			// can one that didn't check the generation this caller holds to.
			if generation == nil, rejected.map({ result != .success($0) }) ?? true { return result }
			guard retiring[connectionID] == nil else { return .failure(.retired) }
		}
		let task = Task { await self.resolve(connectionID, replacing: rejected, generation: generation) }
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

	private func resolve(
		_ connectionID: PlatformConnection.ID,
		replacing rejected: String?,
		generation: String?
	) async -> Result<String, PlatformCredentialError> {
		for _ in 0..<3 {
			switch await step(connectionID, replacing: rejected, generation: generation) {
			case .done(let result): return result
			case .again: continue
			}
		}
		return .failure(.unavailable)
	}

	private func step(_ connectionID: PlatformConnection.ID, replacing rejected: String?, generation: String?) async -> Step {
		let record: PlatformConnectionStore.Record
		switch await store.record(for: connectionID) {
		case .success(let value): record = value
		case .failure(.retired): return .done(.failure(.retired))
		case .failure(let error): return .done(.failure(.store(error)))
		}
		if let generation, record.connection.generation != generation { return .done(.failure(.replaced)) }
		var cloudflare: CloudflareConnectionAccount?
		if case .cloudflare(let account) = record.connection.account {
			// Tokens of a client this Registry doesn't run, as after the production client changed, can't renew.
			guard CloudflareOAuth.accepts(account.clientID, for: account.issuer, productionClientID: productionClientID) else {
				return .done(.failure(.expired))
			}
			cloudflare = account
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
		else {
			// LPM's eligibility for the Cloudflare token ended, though Cloudflare still honours it: it's revoked first.
			if let cloudflare { await retireEnded(connectionID, generation: cloudflare.generation) }
			return .done(.failure(.expired))
		}
		guard let session = await session() else { return .done(.failure(.signedOut)) }
		guard session.principalID == refresh.principalID else { return .done(.failure(.otherAccount)) }
		if let cloudflare, session.issuer != cloudflare.issuer { return .done(.failure(.otherRegistry)) }

		let attempt: PlatformTokenRefresh.Attempt
		if let pending = refresh.attempt {
			attempt = pending
		} else {
			let made = PlatformTokenRefresh.Attempt.make(at: date)
			switch await store.beginRefresh(of: connectionID, token: refresh.token, attempt: made) {
			case .success(true): attempt = made
			case .success(false): return .again
			case .failure(.retired): return .done(.failure(.retired))
			case .failure(let error): return .done(.failure(.store(error)))
			}
		}
		return await renew(
			connectionID, on: platform, token: refresh.token, receivedAt: refresh.obtainedAt, attempt: attempt, session: session,
			generation: cloudflare?.generation)
	}

	private func renew(
		_ connectionID: PlatformConnection.ID,
		on platform: BrowserPlatform,
		token: String,
		receivedAt: Date,
		attempt: PlatformTokenRefresh.Attempt,
		session: PlatformSession,
		generation: String?
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
				case .failure(.retired): return .done(.failure(.retired))
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
				case .failure(.retired): return .done(.failure(.retired))
				case .failure(let error): return .done(.failure(.store(error)))
				}
			case .success(.expired):
				guard let generation else { return reconnect(await store.rejectRefresh(of: connectionID, attempt: attempt.id)) }
				// The Registry's eligibility for the Cloudflare token ended: it's revoked, with the attempt's key, before connecting again.
				await retireEnded(connectionID, generation: generation)
				return .done(.failure(.expired))
			case .success(.failed(let code)):
				// Unless Cloudflare ended the family, whether it renewed the token isn't known: the attempt's key stays for its cleanup.
				let keeping = generation != nil && code != Self.familyEndedCode
				return reconnect(await store.rejectRefresh(of: connectionID, attempt: attempt.id, keepingAttempt: keeping))
			case .success(.unknown):
				return reconnect(await store.rejectRefresh(of: connectionID, attempt: attempt.id, keepingAttempt: generation != nil))
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

	/// What a refused renewal leaves: connecting again, unless the connection
	/// was connected again meanwhile, whose own token is read instead.
	private func reconnect(_ rejected: Result<Bool, PlatformConnectionStoreError>) -> Step {
		switch rejected {
		case .success(false): .again
		case .success(true), .failure: .done(.failure(.expired))
		}
	}

	// MARK: - Retirement

	/// Retires the connection's `generation`, as when it's disconnected or
	/// replaced: once any renewal of it in flight ends, writes its cleanup
	/// entry, which from then on keeps its tokens and retires its record. The
	/// caller revokes it with `revokeNow`, which leaves it to the background
	/// when it can't finish. Nil when the connection holds another generation now, or none.
	func retire(_ connectionID: PlatformConnection.ID, generation: String) async -> Result<PlatformCleanupEntry?, PlatformCredentialError> {
		retiring[connectionID, default: 0] += 1
		defer {
			retiring[connectionID, default: 1] -= 1
			if retiring[connectionID] == 0 { retiring[connectionID] = nil }
		}
		while let task = running[connectionID] {
			_ = await task.value
			if running[connectionID] == task { running[connectionID] = nil }
		}
		return await store.retire(connectionID, generation: generation, at: now()).mapError(PlatformCredentialError.store)
	}

	/// Retires a generation whose eligibility ended, from within its own read,
	/// which a retirement would otherwise wait for.
	private func retireEnded(_ connectionID: PlatformConnection.ID, generation: String) async {
		if case .success(_?) = await store.retire(connectionID, generation: generation, at: now()) {
			resumeCleanup()
			cleanupChanged()
		}
	}

	/// Tries once, now, to finish the cleanup of `entry`, as a disconnect or
	/// a reconnect does before going on; true when it's finished. One that
	/// isn't goes on in the background.
	func revokeNow(_ entry: PlatformCleanupEntry) async -> Bool {
		guard cleaning.insert(entry.generation).inserted else { return false }
		defer { cleaning.remove(entry.generation) }
		var current = entry
		// A renewal's successor is revoked in turn, within the same try.
		for _ in 0..<3 {
			switch await clean(current) {
			case .done:
				cleanupDue[entry.generation] = nil
				cleanupDelays[entry.generation] = nil
				return true
			case .again(let next):
				current = next
			case .wait, .waitForSession:
				resumeCleanup()
				return false
			}
		}
		resumeCleanup()
		return false
	}

	/// Revokes a new grant LPM Vault won't keep, with its tokens in memory,
	/// as when connecting was cancelled or its checks failed. A revocation
	/// that isn't confirmed now writes a cleanup entry, which goes on trying.
	func discard(
		refreshToken: String,
		connectionID: PlatformConnection.ID,
		generation: String,
		issuer: PlatformIssuer,
		clientID: String
	) async -> PlatformGrantDiscard {
		let entry = PlatformCleanupEntry(
			platform: .cloudflare, connectionID: connectionID, generation: generation, issuer: issuer, clientID: clientID,
			refreshToken: refreshToken, attempt: nil, createdAt: now())
		if let session = await session(), session.issuer == issuer,
			CloudflareOAuth.accepts(clientID, for: issuer, productionClientID: productionClientID)
		{
			switch await revoker.revoke(.cloudflare, token: refreshToken, revocationID: entry.revocationID, attempt: nil, session: session) {
			case .success(.accepted):
				return .revoked
			case .success(.unconfirmed):
				_ = await store.mark(PlatformCleanupMarker(platform: .cloudflare, generation: generation, createdAt: now()))
				cleanupChanged()
				return .unconfirmed
			case .success, .failure:
				break
			}
		}
		guard case .success = await store.writeCleanup(entry) else { return .unconfirmed }
		resumeCleanup()
		cleanupChanged()
		return .pending
	}

	// MARK: - Cleanup

	/// Starts revoking what cleanup entries hold, in the background, as when
	/// an entry is written. With `now`, entries waiting for a sign-in or a
	/// backoff are tried at once, as when the vault unlocks, LPM signs in, or
	/// the app switches its Registry. Nothing is sent while there's no session.
	func resumeCleanup(now: Bool = false) {
		if now { cleanupDue = [:] }
		guard cleanupTask == nil else {
			cleanupWanted = true
			return
		}
		cleanupTask = Task { await self.runCleanup() }
	}

	/// Waits until the cleanup in the background has nothing to do now; for tests.
	func cleanupSettled() async {
		while let task = cleanupTask { await task.value }
	}

	private enum CleanupStep {
		case done
		/// The entry now holds a renewal's successor, to revoke next.
		case again(PlatformCleanupEntry)
		/// Not done; try again after the delay.
		case wait(Duration?)
		/// It needs a sign-in to its own Registry, with its own client.
		case waitForSession
	}

	private func runCleanup() async {
		defer {
			cleanupTask = nil
			if cleanupWanted {
				cleanupWanted = false
				resumeCleanup()
			}
		}
		while !Task.isCancelled {
			cleanupWanted = false
			guard case .success(let stored) = await store.cleanup() else { return }
			var wake: ContinuousClock.Instant?
			for item in stored.entries {
				guard !Task.isCancelled else { return }
				switch item {
				case .unreadable(_, isNewer: true):
					// A newer LPM Vault wrote it; it's left for that version.
					continue
				case .unreadable(let generation, isNewer: false):
					_ = await store.abandonCleanup(of: generation, platform: .cloudflare, at: now())
					cleanupChanged()
				case .readable(var entry):
					if let due = cleanupDue[entry.generation], due > uptime() {
						wake = min(wake ?? due, due)
						continue
					}
					// Another try of it is running, as a disconnect's, which resumes this when it can't finish.
					guard cleaning.insert(entry.generation).inserted else { continue }
					var step = await clean(entry)
					while case .again(let next) = step, !Task.isCancelled {
						entry = next
						step = await clean(entry)
					}
					cleaning.remove(entry.generation)
					let delay: Duration
					switch step {
					case .done, .again:
						cleanupDue[entry.generation] = nil
						cleanupDelays[entry.generation] = nil
						continue
					case .wait(let asked):
						let backoff = cleanupDelays[entry.generation] ?? Self.firstCleanupDelay
						cleanupDelays[entry.generation] = min(backoff * 2, Self.longestCleanupDelay)
						delay = max(asked ?? .zero, backoff)
					case .waitForSession:
						delay = Self.sessionCleanupDelay
					}
					let due = uptime() + delay
					cleanupDue[entry.generation] = due
					wake = min(wake ?? due, due)
				}
			}
			guard !cleanupWanted else { continue }
			guard let wake else { return }
			do { try await sleep(max(.zero, wake - uptime())) } catch { return }
		}
	}

	/// One request revoking what `entry` holds, and what its answer does to the entry.
	private func clean(_ entry: PlatformCleanupEntry) async -> CleanupStep {
		guard let session = await session(), session.issuer == entry.issuer,
			CloudflareOAuth.accepts(entry.clientID, for: entry.issuer, productionClientID: productionClientID)
		else { return .waitForSession }
		let key = entry.attempt?.privateKey
		let attempt = entry.attempt.flatMap { attempt in key.map { (id: attempt.id, publicKey: $0.publicKey.x963Representation) } }
		switch await revoker.revoke(entry.platform, token: entry.refreshToken, revocationID: entry.revocationID, attempt: attempt, session: session) {
		case .success(.accepted):
			return finished(await store.finishCleanup(entry, unconfirmed: false, at: now()))
		case .success(.unconfirmed):
			return finished(await store.finishCleanup(entry, unconfirmed: true, at: now()))
		case .success(.superseded(let sealed, _)):
			guard let pending = entry.attempt, let key,
				case .success(let tokens) = PlatformAuthorizationEnvelope.open(
					sealed, id: pending.id, clientKey: key, domain: PlatformAuthorizationEnvelope.refreshDomain,
					read: { $0["platform"] as? String == entry.platform.rawValue ? PlatformTokens(payload: $0) : nil }),
				let successor = tokens.expiry?.refreshToken
			else { return .wait(nil) }
			switch await store.replaceCleanupToken(of: entry.generation, renewedBy: pending.id, with: successor) {
			case .success(true):
				var next = entry
				next.refreshToken = successor
				next.attempt = nil
				return .again(next)
			case .success(false):
				return .done
			case .failure:
				return .wait(nil)
			}
		case .success(.busy):
			return .wait(nil)
		case .success(.retry(let seconds)):
			return .wait(.seconds(seconds))
		case .failure(.signedOut), .failure(.forbidden):
			return .waitForSession
		case .failure(.rateLimited):
			return .wait(.seconds(60))
		case .failure:
			return .wait(nil)
		}
	}

	/// What ending a cleanup in the store leaves: done, or the same answer asked for again later.
	private func finished(_ result: Result<Void, PlatformConnectionStoreError>) -> CleanupStep {
		guard case .success = result else { return .wait(nil) }
		cleanupChanged()
		return .done
	}
}
