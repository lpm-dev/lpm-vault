import CryptoKit
import Foundation
import Testing
@testable import LPMVault

struct PlatformAuthorizationEnvelopeTests {
	/// Sealed by the Registry's own `sealAuthorizationResult` (lib/vault/vercel-authorization.js).
	private let vector = (
		clientPrivateKey: "DNNyB9HoOrWe9u4YXWBgK7N7K2vRpMhDs+Uni73Lajs=",
		authorizationID: "6f1c2d3e-4a5b-4c6d-8e7f-901a2b3c4d5e",
		sealed: PlatformAuthorizationEnvelope.Sealed(
			version: 1,
			ephemeralPublicKey: "BFCQSP98zd7bL9lYXjxSQ6yHe4G54wwHZgi+uiHD6rqVSt9OymzjRAJKSKJh2qCuA9iWmSZysgjOyHBiqk5Ddag=",
			nonce: "WRvMEWrG/SEEDE5N",
			ciphertext: "TRlNa5bK1qrhQHGjrZNYTwpErNQ4u+9wGe+9ozv703QrBMmBdQ6Hc2EPRAMWDIH7Bn6XfMYcAEq2YHIThcdWhirTpL6xPogpCO1B7LO2l1fbvVFeGOockFZ+ZxZx5dWjtFNbJwNdxy4vqqYNleI5mmmLjC1vXzurGyuflt/FWvNyvaxLd8jrrikvoiKPydvSohtA2ifOay+RN/Z1Sg817YNrXcgxyAzvnG2ZSPut/AwBHFwQt+ikJaEjHA=="
		)
	)

	private var clientKey: P256.KeyAgreement.PrivateKey {
		get throws { try P256.KeyAgreement.PrivateKey(rawRepresentation: try #require(Data(base64Encoded: vector.clientPrivateKey))) }
	}

	@Test("a grant the Registry sealed opens with the Mac's key, exactly as sent")
	func opensRegistryVector() throws {
		let grant = try PlatformAuthorizationEnvelope.openVercelGrant(
			vector.sealed, authorizationID: vector.authorizationID, clientKey: clientKey
		).get()
		#expect(grant.accessToken == "vca_TestToken_0123456789abcdefABCDEF")
		#expect(grant.installationID == "icfg_TestInstallation01")
		#expect(grant.teamID == "team_TestTeam01")
		#expect(grant.userID == "user_TestUser01")
	}

	@Test("a sealed grant doesn't open for another authorization, another key, or after any change")
	func refusesTampering() throws {
		let key = try clientKey
		#expect(PlatformAuthorizationEnvelope.openVercelGrant(
			vector.sealed, authorizationID: UUID().uuidString.lowercased(), clientKey: key) == .failure(.undecryptable))
		#expect(PlatformAuthorizationEnvelope.openVercelGrant(
			vector.sealed, authorizationID: vector.authorizationID, clientKey: P256.KeyAgreement.PrivateKey()) == .failure(.undecryptable))
		var ciphertext = try #require(Data(base64Encoded: vector.sealed.ciphertext))
		ciphertext[ciphertext.startIndex] ^= 0x01
		let changed = PlatformAuthorizationEnvelope.Sealed(
			version: 1, ephemeralPublicKey: vector.sealed.ephemeralPublicKey, nonce: vector.sealed.nonce,
			ciphertext: ciphertext.base64EncodedString())
		#expect(PlatformAuthorizationEnvelope.openVercelGrant(changed, authorizationID: vector.authorizationID, clientKey: key) == .failure(.undecryptable))
		let newer = PlatformAuthorizationEnvelope.Sealed(
			version: 2, ephemeralPublicKey: vector.sealed.ephemeralPublicKey, nonce: vector.sealed.nonce, ciphertext: vector.sealed.ciphertext)
		#expect(PlatformAuthorizationEnvelope.openVercelGrant(newer, authorizationID: vector.authorizationID, clientKey: key) == .failure(.malformed))
	}

	@Test(
		"a decrypted grant that isn't a well-formed Vercel grant is refused",
		arguments: [
			#"{"platform":"netlify","accessToken":"t","installationId":"icfg_1","teamId":null,"userId":"u_1"}"#,
			#"{"platform":"vercel","accessToken":"has space","installationId":"icfg_1","teamId":null,"userId":"u_1"}"#,
			#"{"platform":"vercel","accessToken":"t","installationId":"../x","teamId":null,"userId":"u_1"}"#,
			#"{"platform":"vercel","accessToken":"t","installationId":"icfg_1","teamId":7,"userId":"u_1"}"#,
			#"{"platform":"vercel","accessToken":"t","installationId":"icfg_1","userId":7}"#,
		]
	)
	func refusesMalformedGrant(json: String) throws {
		let payload = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
		let key = P256.KeyAgreement.PrivateKey()
		let id = UUID().uuidString.lowercased()
		let sealed = try RegistryTestSealer.seal(payload, authorizationID: id, to: key.publicKey.x963Representation)
		#expect(PlatformAuthorizationEnvelope.openVercelGrant(sealed, authorizationID: id, clientKey: key) == .failure(.invalidGrant))
	}

	@Test("a personal account's grant has no team, and the token never prints")
	func personalGrantIsRedacted() throws {
		let key = P256.KeyAgreement.PrivateKey()
		let id = UUID().uuidString.lowercased()
		let sealed = try RegistryTestSealer.seal(
			["platform": "vercel", "accessToken": "vca_secret_value", "installationId": "icfg_1", "teamId": NSNull(), "userId": "u_1"],
			authorizationID: id, to: key.publicKey.x963Representation)
		let grant = try PlatformAuthorizationEnvelope.openVercelGrant(sealed, authorizationID: id, clientKey: key).get()
		#expect(grant.teamID == nil)
		var dumped = ""
		dump(grant, to: &dumped)
		for text in [grant.description, String(reflecting: grant), "\(grant)", dumped] {
			#expect(!text.contains("vca_secret_value"))
		}
	}
}

