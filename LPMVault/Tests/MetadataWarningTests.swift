import Foundation
import Testing
@testable import LPMVault

@Suite("Authenticated metadata warnings")
struct MetadataWarningTests {
 @Test("committed writes accept the negotiated safe metadata warning extension")
 func committedWritesAcceptMetadataWarnings() throws {
  let nonce = String(repeating: "A", count: 43)
  let body = Data("""
  {"envelopeVersion":3,"operation":"vault.write","outcome":"committed","requestNonce":"\(nonce)","binding":{"scope":"personal","principalId":"user-123","callerUserId":"user-123","vaultId":"vault-123"},"data":{"revision":42,"cryptoVersion":3,"action":"synced"},"warnings":[{"code":"env_metadata_dropped","message":"Encrypted values synced. Invalid metadata was not stored.","hint":"Upgrade the client and push again."}]}
  """.utf8)
  let response = try? AuthenticatedVaultEnvelopeParser.decodeVaultResponse(body, statusCode: 200, operation: .write, requestNonce: nonce, vaultID: "vault-123")
  #expect(response?.warnings.first?.code == "env_metadata_dropped")
  #expect(response?.status == "synced")
 }
 @Test("unsafe, unknown and repeated warning fields are rejected")
 func invalidWarningsAreRejected() throws {
  let nonce = String(repeating: "A", count: 43)
  let warning: [String: Any] = ["code": "env_metadata_dropped", "message": "Values synced.", "hint": "Upgrade the client."]
  var envelope: [String: Any] = ["envelopeVersion": 3, "operation": "vault.write", "outcome": "committed", "requestNonce": nonce, "binding": ["scope": "personal", "principalId": "user-123", "callerUserId": "user-123", "vaultId": "vault-123"], "data": ["revision": 42, "cryptoVersion": 3, "action": "synced"]]
  for warnings: Any in [NSNull(), [warning, warning], [["code": "other", "message": "Values synced.", "hint": "Upgrade."]], [["code": "env_metadata_dropped", "message": "\u{1b}unsafe", "hint": "Upgrade."]], [["code": "env_metadata_dropped", "message": String(repeating: "x", count: 1025), "hint": "Upgrade."]], [["code": "env_metadata_dropped", "message": "Values synced.", "hint": "Upgrade.", "unknown": true]]] {
   envelope["warnings"] = warnings
   let body = try JSONSerialization.data(withJSONObject: envelope)
   #expect(throws: (any Error).self) { try AuthenticatedVaultEnvelopeParser.decodeVaultResponse(body, statusCode: 200, operation: .write, requestNonce: nonce, vaultID: "vault-123") }
  }
  envelope["operation"] = "vault.inspect"
  envelope["outcome"] = "current"
  envelope["data"] = ["revision": 42, "cryptoVersion": 3]
  envelope["warnings"] = [warning]
  let body = try JSONSerialization.data(withJSONObject: envelope)
  #expect(throws: (any Error).self) { try AuthenticatedVaultEnvelopeParser.decodeVaultResponse(body, statusCode: 200, operation: .inspect, requestNonce: nonce, vaultID: "vault-123") }
 }

 @Test("a successful personal push exposes warnings without replacing its success status")
 @MainActor
 func personalPushPresentsMetadataWarnings() async {
  let warning = SyncMetadataWarning(code: "env_metadata_dropped", message: "Values synced. Invalid metadata was not stored.", hint: "Upgrade the client.")
  let sync = MockPersonalSyncService()
  sync.pushHandlers = [{ SyncService.SyncStatus(vaultId: "project", version: 1, cryptoVersion: VaultCrypto.currentCryptoVersion, contentKeyVersion: nil, recipientPublicKeyVersion: nil, recipientPublicKeyFingerprint: nil, status: "synced", error: nil, code: nil, serverVersion: nil, hint: nil, encryptedBlob: nil, wrappedKey: nil, updatedAt: nil, principalId: "user", warnings: [warning]) }]
  let keychain = MockKeychainService()
  keychain.envStorage["project"] = (name: "Project", path: "", environments: ["default": ["TOKEN": "dummy"]])
  let store = VaultStore(keychainService: keychain, biometricService: MockBiometricService(), apiService: MockAPIService(), personalSyncServiceFactory: { _ in sync }, stableSyncEncryptor: { _, _, _, _ in ("dummy-blob", "dummy-key") }, authTokenProvider: { _, _ in "dummy-session" })
  store.currentUser = LPMUser(id: "user", username: "dummy", name: nil, email: nil, avatarUrl: nil, plan: nil, createdAt: nil, orgs: nil)
  store.projects = [VaultProject(id: "project", name: "Project", path: "", environments: ["default": ["TOKEN": "dummy"]])]
  store.isUnlocked = true
  store.openProject(id: "project")
  await store.pushToCloud()
  #expect(store.lastSyncStatus == "Pushed (v1)")
  #expect(store.lastSyncWarnings == [warning])
  #expect(store.syncMetadata["project"]?.isDirty == false)
  store.lock()
  #expect(store.lastSyncWarnings.isEmpty)
 }
}
