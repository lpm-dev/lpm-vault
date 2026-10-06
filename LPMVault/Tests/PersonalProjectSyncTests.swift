import CryptoKit
import Foundation
import Testing

@testable import LPMVault

@Suite("Personal project key sync")
struct PersonalProjectSyncTests {
  @Test("new personal pushes prepare project keys and fresh content without starting a write")
  func newPushUsesProjectKeys() async throws {
    let fixture = PersonalSyncFixture()
    fixture.missingRevision = 0
    let service = fixture.service()
    let prepared = try await prepare(service)
    #expect(fixture.writeCount == 0)
    #expect(fixture.rootCreates == 1)
    let result = try #require(await prepared.start().value().value)
    let envelope = try #require(result.personalKeys)
    #expect(result.version == 1)
    #expect(envelope.projectKeyVersion == 1)
    let written = try #require(fixture.lastWrite)
    let project = try PersonalProjectCrypto.open(
      root: fixture.root, envelope: envelope, registryURL: fixture.origin, principalID: "user-a",
      vaultID: "project-a")
    let plaintext = try PersonalProjectCrypto.decrypt(
      project: project, encryptedBlob: #require(written["encryptedBlob"] as? String),
      wrappedKey: #require(written["wrappedKey"] as? String), principalID: "user-a",
      vaultID: "project-a", revision: 1, cryptoVersion: 3)
    #expect(plaintext == payload)
    #expect(fixture.floor == 0)
    try await service.rememberPersonalKeys(envelope, principalID: "user-a", vaultID: "project-a")
    #expect(fixture.floor == 1)
  }

