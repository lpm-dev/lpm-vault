import CryptoKit
import Foundation
import Testing
@testable import LPMVault

struct PlatformAuthorizationEnvelopeTests {
	/// Sealed by the Registry's own `sealAuthorizationResult` (lib/vault/platform-authorization.js).
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
		let grant = try PlatformAuthorizationEnvelope.open(vector.sealed, as: VercelGrant.self, authorizationID: vector.authorizationID, clientKey: clientKey
		).get()
		#expect(grant.accessToken == "vca_TestToken_0123456789abcdefABCDEF")
		#expect(grant.installationID == "icfg_TestInstallation01")
		#expect(grant.teamID == "team_TestTeam01")
		#expect(grant.userID == "user_TestUser01")
	}

	@Test("a sealed grant doesn't open for another authorization, another key, or after any change")
	func refusesTampering() throws {
		let key = try clientKey
		#expect(PlatformAuthorizationEnvelope.open(vector.sealed, as: VercelGrant.self, authorizationID: UUID().uuidString.lowercased(), clientKey: key) == .failure(.undecryptable))
		#expect(PlatformAuthorizationEnvelope.open(vector.sealed, as: VercelGrant.self, authorizationID: vector.authorizationID, clientKey: P256.KeyAgreement.PrivateKey()) == .failure(.undecryptable))
		var ciphertext = try #require(Data(base64Encoded: vector.sealed.ciphertext))
		ciphertext[ciphertext.startIndex] ^= 0x01
		let changed = PlatformAuthorizationEnvelope.Sealed(
			version: 1, ephemeralPublicKey: vector.sealed.ephemeralPublicKey, nonce: vector.sealed.nonce,
			ciphertext: ciphertext.base64EncodedString())
		#expect(PlatformAuthorizationEnvelope.open(changed, as: VercelGrant.self, authorizationID: vector.authorizationID, clientKey: key) == .failure(.undecryptable))
		let newer = PlatformAuthorizationEnvelope.Sealed(
			version: 2, ephemeralPublicKey: vector.sealed.ephemeralPublicKey, nonce: vector.sealed.nonce, ciphertext: vector.sealed.ciphertext)
		#expect(PlatformAuthorizationEnvelope.open(newer, as: VercelGrant.self, authorizationID: vector.authorizationID, clientKey: key) == .failure(.malformed))
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
		#expect(PlatformAuthorizationEnvelope.open(sealed, as: VercelGrant.self, authorizationID: id, clientKey: key) == .failure(.invalidGrant))
	}

	@Test("a personal account's grant has no team, and the token never prints")
	func personalGrantIsRedacted() throws {
		let key = P256.KeyAgreement.PrivateKey()
		let id = UUID().uuidString.lowercased()
		let sealed = try RegistryTestSealer.seal(
			["platform": "vercel", "accessToken": "vca_secret_value", "installationId": "icfg_1", "teamId": NSNull(), "userId": "u_1"],
			authorizationID: id, to: key.publicKey.x963Representation)
		let grant = try PlatformAuthorizationEnvelope.open(sealed, as: VercelGrant.self, authorizationID: id, clientKey: key).get()
		#expect(grant.teamID == nil)
		var dumped = ""
		dump(grant, to: &dumped)
		for text in [grant.description, String(reflecting: grant), "\(grant)", dumped] {
			#expect(!text.contains("vca_secret_value"))
		}
	}

	/// Sealed by the Registry's own `sealAuthorizationResult` for a Netlify connection, to the same client key.
	private let netlifyVector = (
		authorizationID: "0b7e4f2a-9c1d-4e3f-8a5b-6c7d8e9f0a1b",
		sealed: PlatformAuthorizationEnvelope.Sealed(
			version: 1,
			ephemeralPublicKey: "BLq2Wgs9xVEfkPqJHrPKLE8qV78lIcUClr9U9pJblGUi1QYqPI54nUefhJTgpGfEBaBrHj4nHT+HkIwJ9/xJwzw=",
			nonce: "mSB2C2RB0HQ4cir7",
			ciphertext: "Y7QInSWfLTKcbOmA+eCK8rcfvUuIyCgIhnBVCi/PGPGkEJdagiSzHqNcyui9wvRWVtbU+/l0hSX1HVOOFHvOr+55OxfCzjs0EXEDWPu4tAFGPArxdwiWs2gnjQ=="
		)
	)

	@Test("a Netlify grant the Registry sealed opens with the Mac's key, exactly as sent")
	func opensRegistryNetlifyVector() throws {
		let grant = try PlatformAuthorizationEnvelope.open(
			netlifyVector.sealed, as: NetlifyGrant.self, authorizationID: netlifyVector.authorizationID, clientKey: clientKey
		).get()
		#expect(grant.accessToken == "nfp_TestToken_0123456789abcdefABCDEF")
	}

	@Test("a grant opens only as the platform it names, so one platform's token never passes for another's")
	func opensOnlyAsItsPlatform() throws {
		let key = try clientKey
		#expect(PlatformAuthorizationEnvelope.open(
			vector.sealed, as: NetlifyGrant.self, authorizationID: vector.authorizationID, clientKey: key) == .failure(.invalidGrant))
		#expect(PlatformAuthorizationEnvelope.open(
			netlifyVector.sealed, as: VercelGrant.self, authorizationID: netlifyVector.authorizationID, clientKey: key) == .failure(.invalidGrant))
	}

	@Test(
		"a decrypted grant that isn't a well-formed Netlify grant is refused",
		arguments: [
			#"{"accessToken":"nfp_ok"}"#,
			#"{"platform":"netlify"}"#,
			#"{"platform":"netlify","accessToken":7}"#,
			#"{"platform":"netlify","accessToken":"has space"}"#,
			#"{"platform":"netlify","accessToken":""}"#,
		]
	)
	func refusesMalformedNetlifyGrant(json: String) throws {
		let payload = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
		let key = P256.KeyAgreement.PrivateKey()
		let id = UUID().uuidString.lowercased()
		let sealed = try RegistryTestSealer.seal(payload, authorizationID: id, to: key.publicKey.x963Representation)
		#expect(PlatformAuthorizationEnvelope.open(sealed, as: NetlifyGrant.self, authorizationID: id, clientKey: key) == .failure(.invalidGrant))
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
		let started = try await client.start(.vercel, clientPublicKey: key, loopbackPort: 51_234, session: platformTestSession(route.baseURL)).get()
		#expect(started.id == authorizationID)
		#expect(started.pageURL.absoluteString == installURL)
		let request = try #require(route.requests.first)
		#expect(request.method == "POST" && request.url.path() == "/api/vault/platforms/vercel/authorizations")
		#expect(request.header("Authorization") == "Bearer lpm_session_token")
		#expect(request.json?["publicKey"] as? String == key.base64EncodedString())
		#expect(request.json?["loopbackPort"] as? Int == 51_234)
		let nonce = try #require(request.header(PlatformAuthorizationClient.nonceHeader))
		#expect(nonce.utf8.count == 43)
		_ = try await client.start(.vercel, clientPublicKey: key, loopbackPort: 51_234, session: platformTestSession(route.baseURL)).get()
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
		let result = await client.start(
			.vercel, clientPublicKey: P256.KeyAgreement.PrivateKey().publicKey.x963Representation, loopbackPort: 50_000,
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
		let result = await PlatformAuthorizationClient(session: route.session).start(
			.vercel, clientPublicKey: P256.KeyAgreement.PrivateKey().publicKey.x963Representation, loopbackPort: 50_000,
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
				authorizationID, on: .vercel, proof: proof, session: platformTestSession(route.baseURL))
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
				authorizationID, on: .vercel, proof: platformTestOneTimeValue(), session: platformTestSession(route.baseURL))
			#expect(outcome == .failure(.invalidResponse))
		}
	}

	@Test("cancelling deletes the authorization on its platform's route, with the session", arguments: BrowserPlatform.allCases)
	func cancel(platform: BrowserPlatform) async throws {
		let route = PlatformHTTPStub.registry { _ in PlatformHTTPStub.Reply(status: 204, body: Data()) }
		await PlatformAuthorizationClient(session: route.session).cancel(
			authorizationID, on: platform, session: platformTestSession(route.baseURL))
		let request = try #require(route.requests.first)
		#expect(request.method == "DELETE" && request.url.path() == "/api/vault/platforms/\(platform.rawValue)/authorizations/\(authorizationID)")
		#expect(request.header("Authorization") == "Bearer lpm_session_token")
	}

	/// Netlify's Authorize page as the Registry's `netlifyAuthorizeUrl` makes it, for a Registry at `registry`.
	private func netlifyPage(
		_ registry: URL,
		clientID: String = "-pXkF9rearrWFTVbHyDrWRw_w2Lvg_xHPgFE4B06N-U",
		responseType: String = "code",
		redirect: String? = nil,
		state: String = platformTestOneTimeValue(),
		extra: String = ""
	) -> String {
		let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
		func encoded(_ text: String) -> String { text.addingPercentEncoding(withAllowedCharacters: unreserved)! }
		let callback = redirect ?? "\(registry.absoluteString)/api/vault/platforms/netlify/callback"
		return "https://app.netlify.com/authorize?client_id=\(encoded(clientID))&response_type=\(responseType)"
			+ "&redirect_uri=\(encoded(callback))&state=\(state)\(extra)"
	}

	/// The Registry a stubbed request reached.
	private func registry(of request: PlatformHTTPStub.Request) -> URL {
		URL(string: "http://\(request.url.host() ?? ""):\(request.url.port ?? 0)")!
	}

	@Test("starting a Netlify connection uses Netlify's route and opens Netlify's Authorize page, which returns the code to this Registry")
	func startNetlify() async throws {
		let state = platformTestOneTimeValue()
		let route = PlatformHTTPStub.registry { request in
			startReply(request, overrides: ["platform": "netlify", "installUrl": netlifyPage(registry(of: request), state: state)])
		}
		let started = try await PlatformAuthorizationClient(session: route.session).start(
			.netlify, clientPublicKey: P256.KeyAgreement.PrivateKey().publicKey.x963Representation, loopbackPort: 51_234,
			session: platformTestSession(route.baseURL)
		).get()
		#expect(started.id == authorizationID)
		#expect(started.pageURL.absoluteString == netlifyPage(route.baseURL, state: state))
		#expect(route.requests.first?.url.path() == "/api/vault/platforms/netlify/authorizations")
	}

	@Test(
		"a Netlify start answer about Vercel, or whose page isn't LPM Vault's Authorize page returning the code to this Registry, is refused",
		arguments: [
			"signed-for-vercel", "vercel-page", "http", "host", "path", "fragment", "response-type", "redirect-elsewhere",
			"redirect-vercel", "redirect-missing", "extra", "duplicate-state", "client-id", "state",
		]
	)
	func refusesUntrustedNetlifyStart(change: String) async throws {
		let route = PlatformHTTPStub.registry { request in
			let registry = registry(of: request)
			let page: String = switch change {
			case "vercel-page": installURL
			case "http": netlifyPage(registry).replacingOccurrences(of: "https://", with: "http://")
			case "host": netlifyPage(registry).replacingOccurrences(of: "app.netlify.com", with: "app.netlify.com.example")
			case "path": netlifyPage(registry).replacingOccurrences(of: "/authorize?", with: "/authorize/other?")
			case "fragment": netlifyPage(registry) + "#top"
			case "response-type": netlifyPage(registry, responseType: "token")
			case "redirect-elsewhere": netlifyPage(registry, redirect: "https://elsewhere.example/api/vault/platforms/netlify/callback")
			case "redirect-vercel": netlifyPage(registry, redirect: "\(registry.absoluteString)/api/vault/platforms/vercel/callback")
			case "redirect-missing": netlifyPage(registry).replacingOccurrences(of: "&redirect_uri=", with: "&redirect=")
			case "extra": netlifyPage(registry, extra: "&scope=all")
			case "duplicate-state": netlifyPage(registry, extra: "&state=\(platformTestOneTimeValue())")
			case "client-id": netlifyPage(registry, clientID: "a/b")
			case "state": netlifyPage(registry, state: "short")
			default: netlifyPage(registry)
			}
			return startReply(request, overrides: ["platform": change == "signed-for-vercel" ? "vercel" : "netlify", "installUrl": page])
		}
		let result = await PlatformAuthorizationClient(session: route.session).start(
			.netlify, clientPublicKey: P256.KeyAgreement.PrivateKey().publicKey.x963Representation, loopbackPort: 50_000,
			session: platformTestSession(route.baseURL))
		#expect(result == .failure(.invalidResponse))
	}

	@Test("redeeming a Netlify connection uses Netlify's route, and an answer signed about Vercel is refused")
	func redeemNetlify() async throws {
		for (signedPlatform, expected) in [("netlify", Result<PlatformAuthorizationOutcome, PlatformAuthorizationError>.success(.pending)), ("vercel", .failure(.invalidResponse))] {
			let route = PlatformHTTPStub.registry { request in
				RegistryTestSigner.signed(202, [
					"requestNonce": request.header(PlatformAuthorizationClient.nonceHeader) ?? "", "principalId": platformTestPrincipal,
					"platform": signedPlatform, "authorizationId": authorizationID, "status": "pending",
				])
			}
			let outcome = await PlatformAuthorizationClient(session: route.session).redeem(
				authorizationID, on: .netlify, proof: platformTestOneTimeValue(), session: platformTestSession(route.baseURL))
			#expect(outcome == expected, "signed about \(signedPlatform)")
			#expect(route.requests.first?.url.path() == "/api/vault/platforms/netlify/authorizations/\(authorizationID)/redeem")
		}
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
	private func get(_ port: UInt16, _ query: String, on platform: BrowserPlatform = .vercel) async throws -> (Int, String) {
		let url = try #require(URL(string: "http://127.0.0.1:\(port)\(PlatformConnectionListener.path(for: platform))?\(query)"))
		let (data, response) = try await URLSession(configuration: testSessionConfiguration()).data(from: url)
		return ((response as? HTTPURLResponse)?.statusCode ?? 0, String(decoding: data, as: UTF8.self))
	}

	@Test("only the expected authorization ends the wait; anything else gets a page and is ignored")
	func waitsForExpectedAuthorization() async throws {
		let listener = try await PlatformConnectionListener.start(for: .vercel)
		defer { listener.stop() }
		let id = UUID().uuidString.lowercased()
		listener.expect(id, from: platformTestRegistry)
		let proof = platformTestOneTimeValue()
		let other = try await get(listener.port, platformTestReturn(authorization: UUID().uuidString.lowercased(), proof: proof))
		#expect(other.0 == 400 && other.1.contains("Start from LPM Vault"))
		async let completion = listener.completion(until: Date(timeIntervalSinceNow: testWaitSeconds))
		let page = try await get(listener.port, platformTestReturn(authorization: id, proof: proof, next: "https://vercel.com/dashboard"))
		#expect(page.0 == 200 && page.1.contains("Return to LPM Vault") && page.1.contains("href=\"https://vercel.com/dashboard\""))
		#expect(try await completion == .proof(proof))
	}

	@Test("a return the Registry didn't sign, a failure or a made-up proof, doesn't end the wait")
	func ignoresUnsignedReturns() async throws {
		let listener = try await PlatformConnectionListener.start(for: .vercel)
		defer { listener.stop() }
		let id = UUID().uuidString.lowercased()
		listener.expect(id, from: platformTestRegistry)
		let completion = Task { try await listener.completion(until: Date(timeIntervalSinceNow: testWaitSeconds)) }
		let forgedFailure = try await get(listener.port, "authorization=\(id)&error=authorization_cancelled")
		let forgedProof = try await get(listener.port, "authorization=\(id)&proof=\(platformTestOneTimeValue())")
		let signed = platformTestReturn(authorization: id, error: "authorization_cancelled")
		let swapped = try await get(listener.port, signed.replacingOccurrences(of: "authorization_cancelled", with: "platform_rejected"))
		#expect([forgedFailure, forgedProof, swapped].allSatisfy { $0.1.contains("Start from LPM Vault") })
		completion.cancel()
		await #expect(throws: CancellationError.self, "Still waiting, so only cancelling ends it") { try await completion.value }
	}

	@Test("the Registry's signature, made as its tests make it, is accepted for a local Registry and not for lpm.dev")
	func registrySignatureVector() throws {
		let id = "5f0c2a8e-1b3d-4c5e-8f9a-0b1c2d3e4f5a"
		let signature = "FIExkk9QV1xikHTWmbQAPQ5A-a4aFs8P3L-8q05nWbafm9cWlN6mhGDXm7L7ILsEedeJDZoiYRPSijRSdanzBQ"
		let line = "GET \(PlatformConnectionListener.path(for: .vercel))?authorization=\(id)&error=authorization_cancelled&key=vault-test-rfc8032&signature=\(signature)"
		let request = try #require(PlatformConnectionListener.parse(Data("\(line) HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".utf8), for: .vercel))
		#expect(request.completion == .failure(.cancelledOnPlatform))
		func verifies(_ registry: URL) -> Bool {
			PinnedSessionDelegate.verifyRegistrySignature(
				request.signature, keyID: request.keyID, message: request.signedMessage, registry: registry)
		}
		#expect(verifies(platformTestRegistry))
		#expect(!verifies(URL(string: "https://lpm.dev")!), "The test key is never trusted for lpm.dev")
	}

	@Test("a failure from the Registry ends the wait with its reason")
	func failureEndsWait() async throws {
		let listener = try await PlatformConnectionListener.start(for: .vercel)
		defer { listener.stop() }
		let id = UUID().uuidString.lowercased()
		listener.expect(id, from: platformTestRegistry)
		let page = try await get(listener.port, platformTestReturn(authorization: id, error: "authorization_cancelled"))
		#expect(page.0 == 400 && page.1.contains("cancelled on Vercel"))
		#expect(try await listener.completion(until: Date(timeIntervalSinceNow: testWaitSeconds)) == .failure(.cancelledOnPlatform))
	}

	@Test("waiting ends at the deadline, or when the task is cancelled")
	func deadlineAndCancellation() async throws {
		let listener = try await PlatformConnectionListener.start(for: .vercel)
		await #expect(throws: PlatformConnectionListener.ListenerError.timedOut) {
			try await listener.completion(until: Date(timeIntervalSinceNow: 0.2))
		}
		let waiting = try await PlatformConnectionListener.start(for: .vercel)
		let task = Task { try await waiting.completion(until: Date(timeIntervalSinceNow: testWaitSeconds)) }
		try #require(try await waitUntil { waiting.isWaiting })
		task.cancel()
		await #expect(throws: CancellationError.self) { try await task.value }
	}

	@Test("a Netlify listener takes returns only at Netlify's path, its pages name Netlify, and it offers no link onward")
	func netlifyListener() async throws {
		let listener = try await PlatformConnectionListener.start(for: .netlify)
		defer { listener.stop() }
		let id = UUID().uuidString.lowercased()
		listener.expect(id, from: platformTestRegistry)
		let proof = platformTestOneTimeValue()
		let completion = Task { try await listener.completion(until: Date(timeIntervalSinceNow: testWaitSeconds)) }
		let atVercel = try await get(listener.port, platformTestReturn(authorization: id, proof: proof), on: .vercel)
		#expect(atVercel.0 == 400 && atVercel.1.contains("Connect Netlify from"))
		let page = try await get(listener.port, platformTestReturn(authorization: id, proof: proof, next: "https://vercel.com/dashboard"), on: .netlify)
		#expect(page.0 == 200 && page.1.contains("Netlify approved") && !page.1.contains("vercel.com"))
		#expect(try await completion.value == .proof(proof))
		let refused = PlatformConnectionListener.page(for: .failure(.cancelledOnPlatform), on: .netlify, next: nil)
		#expect(refused.contains("Netlify wasn") && refused.contains("The connection was cancelled on Netlify."))
	}

	@Test("requests that aren't a return from Vercel are not completions")
	func parsing() throws {
		let id = UUID().uuidString.lowercased()
		let proof = platformTestOneTimeValue()
		func request(_ line: String) -> Data { Data("\(line) HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".utf8) }
		let path = PlatformConnectionListener.path(for: .vercel)
		let signed = platformTestReturn(authorization: id, proof: proof)
		#expect(PlatformConnectionListener.parse(request("GET \(path)?\(signed)"), for: .vercel)?.completion == .proof(proof))
		let signature = "&key=vault-test-rfc8032&signature=\(String(repeating: "A", count: 86))"
		for line in [
			"POST \(path)?\(signed)",
			"GET /callback?\(signed)",
			"GET \(path)?authorization=\(id)\(signature)",
			"GET \(path)?authorization=\(id)&proof=\(proof)&error=server_error\(signature)",
			"GET \(path)?authorization=\(id.uppercased())&proof=\(proof)\(signature)",
			"GET \(path)?authorization=\(id)&proof=short\(signature)",
			"GET \(path)?authorization=\(id)&error=Bad%20Code\(signature)",
			"GET \(path)?authorization=\(id)&proof=\(proof)",
			"GET \(path)?authorization=\(id)&proof=\(proof)&key=bad%20key&signature=x",
		] {
			#expect(PlatformConnectionListener.parse(request(line), for: .vercel) == nil, "\(line)")
		}
		let badlyEncoded = PlatformConnectionListener.parse(request("GET \(path)?\(signed)&next=%zz"), for: .vercel)
		#expect(badlyEncoded?.completion == .proof(proof) && badlyEncoded?.next == nil)
		for next in ["https://evil.example/", "http://vercel.com/", "https://user@vercel.com/", "https://vercel.com:8443/"] {
			let query = platformTestReturn(authorization: id, proof: proof, next: next)
			#expect(PlatformConnectionListener.parse(request("GET \(path)?\(query)"), for: .vercel)?.next == nil)
		}
	}
}

