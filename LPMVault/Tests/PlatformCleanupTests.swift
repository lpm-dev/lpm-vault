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
		revoker: ScriptedRevoker = ScriptedRevoker(),
		at clock: TestDate = TestDate(CloudflareLoginFixture.start),
		session: PlatformSession?? = nil,
		waits: RecordedWaits = RecordedWaits(),
		productionClientID: String? = "lpm-vault-production"
	) -> PlatformCredentials {
		let chosen = session ?? .some(platformTestSession(registry))
		// Cleanups wait on a clock that only the test moves, so the waits they ask for are exact.
		let uptime = ManualClock()
		return PlatformCredentials(
			store: store, refresher: refresher, revoker: revoker, session: { chosen }, now: { clock.date }, pendingDelay: .zero,
			uptime: { uptime.now }, sleep: waits.sleep, productionClientID: productionClientID)
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

	@Test("when LPM's eligibility for the token ends, at the Registry or on this Mac, it's retired and revoked before connecting again")
	func eligibilityEnds() async throws {
		let (id, account) = try await connect()
		let revoker = ScriptedRevoker()
		let registryEnded = credentials(refresher: ScriptedTokenRefresher { _, _ in .success(.expired) }, revoker: revoker, at: due)
		#expect(await registryEnded.accessToken(for: id) == .failure(.expired))
		await registryEnded.cleanupSettled()
		#expect(revoker.calls.map(\.token) == ["cf_refresh_1"] && revoker.calls.first?.attempt != nil)
		#expect(keychain.platformConnectionStorage.isEmpty && keychain.platformCleanupStorage.isEmpty)
		_ = account

		let (ended, _) = try await connect(eligibility: 600)
		let refresher = ScriptedTokenRefresher { _, _ in
			Issue.record("Sent past its eligibility")
			return .failure(.transport)
		}
		let locally = credentials(refresher: refresher, revoker: revoker, at: due)
		#expect(await locally.accessToken(for: ended) == .failure(.expired))
		await locally.cleanupSettled()
		#expect(revoker.calls.count == 2 && keychain.platformConnectionStorage.isEmpty)
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
		let entry = try #require(try await retirement.get())
		#expect(entry.refreshToken == "cf_refresh_2" && entry.attempt == nil)
		#expect(await credentials.accessToken(for: id) == .failure(.retired))
	}

	@Test("an accepted revocation deletes the retired record, then its entry")
	func accepted() async throws {
		let (id, account) = try await connect()
		let revoker = ScriptedRevoker()
		let credentials = credentials(revoker: revoker)
		let entry = try #require(try await credentials.retire(id, generation: account.generation).get())
		#expect(await credentials.revokeNow(entry))
		#expect(revoker.calls.map(\.revocationID) == [entry.revocationID] && revoker.calls.first?.issuer == .development)
		#expect(keychain.platformConnectionStorage.isEmpty && keychain.platformCleanupStorage.isEmpty)
	}

	@Test("an unconfirmed revocation deletes the record and leaves a marker in the entry's place")
	func unconfirmed() async throws {
		let (id, account) = try await connect()
		let credentials = credentials(revoker: ScriptedRevoker { _, _ in .success(.unconfirmed) })
		let entry = try #require(try await credentials.retire(id, generation: account.generation).get())
		#expect(await credentials.revokeNow(entry))
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
		let entry = try #require(try await credentials.retire(id, generation: account.generation).get())
		#expect(await credentials.revokeNow(entry))
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
		let locked = credentials(session: .some(nil))
		#expect(await locked.discard(
			refreshToken: "cf_new", connectionID: "cloudflare.unknown", generation: generation, issuer: .development,
			clientID: CloudflareLoginFixture.clientID) == .pending)
	}
}
