import Foundation
import Testing

@testable import LPMVault

@MainActor
@Suite("Local history model")
struct VaultLocalHistoryTests {
	private let vaultId = "history-model"

	/// A real coordinator over an in-memory Keychain whose project went from
	/// A=1 to `then`, A=2 unless a test says, and a model on it that confirms
	/// when `confirms` says.
	private func fixture(
		confirms: Bool = true,
		then: (environments: [String: [String: String]], source: VaultHistorySource) = (["default": ["A": "2"]], VaultHistorySource(.editKey)),
		undoTimer: VaultFeedbackTimer = .importUndo
	) throws -> (VaultLocalHistory, KeychainService) {
		let service = KeychainService(testingService: "dev.lpm.vault.history-model.\(UUID().uuidString)", backend: InMemoryKeychainBackend())
		guard case .success = service.createEnvironments(
			vaultId: vaultId, projectName: "Project", projectPath: "", environments: ["default": ["A": "1"]],
			source: VaultHistorySource(.set))
		else { throw KeychainError.encodingFailed }
		guard case .success = service.applyVaultTransaction(
			project: .update(vaultId: vaultId, environments: then.environments, source: then.source), data: [])
		else { throw KeychainError.encodingFailed }
		let coordinator = VaultPersistenceCoordinator(service: service)
		let actions = VaultLocalHistory.Actions.coordinator(
			coordinator,
			mutate: { projectID, mutation in
				switch await coordinator.mutateProject(projectId: projectID, expectedName: "Project", expectedPath: "", mutation: mutation) {
				case .success: .saved
				case .conflict: .changed
				case .targetUnavailable: .unavailable
				case .failure(let error): .failed(error.description)
				}
			},
			confirm: { _ in confirms })
		return (VaultLocalHistory(actions: actions, undoTimer: undoTimer), service)
	}

	@Test("opening a project reads its state and timeline, newest first")
	func openReadsTheTimeline() async throws {
		let (history, _) = try fixture()
		await history.open(vaultId)
		#expect(history.phase == .loaded)
		#expect(history.state?.history == "on")
		#expect(history.entries.map(\.action) == ["editKey", "set"])
	}

	@Test("a revealed entry's values go when the selection changes")
	func revealedValuesFollowTheSelection() async throws {
		let (history, _) = try fixture()
		await history.open(vaultId)
		let edit = try #require(history.entries.first)
		history.select(edit.id)
		await history.reveal(edit.id)
		#expect(history.revealed[edit.id]?.environments.first?.first == .init(before: "1", after: "2"))
		history.select(history.entries.last?.id)
		#expect(history.revealed.isEmpty)
	}

	@Test("an undo reviewed and applied puts the value back and records the undo")
	func undoIsReviewedThenApplied() async throws {
		let (history, service) = try fixture()
		await history.open(vaultId)
		let edit = try #require(history.entries.first)
		#expect(await history.reviewRollback(.undo(entry: edit.id, only: nil)) == nil)
		let review = try #require(history.rollbackReview)
		#expect(review.changing == 1)
		#expect(review.values.first?.first?.current == "2" && review.values.first?.first?.target == "1")
		#expect(await history.applyRollback() == .saved)
		#expect(history.rollbackReview == nil)
		#expect(try service.getProjectResult(vaultId: vaultId).get()?.environments == ["default": ["A": "1"]])
		#expect(history.entries.first?.action == "undo")
	}