/// A Registry that answers from closures and records each call's platform,
/// and what was cancelled.
private final class FakeAuthorizations: PlatformAuthorizationClientProtocol, @unchecked Sendable {
	private let lock = NSLock()
	private var publicKey: Data?
	private var cancelled: [String] = []
	private var calls: [String] = []
	private var redeems = 0
	let id = UUID().uuidString.lowercased()
	var start: (@Sendable () -> Result<Void, PlatformAuthorizationError>) = { .success(()) }
	var outcome: (@Sendable (_ attempt: Int, _ id: String, _ key: Data) -> Result<PlatformAuthorizationOutcome, PlatformAuthorizationError>) = { _, _, _ in .success(.missing) }
	/// How long after starting the authorization expires.
	var expiresIn: TimeInterval = 30
	let pageURL: URL

	init(pageURL: URL = URL(string: "https://vercel.com/integrations/lpm-vault/new?state=\(platformTestOneTimeValue())")!) {
		self.pageURL = pageURL
	}

	var cancelledIDs: [String] { lock.withLock { cancelled } }
	/// Each call as `start`, `redeem` or `cancel` with its platform, such as `start vercel`.
	var platformCalls: [String] { lock.withLock { calls } }

	func start(_ platform: BrowserPlatform, clientPublicKey: Data, loopbackPort: UInt16, session: PlatformSession) async -> Result<StartedPlatformAuthorization, PlatformAuthorizationError> {
		lock.withLock {
			publicKey = clientPublicKey
			calls.append("start \(platform.rawValue)")
		}
		return start().map { StartedPlatformAuthorization(id: id, pageURL: pageURL, expiresAt: Date(timeIntervalSinceNow: expiresIn)) }
	}

