import CryptoKit
import Foundation
import Testing
@testable import LPMVault

/// A Cloudflare connection's renewals, retirement and cleanup through `PlatformCredentials`.
struct CloudflareCredentialsTests {
	private let keychain = MockKeychainService()
	private let registry = URL(string: "http://localhost:3000")!
	private var store: PlatformConnectionStore { PlatformConnectionStore(service: keychain) }

	private func credentials(
		refresher: ScriptedTokenRefresher = ScriptedTokenRefresher { _, _ in .failure(.transport) },
		revoker: any PlatformTokenRevoking = ScriptedRevoker(),
		at clock: TestDate = TestDate(CloudflareLoginFixture.start),
		session: PlatformSession?? = nil,
		sessions: (@Sendable () -> PlatformSession?)? = nil,
		waits: RecordedWaits = RecordedWaits(),
		sleep: (@Sendable (Duration) async throws -> Void)? = nil,
		productionClientID: String? = "lpm-vault-production",
		changed: @escaping @Sendable () -> Void = {}
	) -> PlatformCredentials {
		let chosen = session ?? .some(platformTestSession(registry))
		// Cleanups wait on a clock that only the test moves, so the waits they ask for are exact.
		let uptime = ManualClock()
		return PlatformCredentials(
			store: store, refresher: refresher, revoker: revoker, session: { sessions.map { $0() } ?? chosen }, now: { clock.date }, pendingDelay: .zero,
			uptime: { uptime.now }, sleep: sleep ?? waits.sleep, productionClientID: productionClientID, cleanupChanged: changed)
	}

	/// Retires a newly connected login's generation, as disconnecting does, leaving its entry.
	@discardableResult
	private func retired(_ account: CloudflareConnectionAccount = CloudflareLoginFixture.account()) async throws -> PlatformCleanupEntry {
		let connection = try await CloudflareLoginFixture.save(account, in: store)
		return try #require(try await store.retire(connection.id, generation: account.generation, at: CloudflareLoginFixture.start).get().entry)
	}

	/// A login whose access token is due when the clock reads `CloudflareLoginFixture.start` plus an hour.
	private func connect(attempt: PlatformTokenRefresh.Attempt? = nil, eligibility: TimeInterval = 365 * 86_400) async throws
		-> (id: PlatformConnection.ID, account: CloudflareConnectionAccount)
	{
		let account = CloudflareLoginFixture.account()
		let connection = try await CloudflareLoginFixture.save(
			account, in: store, refresh: CloudflareLoginFixture.refresh(eligibility: eligibility, attempt: attempt))
		return (connection.id, account)
	}

	private var due: TestDate { TestDate(CloudflareLoginFixture.start.addingTimeInterval(3_600 - 60)) }

	@Test("a Cloudflare connection renews through the Registry that issued it, keeping the tokens Cloudflare rotated")
	func renews() async throws {
		let (id, _) = try await connect()
		let refresher = ScriptedTokenRefresher { call, _ in
			ScriptedTokenRefresher.renewed(call, access: "cf_access_2", refresh: "cf_refresh_2", accessLifetime: 3_600, refreshLifetime: 31_536_000, platform: "cloudflare")
		}
		#expect(await credentials(refresher: refresher, at: due).accessToken(for: id) == .success("cf_access_2"))
		#expect(refresher.calls.map(\.platform) == [.cloudflare] && refresher.calls.map(\.refreshToken) == ["cf_refresh_1"])
	}

	@Test("a connection made through the other LPM environment's Registry is never sent to this one")
	func otherRegistry() async throws {
		let (id, _) = try await connect()
		let refresher = ScriptedTokenRefresher { _, _ in
			Issue.record("Sent to another Registry")
			return .failure(.transport)
		}
		let live = platformTestSession(registry, issuer: .production)
		#expect(await credentials(refresher: refresher, at: due, session: .some(live)).accessToken(for: id) == .failure(.otherRegistry))
	}

	@Test("tokens of a client this Registry doesn't run, as after the production client changed, are never sent")
	func otherClient() async throws {
		let account = CloudflareLoginFixture.account(issuer: .production, clientID: "lpm-vault-old-production")
		let connection = try await CloudflareLoginFixture.save(account, in: store)
		let refresher = ScriptedTokenRefresher { _, _ in
			Issue.record("Sent with another client's token")
			return .failure(.transport)
		}
		let live = platformTestSession(registry, issuer: .production)
		#expect(await credentials(refresher: refresher, at: due, session: .some(live)).accessToken(for: connection.id) == .failure(.expired))
	}

