import Foundation
import Testing

@testable import LPMVault

@Suite("Empty environment sync")
@MainActor
struct EmptyEnvironmentSyncTests {
	@Test(
		"personal push preserves empty environments in its clean snapshot",
		arguments: [false, true])
	func personalPushPreservesEmptyEnvironments(allEmpty: Bool) async throws {
		let environments: [String: [String: String]] = [
			"default": allEmpty ? [:] : ["TOKEN": "dummy"], "staging": [:],
		]
		let keychain = MockKeychainService()
		keychain.envStorage["project"] = (
			name: "Dummy", path: "", environments: environments
		)
		let capture = SyncPlaintextCapture()
		let sync = MockPersonalSyncService()
		sync.pushHandlers = [
			{
				SyncService.SyncStatus(
					vaultId: "project", version: 1,
					cryptoVersion: VaultCrypto.currentCryptoVersion,
					contentKeyVersion: nil, recipientPublicKeyVersion: nil,
					recipientPublicKeyFingerprint: nil,
					status: "ok", error: nil, code: nil, serverVersion: nil,
					hint: nil, encryptedBlob: nil,
					wrappedKey: nil, updatedAt: nil, principalId: "user")
			}
		]
		let store = VaultStore(
			keychainService: keychain, biometricService: MockBiometricService(),
			apiService: MockAPIService(),
			personalSyncServiceFactory: { _ in sync },
			stableSyncEncryptor: { data, _, _, _ in
				capture.record(data)
				return ("dummy-blob", "dummy-key")
			},
			authTokenProvider: { _, _ in "dummy-session" })
		store.currentUser = LPMUser(
			id: "user", username: "dummy", name: nil, email: nil, avatarUrl: nil,
			plan: nil, createdAt: nil, orgs: nil)
		store.projects = [
			VaultProject(
				id: "project", name: "Dummy", path: "", environments: environments)
		]
		store.isUnlocked = true
		store.openProject(id: "project")
		await store.pushToCloud()
		let decoded = try EnvValidation.decodeRemoteEnvironments(#require(capture.value))
		#expect(decoded.environments == environments)
		#expect(store.syncMetadata["project"]?.isDirty == false)
		#expect(keychain.storedSyncMetadata(vaultId: "project")?.isDirty == false)
		store.lock()
	}
}

private final class SyncPlaintextCapture: @unchecked Sendable {
	private let lock = NSLock()
	private var data: Data?
	var value: Data? { lock.withLock { data } }
	func record(_ data: Data) { lock.withLock { self.data = data } }
}
