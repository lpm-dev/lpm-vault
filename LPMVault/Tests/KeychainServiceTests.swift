import Foundation
import Security
import Testing

@testable import LPMVault

/// These tests use a unique service name to avoid polluting the real Keychain.
/// Each test creates and cleans up its own Keychain items.
@Suite("KeychainService — Real Keychain Integration", .serialized)
struct KeychainServiceTests {
	private func makeService() -> KeychainService {
		KeychainService(legacyTestingService: "dev.lpm.vault.test.\(UUID().uuidString)")
	}

	private func cleanup(service: KeychainService, vaultIds: [String]) {
		for id in vaultIds {
			_ = service.deleteProject(vaultId: id)
		}
	}

	// MARK: - CRUD

	@Test("round-trip: save then read returns same secrets")
	func roundTrip() {
		let service = makeService()
		let vaultId = "test-\(UUID().uuidString.prefix(8))"
		defer { cleanup(service: service, vaultIds: [vaultId]) }

		let secrets = ["DB_HOST": "localhost", "API_KEY": "sk-123", "PORT": "3000"]

		let result = service.saveSecrets(
			vaultId: vaultId,
			projectName: "test-project",
			projectPath: "/tmp/test-project",
			secrets: secrets
		)

		guard case .success = result else {
			Issue.record("Save failed: \(result)")
			return
		}

		let retrieved = service.getSecrets(vaultId: vaultId)
		#expect(retrieved == secrets)
	}

	@Test("update overwrites existing secrets")
	func update() {
		let service = makeService()
		let vaultId = "test-\(UUID().uuidString.prefix(8))"
		defer { cleanup(service: service, vaultIds: [vaultId]) }

		// Create
		_ = service.saveSecrets(
			vaultId: vaultId,
			projectName: "project",
			projectPath: "/tmp/p",
			secrets: ["KEY": "old-value"]
		)

		// Update
		let result = service.saveSecrets(
			vaultId: vaultId,
			projectName: "project-renamed",
			projectPath: "/tmp/p-new",
			secrets: ["KEY": "new-value", "NEW_KEY": "added"]
		)

		guard case .success = result else {
			Issue.record("Update failed: \(result)")
			return
		}

		let retrieved = service.getSecrets(vaultId: vaultId)
		#expect(retrieved?["KEY"] == "new-value")
		#expect(retrieved?["NEW_KEY"] == "added")
	}

	@Test("delete removes item")
	func delete() {
		let service = makeService()
		let vaultId = "test-\(UUID().uuidString.prefix(8))"

		// Create
		_ = service.saveSecrets(
			vaultId: vaultId,
			projectName: "to-delete",
			projectPath: "/tmp/d",
			secrets: ["KEY": "val"]
		)

		// Delete
		let deleted = service.deleteProject(vaultId: vaultId)
		#expect(deleted == true)

		// Verify gone
		let retrieved = service.getSecrets(vaultId: vaultId)
		#expect(retrieved == nil)
	}

	@Test("delete non-existent item returns true (idempotent)")
	func deleteNonExistent() {
		let service = makeService()
		let deleted = service.deleteProject(vaultId: "nonexistent-\(UUID().uuidString)")
		#expect(deleted == true)
	}

	@Test("get non-existent vault returns nil")
	func getNonExistent() {
		let service = makeService()
		let result = service.getSecrets(vaultId: "nonexistent-\(UUID().uuidString)")
		#expect(result == nil)
	}

	// MARK: - List

	@Test("list projects returns all vault items")
	func listProjects() {
		// Isolated service to avoid race conditions with parallel tests sharing the index
		let isolatedService = KeychainService(
			legacyTestingService: "dev.lpm.vault.list.\(UUID().uuidString.prefix(8))")
		let id1 = "list-\(UUID().uuidString.prefix(8))"
		let id2 = "list-\(UUID().uuidString.prefix(8))"
		defer {
			_ = isolatedService.deleteProject(vaultId: id1)
			_ = isolatedService.deleteProject(vaultId: id2)
		}

		_ = isolatedService.saveSecrets(
			vaultId: id1,
			projectName: "project-alpha",
			projectPath: "/tmp/alpha",
			secrets: ["A": "1"]
		)
		_ = isolatedService.saveSecrets(
			vaultId: id2,
			projectName: "project-beta",
			projectPath: "/tmp/beta",
			secrets: ["B": "2"]
		)

		let projects = isolatedService.listProjects()

		#expect(projects.count == 2)

		let alpha = projects.first { $0.id == id1 }
		#expect(alpha?.name == "project-alpha")
		#expect(alpha?.path == "/tmp/alpha")
		#expect(alpha?.secrets == ["A": "1"])

		let beta = projects.first { $0.id == id2 }
		#expect(beta?.name == "project-beta")
		#expect(beta?.secrets == ["B": "2"])
	}