	func redeem(_ authorizationID: String, on platform: BrowserPlatform, proof: String, session: PlatformSession) async -> Result<PlatformAuthorizationOutcome, PlatformAuthorizationError> {
		let (attempt, key) = lock.withLock { () -> (Int, Data) in
			defer { redeems += 1 }
			calls.append("redeem \(platform.rawValue)")
			return (redeems, publicKey ?? Data())
		}
		return outcome(attempt, authorizationID, key)
	}

	func cancel(_ authorizationID: String, on platform: BrowserPlatform, session: PlatformSession) async {
		lock.withLock {
			cancelled.append(authorizationID)
			calls.append("cancel \(platform.rawValue)")
		}
	}

	func readyGrant(teamID: String? = "team_acme") -> @Sendable (Int, String, Data) -> Result<PlatformAuthorizationOutcome, PlatformAuthorizationError> {
		ready(["platform": "vercel", "accessToken": "vca_granted", "installationId": "icfg_acme", "teamId": teamID ?? NSNull(), "userId": "u_tolga"])
	}

	func readyNetlifyGrant() -> @Sendable (Int, String, Data) -> Result<PlatformAuthorizationOutcome, PlatformAuthorizationError> {
		ready(["platform": "netlify", "accessToken": "nfp_granted"])
	}

