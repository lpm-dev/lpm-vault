import CryptoKit
import Foundation
import Testing

@testable import LPMVault

@Suite("Current Rust client and server contracts")
struct CurrentContractTests {
	@Test("hashed access account matches the Rust client")
	func hashedAccessAccount() {
		#expect(
			AuthSessionStore.scopedAccessAccount(registryURL: "https://lpm.dev")
				== "auth-token:bd90fc32d95766d5"
		)
	}

	@Test("hashed refresh account matches the Rust client")
	func hashedRefreshAccount() {
		#expect(
			AuthSessionStore.scopedRefreshAccount(registryURL: "https://lpm.dev")
				== "lpm-refresh:bd90fc32d95766d5"
		)
	}

	@Test("session and credential-store lock names match the Rust client")
	func sharedSessionLockNames() {
		#expect(
			AuthSessionStore.sessionLockName(registryURL: "https://lpm.dev")
				== "auth-session-bd90fc32d95766d5d543f79f0751c37a.lock"
		)
		#expect(
			AuthSessionStore.sessionLockName(registryURL: "lpm-auth://credential-store")
				== "auth-session-d1e22cd6f5ad4be6dbd4ded4de2f04f9.lock"
		)
	}

	@Test("credential authority identifiers match the Rust client")
	func sharedCredentialAuthorityIdentifiers() {
		#expect(
			AuthSessionStore.authorityID(kind: "access", registryURL: "https://lpm.dev")
				== "41c1b09ae272839b0a1fd749b7a4aa267af0170297f6b5b887c2b1157efb9c93"
		)
		#expect(
			AuthSessionStore.authorityID(kind: "refresh", registryURL: "https://lpm.dev")
				== "15832937e4b1454a4a2a6573780ea4f80cff333fd7dbe9c065e2557b776bb05f"
		)
	}

	@Test("session registry scope is the exact API base URL")
	func exactRegistryScope() {
		#expect(
			AuthSessionStore.registryURL(for: VaultConstants.apiBaseURL)
				== "https://lpm.dev"
		)
		#expect(
			AuthSessionStore.registryURL(for: URL(string: "http://127.0.0.1:8787")!)
				== "http://127.0.0.1:8787"
		)
	}

	@Test("callback accepts the current POST form exchange-code shape")
	func callbackAcceptsPostForm() {
		let code = String(repeating: "a", count: 64)
		let body = "code=\(code)&state=state-123"
		let request = "POST /callback HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"

		let callback = LoginService.parseCallbackRequest(Data(request.utf8))

		#expect(callback?.code == code)
		#expect(callback?.state == "state-123")
	}

	@Test("callback rejects the retired direct-token shape")
	func callbackRejectsDirectToken() {
		let request = "GET /callback?token=lpm_secret&state=state-123 HTTP/1.1\r\nHost: localhost\r\n\r\n"
		#expect(LoginService.parseCallbackRequest(Data(request.utf8)) == nil)
	}

	@Test("callback rejects the wrong path and malformed exchange codes")
	func callbackRejectsInvalidRequests() {
		let request = "GET /other?code=abc&state=s HTTP/1.1\r\nHost: localhost\r\n\r\n"
		#expect(LoginService.parseCallbackRequest(Data(request.utf8)) == nil)

		let unicodeCode = String(repeating: "ａ", count: 64)
		let unicodeRequest = "GET /callback?code=\(unicodeCode)&state=s HTTP/1.1\r\nHost: localhost\r\n\r\n"
		#expect(LoginService.parseCallbackRequest(Data(unicodeRequest.utf8)) == nil)
	}

	@Test("sync confirmation actions have distinct operation copy")
	func syncConfirmationCopy() {
		#expect(SyncConfirmationAction.push.title == "Push to Cloud")
		#expect(SyncConfirmationAction.pull.title == "Pull from Cloud")
		#expect(SyncConfirmationAction.share.title == "Share with Organization")
		#expect(SyncConfirmationAction.share.buttonTitle == "Share")
	}

	@Test("login exchange body carries the PKCE-bound code and verifier")
	func exchangePayload() throws {
		let code = String(repeating: "b", count: 64)
		let verifier = String(repeating: "v", count: 43)
		let body = try LoginService.exchangeRequestBody(code: code, codeVerifier: verifier)
		let payload = try #require(JSONSerialization.jsonObject(with: body) as? [String: String])

		#expect(payload == ["code": code, "code_verifier": verifier])
	}

	@Test("variable names match the Rust ASCII contract")
	func variableNameValidation() {
		for name in ["FOO", "foo", "_hidden", "API_KEY_2024"] {
			#expect(EnvValidation.isValidVariableName(name))
		}
		for name in ["", "1leading", "with-dash", "with space", "A;evil", "ÉNV"] {
			#expect(!EnvValidation.isValidVariableName(name))
		}
	}

	@Test("vault detects case-only collisions without rejecting Rust-compatible data")
	func portableVariableNames() {
		#expect(
			EnvValidation.caseInsensitiveCollision(
				for: "Hey",
				in: ["HEY", "OTHER"]
			) == "HEY"
		)
		#expect(EnvValidation.areValidEnvironments([
			"default": ["HEY": "upper", "Hey": "mixed"]
		]))
	}

	@Test("environment names match the Rust resolver contract")
	func environmentNameValidation() {
		for name in ["default", "production", "staging.eu", "my-env_1"] {
			#expect(EnvValidation.isValidEnvironmentName(name))
		}
		for name in ["", "__index__", "../etc", "foo/bar", "env name", "prodé"] {
			#expect(!EnvValidation.isValidEnvironmentName(name))
		}
		#expect(!EnvValidation.isValidEnvironmentName(String(repeating: "a", count: 65)))
	}

	@Test("env project identifiers match the Rust portability boundary")
	func safeVaultIdentifiers() {
		for id in ["550e8400-e29b-41d4-a716-446655440000", "my-vault", "vault_v2"] {
			#expect(EnvValidation.isSafeVaultId(id))
		}
		for id in [
			"", ".", "..", "../escape", "foo/bar", "foo\\bar", "~/.lpm", "foo..bar",
			"__index__", "__sync_metadata__", "__org_associations__", "__x25519_private_key__",
		] {
			#expect(!EnvValidation.isSafeVaultId(id))
		}
	}

	@Test("organization slugs are portable path segments")
	func safeOrganizationSlugs() {
		for slug in ["acme", "acme-team", "team_2"] {
			#expect(EnvValidation.isSafeOrgSlug(slug))
		}
		for slug in ["", "-leading", "../team", "team/other", "team space"] {
			#expect(!EnvValidation.isSafeOrgSlug(slug))
		}
	}

	@Test("decrypted cloud payload rejects invalid environment and variable names")
	func invalidCloudPayloadNames() throws {
		let invalidEnvironment = Data(#"{"environments":{"../prod":{"TOKEN":"secret"}}}"#.utf8)
		let invalidVariable = Data(#"{"environments":{"production":{"BAD-NAME":"secret"}}}"#.utf8)

		#expect(throws: EnvValidation.PayloadError.self) {
			try EnvValidation.mergeRemotePayload(invalidEnvironment, into: ["default": [:]])
		}
		#expect(throws: EnvValidation.PayloadError.self) {
			try EnvValidation.mergeRemotePayload(invalidVariable, into: ["default": [:]])
		}
	}

	@Test("decrypted cloud payload merges valid remote values")
	func validCloudPayloadMerge() throws {
		let payload = Data(#"{"environments":{"production":{"TOKEN":"remote"}}}"#.utf8)
		let result = try EnvValidation.mergeRemotePayload(
			payload,
			into: ["default": ["LOCAL": "kept"], "production": ["TOKEN": "old"]]
		)

		#expect(result.environments["default"]?["LOCAL"] == "kept")
		#expect(result.environments["production"]?["TOKEN"] == "remote")
		#expect(result.keyCount == 1)
	}

	@Test("sensitive file exports are owner-only")
	func sensitiveFilePermissions() throws {
		let directory = FileManager.default.temporaryDirectory
			.appendingPathComponent("lpm-vault-test-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: directory) }
		let destination = directory.appendingPathComponent(".env")

		try SecureFileWriter.write(Data("TOKEN=secret\n".utf8), to: destination)

		let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
		let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
		#expect(permissions.intValue & 0o777 == 0o600)
		#expect(try String(contentsOf: destination, encoding: .utf8) == "TOKEN=secret\n")
	}

	@Test("project config access refuses symbolic links")
	func projectConfigRejectsSymbolicLinks() throws {
		let directory = FileManager.default.temporaryDirectory
			.appendingPathComponent("lpm-vault-config-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: directory) }

		let target = directory.appendingPathComponent("outside.json")
		let original = Data(#"{"env":{"production":".env.production"}}"#.utf8)
		try original.write(to: target)
		let config = directory.appendingPathComponent("lpm.json")
		try FileManager.default.createSymbolicLink(at: config, withDestinationURL: target)

		#expect(ProjectConfigFile.readObject(at: config) == nil)
		#expect(throws: ProjectConfigFile.FileError.self) {
			try ProjectConfigFile.writeVaultID("safe-vault-id", to: config)
		}
		#expect(try Data(contentsOf: target) == original)
		let values = try config.resourceValues(forKeys: [.isSymbolicLinkKey])
		#expect(values.isSymbolicLink == true)
	}

	@Test("organization wrapped-key payload carries recipient binding fields")
	func orgWrappedKeyPayload() throws {
		let item = SyncService.WrappedMemberKey(
			userId: "user-1",
			wrappedKey: "ephemeral:iv:ciphertext",
			publicKeyVersion: 7,
			publicKeyFingerprint: String(repeating: "a", count: 64)
		)
		let data = try JSONEncoder().encode(item)
		let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

		#expect(object["userId"] as? String == "user-1")
		#expect(object["wrappedKey"] as? String == "ephemeral:iv:ciphertext")
		#expect(object["publicKeyVersion"] as? Int == 7)
		#expect(object["publicKeyFingerprint"] as? String == String(repeating: "a", count: 64))
	}

	@Test("stable personal wrapping round-trips with an injected key")
	func stableWrappingKeyRoundTrip() throws {
		let wrappingKey = SymmetricKey(data: Data(repeating: 0x5a, count: 32))
		let payload = #"{"environments":{"default":{"TOKEN":"secret"}}}"#
		let encrypted = try VaultCrypto.encryptForStableSync(
			secretsJSON: payload,
			vaultId: "vault-contract",
			wrappingKey: wrappingKey
		)

		#expect(try VaultCrypto.decryptStableSync(
			encryptedBlob: encrypted.encryptedBlob,
			wrappedKey: encrypted.wrappedKey,
			vaultId: "vault-contract",
			cryptoVersion: VaultCrypto.currentCryptoVersion,
			wrappingKey: wrappingKey
		) == payload)
	}

	@Test("public key fingerprint is SHA-256 over raw X25519 bytes")
	func publicKeyFingerprint() {
		let key = Data(repeating: 0x42, count: 32)
		let expected = SHA256.hash(data: key).map { String(format: "%02x", $0) }.joined()
		#expect(VaultCrypto.publicKeyFingerprint(key) == expected)
	}

	@Test("personal token inventory aggregates all cursor pages")
	func personalTokenPagination() async throws {
		let recorder = RequestRecorder()
		let service = makeAPIService(recorder: recorder) { request in
			let cursor = URLComponents(url: try #require(request.url), resolvingAgainstBaseURL: false)?
				.queryItems?.first { $0.name == "cursor" }?.value
			switch cursor {
			case nil:
				return .json(#"[{"id":"one","name":"first"}]"#, nextCursor: "cursor-1")
			case "cursor-1":
				return .json(#"[{"id":"two","name":"second"}]"#)
			default:
				return .status(400)
			}
		}

		let tokens = try await service.fetchPersonalTokens(authToken: "session-token").get()
		#expect(tokens.map(\.id) == ["one", "two"])
		let requests = recorder.requests
		#expect(requests.count == 2)
		#expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer session-token" })
	}

	@Test("token inventory rejects cursor cycles")
	func tokenPaginationRejectsCursorCycle() async {
		let service = makeAPIService { request in
			let cursor = request.url.flatMap {
				URLComponents(url: $0, resolvingAgainstBaseURL: false)?
					.queryItems?.first { $0.name == "cursor" }?.value
			}
			switch cursor {
			case nil: return .json("[]", nextCursor: "cursor-a")
			case "cursor-a": return .json("[]", nextCursor: "cursor-b")
			default: return .json("[]", nextCursor: "cursor-a")
			}
		}

		let result = await service.fetchPersonalTokens(authToken: "session-token")
		guard case .failure(.invalidResponse) = result else {
			Issue.record("Expected invalid response for a cursor cycle")
			return
		}
	}

	@Test("token inventory rejects oversized cursors")
	func tokenPaginationRejectsOversizedCursor() async {
		let service = makeAPIService { _ in
			.json("[]", nextCursor: String(repeating: "x", count: 161))
		}

		let result = await service.fetchPersonalTokens(authToken: "session-token")
		guard case .failure(.invalidResponse) = result else {
			Issue.record("Expected invalid response for an oversized cursor")
			return
		}
	}

	@Test("organization token route encodes the slug once")
	func orgTokenSlugEncoding() async throws {
		let recorder = RequestRecorder()
		let service = makeAPIService(recorder: recorder) { _ in .json("[]") }

		let tokens = try await service.fetchOrgTokens(
			orgSlug: "acme/team %",
			authToken: "session-token"
		).get()
		#expect(tokens.isEmpty)
		let request = try #require(recorder.requests.first)
		let components = try #require(request.url.flatMap {
			URLComponents(url: $0, resolvingAgainstBaseURL: false)
		})
		#expect(components.percentEncodedPath == "/api/orgs/acme%2Fteam%20%25/tokens")
	}

	@Test("empty token inventory is distinct from request failure")
	func emptyTokenInventoryIsTypedSuccess() async {
		let emptyService = makeAPIService { _ in .json("[]") }
		let failureService = makeAPIService { _ in .status(503) }

		let empty = await emptyService.fetchPersonalTokens(authToken: "session-token")
		let failure = await failureService.fetchPersonalTokens(authToken: "session-token")
		guard case .success(let tokens) = empty else {
			Issue.record("Expected an empty successful inventory")
			return
		}
		#expect(tokens.isEmpty)
		guard case .failure(.server(503)) = failure else {
			Issue.record("Expected a typed HTTP 503 failure")
			return
		}
	}

	@Test("cloud env project listing follows bounded cursor pagination")
	func cloudProjectPagination() async throws {
		let recorder = RequestRecorder()
		let service = makeSyncService(recorder: recorder) { request in
			#expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer session-token")
			if request.url?.query == "cursor=cursor-2" {
				return .json(#"{"vaults":[{"vaultId":"vault-2","name":"two"}],"nextCursor":null}"#)
			}
			return .json(#"{"vaults":[{"vaultId":"vault-1","name":"one"}],"nextCursor":"cursor-2"}"#)
		}

		let result = await service.listPersonalProjects(authToken: "session-token")
		guard case .success(let projects) = result else {
			Issue.record("Expected a successful project listing")
			return
		}
		#expect(projects.map(\.vaultId) == ["vault-1", "vault-2"])
		#expect(recorder.requests.count == 2)
	}

	@Test("cloud env project listing distinguishes an incompatible session")
	func cloudProjectSessionAuthorizationFailure() async {
		let service = makeSyncService { _ in
			MockResponse(
				statusCode: 403,
				body: Data(#"{"error":"This endpoint requires a CLI session. Run `lpm login` to authenticate."}"#.utf8),
				headers: ["Content-Type": "application/json"]
			)
		}

		let result = await service.listPersonalProjects(authToken: "legacy-token")

		guard case .failure(let error) = result else {
			Issue.record("Expected a typed authorization failure")
			return
		}
		#expect(error == .sessionNotAuthorized)
	}

	@Test("cloud env project listing rejects malformed success data")
	func cloudProjectInvalidResponse() async {
		let service = makeSyncService { _ in .json(#"{"projects":[]}"#) }

		let result = await service.listPersonalProjects(authToken: "session-token")

		guard case .failure(let error) = result else {
			Issue.record("Expected an invalid-response failure")
			return
		}
		#expect(error == .invalidResponse)
	}

	private func makeAPIService(
		recorder: RequestRecorder = RequestRecorder(),
		handler: @escaping MockURLProtocol.Handler
	) -> LPMAPIService {
		let host = "\(UUID().uuidString.lowercased()).example"
		MockURLProtocol.routes.register(host: host) { request in
			recorder.record(request)
			return try handler(request)
		}
		let configuration = URLSessionConfiguration.ephemeral
		configuration.protocolClasses = [MockURLProtocol.self]
		return LPMAPIService(
			baseURL: URL(string: "https://\(host)")!,
			session: URLSession(configuration: configuration)
		)
	}

	private func makeSyncService(
		recorder: RequestRecorder = RequestRecorder(),
		handler: @escaping MockURLProtocol.Handler
	) -> SyncService {
		let host = "\(UUID().uuidString.lowercased()).example"
		MockURLProtocol.routes.register(host: host) { request in
			recorder.record(request)
			return try handler(request)
		}
		let configuration = URLSessionConfiguration.ephemeral
		configuration.protocolClasses = [MockURLProtocol.self]
		return SyncService(
			baseURL: URL(string: "https://\(host)")!,
			session: URLSession(configuration: configuration)
		)
	}
}

private struct MockResponse {
	let statusCode: Int
	let body: Data
	let headers: [String: String]

	static func json(_ body: String, nextCursor: String? = nil) -> Self {
		var headers = ["Content-Type": "application/json"]
		if let nextCursor { headers["X-LPM-Next-Cursor"] = nextCursor }
		return Self(statusCode: 200, body: Data(body.utf8), headers: headers)
	}

	static func status(_ statusCode: Int) -> Self {
		Self(statusCode: statusCode, body: Data(), headers: [:])
	}
}

private final class RequestRecorder: @unchecked Sendable {
	private let lock = NSLock()
	private var storage: [URLRequest] = []

	var requests: [URLRequest] {
		lock.withLock { storage }
	}

	func record(_ request: URLRequest) {
		lock.withLock { storage.append(request) }
	}
}

private final class MockRoutes: @unchecked Sendable {
	typealias Handler = (URLRequest) throws -> MockResponse
	private let lock = NSLock()
	private var handlers: [String: Handler] = [:]

	func register(host: String, handler: @escaping Handler) {
		lock.withLock { handlers[host] = handler }
	}

	func response(for request: URLRequest) throws -> MockResponse {
		let host = try #require(request.url?.host)
		let handler = try #require(lock.withLock { handlers[host] })
		return try handler(request)
	}
}

private final class MockURLProtocol: URLProtocol {
	typealias Handler = MockRoutes.Handler
	static let routes = MockRoutes()

	override class func canInit(with request: URLRequest) -> Bool { true }
	override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

	override func startLoading() {
		do {
			let stub = try Self.routes.response(for: request)
			guard let url = request.url,
				let response = HTTPURLResponse(
				url: url,
				statusCode: stub.statusCode,
				httpVersion: "HTTP/1.1",
				headerFields: stub.headers
			) else { throw URLError(.badURL) }
			client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
			client?.urlProtocol(self, didLoad: stub.body)
			client?.urlProtocolDidFinishLoading(self)
		} catch {
			client?.urlProtocol(self, didFailWithError: error)
		}
	}

	override func stopLoading() {}
}