struct PlatformAuthorizationClientTests {
	private let installURL = "https://vercel.com/integrations/lpm-vault/new?state=\(platformTestOneTimeValue())"
	private let authorizationID = UUID().uuidString.lowercased()

	private func startReply(_ request: PlatformHTTPStub.Request, overrides: [String: Any] = [:]) -> PlatformHTTPStub.Reply {
		var body: [String: Any] = [
			"requestNonce": request.header(PlatformAuthorizationClient.nonceHeader) ?? "",
			"principalId": platformTestPrincipal,
			"platform": "vercel",
			"authorizationId": authorizationID,
			"installUrl": installURL,
			"expiresAt": "2026-10-14T10:00:00.000Z",
		]
		body.merge(overrides) { _, new in new }
		return RegistryTestSigner.signed(201, body)
	}

	@Test("starting sends the Mac's key, port, session and a fresh nonce, and reads the signed answer")
	func start() async throws {
		let route = PlatformHTTPStub.registry { startReply($0) }
		let client = PlatformAuthorizationClient(session: route.session)
		let key = P256.KeyAgreement.PrivateKey().publicKey.x963Representation
		let started = try await client.startVercel(clientPublicKey: key, loopbackPort: 51_234, session: platformTestSession(route.baseURL)).get()
		#expect(started.id == authorizationID)
		#expect(started.installURL.absoluteString == installURL)
		let request = try #require(route.requests.first)
		#expect(request.method == "POST" && request.url.path() == "/api/vault/platforms/vercel/authorizations")
		#expect(request.header("Authorization") == "Bearer lpm_session_token")
		#expect(request.json?["publicKey"] as? String == key.base64EncodedString())
		#expect(request.json?["loopbackPort"] as? Int == 51_234)
		let nonce = try #require(request.header(PlatformAuthorizationClient.nonceHeader))
		#expect(nonce.utf8.count == 43)
		_ = try await client.startVercel(clientPublicKey: key, loopbackPort: 51_234, session: platformTestSession(route.baseURL)).get()
		#expect(route.requests.last?.header(PlatformAuthorizationClient.nonceHeader) != nonce)
	}