	@Test("list projects when empty returns empty array")
	func listEmpty() {
		// Use a unique service that definitely has no items
		let service = KeychainService(
			legacyTestingService: "dev.lpm.vault.empty.\(UUID().uuidString.prefix(8))")
		let projects = service.listProjects()
		#expect(projects.isEmpty)
	}

	// MARK: - Edge Cases

	@Test("empty secrets dictionary is valid")
	func emptySecrets() {
		let service = makeService()
		let vaultId = "test-\(UUID().uuidString.prefix(8))"
		defer { cleanup(service: service, vaultIds: [vaultId]) }

		let result = service.saveSecrets(
			vaultId: vaultId,
			projectName: "empty-project",
			projectPath: "/tmp/empty",
			secrets: [:]
		)

		guard case .success = result else {
			Issue.record("Save empty secrets failed")
			return
		}

		let retrieved = service.getSecrets(vaultId: vaultId)
		#expect(retrieved == [:])
	}

	@Test("secrets with special characters preserved")
	func specialCharacters() {
		let service = makeService()
		let vaultId = "test-\(UUID().uuidString.prefix(8))"
		defer { cleanup(service: service, vaultIds: [vaultId]) }

		let secrets = [
			"URL": "postgres://user:p@ss=w0rd@host:5432/db?ssl=true&timeout=30",
			"JSON": "{\"key\": \"value\", \"nested\": {\"a\": 1}}",
			"MULTILINE": "line1\nline2\nline3",
			"UNICODE": "hello \u{1F512} world \u{00E9}\u{00E8}\u{00EA}",
		]

		_ = service.saveSecrets(
			vaultId: vaultId,
			projectName: "special",
			projectPath: "/tmp/special",
			secrets: secrets
		)

		let retrieved = service.getSecrets(vaultId: vaultId)
		#expect(retrieved == secrets)
	}
}

@Suite("Shared Keychain migration")
struct SharedKeychainMigrationTests {
	private final class FakeBackend: KeychainStoreBackend {
		var shared: [String: Data] = [:]
		var legacy: [String: Data] = [:]
		var corruptSharedWrites = false
		var rejectLegacyDelete = false
		var rejectSharedDelete = false
		var rejectSharedReads = false
		var sharedWriteFailuresRemaining = 0
		var sharedValueInsertedBeforeAdd: Data?
		var sharedValueUpdatedAfterAdd: Data?
		var sharedValueUpdatedAfterWrite: Data?
		var legacyValueUpdatedOnSharedFailure: Data?

		func read(service: String, account: String, location: KeychainStoreLocation) throws -> Data?
		{
			if location == .shared, rejectSharedReads {
				throw KeychainStoreError.status(operation: "read", code: errSecMissingEntitlement)
			}
			return location == .shared ? shared[account] : legacy[account]
		}

		func write(
			service: String,
			account: String,
			data: Data,
			location: KeychainStoreLocation
		) throws {
			if location == .shared {
				if sharedWriteFailuresRemaining > 0 {
					sharedWriteFailuresRemaining -= 1
					if let concurrent = legacyValueUpdatedOnSharedFailure {
						legacyValueUpdatedOnSharedFailure = nil
						legacy[account] = concurrent
					}
					throw KeychainStoreError.status(operation: "write", code: errSecNotAvailable)
				}
				shared[account] = corruptSharedWrites ? Data("corrupt".utf8) : data
				if let concurrent = sharedValueUpdatedAfterWrite {
					sharedValueUpdatedAfterWrite = nil
					shared[account] = concurrent
				}
			} else {
				legacy[account] = data
			}
		}

		func add(
			service: String,
			account: String,
			data: Data,
			location: KeychainStoreLocation
		) throws {
			if location == .shared, let concurrent = sharedValueInsertedBeforeAdd {
				sharedValueInsertedBeforeAdd = nil
				shared[account] = concurrent
				throw KeychainStoreError.status(operation: "add", code: errSecDuplicateItem)
			}
			let exists = location == .shared ? shared[account] != nil : legacy[account] != nil
			guard !exists else {
				throw KeychainStoreError.status(operation: "add", code: errSecDuplicateItem)
			}
			try write(service: service, account: account, data: data, location: location)
			if location == .shared, let concurrent = sharedValueUpdatedAfterAdd {
				sharedValueUpdatedAfterAdd = nil
				shared[account] = concurrent
			}
		}