	func readyGitHubGrant() -> @Sendable (Int, String, Data) -> Result<PlatformAuthorizationOutcome, PlatformAuthorizationError> {
		ready([
			"platform": "github", "accessToken": "ghu_granted", "accessTokenExpiresIn": 28_800,
			"refreshToken": "ghr_granted", "refreshTokenExpiresIn": 15_897_600, "appSlug": "lpm-vault",
		])
	}

	private func ready(_ payload: [String: Any]) -> @Sendable (Int, String, Data) -> Result<PlatformAuthorizationOutcome, PlatformAuthorizationError> {
		let json = try! JSONSerialization.data(withJSONObject: payload)
		return { _, id, key in
			let payload = try! JSONSerialization.jsonObject(with: json) as! [String: Any]
			return .success(.ready(try! RegistryTestSealer.seal(payload, authorizationID: id, to: key)))
		}
	}
}

private struct FakeVercel: VercelClientProtocol {
	var account: Result<VercelAccount, VercelAPIError> = .success(VercelAccount(name: "Acme", slug: "acme"))
	func account(teamID: String?) async -> Result<VercelAccount, VercelAPIError> { account }
	func projects(teamID: String?) async -> Result<[VercelProject], VercelAPIError> { .success([]) }
	func customEnvironments(projectID: String, teamID: String?) async -> Result<[VercelCustomEnvironment], VercelAPIError> { .success([]) }
	func variables(projectID: String, teamID: String?) async -> Result<VercelVariableList, VercelAPIError> { .failure(.notFound) }
	func create(_ writes: [VercelVariableWrite], projectID: String, teamID: String?) async -> Result<[String: Result<VercelEnvironmentVariable, VercelAPIError>], VercelAPIError> { .failure(.notFound) }
	func replace(_ variableID: String, key: String, value: String, storage: VercelVariableWrite.Storage, projectID: String, teamID: String?) async -> Result<VercelEnvironmentVariable, VercelAPIError> { .failure(.notFound) }
}

