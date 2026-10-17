import CryptoKit
import Foundation
import Testing
@testable import LPMVault

/// A clock a test moves by hand.
final class TestDate: @unchecked Sendable {
	private let lock = NSLock()
	private var value: Date

	init(_ date: Date) { value = date }

	var date: Date {
		get { lock.withLock { value } }
		set { lock.withLock { value = newValue } }
	}
}

/// A Registry that answers token refreshes as a test scripts it, recording each request.
final class ScriptedTokenRefresher: PlatformTokenRefreshing, @unchecked Sendable {
	struct Call: Sendable {
		let platform: BrowserPlatform
		let refreshToken: String
		let clientPublicKey: Data
		let refreshID: String
		let principalID: String
	}

	typealias Answer = @Sendable (_ call: Call, _ index: Int) async -> Result<PlatformTokenRefreshOutcome, PlatformAuthorizationError>

	private let lock = NSLock()
	private var log: [Call] = []
	private let answer: Answer

	init(_ answer: @escaping Answer) {
		self.answer = answer
	}

	var calls: [Call] { lock.withLock { log } }

	func refresh(
		_ platform: BrowserPlatform,
		refreshToken: String,
		clientPublicKey: Data,
		refreshID: String,
		session: PlatformSession
	) async -> Result<PlatformTokenRefreshOutcome, PlatformAuthorizationError> {
		let call = Call(
			platform: platform, refreshToken: refreshToken, clientPublicKey: clientPublicKey, refreshID: refreshID,
			principalID: session.principalID)
		let index = lock.withLock {
			log.append(call)
			return log.count - 1
		}
		return await answer(call, index)
	}

	/// The answer the Registry gives a refresh that renewed the token.
	static func renewed(
		_ call: Call,
		access: String = "nfo_renewed_access",
		refresh: String = "nfo_renewed_refresh",
		accessLifetime: Int = 28_800,
		refreshLifetime: Int = 15_897_600,
		platform: String = "netlify",
		domain: String = PlatformAuthorizationEnvelope.refreshDomain
	) -> Result<PlatformTokenRefreshOutcome, PlatformAuthorizationError> {
		let payload: [String: Any] = [
			"platform": platform, "accessToken": access, "accessTokenExpiresIn": accessLifetime,
			"refreshToken": refresh, "refreshTokenExpiresIn": refreshLifetime,
		]
		let sealed = try! RegistryTestSealer.seal(payload, authorizationID: call.refreshID, to: call.clientPublicKey, domain: domain)
		return .success(.ready(sealed))
	}
}

/// A gate a test opens once.
actor TestGate {
	private var isOpen = false
	private var waiters: [CheckedContinuation<Void, Never>] = []

	func wait() async {
		guard !isOpen else { return }
		await withCheckedContinuation { waiters.append($0) }
	}

	func open() {
		isOpen = true
		for waiter in waiters { waiter.resume() }
		waiters = []
	}
}