	@Test(
		"a start answer that's unsigned, for another request or person, or that points the browser elsewhere is refused",
		arguments: ["unsigned", "nonce", "principal", "platform", "url-host", "url-path", "url-state", "id"]
	)
	func refusesUntrustedStart(change: String) async throws {
		let route = PlatformHTTPStub.registry { request in
			switch change {
			case "unsigned": return .json(201, ["requestNonce": request.header(PlatformAuthorizationClient.nonceHeader) ?? ""])
			case "nonce": return startReply(request, overrides: ["requestNonce": platformTestOneTimeValue()])
			case "principal": return startReply(request, overrides: ["principalId": "someone_else"])
			case "platform": return startReply(request, overrides: ["platform": "netlify"])
			case "url-host": return startReply(request, overrides: ["installUrl": "https://vercel.example/integrations/lpm-vault/new?state=\(platformTestOneTimeValue())"])
			case "url-path": return startReply(request, overrides: ["installUrl": "https://vercel.com/login?next=/integrations/lpm-vault/new"])
			case "url-state": return startReply(request, overrides: ["installUrl": "https://vercel.com/integrations/lpm-vault/new?state=x&redirect=evil"])
			default: return startReply(request, overrides: ["authorizationId": "not-a-uuid"])
			}
		}
		let client = PlatformAuthorizationClient(session: route.session)
		let result = await client.startVercel(
			clientPublicKey: P256.KeyAgreement.PrivateKey().publicKey.x963Representation, loopbackPort: 50_000,
			session: platformTestSession(route.baseURL))
		#expect(result == .failure(.invalidResponse))
	}

	@Test(
		"the Registry's unsigned refusals map to what the person can do about them",
		arguments: [
			(401, [:], PlatformAuthorizationError.signedOut),
			(403, [:], .forbidden),
			(503, ["code": "platform_unavailable"], .unavailable),
			(429, ["code": "too_many_authorizations"], .tooManyOpen),
			(429, ["code": "rate_limited"], .rateLimited),
			(500, [:], .server(500)),
		] as [(Int, [String: String], PlatformAuthorizationError)]
	)
	func startRefusals(status: Int, body: [String: String], expected: PlatformAuthorizationError) async {
		let route = PlatformHTTPStub.registry { _ in .json(status, body) }
		let result = await PlatformAuthorizationClient(session: route.session).startVercel(
			clientPublicKey: P256.KeyAgreement.PrivateKey().publicKey.x963Representation, loopbackPort: 50_000,
			session: platformTestSession(route.baseURL))
		#expect(result == .failure(expected))
	}