	@Test("a renamed key's two rows switch together, and an unknown row can't be switched on")
	func linkedRowsSwitchTogether() async throws {
		let (history, _) = try fixture(then: (
			["default": ["B": "1"]],
			VaultHistorySource(.renameKey, renames: [.key(environment: "default", from: "A", to: "B")])))
		await history.open(vaultId)
		let created = try #require(history.entries.last)
		#expect(await history.reviewRollback(.environment("default", entry: created.id, side: "after")) == nil)
		var review = try #require(history.rollbackReview)
		let rows = try #require(review.plan.environments.first?.rows)
		#expect(Set(rows.map(\.key)) == ["A", "B"] && rows.allSatisfy { $0.linked.count == 1 })
		#expect(review.changing == 2 && review.changesAnything)
		review.setApplies(false, environment: 0, row: 0)
		#expect(!review.applies(environment: 0, row: 0) && !review.applies(environment: 0, row: 1))
		#expect(review.changing == 0 && !review.changesAnything)
		review.setApplies(true, environment: 0, row: 1)
		#expect(review.changing == 2)
	}

	@Test("a rollback offers its undo, which puts the values back at once, until the undo window ends")
	func appliedRollbackCanBeUndone() async throws {
		let window = ManualFeedbackTimer()
		let (history, service) = try fixture(undoTimer: window.timer)
		await history.open(vaultId)
		let edit = try #require(history.entries.first)
		#expect(await history.reviewRollback(.undo(entry: edit.id, only: nil)) == nil)
		#expect(await history.applyRollback() == .saved)
		let applied = try #require(history.applied)
		#expect(applied.isUndo && applied.keys == 1 && applied.undo == .available)
		#expect(history.entries.first?.id == applied.entry, "the toast undoes the entry the rollback recorded")

		await history.undoApplied()
		#expect(history.applied?.undo == .undone)
		#expect(history.rollbackReview == nil, "an exact undo needs no review")
		#expect(try service.getProjectResult(vaultId: vaultId).get()?.environments == ["default": ["A": "2"]])
		#expect(history.entries.first?.related?.id == applied.entry)

		_ = try await waitUntil { window.started == 1 }
		window.expire()
		_ = try await waitUntil { history.applied == nil }
	}

	@Test("undoing a rollback after the values changed again opens its review instead")
	func undoAfterAnotherChangeIsReviewed() async throws {
		let (history, service) = try fixture(undoTimer: ManualFeedbackTimer().timer)
		await history.open(vaultId)
		let edit = try #require(history.entries.first)
		#expect(await history.reviewRollback(.undo(entry: edit.id, only: nil)) == nil)
		#expect(await history.applyRollback() == .saved)
		guard case .success = service.applyVaultTransaction(
			project: .update(vaultId: vaultId, environments: ["default": ["A": "3"]], source: VaultHistorySource(.set)), data: [])
		else { throw KeychainError.encodingFailed }
		await history.undoApplied()
		#expect(history.applied?.undo == .reviewing)
		let review = try #require(history.rollbackReview)
		#expect(review.plan.kind == "undo" && review.plan.environments.first?.rows.first?.changedAgain != nil)
		#expect(try service.getProjectResult(vaultId: vaultId).get()?.environments == ["default": ["A": "3"]])
	}

	@Test("a rollback reviewed before the values changed is refused as changed, and its review stays to be made again")
	func staleRollbackIsChanged() async throws {
		let (history, service) = try fixture()
		await history.open(vaultId)
		let edit = try #require(history.entries.first)
		#expect(await history.reviewRollback(.undo(entry: edit.id, only: nil)) == nil)
		let id = try #require(history.rollbackReview?.id)
		guard case .success = service.applyVaultTransaction(
			project: .update(vaultId: vaultId, environments: ["default": ["A": "3"]], source: VaultHistorySource(.set)), data: [])
		else { throw KeychainError.encodingFailed }
		#expect(await history.applyRollback() == .changed)
		#expect(try service.getProjectResult(vaultId: vaultId).get()?.environments == ["default": ["A": "3"]])
		#expect(await history.reviewRollback(.undo(entry: edit.id, only: nil)) == nil)
		#expect(history.rollbackReview?.id == id, "made again, it keeps its sheet")
		#expect(history.rollbackReview?.plan.environments.first?.rows.first?.changedAgain != nil)
	}

