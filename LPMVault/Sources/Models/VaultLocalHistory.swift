import Foundation
import Observation

/// One project's local history as the History page, the inspector and the
/// review sheets show it. Values come out of history only to be revealed or
/// reviewed, and leave memory when the selection changes or the app locks.
@MainActor
@Observable
final class VaultLocalHistory {
	/// What the model asks of the app's storage, so tests can give it a real
	/// coordinator or a stand-in.
	struct Actions {
		var state: @Sendable (String) async -> Result<VaultHistoryState, KeychainError>
		var timeline: @Sendable (String, HistoryEngine.Filter?) async -> Result<HistoryEngine.Timeline?, KeychainError>
		var reveal: @Sendable (String, [String]) async -> Result<HistoryEngine.Answer<[HistoryEngine.Entry]>, KeychainError>
		var planRollback: @Sendable (String, HistoryEngine.RollbackTarget) async -> Result<HistoryEngine.Answer<HistoryEngine.Plan>, KeychainError>
		var reviewRemoval: @Sendable (_ vaultId: String, _ entry: String, _ environment: String, _ key: String, _ side: String) async
			-> Result<HistoryEngine.Review, KeychainError>
		var remove: @Sendable (String, HistoryEngine.Review, [Int]) async -> Result<Void, KeychainError>
		var setEnabled: @Sendable (String, Bool) async -> Result<Void, KeychainError>
		var takeOutcomes: @Sendable () async -> [String: VaultHistoryOutcome]
		/// Applies a mutation through the store's mutation queue.
		var mutate: @MainActor (String, VaultProjectMutation) async -> ProjectMutationOutcome
		/// Asks for fresh authentication, every time.
		var confirm: @MainActor (String) async -> Bool

		static func coordinator(
			_ persistence: VaultPersistenceCoordinator,
			mutate: @escaping @MainActor (String, VaultProjectMutation) async -> ProjectMutationOutcome,
			confirm: @escaping @MainActor (String) async -> Bool
		) -> Actions {
			Actions(
				state: { await persistence.historyState(vaultId: $0) },
				timeline: { await persistence.historyTimeline(vaultId: $0, filter: $1) },
				reveal: { await persistence.historyReveal(vaultId: $0, ids: $1) },
				planRollback: { await persistence.historyRollbackPlan(vaultId: $0, target: $1) },
				reviewRemoval: { await persistence.historyRemovalReview(vaultId: $0, entry: $1, environment: $2, key: $3, side: $4) },
				remove: { await persistence.removeFromHistory(vaultId: $0, review: $1, selection: $2) },
				setEnabled: { await persistence.setHistoryEnabled(vaultId: $0, enabled: $1) },
				takeOutcomes: { await persistence.takeHistoryOutcomes() },
				mutate: mutate,
				confirm: confirm)
		}
	}

	enum Phase: Equatable {
		case idle
		case loading
		case loaded
		case failed(String)
	}

	/// The source chips, in the page's order, with the engine's group names.
	enum Source: String, CaseIterable, Identifiable {
		case app, cli, `import`, restore, pull, rollback, outside

		var id: String { rawValue }
	}

	struct Filter: Equatable {
		var environment: String?
		var keyContains = ""
		var source: Source?

		var engine: HistoryEngine.Filter? {
			let key = keyContains.trimmingCharacters(in: .whitespaces)
			guard environment != nil || !key.isEmpty || source != nil else { return nil }
			return HistoryEngine.Filter(environment: environment, keyContains: key.isEmpty ? nil : key, source: source?.rawValue)
		}
	}

	/// An entry's values, revealed: one list per environment, in its keys' order.
	struct Revealed: Equatable {
		struct Sides: Equatable {
			let before: String?
			let after: String?
		}

		let environments: [[Sides]]
	}