	@Test("redeeming reads each signed outcome for this authorization")
	func redeemOutcomes() async throws {
		let sealed = PlatformAuthorizationEnvelope.Sealed(version: 1, ephemeralPublicKey: "e", nonce: "n", ciphertext: "c")
		let cases: [(Int, [String: Any], PlatformAuthorizationOutcome)] = [
			(200, ["status": "ready", "envelope": sealed.json], .ready(sealed)),
			(202, ["status": "pending"], .pending),
			(409, ["status": "failed", "code": "authorization_cancelled"], .failed(code: "authorization_cancelled")),
			(409, ["status": "failed", "code": "<script>"], .failed(code: "server_error")),
			(410, ["status": "expired"], .expired),
			(403, ["status": "proof_mismatch"], .proofMismatch),
			(404, ["status": "missing"], .missing),
		]
		for (status, body, expected) in cases {
			let bodyData = try JSONSerialization.data(withJSONObject: body)
			let route = PlatformHTTPStub.registry { request in
				var signed = (try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any]) ?? [:]
				signed["requestNonce"] = request.header(PlatformAuthorizationClient.nonceHeader) ?? ""
				signed["principalId"] = platformTestPrincipal
				signed["platform"] = "vercel"
				signed["authorizationId"] = authorizationID
				return RegistryTestSigner.signed(status, signed)
			}
			let proof = platformTestOneTimeValue()
			let outcome = await PlatformAuthorizationClient(session: route.session).redeem(
				authorizationID, proof: proof, session: platformTestSession(route.baseURL))
			#expect(outcome == .success(expected), "HTTP \(status)")
			#expect(route.requests.first?.url.path() == "/api/vault/platforms/vercel/authorizations/\(authorizationID)/redeem")
			#expect(route.requests.first?.json?["proof"] as? String == proof)
		}
	}

	@Test("a redeem answer about another authorization, or unsigned, is refused")
	func redeemRefusesUntrusted() async {
		let replies: [PlatformHTTPStub.Handler] = [
			{ request in RegistryTestSigner.signed(200, [
				"requestNonce": request.header(PlatformAuthorizationClient.nonceHeader) ?? "", "principalId": platformTestPrincipal,
				"platform": "vercel", "authorizationId": UUID().uuidString.lowercased(), "status": "pending",
			]) },
			{ _ in PlatformHTTPStub.Reply.json(200, ["status": "ready"]) },
		]
		for reply in replies {
			let route = PlatformHTTPStub.registry(reply)
			let outcome = await PlatformAuthorizationClient(session: route.session).redeem(
				authorizationID, proof: platformTestOneTimeValue(), session: platformTestSession(route.baseURL))
			#expect(outcome == .failure(.invalidResponse))
		}
	}

	@Test("cancelling deletes the authorization with the session")
	func cancel() async throws {
		let route = PlatformHTTPStub.registry { _ in PlatformHTTPStub.Reply(status: 204, body: Data()) }
		await PlatformAuthorizationClient(session: route.session).cancel(authorizationID, session: platformTestSession(route.baseURL))
		let request = try #require(route.requests.first)
		#expect(request.method == "DELETE" && request.url.path() == "/api/vault/platforms/vercel/authorizations/\(authorizationID)")
		#expect(request.header("Authorization") == "Bearer lpm_session_token")
	}

	@Test("the session's token never prints")
	func sessionIsRedacted() {
		let session = platformTestSession(URL(string: "https://lpm.dev")!)
		var dumped = ""
		dump(session, to: &dumped)
		for text in [session.description, String(reflecting: session), dumped] {
			#expect(!text.contains("lpm_session_token"))
		}
	}
}

struct PlatformConnectionListenerTests {
	private func get(_ port: UInt16, _ query: String) async throws -> (Int, String) {
		let url = try #require(URL(string: "http://127.0.0.1:\(port)\(PlatformConnectionListener.path)?\(query)"))
		let (data, response) = try await URLSession(configuration: .ephemeral).data(from: url)
		return ((response as? HTTPURLResponse)?.statusCode ?? 0, String(decoding: data, as: UTF8.self))
	}

	@Test("only the expected authorization ends the wait; anything else gets a page and is ignored")
	func waitsForExpectedAuthorization() async throws {
		let listener = try await PlatformConnectionListener.start()
		defer { listener.stop() }
		let id = UUID().uuidString.lowercased()
		listener.expect(id)
		let proof = platformTestOneTimeValue()
		let other = try await get(listener.port, "authorization=\(UUID().uuidString.lowercased())&proof=\(proof)")
		#expect(other.0 == 400 && other.1.contains("Start from LPM Vault"))
		let next = "https%3A%2F%2Fvercel.com%2Fdashboard"
		async let completion = listener.completion(until: Date(timeIntervalSinceNow: 5))
		let page = try await get(listener.port, "authorization=\(id)&proof=\(proof)&next=\(next)")
		#expect(page.0 == 200 && page.1.contains("Return to LPM Vault") && page.1.contains("href=\"https://vercel.com/dashboard\""))
		#expect(try await completion == .proof(proof))
	}

	@Test("a failure from the Registry ends the wait with its reason")
	func failureEndsWait() async throws {
		let listener = try await PlatformConnectionListener.start()
		defer { listener.stop() }
		let id = UUID().uuidString.lowercased()
		listener.expect(id)
		let page = try await get(listener.port, "authorization=\(id)&error=authorization_cancelled")
		#expect(page.0 == 400 && page.1.contains("cancelled on Vercel"))
		#expect(try await listener.completion(until: Date(timeIntervalSinceNow: 5)) == .failure(.cancelledOnPlatform))
	}