  @Test("existing personal keys support authenticated pull, import, and subsequent push")
  func existingProjectRoundTrips() async throws {
    let fixture = PersonalSyncFixture()
    try fixture.makeCurrent(revision: 3)
    let service = fixture.service()
    let response = try #require(
      await service.pullAuthenticated(authToken: "dummy", vaultId: "project-a").value)
    let plaintext = try await service.decryptPersonalPayload(
      response,
      legacyDecryptor: { _, _, _, _, _, _ in
        throw PersonalProjectCrypto.KeyError.invalidContext
      })
    #expect(plaintext == payload)
    let importer = EnvProjectImportService(
      personalSyncService: service, organizationSyncService: MockOrgSyncService(),
      registryURL: fixture.origin, sharingKeypairProvider: { (Data(), Data()) },
      personalDecryptor: { _, _, _, _, _, _ in throw PersonalProjectCrypto.KeyError.invalidContext }
    )
    let imported = try await importer.loadPersonal(authToken: "dummy", vaultId: "project-a")
    #expect(imported.environments == ["default": ["TOKEN": "synthetic"]])
    #expect(imported.personalKeys == response.personalKeys)
    #expect(fixture.floor == 0)
    try await importer.rememberPersonalKeys(imported)
    #expect(fixture.floor == 1)
    let result = try #require(
      await (try prepare(service, expectedVersion: 3)).start().value().value)
    #expect(result.version == 4)
    #expect(result.personalKeys == response.personalKeys)
    #expect(fixture.rootCreates == 0)
  }

  @Test(
    "missing or wrong root keys never fall back to legacy encryption", arguments: [false, true])
  func unavailableRootsRejectSync(wrongRoot: Bool) async throws {
    let fixture = PersonalSyncFixture()
    try fixture.makeCurrent(revision: 3)
    if wrongRoot {
      fixture.root = SymmetricKey(data: Data(repeating: 9, count: 32))
    } else {
      fixture.rootMissing = true
    }
    let service = fixture.service()
    let response = try #require(
      await service.pullAuthenticated(authToken: "dummy", vaultId: "project-a").value)
    await #expect(throws: (any Error).self) {
      try await service.decryptPersonalPayload(
        response,
        legacyDecryptor: { _, _, _, _, _, _ in
          Issue.record("Legacy fallback must not run")
          return payload
        })
    }
    await #expect(throws: (any Error).self) { try await prepare(service, expectedVersion: 3) }
    #expect(fixture.writeCount == 0)
    #expect(fixture.rootCreates == 0)
  }

  @Test(
    "legacy projects upgrade only after their existing payload decrypts and validates",
    arguments: [false, true])
  func legacyUpgradeRequiresDecryption(valid: Bool) async throws {
    let fixture = PersonalSyncFixture()
    fixture.currentData = [
      "revision": 3, "cryptoVersion": 3, "encryptedBlob": "legacy", "wrappedKey": "legacy-key",
      "updatedAt": "2026-10-06T20:00:00Z",
    ]
    let service = fixture.service(legacyDecryptor: { _, _, _, _, _, _ in
      valid ? payload : Data("invalid".utf8)
    })
    if valid {
      let result = try #require(
        await (try prepare(service, expectedVersion: 3)).start().value().value)
      #expect(result.version == 4)
      #expect(result.personalKeys?.personalKeyScheme == 2)
      #expect(fixture.rootCreates == 1)
    } else {
      await #expect(throws: (any Error).self) { try await prepare(service, expectedVersion: 3) }
      #expect(fixture.rootCreates == 0)
      #expect(fixture.writeCount == 0)
    }
  }

  @Test("trusted key checkpoints reject legacy downgrades before decryption or writes")
  func legacyDowngradeIsRejected() async throws {
    let fixture = PersonalSyncFixture()
    fixture.floor = 1
    fixture.currentData = [
      "revision": 3, "cryptoVersion": 3, "encryptedBlob": "legacy", "wrappedKey": "legacy-key",
      "updatedAt": "2026-10-06T20:00:00Z",
    ]
    let service = fixture.service(legacyDecryptor: { _, _, _, _, _, _ in
      Issue.record("Downgraded key must not decrypt")
      return payload
    })
    let response = try #require(
      await service.pullAuthenticated(authToken: "dummy", vaultId: "project-a").value)
    await #expect(throws: (any Error).self) {
      try await service.decryptPersonalPayload(
        response,
        legacyDecryptor: { _, _, _, _, _, _ in
          Issue.record("Downgraded key must not decrypt")
          return payload
        })
    }
    await #expect(throws: (any Error).self) { try await prepare(service, expectedVersion: 3) }
    #expect(fixture.writeCount == 0)
  }

  @Test("authenticated preflight races return retryable conflicts without writing")
  func preparationRacesRemainRetryable() async throws {
    let fixture = PersonalSyncFixture()
    try fixture.makeCurrent(revision: 4)
    let service = fixture.service()
    let conflict = try #require(
      await (try prepare(service, expectedVersion: 3, force: true)).start().value().value)
    #expect(conflict.code == "vault_version_conflict")
    #expect(conflict.serverVersion == 4)
    #expect(fixture.writeCount == 0)
    let result = try #require(
      await (try prepare(service, expectedVersion: 4, force: true)).start().value().value)
    #expect(result.version == 5)
  }

  @Test("deleted projects require recreation consent and advance the trusted project key version")
  func recreationAdvancesKeyVersion() async throws {
    let fixture = PersonalSyncFixture()
    fixture.missingRevision = 3
    fixture.floor = 2
    let service = fixture.service()
    let conflict = try #require(
      await (try prepare(service, expectedVersion: 3)).start().value().value)
    #expect(conflict.code == "vault_recreation_intent_required")
    #expect(fixture.rootCreates == 0)
    let prepared = try await prepare(service, expectedVersion: 3, force: true, recreate: true)
    let result = try #require(await prepared.start().value().value)
    #expect(result.version == 4)
    #expect(result.personalKeys?.projectKeyVersion == 3)
  }

  @Test("committed responses must preserve the exact prepared project key binding")
  func committedKeySubstitutionIsRejected() async throws {
    let fixture = PersonalSyncFixture()
    fixture.missingRevision = 0
    fixture.alterCommittedKeys = true
    let result = await (try prepare(fixture.service())).start().value()
    #expect(result.value == nil)
    #expect(fixture.floor == 0)
  }

  @Test("invalid metadata size fails before network access or key creation")
  func metadataSizeIsCheckedBeforeKeySideEffects() async throws {
    let fixture = PersonalSyncFixture()
    let service = fixture.service()
    await #expect(throws: (any Error).self) {
      try await prepare(
        service, schema: .object(["large": .string(String(repeating: "x", count: 300_000))]))
    }
    #expect(fixture.readCount == 0)
    #expect(fixture.rootCreates == 0)
  }

  @Test("invalid imported payloads do not advance the trusted key checkpoint")
  func invalidImportDoesNotAdvanceCheckpoint() async throws {
    let fixture = PersonalSyncFixture()
    try fixture.makeCurrent(revision: 3, plaintext: Data("invalid".utf8))
    let service = fixture.service()
    let importer = EnvProjectImportService(
      personalSyncService: service, organizationSyncService: MockOrgSyncService(),
      sharingKeypairProvider: { (Data(), Data()) })
    await #expect(throws: (any Error).self) {
      try await importer.loadPersonal(authToken: "dummy", vaultId: "project-a")
    }
    #expect(fixture.floor == 0)
  }

  @MainActor
  @Test("native store pulls project-key payloads and pushes the next revision")
  func storeUsesProjectKeys() async throws {
    let fixture = PersonalSyncFixture()
    try fixture.makeCurrent(revision: 3)
    let service = fixture.service()
    let keychain = MockKeychainService()
    keychain.envStorage["project-a"] = (
      name: "Synthetic", path: "", environments: ["default": ["TOKEN": "local"]]
    )
    let store = VaultStore(
      keychainService: keychain, biometricService: MockBiometricService(),
      apiService: MockAPIService(), personalSyncServiceFactory: { _ in service },
      stableSyncEncryptor: { _, _, _, _ in
        Issue.record("Legacy encryptor must not run")
        return ("", "")
      },
      stableSyncDecryptor: { _, _, _, _, _, _ in
        Issue.record("Legacy decryptor must not run")
        return Data()
      }, authTokenProvider: { _, _ in "dummy" })
    store.currentUser = LPMUser(
      id: "user-a", username: "dummy", name: nil, email: nil, avatarUrl: nil, plan: nil,
      createdAt: nil, orgs: nil)
    store.projects = [
      VaultProject(
        id: "project-a", name: "Synthetic", path: "", environments: ["default": ["TOKEN": "local"]])
    ]
    store.isUnlocked = true
    store.openProject(id: "project-a")
    #expect(await store.pullFromCloud())
    #expect(store.selectedProject?.environments["default"]?["TOKEN"] == "synthetic")
    #expect(store.syncMetadata["project-a"]?.lastVersion == 3)
    #expect(fixture.floor == 1)
    await store.pushToCloud()
    #expect(store.lastSyncStatus == "Pushed (v4)")
    #expect(store.syncMetadata["project-a"]?.lastVersion == 4)
    store.lock()
  }

  @MainActor
  @Test(
    "force push retries a project-key preflight race and commits the next authenticated revision")
  func storeRetriesPreparationRace() async throws {
    let fixture = PersonalSyncFixture()
    try fixture.makeCurrent(revision: 4)
    fixture.inspectedRevisions = [3, 4]
    let service = fixture.service()
    let keychain = MockKeychainService()
    keychain.envStorage["project-a"] = (
      name: "Synthetic", path: "", environments: ["default": ["TOKEN": "local"]]
    )
    let store = VaultStore(
      keychainService: keychain, biometricService: MockBiometricService(),
      apiService: MockAPIService(), personalSyncServiceFactory: { _ in service },
      authTokenProvider: { _, _ in "dummy" })
    store.currentUser = LPMUser(
      id: "user-a", username: "dummy", name: nil, email: nil, avatarUrl: nil, plan: nil,
      createdAt: nil, orgs: nil)
    store.projects = [
      VaultProject(
        id: "project-a", name: "Synthetic", path: "", environments: ["default": ["TOKEN": "local"]])
    ]
    store.isUnlocked = true
    store.openProject(id: "project-a")
    await store.pushToCloud(force: true)
    #expect(store.lastSyncStatus == "Pushed (v5)")
    #expect(fixture.writeCount == 1)
    #expect(fixture.inspectedRevisions.isEmpty)
    store.lock()
  }

  @MainActor
  @Test(
    "checkpoint failures preserve the successful pull and push status with an actionable warning")
  func committedSyncReportsCheckpointFailure() async throws {
    let fixture = PersonalSyncFixture()
    try fixture.makeCurrent(revision: 3)
    fixture.checkpointFails = true
    let service = fixture.service()
    let keychain = MockKeychainService()
    keychain.envStorage["project-a"] = (
      name: "Synthetic", path: "", environments: ["default": ["TOKEN": "local"]]
    )
    let store = VaultStore(
      keychainService: keychain, biometricService: MockBiometricService(),
      apiService: MockAPIService(), personalSyncServiceFactory: { _ in service },
      authTokenProvider: { _, _ in "dummy" })
    store.currentUser = LPMUser(
      id: "user-a", username: "dummy", name: nil, email: nil, avatarUrl: nil, plan: nil,
      createdAt: nil, orgs: nil)
    store.projects = [
      VaultProject(
        id: "project-a", name: "Synthetic", path: "", environments: ["default": ["TOKEN": "local"]])
    ]
    store.isUnlocked = true
    store.openProject(id: "project-a")
    #expect(await store.pullFromCloud())
    #expect(
      store.error?.hasPrefix("The pull succeeded, but the local key checkpoint could not be saved:")
        == true)
    #expect(store.lastSyncStatus?.hasPrefix("Pulled (v3") == true)
    await store.pushToCloud()
    #expect(store.lastSyncStatus == "Pushed (v4)")
    #expect(
      store.error?.hasPrefix("The push succeeded, but the local key checkpoint could not be saved:")
        == true)
    #expect(store.syncMetadata["project-a"]?.lastVersion == 4)
    store.lock()
  }

  private func prepare(
    _ service: SyncService, expectedVersion: Int? = nil, force: Bool = false,
    recreate: Bool = false, schema: LPMJSONValue? = nil
  ) async throws -> PreparedRemoteOperation<
    SyncService.AuthenticatedResponse<SyncService.SyncStatus>
  > {
    try await service.preparePersonalPush(
      authToken: "dummy", expectedPrincipalId: "user-a", vaultId: "project-a", plaintext: payload,
      expectedVersion: expectedVersion, force: force, recreateMissing: recreate, name: "Synthetic",
      schema: schema,
      legacyEncryptor: { _, _, _, _ in
        Issue.record("Real sync must not use legacy encryption")
        return ("", "")
      })
  }
}