/// Plays the browser: `delay` after the platform's page "opens", returns to the Mac's listener.
private func browser(
	returning query: String,
	on platform: BrowserPlatform = .vercel,
	after delay: Duration = .zero,
	listener: @escaping @Sendable () -> UInt16?
) -> @Sendable (URL) async -> Void {
	{ _ in
		guard let port = listener() else { return }
		Task.detached {
			try? await Task.sleep(for: delay)
			let url = URL(string: "http://127.0.0.1:\(port)\(PlatformConnectionListener.path(for: platform))?\(query)")!
			_ = try? await URLSession(configuration: testSessionConfiguration()).data(from: url)
		}
	}
}

private func failure<Value>(of result: Result<Value, BrowserConnectError>) -> BrowserConnectError? {
	if case .failure(let error) = result { return error }
	return nil
}

private final class Port: @unchecked Sendable {
	private let lock = NSLock()
	private var started: PlatformConnectionListener?
	/// The listener the connection started, once it has.
	var listener: PlatformConnectionListener? {
		get { lock.withLock { started } }
		set { lock.withLock { started = newValue } }
	}
	var port: UInt16? { listener?.port }
}

/// A browser authorization against `authorizations` whose listener's port lands in `port`.
private func browserAuthorization(_ authorizations: FakeAuthorizations, port: Port) -> BrowserAuthorization {
	var authorization = BrowserAuthorization(authorizations: authorizations, listen: { platform in
		let listener = try await PlatformConnectionListener.start(for: platform)
		port.listener = listener
		return listener
	})
	authorization.pendingDelay = .milliseconds(10)
	return authorization
}

struct VercelConnectorTests {
	private func connector(
		_ authorizations: FakeAuthorizations,
		vercel: FakeVercel = FakeVercel(),
		port: Port
	) -> VercelConnector {
		VercelConnector(authorization: browserAuthorization(authorizations, port: port), client: { _ in vercel })
	}

	private let session = platformTestSession(URL(string: "http://localhost:1")!)

	@Test("connecting opens Vercel, waits for the browser, collects the grant once and reads the account")
	func connects() async throws {
		let authorizations = FakeAuthorizations()
		authorizations.outcome = authorizations.readyGrant()
		let port = Port()
		let opened = OpenedPages()
		let id = authorizations.id
		let proof = platformTestOneTimeValue()
		let result = await connector(authorizations, port: port).connect(session: session) { url in
			opened.append(url)
			await browser(returning: platformTestReturn(authorization: id, proof: proof), listener: { port.port })(url)
		}
		let connected = try result.get()
		#expect(opened.urls == [authorizations.pageURL])
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
			session: session, open: browser(returning: platformTestReturn(authorization: id, proof: proof), listener: { port.port }))
		#expect(try result.get().grant.installationID == "icfg_acme")
	}

	@Test(
		"each way a connection can end early says why, and the authorization is cancelled when it wasn't collected",
		arguments: ["platform", "proof", "expired", "token", "signedOut"]
	)
	func endsEarly(path: String) async throws {
		let authorizations = FakeAuthorizations()
		var vercel = FakeVercel()
		var query = platformTestReturn(authorization: authorizations.id, proof: platformTestOneTimeValue())
		let expected: BrowserConnectError
		switch path {
		case "platform":
			query = platformTestReturn(authorization: authorizations.id, error: "authorization_cancelled")
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
		if ["platform", "proof", "expired"].contains(path) {
			#expect(try await waitUntil { authorizations.cancelledIDs == [authorizations.id] })
		} else {
			try await quietPeriod()
			#expect(authorizations.cancelledIDs.isEmpty)
		}
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
			session: session, open: browser(returning: platformTestReturn(authorization: id, proof: proof), listener: { port.port }))
		#expect(try result.get().account == VercelAccount(name: "Personal account", slug: nil))
	}

	@Test("cancelling while the browser is open stops waiting and cancels the authorization")
	func cancelWhileWaiting() async throws {
		let authorizations = FakeAuthorizations()
		let port = Port()
		let task = Task { await connector(authorizations, port: port).connect(session: session) { _ in } }
		try #require(try await waitUntil { port.listener?.isWaiting == true })
		task.cancel()
		#expect(failure(of: await task.value) == .cancelled)
		#expect(try await waitUntil { authorizations.cancelledIDs == [authorizations.id] })
	}
}