	@Test("locking ends the offer to undo a rollback")
	func lockingEndsTheUndoOffer() async throws {
		let (history, _) = try fixture(undoTimer: ManualFeedbackTimer().timer)
		await history.open(vaultId)
		let edit = try #require(history.entries.first)
		#expect(await history.reviewRollback(.undo(entry: edit.id, only: nil)) == nil)
		#expect(await history.applyRollback() == .saved)
		#expect(history.applied != nil)
		history.reset()
		#expect(history.applied == nil && history.rollbackReview == nil)
	}

	@Test("removing a value asks for authentication and does nothing without it")
	func removalNeedsAuthentication() async throws {
		let (refused, _) = try fixture(confirms: false)
		await refused.open(vaultId)
		let edit = try #require(refused.entries.first)
		#expect(await refused.reviewRemoval(entry: edit.id, environment: "default", key: "A", side: "before") == nil)
		#expect(await refused.remove() == nil)
		#expect(refused.removalReview != nil, "nothing was removed, so the review stays")

		let (history, _) = try fixture()
		await history.open(vaultId)
		let entry = try #require(history.entries.first)
		#expect(await history.reviewRemoval(entry: entry.id, environment: "default", key: "A", side: "before") == nil)
		#expect(await history.remove() == nil)
		#expect(history.removalReview == nil)
		history.select(entry.id)
		await history.reveal(entry.id)
		#expect(history.revealed[entry.id]?.environments.first?.first?.before == nil)
	}

	@Test("turning history off asks for authentication and deletes it")
	func turningOffDeletesHistory() async throws {
		let (history, _) = try fixture()
		await history.open(vaultId)
		#expect(await history.setEnabled(false, projectID: vaultId) == nil)
		#expect(history.state?.history == "off")
		#expect(history.timeline == nil)
	}

	@Test("a project's summary counts every change, whatever the page is filtered to, and lists no rows")
	func summaryIgnoresThePageFilter() async throws {
		let (history, _) = try fixture()
		await history.open(vaultId)
		history.filter.source = .cli
		history.filter.keyContains = "NOTHING"
		await history.reload()
		#expect(history.entries.isEmpty)
		let summary = try await history.summary(of: vaultId).get()
		#expect(summary.state.history == "on")
		#expect(summary.timeline?.readable == 2 && summary.timeline?.rows.isEmpty == true && summary.timeline?.oldest != nil)
		#expect(await history.setEnabled(false, projectID: vaultId) == nil)
		#expect(try await history.summary(of: vaultId).get() == .init(state: .init(history: "off", damage: []), timeline: nil))
	}

	@Test("a change history didn't record leaves its reason for the project until a later one records")
	func notRecordedOutcomesAreKept() async {
		final class Outcomes: @unchecked Sendable {
			var pending: [String: VaultHistoryOutcome] = [:]
		}
		let outcomes = Outcomes()
		var actions = VaultLocalHistory.Actions.coordinator(
			VaultPersistenceCoordinator(service: MockKeychainService()),
			mutate: { _, _ in .unavailable }, confirm: { _ in false })
		actions.takeOutcomes = {
			defer { outcomes.pending = [:] }
			return outcomes.pending
		}
		let history = VaultLocalHistory(actions: actions)
		outcomes.pending = ["p": .notRecorded(reason: "limit", message: "This Mac holds too many LPM records.")]
		await history.collectOutcomes()
		#expect(history.notRecorded["p"] == .init(reason: "limit", message: "This Mac holds too many LPM records."))
		outcomes.pending = ["p": .recorded(entry: nil, gap: false, crowded: nil)]
		await history.collectOutcomes()
		#expect(history.notRecorded["p"] == nil)
		#expect(history.crowded == nil)

		outcomes.pending = ["p": .recorded(entry: nil, gap: false, crowded: 4_200)]
		await history.collectOutcomes()
		#expect(history.crowded == 4_200, "a ring that started smaller says the Mac is crowded")
		history.noteCrowded(nil)
		#expect(history.crowded == nil, "until the pass after unlock finds it isn't")
	}
}