		func delete(
			service: String,
			account: String,
			location: KeychainStoreLocation
		) throws -> Bool {
			if location == .legacy, rejectLegacyDelete {
				throw KeychainStoreError.status(operation: "delete", code: errSecAuthFailed)
			}
			if location == .shared, rejectSharedDelete {
				throw KeychainStoreError.status(operation: "delete", code: errSecNotAvailable)
			}
			if location == .shared {
				return shared.removeValue(forKey: account) != nil
			}
			return legacy.removeValue(forKey: account) != nil
		}
	}

	@Test("shared queries require the Team-scoped Data Protection Keychain")
	func protectedQueryContract() throws {
		let shared = try SecurityKeychainStoreBackend.identityQuery(
			service: "service",
			account: "account",
			location: .shared
		)
		let legacy = try SecurityKeychainStoreBackend.identityQuery(
			service: "service",
			account: "account",
			location: .legacy
		)

		#expect(
			shared[kSecAttrAccessGroup as String] as? String == VaultConstants.keychainAccessGroup)
		#expect(shared[kSecUseDataProtectionKeychain as String] as? Bool == true)
		#expect(legacy[kSecAttrAccessGroup as String] == nil)
		#expect(legacy[kSecUseDataProtectionKeychain as String] == nil)
		#expect(legacy[kSecUseKeychain as String] != nil)
	}

	@Test("legacy-only values are copied, verified, and preserved")
	func legacyMigration() throws {
		let backend = FakeBackend()
		let value = Data("secret".utf8)
		backend.legacy["account"] = value
		let store = SharedKeychainStore(service: "service", backend: backend)

		#expect(try store.read(account: "account") == value)
		#expect(backend.shared["account"] == value)
		#expect(backend.legacy["account"] == value)
	}

	@Test("a current CLI legacy update repairs the protected copy")
	func legacyUpdateWinsDuringCompatibility() throws {
		let backend = FakeBackend()
		backend.shared["account"] = Data("protected".utf8)
		backend.legacy["account"] = Data("legacy".utf8)
		let store = SharedKeychainStore(service: "service", backend: backend)

		#expect(try store.read(account: "account") == Data("legacy".utf8))
		#expect(backend.shared["account"] == Data("legacy".utf8))
		#expect(backend.legacy["account"] == Data("legacy".utf8))
	}

	@Test("a shared-only value is copied to the legacy store during compatibility")
	func sharedOnlyCompatibilityBackfill() throws {
		let backend = FakeBackend()
		let value = Data("protected".utf8)
		backend.shared["account"] = value
		let store = SharedKeychainStore(service: "service", backend: backend)

		#expect(try store.read(account: "account") == value)
		#expect(backend.shared["account"] == value)
		#expect(backend.legacy["account"] == value)
	}

	@Test("an identical protected copy created during migration is accepted")
	func concurrentIdenticalMigration() throws {
		let backend = FakeBackend()
		let value = Data("secret".utf8)
		backend.legacy["account"] = value
		backend.shared["account"] = value
		let store = SharedKeychainStore(service: "service", backend: backend)

		#expect(try store.read(account: "account") == value)
		#expect(backend.shared["account"] == value)
		#expect(backend.legacy["account"] == value)
	}

	@Test("a protected update during compatibility repair fails verification")
	func concurrentDivergentRepair() {
		let backend = FakeBackend()
		backend.legacy["account"] = Data("legacy".utf8)
		backend.sharedValueUpdatedAfterWrite = Data("protected".utf8)
		let store = SharedKeychainStore(service: "service", backend: backend)

		#expect(throws: KeychainStoreError.migrationVerificationFailed) {
			_ = try store.read(account: "account")
		}
		#expect(backend.shared["account"] == Data("protected".utf8))
		#expect(backend.legacy["account"] == Data("legacy".utf8))
	}

	@Test("failed migration verification preserves the legacy value")
	func migrationVerificationFailure() {
		let backend = FakeBackend()
		let value = Data("secret".utf8)
		backend.legacy["account"] = value
		backend.corruptSharedWrites = true
		let store = SharedKeychainStore(service: "service", backend: backend)

		#expect(throws: KeychainStoreError.migrationVerificationFailed) {
			_ = try store.read(account: "account")
		}
		#expect(backend.shared["account"] == Data("corrupt".utf8))
		#expect(backend.legacy["account"] == value)
	}

	@Test("reads never attempt automatic legacy deletion")
	func migrationPreservesCompatibilityCopy() throws {
		let backend = FakeBackend()
		let value = Data("secret".utf8)
		backend.legacy["account"] = value
		backend.rejectLegacyDelete = true
		let store = SharedKeychainStore(service: "service", backend: backend)

		#expect(try store.read(account: "account") == value)
		#expect(backend.shared["account"] == value)
		#expect(backend.legacy["account"] == value)
	}

	@Test("writes update an existing legacy compatibility copy")
	func compatibilityWrite() throws {
		let backend = FakeBackend()
		let previous = Data("previous".utf8)
		let updated = Data("updated".utf8)
		backend.shared["account"] = previous
		backend.legacy["account"] = previous
		let store = SharedKeychainStore(service: "service", backend: backend)

		try store.write(account: "account", data: updated)

		#expect(backend.shared["account"] == updated)
		#expect(backend.legacy["account"] == updated)
	}

	@Test("brand-new writes create both compatibility copies")
	func compatibilityWriteCreatesLegacyCopy() throws {
		let backend = FakeBackend()
		let value = Data("new".utf8)
		let store = SharedKeychainStore(service: "service", backend: backend)

		try store.write(account: "account", data: value)

		#expect(backend.shared["account"] == value)
		#expect(backend.legacy["account"] == value)
	}

	@Test("brand-new add creates both compatibility copies")
	func compatibilityAddCreatesLegacyCopy() throws {
		let backend = FakeBackend()
		let value = Data("new".utf8)
		let store = SharedKeychainStore(service: "service", backend: backend)

		try store.add(account: "account", data: value)

		#expect(backend.shared["account"] == value)
		#expect(backend.legacy["account"] == value)
	}

	@Test("a transient protected-write failure is recovered from the legacy copy")
	func compatibilityWriteRecoversSecondStoreFailure() throws {
		let backend = FakeBackend()
		backend.sharedWriteFailuresRemaining = 1
		let value = Data("new".utf8)
		let store = SharedKeychainStore(service: "service", backend: backend)

		try store.write(account: "account", data: value)

		#expect(backend.shared["account"] == value)
		#expect(backend.legacy["account"] == value)
	}

	@Test("a persistent protected add failure rolls back its legacy copy")
	func compatibilityAddRollsBackPersistentSecondStoreFailure() throws {
		let backend = FakeBackend()
		backend.sharedWriteFailuresRemaining = 2
		let value = Data("new".utf8)
		let store = SharedKeychainStore(service: "service", backend: backend)

		#expect(throws: KeychainStoreError.self) {
			try store.add(account: "account", data: value)
		}
		#expect(backend.shared["account"] == nil)
		#expect(backend.legacy["account"] == nil)

		try store.add(account: "account", data: value)

		#expect(backend.shared["account"] == value)
		#expect(backend.legacy["account"] == value)
	}

	@Test("a persistent protected write failure restores its legacy snapshot")
	func compatibilityWriteRollsBackPersistentSecondStoreFailure() {
		let backend = FakeBackend()
		let previous = Data("previous".utf8)
		backend.shared["account"] = previous
		backend.legacy["account"] = previous
		backend.sharedWriteFailuresRemaining = 2
		let store = SharedKeychainStore(service: "service", backend: backend)

		#expect(throws: KeychainStoreError.self) {
			try store.write(account: "account", data: Data("updated".utf8))
		}
		#expect(backend.shared["account"] == previous)
		#expect(backend.legacy["account"] == previous)
	}

	@Test("compatibility rollback never overwrites a concurrent legacy update")
	func compatibilityRollbackPreservesConcurrentLegacyUpdate() {
		let backend = FakeBackend()
		let previous = Data("previous".utf8)
		let concurrent = Data("concurrent".utf8)
		backend.shared["account"] = previous
		backend.legacy["account"] = previous
		backend.sharedWriteFailuresRemaining = 2
		backend.legacyValueUpdatedOnSharedFailure = concurrent
		let store = SharedKeychainStore(service: "service", backend: backend)

		#expect(throws: KeychainStoreError.migrationConflict) {
			try store.write(account: "account", data: Data("attempted".utf8))
		}
		#expect(backend.shared["account"] == previous)
		#expect(backend.legacy["account"] == concurrent)
	}

	@Test("persistent cutover ignores divergent legacy data")
	func protectedOnlyReadAfterCutover() throws {
		let backend = FakeBackend()
		backend.shared["__legacy_keychain_cutover_v1__"] = Data("protected-only-v1".utf8)
		backend.shared["account"] = Data("protected".utf8)
		backend.legacy["account"] = Data("legacy".utf8)
		let store = SharedKeychainStore(service: "service", backend: backend)

		#expect(try store.read(account: "account") == Data("protected".utf8))
		#expect(backend.legacy["account"] == Data("legacy".utf8))
	}

	@Test("persistent cutover disables compatibility dual writes")
	func protectedOnlyWriteAfterCutover() throws {
		let backend = FakeBackend()
		backend.shared["__legacy_keychain_cutover_v1__"] = Data("protected-only-v1".utf8)
		backend.shared["account"] = Data("protected".utf8)
		backend.legacy["account"] = Data("legacy".utf8)
		let store = SharedKeychainStore(service: "service", backend: backend)

		try store.write(account: "account", data: Data("updated".utf8))

		#expect(backend.shared["account"] == Data("updated".utf8))
		#expect(backend.legacy["account"] == Data("legacy".utf8))
	}

	@Test("persistent cutover makes brand-new adds protected-only")
	func protectedOnlyAddAfterCutover() throws {
		let backend = FakeBackend()
		backend.shared["__legacy_keychain_cutover_v1__"] = Data("protected-only-v1".utf8)
		let store = SharedKeychainStore(service: "service", backend: backend)

		try store.add(account: "account", data: Data("new".utf8))

		#expect(backend.shared["account"] == Data("new".utf8))
		#expect(backend.legacy["account"] == nil)
	}

	@Test("write verification never rolls back a concurrent protected update")
	func concurrentUpdateAfterWrite() {
		let backend = FakeBackend()
		backend.shared["account"] = Data("previous".utf8)
		backend.sharedValueUpdatedAfterWrite = Data("concurrent".utf8)
		let store = SharedKeychainStore(service: "service", backend: backend)

		#expect(throws: KeychainStoreError.migrationConflict) {
			try store.write(account: "account", data: Data("requested".utf8))
		}
		#expect(backend.shared["account"] == Data("concurrent".utf8))
		#expect(backend.legacy["account"] == Data("previous".utf8))
	}

	@Test("add verification never deletes a concurrent protected update")
	func concurrentUpdateAfterAdd() {
		let backend = FakeBackend()
		backend.sharedValueUpdatedAfterAdd = Data("concurrent".utf8)
		let store = SharedKeychainStore(service: "service", backend: backend)

		#expect(throws: KeychainStoreError.migrationConflict) {
			try store.add(account: "account", data: Data("requested".utf8))
		}
		#expect(backend.shared["account"] == Data("concurrent".utf8))
	}

	@Test("a protected delete failure is repaired from the preserved protected copy")
	func sharedDeleteFailureIsRecoverable() throws {
		let backend = FakeBackend()
		let value = Data("secret".utf8)
		backend.shared["account"] = value
		backend.legacy["account"] = value
		backend.rejectSharedDelete = true
		let store = SharedKeychainStore(service: "service", backend: backend)

		#expect(throws: KeychainStoreError.status(operation: "delete", code: errSecNotAvailable)) {
			_ = try store.delete(account: "account")
		}
		#expect(backend.legacy["account"] == nil)
		#expect(backend.shared["account"] == value)

		backend.rejectSharedDelete = false
		#expect(try store.read(account: "account") == value)
		#expect(backend.legacy["account"] == value)
	}

	@Test("a protected read error never creates or replaces key material")
	func readFailureDoesNotWrite() {
		let backend = FakeBackend()
		backend.legacy["account"] = Data("legacy".utf8)
		backend.rejectSharedReads = true
		let store = SharedKeychainStore(service: "service", backend: backend)

		#expect(
			throws: KeychainStoreError.status(operation: "read", code: errSecMissingEntitlement)
		) {
			try store.write(account: "account", data: Data("new".utf8))
		}
		#expect(backend.shared["account"] == nil)
		#expect(backend.legacy["account"] == Data("legacy".utf8))
	}
}

@Suite("Keychain error guidance")
struct KeychainErrorGuidanceTests {
	@Test("locked Data Protection Keychain guidance does not suggest legacy ACL approval")
	func lockedKeychainGuidance() {
		let message = KeychainError.keychainLocked.description

		#expect(message.contains("Unlock your login Keychain"))
		#expect(!message.contains("allow LPM Vault"))
	}

	@Test("missing shared entitlement guidance requires an official build")
	func missingEntitlementGuidance() {
		let message = KeychainError.missingEntitlement.description

		#expect(message.contains("shared Keychain access group"))
		#expect(message.contains("official build"))
	}
}
