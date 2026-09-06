import CryptoKit
import Foundation
import Security
import Testing

@testable import LPMVault

@Suite("Current Rust client and server contracts")
struct CurrentContractTests {
  @Test("sync metadata requires the current checkpoint field")
  func syncMetadataRequiresCheckpointField() {
    let input = Data(
      #"{"lastSyncedAt":0,"lastAction":"pull","lastVersion":7,"isDirty":false,"binding":{"registryURL":"https://lpm.dev","principalID":"account-1","scope":"personal"}}"#.utf8
    )

    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(SyncMetadata.self, from: input)
    }
  }

  @Test("checkpoint lookup ignores checkpoint-less top-level fields")
  func checkpointLookupRequiresCheckpoint() {
    let binding = SyncPrincipalBinding(
      registryURL: "https://lpm.dev",
      principalID: "account-1",
      scope: "personal"
    )
    let metadata = SyncMetadata(
      lastSyncedAt: Date(timeIntervalSinceReferenceDate: 0),
      lastAction: "pull",
      lastVersion: 7
    )

    #expect(metadata.version(boundTo: binding) == nil)
  }

  @Test("checkpoint scoping ignores checkpoint-less top-level versions")
  func checkpointScopingRequiresCheckpoint() {
    let binding = SyncPrincipalBinding(
      registryURL: "https://lpm.dev",
      principalID: "account-1",
      scope: "personal"
    )
    let metadata = SyncMetadata(
      lastSyncedAt: Date(timeIntervalSinceReferenceDate: 0),
      lastAction: "pull",
      lastVersion: 7
    )

    #expect(metadata.scoped(to: binding) == nil)
  }

  @Test("checkpoint recording ignores checkpoint-less top-level floors")
  func checkpointRecordingRequiresCheckpointFloor() throws {
    let binding = SyncPrincipalBinding(
      registryURL: "https://lpm.dev",
      principalID: "account-1",
      scope: "personal"
    )
    var metadata = SyncMetadata(
      lastSyncedAt: Date(timeIntervalSinceReferenceDate: 0),
      lastAction: "pull",
      lastVersion: 7
    )

    try metadata.record(
      binding: binding,
      version: 1,
      action: "pull",
      date: Date(timeIntervalSinceReferenceDate: 1),
      isDirty: false
    )

    #expect(metadata.version(boundTo: binding) == 1)
  }

  @Test("organization member keys require an immutable organization identity")
  func memberKeysRequireOrganizationIdentity() async {
    let service = makeSyncService { _ in
      return MockResponse(
        statusCode: 200,
        body: Data("[]".utf8),
        headers: [
          "Content-Type": "application/json",
          "X-LPM-Org-Wrapped-Keys-Write": "allowed",
        ]
      )
    }

    let response = await service.getOrgMemberKeyAccessAuthenticated(
      authToken: "token",
      expectedCallerUserID: "user-1",
      orgSlug: "acme"
    )

    #expect(response.value == nil)
  }

  @Test("organization member keys require a bounded authenticated caller")
  func memberKeysRequireAuthenticatedCaller() async {
    let organizationID = "11111111-1111-4111-8111-111111111111"
    for callerUserID in [nil, "caller\nsubstitution"] as [String?] {
      let service = makeSyncService { _ in
        var headers = [
          "Content-Type": "application/json",
          "X-LPM-Organization-ID": organizationID,
          "X-LPM-Org-Wrapped-Keys-Write": "allowed",
        ]
        headers["X-LPM-Caller-User-ID"] = callerUserID
        return MockResponse(statusCode: 200, body: Data("[]".utf8), headers: headers)
      }

      let response = await service.getOrgMemberKeyAccessAuthenticated(
        authToken: "token",
        expectedCallerUserID: "user-1",
        orgSlug: "acme"
      )

      #expect(response.value == nil)
    }
  }

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
    let request =
      "POST /callback HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"

    let callback = LoginService.parseCallbackRequest(Data(request.utf8))

    #expect(callback?.code == code)
    #expect(callback?.state == "state-123")
  }

  @Test("callback rejects the retired direct-token shape")
  func callbackRejectsDirectToken() {
    let request =
      "GET /callback?token=lpm_secret&state=state-123 HTTP/1.1\r\nHost: localhost\r\n\r\n"
    #expect(LoginService.parseCallbackRequest(Data(request.utf8)) == nil)
  }

  @Test("callback rejects the wrong path and malformed exchange codes")
  func callbackRejectsInvalidRequests() {
    let request = "GET /other?code=abc&state=s HTTP/1.1\r\nHost: localhost\r\n\r\n"
    #expect(LoginService.parseCallbackRequest(Data(request.utf8)) == nil)

    let unicodeCode = String(repeating: "ａ", count: 64)
    let unicodeRequest =
      "GET /callback?code=\(unicodeCode)&state=s HTTP/1.1\r\nHost: localhost\r\n\r\n"
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
    #expect(
      EnvValidation.areValidEnvironments([
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

  @Test("sensitive file exports remove inherited access-control entries")
  func sensitiveFileExportsRemoveInheritedACLs() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("lpm-vault-acl-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let chmod = Process()
    chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
    chmod.arguments = ["+a", "group:everyone allow read,file_inherit", directory.path]
    try chmod.run()
    chmod.waitUntilExit()
    try #require(chmod.terminationStatus == 0)

    let destination = directory.appendingPathComponent(".env")
    try SecureFileWriter.write(Data("TOKEN=secret\n".utf8), to: destination)

    let acl = destination.withUnsafeFileSystemRepresentation { path in
      guard let path else { return acl_t?.none }
      return acl_get_file(path, ACL_TYPE_EXTENDED)
    }
    defer {
      if let acl { acl_free(UnsafeMutableRawPointer(acl)) }
    }
    #expect(acl == nil)
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
      principalId: "00000000-0000-4000-8000-000000000123",
      vaultId: "vault-contract",
      revision: 7,
      wrappingKey: wrappingKey
    )

    #expect(
      try VaultCrypto.decryptStableSync(
        encryptedBlob: encrypted.encryptedBlob,
        wrappedKey: encrypted.wrappedKey,
        principalId: "00000000-0000-4000-8000-000000000123",
        vaultId: "vault-contract",
        revision: 7,
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
    #expect(
      requests.allSatisfy {
        $0.value(forHTTPHeaderField: "Authorization") == "Bearer session-token"
      })
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

  @Test("token inventory enforces one cumulative response budget")
  func tokenPaginationRejectsCumulativeOversize() async {
    let largeName = String(repeating: "x", count: 1_100_000)
    let service = makeAPIService { request in
      let cursor = request.url.flatMap {
        URLComponents(url: $0, resolvingAgainstBaseURL: false)?
          .queryItems?.first { $0.name == "cursor" }?.value
      }
      let id = cursor == nil ? "one" : "two"
      let body = try JSONEncoder().encode([
        LPMToken(
          id: id,
          name: largeName,
          scope: nil,
          expiresAt: nil,
          lastUsedAt: nil,
          downloadCount: nil,
          createdAt: nil,
          orgSlug: nil
        )
      ])
      return MockResponse(
        statusCode: 200,
        body: body,
        headers: cursor == nil
          ? ["Content-Type": "application/json", "X-LPM-Next-Cursor": "second"]
          : ["Content-Type": "application/json"]
      )
    }

    let result = await service.fetchPersonalTokens(authToken: "session-token")
    guard case .failure(.invalidResponse) = result else {
      Issue.record("Expected cumulative token response bytes to be rejected")
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
    let components = try #require(
      request.url.flatMap {
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
        body: Data(
          #"{"error":"This endpoint requires a CLI session. Run `lpm login` to authenticate."}"#
            .utf8),
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

  @Test("cloud env project listing rejects duplicate project identities across pages")
  func cloudProjectPaginationRejectsDuplicateProjectIDs() async {
    let service = makeSyncService { request in
      if request.url?.query == "cursor=cursor-2" {
        return .json(
          #"{"vaults":[{"vaultId":"duplicate","name":"second"}],"nextCursor":null}"#)
      }
      return .json(
        #"{"vaults":[{"vaultId":"duplicate","name":"first"}],"nextCursor":"cursor-2"}"#)
    }

    let result = await service.listPersonalProjects(authToken: "session-token")

    guard case .failure(let error) = result else {
      Issue.record("Expected duplicate project identities to be rejected")
      return
    }
    #expect(error == .invalidPagination)
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

  @Test("cloud env project listing enforces one cumulative response budget")
  func cloudProjectPaginationRejectsCumulativeOversize() async {
    let largeName = String(repeating: "x", count: 5_300_000)
    let service = makeSyncService { request in
      let isSecondPage = request.url?.query == "cursor=second"
      let page: [String: Any] = [
        "vaults": [
          [
            "vaultId": isSecondPage ? "two" : "one",
            "name": largeName,
          ]
        ],
        "nextCursor": isSecondPage ? NSNull() : "second",
      ]
      return MockResponse(
        statusCode: 200,
        body: try JSONSerialization.data(withJSONObject: page),
        headers: ["Content-Type": "application/json"]
      )
    }

    let result = await service.listPersonalProjects(authToken: "session-token")
    guard case .failure(.invalidResponse) = result else {
      Issue.record("Expected cumulative project response bytes to be rejected")
      return
    }
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
      expectedPrincipalId: "account-1",
      vaultId: "vault-1",
      encryptedBlob: "request-ciphertext",
      wrappedKey: "request-wrapped",
      expectedVersion: 6
    )
    let pulled = await service.pull(authToken: "session-token", vaultId: "vault-1")

    #expect(pushed == nil)
    #expect(pulled == nil)
  }

  @Test("organization pull preserves the exact member rewrap response")
  func organizationPullPreservesExactMemberRewrapResponse() async {
    let organizationID = "11111111-1111-4111-8111-111111111111"
    let service = makeSyncService { request in
      let nonce = try #require(
        request.value(forHTTPHeaderField: "X-LPM-Vault-Request-Nonce")
      )
      return try signedSyncResponse(
        vaultEnvelope(
          operation: "vault.pull",
          outcome: "memberRewrapRequired",
          requestNonce: nonce,
          binding: [
            "scope": "organization",
            "principalId": organizationID,
            "callerUserId": "user-1",
            "organizationSlug": "acme",
            "vaultId": "vault-1",
          ],
          data: ["revision": 4, "contentKeyVersion": 2]
        ),
        token: "session-token",
        statusCode: 403
      )
    }

    guard
      case .response(let response) = await service.pullOrgAuthenticated(
        authToken: "session-token",
        orgSlug: "acme",
        vaultId: "vault-1"
      )
    else {
      Issue.record("The exact member rewrap response was not preserved")
      return
    }
    #expect(response?.code == "vault_member_needs_rewrap")
  }

  @Test("invalid signed responses are rejected before decoding")
  func invalidSignedResponseRejectsBeforeDecoding() throws {
    let response = try #require(
      HTTPURLResponse(
        url: URL(string: "https://lpm.dev/api/vaults/vault-1")!,
        statusCode: 200,
        httpVersion: "HTTP/1.1",
        headerFields: ["Content-Type": "application/json"]
      )
    )
    let counter = DecodeCallCounter()

    let result: SyncService.AuthenticatedResponse<DecodeProbeResponse> =
      SyncService.adjudicateResponse(
        response,
        data: Data(#"{"payload":"untrusted"}"#.utf8),
        signedSuccess: true,
        decode: { _, _ in
          counter.record()
          return DecodeProbeResponse()
        }
      )

    guard case .response(nil) = result else {
      Issue.record("An invalidly signed response was accepted")
      return
    }
    #expect(counter.callCount == 0)
  }

  @Test("organization pull rejects other forbidden responses")
  func organizationPullRejectsOtherForbiddenResponses() async {
    let service = makeSyncService { _ in
      MockResponse(
        statusCode: 403,
        body: Data(
          #"{"error":"Forbidden","code":"vault_access_denied"}"#.utf8
        ),
        headers: ["Content-Type": "application/json"]
      )
    }

    guard
      case .response(nil) = await service.pullOrgAuthenticated(
        authToken: "session-token",
        orgSlug: "acme",
        vaultId: "vault-1"
      )
    else {
      Issue.record("A non-rewrap forbidden response was accepted")
      return
    }
  }

  @Test("organization pull preserves unauthorized responses")
  func organizationPullPreservesUnauthorizedResponses() async {
    let service = makeSyncService { _ in
      MockResponse(
        statusCode: 401,
        body: Data(#"{"error":"Unauthorized"}"#.utf8),
        headers: ["Content-Type": "application/json"]
      )
    }

    let response = await service.pullOrgAuthenticated(
      authToken: "session-token",
      orgSlug: "acme",
      vaultId: "vault-1"
    )
    guard case .unauthorized = response else {
      Issue.record("An unauthorized organization pull was not preserved")
      return
    }
  }

  @Test("organization pull rejects an invalidly signed unauthorized response")
  func organizationPullRejectsInvalidlySignedUnauthorizedResponse() async {
    let service = makeSyncService { _ in
      MockResponse(
        statusCode: 401,
        body: Data(#"{"error":"Unauthorized"}"#.utf8),
        headers: [
          "Content-Type": "application/json",
          "X-LPM-Response-Key-ID": "vault-test-rfc8032",
          "X-LPM-Response-Signature": String(repeating: "A", count: 86),
        ]
      )
    }

    guard
      case .response(nil) = await service.pullOrgAuthenticated(
        authToken: "session-token",
        orgSlug: "acme",
        vaultId: "vault-1"
      )
    else {
      Issue.record("An invalidly signed unauthorized response was accepted")
      return
    }
  }

  @Test("organization pull rejects malformed member rewrap responses")
  func organizationPullRejectsMalformedMemberRewrapResponses() async {
    let service = makeSyncService { _ in
      MockResponse(
        statusCode: 403,
        body: Data(#"{"code":"vault_member_needs_rewrap""#.utf8),
        headers: ["Content-Type": "application/json"]
      )
    }

    guard
      case .response(nil) = await service.pullOrgAuthenticated(
        authToken: "session-token",
        orgSlug: "acme",
        vaultId: "vault-1"
      )
    else {
      Issue.record("A malformed member rewrap response was accepted")
      return
    }
  }

  @Test("organization pull rejects unbound member rewrap identities")
  func organizationPullRejectsUnboundMemberRewrapIdentity() async {
    let organizationID = "11111111-1111-4111-8111-111111111111"
    for callerUserID in [nil, "caller\nsubstitution"] as [String?] {
      var payload: [String: Any] = [
        "error": "You do not have a wrapped key for this organization env project",
        "code": "vault_member_needs_rewrap",
        "organizationId": organizationID,
      ]
      payload["callerUserId"] = callerUserID
      let service = makeSyncService { _ in
        MockResponse(
          statusCode: 403,
          body: try JSONSerialization.data(withJSONObject: payload),
          headers: ["Content-Type": "application/json"]
        )
      }

      guard
        case .response(nil) = await service.pullOrgAuthenticated(
          authToken: "session-token",
          orgSlug: "acme",
          vaultId: "vault-1"
        )
      else {
        Issue.record("Accepted an unbound member rewrap identity")
        continue
      }
    }
  }

  @Test("organization push includes the immutable organization identity")
  func organizationPushIncludesImmutableOrganizationIdentity() async throws {
    let organizationID = "11111111-1111-4111-8111-111111111111"
    let recorder = RequestRecorder()
    let service = makeSyncService(recorder: recorder) { _ in .status(400) }
    let wrappedKeys = [
      SyncService.WrappedMemberKey(
        userId: "user-1",
        wrappedKey: "wrapped-key-1",
        publicKeyVersion: 4,
        publicKeyFingerprint: "fingerprint-1"
      ),
      SyncService.WrappedMemberKey(
        userId: "user-2",
        wrappedKey: "wrapped-key-2",
        publicKeyVersion: 7,
        publicKeyFingerprint: "fingerprint-2"
      ),
    ]
    let schema = LPMJSONValue.object([
      "API_URL": .object([
        "description": .string("Service endpoint"),
        "required": .bool(true),
      ])
    ])

    _ = await service.pushOrg(
      authToken: "session-token",
      orgSlug: "acme",
      expectedOrganizationID: organizationID,
      expectedCallerUserID: "user-1",
      vaultId: "vault-1",
      encryptedBlob: "ciphertext",
      wrappedKeys: wrappedKeys,
      expectedVersion: 2,
      name: "Production",
      schema: schema
    )

    let request = try #require(recorder.requests.first)
    let data = try requestBodyData(request)
    let body = try JSONDecoder().decode(LPMJSONValue.self, from: data)
    #expect(
      body
        == .object([
          "encryptedBlob": .string("ciphertext"),
          "cryptoVersion": .integer(Int64(VaultCrypto.currentCryptoVersion)),
          "ciphertextRevision": .integer(3),
          "expectedOrganizationId": .string(organizationID),
          "expectedCallerUserId": .string("user-1"),
          "wrappedKeys": .array([
            .object([
              "userId": .string("user-1"),
              "wrappedKey": .string("wrapped-key-1"),
              "publicKeyVersion": .integer(4),
              "publicKeyFingerprint": .string("fingerprint-1"),
            ]),
            .object([
              "userId": .string("user-2"),
              "wrappedKey": .string("wrapped-key-2"),
              "publicKeyVersion": .integer(7),
              "publicKeyFingerprint": .string("fingerprint-2"),
            ]),
          ]),
          "expectedVersion": .integer(2),
          "name": .string("Production"),
          "schema": schema,
        ])
    )
  }

  @Test("personal recreation push sends explicit authenticated revision intent")
  func personalRecreationPushBodyContract() async throws {
    let recorder = RequestRecorder()
    let service = makeSyncService(recorder: recorder) { _ in .status(400) }

    _ = await service.push(
      authToken: "session-token",
      expectedPrincipalId: "account-1",
      vaultId: "vault-1",
      encryptedBlob: "ciphertext",
      wrappedKey: "wrapped-key",
      expectedVersion: 5,
      force: true,
      recreateMissing: true,
      name: "Production"
    )
    _ = await service.push(
      authToken: "session-token",
      expectedPrincipalId: "account-1",
      vaultId: "vault-2",
      encryptedBlob: "ciphertext",
      wrappedKey: "wrapped-key",
      expectedVersion: 5,
      force: true,
      recreateMissing: false,
      name: "Production"
    )

    let recreationRequest = try #require(recorder.requests.first)
    let recreationBody = try JSONDecoder().decode(
      LPMJSONValue.self,
      from: requestBodyData(recreationRequest)
    )
    #expect(
      recreationBody
        == .object([
          "encryptedBlob": .string("ciphertext"),
          "wrappedKey": .string("wrapped-key"),
          "cryptoVersion": .integer(Int64(VaultCrypto.currentCryptoVersion)),
          "ciphertextRevision": .integer(6),
          "expectedPrincipalId": .string("account-1"),
          "expectedVersion": .integer(5),
          "force": .bool(true),
          "recreateMissing": .bool(true),
          "name": .string("Production"),
        ])
    )

    let ordinaryForceRequest = try #require(recorder.requests.dropFirst().first)
    let ordinaryForceBody = try JSONDecoder().decode(
      LPMJSONValue.self,
      from: requestBodyData(ordinaryForceRequest)
    )
    guard case .object(let fields) = ordinaryForceBody else {
      Issue.record("Expected a JSON object request body")
      return
    }
    #expect(fields["recreateMissing"] == nil)
  }

  @Test("organization push preserves exact actionable Registry failures")
  func organizationPushPreservesActionableFailures() async {
    let fixtures: [(
      status: Int, outcome: String, data: [String: Any], code: String, displayError: String
    )] = [
      (
        403,
        "memberRewrapRequired",
        ["currentRevision": 4],
        "vault_member_needs_rewrap",
        "Organization env key must be rewrapped for this member"
      ),
      (
        409,
        "contentKeyRotationRequired",
        ["currentRevision": 4],
        "vault_content_key_rotation_required",
        "The organization content key must be rotated"
      ),
      (
        409,
        "rejected",
        [
          "code": "vault_recipient_key_conflict",
          "message": "An organization member's sharing key changed. Fetch the current recipient keys and retry.",
        ],
        "vault_recipient_key_conflict",
        "An organization member's sharing key changed. Fetch the current recipient keys and retry."
      ),
      (
        409,
        "rejected",
        [
          "code": "ORG_ENV_ID_CHANGED",
          "message": "Organization identity changed while the encrypted env write was in progress",
        ],
        "ORG_ENV_ID_CHANGED",
        "Organization identity changed while the encrypted env write was in progress"
      ),
      (
        409,
        "rejected",
        [
          "code": "ORG_ENV_SLUG_CHANGED",
          "message": "Organization slug changed while the encrypted env write was in progress",
        ],
        "ORG_ENV_SLUG_CHANGED",
        "Organization slug changed while the encrypted env write was in progress"
      ),
      (
        409,
        "rejected",
        [
          "code": "vault_crypto_version_downgrade",
          "message": "Env crypto version downgrade rejected",
        ],
        "vault_crypto_version_downgrade",
        "Env crypto version downgrade rejected"
      ),
      (
        403,
        "rejected",
        [
          "code": "vault_org_role_changed",
          "message": "Only current organization owners and admins can replace wrapped keys",
        ],
        "vault_org_role_changed",
        "Only current organization owners and admins can replace wrapped keys"
      ),
    ]

    for fixture in fixtures {
      let service = makeSyncService { request in
        let nonce = try #require(
          request.value(forHTTPHeaderField: "X-LPM-Vault-Request-Nonce")
        )
        return try signedSyncResponse(
          vaultEnvelope(
            operation: "vault.write",
            outcome: fixture.outcome,
            requestNonce: nonce,
            binding: [
              "scope": "organization",
              "principalId": "11111111-1111-4111-8111-111111111111",
              "callerUserId": "user-1",
              "organizationSlug": "acme",
              "vaultId": "vault-1",
            ],
            data: fixture.data
          ),
          token: "session-token",
          statusCode: fixture.status
        )
      }
      let response = await service.pushOrg(
        authToken: "session-token",
        orgSlug: "acme",
        expectedOrganizationID: "11111111-1111-4111-8111-111111111111",
        expectedCallerUserID: "user-1",
        vaultId: "vault-1",
        encryptedBlob: "ciphertext",
        wrappedKeys: nil,
        expectedVersion: 3
      )

      #expect(response?.code == fixture.code)
      #expect(response?.displayError == fixture.displayError)
    }
  }

  @Test("organization push rejects malformed Registry failure envelopes")
  func organizationPushRejectsMalformedFailures() async throws {
    let rewrapError =
      "Org vault exists on the server but you don't have a wrapped key for it yet, so you can't pull it. Ask an existing org owner or admin to re-share the vault with you before pushing."
    let recipientError =
      "An organization member's sharing key changed. Fetch the current recipient keys and retry."
    let recipientID = "11111111-1111-4111-8111-111111111111"
    let fixtures: [(Int, [String: Any])] = [
      (400, ["error": rewrapError, "code": "vault_member_needs_rewrap", "serverVersion": 4]),
      (409, ["error": "Wrong error", "code": "vault_member_needs_rewrap", "serverVersion": 4]),
      (409, ["error": rewrapError, "code": "vault_member_needs_rewrap"]),
      (409, ["error": rewrapError, "code": "vault_member_needs_rewrap", "serverVersion": 0]),
      (
        409,
        [
          "error": rewrapError, "code": "vault_member_needs_rewrap",
          "serverVersion": Int(Int32.max) + 1,
        ]
      ),
      (
        409,
        [
          "error": "Version conflict", "code": "vault_version_conflict",
          "serverVersion": Int(Int32.max) + 1,
        ]
      ),
      (
        409,
        [
          "error": recipientError, "code": "vault_recipient_key_conflict", "serverVersion": 4,
          "userId": recipientID,
        ]
      ),
      (
        409,
        [
          "error": rewrapError, "code": "vault_member_needs_rewrap", "serverVersion": 4,
          "vaultId": "vault-1",
        ]
      ),
      (
        409,
        [
          "error": rewrapError, "code": "vault_member_needs_rewrap", "serverVersion": 4,
          "hint": String(repeating: "h", count: 2_049),
        ]
      ),
      (
        409,
        [
          "error": rewrapError, "code": "vault_member_needs_rewrap", "serverVersion": 4,
          "hint": "retry\nnow",
        ]
      ),
      (
        409,
        [
          "error": recipientError, "code": "vault_recipient_key_conflict",
          "userId": String(repeating: "u", count: 2_049),
        ]
      ),
      (
        409, ["error": recipientError, "code": "vault_recipient_key_conflict", "userId": "user\t1"]
      ),
      (409, ["error": recipientError, "code": "vault_recipient_key_conflict"]),
      (
        409,
        ["error": recipientError, "code": "vault_recipient_key_conflict", "userId": "not-a-uuid"]
      ),
      (409, ["error": "Unknown", "code": "unknown_failure"]),
    ]

    for (statusCode, payload) in fixtures {
      let body = try JSONSerialization.data(withJSONObject: payload)
      let service = makeSyncService { _ in
        MockResponse(
          statusCode: statusCode,
          body: body,
          headers: ["Content-Type": "application/json"]
        )
      }
      let response = await service.pushOrg(
        authToken: "session-token",
        orgSlug: "acme",
        expectedOrganizationID: recipientID,
        expectedCallerUserID: "user-1",
        vaultId: "vault-1",
        encryptedBlob: "ciphertext",
        wrappedKeys: nil,
        expectedVersion: 3
      )

      #expect(response == nil)
    }
  }

  @Test("sync unauthorized response clears cached account state")
  @MainActor
  func syncUnauthorizedClearsIdentity() async {
    let service = makeSyncService { _ in
      MockResponse(
        statusCode: 401,
        body: Data(#"{"error":"unauthorized"}"#.utf8),
        headers: ["Content-Type": "application/json"]
      )
    }
    let keychain = MockKeychainService()
    keychain.envStorage["unauthorized"] = (
      name: "Unauthorized",
      path: "",
      environments: ["default": ["TOKEN": "local"]]
    )
    let store = VaultStore(
      keychainService: keychain,
      biometricService: MockBiometricService(),
      apiService: MockAPIService(),
      personalSyncServiceFactory: { _ in service },
      authTokenProvider: { _, _ in "rejected-session" }
    )
    store.currentUser = LPMUser(
      id: "account-a",
      username: "account-a",
      name: nil,
      email: nil,
      avatarUrl: nil,
      plan: nil,
      createdAt: nil,
      orgs: []
    )
    store.projects = [
      VaultProject(
        id: "unauthorized",
        name: "Unauthorized",
        path: "",
        environments: ["default": ["TOKEN": "local"]]
      )
    ]
    store.isUnlocked = true
    store.selectProject("unauthorized")

    await store.pullFromCloud()

    #expect(store.currentUser == nil)
    #expect(store.lastSyncStatus == nil)
  }

  @Test("live personal 409 conflict reaches the conflict-resolution state")
  @MainActor
  func personalConflictPropagation() async throws {
    let service = makeSyncService { request in
      if request.url?.query == "versionOnly=true" {
        let nonce = try #require(
          request.value(forHTTPHeaderField: "X-LPM-Vault-Request-Nonce")
        )
        return try signedSyncResponse(
          vaultEnvelope(
            operation: "vault.inspect",
            outcome: "current",
            requestNonce: nonce,
            binding: [
              "scope": "personal",
              "principalId": "account-1",
              "callerUserId": "account-1",
              "vaultId": "vault-1",
            ],
            data: [
              "revision": 7,
              "cryptoVersion": VaultCrypto.currentCryptoVersion,
            ]
          ),
          token: "session-token"
        )
      }
      let nonce = try #require(
        request.value(forHTTPHeaderField: "X-LPM-Vault-Request-Nonce")
      )
      return try signedSyncResponse(
        vaultEnvelope(
          operation: "vault.write",
          outcome: "revisionConflict",
          requestNonce: nonce,
          binding: [
            "scope": "personal",
            "principalId": "account-1",
            "callerUserId": "account-1",
            "vaultId": "vault-1",
          ],
          data: ["currentRevision": 9]
        ),
        token: "session-token",
        statusCode: 409
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
      stableSyncEncryptor: { _, _, _, _ in ("request-ciphertext", "request-wrapped") },
      authTokenProvider: { _, _ in "session-token" }
    )
    store.currentUser = LPMUser(
      id: "account-1",
      username: "user",
      name: nil,
      email: nil,
      avatarUrl: nil,
      plan: nil,
      createdAt: nil,
      orgs: nil
    )
    store.projects = [
      VaultProject(
        id: "vault-1",
        name: "Conflict",
        path: "",
        environments: ["default": ["TOKEN": "local"]]
      )
    ]
    let metadata = SyncMetadata(
      lastSyncedAt: Date(),
      lastAction: "pull",
      lastVersion: 7,
      isDirty: false,
      binding: SyncPrincipalBinding(
        registryURL: store.appEnvironment.registryURL,
        principalID: "account-1",
        scope: "personal"
      )
    )
    store.syncMetadata["vault-1"] = metadata
    #expect(keychain.seedSyncMetadata(["vault-1": metadata]))
    store.isUnlocked = true
    store.selectProject("vault-1")

    await store.pushToCloud()

    #expect(store.lastSyncStatus == "conflict")
    #expect(store.error == "The cloud env project changed. Pull the latest version before pushing.")
  }

  @Test("authenticated sync envelope binds a personal payload to its request")
  func authenticatedPersonalSyncEnvelope() async throws {
    let recorder = RequestRecorder()
    let service = makeSyncService(recorder: recorder) { request in
      let nonce = try #require(
        request.value(forHTTPHeaderField: "X-LPM-Vault-Request-Nonce")
      )
      #expect(nonce.count == 43)
      #expect(
        nonce.utf8.allSatisfy {
          ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90)
            || ($0 >= 97 && $0 <= 122) || $0 == 45 || $0 == 95
        })
      return try signedSyncResponse(
        personalPullEnvelope(requestNonce: nonce),
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

  @Test("authenticated write envelope accepts the exact request binding")
  func authenticatedPersonalWriteEnvelope() async throws {
    let service = makeSyncService { request in
      let nonce = try #require(
        request.value(forHTTPHeaderField: "X-LPM-Vault-Request-Nonce")
      )
      return try signedSyncResponse(
        personalWriteEnvelope(requestNonce: nonce),
        token: "session-token"
      )
    }

    let response = await service.push(
      authToken: "session-token",
      expectedPrincipalId: "account-1",
      vaultId: "vault-1",
      encryptedBlob: "new-ciphertext",
      wrappedKey: "new-wrapped"
    )

    #expect(response?.version == 8)
    #expect(response?.status == "synced")
  }

  @Test("authenticated sync envelope rejects substitution replay downgrade and missing bindings")
  func authenticatedSyncEnvelopeRejectsInvalidBindings() async throws {
    let invalidEnvelopes = [
      "cross-vault",
      "replay",
      "scope-substitution",
      "missing-principal-id",
      "missing-envelope-version",
      "missing-revision",
      "crypto-version-downgrade",
      "payload-substitution",
    ]

    for name in invalidEnvelopes {
      let service = makeSyncService { request in
        let nonce = try #require(
          request.value(forHTTPHeaderField: "X-LPM-Vault-Request-Nonce")
        )
        var envelope = personalPullEnvelope(requestNonce: nonce)
        switch name {
        case "cross-vault":
          var binding = try #require(envelope["binding"] as? [String: Any])
          binding["vaultId"] = "vault-2"
          envelope["binding"] = binding
        case "replay": envelope["requestNonce"] = String(repeating: "A", count: 43)
        case "scope-substitution":
          var binding = try #require(envelope["binding"] as? [String: Any])
          binding["scope"] = "organization"
          envelope["binding"] = binding
        case "missing-principal-id":
          var binding = try #require(envelope["binding"] as? [String: Any])
          binding.removeValue(forKey: "principalId")
          envelope["binding"] = binding
        case "missing-envelope-version": envelope.removeValue(forKey: "envelopeVersion")
        case "missing-revision":
          var data = try #require(envelope["data"] as? [String: Any])
          data.removeValue(forKey: "revision")
          envelope["data"] = data
        case "crypto-version-downgrade":
          var data = try #require(envelope["data"] as? [String: Any])
          data["cryptoVersion"] = VaultCrypto.currentCryptoVersion - 1
          envelope["data"] = data
        case "payload-substitution":
          let signed = try signedSyncResponse(envelope, token: "session-token")
          var data = try #require(envelope["data"] as? [String: Any])
          data["encryptedBlob"] = "other-ciphertext"
          envelope["data"] = data
          return MockResponse(
            statusCode: signed.statusCode,
            body: try JSONSerialization.data(
              withJSONObject: envelope,
              options: [.sortedKeys]
            ),
            headers: signed.headers
          )
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

  @Test("authenticated sync rejects revision-unbound legacy pulls and writes")
  func authenticatedSyncLegacyVersionPolicy() async throws {
    for cryptoVersion in [1, 2] {
      let legacyPull = makeSyncService { request in
        let nonce = try #require(
          request.value(forHTTPHeaderField: "X-LPM-Vault-Request-Nonce")
        )
        return try signedSyncResponse(
          [
            "vaultId": "vault-1",
            "version": 7,
            "serverVersion": 7,
            "cryptoVersion": cryptoVersion,
            "envelopeVersion": 2,
            "scope": "personal",
            "requestNonce": nonce,
            "encryptedBlob": "legacy-ciphertext",
            "wrappedKey": "legacy-wrapped",
          ],
          token: "session-token"
        )
      }

      let pulled = await legacyPull.pull(
        authToken: "session-token",
        vaultId: "vault-1"
      )

      #expect(pulled == nil)
    }

    let legacyPush = makeSyncService { request in
      let nonce = try #require(
        request.value(forHTTPHeaderField: "X-LPM-Vault-Request-Nonce")
      )
      return try signedSyncResponse(
        [
          "vaultId": "vault-1",
          "version": 8,
          "serverVersion": 8,
          "cryptoVersion": 1,
          "envelopeVersion": 2,
          "scope": "personal",
          "requestNonce": nonce,
        ],
        token: "session-token"
      )
    }

    let pushed = await legacyPush.push(
      authToken: "session-token",
      expectedPrincipalId: "account-1",
      vaultId: "vault-1",
      encryptedBlob: "ciphertext",
      wrappedKey: "wrapped"
    )

    #expect(pushed == nil)
  }

  @Test("authenticated pull requires payload fields and write responses forbid them")
  func authenticatedSyncPayloadShapePolicy() async throws {
    let payloadlessPull = makeSyncService { request in
      let nonce = try #require(
        request.value(forHTTPHeaderField: "X-LPM-Vault-Request-Nonce")
      )
      var envelope = personalPullEnvelope(requestNonce: nonce)
      var data = try #require(envelope["data"] as? [String: Any])
      data.removeValue(forKey: "wrappedKey")
      envelope["data"] = data
      return try signedSyncResponse(
        envelope,
        token: "session-token"
      )
    }
    #expect(
      await payloadlessPull.pull(
        authToken: "session-token",
        vaultId: "vault-1"
      ) == nil)

    let payloadBearingWrite = makeSyncService { request in
      let nonce = try #require(
        request.value(forHTTPHeaderField: "X-LPM-Vault-Request-Nonce")
      )
      var envelope = personalWriteEnvelope(requestNonce: nonce)
      var data = try #require(envelope["data"] as? [String: Any])
      data["encryptedBlob"] = "ciphertext"
      envelope["data"] = data
      return try signedSyncResponse(envelope, token: "session-token")
    }
    #expect(
      await payloadBearingWrite.push(
        authToken: "session-token",
        expectedPrincipalId: "account-1",
        vaultId: "vault-1",
        encryptedBlob: "new-ciphertext",
        wrappedKey: "new-wrapped"
      ) == nil)
  }

  @Test("version preflight is metadata-only and distinguishes authenticated not-found")
  func versionPreflightContract() async throws {
    let found = makeSyncService { request in
      #expect(request.url?.query == "versionOnly=true")
      let nonce = try #require(
        request.value(forHTTPHeaderField: "X-LPM-Vault-Request-Nonce")
      )
      return try signedSyncResponse(
        vaultEnvelope(
          operation: "vault.inspect",
          outcome: "current",
          requestNonce: nonce,
          binding: [
            "scope": "personal",
            "principalId": "account-1",
            "callerUserId": "account-1",
            "vaultId": "vault-1",
          ],
          data: [
            "revision": 8,
            "cryptoVersion": VaultCrypto.currentCryptoVersion,
          ]
        ),
        token: "session-token"
      )
    }
    guard
      case .response(.found(let status)) = await found.versionPreflightAuthenticated(
        authToken: "session-token",
        vaultId: "vault-1"
      )
    else {
      Issue.record("Rejected a valid signed version-only response")
      return
    }
    #expect(status.version == 8)

    let missing = makeSyncService { request in
      #expect(request.url?.query == "versionOnly=true")
      let nonce = try #require(
        request.value(forHTTPHeaderField: "X-LPM-Vault-Request-Nonce")
      )
      return try signedSyncResponse(
        vaultEnvelope(
          operation: "vault.inspect",
          outcome: "missing",
          requestNonce: nonce,
          binding: [
            "scope": "personal",
            "principalId": "account-1",
            "callerUserId": "account-1",
            "vaultId": "vault-1",
          ],
          data: ["retainedRevision": 0]
        ),
        token: "session-token",
        statusCode: 404
      )
    }
    guard
      case .response(.notFound) = await missing.versionPreflightAuthenticated(
        authToken: "session-token",
        vaultId: "vault-1"
      )
    else {
      Issue.record("Did not preserve the version-only not-found state")
      return
    }

    let malformed = makeSyncService { _ in
      MockResponse(
        statusCode: 404,
        body: Data(#"{"error":"different"}"#.utf8),
        headers: ["Content-Type": "application/json"]
      )
    }
    guard
      case .response(nil) = await malformed.versionPreflightAuthenticated(
        authToken: "session-token",
        vaultId: "vault-1"
      )
    else {
      Issue.record("Accepted a malformed version-only not-found response")
      return
    }
  }

  @Test("authenticated organization envelope accepts the exact request binding")
  func authenticatedOrganizationSyncEnvelope() async throws {
    let service = makeSyncService { request in
      let nonce = try #require(
        request.value(forHTTPHeaderField: "X-LPM-Vault-Request-Nonce")
      )
      return try signedSyncResponse(
        organizationPullEnvelope(requestNonce: nonce),
        token: "session-token"
      )
    }

    let response = await service.pullOrg(
      authToken: "session-token",
      orgSlug: "acme",
      vaultId: "vault-1"
    )

    #expect(response?.vaultId == "vault-1")
    #expect(response?.version == 4)
  }

  @Test("authenticated organization envelope rejects a substituted organization slug")
  func authenticatedOrganizationPullRejectsSlugSubstitution() async throws {
    let service = makeSyncService { request in
      let nonce = try #require(
        request.value(forHTTPHeaderField: "X-LPM-Vault-Request-Nonce")
      )
      var envelope = organizationPullEnvelope(requestNonce: nonce)
      var binding = try #require(envelope["binding"] as? [String: Any])
      binding["organizationSlug"] = "other-org"
      envelope["binding"] = binding
      return try signedSyncResponse(
        envelope,
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

  @Test("authenticated organization pulls require a caller identity")
  func authenticatedOrganizationPullRequiresCallerIdentity() async throws {
    let service = makeSyncService { request in
      let nonce = try #require(
        request.value(forHTTPHeaderField: "X-LPM-Vault-Request-Nonce")
      )
      var envelope = organizationPullEnvelope(requestNonce: nonce)
      var binding = try #require(envelope["binding"] as? [String: Any])
      binding.removeValue(forKey: "callerUserId")
      envelope["binding"] = binding
      return try signedSyncResponse(envelope, token: "session-token")
    }

    let response = await service.pullOrg(
      authToken: "session-token",
      orgSlug: "acme",
      vaultId: "vault-1"
    )

    #expect(response == nil)
  }

  @Test("organization member inventory is signed and bound to the request")
  func authenticatedOrganizationMemberInventory() async throws {
    let organizationID = "11111111-1111-4111-8111-111111111111"
    let publicKeyData = Data(repeating: 7, count: 32)
    let publicKey = publicKeyData.base64EncodedString()
    let fingerprint = VaultCrypto.publicKeyFingerprint(publicKeyData)
    let service = makeSyncService { request in
      let nonce = try #require(
        request.value(forHTTPHeaderField: "X-LPM-Vault-Request-Nonce")
      )
      return try signedSyncResponse(
        vaultEnvelope(
          operation: "organization.memberKeys.read",
          outcome: "current",
          requestNonce: nonce,
          binding: [
            "scope": "organization",
            "principalId": organizationID,
            "callerUserId": "user-1",
            "organizationSlug": "acme",
          ],
          data: [
            "capability": "replaceWrappedKeysAllowed",
            "members": [
              [
                "userId": "user-1",
                "role": "owner",
                "sharingKey": [
                  "algorithm": "X25519",
                  "publicKey": publicKey,
                  "version": 2,
                  "fingerprint": fingerprint,
                ],
              ]
            ],
          ]
        ),
        token: "session-token"
      )
    }

    let access = await service.getOrgMemberKeyAccess(
      authToken: "session-token",
      expectedCallerUserID: "user-1",
      orgSlug: "acme"
    )

    #expect(access?.organizationID == organizationID)
    #expect(access?.callerUserID == "user-1")
    #expect(access?.members.first?.publicKey == publicKey)
    let members = try #require(access?.members)
    var decodeCount = 0
    var fingerprintCount = 0
    _ = try OrganizationMemberAuthorizationPolicy.prepare(
      members,
      trust: OrgKeyTrust(),
      decodePublicKey: { encoded in
        decodeCount += 1
        return Data(base64Encoded: encoded)
      },
      fingerprintPublicKey: { key in
        fingerprintCount += 1
        return VaultCrypto.publicKeyFingerprint(key)
      }
    )
    #expect(decodeCount == 0)
    #expect(fingerprintCount == 0)
  }

  @Test("organization member inventory rejects a caller substitution")
  func authenticatedOrganizationMemberInventoryRejectsCallerSubstitution() async throws {
    let service = makeSyncService { request in
      let nonce = try #require(
        request.value(forHTTPHeaderField: "X-LPM-Vault-Request-Nonce")
      )
      return try signedSyncResponse(
        vaultEnvelope(
          operation: "organization.memberKeys.read",
          outcome: "current",
          requestNonce: nonce,
          binding: [
            "scope": "organization",
            "principalId": "11111111-1111-4111-8111-111111111111",
            "callerUserId": "user-2",
            "organizationSlug": "acme",
          ],
          data: [
            "capability": "replaceWrappedKeysForbidden",
            "members": [
              ["userId": "user-2", "role": "member", "sharingKey": NSNull()]
            ],
          ]
        ),
        token: "session-token"
      )
    }

    let access = await service.getOrgMemberKeyAccess(
      authToken: "session-token",
      expectedCallerUserID: "user-1",
      orgSlug: "acme"
    )

    #expect(access == nil)
  }

  @Test("organization member inventory accepts the registry's 10,000-member contract")
  func authenticatedOrganizationMemberInventoryLimit() throws {
    let members: [[String: Any]] = (0..<10_000).map { index in
      [
        "userId": String(format: "member-%05d", index),
        "role": index == 0 ? "owner" : "member",
        "sharingKey": NSNull(),
      ]
    }
    let nonce = String(repeating: "A", count: 43)
    let body = try JSONSerialization.data(
      withJSONObject: vaultEnvelope(
        operation: "organization.memberKeys.read",
        outcome: "current",
        requestNonce: nonce,
        binding: [
          "scope": "organization",
          "principalId": "11111111-1111-4111-8111-111111111111",
          "callerUserId": "member-00000",
          "organizationSlug": "acme",
        ],
        data: [
          "capability": "replaceWrappedKeysAllowed",
          "members": members,
        ]
      )
    )

    let access = try AuthenticatedVaultEnvelopeParser.decodeMemberInventory(
      body,
      statusCode: 200,
      requestNonce: nonce,
      organizationSlug: "acme",
      expectedCallerUserID: "member-00000"
    )

    #expect(access.members.count == 10_000)
  }

  @Test("sharing-key reads are signed and bound to the principal")
  func authenticatedSharingKeyRead() async throws {
    let publicKeyData = Data(repeating: 7, count: 32)
    let publicKey = publicKeyData.base64EncodedString()
    let fingerprint = VaultCrypto.publicKeyFingerprint(publicKeyData)
    let service = makeSyncService { request in
      let nonce = try #require(
        request.value(forHTTPHeaderField: "X-LPM-Vault-Request-Nonce")
      )
      return try signedSyncResponse(
        vaultEnvelope(
          operation: "sharingKey.read",
          outcome: "present",
          requestNonce: nonce,
          binding: ["scope": "account", "principalId": "account-1"],
          data: [
            "sharingKey": [
              "algorithm": "X25519",
              "publicKey": publicKey,
              "version": 2,
              "fingerprint": fingerprint,
              "createdAt": "2026-09-05T12:00:00.000Z",
              "updatedAt": "2026-09-05T12:00:00.000Z",
            ]
          ]
        ),
        token: "session-token"
      )
    }

    let record = await service.getMyPublicKey(
      authToken: "session-token",
      expectedPrincipalId: "account-1"
    )

    #expect(record?.principalId == "account-1")
    #expect(record?.publicKey == publicKey)
  }

  @Test("sharing-key reads reject an authenticated principal substitution")
  func authenticatedSharingKeyReadRejectsPrincipalSubstitution() async throws {
    let service = makeSyncService { request in
      let nonce = try #require(
        request.value(forHTTPHeaderField: "X-LPM-Vault-Request-Nonce")
      )
      return try signedSyncResponse(
        vaultEnvelope(
          operation: "sharingKey.read",
          outcome: "absent",
          requestNonce: nonce,
          binding: ["scope": "account", "principalId": "account-2"],
          data: [:]
        ),
        token: "session-token"
      )
    }

    let record = await service.getMyPublicKey(
      authToken: "session-token",
      expectedPrincipalId: "account-1"
    )

    #expect(record == nil)
  }

  @Test("sharing-key writes require an authoritative signed reread")
  func authenticatedSharingKeyWriteRequiresAuthoritativeReread() async throws {
    let publicKeyData = Data(repeating: 7, count: 32)
    let publicKey = publicKeyData.base64EncodedString()
    let fingerprint = VaultCrypto.publicKeyFingerprint(publicKeyData)
    let recorder = RequestRecorder()
    let service = makeSyncService(recorder: recorder) { request in
      let nonce = try #require(
        request.value(forHTTPHeaderField: "X-LPM-Vault-Request-Nonce")
      )
      let isWrite = request.httpMethod == "POST"
      return try signedSyncResponse(
        vaultEnvelope(
          operation: isWrite ? "sharingKey.write" : "sharingKey.read",
          outcome: isWrite ? "set" : "absent",
          requestNonce: nonce,
          binding: ["scope": "account", "principalId": "account-1"],
          data: isWrite
            ? [
              "sharingKey": [
                "algorithm": "X25519",
                "publicKey": publicKey,
                "version": 1,
                "fingerprint": fingerprint,
                "createdAt": "2026-09-05T12:00:00.000Z",
                "updatedAt": "2026-09-05T12:00:00.000Z",
              ]
            ]
            : [:]
        ),
        token: "session-token"
      )
    }

    let response = await service.uploadPublicKey(
      authToken: "session-token",
      expectedPrincipalId: "account-1",
      publicKey: publicKey
    )

    #expect(response == nil)
    #expect(recorder.requests.count == 2)
  }

  private func personalPullEnvelope(requestNonce: String) -> [String: Any] {
    vaultEnvelope(
      operation: "vault.pull",
      outcome: "current",
      requestNonce: requestNonce,
      binding: [
        "scope": "personal",
        "principalId": "account-1",
        "callerUserId": "account-1",
        "vaultId": "vault-1",
      ],
      data: [
        "revision": 7,
        "cryptoVersion": VaultCrypto.currentCryptoVersion,
        "encryptedBlob": "ciphertext",
        "wrappedKey": "wrapped",
        "updatedAt": "2026-09-05T12:00:00.000Z",
      ]
    )
  }

  private func personalWriteEnvelope(requestNonce: String) -> [String: Any] {
    vaultEnvelope(
      operation: "vault.write",
      outcome: "committed",
      requestNonce: requestNonce,
      binding: [
        "scope": "personal",
        "principalId": "account-1",
        "callerUserId": "account-1",
        "vaultId": "vault-1",
      ],
      data: [
        "revision": 8,
        "cryptoVersion": VaultCrypto.currentCryptoVersion,
        "action": "synced",
      ]
    )
  }

  private func organizationPullEnvelope(requestNonce: String) -> [String: Any] {
    vaultEnvelope(
      operation: "vault.pull",
      outcome: "current",
      requestNonce: requestNonce,
      binding: [
        "scope": "organization",
        "principalId": "11111111-1111-4111-8111-111111111111",
        "callerUserId": "user-1",
        "organizationSlug": "acme",
        "vaultId": "vault-1",
      ],
      data: [
        "revision": 4,
        "cryptoVersion": VaultCrypto.currentCryptoVersion,
        "encryptedBlob": "ciphertext",
        "wrappedKey": "wrapped",
        "updatedAt": "2026-09-05T12:00:00.000Z",
        "contentKeyVersion": 2,
        "recipientPublicKeyVersion": 3,
        "recipientPublicKeyFingerprint": String(repeating: "a", count: 64),
      ]
    )
  }

  private func vaultEnvelope(
    operation: String,
    outcome: String,
    requestNonce: String,
    binding: [String: Any],
    data: [String: Any]
  ) -> [String: Any] {
    [
      "envelopeVersion": 3,
      "operation": operation,
      "outcome": outcome,
      "requestNonce": requestNonce,
      "binding": binding,
      "data": data,
    ]
  }

  private func signedSyncResponse(
    _ object: [String: Any],
    token _: String,
    statusCode: Int = 200
  ) throws -> MockResponse {
    let body = try JSONSerialization.data(
      withJSONObject: object,
      options: [.sortedKeys]
    )
    let keyID = "vault-test-rfc8032"
    let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: Data([
      0x9d, 0x61, 0xb1, 0x9d, 0xef, 0xfd, 0x5a, 0x60,
      0xba, 0x84, 0x4a, 0xf4, 0x92, 0xec, 0x2c, 0xc4,
      0x44, 0x49, 0xc5, 0x69, 0x7b, 0x32, 0x69, 0x19,
      0x70, 0x3b, 0xac, 0x03, 0x1c, 0xae, 0x7f, 0x60,
    ]))
    var frame = Data("lpm-authenticated-response\0".utf8)
    frame.append(4)
    var status = try #require(UInt16(exactly: statusCode)).bigEndian
    Swift.withUnsafeBytes(of: &status) { frame.append(contentsOf: $0) }
    frame.append(UInt8(keyID.utf8.count))
    frame.append(contentsOf: keyID.utf8)
    var bodyLength = UInt64(body.count).bigEndian
    Swift.withUnsafeBytes(of: &bodyLength) { frame.append(contentsOf: $0) }
    frame.append(contentsOf: SHA256.hash(data: body))
    let signature = try privateKey.signature(for: frame)
      .base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
    return MockResponse(
      statusCode: statusCode,
      body: body,
      headers: [
        "Content-Type": "application/json",
        "X-LPM-Response-Key-ID": keyID,
        "X-LPM-Response-Signature": signature,
      ]
    )
  }

  private func requestBodyData(_ request: URLRequest) throws -> Data {
    if let body = request.httpBody { return body }
    let stream = try #require(request.httpBodyStream)
    stream.open()
    defer { stream.close() }

    var body = Data()
    var buffer = [UInt8](repeating: 0, count: 4_096)
    while stream.hasBytesAvailable {
      let count = stream.read(&buffer, maxLength: buffer.count)
      if count < 0 { throw stream.streamError ?? URLError(.cannotDecodeContentData) }
      if count == 0 { break }
      body.append(buffer, count: count)
    }
    return body
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
      session: URLSession(
        configuration: configuration,
        delegate: BoundedHTTPResponseDelegate(),
        delegateQueue: nil
      )
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
      session: URLSession(
        configuration: configuration,
        delegate: BoundedHTTPResponseDelegate(),
        delegateQueue: nil
      ),
      responseSignatureVerifier: { response, body, required in
        PinnedSessionDelegate.verifyResponseSignatureForTesting(
          response,
          body: body,
          requireSignature: required,
          trustedSigningKeys: [
            "vault-test-rfc8032": Data([
              0xd7, 0x5a, 0x98, 0x01, 0x82, 0xb1, 0x0a, 0xb7,
              0xd5, 0x4b, 0xfe, 0xd3, 0xc9, 0x64, 0x07, 0x3a,
              0x0e, 0xe1, 0x72, 0xf3, 0xda, 0xa6, 0x23, 0x25,
              0xaf, 0x02, 0x1a, 0x68, 0xf7, 0x07, 0x51, 0x1a,
            ])
          ]
        )
      }
    )
  }
}

private struct PreciseSchemaNumbers: Decodable {
  let fractional: Decimal
  let large: Decimal
}

private struct DecodeProbeResponse: Sendable {}

private final class DecodeCallCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0

  var callCount: Int {
    lock.withLock { count }
  }

  func record() {
    lock.withLock { count += 1 }
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
        )
      else { throw URLError(.badURL) }
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: stub.body)
      client?.urlProtocolDidFinishLoading(self)
    } catch {
      client?.urlProtocol(self, didFailWithError: error)
    }
  }

  override func stopLoading() {}
}