struct PlatformTokensTests {
	@Test("a grant's tokens are the access token alone, or with all of what renews it")
	func readsTokens() throws {
		#expect(PlatformTokens(payload: ["accessToken": "t_access"]) == PlatformTokens(accessToken: "t_access", expiry: nil))
		let expiring = try #require(PlatformTokens(payload: [
			"accessToken": "t_access", "accessTokenExpiresIn": 28_800, "refreshToken": "t_refresh", "refreshTokenExpiresIn": 15_897_600,
		]))
		#expect(expiring.expiry == PlatformTokens.Expiry(accessTokenLifetime: 28_800, refreshToken: "t_refresh", refreshTokenLifetime: 15_897_600))
		let received = Date(timeIntervalSince1970: 1_760_000_000)
		let refresh = try #require(expiring.refresh(receivedAt: received, principalID: "user_1"))
		#expect(refresh.accessTokenExpiresAt == received.addingTimeInterval(28_800))
		#expect(refresh.expiresAt == received.addingTimeInterval(15_897_600))
		#expect(refresh.obtainedAt == received && refresh.principalID == "user_1" && refresh.attempt == nil && !refresh.isRejected)
	}

	@Test(
		"tokens that are incomplete, malformed or out of range are refused",
		arguments: [
			#"{"accessTokenExpiresIn":60,"refreshToken":"r","refreshTokenExpiresIn":60}"#,
			#"{"accessToken":"a","accessTokenExpiresIn":60}"#,
			#"{"accessToken":"a","refreshToken":"r","refreshTokenExpiresIn":60}"#,
			#"{"accessToken":"a","accessTokenExpiresIn":60,"refreshToken":"r"}"#,
			#"{"accessToken":"a","accessTokenExpiresIn":true,"refreshToken":"r","refreshTokenExpiresIn":60}"#,
			#"{"accessToken":"a","accessTokenExpiresIn":1.5,"refreshToken":"r","refreshTokenExpiresIn":60}"#,
			#"{"accessToken":"a","accessTokenExpiresIn":"60","refreshToken":"r","refreshTokenExpiresIn":60}"#,
			#"{"accessToken":"a","accessTokenExpiresIn":0,"refreshToken":"r","refreshTokenExpiresIn":60}"#,
			#"{"accessToken":"a","accessTokenExpiresIn":60,"refreshToken":"r","refreshTokenExpiresIn":99999999999}"#,
			#"{"accessToken":"a","accessTokenExpiresIn":60,"refreshToken":"a","refreshTokenExpiresIn":60}"#,
			#"{"accessToken":"a b","accessTokenExpiresIn":60,"refreshToken":"r","refreshTokenExpiresIn":60}"#,
			#"{"accessToken":"a","accessTokenExpiresIn":60,"refreshToken":"r b","refreshTokenExpiresIn":60}"#,
		]
	)
	func refusesMalformed(json: String) throws {
		let payload = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
		#expect(PlatformTokens(payload: payload) == nil)
	}

	@Test("a token is renewed when it's about to expire, the clock went back, or a renewal is unfinished")
	func renewalIsDue() {
		let obtained = Date(timeIntervalSince1970: 1_760_000_000)
		var refresh = PlatformTokenRefresh(
			token: "r", accessTokenExpiresAt: obtained.addingTimeInterval(8 * 3_600), expiresAt: obtained.addingTimeInterval(86_400),
			obtainedAt: obtained, principalID: "user_1")
		#expect(!refresh.isDue(at: obtained))
		#expect(!refresh.isDue(at: obtained.addingTimeInterval(8 * 3_600 - PlatformTokenRefresh.renewalMargin - 1)))
		#expect(refresh.isDue(at: obtained.addingTimeInterval(8 * 3_600 - PlatformTokenRefresh.renewalMargin)))
		#expect(refresh.isDue(at: obtained.addingTimeInterval(-1)), "A clock set back can't tell how old the token is")
		refresh.attempt = .make(at: obtained)
		#expect(refresh.isDue(at: obtained), "An unfinished renewal may already have replaced the token")
	}

	@Test("tokens, refresh tokens and an attempt's key never print")
	func redacted() throws {
		let tokens = try #require(PlatformTokens(
			accessToken: "secret_access", expiry: .init(accessTokenLifetime: 60, refreshToken: "secret_refresh", refreshTokenLifetime: 60)))
		var refresh = try #require(tokens.refresh(receivedAt: Date(), principalID: "user_1"))
		refresh.attempt = .make(at: Date())
		let key = try #require(refresh.attempt).key.base64EncodedString()
		for value in [tokens as Any, refresh as Any, refresh.attempt as Any] {
			var dumped = ""
			dump(value, to: &dumped)
			for text in [String(describing: value), String(reflecting: value), dumped] {
				#expect(!text.contains("secret_access") && !text.contains("secret_refresh") && !text.contains(key))
			}
		}
	}
}

struct PlatformTokenRefreshEnvelopeTests {
	/// Sealed by the Registry's own `sealRefreshResult` (lib/vault/platform-token-refresh.js).
	private let vector = (
		clientPrivateKey: "IVRq7jde3cSOh8neVfqyu+XYxPzhcNCqFQt0L1XkQYM=",
		refreshID: "3c9e1f2a-5b6d-4e7f-8a9b-0c1d2e3f4a5b",
		sealed: PlatformAuthorizationEnvelope.Sealed(
			version: 1,
			ephemeralPublicKey: "BKsoyesjj6QsTVjZsgkaCE7PufxluTt75Rv7IWYbZkHu+394RpR2HXvSWxEvfSRs3jwQmruBo23DsVEyIGh2vNM=",
			nonce: "KaiVMxY8ZNKOjxgV",
			ciphertext: "AV18tXkHVkKb9AcgppQPRDLOlu6745yi0YsCGrCBdB4R0AMZ3ca8ykJYvGzzKJxffrWZZ90LXku/TfvsmHv8D1fDqQxADEvxLj8vJ0DmEc8Oo+GclNiINatgfJFZzeTqr+7t7VRqPUzsfwMULKXydqksvQmmPl644a9XSEUcwJpFv5V7SX3mxwDrMwgpp6fsrAC612o3i3rx2weBFmQI+d80wJzZWkV5roaNOoebDN0ZVwOv307URPeF53vxhxcA0aliXAtXTxcK8Q=="
		)
	)

