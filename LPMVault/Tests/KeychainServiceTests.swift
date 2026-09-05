import CryptoKit
import Foundation
import Security
import Testing

@testable import LPMVault

private final class KeychainServiceTestBackend: KeychainStoreBackend, @unchecked Sendable {
	private let lock = NSLock()
	private var storage: [String: Data] = [:]

	private func key(service: String, account: String) -> String {
		"\(service)\u{0}\(account)"
	}

	func read(service: String, account: String) throws -> Data? {
		lock.withLock { storage[key(service: service, account: account)] }
	}

	func write(service: String, account: String, data: Data) throws {
		lock.withLock { storage[key(service: service, account: account)] = data }
	}

	func add(service: String, account: String, data: Data) throws {
		try lock.withLock {
			let storageKey = key(service: service, account: account)
			guard storage[storageKey] == nil else {
				throw KeychainStoreError.status(operation: "add", code: errSecDuplicateItem)
			}
			storage[storageKey] = data
		}
	}

	func delete(service: String, account: String) throws -> Bool {
		lock.withLock { storage.removeValue(forKey: key(service: service, account: account)) != nil }
	}
}

@Suite("KeychainService", .serialized)
struct KeychainServiceTests {
	private func makeService() -> KeychainService {
		KeychainService(
			testingService: "dev.lpm.vault.test.\(UUID().uuidString)",
			backend: KeychainServiceTestBackend()
		)
	}

	private func cleanup(service: KeychainService, vaultIds: [String]) {
		for id in vaultIds {
			_ = service.applyVaultTransaction(
				project: .delete(vaultId: id, deletePayload: true),
				data: []
			)
		}
	}

	private func succeeded(_ result: KeychainResult) -> Bool {
		switch result {
		case .success, .successWithWarning: true
		case .failure: false
		}
	}

	// MARK: - CRUD

	@Test("round-trip: create then read returns the same environments")
	func roundTrip() {
		let service = makeService()
		let vaultId = "test-\(UUID().uuidString.prefix(8))"
		defer { cleanup(service: service, vaultIds: [vaultId]) }

		let secrets = ["DB_HOST": "localhost", "API_KEY": "sk-123", "PORT": "3000"]

		let environments = ["default": secrets]
		let result = service.createEnvironments(
			vaultId: vaultId,
			projectName: "test-project",
			projectPath: "/tmp/test-project",
			environments: environments
		)

		guard case .success = result else {
			Issue.record("Save failed: \(result)")
			return
		}

		let retrieved = service.getEnvironments(vaultId: vaultId)
		#expect(retrieved == environments)
	}

	@Test("update overwrites existing secrets")
	func update() {
		let service = makeService()
		let vaultId = "test-\(UUID().uuidString.prefix(8))"
		defer { cleanup(service: service, vaultIds: [vaultId]) }

		// Create
		_ = service.createEnvironments(
			vaultId: vaultId,
			projectName: "project",
			projectPath: "/tmp/p",
			environments: ["default": ["KEY": "old-value"]]
		)

		// Update
		let result = service.saveEnvironments(
			vaultId: vaultId,
			projectName: "project-renamed",
			projectPath: "/tmp/p-new",
			environments: ["default": ["KEY": "new-value", "NEW_KEY": "added"]]
		)

		guard case .success = result else {
			Issue.record("Update failed: \(result)")
			return
		}

		let retrieved = service.getEnvironments(vaultId: vaultId)
		#expect(retrieved?["default"]?["KEY"] == "new-value")
		#expect(retrieved?["default"]?["NEW_KEY"] == "added")
	}

	@Test("delete removes item")
	func delete() {
		let service = makeService()
		let vaultId = "test-\(UUID().uuidString.prefix(8))"

		// Create
		_ = service.createEnvironments(
			vaultId: vaultId,
			projectName: "to-delete",
			projectPath: "/tmp/d",
			environments: ["default": ["KEY": "val"]]
		)

		// Delete
		let deleted = service.applyVaultTransaction(
			project: .delete(vaultId: vaultId, deletePayload: true),
			data: []
		)
		#expect(succeeded(deleted))

		// Verify gone
		let retrieved = service.getEnvironments(vaultId: vaultId)
		#expect(retrieved == nil)
	}

	@Test("delete non-existent item returns true (idempotent)")
	func deleteNonExistent() {
		let service = makeService()
		let deleted = service.applyVaultTransaction(
			project: .delete(
				vaultId: "nonexistent-\(UUID().uuidString)",
				deletePayload: true
			),
			data: []
		)
		#expect(succeeded(deleted))
	}