	@Test("waiting ends at the deadline, or when the task is cancelled")
	func deadlineAndCancellation() async throws {
		let listener = try await PlatformConnectionListener.start()
		await #expect(throws: PlatformConnectionListener.ListenerError.timedOut) {
			try await listener.completion(until: Date(timeIntervalSinceNow: 0.2))
		}
		let waiting = try await PlatformConnectionListener.start()
		let task = Task { try await waiting.completion(until: Date(timeIntervalSinceNow: 30)) }
		try await Task.sleep(for: .milliseconds(50))
		task.cancel()
		await #expect(throws: CancellationError.self) { try await task.value }
	}

	@Test("requests that aren't a return from Vercel are not completions")
	func parsing() throws {
		let id = UUID().uuidString.lowercased()
		let proof = platformTestOneTimeValue()
		func request(_ line: String) -> Data { Data("\(line) HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".utf8) }
		let path = PlatformConnectionListener.path
		#expect(PlatformConnectionListener.parse(request("GET \(path)?authorization=\(id)&proof=\(proof)"))?.completion == .proof(proof))
		for line in [
			"POST \(path)?authorization=\(id)&proof=\(proof)",
			"GET /callback?authorization=\(id)&proof=\(proof)",
			"GET \(path)?authorization=\(id)",
			"GET \(path)?authorization=\(id)&proof=\(proof)&error=server_error",
			"GET \(path)?authorization=\(id.uppercased())&proof=\(proof)",
			"GET \(path)?authorization=\(id)&proof=short",
			"GET \(path)?authorization=\(id)&error=Bad%20Code",
		] {
			#expect(PlatformConnectionListener.parse(request(line)) == nil, "\(line)")
		}
		let badlyEncoded = PlatformConnectionListener.parse(request("GET \(path)?authorization=\(id)&proof=\(proof)&next=%zz"))
		#expect(badlyEncoded?.completion == .proof(proof) && badlyEncoded?.next == nil)
		for next in ["https://evil.example/", "http://vercel.com/", "https://user@vercel.com/", "https://vercel.com:8443/"] {
			let encoded = try #require(next.addingPercentEncoding(withAllowedCharacters: .alphanumerics))
			#expect(PlatformConnectionListener.parse(request("GET \(path)?authorization=\(id)&proof=\(proof)&next=\(encoded)"))?.next == nil)
		}
	}
}

/// A Registry that answers from closures and records what was cancelled.
private final class FakeAuthorizations: PlatformAuthorizationClientProtocol, @unchecked Sendable {
	private let lock = NSLock()
	private var publicKey: Data?
	private var cancelled: [String] = []
	private var redeems = 0
	let id = UUID().uuidString.lowercased()
	var start: (@Sendable () -> Result<Void, PlatformAuthorizationError>) = { .success(()) }
	var outcome: (@Sendable (_ attempt: Int, _ id: String, _ key: Data) -> Result<PlatformAuthorizationOutcome, PlatformAuthorizationError>) = { _, _, _ in .success(.missing) }
	let installURL = URL(string: "https://vercel.com/integrations/lpm-vault/new?state=\(platformTestOneTimeValue())")!

	var cancelledIDs: [String] { lock.withLock { cancelled } }

	func startVercel(clientPublicKey: Data, loopbackPort: UInt16, session: PlatformSession) async -> Result<StartedPlatformAuthorization, PlatformAuthorizationError> {
		lock.withLock { publicKey = clientPublicKey }
		return start().map { StartedPlatformAuthorization(id: id, installURL: installURL, expiresAt: Date(timeIntervalSinceNow: 30)) }
	}

	func redeem(_ authorizationID: String, proof: String, session: PlatformSession) async -> Result<PlatformAuthorizationOutcome, PlatformAuthorizationError> {
		let (attempt, key) = lock.withLock { () -> (Int, Data) in
			defer { redeems += 1 }
			return (redeems, publicKey ?? Data())
		}
		return outcome(attempt, authorizationID, key)
	}

