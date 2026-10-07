import Foundation
import Testing

@testable import LPMVault

@Suite("Personal project read errors")
@MainActor
struct PersonalProjectReadErrorTests {
  @Test(
    "authenticated personal pull errors preserve dirty values and reject substituted bindings",
    arguments: ["missing-empty", "missing-retained", "rejected"],
    [("account-1", "project-a"), ("other-account", "project-a"),
      ("account-1", "other-project"), ("other-account", "other-project")]
  )
  func personalPullErrorsPreserveLocalState(
    outcome: String, context: (principalID: String, vaultID: String)
  ) async throws {
    let result = try response(
      outcome: outcome, principalID: context.principalID, vaultID: context.vaultID
    )
    let sync = MockPersonalSyncService()
    sync.pullHandlers = [{ result }]
    let keychain = MockKeychainService()
    let environments = ["default": ["TOKEN": "local", "LOCAL_ONLY": "pending"]]
    keychain.envStorage["project-a"] = (name: "Local", path: "", environments: environments)
    let metadata = mockCurrentSyncMetadata(
      version: 8, principalID: "account-1", scope: "personal", isDirty: true
    )
    #expect(keychain.seedSyncMetadata(["project-a": metadata]))
    let suiteName = "personal-read-errors-\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suiteName))
    defer { preferences.removePersistentDomain(forName: suiteName) }
    let store = VaultStore(
      keychainService: keychain, biometricService: MockBiometricService(),
      apiService: MockAPIService(),
      personalSyncServiceFactory: { _ in sync },
      preferences: preferences,
      stableSyncDecryptor: { _, _, _, _, _, _ in
        Issue.record("Authenticated errors must not decrypt")
        return Data()
      },
      authTokenProvider: { _, _ in "session-token" }
    )
    store.appEnvironment = .production
    store.currentUser = LPMUser(
      id: "account-1", username: "user", name: nil, email: nil,
      avatarUrl: nil, plan: nil, createdAt: nil, orgs: nil
    )
    store.projects = [VaultProject(
      id: "project-a", name: "Local", path: "", environments: environments
    )]
    store.syncMetadata = ["project-a": metadata]
    store.isUnlocked = true
    store.openProject(id: "project-a")
    let checkpoint = keychain.dataStorage

    #expect(await store.pullFromCloud() == false)

    let matches = context.principalID == "account-1" && context.vaultID == "project-a"
    #expect(store.error == (matches
      ? result.displayError
      : "The pull response did not match this env project or contain a valid version."))
    #expect(store.selectedProject?.environments == environments)
    #expect(keychain.envStorage["project-a"]?.environments == environments)
    #expect(keychain.dataStorage == checkpoint)
    #expect(store.syncMetadata["project-a"]?.lastVersion == 8)
    #expect(store.syncMetadata["project-a"]?.isDirty == true)
    #expect(keychain.storedSyncMetadata(vaultId: "project-a")?.lastVersion == 8)
    #expect(keychain.storedSyncMetadata(vaultId: "project-a")?.isDirty == true)
    #expect(keychain.saveEnvironmentsCallCount == 0)
    #expect(sync.pushCallCount == 0)
    #expect(store.lastSyncStatus == "failed")
    #expect(!store.isSyncing)
  }

  @Test("personal imports preserve missing and rejected diagnostics without decryption",
    arguments: ["missing-empty", "missing-retained", "rejected"])
  func personalImportsPreserveErrors(outcome: String) async throws {
    let result = try response(outcome: outcome, principalID: "account-1", vaultID: "project-a")
    let sync = MockPersonalSyncService()
    sync.pullHandlers = [{ result }]
    let importer = EnvProjectImportService(
      personalSyncService: sync, organizationSyncService: MockOrgSyncService(),
      sharingKeypairProvider: { (Data(), Data()) },
      personalDecryptor: { _, _, _, _, _, _ in
        Issue.record("Authenticated errors must not decrypt")
        return Data()
      }
    )
    await #expect(throws: EnvProjectImportError.noData(try #require(result.displayError))) {
      try await importer.loadPersonal(authToken: "session-token", vaultId: "project-a")
    }
  }

  private func response(
    outcome: String, principalID: String, vaultID: String
  ) throws -> SyncService.SyncStatus {
    let missing = outcome.hasPrefix("missing-")
    let nonce = String(repeating: "A", count: 43)
    let data: [String: Any] = missing
      ? ["retainedRevision": outcome == "missing-empty" ? 0 : 8]
      : ["code": "vault_access_denied", "message": "Access denied"]
    let body = try JSONSerialization.data(withJSONObject: [
      "envelopeVersion": 3, "operation": "vault.pull",
      "outcome": missing ? "missing" : "rejected", "requestNonce": nonce,
      "binding": ["scope": "personal", "principalId": principalID,
        "callerUserId": principalID, "vaultId": vaultID],
      "data": data,
    ])
    return try AuthenticatedVaultEnvelopeParser.decodeVaultResponse(
      body, statusCode: missing ? 404 : 403, operation: .pull,
      requestNonce: nonce, vaultID: vaultID
    )
  }
}
