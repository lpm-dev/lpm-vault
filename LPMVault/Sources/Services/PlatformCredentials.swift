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

/// What became of tokens LPM Vault set out to revoke.
enum PlatformRevocation: Equatable, Sendable {
	/// The platform ended them.
	case revoked
	/// A cleanup entry goes on revoking them in the background.
	case pending
	/// A cleanup entry keeps them, but nothing is sent until LPM is signed
	/// in through the Registry that issued them.
	case waitingForSignIn
	/// They may still work: lpm.dev couldn't confirm their revocation, or it
	/// couldn't be saved to try again. A note on the Platforms page says so.
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
	/// A read of a connection's token in flight, which callers asking meanwhile share.
	private struct Read {
		let task: Task<Result<String, PlatformCredentialError>, Never>
		/// The generation the read holds the connection to, if any.
		let generation: String?
	}

	private var running: [PlatformConnection.ID: Read] = [:]
	/// Connections a retirement is waiting on, whose tokens nobody reads meanwhile.
	private var retiring: [PlatformConnection.ID: Int] = [:]
	/// How many callers have shared a read, with any renewal, another caller started; it only grows.
	private(set) var sharedReads = 0

	private var cleanupTask: Task<Void, Never>?
	/// The cleanup's wait until an entry is due, which `resumeCleanup` cuts short.
	private var cleanupNap: Task<Void, any Error>?
	/// Cleanup was asked for while it ran, so it looks at the entries once more.
	private var cleanupWanted = false
	/// Until when no revocation is sent, as lpm.dev limits this person's or
	/// couldn't be reached, and how long the next such pause lasts.
	private var cleanupPause: ContinuousClock.Instant?
	private var pauseDelay: Duration?
	/// How long cleanup waits before listing its entries again, after the Keychain failed to.
	private var listingDelay: Duration?
	/// Notes of revocations lpm.dev couldn't confirm that the Keychain
	/// couldn't save either, shown until they're dismissed or the app quits.
	private(set) var unsavedMarkers: [PlatformCleanupMarker] = []
	/// Generations whose cleanup waits for a sign-in to the Registry that issued their tokens.
	private(set) var waitingForSignIn: Set<String> = []
	/// When each waiting cleanup is due, and how long it waits next time, by generation.
	private var cleanupDue: [String: ContinuousClock.Instant] = [:]
	private var cleanupDelays: [String: Duration] = [:]
	/// Generations whose cleanup is running now, which nothing else starts meanwhile.
	private var cleaning: Set<String> = []
	/// lpm.dev takes one of a person's revocations at a time, so this Mac
	/// sends one at a time: the rest wait their turn here, in order.
	private var revocationInFlight = false
	private var revocationTurns: [CheckedContinuation<Void, Never>] = []

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
		while let read = running[connectionID] {
			sharedReads += 1
			let result = await read.task.value
			if running[connectionID]?.task == read.task { running[connectionID] = nil }
			// A read held to another generation than this caller's, or to none when this caller holds to one,
			// can't answer it, nor can one that ended with the refused token itself.
			let answers = generation == nil ? result != .failure(.replaced) : read.generation == generation
			if answers, rejected.map({ result != .success($0) }) ?? true { return result }
			guard retiring[connectionID] == nil else { return .failure(.retired) }
		}
		let task = Task { await self.resolve(connectionID, replacing: rejected, generation: generation) }
		running[connectionID] = Read(task: task, generation: generation)
		let result = await task.value
		if running[connectionID]?.task == task { running[connectionID] = nil }
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
	/// when it can't finish.
	func retire(
		_ connectionID: PlatformConnection.ID,
		generation: String
	) async -> Result<PlatformConnectionStore.Retirement, PlatformCredentialError> {
		retiring[connectionID, default: 0] += 1
		defer {
			retiring[connectionID, default: 1] -= 1
			if retiring[connectionID] == 0 { retiring[connectionID] = nil }
		}
		while let read = running[connectionID] {
			_ = await read.task.value
			if running[connectionID]?.task == read.task { running[connectionID] = nil }
		}
		return await store.retire(connectionID, generation: generation, at: now()).mapError(PlatformCredentialError.store)
	}

	/// Retires a generation whose eligibility ended, from within its own read,
	/// which a retirement would otherwise wait for. Once its tokens are
	/// revoked, the login stays, as one to reconnect.
	private func retireEnded(_ connectionID: PlatformConnection.ID, generation: String) async {
		if case .success(.entry) = await store.retire(connectionID, generation: generation, asksToReconnect: true, at: now()) {
			resumeCleanup()
			cleanupChanged()
		}
	}