/// A Netlify that answers each read of the user from a script, whose last answer repeats.
private final class ScriptedNetlify: NetlifyClientProtocol, @unchecked Sendable {
	private let lock = NSLock()
	private var answers: [Result<NetlifyUser, NetlifyAPIError>]
	private var reads = 0
	private var received: [String] = []

	init(_ answers: [Result<NetlifyUser, NetlifyAPIError>]) {
		self.answers = answers
	}

	var userReads: Int { lock.withLock { reads } }
	/// The tokens clients were made with.
	var tokens: [String] { lock.withLock { received } }

	func client(_ token: String) -> any NetlifyClientProtocol {
		lock.withLock { received.append(token) }
		return self
	}

	func user() async -> Result<NetlifyUser, NetlifyAPIError> {
		lock.withLock {
			reads += 1
			return answers.count > 1 ? answers.removeFirst() : answers[0]
		}
	}

	func sites() async -> Result<[NetlifySite], NetlifyAPIError> { .failure(.notFound) }
	func variables(siteID: String, teamID: String) async -> Result<[NetlifyVariable], NetlifyAPIError> { .failure(.notFound) }
	func variable(_ key: String, siteID: String, teamID: String) async -> Result<NetlifyVariable?, NetlifyAPIError> { .failure(.notFound) }
	func create(_ write: NetlifyVariableWrite, siteID: String, teamID: String) async -> Result<NetlifyVariable, NetlifyAPIError> { .failure(.notFound) }
	func setValue(_ write: NetlifyVariableWrite, siteID: String, teamID: String) async -> Result<NetlifyVariable, NetlifyAPIError> { .failure(.notFound) }
}

private final class OpenedPages: @unchecked Sendable {
	private let lock = NSLock()
	private var opened: [URL] = []
	var urls: [URL] { lock.withLock { opened } }
	func append(_ url: URL) { lock.withLock { opened.append(url) } }
}

struct NetlifyConnectorTests {
	private static let tolga = NetlifyUser(id: "5f1a2b3c4d5e6f7a8b9c0d1e", name: "Tolga Ergin", email: "tolga@example.com")
	private static let authorizePage = URL(string:
		"https://app.netlify.com/authorize?client_id=lpm_vault&response_type=code&redirect_uri=http%3A%2F%2Flocalhost%3A1%2Fapi%2Fvault%2Fplatforms%2Fnetlify%2Fcallback&state=\(platformTestOneTimeValue())")!

	private let session = platformTestSession(URL(string: "http://localhost:1")!)

	/// Connects against `authorizations`, with a browser that returns `query` for the authorization to the listener.
	private func connect(
		_ authorizations: FakeAuthorizations,
		netlify: ScriptedNetlify = ScriptedNetlify([.success(tolga)]),
		query: ((String) -> String)? = nil,
		retryDelay: Duration = .milliseconds(5),
		browserDelay: Duration = .zero,
		opened: OpenedPages? = nil
	) async -> Result<NetlifyConnection, BrowserConnectError> {
		let port = Port()
		var connector = NetlifyConnector(authorization: browserAuthorization(authorizations, port: port), client: netlify.client)
		connector.retryDelay = retryDelay
		let returning = query?(authorizations.id) ?? platformTestReturn(authorization: authorizations.id, proof: platformTestOneTimeValue())
		let browser = browser(returning: returning, on: .netlify, after: browserDelay, listener: { port.port })
		return await connector.connect(session: session) { url in
			opened?.append(url)
			await browser(url)
		}
	}

	@Test("connecting opens Netlify's Authorize page, waits for the browser at Netlify's path, collects the token once and reads whose it is")
	func connects() async throws {
		let authorizations = FakeAuthorizations(pageURL: Self.authorizePage)
		authorizations.outcome = authorizations.readyNetlifyGrant()
		let netlify = ScriptedNetlify([.success(Self.tolga)])
		let opened = OpenedPages()
		let connection = try await connect(authorizations, netlify: netlify, opened: opened).get()
		#expect(opened.urls == [Self.authorizePage])
		#expect(connection == NetlifyConnection(user: Self.tolga, token: "nfp_granted"))
		#expect(netlify.tokens == ["nfp_granted"])
		#expect(authorizations.platformCalls == ["start netlify", "redeem netlify"])
		#expect(authorizations.cancelledIDs.isEmpty)
	}

	@Test("without an LPM session nothing opens, and the message says to sign in")
	func signedOut() async {
		let authorizations = FakeAuthorizations(pageURL: Self.authorizePage)
		authorizations.start = { .failure(.signedOut) }
		let opened = OpenedPages()
		let result = await connect(authorizations, opened: opened)
		#expect(failure(of: result) == .signedOut)
		#expect(failure(of: result)?.message(for: .netlify) == "Sign in to LPM to connect Netlify.")
		#expect(opened.urls.isEmpty)
	}

	@Test("a Vercel grant can't complete a Netlify connection, and its token is never used")
	func refusesVercelGrant() async {
		let authorizations = FakeAuthorizations(pageURL: Self.authorizePage)
		authorizations.outcome = authorizations.readyGrant()
		let netlify = ScriptedNetlify([.success(Self.tolga)])
		#expect(failure(of: await connect(authorizations, netlify: netlify)) == .invalidResponse)
		#expect(netlify.tokens.isEmpty && netlify.userReads == 0)
	}

