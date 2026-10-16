import AppKit
import Observation

/// Decides whether LPM Vault can quit, however quitting was asked for: ⌘Q,
/// the menu, the Dock, an update's restart, logging out, restarting or
/// shutting down. It first lets running writes finish. Unsaved edits then
/// get a sheet that saves them, discards them, or keeps the app open.
///
/// AppKit, while it waits for a later answer to quitting, quits at once on
/// any other request to quit, so a decision the app starts doesn't keep it
/// waiting: the request is cancelled, and quitting is asked for again once
/// it's decided. Only the end of the session, which waits for every app,
/// gets a later answer.
@Observable
@MainActor
final class VaultQuitCoordinator {
	enum Phase: Equatable {
		case idle
		/// Writes that were running when quitting began are finishing.
		case finishing
		case reviewing
		case saving
		case failed
	}

	enum ItemState: Equatable {
		case waiting
		case saving
		case saved
		case failed(String)
		/// Edits that can't be saved here, with why.
		case needsReview(String)
	}

	struct Item: Identifiable, Equatable {
		enum Kind: Equatable {
			/// Key drafts this sheet can save.
			case keys([VaultUnsavedWork.KeyEdit])
			/// Key drafts that need a review in the inspector first.
			case review([VaultUnsavedWork.KeyEdit])
			/// The project's schema draft, with how many rules it changes.
			case schema(changes: Int)
			/// The project's unsaved Project Settings.
			case settings(newName: String?, changesIcon: Bool)
			/// A sheet still open, with what it does and what's typed into it.
			case sheet(title: String, detail: String)
		}

		let id: String
		let projectID: String
		let projectName: String
		var kind: Kind
		var state: ItemState

		/// The unsaved edits it holds; a schema draft or a sheet counts none.
		var editCount: Int {
			switch kind {
			case .keys(let keys), .review(let keys): keys.reduce(0) { $0 + $1.edits }
			case .schema, .settings, .sheet: 0
			}
		}

		var isFailed: Bool {
			if case .failed = state { true } else { false }
		}

		var needsReview: Bool {
			if case .needsReview = state { true } else { false }
		}

		/// Whether this sheet can save it, unlike edits that need a review or an open sheet's.
		var isSaveable: Bool {
			switch kind {
			case .keys, .schema, .settings: true
			case .review, .sheet: false
			}
		}
	}

	struct Timing: Sendable {
		/// How long writes run before the sheet says they're being finished.
		var finishingDelay: Duration = .milliseconds(150)
		/// How long writes run before the sheet offers to quit without them.
		var overdueAfter: Duration = .seconds(10)
	}

	/// Shows and hides the sheet, which is attached to the app's window.
	@MainActor
	protocol Presenter: AnyObject {
		/// Shows the sheet, bringing the app's window forward; false when there's no window.
		func present(_ coordinator: VaultQuitCoordinator) -> Bool
		func dismiss()
	}

	private(set) var phase: Phase = .idle
	private(set) var items: [Item] = []
	/// Whether quitting is being decided, which the shortcut and the Quit command wait out.
	private(set) var isQuitting = false
	/// Whether writes have run long enough that quitting without them is offered.
	private(set) var isFinishingOverdue = false

	@ObservationIgnored private weak var store: VaultStore?
	@ObservationIgnored private let presenter: any Presenter
	@ObservationIgnored private let timing: Timing
	/// Answers a request to quit that AppKit is waiting on.
	@ObservationIgnored private let reply: (Bool) -> Void
	/// Asks AppKit to quit again once quitting is decided.
	@ObservationIgnored private let terminate: () -> Void
	/// Each decision's own number, so work left from an earlier one changes nothing.
	@ObservationIgnored private var run = 0
	@ObservationIgnored private var work: Task<Void, Never>?
	@ObservationIgnored private var lockWatch: Task<Void, Never>?
	@ObservationIgnored private var isPresented = false
	/// Whether AppKit is waiting on a later answer, as the end of a session does.
	@ObservationIgnored private var awaitsReply = false
	@ObservationIgnored private var isApproved = false

	init(
		store: VaultStore?,
		presenter: any Presenter,
		timing: Timing = Timing(),
		reply: @escaping (Bool) -> Void = { NSApp.reply(toApplicationShouldTerminate: $0) },
		terminate: @escaping () -> Void
	) {
		self.store = store
		self.presenter = presenter
		self.timing = timing
		self.reply = reply
		self.terminate = terminate
	}