	@Test("a connection Cloudflare no longer accepts says removing LPM Vault there is one way that happens")
	func reconnectCopy() {
		#expect(PlatformCredentialError.expired.message(for: .cloudflare).contains("removed under Connected Applications on Cloudflare"))
		#expect(CloudflarePublishing.message(.unauthorized).contains("removed under Connected Applications on Cloudflare"))
	}

	@Test("other platforms' connections carry no issuer and renew through whichever Registry the app is signed in to, as before")
	func otherPlatformsIgnoreIssuer() async throws {
		let refresh = PlatformTokenRefresh(
			token: "nfo_refresh", accessTokenExpiresAt: CloudflareLoginFixture.start.addingTimeInterval(60),
			expiresAt: CloudflareLoginFixture.start.addingTimeInterval(86_400), obtainedAt: CloudflareLoginFixture.start, principalID: platformTestPrincipal)
		let id = try await store.save(
			.netlify(NetlifyConnectionAccount(userID: "u_1", name: "Tolga", email: nil)), accessToken: "nfo_access", refresh: refresh,
			at: CloudflareLoginFixture.start).get().id
		let refresher = ScriptedTokenRefresher { call, _ in ScriptedTokenRefresher.renewed(call) }
		for issuer in PlatformIssuer.allCases {
			let credentials = credentials(refresher: refresher, at: TestDate(CloudflareLoginFixture.start.addingTimeInterval(30)), session: .some(platformTestSession(registry, issuer: issuer)))
			#expect(await credentials.accessToken(for: id) != .failure(.otherRegistry))
		}
		#expect(refresher.calls.count == 1)
	}

	@Test("a refusal that ended the family drops the renewal's key; any other leaves it for the connection's cleanup")
	func keepsKeyUnlessFamilyEnded() async throws {
		for (code, keeps) in [("refresh_rejected", false), ("refresh_not_kept", true), ("refresh_uncertain", true), ("refresh_abandoned", true)] {
			let (id, account) = try await connect()
			let refresher = ScriptedTokenRefresher { _, _ in .success(.failed(code: code)) }
			#expect(await credentials(refresher: refresher, at: due).accessToken(for: id) == .failure(.expired))
			let refresh = try #require(try await store.record(for: id).get().refresh)
			#expect(refresh.isRejected)
			#expect((refresh.attempt != nil) == keeps, "\(code)")
			#expect(try await store.listing(at: due.date).get().expired == [id])
			_ = account
		}
	}

	@Test("a token the Registry doesn't know is kept with its renewal's key once it's past the grace for one just received")
	func unknownKeepsKey() async throws {
		let (id, _) = try await connect()
		let refresher = ScriptedTokenRefresher { _, _ in .success(.unknown) }
		#expect(await credentials(refresher: refresher, at: due).accessToken(for: id) == .failure(.expired))
		#expect(try await store.record(for: id).get().refresh?.attempt != nil)
	}

	@Test("when LPM's eligibility for the token ends, at the Registry or on this Mac, it's revoked, and the login stays to be connected again")
	func eligibilityEnds() async throws {
		let (id, account) = try await connect()
		let revoker = ScriptedRevoker()
		let registryEnded = credentials(refresher: ScriptedTokenRefresher { _, _ in .success(.expired) }, revoker: revoker, at: due)
		#expect(await registryEnded.accessToken(for: id) == .failure(.expired))
		await registryEnded.cleanupSettled()
		#expect(revoker.calls.map(\.token) == ["cf_refresh_1"] && revoker.calls.first?.attempt != nil)
		#expect(try await store.listing(at: due.date).get().expired == [id] && keychain.platformCleanupStorage.isEmpty)
		_ = account

		let (ended, _) = try await connect(eligibility: 600)
		let refresher = ScriptedTokenRefresher { _, _ in
			Issue.record("Sent past its eligibility")
			return .failure(.transport)
		}
		let locally = credentials(refresher: refresher, revoker: revoker, at: due)
		#expect(await locally.accessToken(for: ended) == .failure(.expired))
		await locally.cleanupSettled()
		#expect(revoker.calls.count == 2 && keychain.platformCleanupStorage.isEmpty)
		#expect(try await store.listing(at: due.date).get().expired == [ended])
	}

