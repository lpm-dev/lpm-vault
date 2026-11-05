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
		/// One key, by its name now, followed back through its renames.
		var exactKey: String?
		var keyContains = ""
		var source: Source?

		var engine: HistoryEngine.Filter? {
			let key = keyContains.trimmingCharacters(in: .whitespaces)
			guard environment != nil || exactKey != nil || !key.isEmpty || source != nil else { return nil }
			return HistoryEngine.Filter(
				environment: environment, exactKey: exactKey, keyContains: key.isEmpty ? nil : key, source: source?.rawValue)
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
		/// Kept when the review is made again, as for another environment,
		/// so its sheet stays open.
		let id: UUID
		let projectID: String
		let target: HistoryEngine.RollbackTarget
		let plan: HistoryEngine.Plan
		/// The entry the plan's point is at, when it's known.
		let pointEntry: HistoryEngine.Entry?
		/// Each row's current and target values, by environment and row.
		let values: [[(current: String?, target: String?)]]
		/// Rows switched off: unknown rows start off and stay off.
		private(set) var skipped: Set<HistoryRollbackSkip>
		/// Environments the rollback would delete once empty, which stay.
		var keptEnvironments: Set<Int> = []

		init(
			id: UUID = UUID(), projectID: String, target: HistoryEngine.RollbackTarget, plan: HistoryEngine.Plan,
			pointEntry: HistoryEngine.Entry? = nil, values: [[(current: String?, target: String?)]]
		) {
			self.id = id
			self.projectID = projectID
			self.target = target
			self.plan = plan
			self.pointEntry = pointEntry
			self.values = values
			var skipped = Set<HistoryRollbackSkip>()
			for (environmentIndex, environment) in plan.environments.enumerated() {
				for (rowIndex, row) in environment.rows.enumerated() where row.change == "unknown" {
					skipped.insert(HistoryRollbackSkip(environment: environmentIndex, row: rowIndex))
				}
			}
			self.skipped = skipped
		}

		func applies(environment: Int, row: Int) -> Bool {
			!skipped.contains(HistoryRollbackSkip(environment: environment, row: row))
		}

		/// Switches a row on or off, with the other rows of a key renamed
		/// since, which apply together. An unknown row stays off.
		mutating func setApplies(_ applies: Bool, environment: Int, row: Int) {
			let rows = plan.environments[environment].rows
			guard rows[row].change != "unknown" else { return }
			let linked = Set(rows[row].linked)
			for (index, other) in rows.enumerated() where index == row || linked.contains(other.key) {
				let skip = HistoryRollbackSkip(environment: environment, row: index)
				if applies { skipped.remove(skip) } else { skipped.insert(skip) }
			}
		}

		/// How many keys the rollback changes with these switches.
		var changing: Int {
			plan.environments.enumerated().reduce(0) { total, item in
				total + item.element.rows.indices.filter { row in
					item.element.rows[row].changes && applies(environment: item.offset, row: row)
				}.count
			}
		}

		/// Whether applying deletes the environment: it didn't exist at the
		/// point, every key it has leaves, and it isn't kept.
		func deletesEnvironment(_ index: Int) -> Bool {
			let environment = plan.environments[index]
			return environment.offersDeletion && !keptEnvironments.contains(index)
				&& environment.rows.indices.allSatisfy { applies(environment: index, row: $0) }
		}

		/// Whether applying with these switches changes anything, as the
		/// engine decides: a key, or an environment's name or existence.
		var changesAnything: Bool {
			changing > 0 || plan.environments.indices.contains { index in
				let environment = plan.environments[index]
				return environment.recreates || environment.renames || deletesEnvironment(index)
			}
		}

		/// What applying with these switches does to publish destinations.
		var follow: HistoryRollbackFollow {
			HistoryRollbackFollow(plan: plan, skipped: skipped, keepEmpty: keptEnvironments)
		}
	}

	/// A removal being reviewed, with the places switched on.
	struct RemovalReview: Identifiable {
		let id: UUID
		let projectID: String
		let review: HistoryEngine.Review
		/// The chosen value: a side of a key in an environment of an entry.
		let entry: String
		let key: String
		let environment: String
		let side: String
		var selection: Set<Int>
	}

	/// A rollback just applied, which can be undone for a short while.
	struct AppliedRollback: Equatable {
		enum Undo: Equatable {
			case available
			case undoing
			case undone
			/// It opened a review instead, since the values changed or
			/// something can't be put back exactly.
			case reviewing
			case failed(String)
		}

		/// The rollback's own entry.
		let entry: String
		let projectID: String
		let isUndo: Bool
		let keys: Int
		let savedAt: Date
		var undo: Undo = .available
	}

	private let actions: Actions
	private(set) var projectID: String?
	private(set) var phase: Phase = .idle
	private(set) var timeline: HistoryEngine.Timeline?
	private(set) var state: VaultHistoryState?
	var filter = Filter()
	private(set) var selectedEntryID: String?
	private(set) var revealed: [String: Revealed] = [:]
	/// Why a change wasn't recorded: the outcome's stable reason and its message.
	struct NotRecorded: Equatable {
		let reason: String
		let message: String
	}

	/// A project's history in brief, as its settings show it.
	struct Summary: Equatable {
		let state: VaultHistoryState
		/// Counts and the oldest change, without rows; nil while history is off.
		let timeline: HistoryEngine.Timeline?
	}

	/// Why each project's last change wasn't recorded, until a later one is.
	private(set) var notRecorded: [String: NotRecorded] = [:]
	var rollbackReview: RollbackReview?
	var removalReview: RemovalReview?
	private(set) var applied: AppliedRollback?
	/// Changes whenever something asks to show the History page, filtered
	/// as `show` says; the workspace follows it.
	private(set) var showRequest: UUID?
	private var pendingShow: (projectID: String, filter: Filter)?
	/// Bumps whenever what the page shows changes hands, so an answer to an
	/// older request is dropped.
	private var generation = 0
	/// Bumps when the app locks, so a review asked for before isn't opened after.
	private var session = 0
	private let undoTimer: VaultFeedbackTimer
	private let now: () -> Date
	private var appliedExpiry: Task<Void, Never>?

	init(actions: Actions, undoTimer: VaultFeedbackTimer = .importUndo, now: @escaping () -> Date = Date.init) {
		self.actions = actions
		self.undoTimer = undoTimer
		self.now = now
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

	/// Shows `projectID`'s history, from the top, filtered as a pending
	/// `show` asked.
	func open(_ projectID: String) async {
		if self.projectID != projectID {
			forgetValues()
			self.projectID = projectID
			filter = Filter()
			selectedEntryID = nil
			timeline = nil
			state = nil
		}
		if let pending = pendingShow, pending.projectID == projectID {
			pendingShow = nil
			filter = pending.filter
			select(nil)
		}
		await reload()
	}

	/// Asks for the History page of `projectID`, filtered to an environment
	/// or a key.
	func show(_ projectID: String, environment: String? = nil, key: String? = nil) {
		pendingShow = (projectID, Filter(environment: environment, exactKey: key))
		showRequest = UUID()
		if projectID == self.projectID {
			Task { await open(projectID) }
		}
	}

	/// The newest changes to `key` in `projectID`, through its renames, at
	/// most `limit` of them, whatever the page shows.
	func changes(to key: String, in projectID: String, limit: Int) async -> Result<[HistoryEngine.Entry], KeychainError> {
		await actions.timeline(projectID, HistoryEngine.Filter(exactKey: key, limit: limit)).map { timeline in
			timeline?.rows.compactMap { row in
				if case .entry(let entry) = row { return entry }
				return nil
			} ?? []
		}
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
		dismissApplied()
		pendingShow = nil
		session += 1
		generation += 1
		projectID = nil
		phase = .idle
		timeline = nil
		state = nil
		selectedEntryID = nil
		filter = Filter()
	}

	// MARK: - Rollback

	/// Opens the review of rolling back to `target`, in the page's project
	/// unless `projectID` names another. `entry` is the entry the target
	/// points at, when the caller has it.
	func reviewRollback(
		_ target: HistoryEngine.RollbackTarget, in projectID: String? = nil, entry: HistoryEngine.Entry? = nil
	) async -> KeychainError? {
		guard let projectID = projectID ?? self.projectID else { return nil }
		let session = session
		switch await actions.planRollback(projectID, target) {
		case .success(let answer):
			guard session == self.session else { return nil }
			let plan = answer.response
			rollbackReview = RollbackReview(
				id: rollbackReview?.id ?? UUID(), projectID: projectID, target: target, plan: plan,
				pointEntry: entry ?? entries.first { $0.id == plan.point.entry }, values: Self.values(of: answer))
			return nil
		case .failure(let error):
			return error
		}
	}

	/// Applies the rollback under review, as switched, and offers to undo it.
	func applyRollback() async -> ProjectMutationOutcome {
		guard let review = rollbackReview else { return .unavailable }
		let source = Self.source(of: review.plan)
		let outcome = await actions.mutate(
			review.projectID,
			.historyRollback(
				target: review.target, plan: review.plan, skipped: Array(review.skipped), keepEmpty: review.keptEnvironments.sorted(),
				source: source))
		if case .saved = outcome {
			rollbackReview = nil
			offerUndo(AppliedRollback(
				entry: source.id, projectID: review.projectID, isUndo: review.plan.kind == "undo", keys: review.changing, savedAt: now()))
			await reload()
		}
		return outcome
	}

	/// Undoes the rollback just applied: at once when its undo puts back
	/// exactly what it replaced, else through a review.
	func undoApplied() async {
		guard var applied, applied.undo == .available else { return }
		applied.undo = .undoing
		self.applied = applied
		let target = HistoryEngine.RollbackTarget.undo(entry: applied.entry, only: nil)
		let answer: HistoryEngine.Answer<HistoryEngine.Plan>
		switch await actions.planRollback(applied.projectID, target) {
		case .success(let planned): answer = planned
		case .failure(let error):
			settleUndo(of: applied.entry, .failed(error.description))
			return
		}
		guard self.applied?.entry == applied.entry else { return }
		let plan = answer.response
		guard Self.putsBackExactly(plan) else {
			rollbackReview = RollbackReview(
				projectID: applied.projectID, target: target, plan: plan,
				pointEntry: entries.first { $0.id == plan.point.entry }, values: Self.values(of: answer))
			settleUndo(of: applied.entry, .reviewing)
			return
		}
		let outcome = await actions.mutate(
			applied.projectID,
			.historyRollback(target: target, plan: plan, skipped: [], keepEmpty: [], source: Self.source(of: plan)))
		switch outcome {
		case .saved:
			settleUndo(of: applied.entry, .undone)
			await reload()
		case .changed:
			settleUndo(of: applied.entry, .failed("The values changed since, so nothing was undone."))
		case .unavailable:
			settleUndo(of: applied.entry, .failed("The project isn't available, so nothing was undone."))
		case .failed(let message):
			settleUndo(of: applied.entry, .failed(message))
		}
	}

	func dismissApplied() {
		appliedExpiry?.cancel()
		appliedExpiry = nil
		applied = nil
	}

	private func offerUndo(_ rollback: AppliedRollback) {
		appliedExpiry?.cancel()
		applied = rollback
		let timer = undoTimer
		appliedExpiry = Task { [weak self] in
			do { try await timer.wait() } catch { return }
			guard let self, self.applied?.entry == rollback.entry else { return }
			self.applied = nil
		}
	}

	private func settleUndo(of entry: String, _ undo: AppliedRollback.Undo) {
		guard applied?.entry == entry else { return }
		applied?.undo = undo
	}

	/// Whether an undo, applied without a review, puts back exactly what the
	/// change replaced: every key known, and nothing changed since.
	private static func putsBackExactly(_ plan: HistoryEngine.Plan) -> Bool {
		plan.environments.allSatisfy { environment in
			environment.unnamedKeys == nil
				&& environment.rows.allSatisfy { $0.change != "unknown" && $0.gaps.isEmpty && $0.changedAgain == nil }
		}
	}

	private static func source(of plan: HistoryEngine.Plan) -> VaultHistorySource {
		VaultHistorySource(plan.kind == "undo" ? .undo : .rollback, detail: .init(related: plan.point.related))
	}

	private static func values(of answer: HistoryEngine.Answer<HistoryEngine.Plan>) -> [[(current: String?, target: String?)]] {
		answer.response.environments.map { environment in
			environment.rows.map { row in (current: text(answer.blobs, row.current), target: text(answer.blobs, row.target)) }
		}
	}

	// MARK: - Removal

	func reviewRemoval(entry: String, environment: String, key: String, side: String) async -> KeychainError? {
		guard let projectID else { return nil }
		switch await actions.reviewRemoval(projectID, entry, environment, key, side) {
		case .success(let review):
			removalReview = RemovalReview(
				id: removalReview?.id ?? UUID(), projectID: projectID, review: review, entry: entry, key: key,
				environment: environment, side: side, selection: Set(review.defaultSelection))
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
			case .notRecorded(let reason, let message): notRecorded[vaultId] = NotRecorded(reason: reason, message: message)
			case .recorded, .nothing, .off: notRecorded[vaultId] = nil
			}
		}
	}

	func dismissNotRecorded(_ projectID: String) {
		notRecorded[projectID] = nil
	}

	/// The project's history state and its unfiltered counts, whatever the
	/// History page is filtered to.
	func summary(of projectID: String) async -> Result<Summary, KeychainError> {
		await collectOutcomes()
		let state: VaultHistoryState
		switch await actions.state(projectID) {
		case .success(let read): state = read
		case .failure(let error): return .failure(error)
		}
		guard state.history != "off" else { return .success(Summary(state: state, timeline: nil)) }
		return await actions.timeline(projectID, HistoryEngine.Filter(limit: 0)).map { Summary(state: state, timeline: $0) }
	}

	/// A side of an entry's change, once the entry is revealed.
	func revealedValue(entry: String, environment: String, key: String, side: String) -> String? {
		guard let revealed = revealed[entry], let changed = entries.first(where: { $0.id == entry }),
			let environmentIndex = changed.environments.firstIndex(where: { $0.name == environment }),
			let keyIndex = changed.environments[environmentIndex].keys?.firstIndex(where: { $0.key == key }),
			revealed.environments.indices.contains(environmentIndex),
			revealed.environments[environmentIndex].indices.contains(keyIndex)
		else { return nil }
		let sides = revealed.environments[environmentIndex][keyIndex]
		return side == "before" ? sides.before : sides.after
	}

	private static func text(_ blobs: HistoryEngine.Blobs, _ index: Int?) -> String? {
		index.flatMap { blobs[$0] }?.withUnsafeBytes { String(decoding: $0, as: UTF8.self) }
	}

	private func text(_ blobs: HistoryEngine.Blobs, _ index: Int?) -> String? {
		Self.text(blobs, index)
	}
}
