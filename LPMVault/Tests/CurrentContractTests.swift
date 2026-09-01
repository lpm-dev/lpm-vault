import CryptoKit
import Darwin
import Foundation
import Security
import Testing

@testable import LPMVault

@Suite("Current Rust client and server contracts")
struct CurrentContractTests {
	@Test("schema JSON keeps numeric precision during request encoding")
	func schemaJSONKeepsNumericPrecision() throws {
		let input = Data(
			#"{"fractional":1.234567890123456789,"large":99999999999999999999999999999999999999}"#.utf8
		)
		let value = try JSONDecoder().decode(LPMJSONValue.self, from: input)
		let encoded = try JSONEncoder().encode(value)
		let decoded = try JSONDecoder().decode(PreciseSchemaNumbers.self, from: encoded)

		#expect(decoded.fractional == Decimal(string: "1.234567890123456789"))
		#expect(decoded.large == Decimal(string: "99999999999999999999999999999999999999"))
	}

	@Test("auth credentials are device-bound on add and update")
	func authCredentialsAreDeviceBound() {
		#expect(
			KeychainAuthCredentialBackend.accessibility
				== kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String
		)
	}

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

	@Test("protected-only cutover requires a shared-Keychain-compatible CLI")
	func protectedOnlyCutoverVersionGate() {
		#expect(LPMCLICompatibility.isCompatible(versionOutput: "lpm 0.76.0\n"))
		#expect(LPMCLICompatibility.isCompatible(versionOutput: "lpm 0.76.5"))
		#expect(!LPMCLICompatibility.isCompatible(versionOutput: "lpm 0.75.99"))
		#expect(!LPMCLICompatibility.isCompatible(versionOutput: "lpm 0.76.0-beta.1"))
		#expect(!LPMCLICompatibility.isCompatible(versionOutput: "unknown"))
		#expect(LPMCLICompatibility.allInstalledVersionsAreCompatible([
			"lpm 0.76.5",
			"lpm 0.77.0",
		]))
		#expect(!LPMCLICompatibility.allInstalledVersionsAreCompatible([
			"lpm 0.75.99",
			"lpm 0.76.5",
		]))
		#expect(!LPMCLICompatibility.allInstalledVersionsAreCompatible([
			"lpm 0.76.5",
			nil,
		]))
		#expect(!LPMCLICompatibility.allInstalledVersionsAreCompatible([]))
	}

	@Test("CLI compatibility stops after the first incompatible trusted candidate")
	func protectedOnlyCutoverVersionGateIsLazy() {
		let first = URL(fileURLWithPath: "/trusted/first")
		let second = URL(fileURLWithPath: "/trusted/second")
		var executed: [URL] = []

		let compatible = LPMCLICompatibility.installedCLIIsCompatible(
			candidates: [first, second],
			versionReader: { candidate in
				executed.append(candidate)
				return candidate == first ? "lpm 0.75.0" : "lpm 0.76.0"
			}
		)

		#expect(!compatible)
		#expect(executed == [first])
	}

	@Test("CLI compatibility ignores ambient PATH entries")
	func protectedOnlyCutoverIgnoresAmbientPath() {
		let home = URL(fileURLWithPath: "/Users/tester")
		let locations = LPMCLICompatibility.candidateLocations(home: home)

		#expect(!locations.contains(URL(fileURLWithPath: "/tmp/project/lpm")))
		#expect(locations == [
			URL(fileURLWithPath: "/opt/homebrew/bin/lpm"),
			URL(fileURLWithPath: "/usr/local/bin/lpm"),
			home.appendingPathComponent(".local/bin/lpm"),
			home.appendingPathComponent(".n/bin/lpm"),
		])
	}

	@Test("CLI version probing bounds output, time, and descendant lifetime")
	func protectedOnlyCutoverProbeIsBounded() throws {
		let directory = FileManager.default.temporaryDirectory
			.appendingPathComponent("lpm-cli-probe-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: directory) }

		let oversized = directory.appendingPathComponent("oversized")
		try Data("#!/bin/sh\nyes x | head -c 8192\n".utf8).write(to: oversized)
		try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: oversized.path)
		#expect(LPMCLICompatibility.versionOutput(
			executable: oversized,
			timeout: 0.5,
			maximumBytes: 4 * 1024
		) == nil)

		let childPIDFile = directory.appendingPathComponent("child.pid")
		let inheritedOutput = directory.appendingPathComponent("inherited-output")
		let script = """
			#!/bin/sh
			sleep 0.05
			/bin/sh -c 'trap "" TERM; echo $$ > "\(childPIDFile.path)"; sleep 10' &
			while [ ! -s "\(childPIDFile.path)" ]; do sleep 0.01; done
			printf 'lpm 0.76.0\\n'
			"""
		try Data(script.utf8).write(to: inheritedOutput)
		try FileManager.default.setAttributes(
			[.posixPermissions: 0o700],
			ofItemAtPath: inheritedOutput.path
		)
		let start = ProcessInfo.processInfo.systemUptime
		let output = LPMCLICompatibility.versionOutput(
			executable: inheritedOutput,
			timeout: 0.5
		)
		let elapsed = ProcessInfo.processInfo.systemUptime - start
		#expect(output == "lpm 0.76.0\n")
		#expect(elapsed < 0.5)
		let childPID = try #require(
			Int32(String(contentsOf: childPIDFile, encoding: .utf8)
				.trimmingCharacters(in: .whitespacesAndNewlines))
		)
		for _ in 0..<100 where Darwin.kill(childPID, 0) == 0 {
			Thread.sleep(forTimeInterval: 0.005)
		}
		#expect(Darwin.kill(childPID, 0) != 0)
	}

	@Test("wrapping-key file cutover deletes only the exact verified regular file")
	func exactWrappingKeyFileCutover() throws {
		let directory = FileManager.default.temporaryDirectory
			.appendingPathComponent("lpm-wrapping-key-cutover-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: directory) }
		let key = Data(repeating: 0x5a, count: 32)
		let encoded = key.map { String(format: "%02x", $0) }.joined()
		let file = directory.appendingPathComponent(".vault-key")
		try Data(encoded.utf8).write(to: file)
		try FileManager.default.setAttributes(
			[.posixPermissions: 0o600],
			ofItemAtPath: file.path
		)

		try VaultCrypto.deleteLegacyWrappingKeyFile(at: file, expectedKey: key)

		#expect(!FileManager.default.fileExists(atPath: file.path))

		let target = directory.appendingPathComponent("target")
		try Data(encoded.utf8).write(to: target)
		try FileManager.default.setAttributes(
			[.posixPermissions: 0o600],
			ofItemAtPath: target.path
		)
		try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
		#expect(throws: VaultCrypto.CryptoError.self) {
			try VaultCrypto.deleteLegacyWrappingKeyFile(at: file, expectedKey: key)
		}
		#expect(try Data(contentsOf: target) == Data(encoded.utf8))
		#expect(try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true)

		try FileManager.default.removeItem(at: file)
		let linkedFile = directory.appendingPathComponent(".vault-key.link")
		try FileManager.default.linkItem(at: target, to: file)
		try FileManager.default.linkItem(at: target, to: linkedFile)
		#expect(VaultCrypto.inspectStableWrappingKeyFile(at: file) == .unsafe)
		#expect(throws: VaultCrypto.CryptoError.self) {
			try VaultCrypto.deleteLegacyWrappingKeyFile(at: file, expectedKey: key)
		}
		#expect(try Data(contentsOf: linkedFile) == Data(encoded.utf8))
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

	@Test("sync push and pull reject unsigned non-success responses with success-shaped JSON")
	func syncRejectsNonSuccessPayloads() async {
		let body = #"{"version":7,"encryptedBlob":"ciphertext","wrappedKey":"wrapped"}"#
		let service = makeSyncService { _ in
			MockResponse(
				statusCode: 409,
				body: Data(body.utf8),
				headers: ["Content-Type": "application/json"]
			)
		}

		let pushed = await service.push(
			authToken: "session-token",
			vaultId: "vault-1",
			encryptedBlob: "request-ciphertext",
			wrappedKey: "request-wrapped",
			expectedVersion: 6
		)
		let pulled = await service.pull(authToken: "session-token", vaultId: "vault-1")

		#expect(pushed == nil)
		#expect(pulled == nil)
	}

	@Test("live personal 409 conflict reaches the conflict-resolution state")
	@MainActor
	func personalConflictPropagation() async {
		let service = makeSyncService { _ in
			MockResponse(
				statusCode: 409,
				body: Data(
					#"{"error":"Version conflict","code":"vault_version_conflict","serverVersion":9,"expectedVersion":7,"hint":"Use --force to overwrite, or pull first"}"#.utf8
				),
				headers: ["Content-Type": "application/json"]
			)
		}
		let keychain = MockKeychainService()
		keychain.envStorage["vault-1"] = (
			name: "Conflict",
			path: "",
			environments: ["default": ["TOKEN": "local"]]
		)
		let store = VaultStore(
			keychainService: keychain,
			biometricService: MockBiometricService(),
			apiService: MockAPIService(),
			personalSyncServiceFactory: { _ in service },
			stableSyncEncryptor: { _, _ in ("request-ciphertext", "request-wrapped") },
			authTokenProvider: { _, _ in "session-token" }
		)
		store.projects = [VaultProject(
			id: "vault-1",
			name: "Conflict",
			path: "",
			environments: ["default": ["TOKEN": "local"]]
		)]
		store.syncMetadata["vault-1"] = SyncMetadata(
			lastSyncedAt: Date(),
			lastAction: "pull",
			lastVersion: 7,
			isDirty: false
		)
		store.isUnlocked = true
		store.selectProject("vault-1")

		await store.pushToCloud()

		#expect(store.lastSyncStatus == "conflict")
		#expect(store.error == nil)
	}

	@Test("authenticated sync envelope binds a personal payload to its request")
	func authenticatedPersonalSyncEnvelope() async throws {
		let recorder = RequestRecorder()
		let service = makeSyncService(recorder: recorder) { request in
			let nonce = try #require(
				request.value(forHTTPHeaderField: "X-LPM-Vault-Request-Nonce")
			)
			#expect(nonce.count == 43)
			#expect(nonce.utf8.allSatisfy {
				($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90)
					|| ($0 >= 97 && $0 <= 122) || $0 == 45 || $0 == 95
			})
			return try signedSyncResponse(
				[
					"vaultId": "vault-1",
					"version": 7,
					"serverVersion": 7,
					"cryptoVersion": 2,
					"envelopeVersion": 2,
					"scope": "personal",
					"requestNonce": nonce,
					"encryptedBlob": "ciphertext",
					"wrappedKey": "wrapped",
					"payloadDigest":
						"129f6d5175b7c0875d84918c4cbf6a12a4843cea2167345b932568c94fb0dc8f",
				],
				token: "session-token"
			)
		}

		let response = await service.pull(
			authToken: "session-token",
			vaultId: "vault-1"
		)

		#expect(response?.vaultId == "vault-1")
		#expect(response?.version == 7)
		#expect(recorder.requests.count == 1)
	}

	@Test("authenticated sync envelope rejects substitution replay downgrade and missing bindings")
	func authenticatedSyncEnvelopeRejectsInvalidBindings() async throws {
		let invalidEnvelopes = [
			"cross-vault",
			"replay",
			"scope-substitution",
			"downgrade",
			"missing-envelope-version",
			"missing-server-version",
			"server-version-substitution",
			"payload-substitution",
		]

		for name in invalidEnvelopes {
			let service = makeSyncService { request in
				let nonce = try #require(
					request.value(forHTTPHeaderField: "X-LPM-Vault-Request-Nonce")
				)
				var envelope: [String: Any] = [
					"vaultId": "vault-1",
					"version": 7,
					"serverVersion": 7,
					"cryptoVersion": 2,
					"envelopeVersion": 2,
					"scope": "personal",
					"requestNonce": nonce,
					"encryptedBlob": "ciphertext",
					"wrappedKey": "wrapped",
					"payloadDigest": syncPayloadDigest(
						encryptedBlob: "ciphertext",
						wrappedKey: "wrapped"
					),
				]
				switch name {
				case "cross-vault": envelope["vaultId"] = "vault-2"
				case "replay": envelope["requestNonce"] = String(repeating: "A", count: 43)
				case "scope-substitution": envelope["scope"] = "organization"
				case "downgrade": envelope["cryptoVersion"] = 1
				case "missing-envelope-version": envelope.removeValue(forKey: "envelopeVersion")
				case "missing-server-version": envelope.removeValue(forKey: "serverVersion")
				case "server-version-substitution": envelope["serverVersion"] = 6
				case "payload-substitution": envelope["encryptedBlob"] = "other-ciphertext"
				default: Issue.record("Unknown invalid-envelope vector: \(name)")
				}
				return try signedSyncResponse(envelope, token: "session-token")
			}

			let response = await service.pull(
				authToken: "session-token",
				vaultId: "vault-1"
			)
			#expect(response == nil, "Accepted invalid sync envelope: \(name)")
		}
	}

	@Test("authenticated organization envelope binds the canonical organization slug")
	func authenticatedOrganizationSyncEnvelope() async throws {
		let service = makeSyncService { request in
			let nonce = try #require(
				request.value(forHTTPHeaderField: "X-LPM-Vault-Request-Nonce")
			)
			return try signedSyncResponse(
				[
					"vaultId": "vault-1",
					"version": 4,
					"serverVersion": 4,
					"cryptoVersion": 2,
					"envelopeVersion": 2,
					"scope": "organization",
					"organizationSlug": "other-org",
					"requestNonce": nonce,
					"encryptedBlob": "ciphertext",
					"wrappedKey": "wrapped",
					"payloadDigest": syncPayloadDigest(
						encryptedBlob: "ciphertext",
						wrappedKey: "wrapped"
					),
				],
				token: "session-token"
			)
		}

		let response = await service.pullOrg(
			authToken: "session-token",
			orgSlug: "acme",
			vaultId: "vault-1"
		)

		#expect(response == nil)
	}

	private func signedSyncResponse(
		_ object: [String: Any],
		token: String
	) throws -> MockResponse {
		let body = try JSONSerialization.data(
			withJSONObject: object,
			options: [.sortedKeys]
		)
		let key = SHA256.hash(data: Data(token.utf8))
		let mac = HMAC<SHA256>.authenticationCode(
			for: body,
			using: SymmetricKey(data: Data(key))
		)
		return MockResponse(
			statusCode: 200,
			body: body,
			headers: [
				"Content-Type": "application/json",
				"X-LPM-Signature": Data(mac).base64EncodedString(),
			]
		)
	}

	private func syncPayloadDigest(
		encryptedBlob: String,
		wrappedKey: String
	) -> String {
		var input = Data("lpm-vault-payload\0".utf8)
		for value in [encryptedBlob, wrappedKey] {
			let bytes = Data(value.utf8)
			var length = UInt32(bytes.count).bigEndian
			withUnsafeBytes(of: &length) { input.append(contentsOf: $0) }
			input.append(bytes)
		}
		return SHA256.hash(data: input)
			.map { String(format: "%02x", $0) }
			.joined()
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

private struct PreciseSchemaNumbers: Decodable {
	let fractional: Decimal
	let large: Decimal
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