	/// Tries once, now, to finish the cleanup of `entry`, as a disconnect or
	/// a reconnect does before going on, even when the caller is cancelled.
	/// One that isn't finished goes on in the background, no sooner than lpm.dev asked.
	func revokeNow(_ entry: PlatformCleanupEntry) async -> PlatformRevocation {
		// Its own task, so a cancelled caller still sends it.
		await Task { await self.revoking(entry) }.value
	}

	private func revoking(_ entry: PlatformCleanupEntry) async -> PlatformRevocation {
		guard cleaning.insert(entry.generation).inserted else { return .pending }
		defer { cleaning.remove(entry.generation) }
		// While lpm.dev takes none of this person's revocations, the background tries it once the pause ends.
		guard !isPaused else {
			resumeCleanup()
			return .pending
		}
		var step = CleanupStep.waitForSession
		if let session = await session(for: entry) {
			step = await clean(entry, session: session)
			// A renewal's successor is revoked in turn; it has no renewal of its own to hand over.
			while case .again(let next) = step { step = await clean(next, session: session) }
		}
		postpone(entry.generation, after: step)
		switch step {
		case .done(let outcome):
			return outcome
		case .waitForSession:
			resumeCleanup()
			return .waitingForSignIn
		case .again, .wait, .pause:
			resumeCleanup()
			return .pending
		}
	}

	/// Revokes a new grant LPM Vault won't keep, with its tokens in memory,
	/// as when connecting was cancelled or its checks failed, even when the
	/// caller is cancelled. A revocation that isn't confirmed now writes a
	/// cleanup entry, which goes on trying; one whose entry can't be saved
	/// either leaves a note.
	func discard(
		refreshToken: String,
		connectionID: PlatformConnection.ID,
		generation: String,
		issuer: PlatformIssuer,
		clientID: String
	) async -> PlatformRevocation {
		// Its own task, so a cancelled connection still sends it.
		await Task {
			await self.discarding(
				refreshToken: refreshToken, connectionID: connectionID, generation: generation, issuer: issuer, clientID: clientID)
		}.value
	}

	private func discarding(
		refreshToken: String,
		connectionID: PlatformConnection.ID,
		generation: String,
		issuer: PlatformIssuer,
		clientID: String
	) async -> PlatformRevocation {
		let entry = PlatformCleanupEntry(
			platform: .cloudflare, connectionID: connectionID, generation: generation, issuer: issuer, clientID: clientID,
			refreshToken: refreshToken, attempt: nil, createdAt: now())
		// Not tried while lpm.dev takes none of this person's revocations: the entry waits for the pause to end.
		var step: CleanupStep?
		if !isPaused {
			if let session = await session(for: entry) {
				step = await clean(entry, session: session, stored: false)
			} else {
				step = .waitForSession
			}
		}
		if case .done(let outcome)? = step { return outcome }
		guard case .success = await store.writeCleanup(entry) else {
			await note(PlatformCleanupMarker(platform: .cloudflare, generation: generation, createdAt: now()))
			return .unconfirmed
		}
		if let step { postpone(generation, after: step) }
		resumeCleanup()
		cleanupChanged()
		if case .waitForSession? = step { return .waitingForSignIn }
		return .pending
	}

	/// Leaves a note that a Cloudflare login's tokens may still work. One the
	/// Keychain can't save is kept in memory until it's dismissed.
	func note(_ marker: PlatformCleanupMarker) async {
		if case .failure = await store.mark(marker), !unsavedMarkers.contains(where: { $0.generation == marker.generation }) {
			unsavedMarkers.append(marker)
		}
		cleanupChanged()
	}

	/// Forgets the notes of `generations` kept in memory, which the person dismissed.
	func forgetUnsavedMarkers(_ generations: Set<String>) {
		unsavedMarkers.removeAll { generations.contains($0.generation) }
	}

	// MARK: - Cleanup

	/// Starts revoking what cleanup entries hold, in the background, as when
	/// an entry is written, and wakes a cleanup waiting to try again. With
	/// `now`, entries waiting for a sign-in or a backoff are tried at once,
	/// as when the vault unlocks, LPM signs in, or the app switches its
	/// Registry. Nothing is sent while there's no session.
	func resumeCleanup(now: Bool = false) {
		if now {
			cleanupDue = [:]
			cleanupPause = nil
		}
		guard cleanupTask == nil else {
			cleanupWanted = true
			cleanupNap?.cancel()
			return
		}
		cleanupTask = Task { await self.runCleanup() }
	}

	/// Stops the cleanup in the background, as when the vault locks, when
	/// nothing could be sent anyway; `resumeCleanup` starts it again.
	func stopCleanup() {
		cleanupWanted = false
		cleanupTask?.cancel()
		cleanupNap?.cancel()
	}

	/// Waits until the cleanup in the background has nothing to do now; for tests.
	func cleanupSettled() async {
		while let task = cleanupTask { await task.value }
	}

