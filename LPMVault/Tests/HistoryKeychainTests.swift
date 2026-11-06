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

	/// A service whose project `vaultId` went from A=1 to A=2, recorded.
	private func edited() throws -> (KeychainService, InMemoryKeychainBackend, String) {
		let (service, backend, name) = makeService()
		guard case .success = service.createEnvironments(
			vaultId: vaultId, projectName: "Project", projectPath: "", environments: ["default": ["A": "1"]],
			source: VaultHistorySource(.set))
		else { throw KeychainError.encodingFailed }
		guard case .success = service.applyVaultTransaction(
			project: .update(vaultId: vaultId, environments: ["default": ["A": "2"]], source: VaultHistorySource(.editKey)), data: [])
		else { throw KeychainError.encodingFailed }
		_ = service.takeHistoryOutcomes()
		return (service, backend, name)
	}

	private func entries(_ service: KeychainService) throws -> [HistoryEngine.Entry] {
		try #require(try service.historyTimelineResult(vaultId: vaultId, filter: nil).get()).rows.compactMap { row in
			if case .entry(let entry) = row { return entry }
			return nil
		}
	}

	@Test("the timeline and a reveal read the project's history through the service")
	func timelineAndReveal() throws {
		let (service, _, _) = try edited()
		let timeline = try #require(try service.historyTimelineResult(vaultId: vaultId, filter: nil).get())
		#expect(timeline.readable == 2 && timeline.liveGap == nil)
		let edit = try #require(try entries(service).first)
		let revealed = try service.historyRevealResult(vaultId: vaultId, ids: [edit.id]).get()
		let sides = try #require(revealed.response.first?.values?.first?.first)
		let before = sides.before.flatMap { revealed.blobs[$0] }?.withUnsafeBytes { String(decoding: $0, as: UTF8.self) }
		#expect(before == "1")
		#expect(try service.historyStateResult(vaultId: vaultId).get() == VaultHistoryState(history: "on", damage: []))
	}

	@Test("a rollback plans from the history and gives back the reviewed point's values")
	func rollbackGivesTheEarlierValues() throws {
		let (service, _, _) = try edited()
		let edit = try #require(try entries(service).first)
		let target = HistoryEngine.RollbackTarget.undo(entry: edit.id, only: nil)
		let plan = try service.historyRollbackPlanResult(vaultId: vaultId, target: target).get().response
		guard case .failure(.history(code: "history.changed_since_review", _)) = service.historyRolledBackEnvironmentsResult(
			vaultId: vaultId, target: target, fingerprint: "stale", skipped: [], keepEmpty: [])
		else {
			Issue.record("a stale review must be refused")
			return
		}
		let environments = try service.historyRolledBackEnvironmentsResult(
			vaultId: vaultId, target: target, fingerprint: plan.fingerprint, skipped: [], keepEmpty: []).get().environments
		#expect(environments == ["default": ["A": "1"]])
	}

	@Test("removing a value from history leaves no entry that reveals it")
	func removalTakesTheValueOut() throws {
		let (service, _, _) = try edited()
		let edit = try #require(try entries(service).first)
		let review = try service.historyRemovalReviewResult(
			vaultId: vaultId, entry: edit.id, environment: "default", key: "A", side: "before").get()
		#expect(!review.defaultSelection.isEmpty)
		try service.removeFromHistoryResult(vaultId: vaultId, review: review, selection: review.defaultSelection).get()
		let revealed = try service.historyRevealResult(vaultId: vaultId, ids: try entries(service).map(\.id)).get()
		let values = revealed.blobs.items.map { blob in blob.withUnsafeBytes { String(decoding: $0, as: UTF8.self) } }
		#expect(!values.contains("1"), "\(values)")
	}

	@Test("turning history off deletes it and stops recording; turning it on starts again at the next change")
	func historyOffAndOn() throws {
		let (service, backend, name) = try edited()
		try service.setHistoryEnabledResult(vaultId: vaultId, enabled: false).get()
		#expect(try service.historyStateResult(vaultId: vaultId).get().history == "off")
		#expect(try stored(backend, service: name) == nil)
		_ = service.applyVaultTransaction(
			project: .update(vaultId: vaultId, environments: ["default": ["A": "3"]], source: VaultHistorySource(.set)), data: [])
		#expect(service.takeHistoryOutcomes()[vaultId] == .off)
		#expect(try stored(backend, service: name) == nil)

		try service.setHistoryEnabledResult(vaultId: vaultId, enabled: true).get()
		let next = VaultHistorySource(.set)
		_ = service.applyVaultTransaction(
			project: .update(vaultId: vaultId, environments: ["default": ["A": "4"]], source: next), data: [])
		#expect(service.takeHistoryOutcomes()[vaultId] == .recorded(entry: next.id, gap: false, crowded: nil))
		#expect(try actions(try #require(try stored(backend, service: name))) == ["set"])
	}

	@Test("the coordinator applies a reviewed undo as one write recorded as an undo of that entry")
	func coordinatorAppliesAnUndo() async throws {
		let (service, _, _) = try edited()
		let coordinator = VaultPersistenceCoordinator(service: service)
		let edit = try #require(try entries(service).first)
		let target = HistoryEngine.RollbackTarget.undo(entry: edit.id, only: nil)
		let plan = try await coordinator.historyRollbackPlan(vaultId: vaultId, target: target).get().response
		let source = VaultHistorySource(.undo, detail: .init(related: plan.point.related))
		guard case .success(let commit) = await coordinator.mutateProject(
			projectId: vaultId, expectedName: "Project", expectedPath: "",
			mutation: .historyRollback(target: target, plan: plan, skipped: [], keepEmpty: [], source: source))
		else {
			Issue.record("the undo was refused")
			return
		}
		#expect(commit.project.environments == ["default": ["A": "1"]])
		#expect(commit.syncMetadata?.isDirty == true)
		let newest = try #require(try entries(service).first)
		#expect(newest.action == "undo")
		#expect(newest.id == source.id, "the entry is the source the caller made, so it can offer to undo it")
		#expect(newest.related == plan.point.related, "an undo names the entry it undoes, as the engine's plan points at it")
	}

	@Test("an undo reviewed before the values changed again writes nothing")
	func staleUndoWritesNothing() async throws {
		let (service, _, _) = try edited()
		let coordinator = VaultPersistenceCoordinator(service: service)
		let edit = try #require(try entries(service).first)
		let target = HistoryEngine.RollbackTarget.undo(entry: edit.id, only: nil)
		let plan = try await coordinator.historyRollbackPlan(vaultId: vaultId, target: target).get().response
		_ = service.applyVaultTransaction(
			project: .update(vaultId: vaultId, environments: ["default": ["A": "9"]], source: VaultHistorySource(.set)), data: [])
		guard case .conflict(let latest, _) = await coordinator.mutateProject(
			projectId: vaultId, expectedName: "Project", expectedPath: "",
			mutation: .historyRollback(
				target: target, plan: plan, skipped: [], keepEmpty: [],
				source: VaultHistorySource(.undo, detail: .init(related: plan.point.related))))
		else {
			Issue.record("a stale review is a conflict, which hands the app the values that changed")
			return
		}
		#expect(latest.environments == ["default": ["A": "9"]])
		#expect(try service.getProjectResult(vaultId: vaultId).get()?.environments == ["default": ["A": "9"]])
	}

	@Test("a backup lists no project whose only newer data is its local history, which no backup carries")
	func backupsDontListHistoryAsNewerData() throws {
		let (service, _, _) = try edited()
		let inventory = try service.backupInventoryResult().get()
		#expect(inventory.projects.map(\.vaultId) == [vaultId])
		#expect(inventory.companion.withNewerData.isEmpty)
		#expect(inventory.companion.excluded.isEmpty)
		try service.setHistoryEnabledResult(vaultId: vaultId, enabled: false).get()
		#expect(try service.backupInventoryResult().get().companion.withNewerData.isEmpty, "history off is a setting, not data")
	}

	@Test("a change to more keys than a request may carry blobs is revealed and rolled back whole")
	func largeChangesRevealAndRollBack() throws {
		let (service, _, _) = makeService()
		let first = Dictionary(uniqueKeysWithValues: (0..<70).map { ("K\($0)", "one-\($0)") })
		guard case .success = service.createEnvironments(
			vaultId: vaultId, projectName: "Project", projectPath: "", environments: ["default": first], source: VaultHistorySource(.set))
		else { throw KeychainError.encodingFailed }
		var second = first
		second["K0"] = "two-0"
		guard case .success = service.applyVaultTransaction(
			project: .update(vaultId: vaultId, environments: ["default": second], source: VaultHistorySource(.editKey)), data: [])
		else { throw KeychainError.encodingFailed }
		let created = try #require(try entries(service).last)
		let revealed = try service.historyRevealResult(vaultId: vaultId, ids: [created.id]).get()
		#expect(revealed.response.first?.values?.first?.count == 70)

		let edit = try #require(try entries(service).first)
		let target = HistoryEngine.RollbackTarget.key("K0", environment: "default", entry: edit.id)
		let plan = try service.historyRollbackPlanResult(vaultId: vaultId, target: target).get().response
		let environments = try service.historyRolledBackEnvironmentsResult(
			vaultId: vaultId, target: target, fingerprint: plan.fingerprint, skipped: [], keepEmpty: []).get().environments
		#expect(environments == ["default": first])
	}

	@Test("a rollback reviewed while history was supported is refused once the marker says a newer version keeps it")
	func rollbackRefusedOnceHistoryIsUnsupported() throws {
		let (service, backend, name) = try edited()
		let edit = try #require(try entries(service).first)
		let target = HistoryEngine.RollbackTarget.undo(entry: edit.id, only: nil)
		let plan = try service.historyRollbackPlanResult(vaultId: vaultId, target: target).get().response
		let markerAccount = try CompanionEngine.markerAccount(vaultId: vaultId)
		let marker = try #require(try backend.read(service: name, account: markerAccount))
		var json = try #require(try JSONSerialization.jsonObject(with: marker) as? [String: Any])
		var features = try #require(json["features"] as? [String: Any])
		var history = try #require(features["history"] as? [String: Any])
		history["version"] = 2
		features["history"] = history
		json["features"] = features
		try backend.write(service: name, account: markerAccount, data: try JSONSerialization.data(withJSONObject: json))
		#expect(try service.historyStateResult(vaultId: vaultId).get().history == "unsupported")
		guard case .failure = service.historyRolledBackEnvironmentsResult(
			vaultId: vaultId, target: target, fingerprint: plan.fingerprint, skipped: [], keepEmpty: [])
		else {
			Issue.record("history this version doesn't support can't roll values back")
			return
		}
	}

	@Test("undoing an environment rename records a rename back, so the environment's history stays one line")
	func undoingARenameRecordsARename() async throws {
		let (service, _, _) = makeService()
		guard case .success = service.createEnvironments(
			vaultId: vaultId, projectName: "Project", projectPath: "", environments: ["production": ["A": "1"]],
			source: VaultHistorySource(.set))
		else { throw KeychainError.encodingFailed }
		guard case .success = service.applyVaultTransaction(
			project: .update(vaultId: vaultId, environments: ["live": ["A": "1"]],
				source: VaultHistorySource(.renameEnvironment, renames: [.environment(from: "production", to: "live")])),
			data: [])
		else { throw KeychainError.encodingFailed }
		let coordinator = VaultPersistenceCoordinator(service: service)
		let rename = try #require(try entries(service).first)
		let target = HistoryEngine.RollbackTarget.undo(entry: rename.id, only: nil)
		let plan = try await coordinator.historyRollbackPlan(vaultId: vaultId, target: target).get().response
		guard case .success = await coordinator.mutateProject(
			projectId: vaultId, expectedName: "Project", expectedPath: "",
			mutation: .historyRollback(
				target: target, plan: plan, skipped: [], keepEmpty: [],
				source: VaultHistorySource(.undo, detail: .init(related: plan.point.related))))
		else {
			Issue.record("the undo was refused")
			return
		}
		let undo = try #require(try entries(service).first)
		#expect(undo.action == "undo")
		#expect(undo.environments.map(\.name) == ["production"])
		#expect(undo.environments.first?.renamedFrom == "live")
		let timeline = try #require(try service.historyTimelineResult(vaultId: vaultId, filter: nil).get())
		#expect(timeline.environments.allSatisfy { $0.deletedAt == nil }, "\(timeline.environments)")
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
