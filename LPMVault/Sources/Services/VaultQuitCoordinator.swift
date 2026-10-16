import AppKit
import Observation

/// Decides whether LPM Vault can quit, however quitting was asked for: ⌘Q,
/// the menu, the Dock, logging out, shutting down, or an update's restart.
/// It first lets writes already running finish. Unsaved edits then get a
/// sheet that saves them, discards them, or keeps the app open.
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
			case keys([VaultKeyDraft.ID])
			case schema
		}

		let id: String
		let projectID: String
		let projectName: String
		let kind: Kind
		/// What follows the project's name, such as "3 keys" or "Schema draft".
		let subject: String
		let detail: String
		let badge: String
		/// The unsaved edits it holds; none for a schema draft, which counts as a draft.
		let editCount: Int
		var state: ItemState
	}

	/// Shows and hides the sheet, which is attached to the app's window.
	@MainActor
	protocol Presenter: AnyObject {
		/// Shows the sheet; false when there's no window to show it on.
		func present(_ coordinator: VaultQuitCoordinator) -> Bool
		func dismiss()
	}

	private(set) var phase: Phase = .idle
	private(set) var items: [Item] = []

	@ObservationIgnored private weak var store: VaultStore?
	@ObservationIgnored private let presenter: any Presenter
	@ObservationIgnored private let reply: (Bool) -> Void
	@ObservationIgnored private let finishingDelay: Duration
	@ObservationIgnored private var isPresented = false
	@ObservationIgnored private var run: Task<Void, Never>?

	init(
		store: VaultStore?,
		presenter: any Presenter,
		finishingDelay: Duration = .milliseconds(150),
		reply: @escaping (Bool) -> Void = { NSApp.reply(toApplicationShouldTerminate: $0) }
	) {
		self.store = store
		self.presenter = presenter
		self.finishingDelay = finishingDelay
		self.reply = reply
	}

	func attach(_ store: VaultStore) {
		self.store = store
	}

	var isQuitting: Bool { phase != .idle || run != nil }

	/// The answer to `applicationShouldTerminate`: quit later, once writes
	/// finish and unsaved edits are saved or discarded.
	func shouldTerminate() -> NSApplication.TerminateReply {
		guard run == nil, phase == .idle else { return .terminateCancel }
		guard store != nil else { return .terminateNow }
		run = Task { [weak self] in await self?.prepareToQuit() }
		return .terminateLater
	}

	private func prepareToQuit() async {
		guard let store else { return finish(quitting: true) }
		let writes = Task { await store.finishWritesInProgress() }
		let shown = Task { [finishingDelay] in
			try? await Task.sleep(for: finishingDelay)
			return !Task.isCancelled
		}
		Task { [weak self] in
			guard await shown.value, let self, self.run != nil, self.phase == .idle else { return }
			self.phase = .finishing
			self.isPresented = self.presenter.present(self)
		}
		await writes.value
		shown.cancel()
		guard run != nil else { return }
		let work = store.unsavedWork()
		guard !work.isEmpty else { return finish(quitting: true) }
		items = Self.items(for: work)
		phase = .reviewing
		if !isPresented { isPresented = presenter.present(self) }
		// Without a window to ask in, unsaved edits are discarded, as locking does.
		if !isPresented { finish(quitting: true) }
	}

	/// Saves every edit that can be saved, a project at a time, and quits
	/// once nothing that was asked to be saved failed.
	func saveAndQuit() {
		guard phase == .reviewing || phase == .failed, let store else { return }
		phase = .saving
		Task {
			for index in items.indices where items[index].state == .waiting || isFailed(items[index].state) {
				guard phase == .saving else { return }
				items[index].state = .saving
				let state = await save(items[index], in: store)
				// Cancel ends the sheet while a save finishes.
				guard phase == .saving, items.indices.contains(index) else { return }
				items[index].state = state
			}
			guard phase == .saving else { return }
			if items.contains(where: { isFailed($0.state) }) {
				phase = .failed
			} else {
				finish(quitting: true)
			}
		}
	}

	/// Quits without saving what's left; edits already saved stay saved.
	func discardAndQuit() {
		guard phase == .reviewing || phase == .failed else { return }
		finish(quitting: true)
	}

	/// Keeps the app open with the unsaved edits as they are.
	func cancel() {
		guard phase != .idle || run != nil else { return }
		finish(quitting: false)
	}

	var savedCount: Int { items.filter { $0.state == .saved }.count }

	var failedItems: [Item] { items.filter { isFailed($0.state) } }

	private func isFailed(_ state: ItemState) -> Bool {
		if case .failed = state { true } else { false }
	}

	private func save(_ item: Item, in store: VaultStore) async -> ItemState {
		guard store.isUnlocked else { return .failed("LPM Vault locked before this could be saved.") }
		guard await store.openProjectForSaving(item.projectID) else {
			return .failed("\(item.projectName) couldn't be loaded to save it.")
		}
		switch item.kind {
		case .keys(let ids):
			for id in ids where store.keyDrafts.draft(id)?.canSave == true {
				do {
					try await store.saveKeyDraft(id)
				} catch {
					return .failed("\(id.key) couldn't be saved: \(error.localizedDescription)")
				}
			}
			return .saved
		case .schema:
			do {
				try await store.saveSchemaDraft(in: item.projectID)
				return .saved
			} catch {
				return .failed("The rules couldn't be written to lpm.json: \(error.message)")
			}
		}
	}

	private func finish(quitting: Bool) {
		if isPresented {
			presenter.dismiss()
			isPresented = false
		}
		let waiting = run != nil
		run?.cancel()
		run = nil
		phase = .idle
		items = []
		if waiting { reply(quitting) }
	}

	static func items(for work: VaultUnsavedWork) -> [Item] {
		var items: [Item] = []
		for edits in work.keyEdits {
			if !edits.saveable.isEmpty {
				let keys = edits.saveable.map(\.key)
				items.append(Item(
					id: "keys:" + edits.projectID,
					projectID: edits.projectID,
					projectName: edits.projectName,
					kind: .keys(edits.saveable),
					subject: keys.count == 1 ? "1 key" : "\(keys.count) keys",
					detail: keys.joined(separator: ", ") + (keys.count == 1 ? " · inspector edit" : " · inspector edits"),
					badge: edits.editCount == 1 ? "1 edit" : "\(edits.editCount) edits",
					editCount: edits.editCount,
					state: .waiting
				))
			}
			if !edits.needsReview.isEmpty {
				let count = edits.needsReview.count
				items.append(Item(
					id: "review:" + edits.projectID,
					projectID: edits.projectID,
					projectName: edits.projectName,
					kind: .keys([]),
					subject: count == 1 ? "1 key needs review" : "\(count) keys need review",
					detail: edits.needsReview.joined(separator: ", ") + " · changed elsewhere since the edit",
					badge: "review",
					editCount: count,
					state: .needsReview("Review in the inspector; quitting discards \(count == 1 ? "this edit" : "these edits").")
				))
			}
		}
		for draft in work.schemaDrafts {
			items.append(Item(
				id: "schema:" + draft.projectID,
				projectID: draft.projectID,
				projectName: draft.projectName,
				kind: .schema,
				subject: "Schema draft",
				detail: (draft.changeCount == 1 ? "1 rule change" : "\(draft.changeCount) rule changes") + " · lpm.json not written",
				badge: "draft",
				editCount: 0,
				state: .waiting
			))
		}
		return items
	}

	/// The keys among `items` that will be lost because they need a review first.
	var needsReviewCount: Int {
		items.filter { if case .needsReview = $0.state { true } else { false } }.count
	}
}