	private enum CleanupStep {
		/// The cleanup ended: the tokens were revoked, or lpm.dev couldn't confirm it and a note says so.
		case done(PlatformRevocation)
		/// The entry now holds a renewal's successor, to revoke next.
		case again(PlatformCleanupEntry)
		/// Not done; this entry is tried again after the delay, or its backoff when that's longer.
		case wait(Duration?)
		/// No entry is tried until the delay, or the pause's backoff, passes:
		/// lpm.dev takes no revocations from this person now, or can't be reached.
		case pause(Duration?)
		/// It needs a sign-in to its own Registry, with its own client.
		case waitForSession
	}

	private var isPaused: Bool {
		cleanupPause.map { $0 > uptime() } ?? false
	}

	/// The session `entry` is revoked with: one signed in to its own
	/// Registry, which must still run its client. Nil sends nothing.
	private func session(for entry: PlatformCleanupEntry) async -> PlatformSession? {
		guard CloudflareOAuth.accepts(entry.clientID, for: entry.issuer, productionClientID: productionClientID),
			let session = await session(), session.issuer == entry.issuer
		else { return nil }
		return session
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
			let wake = await cleanupPass()
			guard !cleanupWanted else { continue }
			guard let wake else { return }
			let nap = Task { [sleep, delay = max(.zero, wake - uptime())] in try await sleep(delay) }
			cleanupNap = nap
			let slept = await nap.result
			cleanupNap = nil
			// A wait cut short by `resumeCleanup` looks again at once; one that failed by itself ends the cleanup.
			if case .failure = slept, !nap.isCancelled { return }
		}
	}

	/// Tries each cleanup entry that's due, telling the Platforms page once
	/// if any changed; when the next waiting one is due.
	private func cleanupPass() async -> ContinuousClock.Instant? {
		let generations: [String]
		switch await store.cleanupGenerations() {
		case .success(let listed):
			generations = listed
			listingDelay = nil
		case .failure:
			let delay = listingDelay ?? Self.firstCleanupDelay
			listingDelay = min(delay * 2, Self.longestCleanupDelay)
			return uptime() + delay
		}
		var wake: ContinuousClock.Instant?
		let wereWaitingForSignIn = waitingForSignIn
		var changed = false
		// Asked for once in a pass, when an entry first needs it.
		var session: PlatformSession??
		for generation in generations where !Task.isCancelled {
			if let due = cleanupDue[generation], due > uptime() {
				wake = min(wake ?? due, due)
				continue
			}
			if let pause = cleanupPause, pause > uptime() {
				wake = min(wake ?? pause, pause)
				break
			}
			// Another try of it is running, as a disconnect's, which resumes cleanup when it can't finish.
			guard cleaning.insert(generation).inserted else { continue }
			let taken = await turn(of: generation, session: &session)
			cleaning.remove(generation)
			changed = changed || taken.changed
			if let next = taken.next { wake = min(wake ?? next, next) }
		}
		waitingForSignIn.formIntersection(generations)
		if changed || waitingForSignIn != wereWaitingForSignIn { cleanupChanged() }
		return wake
	}

	/// One entry's turn in a pass: whether what the Platforms page shows
	/// changed, and when this entry, or every entry, is due next.
	private func turn(of generation: String, session: inout PlatformSession??) async -> (changed: Bool, next: ContinuousClock.Instant?) {
		var entry: PlatformCleanupEntry
		var changed = false
		switch await store.cleanupEntry(of: generation) {
		case .success(.readable(let stored)?):
			entry = stored
		case .success(.unreadable(_, isNewer: false)?):
			// Rebuilt from its generation's record, it's revoked now; without one, a marker takes its place.
			guard case .success(let rebuilt) = await store.recoverCleanup(of: generation, at: now()) else {
				return (false, postpone(generation, after: .wait(nil)))
			}
			guard let rebuilt else { return (true, nil) }
			entry = rebuilt
			changed = true
		case .success(.unreadable(_, isNewer: true)?), .success(nil):
			// A newer LPM Vault's entry is left for it, and one gone since the listing is done.
			return (false, nil)
		case .failure:
			return (false, postpone(generation, after: .wait(nil)))
		}
		guard CloudflareOAuth.accepts(entry.clientID, for: entry.issuer, productionClientID: productionClientID) else {
			return (changed, postpone(generation, after: .waitForSession))
		}
		if session == nil { session = .some(await self.session()) }
		guard case let current?? = session, current.issuer == entry.issuer else {
			return (changed, postpone(generation, after: .waitForSession))
		}
		var step = await clean(entry, session: current)
		while case .again(let next) = step, !Task.isCancelled {
			entry = next
			step = await clean(entry, session: current)
		}
		switch step {
		case .done: changed = true
		// lpm.dev didn't take the session: the rest of the pass waits for a sign-in too.
		case .waitForSession: session = .some(nil)
		case .again, .wait, .pause: break
		}
		return (changed, postpone(generation, after: step))
	}

	/// Schedules the next try of `generation`'s cleanup after `step`; when
	/// it, or every cleanup when lpm.dev paused them all, is due. Nil when
	/// its cleanup ended.
	@discardableResult
	private func postpone(_ generation: String, after step: CleanupStep) -> ContinuousClock.Instant? {
		if case .waitForSession = step {
			waitingForSignIn.insert(generation)
		} else {
			waitingForSignIn.remove(generation)
		}
		let delay: Duration
		switch step {
		case .done, .again:
			cleanupDue[generation] = nil
			cleanupDelays[generation] = nil
			return nil
		case .wait(let asked):
			let backoff = cleanupDelays[generation] ?? Self.firstCleanupDelay
			cleanupDelays[generation] = min(backoff * 2, Self.longestCleanupDelay)
			delay = max(asked ?? .zero, backoff)
		case .waitForSession:
			delay = Self.sessionCleanupDelay
		case .pause(let asked):
			let backoff = pauseDelay ?? Self.firstCleanupDelay
			pauseDelay = min(backoff * 2, Self.longestCleanupDelay)
			let until = uptime() + max(asked ?? .zero, backoff)
			cleanupPause = until
			return until
		}
		let due = uptime() + delay
		cleanupDue[generation] = due
		return due
	}

	/// One request revoking what `entry` holds, and what its answer does to
	/// the entry. An entry that isn't `stored`, as a new grant being
	/// discarded, only leaves a note when its revocation isn't confirmed.
	private func clean(_ entry: PlatformCleanupEntry, session: PlatformSession, stored: Bool = true) async -> CleanupStep {
		let key = entry.attempt?.privateKey
		let attempt = entry.attempt.flatMap { attempt in key.map { (id: attempt.id, publicKey: $0.publicKey.x963Representation) } }
		let outcome: PlatformTokenRevocationOutcome
		await takeRevocationTurn()
		let answer = await revoker.revoke(
			entry.platform, token: entry.refreshToken, revocationID: entry.revocationID, attempt: attempt, session: session)
		endRevocationTurn()
		switch answer {
		case .success(.throttled(let seconds)):
			return .pause(.seconds(seconds))
		case .success(let answer):
			outcome = answer
		case .failure(.signedOut), .failure(.forbidden):
			return .waitForSession
		case .failure(.rateLimited):
			return .pause(.seconds(60))
		case .failure(.transport), .failure(.unavailable), .failure(.server):
			return .pause(nil)
		case .failure:
			return .wait(nil)
		}
		// lpm.dev answered about this entry, so it takes revocations again.
		cleanupPause = nil
		pauseDelay = nil
		switch outcome {
		case .accepted:
			guard stored else { return .done(.revoked) }
			return finished(await store.finishCleanup(entry, unconfirmed: false, at: now()), as: .revoked)
		case .unconfirmed:
			guard stored else {
				await note(PlatformCleanupMarker(platform: entry.platform, generation: entry.generation, createdAt: now()))
				return .done(.unconfirmed)
			}
			return finished(await store.finishCleanup(entry, unconfirmed: true, at: now()), as: .unconfirmed)
		case .superseded(let sealed, _):
			guard stored, let pending = entry.attempt, let key,
				case .success(let tokens) = PlatformAuthorizationEnvelope.open(
					sealed, id: pending.id, clientKey: key, domain: PlatformAuthorizationEnvelope.refreshDomain,
					read: { $0["platform"] as? String == entry.platform.rawValue ? PlatformTokens(payload: $0) : nil }),
				let successor = tokens.expiry?.refreshToken
			else { return .wait(nil) }
			guard case .success(true) = await store.replaceCleanupToken(of: entry.generation, renewedBy: pending.id, with: successor) else {
				return .wait(nil)
			}
			var next = entry
			next.refreshToken = successor
			next.attempt = nil
			return .again(next)
		case .busy, .throttled:
			return .wait(nil)
		case .retry(let seconds):
			return .wait(.seconds(seconds))
		}
	}

	/// Waits until this Mac may send a revocation.
	private func takeRevocationTurn() async {
		guard revocationInFlight else {
			revocationInFlight = true
			return
		}
		await withCheckedContinuation { revocationTurns.append($0) }
	}

	/// Hands the turn to the next revocation waiting, or frees it.
	private func endRevocationTurn() {
		if revocationTurns.isEmpty {
			revocationInFlight = false
		} else {
			revocationTurns.removeFirst().resume()
		}
	}

	/// What ending a cleanup in the store leaves: done, or the same answer asked for again later.
	private func finished(_ result: Result<Void, PlatformConnectionStoreError>, as outcome: PlatformRevocation) -> CleanupStep {
		guard case .success = result else { return .wait(nil) }
		return .done(outcome)
	}
}