	func attach(_ store: VaultStore) {
		self.store = store
	}

	/// The answer to `applicationShouldTerminate`. `sessionEnding` is a logout,
	/// restart or shutdown, which waits for a later answer.
	func shouldTerminate(sessionEnding: Bool) -> NSApplication.TerminateReply {
		if isApproved { return .terminateNow }
		guard let store else { return .terminateNow }
		if isQuitting {
			guard sessionEnding, !awaitsReply else { return .terminateCancel }
			awaitsReply = true
			return .terminateLater
		}
		guard store.hasWorkQuittingWouldLose else { return .terminateNow }
		begin(store)
		awaitsReply = sessionEnding
		return sessionEnding ? .terminateLater : .terminateCancel
	}

	private func begin(_ store: VaultStore) {
		run += 1
		let run = run
		isQuitting = true
		lockWatch = Task { [weak self, weak store] in
			let locked = await ObservedWait.value { (store?.isUnlocked ?? false) ? nil : true }
			guard locked == true else { return }
			self?.vaultLocked(run)
		}
		work = Task { [weak self] in await self?.prepare(run) }
	}

	/// Lets running writes finish, saying so once they take a moment, and
	/// offering to quit without them once they take too long.
	private func prepare(_ run: Int) async {
		guard let store else { return finish(quitting: true) }
		let shown = Task { [weak self, finishingDelay = timing.finishingDelay] in
			try? await Task.sleep(for: finishingDelay)
			guard let self, !Task.isCancelled, self.run == run, phase == .idle else { return }
			phase = .finishing
			show()
		}
		defer { shown.cancel() }
		if await !store.finishWritesInProgress(within: timing.overdueAfter) {
			guard self.run == run else { return }
			isFinishingOverdue = true
			if phase == .idle {
				phase = .finishing
				show()
			}
			while await !store.finishWritesInProgress(within: .seconds(60)) {
				guard self.run == run else { return }
			}
		}
		guard self.run == run else { return }
		isFinishingOverdue = false
		review(store)
	}

	private func review(_ store: VaultStore) {
		let work = store.unsavedWork()
		guard !work.isEmpty else { return finish(quitting: true) }
		items = Self.items(for: work)
		phase = .reviewing
		// Without a window to ask in, the edits stay and the app stays open.
		guard show() else { return finish(quitting: false) }
	}

	@discardableResult
	private func show() -> Bool {
		if !isPresented { isPresented = presenter.present(self) }
		return isPresented
	}

	/// Locking discards unsaved edits, so nothing is left to ask about, and the
	/// list, which would show them over the locked app, goes. Writes still finish first.
	private func vaultLocked(_ run: Int) {
		guard self.run == run, isQuitting else { return }
		work?.cancel()
		if isPresented {
			presenter.dismiss()
			isPresented = false
		}
		items = []
		phase = .idle
		isFinishingOverdue = false
		self.run += 1
		let next = self.run
		work = Task { [weak self] in await self?.prepare(next) }
	}

	/// Saves every edit that can be saved, a project at a time, and quits
	/// once nothing that was asked to be saved failed.
	func saveAndQuit() {
		guard phase == .reviewing || phase == .failed, store != nil else { return }
		phase = .saving
		let run = run
		work = Task { [weak self] in await self?.save(run) }
	}

	/// Quits without saving what's left; edits already saved stay saved.
	func discardAndQuit() {
		guard phase == .reviewing || phase == .failed || (phase == .finishing && isFinishingOverdue) else { return }
		finish(quitting: true)
	}

	/// Keeps the app open with the unsaved edits as they are. A key being
	/// written finishes; no other starts.
	func cancel() {
		guard isQuitting else { return }
		finish(quitting: false)
	}

	var savedCount: Int { items.filter { $0.state == .saved }.count }

	var failedItems: [Item] { items.filter(\.isFailed) }

	/// The rows whose edits quitting discards because they can't be saved here.
	var needsReviewCount: Int { items.filter(\.needsReview).count }