	@Test("a refresh the Registry sealed opens under the refresh domain only")
	func opensRegistryVector() throws {
		let key = try P256.KeyAgreement.PrivateKey(rawRepresentation: try #require(Data(base64Encoded: vector.clientPrivateKey)))
		let tokens = try PlatformAuthorizationEnvelope.open(
			vector.sealed, id: vector.refreshID, clientKey: key, domain: PlatformAuthorizationEnvelope.refreshDomain,
			read: PlatformTokens.init(payload:)
		).get()
		#expect(tokens.accessToken == "ghu_TestRefreshedAccess0123456789")
		#expect(tokens.expiry == .init(accessTokenLifetime: 28_800, refreshToken: "ghr_TestRefreshedRefresh0123456789", refreshTokenLifetime: 15_897_600))
		#expect(
			PlatformAuthorizationEnvelope.open(vector.sealed, as: NetlifyGrant.self, authorizationID: vector.refreshID, clientKey: key)
				== .failure(.undecryptable),
			"A refresh's result never opens as a connection's grant")
	}
}

struct PlatformTokenRefreshClientTests {
	private let refreshID = "0d2c8f4e-6b1a-4c3d-9e8f-7a6b5c4d3e2f"
	private let key = P256.KeyAgreement.PrivateKey()

	private func refresh(_ route: PlatformHTTPStub.Route, id: String? = nil) async -> Result<PlatformTokenRefreshOutcome, PlatformAuthorizationError> {
		await PlatformAuthorizationClient(session: route.session).refresh(
			.netlify, refreshToken: "nfo_refresh_old", clientPublicKey: key.publicKey.x963Representation,
			refreshID: id ?? refreshID, session: platformTestSession(route.baseURL))
	}

	/// A Registry that answers with `fields`, signed for the request's nonce,
	/// the test person, Netlify and this attempt unless `fields` says otherwise.
	private func answering(_ status: Int, _ fields: [String: Any]) -> PlatformHTTPStub.Route {
		let json = (try? JSONSerialization.data(withJSONObject: fields)) ?? Data()
		let refreshID = refreshID
		return PlatformHTTPStub.registry { request in
			let fields = (try? JSONSerialization.jsonObject(with: json) as? [String: Any]) ?? [:]
			let base: [String: Any] = [
				"requestNonce": request.header(PlatformAuthorizationClient.nonceHeader) ?? "",
				"principalId": platformTestPrincipal, "platform": "netlify", "refreshId": refreshID,
			]
			return RegistryTestSigner.signed(status, base.merging(fields) { _, new in new })
		}
	}

	@Test("a refresh sends the token, the attempt's key and its ID to the platform's route, with the session and a nonce")
	func sendsRefresh() async throws {
		let route = answering(202, ["status": "pending"])
		#expect(await refresh(route) == .success(.pending))
		let request = try #require(route.requests.first)
		#expect(request.method == "POST")
		#expect(request.url.path == "/api/vault/platforms/netlify/tokens")
		#expect(request.header("Authorization") == "Bearer lpm_session_token")
		#expect(PlatformAuthorizationClient.isOneTimeValue(request.header(PlatformAuthorizationClient.nonceHeader) ?? ""))
		let body = try #require(request.json)
		#expect(body.count == 3)
		#expect(body["refreshToken"] as? String == "nfo_refresh_old")
		#expect(body["publicKey"] as? String == key.publicKey.x963Representation.base64EncodedString())
		#expect(body["refreshId"] as? String == refreshID)
	}

	@Test("each signed answer about the attempt is read as the Registry means it")
	func readsOutcomes() async throws {
		let sealed = try RegistryTestSealer.seal(
			["platform": "netlify", "accessToken": "a"], authorizationID: refreshID, to: key.publicKey.x963Representation,
			domain: PlatformAuthorizationEnvelope.refreshDomain)
		let cases: [(Int, [String: Any], PlatformTokenRefreshOutcome)] = [
			(200, ["status": "ready", "envelope": sealed.json], .ready(sealed)),
			(202, ["status": "pending"], .pending),
			(409, ["status": "failed", "code": "refresh_rejected"], .failed(code: "refresh_rejected")),
			(409, ["status": "failed", "code": "Not A Code!"], .failed(code: "server_error")),
			(410, ["status": "expired"], .expired),
			(404, ["status": "unknown"], .unknown),
		]
		for (status, fields, outcome) in cases {
			#expect(await refresh(answering(status, fields)) == .success(outcome))
		}
	}