	func cancel(_ authorizationID: String, session: PlatformSession) async {
		lock.withLock { cancelled.append(authorizationID) }
	}

	func readyGrant(teamID: String? = "team_acme") -> @Sendable (Int, String, Data) -> Result<PlatformAuthorizationOutcome, PlatformAuthorizationError> {
		{ _, id, key in
			let sealed = try! RegistryTestSealer.seal(
				["platform": "vercel", "accessToken": "vca_granted", "installationId": "icfg_acme", "teamId": teamID ?? NSNull(), "userId": "u_tolga"],
				authorizationID: id, to: key)
			return .success(.ready(sealed))
		}
	}
}

private struct FakeVercel: VercelClientProtocol {
	var account: Result<VercelAccount, VercelAPIError> = .success(VercelAccount(name: "Acme", slug: "acme"))
	func account(teamID: String?) async -> Result<VercelAccount, VercelAPIError> { account }
	func projects(teamID: String?, ownerID: String) async -> Result<[VercelProject], VercelAPIError> { .success([]) }
	func customEnvironments(projectID: String, teamID: String?) async -> Result<[VercelCustomEnvironment], VercelAPIError> { .success([]) }
	func variables(projectID: String, teamID: String?) async -> Result<VercelVariableList, VercelAPIError> { .failure(.notFound) }
	func create(_ writes: [VercelVariableWrite], projectID: String, teamID: String?) async -> Result<[String: Result<VercelEnvironmentVariable, VercelAPIError>], VercelAPIError> { .failure(.notFound) }
	func replace(_ variableID: String, key: String, value: String, storage: VercelVariableWrite.Storage, projectID: String, teamID: String?) async -> Result<VercelEnvironmentVariable, VercelAPIError> { .failure(.notFound) }
}

/// Plays the browser: after Vercel's page "opens", returns to the Mac's listener.
private func browser(returning query: String, listener: @escaping @Sendable () -> UInt16?) -> @Sendable (URL) async -> Void {
	{ _ in
		guard let port = listener() else { return }
		Task.detached {
			let url = URL(string: "http://127.0.0.1:\(port)\(PlatformConnectionListener.path)?\(query)")!
			_ = try? await URLSession(configuration: .ephemeral).data(from: url)
		}
	}
}

private func failure<Value>(of result: Result<Value, VercelConnectError>) -> VercelConnectError? {
	if case .failure(let error) = result { return error }
	return nil
}

struct VercelConnectorTests {
	private final class Port: @unchecked Sendable {
		private let lock = NSLock()
		private var value: UInt16?
		var port: UInt16? {
			get { lock.withLock { value } }
			set { lock.withLock { value = newValue } }
		}
	}

	private func connector(
		_ authorizations: FakeAuthorizations,
		vercel: FakeVercel = FakeVercel(),
		port: Port
	) -> VercelConnector {
		var connector = VercelConnector(
			authorizations: authorizations,
			listen: {
				let listener = try await PlatformConnectionListener.start()
				port.port = listener.port
				return listener
			},
			client: { _ in vercel })
		connector.pendingDelay = .milliseconds(10)
		return connector
	}

	private let session = platformTestSession(URL(string: "http://localhost:1")!)

	@Test("connecting opens Vercel, waits for the browser, collects the grant once and reads the account")
	func connects() async throws {
		let authorizations = FakeAuthorizations()
		authorizations.outcome = authorizations.readyGrant()
		let port = Port()
		let opened = Port()
		let id = authorizations.id
		let proof = platformTestOneTimeValue()
		let result = await connector(authorizations, port: port).connect(session: session) { url in
			#expect(url == authorizations.installURL)
			opened.port = 1
			await browser(returning: "authorization=\(id)&proof=\(proof)", listener: { port.port })(url)
		}
		let connected = try result.get()
		#expect(opened.port == 1)
		#expect(connected.grant.accessToken == "vca_granted" && connected.grant.teamID == "team_acme")
		#expect(connected.account == VercelAccount(name: "Acme", slug: "acme"))
		#expect(authorizations.cancelledIDs.isEmpty)
	}

