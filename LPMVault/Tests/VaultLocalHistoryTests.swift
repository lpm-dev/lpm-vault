import Foundation
import Testing

@testable import LPMVault

@MainActor
@Suite("Local history model")
struct VaultLocalHistoryTests {
	private let vaultId = "history-model"

	/// A real coordinator over an in-memory Keychain whose project went from
	/// A=1 to A=2, and a model on it that confirms when `confirms` says.
	private func fixture(confirms: Bool = true) throws -> (VaultLocalHistory, KeychainService) {
		let service = KeychainService(testingService: "dev.lpm.vault.history-model.\(UUID().uuidString)", backend: InMemoryKeychainBackend())
		guard case .success = service.createEnvironments(
			vaultId: vaultId, projectName: "Project", projectPath: "", environments: ["default": ["A": "1"]],
			source: VaultHistorySource(.set))
		else { throw KeychainError.encodingFailed }
		guard case .success = service.applyVaultTransaction(
			project: .update(vaultId: vaultId, environments: ["default": ["A": "2"]], source: VaultHistorySource(.editKey)), data: [])
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
		return (VaultLocalHistory(actions: actions), service)
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
		#expect(history.notRecorded["p"] == "This Mac holds too many LPM records.")
		outcomes.pending = ["p": .recorded(entry: nil, gap: false, crowded: nil)]
		await history.collectOutcomes()
		#expect(history.notRecorded["p"] == nil)
	}
}