	@Test("an answer signed for another attempt, person or platform, or not signed, isn't believed")
	func refusesForeignAnswers() async {
		let foreign: [[String: Any]] = [
			["status": "pending", "refreshId": "11111111-2222-4333-8444-555555555555"],
			["status": "pending", "principalId": "user_someone_else"],
			["status": "pending", "platform": "vercel"],
		]
		for fields in foreign {
			#expect(await refresh(answering(202, fields)) == .failure(.invalidResponse))
		}
		let pending = PlatformHTTPStub.Reply.json(202, ["status": "pending", "refreshId": refreshID])
		let unsigned = PlatformHTTPStub.registry { _ in pending }
		#expect(await refresh(unsigned) == .failure(.invalidResponse))
	}

	@Test("failures the Registry answers before signing anything are read from their status")
	func readsUnsignedFailures() async {
		let cases: [(Int, [String: Any], PlatformAuthorizationError)] = [
			(401, [:], .signedOut),
			(403, [:], .forbidden),
			(429, ["code": "rate_limited"], .rateLimited),
			(503, ["code": "platform_unavailable"], .unavailable),
			(404, ["error": "Not found"], .server(404)),
			(500, [:], .server(500)),
		]
		for (status, body, error) in cases {
			let reply = PlatformHTTPStub.Reply.json(status, body)
			#expect(await refresh(PlatformHTTPStub.registry { _ in reply }) == .failure(error))
		}
	}

	@Test("a malformed attempt is refused before anything is sent")
	func refusesMalformedAttempt() async {
		let route = PlatformHTTPStub.registry { _ in .json(500, [:]) }
		#expect(await refresh(route, id: refreshID.uppercased()) == .failure(.invalidResponse))
		#expect(route.requests.isEmpty)
	}
}

struct PlatformConnectionStoreRefreshTests {
	private let keychain = MockKeychainService()
	private var store: PlatformConnectionStore { PlatformConnectionStore(service: keychain) }
	private let connectedAt = Date(timeIntervalSince1970: 1_760_000_000.5)
	private let account = PlatformConnection.Account.netlify(NetlifyConnectionAccount(userID: "u_1", name: "Tolga", email: nil))

	private func refresh(token: String = "nfo_refresh_1") -> PlatformTokenRefresh {
		PlatformTokenRefresh(
			token: token, accessTokenExpiresAt: connectedAt.addingTimeInterval(28_800), expiresAt: connectedAt.addingTimeInterval(86_400),
			obtainedAt: connectedAt, principalID: platformTestPrincipal)
	}