	/// A rollback being reviewed, with the values its rows show.
	struct RollbackReview: Identifiable {
		let id = UUID()
		let projectID: String
		let target: HistoryEngine.RollbackTarget
		let plan: HistoryEngine.Plan
		/// Each row's current and target values, by environment and row.
		let values: [[(current: String?, target: String?)]]
		/// Rows switched off: unknown rows start off and stay off.
		var skipped: Set<HistoryRollbackSkip>
		/// Environments the rollback would delete once empty, which stay.
		var keptEnvironments: Set<Int> = []

		/// How many keys the rollback changes with these switches.
		var changing: Int {
			plan.environments.enumerated().reduce(0) { total, item in
				total + item.element.rows.indices.filter { row in
					item.element.rows[row].changes && !skipped.contains(HistoryRollbackSkip(environment: item.offset, row: row))
				}.count
			}
		}
	}

	/// A removal being reviewed, with the places switched on.
	struct RemovalReview: Identifiable {
		let id = UUID()
		let projectID: String
		let review: HistoryEngine.Review
		/// The chosen key, as the subject card names it.
		let key: String
		let environment: String
		var selection: Set<Int>
	}

	private let actions: Actions
	private(set) var projectID: String?
	private(set) var phase: Phase = .idle
	private(set) var timeline: HistoryEngine.Timeline?
	private(set) var state: VaultHistoryState?
	var filter = Filter()
	private(set) var selectedEntryID: String?
	private(set) var revealed: [String: Revealed] = [:]
	/// Why the project's last change wasn't recorded, until the page shows it.
	private(set) var notRecorded: [String: String] = [:]
	var rollbackReview: RollbackReview?
	var removalReview: RemovalReview?
	/// Bumps whenever what the page shows changes hands, so an answer to an
	/// older request is dropped.
	private var generation = 0

	init(actions: Actions) {
		self.actions = actions
	}

	var entries: [HistoryEngine.Entry] {
		timeline?.rows.compactMap { row in
			if case .entry(let entry) = row { return entry }
			return nil
		} ?? []
	}

	var selectedEntry: HistoryEngine.Entry? {
		guard let selectedEntryID else { return nil }
		return entries.first { $0.id == selectedEntryID }
	}

	/// Shows `projectID`'s history, from the top.
	func open(_ projectID: String) async {
		if self.projectID != projectID {
			forgetValues()
			self.projectID = projectID
			filter = Filter()
			selectedEntryID = nil
			timeline = nil
			state = nil
		}
		await reload()
	}

	/// Reads the project's history again, with the current filter.
	func reload() async {
		guard let projectID else { return }
		generation += 1
		let generation = generation
		phase = .loading
		await collectOutcomes()
		let state = await actions.state(projectID)
		let timeline = await actions.timeline(projectID, filter.engine)
		guard generation == self.generation, projectID == self.projectID else { return }
		switch (state, timeline) {
		case (.success(let state), .success(let timeline)):
			self.state = state
			self.timeline = timeline
			if let selectedEntryID, !entries.contains(where: { $0.id == selectedEntryID }) { select(nil) }
			phase = .loaded
		case (.failure(let error), _), (_, .failure(let error)):
			phase = .failed(error.description)
		}
	}

	func select(_ entryID: String?) {
		guard entryID != selectedEntryID else { return }
		forgetValues()
		selectedEntryID = entryID
	}

	/// Reveals the selected entry's values, which stay until the selection
	/// changes, the window is covered, or the app locks.
	func reveal(_ entryID: String) async {
		guard let projectID, revealed[entryID] == nil else { return }
		let generation = generation
		guard case .success(let answer) = await actions.reveal(projectID, [entryID]),
			generation == self.generation, projectID == self.projectID, entryID == selectedEntryID,
			let entry = answer.response.first
		else { return }
		revealed[entryID] = Revealed(environments: (entry.values ?? []).map { sides in
			sides.map { Revealed.Sides(before: text(answer.blobs, $0.before), after: text(answer.blobs, $0.after)) }
		})
	}

	/// Hides every revealed value, as covering the window does.
	func hideRevealed() {
		revealed = [:]
	}

	/// Drops every revealed value and withdraws pending reviews.
	func forgetValues() {
		revealed = [:]
		rollbackReview = nil
		removalReview = nil
	}