	@Test("refusing on Netlify ends the connection naming Netlify, and the authorization is cancelled on Netlify's route")
	func refusedOnNetlify() async throws {
		let authorizations = FakeAuthorizations(pageURL: Self.authorizePage)
		let result = await connect(authorizations, query: { platformTestReturn(authorization: $0, error: "authorization_cancelled") })
		#expect(failure(of: result) == .platform(.cancelledOnPlatform))
		#expect(failure(of: result)?.message(for: .netlify) == "The connection was cancelled on Netlify.")
		#expect(try await waitUntil { authorizations.cancelledIDs == [authorizations.id] })
		#expect(authorizations.platformCalls == ["start netlify", "cancel netlify"])
	}

	@Test("the user is read again when Netlify couldn't answer, since the token can't be collected again")
	func retriesUser() async throws {
		let recovering = FakeAuthorizations(pageURL: Self.authorizePage)
		recovering.outcome = recovering.readyNetlifyGrant()
		let netlify = ScriptedNetlify([.failure(.transport), .failure(.server(503)), .success(Self.tolga)])
		#expect(try await connect(recovering, netlify: netlify).get().user == Self.tolga)
		#expect(netlify.userReads == 3)

		let down = FakeAuthorizations(pageURL: Self.authorizePage)
		down.outcome = down.readyNetlifyGrant()
		let unreachable = ScriptedNetlify([.failure(.rateLimited(until: Date())), .failure(.transport)])
		#expect(failure(of: await connect(down, netlify: unreachable)) == .transport)
		#expect(unreachable.userReads == 3)
	}

	@Test(
		"a token Netlify refuses at once isn't kept, and neither is one whose user Netlify doesn't say",
		arguments: [
			(NetlifyAPIError.unauthorized, BrowserConnectError.tokenRejected), (.forbidden, .tokenRejected),
			(.invalidResponse, .accountUnreadable), (.notFound, .accountUnreadable), (.rejected(status: 422), .accountUnreadable),
		]
	)
	func refusedUser(error: NetlifyAPIError, expected: BrowserConnectError) async {
		let authorizations = FakeAuthorizations(pageURL: Self.authorizePage)
		authorizations.outcome = authorizations.readyNetlifyGrant()
		let netlify = ScriptedNetlify([.failure(error)])
		#expect(failure(of: await connect(authorizations, netlify: netlify)) == expected)
		#expect(netlify.userReads == 1)
	}

	@Test("a rate limit on reading the user is waited out until Netlify says it lifts, so the grant isn't lost")
	func waitsOutUserRateLimit() async throws {
		let authorizations = FakeAuthorizations(pageURL: Self.authorizePage)
		authorizations.outcome = authorizations.readyNetlifyGrant()
		let lifts = Date(timeIntervalSinceNow: 0.4)
		let netlify = ScriptedNetlify([.failure(.rateLimited(until: lifts)), .success(Self.tolga)])
		#expect(try await connect(authorizations, netlify: netlify).get().user == Self.tolga)
		#expect(Date() >= lifts)
		#expect(netlify.userReads == 2)
	}

	@Test("a rate limit that lifts later than LPM Vault waits, or keeps applying, says Netlify is limiting requests")
	func userRateLimited() async {
		let later = FakeAuthorizations(pageURL: Self.authorizePage)
		later.outcome = later.readyNetlifyGrant()
		let limited = ScriptedNetlify([.failure(.rateLimited(until: Date(timeIntervalSinceNow: 3_600)))])
		let result = await connect(later, netlify: limited)
		#expect(failure(of: result) == .platformRateLimited)
		#expect(failure(of: result)?.message(for: .netlify) == "Netlify is limiting requests. Wait a minute, then connect again.")
		#expect(limited.userReads == 1)

		let again = FakeAuthorizations(pageURL: Self.authorizePage)
		again.outcome = again.readyNetlifyGrant()
		let stays = ScriptedNetlify([.failure(.rateLimited(until: Date()))])
		#expect(failure(of: await connect(again, netlify: stays)) == .platformRateLimited)
		#expect(stays.userReads == 3)
	}

	@Test("cancelling while the user is about to be read again, or a rate limit is waited out, stops at once", .hangLimit)
	func cancelWhileRetrying() async throws {
		// Each wait outlasts the test's time limit, or ends in a second read, unless cancelling stops it.
		let longestRateLimit = Double(NetlifyHTTP.maximumRateLimitWait.components.seconds) - 1
		for answer: NetlifyAPIError in [.transport, .rateLimited(until: Date(timeIntervalSinceNow: longestRateLimit))] {
			let authorizations = FakeAuthorizations(pageURL: Self.authorizePage)
			authorizations.outcome = authorizations.readyNetlifyGrant()
			let netlify = ScriptedNetlify([.failure(answer)])
			let task = Task { await connect(authorizations, netlify: netlify, retryDelay: .seconds(3_600)) }
			try #require(try await waitUntil { netlify.userReads == 1 })
			task.cancel()
			#expect(failure(of: await task.value) == .cancelled)
			#expect(netlify.userReads == 1)
		}
	}

	@Test("a browser coming back just after the authorization expires, from a code the Registry claimed in time, still connects")
	func returnsAfterExpiry() async throws {
		let authorizations = FakeAuthorizations(pageURL: Self.authorizePage)
		authorizations.expiresIn = 0.05
		authorizations.outcome = authorizations.readyNetlifyGrant()
		let connection = try await connect(authorizations, browserDelay: .milliseconds(300)).get()
		#expect(connection.user == Self.tolga)
		#expect(authorizations.cancelledIDs.isEmpty)
	}
}

/// A GitHub that answers each read of the user from a script, whose last answer repeats.
private final class ScriptedGitHub: GitHubClientProtocol, @unchecked Sendable {
	private let lock = NSLock()
	private var answers: [Result<GitHubUser, GitHubAPIError>]
	private var reads = 0
	private var received: [String] = []

	init(_ answers: [Result<GitHubUser, GitHubAPIError>]) {
		self.answers = answers
	}

	var userReads: Int { lock.withLock { reads } }
	var tokens: [String] { lock.withLock { received } }

	func client(_ token: String) -> any GitHubClientProtocol {
		lock.withLock { received.append(token) }
		return self
	}