	@Test("get non-existent environment map returns nil")
	func getNonExistent() {
		let service = makeService()
		let result = service.getEnvironments(vaultId: "nonexistent-\(UUID().uuidString)")
		#expect(result == nil)
	}

	// MARK: - List

	@Test("list projects returns all vault items")
	func listProjects() {
		// Isolated service to avoid race conditions with parallel tests sharing the index
		let isolatedService = KeychainService(
			testingService: "dev.lpm.vault.list.\(UUID().uuidString.prefix(8))",
			backend: KeychainServiceTestBackend()
		)
		let id1 = "list-\(UUID().uuidString.prefix(8))"
		let id2 = "list-\(UUID().uuidString.prefix(8))"
		defer {
			cleanup(service: isolatedService, vaultIds: [id1, id2])
		}

		_ = isolatedService.createEnvironments(
			vaultId: id1,
			projectName: "project-alpha",
			projectPath: "/tmp/alpha",
			environments: ["default": ["A": "1"]]
		)
		_ = isolatedService.createEnvironments(
			vaultId: id2,
			projectName: "project-beta",
			projectPath: "/tmp/beta",
			environments: ["default": ["B": "2"]]
		)

		let projects = isolatedService.listProjects()

		#expect(projects.count == 2)

		let alpha = projects.first { $0.id == id1 }
		#expect(alpha?.name == "project-alpha")
		#expect(alpha?.path == "/tmp/alpha")
		#expect(alpha?.secrets(for: "default") == ["A": "1"])

		let beta = projects.first { $0.id == id2 }
		#expect(beta?.name == "project-beta")
		#expect(beta?.secrets(for: "default") == ["B": "2"])
	}

	@Test("list projects when empty returns empty array")
	func listEmpty() {
		// Use a unique service that definitely has no items
		let service = KeychainService(
			testingService: "dev.lpm.vault.empty.\(UUID().uuidString.prefix(8))",
			backend: KeychainServiceTestBackend()
		)
		let projects = service.listProjects()
		#expect(projects.isEmpty)
	}

	// MARK: - Edge Cases

	@Test("empty default environment is valid")
	func emptySecrets() {
		let service = makeService()
		let vaultId = "test-\(UUID().uuidString.prefix(8))"
		defer { cleanup(service: service, vaultIds: [vaultId]) }

		let result = service.createEnvironments(
			vaultId: vaultId,
			projectName: "empty-project",
			projectPath: "/tmp/empty",
			environments: ["default": [:]]
		)

		guard case .success = result else {
			Issue.record("Save empty secrets failed")
			return
		}

		let retrieved = service.getEnvironments(vaultId: vaultId)
		#expect(retrieved == ["default": [:]])
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

		_ = service.createEnvironments(
			vaultId: vaultId,
			projectName: "special",
			projectPath: "/tmp/special",
			environments: ["default": secrets]
		)

		let retrieved = service.getEnvironments(vaultId: vaultId)
		#expect(retrieved == ["default": secrets])
	}

	@Test("invalid decoded environment maps fail closed")
	func invalidDecodedEnvironmentMapFailsClosed() throws {
		let service = makeService()
		let vaultId = "test-\(UUID().uuidString.prefix(8))"
		defer { cleanup(service: service, vaultIds: [vaultId]) }
		guard case .success = service.createEnvironments(
			vaultId: vaultId,
			projectName: "invalid",
			projectPath: "",
			environments: ["default": [:]]
		) else {
			Issue.record("Could not create the indexed test project")
			return
		}
		let invalid = try JSONSerialization.data(withJSONObject: [
			"environments": ["../unsafe": ["VALID_KEY": "value"]]
		])
		#expect(service.writeData(account: vaultId, data: invalid))

		guard case .failure = service.getProjectResult(vaultId: vaultId) else {
			Issue.record("Invalid decoded environments were accepted")
			return
		}
	}

	@Test("invalid environment maps are rejected before writes")
	func invalidEnvironmentMapWriteIsRejected() {
		let service = makeService()
		let vaultId = "test-\(UUID().uuidString.prefix(8))"
		defer { cleanup(service: service, vaultIds: [vaultId]) }

		guard case .failure = service.saveEnvironments(
			vaultId: vaultId,
			projectName: "invalid",
			projectPath: "",
			environments: ["default": ["BAD-KEY": "value"]]
		) else {
			Issue.record("Invalid environment data was written")
			return
		}
		#expect(service.getEnvironments(vaultId: vaultId) == nil)
	}