private let payload = Data(#"{"environments":{"default":{"TOKEN":"synthetic"}}}"#.utf8)

private final class PersonalSyncFixture: @unchecked Sendable {
  private let lock = NSLock()
  let origin = "https://\(UUID().uuidString.lowercased()).example"
  var root = SymmetricKey(data: Data(repeating: 7, count: 32))
  var rootMissing = false
  var floor = 0
  var currentData: [String: Any]?
  var missingRevision: Int?
  var alterCommittedKeys = false
  var checkpointFails = false
  var inspectedRevisions: [Int] = []
  private(set) var rootCreates = 0
  private(set) var writeCount = 0
  private(set) var readCount = 0
  private(set) var lastWrite: [String: Any]?

  func makeCurrent(revision: Int, plaintext: Data = payload) throws {
    let project = try PersonalProjectCrypto.create(
      root: root, registryOrigin: origin, principalID: "user-a", vaultID: "project-a", version: 1)
    let encrypted = try PersonalProjectCrypto.encrypt(
      project: project, plaintext: plaintext, principalID: "user-a", vaultID: "project-a",
      revision: revision)
    currentData = [
      "revision": revision, "cryptoVersion": 3, "encryptedBlob": encrypted.encryptedBlob,
      "wrappedKey": encrypted.wrappedKey, "updatedAt": "2026-10-06T20:00:00Z",
      "personalKeyScheme": 2, "personalRegistryOrigin": origin, "projectKeyVersion": 1,
      "wrappedProjectKey": project.envelope.wrappedProjectKey,
    ]
  }

  func service(
    legacyDecryptor: @escaping PersonalPayloadDecryptor = { _, _, _, _, _, _ in
      throw PersonalProjectCrypto.KeyError.invalidContext
    }
  ) -> SyncService {
    PersonalSyncURLProtocol.routes.set(origin: origin) { [self] request in try reply(request) }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [PersonalSyncURLProtocol.self]
    let keys = PersonalProjectKeyStore(
      root: { [self] requestedOrigin, principal, create in
        try lock.withLock {
          guard requestedOrigin == origin, principal == "user-a" else {
            throw PersonalProjectCrypto.KeyError.invalidContext
          }
          if create { rootCreates += 1 }
          guard !rootMissing else { throw PersonalProjectCrypto.KeyError.missingRoot }
          return root
        }
      },
      checkpoint: { [self] requestedOrigin, principal, vault, next in
        try lock.withLock {
          guard requestedOrigin == origin, principal == "user-a", vault == "project-a" else {
            throw PersonalProjectCrypto.KeyError.invalidContext
          }
          if let next {
            guard !checkpointFails else { throw PersonalProjectCrypto.KeyError.storage }
            guard next >= floor else { throw PersonalProjectCrypto.KeyError.downgrade }
            floor = next
          }
          return floor
        }
      })
    return SyncService(
      baseURL: URL(string: origin)!,
      session: URLSession(
        configuration: configuration, delegate: BoundedHTTPResponseDelegate(), delegateQueue: nil),
      personalProjectKeys: keys, legacyPersonalDecryptor: legacyDecryptor,
      responseSignatureVerifier: { _, _, _ in true })
  }

  private func reply(_ request: URLRequest) throws -> (Int, Data) {
    try lock.withLock {
      let nonce = try #require(request.value(forHTTPHeaderField: "X-LPM-Vault-Request-Nonce"))
      var data: [String: Any]
      var operation = "vault.pull"
      var outcome = "current"
      var status = 200
      if request.httpMethod == "POST" {
        writeCount += 1
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
          stream.open()
          defer { stream.close() }
          var bytes = Data()
          var buffer = [UInt8](repeating: 0, count: 4096)
          while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else { throw URLError(.cannotDecodeContentData) }
            if count == 0 { break }
            bytes.append(contentsOf: buffer.prefix(count))
          }
          body = bytes
        }
        let bodyBytes = try #require(body)
        let written = try #require(
          try JSONSerialization.jsonObject(with: bodyBytes) as? [String: Any])
        lastWrite = written
        operation = "vault.write"
        outcome = "committed"
        data = [
          "revision": try #require(written["ciphertextRevision"]), "cryptoVersion": 3,
          "action": "synced",
        ]
        for key in [
          "personalKeyScheme", "personalRegistryOrigin", "projectKeyVersion", "wrappedProjectKey",
        ] { data[key] = written[key] }
        if alterCommittedKeys { data["wrappedProjectKey"] = "different-key" }
      } else {
        readCount += 1
        if request.url?.query == "versionOnly=true" {
          operation = "vault.inspect"
          let revision =
            inspectedRevisions.isEmpty
            ? (currentData?["revision"] as? Int ?? 0) : inspectedRevisions.removeFirst()
          if let missingRevision {
            data = ["retainedRevision": missingRevision]
            outcome = "missing"
            status = 404
          } else {
            data = ["revision": revision, "cryptoVersion": 3]
          }
        } else if let missingRevision {
          data = ["retainedRevision": missingRevision]
          outcome = "missing"
          status = 404
        } else {
          data = try #require(currentData)
        }
      }
      let envelope: [String: Any] = [
        "envelopeVersion": 3, "operation": operation, "outcome": outcome, "requestNonce": nonce,
        "binding": [
          "scope": "personal", "principalId": "user-a", "callerUserId": "user-a",
          "vaultId": "project-a",
        ], "data": data,
      ]
      return (status, try JSONSerialization.data(withJSONObject: envelope))
    }
  }
}

private final class PersonalSyncRoutes: @unchecked Sendable {
  private let lock = NSLock()
  private var handlers: [String: @Sendable (URLRequest) throws -> (Int, Data)] = [:]
  func set(origin: String, handler: @escaping @Sendable (URLRequest) throws -> (Int, Data)) {
    lock.withLock { handlers[origin] = handler }
  }
  func reply(_ request: URLRequest) throws -> (Int, Data) {
    let origin = try #require(request.url.map { "https://\($0.host!)" })
    let handler = try #require(lock.withLock { handlers[origin] })
    return try handler(request)
  }
}

private final class PersonalSyncURLProtocol: URLProtocol {
  static let routes = PersonalSyncRoutes()
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    do {
      let (status, body) = try Self.routes.reply(request)
      let url = try #require(request.url)
      let response = try #require(
        HTTPURLResponse(
          url: url, statusCode: status, httpVersion: "HTTP/1.1",
          headerFields: ["Content-Type": "application/json"]))
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: body)
      client?.urlProtocolDidFinishLoading(self)
    } catch { client?.urlProtocol(self, didFailWithError: error) }
  }
  override func stopLoading() {}
}