	@Test("a connection's refresh state round-trips, with an unfinished attempt, to the millisecond")
	func roundTrips() async throws {
		let store = store
		var stored = refresh()
		stored.attempt = .make(at: connectedAt)
		let saved = try await store.save(account, accessToken: "nfo_access_1", refresh: stored, at: connectedAt).get()
		let record = try await store.record(for: saved.id).get()
		#expect(record.accessToken == "nfo_access_1")
		#expect(record.refresh == stored)
		#expect(record.refresh?.attempt?.privateKey != nil)
		let decoded = PlatformConnectionStore.decode(try #require(keychain.platformConnectionStorage[saved.id]), account: saved.id)
		#expect(decoded == .success(record))
	}

	@Test("a connection without one reads back without one")
	func withoutRefresh() async throws {
		let store = store
		let saved = try await store.save(account, accessToken: "nfo_access_1", at: connectedAt).get()
		#expect(try await store.record(for: saved.id).get().refresh == nil)
		let data = try #require(keychain.platformConnectionStorage[saved.id])
		let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
		#expect(object["refresh"] == nil, "Records of tokens that don't expire stay as they were")
	}

	@Test("a token-only platform can't carry a refresh state, and a malformed one makes the record unreadable")
	func refusesMalformedRefresh() async throws {
		let coolify = PlatformConnectionStore.Record(
			connection: PlatformConnection(
				account: .coolify(CoolifyConnectionAccount(instance: CoolifyInstance(origin: "https://coolify.example.com")!, teamID: "0", teamName: "Team")),
				connectedAt: connectedAt),
			accessToken: "3|coolify", refresh: refresh())
		#expect(PlatformConnectionStore.encode(coolify) == nil)

		let store = store
		let saved = try await store.save(account, accessToken: "nfo_access_1", refresh: refresh(), at: connectedAt).get()
		let data = try #require(keychain.platformConnectionStorage[saved.id])
		let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
		let refreshObject = try #require(object["refresh"] as? [String: Any])
		let damaged: [[String: Any]] = [
			refreshObject.merging(["rejected": 0]) { _, new in new },
			refreshObject.merging(["token": "has space"]) { _, new in new },
			refreshObject.merging(["principalId": ""]) { _, new in new },
			refreshObject.merging(["attempt": ["id": "NOT-A-UUID", "key": "", "startedAt": 0]]) { _, new in new },
			refreshObject.merging(["attempt": ["id": UUID().uuidString.lowercased(), "key": Data(count: 32).base64EncodedString(), "startedAt": 0]]) { _, new in new },
			refreshObject.merging(["extra": true]) { _, new in new },
			refreshObject.filter { $0.key != "expiresAt" },
		]
		for value in damaged {
			let changed = object.merging(["refresh": value]) { _, new in new }
			keychain.platformConnectionStorage[saved.id] = try JSONSerialization.data(withJSONObject: changed)
			#expect(await store.record(for: saved.id).map(\.accessToken) == .failure(.unreadable))
		}
	}

	@Test("a renewal is begun only for the token the connection holds, once, and finished or refused only by its own attempt")
	func updatesAreConditional() async throws {
		let store = store
		let saved = try await store.save(account, accessToken: "nfo_access_1", refresh: refresh(), at: connectedAt).get()
		let attempt = PlatformTokenRefresh.Attempt.make(at: connectedAt)
		#expect(try await store.beginRefresh(of: saved.id, token: "nfo_refresh_other", attempt: attempt).get() == false)
		#expect(try await store.beginRefresh(of: saved.id, token: "nfo_refresh_1", attempt: attempt).get())
		#expect(try await store.beginRefresh(of: saved.id, token: "nfo_refresh_1", attempt: .make(at: connectedAt)).get() == false)
		#expect(try await store.record(for: saved.id).get().refresh?.attempt == attempt)

		let tokens = try #require(PlatformTokens(
			accessToken: "nfo_access_2", expiry: .init(accessTokenLifetime: 60, refreshToken: "nfo_refresh_2", refreshTokenLifetime: 120)))
		let received = connectedAt.addingTimeInterval(30)
		#expect(try await store.completeRefresh(of: saved.id, attempt: UUID().uuidString.lowercased(), with: tokens, at: received).get() == false)
		#expect(try await store.rejectRefresh(of: saved.id, attempt: UUID().uuidString.lowercased()).get() == false)
		#expect(try await store.completeRefresh(of: saved.id, attempt: attempt.id, with: tokens, at: received).get())
		let renewed = try await store.record(for: saved.id).get()
		#expect(renewed.accessToken == "nfo_access_2")
		#expect(renewed.connection == saved)
		#expect(renewed.refresh == PlatformTokenRefresh(
			token: "nfo_refresh_2", accessTokenExpiresAt: received.addingTimeInterval(60), expiresAt: received.addingTimeInterval(120),
			obtainedAt: received, principalID: platformTestPrincipal))

		let next = PlatformTokenRefresh.Attempt.make(at: received)
		#expect(try await store.beginRefresh(of: saved.id, token: "nfo_refresh_2", attempt: next).get())
		#expect(try await store.rejectRefresh(of: saved.id, attempt: next.id).get())
		let rejected = try #require(try await store.record(for: saved.id).get().refresh)
		#expect(rejected.isRejected && rejected.attempt == nil)
		#expect(try await store.beginRefresh(of: saved.id, token: "nfo_refresh_2", attempt: .make(at: received)).get() == false)
	}
}

struct PlatformCredentialsTests {
	private let keychain = MockKeychainService()
	private let registry = URL(string: "http://localhost:3000")!
	private let start = Date(timeIntervalSince1970: 1_760_000_000)
	private let account = PlatformConnection.Account.netlify(NetlifyConnectionAccount(userID: "u_1", name: "Tolga", email: nil))

	private var store: PlatformConnectionStore { PlatformConnectionStore(service: keychain) }