	@Test("a token asked for by its generation isn't given once the login was connected again")
	func generationFreeze() async throws {
		let (id, account) = try await connect()
		let credentials = credentials()
		#expect(await credentials.accessToken(for: id, generation: account.generation) == .success("cf_access_1"))
		try await CloudflareLoginFixture.save(CloudflareLoginFixture.account(), in: store, access: "cf_access_new")
		#expect(await credentials.accessToken(for: id, generation: account.generation) == .failure(.replaced))
	}

	@Test("retiring waits for a renewal in flight, so the entry holds the tokens it left, and the token isn't read after", .timeLimit(.minutes(1)))
	func retireWaitsForRenewal() async throws {
		let (id, account) = try await connect()
		let gate = TestGate()
		let sent = TestGate()
		let refresher = ScriptedTokenRefresher { call, _ in
			await sent.open()
			await gate.wait()
			return ScriptedTokenRefresher.renewed(call, access: "cf_access_2", refresh: "cf_refresh_2", accessLifetime: 3_600, refreshLifetime: 31_536_000, platform: "cloudflare")
		}
		let revoker = ScriptedRevoker { _, _ in .success(.retry(after: 30)) }
		let credentials = credentials(refresher: refresher, revoker: revoker, at: due)
		async let renewal = credentials.accessToken(for: id)
		await sent.wait()
		async let retirement = credentials.retire(id, generation: account.generation)
		try await letStartedWorkGetAhead()
		await gate.open()
		#expect(await renewal == .success("cf_access_2"))
		let entry = try #require(try await retirement.get().entry)
		#expect(entry.refreshToken == "cf_refresh_2" && entry.attempt == nil)
		#expect(await credentials.accessToken(for: id) == .failure(.retired))
	}

	@Test("an accepted revocation deletes the retired record, then its entry")
	func accepted() async throws {
		let (id, account) = try await connect()
		let revoker = ScriptedRevoker()
		let credentials = credentials(revoker: revoker)
		let entry = try #require(try await credentials.retire(id, generation: account.generation).get().entry)
		#expect(await credentials.revokeNow(entry) == .revoked)
		#expect(revoker.calls.map(\.revocationID) == [entry.revocationID] && revoker.calls.first?.issuer == .development)
		#expect(keychain.platformConnectionStorage.isEmpty && keychain.platformCleanupStorage.isEmpty)
	}

	@Test("an unconfirmed revocation deletes the record and leaves a marker in the entry's place")
	func unconfirmed() async throws {
		let (id, account) = try await connect()
		let credentials = credentials(revoker: ScriptedRevoker { _, _ in .success(.unconfirmed) })
		let entry = try #require(try await credentials.retire(id, generation: account.generation).get().entry)
		#expect(await credentials.revokeNow(entry) == .unconfirmed)
		#expect(keychain.platformConnectionStorage.isEmpty)
		#expect(Array(keychain.platformCleanupStorage.keys) == [PlatformCleanupRecords.markerAccount(account.generation)])
	}

	@Test("a superseded token's successor, collected with the renewal's key, replaces it in the entry before it's revoked in turn")
	func superseded() async throws {
		let attempt = PlatformTokenRefresh.Attempt.make(at: CloudflareLoginFixture.start)
		let (id, account) = try await connect(attempt: attempt)
		let revoker = ScriptedRevoker { call, index in
			guard index == 0, let pending = call.attempt else { return .success(.accepted) }
			return .success(.superseded(CloudflareLoginFixture.successor(for: pending), age: 3))
		}
		let credentials = credentials(revoker: revoker)
		let entry = try #require(try await credentials.retire(id, generation: account.generation).get().entry)
		#expect(await credentials.revokeNow(entry) == .revoked)
		#expect(revoker.calls.map(\.token) == ["cf_refresh_1", "cf_refresh_2"])
		#expect(revoker.calls[0].attempt?.id == attempt.id && revoker.calls[1].attempt == nil)
		#expect(Set(revoker.calls.map(\.revocationID)) == [entry.revocationID])
		#expect(keychain.platformConnectionStorage.isEmpty && keychain.platformCleanupStorage.isEmpty)
	}