	/// Clears everything, as locking does.
	func reset() {
		forgetValues()
		generation += 1
		projectID = nil
		phase = .idle
		timeline = nil
		state = nil
		selectedEntryID = nil
		filter = Filter()
	}

	// MARK: - Rollback

	/// Opens the review of rolling back to `target`.
	func reviewRollback(_ target: HistoryEngine.RollbackTarget) async -> KeychainError? {
		guard let projectID else { return nil }
		let generation = generation
		switch await actions.planRollback(projectID, target) {
		case .success(let answer):
			guard generation == self.generation, projectID == self.projectID else { return nil }
			let plan = answer.response
			let values = plan.environments.map { environment in
				environment.rows.map { row in (current: text(answer.blobs, row.current), target: text(answer.blobs, row.target)) }
			}
			var skipped = Set<HistoryRollbackSkip>()
			for (environmentIndex, environment) in plan.environments.enumerated() {
				for (rowIndex, row) in environment.rows.enumerated() where row.change == "unknown" {
					skipped.insert(HistoryRollbackSkip(environment: environmentIndex, row: rowIndex))
				}
			}
			rollbackReview = RollbackReview(projectID: projectID, target: target, plan: plan, values: values, skipped: skipped)
			return nil
		case .failure(let error):
			return error
		}
	}

	/// Applies the rollback under review, as switched.
	func applyRollback() async -> ProjectMutationOutcome {
		guard let review = rollbackReview else { return .unavailable }
		let keepEmpty = review.plan.environments.indices.filter { review.keptEnvironments.contains($0) }
		let outcome = await actions.mutate(
			review.projectID,
			.historyRollback(target: review.target, plan: review.plan, skipped: Array(review.skipped), keepEmpty: keepEmpty))
		if case .saved = outcome {
			rollbackReview = nil
			await reload()
		}
		return outcome
	}

	// MARK: - Removal

	func reviewRemoval(entry: String, environment: String, key: String, side: String) async -> KeychainError? {
		guard let projectID else { return nil }
		switch await actions.reviewRemoval(projectID, entry, environment, key, side) {
		case .success(let review):
			removalReview = RemovalReview(
				projectID: projectID, review: review, key: key, environment: environment,
				selection: Set(review.defaultSelection))
			return nil
		case .failure(let error):
			return error
		}
	}

	/// Removes the value from the places switched on, after fresh authentication.
	func remove() async -> KeychainError? {
		guard let review = removalReview, !review.selection.isEmpty else { return nil }
		guard await actions.confirm("remove a value from local history") else { return nil }
		switch await actions.remove(review.projectID, review.review, review.selection.sorted()) {
		case .success:
			removalReview = nil
			forgetValues()
			await reload()
			return nil
		case .failure(let error):
			return error
		}
	}

	// MARK: - On and off

	/// Turns the project's history off after fresh authentication, deleting
	/// it, or back on.
	func setEnabled(_ enabled: Bool, projectID: String) async -> KeychainError? {
		if !enabled, !(await actions.confirm("turn off local history and delete it")) { return nil }
		switch await actions.setEnabled(projectID, enabled) {
		case .success:
			if projectID == self.projectID {
				forgetValues()
				selectedEntryID = nil
				await reload()
			}
			return nil
		case .failure(let error):
			return error
		}
	}

	// MARK: - Outcomes

	/// Takes what history made of recent changes, keeping why a project's
	/// last change wasn't recorded.
	func collectOutcomes() async {
		for (vaultId, outcome) in await actions.takeOutcomes() {
			switch outcome {
			case .notRecorded(_, let message): notRecorded[vaultId] = message
			case .recorded, .nothing, .off: notRecorded[vaultId] = nil
			}
		}
	}

	func dismissNotRecorded(_ projectID: String) {
		notRecorded[projectID] = nil
	}

	private func text(_ blobs: HistoryEngine.Blobs, _ index: Int?) -> String? {
		index.flatMap { blobs[$0] }?.withUnsafeBytes { String(decoding: $0, as: UTF8.self) }
	}
}