	/// A connection whose access token expires `lifetime` after `start`.
	private func connect(lifetime: TimeInterval = 8 * 3_600, refreshLifetime: TimeInterval = 86_400, attempt: PlatformTokenRefresh.Attempt? = nil) async throws -> PlatformConnection.ID {
		let refresh = PlatformTokenRefresh(
			token: "nfo_refresh_old", accessTokenExpiresAt: start.addingTimeInterval(lifetime),
			expiresAt: start.addingTimeInterval(refreshLifetime), obtainedAt: start, principalID: platformTestPrincipal, attempt: attempt)
		return try await store.save(account, accessToken: "nfo_access_old", refresh: refresh, at: start).get().id
	}

	private func credentials(
		_ refresher: ScriptedTokenRefresher,
		at clock: TestDate,
		session: PlatformSession?? = nil
	) -> PlatformCredentials {
		let chosen = session ?? .some(platformTestSession(registry))
		return PlatformCredentials(store: store, refresher: refresher, session: { chosen }, now: { clock.date }, pendingDelay: .zero)
	}

	@Test("a token that doesn't expire, or isn't about to, is read without asking lpm.dev")
	func readsCurrentTokens() async throws {
		let refresher = ScriptedTokenRefresher { _, _ in .failure(.transport) }
		let lasting = try await store.save(
			.vercel(VercelConnectionAccount(installationID: "icfg_1", teamID: "team_1", userID: "u_1", name: "Acme", slug: nil)),
			accessToken: "vca_lasting", at: start).get()
		let id = try await connect()
		let clock = TestDate(start.addingTimeInterval(3_600))
		let credentials = credentials(refresher, at: clock)
		#expect(await credentials.accessToken(for: lasting.id) == .success("vca_lasting"))
		#expect(await credentials.accessToken(for: id) == .success("nfo_access_old"))
		#expect(refresher.calls.isEmpty)
		#expect(await credentials.accessToken(for: "netlify.missing") == .failure(.store(.notFound)))
	}