	@Test("a revocation to try again waits at least as long as the Registry asks, and longer each time, with no budget")
	func retriesWithBackoff() async throws {
		let (id, account) = try await connect()
		let waits = RecordedWaits()
		let revoker = ScriptedRevoker { _, index in index < 3 ? .success(.retry(after: index == 0 ? 30 : 1)) : .success(.accepted) }
		let credentials = credentials(revoker: revoker, waits: waits)
		_ = try await credentials.retire(id, generation: account.generation).get()
		await credentials.resumeCleanup()
		await credentials.cleanupSettled()
		#expect(waits.values == [.seconds(30)])
		await credentials.resumeCleanup(now: true)
		await credentials.cleanupSettled()
		await credentials.resumeCleanup(now: true)
		await credentials.cleanupSettled()
		#expect(waits.values == [.seconds(30), .seconds(10), .seconds(20)])
		await credentials.resumeCleanup(now: true)
		await credentials.cleanupSettled()
		#expect(revoker.calls.count == 4 && keychain.platformCleanupStorage.isEmpty)
	}

	@Test("a cleanup waits, sending nothing, without a session, through another Registry, or for another client")
	func waitsForItsRegistry() async throws {
		let (id, account) = try await connect()
		let revoker = ScriptedRevoker { _, _ in
			Issue.record("Sent without its own Registry and client")
			return .success(.accepted)
		}
		for (session, clientID) in [
			(PlatformSession?.none, "lpm-vault-production"),
			(platformTestSession(registry, issuer: .production), "lpm-vault-production"),
		] {
			let waits = RecordedWaits()
			let credentials = credentials(revoker: revoker, session: .some(session), waits: waits, productionClientID: clientID)
			_ = try await credentials.retire(id, generation: account.generation).get()
			await credentials.resumeCleanup()
			await credentials.cleanupSettled()
			#expect(waits.values == [PlatformCredentials.sessionCleanupDelay])
		}
		#expect(keychain.platformCleanupStorage.count == 1)

		// A production client lpm.dev doesn't run any more, as after it changed, is never sent, cleaning up or discarding.
		keychain.platformCleanupStorage = [:]
		try await retired(CloudflareLoginFixture.account(issuer: .production, clientID: "lpm-vault-old-production"))
		let live = platformTestSession(registry, issuer: .production)
		let waits = RecordedWaits()
		let otherClient = credentials(revoker: revoker, session: .some(live), waits: waits)
		await otherClient.resumeCleanup()
		await otherClient.cleanupSettled()
		#expect(waits.values == [PlatformCredentials.sessionCleanupDelay])
		#expect(await otherClient.discard(
			refreshToken: "cf_new", connectionID: "cloudflare.unknown", generation: CloudflareConnectionAccount.makeGeneration(),
			issuer: .production, clientID: "lpm-vault-old-production") == .waitingForSignIn)
	}

	@Test("an entry that can't be read is written again from its generation's record when that's still stored, and revoked")
	func rebuildsUnreadableEntry() async throws {
		let (id, account) = try await connect()
		let revoker = ScriptedRevoker()
		let credentials = credentials(revoker: revoker)
		_ = try await credentials.retire(id, generation: account.generation).get()
		keychain.platformCleanupStorage[PlatformCleanupRecords.entryAccount(account.generation)] = Data("{".utf8)
		await credentials.resumeCleanup()
		await credentials.cleanupSettled()
		#expect(revoker.calls.map(\.token) == ["cf_refresh_1"])
		#expect(keychain.platformConnectionStorage.isEmpty && keychain.platformCleanupStorage.isEmpty)
	}

	@Test("an entry that can't be read becomes a marker, and a newer version's is left for it")
	func unreadableEntries() async throws {
		let generation = CloudflareConnectionAccount.makeGeneration()
		let newer = CloudflareConnectionAccount.makeGeneration()
		keychain.platformCleanupStorage[PlatformCleanupRecords.entryAccount(generation)] = Data("{".utf8)
		keychain.platformCleanupStorage[PlatformCleanupRecords.entryAccount(newer)] = Data(#"{"version":9,"kind":"entry"}"#.utf8)
		let credentials = credentials()
		await credentials.resumeCleanup()
		await credentials.cleanupSettled()
		#expect(Set(keychain.platformCleanupStorage.keys) == [
			PlatformCleanupRecords.markerAccount(generation), PlatformCleanupRecords.entryAccount(newer),
		])
	}

	@Test("a new grant LPM Vault won't keep is revoked at once; one that isn't confirmed gets an entry that goes on trying")
	func discards() async throws {
		let generation = CloudflareConnectionAccount.makeGeneration()
		let confirmed = credentials()
		#expect(await confirmed.discard(
			refreshToken: "cf_new", connectionID: "cloudflare.unknown", generation: generation, issuer: .development,
			clientID: CloudflareLoginFixture.clientID) == .revoked)
		#expect(keychain.platformCleanupStorage.isEmpty)

		let waits = RecordedWaits()
		let unreachable = credentials(revoker: ScriptedRevoker { _, _ in .failure(.transport) }, waits: waits)
		#expect(await unreachable.discard(
			refreshToken: "cf_new", connectionID: "cloudflare.unknown", generation: generation, issuer: .development,
			clientID: CloudflareLoginFixture.clientID) == .pending)
		await unreachable.cleanupSettled()
		#expect(Array(keychain.platformCleanupStorage.keys) == [PlatformCleanupRecords.entryAccount(generation)])

		keychain.platformCleanupStorage = [:]
		let signedOut = credentials(session: .some(nil))
		#expect(await signedOut.discard(
			refreshToken: "cf_new", connectionID: "cloudflare.unknown", generation: generation, issuer: .development,
			clientID: CloudflareLoginFixture.clientID) == .waitingForSignIn)
		#expect(await signedOut.waitingForSignIn == [generation])
	}

	@Test("a cleanup waiting for a sign-in looks again as soon as one arrives", .timeLimit(.minutes(5)))
	func wakesForSignIn() async throws {
		try await retired()
		let signedIn = TestValue<PlatformSession?>(nil)
		let revoker = ScriptedRevoker()
		let waits = HeldWaits()
		let credentials = credentials(revoker: revoker, sessions: { signedIn.value }, sleep: waits.sleep)
		await credentials.resumeCleanup()
		#expect(try await waitUntil { waits.values == [PlatformCredentials.sessionCleanupDelay] })
		signedIn.value = platformTestSession(registry)
		await credentials.resumeCleanup(now: true)
		try #require(try await waitUntil { revoker.calls.count == 1 }, "The sleeping cleanup woke")
		await credentials.cleanupSettled()
		#expect(keychain.platformCleanupStorage.isEmpty)
	}

	@Test("a cleanup the Keychain fails, listing entries or mending one, is tried again after a backoff")
	func keychainFailuresRetry() async throws {
		let entry = try await retired()
		keychain.failPlatformCleanupAccounts = ["*"]
		let listing = RecordedWaits()
		let unlisted = credentials(waits: listing)
		await unlisted.resumeCleanup()
		await unlisted.cleanupSettled()
		#expect(listing.values == [PlatformCredentials.firstCleanupDelay])

		keychain.failPlatformCleanupAccounts = []
		keychain.platformCleanupStorage[PlatformCleanupRecords.entryAccount(entry.generation)] = Data("{".utf8)
		keychain.failPlatformConnectionAccounts = ["*"]
		let mending = RecordedWaits()
		let unmended = credentials(waits: mending)
		await unmended.resumeCleanup()
		await unmended.cleanupSettled()
		#expect(mending.values == [PlatformCredentials.firstCleanupDelay])
	}

	@Test("a revocation the Registry asks to try later, during a disconnect or a discard, isn't sent again before then")
	func keepsRetryAfter() async throws {
		let entry = try await retired()
		let revoker = ScriptedRevoker { _, index in index == 0 ? .success(.retry(after: 30)) : .success(.accepted) }
		let waits = RecordedWaits()
		let credentials = credentials(revoker: revoker, waits: waits)
		_ = await credentials.revokeNow(entry)
		await credentials.cleanupSettled()
		#expect(revoker.calls.count == 1 && waits.values == [.seconds(30)])

		keychain.platformCleanupStorage = [:]
		let discarding = ScriptedRevoker { _, index in index == 0 ? .success(.retry(after: 30)) : .success(.accepted) }
		let discardWaits = RecordedWaits()
		let discarder = self.credentials(revoker: discarding, waits: discardWaits)
		_ = await discarder.discard(
			refreshToken: "cf_new", connectionID: "cloudflare.unknown", generation: CloudflareConnectionAccount.makeGeneration(),
			issuer: .development, clientID: CloudflareLoginFixture.clientID)
		await discarder.cleanupSettled()
		#expect(discarding.calls.count == 1 && discardWaits.values == [.seconds(30)])
	}

	@Test("the Registry's limit on one person's revocations holds back every cleanup until it lifts, not only the one refused")
	func perPersonLimitPausesAll() async throws {
		try await retired()
		try await retired()
		let route = PlatformHTTPStub.registry { _ in .json(429, ["code": "rate_limited"], headers: ["Retry-After": "12"]) }
		let waits = RecordedWaits()
		let credentials = credentials(
			revoker: PlatformAuthorizationClient(session: route.session), sessions: { platformTestSession(route.baseURL) }, waits: waits)
		await credentials.resumeCleanup()
		await credentials.cleanupSettled()
		#expect(route.requests.count == 1)
		#expect(waits.values == [.seconds(12)])
	}

	@Test("callers asking for one generation's token while it's read share that read", .timeLimit(.minutes(5)))
	func sharesGenerationBoundReads() async throws {
		let (id, account) = try await connect()
		let credentials = credentials()
		let reads = keychain.appItemReadCount(.platformConnections)
		let entered = DispatchSemaphore(value: 0)
		let held = DispatchSemaphore(value: 0)
		let once = TestValue(false)
		keychain.beforeAppItemRead = { store, read in
			guard store == .platformConnections, read == id else { return }
			var first = false
			once.update { held in
				first = !held
				held = true
			}
			guard first else { return }
			entered.signal()
			_ = held.wait(timeout: .now() + testWaitSeconds)
		}
		async let first = credentials.accessToken(for: id, generation: account.generation)
		await withCheckedContinuation { continuation in
			Thread.detachNewThread {
				_ = entered.wait(timeout: .now() + testWaitSeconds)
				continuation.resume()
			}
		}
		async let second = credentials.accessToken(for: id, generation: account.generation)
		#expect(try await waitUntil { await credentials.sharedReads == 1 })
		held.signal()
		#expect(await first == .success("cf_access_1"))
		#expect(await second == .success("cf_access_1"))
		#expect(keychain.appItemReadCount(.platformConnections) - reads == 1)
		keychain.beforeAppItemRead = nil
	}

	@Test("a cleanup pass that finishes several entries tells the page once")
	func notifiesOncePerPass() async throws {
		for _ in 0..<3 { try await retired() }
		let changes = TestValue(0)
		let credentials = credentials(changed: { changes.update { $0 += 1 } })
		await credentials.resumeCleanup()
		await credentials.cleanupSettled()
		#expect(keychain.platformCleanupStorage.isEmpty)
		#expect(changes.value == 1)
	}

	@Test("listing connections reads no cleanup item, and a pass reads only the entries due, never the markers")
	func readsOnlyWhatItNeeds() async throws {
		try await retired()
		for _ in 0..<3 {
			_ = await store.mark(PlatformCleanupMarker(
				platform: .cloudflare, generation: CloudflareConnectionAccount.makeGeneration(), createdAt: CloudflareLoginFixture.start))
		}
		let before = keychain.appItemReadCount(.platformCleanup)
		_ = try await store.connections().get()
		#expect(keychain.appItemReadCount(.platformCleanup) == before)

		let credentials = credentials(revoker: ScriptedRevoker { _, _ in .success(.retry(after: 30)) })
		await credentials.resumeCleanup()
		await credentials.cleanupSettled()
		let afterFirst = keychain.appItemReadCount(.platformCleanup)
		#expect(afterFirst - before == 1)
		await credentials.resumeCleanup()
		await credentials.cleanupSettled()
		#expect(keychain.appItemReadCount(.platformCleanup) == afterFirst)
	}

	@Test("a pass asks for the LPM session once, and not at all for entries of a client this Registry doesn't run")
	func resolvesSessionOnce() async throws {
		try await retired(CloudflareLoginFixture.account(issuer: .production, clientID: "lpm-vault-old-production"))
		let ineligible = TestValue(0)
		let unasked = credentials(sessions: {
			ineligible.update { $0 += 1 }
			return platformTestSession(self.registry, issuer: .production)
		})
		await unasked.resumeCleanup()
		await unasked.cleanupSettled()
		#expect(ineligible.value == 0)

		keychain.platformCleanupStorage = [:]
		keychain.platformConnectionStorage = [:]
		try await retired()
		try await retired(CloudflareLoginFixture.account(subject: CloudflareLoginFixture.otherSubject))
		let asked = TestValue(0)
		let credentials = credentials(revoker: ScriptedRevoker { _, _ in .success(.retry(after: 30)) }, sessions: {
			asked.update { $0 += 1 }
			return platformTestSession(self.registry)
		})
		await credentials.resumeCleanup()
		await credentials.cleanupSettled()
		#expect(asked.value == 1)
	}

	@Test("a discarded grant whose revocation isn't confirmed, and whose entry can't be saved, still leaves a note")
	func discardLeavesNote() async throws {
		let generation = CloudflareConnectionAccount.makeGeneration()
		keychain.failAppItemWrites = [PlatformCleanupRecords.entryAccount(generation)]
		let credentials = credentials(revoker: ScriptedRevoker { _, _ in .failure(.transport) })
		#expect(await credentials.discard(
			refreshToken: "cf_new", connectionID: "cloudflare.unknown", generation: generation, issuer: .development,
			clientID: CloudflareLoginFixture.clientID) == .unconfirmed)
		#expect(Array(keychain.platformCleanupStorage.keys) == [PlatformCleanupRecords.markerAccount(generation)])
	}

	@Test("this Mac sends one revocation at a time, as lpm.dev takes one of a person's at a time, so a disconnect waits its turn rather than being refused", .timeLimit(.minutes(5)))
	func revocationsTakeTurns() async throws {
		let waiting = try await retired()
		let gate = TestGate()
		let inFlight = TestValue(0)
		let revoker = ScriptedRevoker { call, _ in
			var admitted = false
			inFlight.update { count in
				admitted = count == 0
				if admitted { count += 1 }
			}
			guard admitted else { return .success(.throttled(after: 30)) }
			if call.revocationID == waiting.revocationID { await gate.wait() }
			inFlight.update { $0 -= 1 }
			return .success(.accepted)
		}
		let credentials = credentials(revoker: revoker)
		// The background cleanup holds the one revocation lpm.dev takes at a time.
		await credentials.resumeCleanup()
		#expect(try await waitUntil { revoker.calls.count == 1 })
		let disconnected = try await retired(CloudflareLoginFixture.account(subject: CloudflareLoginFixture.otherSubject))
		async let revocation = credentials.revokeNow(disconnected)
		try await letStartedWorkGetAhead()
		await gate.open()
		#expect(await revocation == .revoked)
		await credentials.cleanupSettled()
		#expect(keychain.platformCleanupStorage.isEmpty)
	}

	@Test("a login whose eligibility ended is revoked, then stays listed under its label as one to reconnect")
	func endedLoginAsksToReconnect() async throws {
		let (id, account) = try await connect()
		let revoker = ScriptedRevoker()
		let credentials = credentials(refresher: ScriptedTokenRefresher { _, _ in .success(.expired) }, revoker: revoker, at: due)
		#expect(await credentials.accessToken(for: id) == .failure(.expired))
		await credentials.cleanupSettled()
		#expect(revoker.calls.map(\.token) == ["cf_refresh_1"])
		let listing = try await store.listing(at: due.date).get()
		#expect(listing.connections.map(\.id) == [id] && listing.expired == [id])
		#expect(listing.connections.first?.name == account.label && listing.retiring.isEmpty && listing.markers.isEmpty)
		#expect(await credentials.accessToken(for: id) == .failure(.expired))
	}

	@Test("a login whose tokens the platform already ended has nothing to revoke: disconnecting or replacing it only removes it")
	func endedFamilyNeedsNoRevocation() async throws {
		let (id, account) = try await connect()
		let revoker = ScriptedRevoker()
		let credentials = credentials(
			refresher: ScriptedTokenRefresher { _, _ in .success(.failed(code: PlatformCredentials.familyEndedCode)) }, revoker: revoker, at: due)
		#expect(await credentials.accessToken(for: id) == .failure(.expired))
		#expect(try await credentials.retire(id, generation: account.generation).get() == .ended)
		#expect(revoker.calls.isEmpty && keychain.platformConnectionStorage.isEmpty && keychain.platformCleanupStorage.isEmpty)
	}

	@Test("stopping the cleanup, as locking does, ends one that's waiting, and keeps its entry for when it resumes", .timeLimit(.minutes(5)))
	func stopsCleanup() async throws {
		try await retired()
		let waits = HeldWaits()
		let credentials = credentials(session: .some(nil), sleep: waits.sleep)
		await credentials.resumeCleanup()
		#expect(try await waitUntil { waits.values == [PlatformCredentials.sessionCleanupDelay] })
		await credentials.stopCleanup()
		await credentials.cleanupSettled()
		#expect(keychain.platformCleanupStorage.count == 1)
	}
}