	@Test("an empty environment wrapper normalizes to the default environment")
	func emptyEnvironmentWrapperNormalizesToDefault() throws {
		let service = makeService()
		let vaultId = "test-\(UUID().uuidString.prefix(8))"
		defer { cleanup(service: service, vaultIds: [vaultId]) }
		guard case .success = service.createEnvironments(
			vaultId: vaultId,
			projectName: "empty",
			projectPath: "",
			environments: ["default": [:]]
		) else {
			Issue.record("Could not create the indexed test project")
			return
		}
		let empty = try JSONSerialization.data(withJSONObject: ["environments": [:]])
		#expect(service.writeData(account: vaultId, data: empty))

		#expect(service.getEnvironments(vaultId: vaultId) == ["default": [:]])
	}
}

@Suite("Shared Keychain migration")
struct SharedKeychainMigrationTests {
	@Test("transaction locks reject hard-linked files without changing their target")
	func transactionLockRejectsHardLinks() throws {
		let home = FileManager.default.temporaryDirectory
			.appendingPathComponent(UUID().uuidString, isDirectory: true)
		let directory = home.appendingPathComponent(".lpm", isDirectory: true)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: home) }
		let target = home.appendingPathComponent("target")
		let lock = directory.appendingPathComponent(".vault-keychain.lock")
		try Data("target".utf8).write(to: target)
		try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: target.path)
		#expect(Darwin.link(target.path, lock.path) == 0)

		#expect(throws: KeychainStoreError.self) {
			let descriptor = try VaultKeychainTransactionLock.openLockFile(homeURL: home)
			_ = Darwin.close(descriptor)
		}
		let permissions = try #require(
			FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? NSNumber
		)
		#expect(permissions.intValue & 0o777 == 0o640)
	}

	@Test("transaction locks reject pathname replacement before admission")
	func transactionLockRejectsPathReplacement() throws {
		let home = FileManager.default.temporaryDirectory
			.appendingPathComponent(UUID().uuidString, isDirectory: true)
		let directory = home.appendingPathComponent(".lpm", isDirectory: true)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: home) }
		let lock = directory.appendingPathComponent(".vault-keychain.lock")
		let displaced = directory.appendingPathComponent("displaced.lock")
		try Data("original".utf8).write(to: lock)
		try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: lock.path)

		#expect(throws: KeychainStoreError.self) {
			let descriptor = try VaultKeychainTransactionLock.openLockFile(
				homeURL: home,
				beforeLock: {
					try FileManager.default.moveItem(at: lock, to: displaced)
					try Data("replacement".utf8).write(to: lock)
					try FileManager.default.setAttributes(
						[.posixPermissions: 0o600],
						ofItemAtPath: lock.path
					)
				}
			)
			_ = Darwin.close(descriptor)
		}
		#expect(try Data(contentsOf: lock) == Data("replacement".utf8))
	}

	@Test("transaction locks reject directory replacement before admission")
	func transactionLockRejectsDirectoryReplacement() throws {
		let home = FileManager.default.temporaryDirectory
			.appendingPathComponent(UUID().uuidString, isDirectory: true)
		let directory = home.appendingPathComponent(".lpm", isDirectory: true)
		let displaced = home.appendingPathComponent("displaced.lpm", isDirectory: true)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: home) }
		let lock = directory.appendingPathComponent(".vault-keychain.lock")
		try Data("original".utf8).write(to: lock)
		try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: lock.path)

		#expect(throws: KeychainStoreError.self) {
			let descriptor = try VaultKeychainTransactionLock.openLockFile(
				homeURL: home,
				beforeLock: {
					try FileManager.default.moveItem(at: directory, to: displaced)
					try FileManager.default.createDirectory(
						at: directory,
						withIntermediateDirectories: false
					)
					let replacement = directory.appendingPathComponent(".vault-keychain.lock")
					try Data("replacement".utf8).write(to: replacement)
					try FileManager.default.setAttributes(
						[.posixPermissions: 0o600],
						ofItemAtPath: replacement.path
					)
				}
			)
			_ = Darwin.close(descriptor)
		}
	}

	private final class FakeBackend: KeychainStoreBackend {
		var shared: [String: Data] = [:]
		var corruptSharedWrites = false
		var rejectSharedDelete = false
		var rejectSharedReads = false
		var sharedWriteFailuresRemaining = 0
		var sharedValueInsertedBeforeAdd: Data?
		var sharedValueUpdatedAfterAdd: Data?
		var sharedValueUpdatedAfterWrite: Data?
		var sharedReadCounts: [String: Int] = [:]
		var events: [String] = []
		var failCommittedMarkerVerificationOnce = false
		var failFinalMarkerDeletionVerificationOnce = false
		var finalMarkerWasDeleted = false
		var rejectReadsAfterCommittedMarker = false

		func readCount(account: String) -> Int {
			sharedReadCounts[account, default: 0]
		}

		func read(service: String, account: String) throws -> Data? {
			sharedReadCounts[account, default: 0] += 1
			if rejectReadsAfterCommittedMarker,
				shared["__vault_transaction_v3__"].map({
					String(decoding: $0, as: UTF8.self).contains(#""state":"committed""#)
				}) == true
			{
				throw KeychainStoreError.status(operation: "read", code: errSecNotAvailable)
			}
			if rejectSharedReads {
				throw KeychainStoreError.status(operation: "read", code: errSecMissingEntitlement)
			}
			if account == "__vault_transaction_v3__",
				failCommittedMarkerVerificationOnce,
				let marker = shared[account],
				String(decoding: marker, as: UTF8.self).contains(#""state":"committed""#)
			{
				failCommittedMarkerVerificationOnce = false
				throw KeychainStoreError.status(operation: "read", code: errSecNotAvailable)
			}
			if account == "__vault_transaction_v3__",
				failFinalMarkerDeletionVerificationOnce,
				finalMarkerWasDeleted,
				shared[account] == nil
			{
				failFinalMarkerDeletionVerificationOnce = false
				throw KeychainStoreError.status(operation: "read", code: errSecNotAvailable)
			}
			return shared[account]
		}

		func write(service: String, account: String, data: Data) throws {
			events.append("write:\(account)")
			if sharedWriteFailuresRemaining > 0 {
				sharedWriteFailuresRemaining -= 1
				throw KeychainStoreError.status(operation: "write", code: errSecNotAvailable)
			}
			shared[account] = corruptSharedWrites ? Data("corrupt".utf8) : data
			if let concurrent = sharedValueUpdatedAfterWrite {
				sharedValueUpdatedAfterWrite = nil
				shared[account] = concurrent
			}
		}

		func add(service: String, account: String, data: Data) throws {
			events.append("add:\(account)")
			if let concurrent = sharedValueInsertedBeforeAdd {
				sharedValueInsertedBeforeAdd = nil
				shared[account] = concurrent
				throw KeychainStoreError.status(operation: "add", code: errSecDuplicateItem)
			}
			guard shared[account] == nil else {
				throw KeychainStoreError.status(operation: "add", code: errSecDuplicateItem)
			}
			try write(service: service, account: account, data: data)
			if let concurrent = sharedValueUpdatedAfterAdd {
				sharedValueUpdatedAfterAdd = nil
				shared[account] = concurrent
			}
		}

		func delete(service: String, account: String) throws -> Bool {
			if rejectSharedDelete {
				throw KeychainStoreError.status(operation: "delete", code: errSecNotAvailable)
			}
			events.append("delete:\(account)")
			let markerWasCommitted = account == "__vault_transaction_v3__"
				&& shared[account].map {
					String(decoding: $0, as: UTF8.self).contains(#""state":"committed""#)
				} == true
			let deleted = shared.removeValue(forKey: account) != nil
			if markerWasCommitted, deleted { finalMarkerWasDeleted = true }
			return deleted
		}
	}

	@Test("committed journal recovery acknowledges transaction success")
	func committedJournalRecoveryAcknowledgesSuccess() throws {
		let backend = FakeBackend()
		backend.failCommittedMarkerVerificationOnce = true
		let store = SharedKeychainStore(service: "service", backend: backend)
		let payload = Data(#"{"environments":{"default":{"TOKEN":"secret"}}}"#.utf8)

		try store.applyVaultTransaction([
			.write(account: "vault-id", data: payload)
		])

		#expect(backend.shared["vault-id"] == payload)
		#expect(backend.shared["__vault_transaction_v3__"] == nil)
	}

	@Test("one outer transaction performs one recovery check per store")
	func outerTransactionRecoversEachStoreOnce() throws {
		let backend = FakeBackend()
		let store = SharedKeychainStore(service: "service", backend: backend)

		try VaultKeychainTransactionLock.withLock {
			let first = try store.read(account: "first")
			let second = try store.read(account: "second")
			let third = try store.read(account: "third")
			#expect(first == nil)
			#expect(second == nil)
			#expect(third == nil)
		}

		#expect(backend.readCount(account: "__vault_transaction_v3__") == 1)
		let fourth = try store.read(account: "fourth")
		#expect(fourth == nil)
		#expect(backend.readCount(account: "__vault_transaction_v3__") == 2)
	}

	@Test("an unverifiable committed transaction reports an indeterminate outcome")
	func committedJournalVerificationFailureIsIndeterminate() throws {
		let backend = FakeBackend()
		backend.rejectReadsAfterCommittedMarker = true
		let store = SharedKeychainStore(service: "service", backend: backend)
		let payload = Data(#"{"environments":{"default":{"TOKEN":"secret"}}}"#.utf8)

		#expect(throws: KeychainStoreError.transactionOutcomeIndeterminate) {
			try store.applyVaultTransaction([
				.write(account: "vault-id", data: payload)
			])
		}
		#expect(backend.shared["__vault_transaction_v3__"] != nil)
		#expect(backend.shared["vault-id"] == nil)

		backend.rejectReadsAfterCommittedMarker = false
		try store.recoverVaultTransaction()

		#expect(backend.shared["vault-id"] == payload)
		#expect(backend.shared["__vault_transaction_v3__"] == nil)
	}

	@Test("a final marker verification read failure acknowledges durable commit")
	func finalMarkerVerificationFailureAcknowledgesSuccess() throws {
		let backend = FakeBackend()
		backend.failFinalMarkerDeletionVerificationOnce = true
		let store = SharedKeychainStore(service: "service", backend: backend)
		let payload = Data(#"{"environments":{"default":{"TOKEN":"secret"}}}"#.utf8)

		try store.applyVaultTransaction([
			.write(account: "vault-id", data: payload)
		])

		#expect(backend.shared["vault-id"] == payload)
		#expect(backend.shared["__vault_transaction_v3__"] == nil)
	}

	@Test("journal updates remain authoritative on subsequent reads")
	func journalUpdateIsAuthoritativeOnRead() throws {
		let backend = FakeBackend()
		let oldPayload = Data(#"{"environments":{"default":{"TOKEN":"old"}}}"#.utf8)
		let newPayload = Data(#"{"environments":{"default":{"TOKEN":"new"}}}"#.utf8)
		backend.shared["vault-id"] = oldPayload
		let store = SharedKeychainStore(service: "service", backend: backend)

		try store.applyVaultTransaction([
			.write(account: "vault-id", data: newPayload)
		])

		#expect(try store.read(account: "vault-id") == newPayload)
		#expect(backend.shared["vault-id"] == newPayload)
	}

	@Test("live transaction roll-forward reuses staged source bytes")
	func liveTransactionRollForwardDoesNotRereadTheStage() throws {
		let backend = FakeBackend()
		let store = SharedKeychainStore(service: "service", backend: backend)
		let payload = Data(#"{"environments":{"default":{"TOKEN":"secret"}}}"#.utf8)

		try store.applyVaultTransaction([.write(account: "vault-id", data: payload)])

		let stageReadCounts = backend.sharedReadCounts.filter {
			$0.key.hasPrefix("__vault_transaction_stage_v3__:")
		}
		#expect(stageReadCounts.count == 1)
		#expect(stageReadCounts.values.first == 2)
	}

	@Test("typed project payloads are summarized without reparsing and hashed once")
	func preparedProjectPayloadAvoidsLiveReparsingAndRehashing() {
		let backend = FakeBackend()
		let counters = VaultKeychainPerformanceCounters()
		let service = KeychainService(
			testingService: "service",
			backend: backend,
			performanceCounters: counters
		)
		let result = service.createEnvironments(
			vaultId: "vault-id",
			projectName: "Project",
			projectPath: "",
			environments: ["default": ["TOKEN": "secret"]]
		)

		guard case .success = result else {
			Issue.record("Expected the project transaction to succeed.")
			return
		}
		let snapshot = counters.snapshot
		#expect(snapshot.projectPayloadParseCount == 0)
		#expect(snapshot.projectPayloadHashCount == 1)
		#expect(snapshot.livePayloadReuseCount > 0)
	}

	@Test("committed journals reject redirected write targets")
	func committedJournalRejectsRedirectedWriteTarget() throws {
		let backend = FakeBackend()
		let transactionId = "00000000-0000-4000-8000-000000000001"
		let stage = "__vault_transaction_stage_v3__:\(transactionId):0"
		let payload = Data(#"{"environments":{"default":{"TOKEN":"secret"}}}"#.utf8)
		backend.shared[stage] = payload
		backend.shared["__vault_transaction_v3__"] = try JSONSerialization.data(
			withJSONObject: [
				"schemaVersion": 3,
				"transactionId": transactionId,
				"state": "committed",
				"operations": [[
					"action": "write",
					"targetAccount": "redirected-vault",
					"stagedAccount": stage,
					"operationSha256": operationDigest(
						action: "write", target: "original-vault", data: payload),
				]],
			]
		)
		let store = SharedKeychainStore(service: "service", backend: backend)

		#expect(throws: KeychainStoreError.self) {
			try store.recoverVaultTransaction()
		}

		#expect(backend.shared["redirected-vault"] == nil)
	}

	@Test("persisted recovery independently validates and hashes staged project bytes")
	func persistedRecoveryDoesNotTrustLiveValidationProofs() throws {
		let backend = FakeBackend()
		let counters = VaultKeychainPerformanceCounters()
		let transactionId = "00000000-0000-4000-8000-000000000001"
		let target = "vault-id"
		let stage = "__vault_transaction_stage_v3__:\(transactionId):0"
		let payload = Data(#"{"environments":{"default":{"TOKEN":"secret"}}}"#.utf8)
		backend.shared[stage] = payload
		backend.shared["__vault_transaction_v3__"] = try JSONSerialization.data(
			withJSONObject: [
				"schemaVersion": 3,
				"transactionId": transactionId,
				"state": "committed",
				"operations": [[
					"action": "write",
					"targetAccount": target,
					"stagedAccount": stage,
					"operationSha256": operationDigest(
						action: "write", target: target, data: payload),
				]],
			]
		)
		let store = SharedKeychainStore(
			service: "service",
			backend: backend,
			performanceCounters: counters
		)

		try store.recoverVaultTransaction()

		#expect(backend.shared[target] == payload)
		#expect(counters.snapshot.projectPayloadParseCount == 1)
		#expect(counters.snapshot.projectPayloadHashCount == 1)
	}

	@Test("committed journals reject redirected delete targets")
	func committedJournalRejectsRedirectedDeleteTarget() throws {
		let backend = FakeBackend()
		let transactionId = "00000000-0000-4000-8000-000000000001"
		let payload = Data(#"{"environments":{"default":{}}}"#.utf8)
		backend.shared["redirected-vault"] = payload
		backend.shared["__vault_transaction_v3__"] = try JSONSerialization.data(
			withJSONObject: [
				"schemaVersion": 3,
				"transactionId": transactionId,
				"state": "committed",
				"operations": [[
					"action": "delete",
					"targetAccount": "redirected-vault",
					"operationSha256": operationDigest(
						action: "delete", target: "original-vault", data: nil),
				]],
			]
		)
		let store = SharedKeychainStore(service: "service", backend: backend)

		#expect(throws: KeychainStoreError.self) {
			try store.recoverVaultTransaction()
		}

		#expect(backend.shared["redirected-vault"] == payload)
	}

	@Test("journal decoding rejects unknown marker fields")
	func journalRejectsUnknownMarkerFields() throws {
		let backend = FakeBackend()
		backend.shared["__vault_transaction_v3__"] = Data(#"""
		{
			"schemaVersion":3,
			"transactionId":"00000000-0000-4000-8000-000000000001",
			"state":"committed",
			"operations":[],
			"unknown":true
		}
		"""#.utf8)
		let store = SharedKeychainStore(service: "service", backend: backend)

		#expect(throws: KeychainStoreError.self) {
			try store.recoverVaultTransaction()
		}
	}

	@Test("journal decoding rejects duplicate marker keys")
	func journalRejectsDuplicateMarkerKeys() throws {
		let backend = FakeBackend()
		let transactionId = "00000000-0000-4000-8000-000000000001"
		let target = "vault-id"
		let payload = Data(#"{"environments":{"default":{"TOKEN":"secret"}}}"#.utf8)
		let stage = "__vault_transaction_stage_v3__:\(transactionId):0"
		backend.shared[stage] = payload
		let digest = operationDigest(action: "write", target: target, data: payload)
		backend.shared["__vault_transaction_v3__"] = Data(#"""
		{"schemaVersion":3,"schemaVersion":3,"transactionId":"\#(transactionId)","state":"committed","operations":[{"action":"write","targetAccount":"\#(target)","stagedAccount":"\#(stage)","operationSha256":"\#(digest)"}]}
		"""#.utf8)
		let store = SharedKeychainStore(service: "service", backend: backend)

		#expect(throws: KeychainStoreError.self) {
			try store.recoverVaultTransaction()
		}
		#expect(backend.shared[target] == nil)
	}

	@Test("strict JSON validation accepts its maximum nesting depth")
	func strictJSONValidationAcceptsMaximumDepth() throws {
		let depth = 128
		let json = String(repeating: "[", count: depth)
			+ "0"
			+ String(repeating: "]", count: depth)

		try StrictJSONKeyValidator.validate(Data(json.utf8))
	}

	@Test("strict JSON validation rejects excessive nesting")
	func strictJSONValidationRejectsExcessiveDepth() {
		let depth = 129
		let json = String(repeating: "[", count: depth)
			+ "0"
			+ String(repeating: "]", count: depth)

		#expect(throws: KeychainStoreError.integrityValidationFailed) {
			try StrictJSONKeyValidator.validate(Data(json.utf8))
		}
	}

	@Test("strict JSON validation materializes only object keys without copying input")
	func strictJSONValidationAvoidsWholeInputAndValueCopies() throws {
		let value = String(repeating: "payload", count: 10_000)
		let data = Data(#"{"outer":{"key":"\#(value)"},"escaped\u004bey":"value"}"#.utf8)

		let profile = try StrictJSONKeyValidator.validationProfile(data)

		#expect(profile.materializedStringCount == 3)
		#expect(profile.copiedInputByteCount == 0)
	}

	@Test("strict JSON validation enforces scalar-valid UTF-8 and surrogate pairs")
	func strictJSONValidationEnforcesUnicodeScalarSemantics() throws {
		try StrictJSONKeyValidator.validate(Data(#"{"😀":"\uD83D\uDE00"}"#.utf8))

		let invalidRawSequences: [[UInt8]] = [
			[0xC0, 0x80],
			[0xE0, 0x80, 0x80],
			[0xED, 0xA0, 0x80],
			[0xF4, 0x90, 0x80, 0x80],
			[0x80],
			[0xF0, 0x9F, 0x98],
		]
		for sequence in invalidRawSequences {
			var bytes = Array(#"{"key":""#.utf8)
			bytes.append(contentsOf: sequence)
			bytes.append(contentsOf: Array(#""}"#.utf8))
			#expect(throws: KeychainStoreError.integrityValidationFailed) {
				try StrictJSONKeyValidator.validate(Data(bytes))
			}
		}

		for json in [
			#"{"\uD800":"value"}"#,
			#"{"\uDC00":"value"}"#,
			#"{"\uD800\u0041":"value"}"#,
		] {
			#expect(throws: KeychainStoreError.integrityValidationFailed) {
				try StrictJSONKeyValidator.validate(Data(json.utf8))
			}
		}
	}

	@Test("journal decoding rejects escaped duplicate operation keys")
	func journalRejectsDuplicateOperationKeys() throws {
		let backend = FakeBackend()
		let transactionId = "00000000-0000-4000-8000-000000000001"
		let target = "vault-id"
		let payload = Data(#"{"environments":{"default":{"TOKEN":"secret"}}}"#.utf8)
		let stage = "__vault_transaction_stage_v3__:\(transactionId):0"
		backend.shared[stage] = payload
		let digest = operationDigest(action: "write", target: target, data: payload)
		backend.shared["__vault_transaction_v3__"] = Data(#"""
		{"schemaVersion":3,"transactionId":"\#(transactionId)","state":"committed","operations":[{"action":"write","targetAccount":"\#(target)","target\u0041ccount":"\#(target)","stagedAccount":"\#(stage)","operationSha256":"\#(digest)"}]}
		"""#.utf8)
		let store = SharedKeychainStore(service: "service", backend: backend)

		#expect(throws: KeychainStoreError.self) {
			try store.recoverVaultTransaction()
		}
		#expect(backend.shared[target] == nil)
	}

	@Test("journal recovery rejects duplicate keys in a staged target")
	func journalRejectsDuplicateStagedTargetKeys() throws {
		let backend = FakeBackend()
		let transactionId = "00000000-0000-4000-8000-000000000001"
		let target = "vault-id"
		let payload = Data(
			#"{"environments":{"default":{"TOKEN":"one","TOKEN":"two"}}}"#.utf8)
		let stage = "__vault_transaction_stage_v3__:\(transactionId):0"
		backend.shared[stage] = payload
		let digest = operationDigest(action: "write", target: target, data: payload)
		backend.shared["__vault_transaction_v3__"] = Data(#"""
		{"schemaVersion":3,"transactionId":"\#(transactionId)","state":"committed","operations":[{"action":"write","targetAccount":"\#(target)","stagedAccount":"\#(stage)","operationSha256":"\#(digest)"}]}
		"""#.utf8)
		let store = SharedKeychainStore(service: "service", backend: backend)

		#expect(throws: KeychainStoreError.self) {
			try store.recoverVaultTransaction()
		}
		#expect(backend.shared[target] == nil)
	}

	@Test("sync metadata transaction targets require canonical vault ID encoding")
	func syncMetadataTargetRejectsBase64Alias() {
		let backend = FakeBackend()
		let store = SharedKeychainStore(service: "service", backend: backend)
		let record = Data(#"{"schemaVersion":3,"vaultId":"vault","metadata":{"isDirty":false,"checkpoints":[]}}"#.utf8)

		#expect(throws: KeychainStoreError.self) {
			try store.applyVaultTransaction([
				.write(account: "__sync_metadata__:dmF1bHQ=", data: record)
			])
		}
	}

	@Test("journal recovery rejects retired sync metadata targets")
	func journalRejectsRetiredSyncMetadataTargets() {
		let backend = FakeBackend()
		let store = SharedKeychainStore(service: "service", backend: backend)
		let record = Data(#"{"schemaVersion":2,"vaultId":"vault","metadata":{"isDirty":false,"checkpoints":[]}}"#.utf8)

		#expect(throws: KeychainStoreError.self) {
			try store.applyVaultTransaction([
				.write(account: "__sync_metadata_v2__:dmF1bHQ", data: record)
			])
		}
		#expect(throws: KeychainStoreError.self) {
			try store.applyVaultTransaction([
				.delete(account: "__sync_metadata_v2_marker__")
			])
		}
	}

	private func operationDigest(action: String, target: String, data: Data?) -> String {
		var input = Data("lpm-vault-transaction-operation\0".utf8)
		input.append(contentsOf: action.utf8)
		input.append(0)
		input.append(contentsOf: target.utf8)
		input.append(0)
		if let data { input.append(data) }
		return SHA256.hash(data: input).map { String(format: "%02x", $0) }.joined()
	}

	@Test("journal project mutations preserve exact oversized-payload errors")
	func journalProjectMutationPreservesOversizedPayloadError() {
		let backend = FakeBackend()
		let service = KeychainService(
			testingService: "oversized-project",
			backend: backend
		)
		let project = VaultProject(
			id: "vault-id",
			name: "Project",
			path: "",
			environments: ["default": ["TOKEN": String(repeating: "x", count: 100_000)]]
		)

		guard case .failure(.dataTooLarge(let byteCount)) = service.applyVaultTransaction(
			project: .create(project),
			data: []
		) else {
			Issue.record("Expected the exact oversized-payload error.")
			return
		}

		#expect(byteCount > VaultConstants.maxVaultSizeWarning)
		#expect(backend.shared.isEmpty)
	}

	@Test("queries require the Team-scoped Data Protection Keychain")
	func protectedQueryContract() throws {
		let query = SecurityKeychainStoreBackend.identityQuery(
			service: "service",
			account: "account"
		)

		#expect(
			query[kSecAttrAccessGroup as String] as? String == VaultConstants.keychainAccessGroup)
		#expect(query[kSecUseDataProtectionKeychain as String] as? Bool == true)
		#expect(query[kSecUseKeychain as String] == nil)
	}


	@Test("write verification never rolls back a concurrent protected update")
	func concurrentUpdateAfterWrite() {
		let backend = FakeBackend()
		backend.shared["account"] = Data("previous".utf8)
		backend.sharedValueUpdatedAfterWrite = Data("concurrent".utf8)
		let store = SharedKeychainStore(service: "service", backend: backend)

		#expect(throws: KeychainStoreError.concurrentModification) {
			try store.write(account: "account", data: Data("requested".utf8))
		}
		#expect(backend.shared["account"] == Data("concurrent".utf8))
	}

	@Test("add verification never deletes a concurrent protected update")
	func concurrentUpdateAfterAdd() {
		let backend = FakeBackend()
		backend.sharedValueUpdatedAfterAdd = Data("concurrent".utf8)
		let store = SharedKeychainStore(service: "service", backend: backend)

		#expect(throws: KeychainStoreError.concurrentModification) {
			try store.add(account: "account", data: Data("requested".utf8))
		}
		#expect(backend.shared["account"] == Data("concurrent".utf8))
	}

	@Test("a protected delete failure preserves the protected copy")
	func sharedDeleteFailureIsRecoverable() throws {
		let backend = FakeBackend()
		let value = Data("secret".utf8)
		backend.shared["account"] = value
		backend.rejectSharedDelete = true
		let store = SharedKeychainStore(service: "service", backend: backend)

		#expect(throws: KeychainStoreError.status(operation: "delete", code: errSecNotAvailable)) {
			_ = try store.delete(account: "account")
		}
		#expect(backend.shared["account"] == value)

		backend.rejectSharedDelete = false
		#expect(try store.read(account: "account") == value)
	}

	@Test("a protected read error never creates or replaces key material")
	func readFailureDoesNotWrite() {
		let backend = FakeBackend()
		backend.rejectSharedReads = true
		let store = SharedKeychainStore(service: "service", backend: backend)

		#expect(
			throws: KeychainStoreError.status(operation: "read", code: errSecMissingEntitlement)
		) {
			try store.write(account: "account", data: Data("new".utf8))
		}
		#expect(backend.shared["account"] == nil)
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
