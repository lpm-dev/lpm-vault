import Foundation
import Testing

@testable import LPMVault

@Suite("Local history in the Keychain")
struct HistoryKeychainTests {
	private let vaultId = "history-keychain"

	private func makeService() -> (KeychainService, InMemoryKeychainBackend, String) {
		let backend = InMemoryKeychainBackend()
		let name = "dev.lpm.vault.history.\(UUID().uuidString)"
		return (KeychainService(testingService: name, backend: backend), backend, name)
	}

	/// The project's history as `backend` holds it.
	private func stored(_ backend: InMemoryKeychainBackend, service: String) throws -> HistoryEngine.Stored? {
		let read = { (account: String) in try backend.read(service: service, account: account) }
		guard let head = try read(HistoryRecorder.account("history-head", vaultId)),
			let key = try read(HistoryRecorder.account("key", vaultId))
		else { return nil }
		struct Head: Decodable { let parts: [Int] }
		let parts = try JSONDecoder().decode(Head.self, from: head).parts.map { part in
			(part: part, bytes: try read(HistoryRecorder.account("history", vaultId, part: part)).map { data in
				data.withUnsafeBytes { SecretBytes(copying: $0) }
			})
		}
		return HistoryEngine.Stored(
			vaultId: vaultId, head: head.withUnsafeBytes { SecretBytes(copying: $0) },
			key: key.withUnsafeBytes { SecretBytes(copying: $0) }, parts: parts)
	}

	private func actions(_ stored: HistoryEngine.Stored) throws -> [String] {
		try HistoryEngine.timeline(stored, values: nil).rows.compactMap { row in
			if case .entry(let entry) = row { return entry.action }
			return nil
		}
	}

	@Test("each values write is recorded with its source once its lock scope ends")
	func valuesWritesAreRecorded() throws {
		let (service, backend, name) = makeService()
		let created = VaultHistorySource(.set)
		guard case .success = service.createEnvironments(
			vaultId: vaultId, projectName: "Project", projectPath: "", environments: ["default": ["A": "1"]], source: created)
		else { throw KeychainError.encodingFailed }
		#expect(service.takeHistoryOutcomes()[vaultId] == .recorded(entry: created.id, gap: false, crowded: nil))

		let edited = VaultHistorySource(.editKey)
		guard case .success = service.applyVaultTransaction(
			project: .update(vaultId: vaultId, environments: ["default": ["A": "2"]], source: edited), data: [])
		else { throw KeychainError.encodingFailed }
		#expect(service.takeHistoryOutcomes()[vaultId] == .recorded(entry: edited.id, gap: false, crowded: nil))
		#expect(try actions(try #require(try stored(backend, service: name))) == ["editKey", "set"])
	}

	@Test("a project created without values starts no history")
	func emptyProjectsStartNoHistory() throws {
		let (service, backend, name) = makeService()
		guard case .success = service.createEnvironments(
			vaultId: vaultId, projectName: "Project", projectPath: "", environments: ["default": [:]],
			source: VaultHistorySource(.createEnvironment))
		else { throw KeychainError.encodingFailed }
		#expect(service.takeHistoryOutcomes().isEmpty)
		#expect(try stored(backend, service: name) == nil)
	}

	@Test("one lock scope with several writes to a project records their net change once")
	func oneScopeRecordsOneEntry() throws {
		let (service, backend, name) = makeService()
		guard case .success = service.createEnvironments(
			vaultId: vaultId, projectName: "Project", projectPath: "", environments: ["default": ["A": "1"]],
			source: VaultHistorySource(.set))
		else { throw KeychainError.encodingFailed }
		_ = service.takeHistoryOutcomes()
		let source = VaultHistorySource(.rawEdit)
		_ = service.withKeychainTransaction {
			_ = service.applyVaultTransaction(project: .update(vaultId: vaultId, environments: ["default": ["A": "2"]], source: source), data: [])
			_ = service.applyVaultTransaction(project: .update(vaultId: vaultId, environments: ["default": ["A": "3"]], source: source), data: [])
		}
		#expect(try actions(try #require(try stored(backend, service: name))) == ["rawEdit", "set"])
	}

	@Test("a scope whose writes restore the values it found records nothing")
	func restoredValuesRecordNothing() throws {
		let (service, backend, name) = makeService()
		guard case .success = service.createEnvironments(
			vaultId: vaultId, projectName: "Project", projectPath: "", environments: ["default": ["A": "1"]],
			source: VaultHistorySource(.set))
		else { throw KeychainError.encodingFailed }
		_ = service.takeHistoryOutcomes()
		let source = VaultHistorySource(.renameKey)
		_ = service.withKeychainTransaction {
			_ = service.applyVaultTransaction(project: .update(vaultId: vaultId, environments: ["default": ["B": "1"]], source: source), data: [])
			_ = service.applyVaultTransaction(project: .update(vaultId: vaultId, environments: ["default": ["A": "1"]], source: source), data: [])
		}
		#expect(service.takeHistoryOutcomes().isEmpty, "a compensation that restored the values records nothing")
		#expect(try actions(try #require(try stored(backend, service: name))) == ["set"])
	}

	@Test("a restore merge reviewed against canonically equivalent values that differ is refused")
	func restoreMergeComparesExactly() throws {
		let (service, _, _) = makeService()
		let composed = "caf\u{E9}"
		let decomposed = "cafe\u{301}"
		#expect(composed == decomposed, "Swift's == calls them equal")
		guard case .success = service.createEnvironments(
			vaultId: vaultId, projectName: "Project", projectPath: "", environments: ["default": ["A": decomposed]],
			source: VaultHistorySource(.set))
		else { throw KeychainError.encodingFailed }
		let result = service.mergeRestoredProjectResult(
			vaultId: vaultId, expected: ["default": ["A": composed]], merged: ["default": ["A": "restored"]],
			additionalMutations: [], source: VaultHistorySource(.restore))
		#expect(result == .changedSinceReview)
	}
}