	private func save(_ run: Int) async {
		guard let store else { return }
		var opened: String?
		var changedWhileSaving = false
		var index = 0
		while index < items.count {
			guard self.run == run, phase == .saving else { return }
			let item = items[index]
			guard item.state == .waiting || item.isFailed, item.isSaveable else {
				index += 1
				continue
			}
			items[index].state = .saving
			if opened != item.projectID {
				guard store.isUnlocked else {
					items[index].state = .failed("LPM Vault locked before this could be saved.")
					index += 1
					continue
				}
				let loaded = await store.openProjectForSaving(item.projectID)
				guard self.run == run, phase == .saving else { return }
				guard loaded else {
					items[index].state = .failed("\(item.projectName) couldn't be loaded to save it.")
					index += 1
					continue
				}
				opened = item.projectID
			}
			if case .keys(let keys) = item.kind {
				guard let outcome = await saveKeys(keys, run: run, in: store) else { return }
				if !outcome.review.isEmpty { changedWhileSaving = true }
				index += replace(at: index, with: outcome)
			} else {
				let state = if case .settings = item.kind { await saveSettings(item, in: store) } else { await saveSchema(item, in: store) }
				guard self.run == run, phase == .saving else { return }
				items[index].state = state
				index += 1
			}
		}
		guard self.run == run, phase == .saving else { return }
		// Edits that changed elsewhere while saving weren't listed as needing a
		// review when the person chose to save, so quitting waits for them too.
		if items.contains(where: \.isFailed) || changedWhileSaving {
			phase = .failed
		} else {
			finish(quitting: true)
		}
	}

	private struct KeysOutcome {
		var saved: [VaultUnsavedWork.KeyEdit] = []
		var failed: [(edit: VaultUnsavedWork.KeyEdit, reason: String)] = []
		var review: [VaultUnsavedWork.KeyEdit] = []
	}

	/// Saves each key on its own, so one that fails leaves the others to be
	/// tried; nil when the decision ended while saving.
	private func saveKeys(_ keys: [VaultUnsavedWork.KeyEdit], run: Int, in store: VaultStore) async -> KeysOutcome? {
		var outcome = KeysOutcome()
		for edit in keys {
			guard self.run == run, phase == .saving else { return nil }
			guard let draft = store.keyDrafts.draft(edit.id), draft.isDirty || draft.hasConflict else {
				outcome.saved.append(edit)
				continue
			}
			guard draft.canSave else {
				outcome.review.append(edit)
				continue
			}
			do {
				try await store.saveKeyDraft(edit.id)
			} catch {
				outcome.failed.append((edit, error.localizedDescription))
				continue
			}
			// A save that couldn't start leaves the draft as it was.
			if let left = store.keyDrafts.draft(edit.id), left.isDirty || left.hasConflict {
				if left.canSave {
					outcome.failed.append((edit, "it changed while it was being saved"))
				} else {
					outcome.review.append(edit)
				}
			} else {
				outcome.saved.append(edit)
			}
		}
		guard self.run == run, phase == .saving else { return nil }
		return outcome
	}

	/// Replaces a project's keys row with rows for how its saves went, and
	/// moves keys that now need a review to the project's review row. Returns
	/// how many rows the next one to save is past it.
	private func replace(at index: Int, with outcome: KeysOutcome) -> Int {
		let item = items[index]
		var rows: [Item] = []
		if !outcome.saved.isEmpty {
			rows.append(Item(id: item.id, projectID: item.projectID, projectName: item.projectName, kind: .keys(outcome.saved), state: .saved))
		}
		if !outcome.failed.isEmpty {
			rows.append(Item(id: item.id + ":failed", projectID: item.projectID, projectName: item.projectName,
				kind: .keys(outcome.failed.map(\.edit)), state: .failed(Self.reason(for: outcome.failed))))
		}
		items.replaceSubrange(index...index, with: rows)
		guard !outcome.review.isEmpty else { return rows.count }
		let reviewID = "review:" + item.projectID
		if let existing = items.firstIndex(where: { $0.id == reviewID }), case .review(let keys) = items[existing].kind {
			items[existing].kind = .review(keys + outcome.review)
			items[existing].state = Self.reviewState(count: keys.count + outcome.review.count)
			return rows.count
		}
		items.insert(Item(id: reviewID, projectID: item.projectID, projectName: item.projectName, kind: .review(outcome.review),
			state: Self.reviewState(count: outcome.review.count)), at: index + rows.count)
		return rows.count + 1
	}