	@Test("a result still pending is asked for again before giving up")
	func retriesPending() async throws {
		let authorizations = FakeAuthorizations()
		let ready = authorizations.readyGrant()
		authorizations.outcome = { attempt, id, key in attempt < 2 ? .success(.pending) : ready(attempt, id, key) }
		let port = Port()
		let id = authorizations.id
		let proof = platformTestOneTimeValue()
		let result = await connector(authorizations, port: port).connect(
			session: session, open: browser(returning: "authorization=\(id)&proof=\(proof)", listener: { port.port }))
		#expect(try result.get().grant.installationID == "icfg_acme")
	}

	@Test(
		"each way a connection can end early says why, and the authorization is cancelled when it wasn't collected",
		arguments: ["platform", "proof", "expired", "token", "signedOut"]
	)
	func endsEarly(path: String) async {
		let authorizations = FakeAuthorizations()
		var vercel = FakeVercel()
		var query = "authorization=\(authorizations.id)&proof=\(platformTestOneTimeValue())"
		let expected: VercelConnectError
		switch path {
		case "platform":
			query = "authorization=\(authorizations.id)&error=authorization_cancelled"
			expected = .platform(.cancelledOnPlatform)
		case "proof":
			authorizations.outcome = { _, _, _ in .success(.proofMismatch) }
			expected = .proofRejected
		case "expired":
			authorizations.outcome = { _, _, _ in .success(.expired) }
			expected = .expired
		case "token":
			authorizations.outcome = authorizations.readyGrant()
			vercel.account = .failure(.unauthorized)
			expected = .tokenRejected
		default:
			authorizations.start = { .failure(.signedOut) }
			expected = .signedOut
		}
		let port = Port()
		let finalQuery = query
		let result = await connector(authorizations, vercel: vercel, port: port).connect(
			session: session, open: browser(returning: finalQuery, listener: { port.port }))
		#expect(failure(of: result) == expected)
		try? await Task.sleep(for: .milliseconds(50))
		let shouldCancel = ["platform", "proof", "expired"].contains(path)
		#expect(authorizations.cancelledIDs == (shouldCancel ? [authorizations.id] : []))
	}

	@Test("a name Vercel can't return right now doesn't lose a grant that can't be collected again")
	func keepsGrantWithoutName() async throws {
		let authorizations = FakeAuthorizations()
		authorizations.outcome = authorizations.readyGrant(teamID: nil)
		var vercel = FakeVercel()
		vercel.account = .failure(.transport)
		let port = Port()
		let id = authorizations.id
		let proof = platformTestOneTimeValue()
		let result = await connector(authorizations, vercel: vercel, port: port).connect(
			session: session, open: browser(returning: "authorization=\(id)&proof=\(proof)", listener: { port.port }))
		#expect(try result.get().account == VercelAccount(name: "Personal account", slug: nil))
	}

	@Test("cancelling while the browser is open stops waiting and cancels the authorization")
	func cancelWhileWaiting() async throws {
		let authorizations = FakeAuthorizations()
		let port = Port()
		let task = Task { await connector(authorizations, port: port).connect(session: session) { _ in } }
		while port.port == nil { try await Task.sleep(for: .milliseconds(10)) }
		try await Task.sleep(for: .milliseconds(50))
		task.cancel()
		#expect(failure(of: await task.value) == .cancelled)
		try await Task.sleep(for: .milliseconds(50))
		#expect(authorizations.cancelledIDs == [authorizations.id])
	}
}

@Suite("Registry sessions")
struct PlatformAuthorizationSessionTests {
	@Test("authorization clients made without a session share one, so a connection attempt leaves no session behind")
	func sharesSession() {
		#expect(PlatformAuthorizationClient().session === PlatformAuthorizationClient().session)
		let injected = URLSession(configuration: .ephemeral)
		#expect(PlatformAuthorizationClient(session: injected).session === injected)
	}
}