	func user() async -> Result<GitHubUser, GitHubAPIError> {
		lock.withLock {
			reads += 1
			return answers.count > 1 ? answers.removeFirst() : answers[0]
		}
	}
}

struct GitHubConnectorTests {
	private static let octocat = GitHubUser(id: "583231", login: "octocat", name: "The Octocat")
	private static let authorizePage = URL(string: "https://github.com/login/oauth/authorize?client_id=Iv23li&state=\(platformTestOneTimeValue())")!
	private let session = platformTestSession(URL(string: "http://localhost:1")!)

	private func connect(
		_ authorizations: FakeAuthorizations,
		github: ScriptedGitHub = ScriptedGitHub([.success(octocat)]),
		query: ((String) -> String)? = nil,
		clock: SleepingTestClock = SleepingTestClock()
	) async -> Result<GitHubConnection, BrowserConnectError> {
		let port = Port()
		var connector = GitHubConnector(authorization: browserAuthorization(authorizations, port: port), client: github.client)
		connector.retryDelay = .milliseconds(5)
		connector.now = { clock.date }
		connector.sleep = { clock.sleep($0) }
		let returning = query?(authorizations.id) ?? platformTestReturn(authorization: authorizations.id, proof: platformTestOneTimeValue())
		return await connector.connect(session: session, open: browser(returning: returning, on: .github, listener: { port.port }))
	}

	@Test("connecting opens GitHub's page, waits for the browser at GitHub's path, collects the tokens once and reads whose they are")
	func connects() async throws {
		let authorizations = FakeAuthorizations(pageURL: Self.authorizePage)
		authorizations.outcome = authorizations.readyGitHubGrant()
		let github = ScriptedGitHub([.success(Self.octocat)])
		let received = Date(timeIntervalSince1970: 1_760_000_123)
		let connection = try await connect(authorizations, github: github, clock: SleepingTestClock(received)).get()
		#expect(connection.user == Self.octocat && connection.appSlug == "lpm-vault" && connection.receivedAt == received)
		#expect(connection.tokens.accessToken == "ghu_granted")
		#expect(connection.tokens.expiry == .init(accessTokenLifetime: 28_800, refreshToken: "ghr_granted", refreshTokenLifetime: 15_897_600))
		#expect(github.tokens == ["ghu_granted"])
		#expect(authorizations.platformCalls == ["start github", "redeem github"])
	}

	@Test("another platform's grant can't complete a GitHub connection, and its token is never used")
	func refusesOtherGrant() async {
		let authorizations = FakeAuthorizations(pageURL: Self.authorizePage)
		authorizations.outcome = authorizations.readyNetlifyGrant()
		let github = ScriptedGitHub([.success(Self.octocat)])
		#expect(failure(of: await connect(authorizations, github: github)) == .invalidResponse)
		#expect(github.tokens.isEmpty)
	}

	@Test("an approval that expired before the Registry exchanged it says so, naming GitHub")
	func approvalExpired() async throws {
		let authorizations = FakeAuthorizations(pageURL: Self.authorizePage)
		let result = await connect(authorizations, query: { platformTestReturn(authorization: $0, error: "authorization_expired") })
		#expect(failure(of: result) == .platform(.approvalExpired))
		#expect(failure(of: result)?.message(for: .github) == "Your approval on GitHub expired before it could be used. Connect again.")
	}

	@Test("the user is read again when GitHub couldn't answer or was limiting requests, since the tokens can't be collected again")
	func retriesUser() async throws {
		let authorizations = FakeAuthorizations(pageURL: Self.authorizePage)
		authorizations.outcome = authorizations.readyGitHubGrant()
		let github = ScriptedGitHub([.failure(.transport), .failure(.rateLimited(until: SleepingTestClock.start)), .success(Self.octocat)])
		let clock = SleepingTestClock()
		#expect(try await connect(authorizations, github: github, clock: clock).get().user == Self.octocat)
		#expect(github.userReads == 3)
		#expect(clock.sleeps == [.milliseconds(5), .seconds(1)], "A limit that has just lifted is still given a moment")
	}

	@Test("a rate limit on reading the user that GitHub doesn't say the end of is waited out a minute, then twice that, as GitHub asks")
	func backsOffUnannouncedLimits() async throws {
		let authorizations = FakeAuthorizations(pageURL: Self.authorizePage)
		authorizations.outcome = authorizations.readyGitHubGrant()
		let clock = SleepingTestClock()
		let github = ScriptedGitHub([.failure(.rateLimited(until: nil)), .failure(.rateLimited(until: nil)), .success(Self.octocat)])
		#expect(try await connect(authorizations, github: github, clock: clock).get().user == Self.octocat)
		#expect(clock.sleeps == [.seconds(60), .seconds(120)])
	}

	@Test("a rate limit on reading the user is waited out a moment past its reset, even one that lifts at the longest wait")
	func waitsOutUserRateLimit() async throws {
		let authorizations = FakeAuthorizations(pageURL: Self.authorizePage)
		authorizations.outcome = authorizations.readyGitHubGrant()
		let clock = SleepingTestClock()
		let github = ScriptedGitHub([.failure(.rateLimited(until: clock.date.addingTimeInterval(65))), .success(Self.octocat)])
		#expect(try await connect(authorizations, github: github, clock: clock).get().user == Self.octocat)
		#expect(clock.sleeps == [.seconds(66)])
		#expect(github.userReads == 2)
	}

	@Test(
		"a token GitHub refuses at once isn't kept, and neither is one whose user GitHub doesn't say",
		arguments: [
			(GitHubAPIError.unauthorized, BrowserConnectError.tokenRejected), (.forbidden, .tokenRejected),
			(.invalidResponse, .accountUnreadable), (.notFound, .accountUnreadable),
			(.rateLimited(until: SleepingTestClock.start.addingTimeInterval(66)), .platformRateLimited),
		]
	)
	func refusedUser(error: GitHubAPIError, expected: BrowserConnectError) async {
		let authorizations = FakeAuthorizations(pageURL: Self.authorizePage)
		authorizations.outcome = authorizations.readyGitHubGrant()
		let github = ScriptedGitHub([.failure(error)])
		#expect(failure(of: await connect(authorizations, github: github)) == expected)
		#expect(github.userReads == 1)
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