	@Test("a token about to expire is renewed once through lpm.dev, and the new tokens are saved with lifetimes from their arrival")
	func renews() async throws {
		let id = try await connect()
		let clock = TestDate(start.addingTimeInterval(8 * 3_600 - 60))
		let refresher = ScriptedTokenRefresher { call, _ in ScriptedTokenRefresher.renewed(call) }
		let credentials = credentials(refresher, at: clock)
		#expect(await credentials.accessToken(for: id) == .success("nfo_renewed_access"))
		let call = try #require(refresher.calls.first)
		#expect(refresher.calls.count == 1)
		#expect(call.platform == .netlify && call.refreshToken == "nfo_refresh_old" && call.principalID == platformTestPrincipal)
		#expect(PlatformAuthorizationClient.isCanonicalUUID(call.refreshID) && call.clientPublicKey.count == 65)
		let record = try await store.record(for: id).get()
		#expect(record.accessToken == "nfo_renewed_access")
		#expect(record.refresh == PlatformTokenRefresh(
			token: "nfo_renewed_refresh", accessTokenExpiresAt: clock.date.addingTimeInterval(28_800),
			expiresAt: clock.date.addingTimeInterval(15_897_600), obtainedAt: clock.date, principalID: platformTestPrincipal))
		#expect(await credentials.accessToken(for: id) == .success("nfo_renewed_access"))
		#expect(refresher.calls.count == 1, "The renewed token is used until it's about to expire")
	}

	@Test("callers asking while a renewal runs share it", .timeLimit(.minutes(1)))
	func sharesRenewal() async throws {
		let id = try await connect()
		let clock = TestDate(start.addingTimeInterval(8 * 3_600))
		let gate = TestGate()
		let refresher = ScriptedTokenRefresher { call, _ in
			await gate.wait()
			return ScriptedTokenRefresher.renewed(call)
		}
		let credentials = credentials(refresher, at: clock)
		let callers = (0..<4).map { _ in Task { await credentials.accessToken(for: id) } }
		#expect(try await waitUntil { await credentials.sharedReads == 3 })
		await gate.open()
		for caller in callers {
			#expect(await caller.value == .success("nfo_renewed_access"))
		}
		#expect(refresher.calls.count == 1)
	}

	@Test("a renewal whose answer was lost is sent again as the same attempt, and collects its tokens")
	func resendsLostAttempt() async throws {
		let id = try await connect()
		let clock = TestDate(start.addingTimeInterval(8 * 3_600))
		let refresher = ScriptedTokenRefresher { call, index in
			index == 0 ? .failure(.transport) : ScriptedTokenRefresher.renewed(call)
		}
		let credentials = credentials(refresher, at: clock)
		#expect(await credentials.accessToken(for: id) == .failure(.unavailable))
		let saved = try #require(try await store.record(for: id).get().refresh?.attempt)
		#expect(saved.id == refresher.calls[0].refreshID, "The attempt is saved before it's sent")
		#expect(await credentials.accessToken(for: id) == .success("nfo_renewed_access"))
		#expect(refresher.calls.map(\.refreshID) == [saved.id, saved.id])
		#expect(refresher.calls[1].clientPublicKey == refresher.calls[0].clientPublicKey)
		#expect(try await store.record(for: id).get().refresh?.attempt == nil)
	}

	@Test("an attempt saved before a quit is finished first, even while the old token still looks current")
	func finishesSavedAttempt() async throws {
		let attempt = PlatformTokenRefresh.Attempt.make(at: start)
		let id = try await connect(attempt: attempt)
		let refresher = ScriptedTokenRefresher { call, _ in ScriptedTokenRefresher.renewed(call) }
		let credentials = credentials(refresher, at: TestDate(start.addingTimeInterval(60)))
		#expect(await credentials.accessToken(for: id) == .success("nfo_renewed_access"))
		let call = try #require(refresher.calls.first)
		#expect(call.refreshID == attempt.id)
		#expect(call.clientPublicKey == attempt.privateKey?.publicKey.x963Representation)
	}

	@Test("a request still pending at lpm.dev is asked again until it's ready")
	func waitsForPending() async throws {
		let id = try await connect()
		let refresher = ScriptedTokenRefresher { call, index in
			index < 2 ? .success(.pending) : ScriptedTokenRefresher.renewed(call)
		}
		let credentials = credentials(refresher, at: TestDate(start.addingTimeInterval(8 * 3_600)))
		#expect(await credentials.accessToken(for: id) == .success("nfo_renewed_access"))
		#expect(Set(refresher.calls.map(\.refreshID)).count == 1 && refresher.calls.count == 3)
	}

	@Test("a request that stays pending is left for later, with its attempt kept")
	func givesUpOnPending() async throws {
		let id = try await connect()
		let refresher = ScriptedTokenRefresher { _, _ in .success(.pending) }
		let credentials = credentials(refresher, at: TestDate(start.addingTimeInterval(8 * 3_600)))
		#expect(await credentials.accessToken(for: id) == .failure(.unavailable))
		#expect(refresher.calls.count == PlatformCredentials.pendingRetries + 1)
		#expect(try await store.record(for: id).get().refresh?.attempt != nil)
	}

	@Test(
		"a token lpm.dev won't renew marks the connection expired, and isn't sent again",
		arguments: [
			PlatformTokenRefreshOutcome.failed(code: "refresh_rejected"),
			.failed(code: "refresh_token_used"),
			.expired,
			.unknown,
		]
	)
	func expiresRefused(outcome: PlatformTokenRefreshOutcome) async throws {
		let id = try await connect()
		let refresher = ScriptedTokenRefresher { _, _ in .success(outcome) }
		let credentials = credentials(refresher, at: TestDate(start.addingTimeInterval(8 * 3_600)))
		#expect(await credentials.accessToken(for: id) == .failure(.expired))
		#expect(await credentials.accessToken(for: id) == .failure(.expired))
		#expect(refresher.calls.count == 1)
		let refresh = try #require(try await store.record(for: id).get().refresh)
		#expect(refresh.isRejected && refresh.attempt == nil)
	}

	@Test("renewing needs a sign-in to the LPM account the platform was connected with")
	func needsTheConnectingAccount() async throws {
		let id = try await connect()
		let clock = TestDate(start.addingTimeInterval(8 * 3_600))
		let refresher = ScriptedTokenRefresher { _, _ in .failure(.transport) }
		#expect(await credentials(refresher, at: clock, session: .some(nil)).accessToken(for: id) == .failure(.signedOut))
		let other = PlatformSession(token: "lpm_other", principalID: "user_someone_else", baseURL: registry)
		#expect(await credentials(refresher, at: clock, session: other).accessToken(for: id) == .failure(.otherAccount))
		#expect(refresher.calls.isEmpty)
		#expect(try await store.record(for: id).get().refresh?.attempt == nil, "Nothing is begun without the account that can finish it")
	}

	@Test("a refresh token past its expiry isn't sent, but an attempt sent before it expired is still finished")
	func expiredRefreshToken() async throws {
		let refresher = ScriptedTokenRefresher { call, _ in ScriptedTokenRefresher.renewed(call) }
		let late = TestDate(start.addingTimeInterval(86_400))
		let id = try await connect()
		#expect(await credentials(refresher, at: late).accessToken(for: id) == .failure(.expired))
		#expect(refresher.calls.isEmpty)
		let pending = try await connect(attempt: .make(at: start))
		#expect(await credentials(refresher, at: late).accessToken(for: pending) == .success("nfo_renewed_access"))
	}

	@Test("a clock set back before the token arrived renews it")
	func clockSetBack() async throws {
		let id = try await connect()
		let refresher = ScriptedTokenRefresher { call, _ in ScriptedTokenRefresher.renewed(call) }
		#expect(await credentials(refresher, at: TestDate(start.addingTimeInterval(-3_600))).accessToken(for: id) == .success("nfo_renewed_access"))
	}

	@Test(
		"a result sealed for a connection, or naming another platform, isn't accepted, and the attempt is kept",
		arguments: [(PlatformAuthorizationEnvelope.domain, "netlify"), (PlatformAuthorizationEnvelope.refreshDomain, "vercel")]
	)
	func refusesForeignResult(domain: String, platform: String) async throws {
		let id = try await connect()
		let refresher = ScriptedTokenRefresher { call, _ in ScriptedTokenRefresher.renewed(call, platform: platform, domain: domain) }
		#expect(await credentials(refresher, at: TestDate(start.addingTimeInterval(8 * 3_600))).accessToken(for: id) == .failure(.invalidResponse))
		let record = try await store.record(for: id).get()
		#expect(record.accessToken == "nfo_access_old" && record.refresh?.attempt != nil)
	}

	@Test(
		"a connection connected again during a renewal keeps its new token, whatever lpm.dev answers the old attempt",
		arguments: ["renewed", "failed", "expired", "unknown"]
	)
	func reconnectedMeanwhile(answer: String) async throws {
		let id = try await connect()
		let store = store
		let account = account
		let start = start
		let refresher = ScriptedTokenRefresher { call, _ in
			_ = await store.save(account, accessToken: "nfo_reconnected", at: start)
			switch answer {
			case "failed": return .success(.failed(code: "refresh_token_used"))
			case "expired": return .success(.expired)
			case "unknown": return .success(.unknown)
			default: return ScriptedTokenRefresher.renewed(call)
			}
		}
		#expect(await credentials(refresher, at: TestDate(start.addingTimeInterval(8 * 3_600))).accessToken(for: id) == .success("nfo_reconnected"))
		let record = try await store.record(for: id).get()
		#expect(record.accessToken == "nfo_reconnected" && record.refresh == nil)
	}

	@Test("a token the platform refused is renewed even while it looks current, as when the clock is wrong")
	func renewsRefusedToken() async throws {
		let id = try await connect()
		let refresher = ScriptedTokenRefresher { call, _ in ScriptedTokenRefresher.renewed(call) }
		let credentials = credentials(refresher, at: TestDate(start.addingTimeInterval(60)))
		#expect(await credentials.accessToken(for: id) == .success("nfo_access_old"))
		#expect(refresher.calls.isEmpty)
		#expect(await credentials.accessToken(for: id, replacing: "nfo_access_old") == .success("nfo_renewed_access"))
		#expect(refresher.calls.count == 1)
		#expect(await credentials.accessToken(for: id, replacing: "nfo_access_old") == .success("nfo_renewed_access"),
			"A refusal of a token already replaced is answered with its replacement")
		#expect(refresher.calls.count == 1)
	}

	@Test("a refused token that doesn't renew, or a renewal lpm.dev refuses, means connecting again")
	func refusedTokenWithoutRenewal() async throws {
		let lasting = try await store.save(account, accessToken: "nfo_lasting", at: start).get()
		let refresher = ScriptedTokenRefresher { _, _ in .success(.failed(code: "refresh_rejected")) }
		let credentials = credentials(refresher, at: TestDate(start.addingTimeInterval(60)))
		#expect(await credentials.accessToken(for: lasting.id, replacing: "nfo_lasting") == .failure(.expired))
		let id = try await connect()
		#expect(await credentials.accessToken(for: id, replacing: "nfo_access_old") == .failure(.expired))
	}

	@Test("each failure says what to do, naming the platform")
	func messages() {
		#expect(PlatformCredentialError.expired.message(for: .netlify) == "The Netlify connection expired. Connect Netlify again on the Platforms page.")
		#expect(PlatformCredentialError.signedOut.message(for: .netlify).hasPrefix("Sign in to LPM"))
		#expect(PlatformCredentialError.otherAccount.message(for: .netlify).contains("another LPM account"))
	}
}