	/// Why keys couldn't be saved: one reason for them all when they share it.
	static func reason(for failures: [(edit: VaultUnsavedWork.KeyEdit, reason: String)]) -> String {
		let keys = failures.map(\.edit.key)
		if Set(failures.map(\.reason)).count == 1, let reason = failures.first?.reason {
			return "\(ListFormatter.localizedString(byJoining: keys)) couldn't be saved: \(reason)"
		}
		return failures.map { "\($0.edit.key) couldn't be saved: \($0.reason)" }.joined(separator: "\n")
	}

	private func saveSchema(_ item: Item, in store: VaultStore) async -> ItemState {
		do {
			try await store.saveSchemaDraft(in: item.projectID)
			return .saved
		} catch .conflicts {
			return .needsReview("Its rules changed elsewhere; review the draft on the Schema page. Quitting discards it.")
		} catch {
			return .failed("The rules couldn't be written to lpm.json: \(error.message)")
		}
	}

	private func saveSettings(_ item: Item, in store: VaultStore) async -> ItemState {
		await store.saveProjectSettings(of: item.projectID)
		guard store.projectSettingsDrafts[item.projectID] != nil else { return .saved }
		return .failed(store.projectSettingsErrors[item.projectID] ?? "\(item.projectName)'s settings couldn't be saved.")
	}

	private func finish(quitting: Bool) {
		if isPresented {
			presenter.dismiss()
			isPresented = false
		}
		run += 1
		work?.cancel()
		work = nil
		lockWatch?.cancel()
		lockWatch = nil
		phase = .idle
		items = []
		isFinishingOverdue = false
		isQuitting = false
		if awaitsReply {
			awaitsReply = false
			reply(quitting)
		} else if quitting {
			isApproved = true
			terminate()
		}
	}

	private static func reviewState(count: Int) -> ItemState {
		.needsReview("Review in the inspector; quitting discards \(count == 1 ? "this edit" : "these edits").")
	}

	/// The sheet's rows, a project's together: its keys, the keys it can't
	/// save, its schema draft, its Project Settings, then its open sheets.
	static func items(for work: VaultUnsavedWork) -> [Item] {
		let keyEdits = Dictionary(work.keyEdits.map { ($0.projectID, $0) }, uniquingKeysWith: { first, _ in first })
		let drafts = Dictionary(work.schemaDrafts.map { ($0.projectID, $0) }, uniquingKeysWith: { first, _ in first })
		let settings = Dictionary(work.projectSettings.map { ($0.projectID, $0) }, uniquingKeysWith: { first, _ in first })
		let sheets = Dictionary(grouping: work.openSheets.filter { $0.projectID != nil }, by: { $0.projectID ?? "" })
		var items: [Item] = []
		func sheetItem(_ sheet: VaultUnsavedWork.OpenSheet) -> Item {
			Item(id: "sheet:" + sheet.id.uuidString, projectID: sheet.projectID ?? "", projectName: sheet.projectName,
				kind: .sheet(title: sheet.title, detail: sheet.detail), state: .needsReview("Finish it, or quitting discards it."))
		}
		for projectID in work.projectOrder {
			if let edits = keyEdits[projectID] {
				if !edits.saveable.isEmpty {
					items.append(Item(id: "keys:" + projectID, projectID: projectID, projectName: edits.projectName,
						kind: .keys(edits.saveable), state: .waiting))
				}
				if !edits.needsReview.isEmpty {
					items.append(Item(id: "review:" + projectID, projectID: projectID, projectName: edits.projectName,
						kind: .review(edits.needsReview), state: reviewState(count: edits.needsReview.count)))
				}
			}
			if let draft = drafts[projectID] {
				items.append(Item(id: "schema:" + projectID, projectID: projectID, projectName: draft.projectName,
					kind: .schema(changes: draft.changeCount), state: .waiting))
			}
			if let edit = settings[projectID] {
				items.append(Item(id: "settings:" + projectID, projectID: projectID, projectName: edit.projectName,
					kind: .settings(newName: edit.newName, changesIcon: edit.changesIcon), state: .waiting))
			}
			items += (sheets[projectID] ?? []).map(sheetItem)
		}
		items += work.openSheets.filter { $0.projectID == nil }.map(sheetItem)
		return items
	}
}
