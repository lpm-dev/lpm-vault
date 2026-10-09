import SwiftUI

/// The bottom of the Schema page's side panel: what the draft holds, why it
/// can't be saved yet, and the way on to the review.
struct VaultSchemaEditorFooter: View {
	@Bindable var store: VaultStore
	let project: VaultProject
	/// The item the panel shows.
	let item: ProjectEnvSchemaDraft.Item
	/// What the panel can do with an item it shows read-only, such as "Override rules".
	var readOnlyAction: (systemImage: String, title: String, run: () -> Void)?
	/// Discards the item's change; nil when it has none to discard.
	var discard: (() -> Void)?
	/// The discard changes the draft, so it's off while the rules can't be
	/// edited; one that only closes an item being added isn't.
	var discardEdits = true
	/// Why saving now would leave out what the panel holds, such as an item
	/// whose name can't be used yet.
	var pending: String?
	let onSelect: (VaultSchemaSelection?) -> Void
	let onReview: () -> Void
	/// After a retried save that wrote lpm.json.
	var onSaved: () -> Void = {}

	private var saving: Bool { store.savingSchemaDrafts.contains(project.id) }
	private var canEdit: Bool { store.canEditSchema(of: project.id) }

	/// Why Save is off while the draft has changes, and the item to show for it.
	struct Blocker: Equatable {
		let message: String
		var show: VaultSchemaSelection?
		/// Only the check of the latest edit is still running: the review can
		/// open, and waits for it.
		var checking = false

		/// Whether it keeps the review from opening.
		var blocksReview: Bool { !checking }
	}

	/// Why the draft can't be saved yet, as the panel showing `item` puts it;
	/// with no item, as the page puts it.
	static func blocker(store: VaultStore, projectID: String, item: ProjectEnvSchemaDraft.Item?, pending: String? = nil) -> Blocker? {
		if let pending { return Blocker(message: pending) }
		guard let draft = store.schemaDraft(for: projectID) else { return nil }
		if let conflict = draft.conflicts.first(where: { $0.item == item }) ?? draft.conflicts.first {
			if let item, conflict.item == item { return Blocker(message: "Choose a version of this \(noun(of: item)) above to save.") }
			return Blocker(message: "Can't save until you choose a version of \(name(of: conflict.item)), which changed on disk.", show: selection(of: conflict.item))
		}
		guard let current = store.currentSchemaDraftEvaluation(for: projectID) else { return Blocker(message: "Checking the rules…", checking: true) }
		guard let rejection = current.rejection else {
			guard let clash = store.schemaDraftCaseClash(for: projectID) else { return nil }
			let shown: String? = if case .key(let key)? = item, clash.keys.contains(key) { nil } else {
				clash.keys.first { draft.base(of: .key($0)) == .absent && draft.hasChange(to: .key($0)) }
			}
			return Blocker(message: "Can't save: \(clash.message)", show: shown.map(VaultSchemaSelection.key))
		}
		if let item, rejection.item == item { return Blocker(message: "Fix the problem above to save.") }
		guard let other = rejection.item else { return Blocker(message: "Can't save: \(rejection.reason)") }
		return Blocker(message: "Can't save: \(name(of: other)) has a problem. \(rejection.reason)", show: selection(of: other))
	}

	/// A failed save the panel shows, as one the review can't: not a change on
	/// disk, conflicts, imports changed since the review, or a save in progress.
	static func saveFailure(store: VaultStore, projectID: String) -> ProjectEnvSchemaFile.DraftSaveError? {
		switch store.schemaDraftSaveFailure(for: projectID) {
		case nil, .file(.changed)?, .conflicts?, .inProgress?, .importsChanged?: nil
		case let failure?: failure
		}
	}

	nonisolated static func name(of item: ProjectEnvSchemaDraft.Item) -> String {
		switch item {
		case .key(let key): key.escapingDirectionControls
		case .group(let name): "the group \(name.escapingDirectionControls)"
		case .clientPrefixes: "the client prefixes"
		}
	}

	private static func noun(of item: ProjectEnvSchemaDraft.Item) -> String {
		switch item {
		case .key: "key"
		case .group: "group"
		case .clientPrefixes: "list"
		}
	}

	static func showLabel(_ selection: VaultSchemaSelection) -> String {
		switch selection {
		case .key(let key): "Show \(key.escapingDirectionControls)"
		case .group(let name): "Show the group \(name.escapingDirectionControls)"
		case .newKey, .newGroup: "Show what blocks saving"
		}
	}

	private static func selection(of item: ProjectEnvSchemaDraft.Item) -> VaultSchemaSelection? {
		switch item {
		case .key(let key): .key(key)
		case .group(let name): .group(name)
		case .clientPrefixes: nil
		}
	}

	var body: some View {
		let changes = store.schemaDraft(for: project.id)?.changeCount ?? 0
		let blocker = Self.blocker(store: store, projectID: project.id, item: item, pending: pending)
		let failure = Self.saveFailure(store: store, projectID: project.id)
		VStack(alignment: .leading, spacing: 6) {
			if let blocker {
				HStack(alignment: .firstTextBaseline, spacing: 6) {
					Text(blocker.message)
						.font(.system(size: 11))
						.foregroundStyle(VaultPalette.textTertiary)
						.fixedSize(horizontal: false, vertical: true)
					if let show = blocker.show {
						Button("Show") { onSelect(show) }
							.buttonStyle(.plain)
							.font(.system(size: 11, weight: .semibold))
							.foregroundStyle(VaultPalette.accentForeground)
							.vaultPointingHand()
							.accessibilityLabel(Self.showLabel(show))
					}
				}
			}
			HStack(spacing: 8) {
				if let readOnlyAction {
					// With a draft, its way to the review takes the label's place.
					if failure == nil, changes == 0 {
						Text("Read-only").font(.system(size: 11)).foregroundStyle(VaultPalette.textFaint)
					}
					Spacer(minLength: 4)
					VaultBarButton(systemImage: readOnlyAction.systemImage, title: readOnlyAction.title, height: 26, action: readOnlyAction.run)
						.disabled(!canEdit)
					if failure != nil {
						VaultBarButton(title: saving ? "Saving…" : "Retry save", filled: true, disabled: blocker != nil || !canEdit, height: 26, action: retrySave)
					} else if changes > 0 {
						reviewButton(blocker: blocker)
					}
				} else {
					if failure != nil {
						HStack(spacing: 4) {
							Image(systemName: "xmark.circle").font(.system(size: 10, weight: .semibold))
							Text("Not saved").font(.system(size: 11, weight: .medium))
						}
						.foregroundStyle(VaultPalette.redText)
					} else if changes > 0 {
						HStack(spacing: 4) {
							Image(systemName: "arrow.uturn.backward").font(.system(size: 9, weight: .semibold))
							Text(changes == 1 ? "1 change" : "\(changes) changes").font(.system(size: 11, weight: .medium))
						}
						.foregroundStyle(VaultPalette.orangeTintText)
						.help("⌘Z undoes the last change")
					} else {
						Text("No changes").font(.system(size: 11)).foregroundStyle(VaultPalette.textFaint)
					}
					Spacer(minLength: 4)
					if let discard {
						VaultBarButton(title: "Discard", height: 26, action: discard)
							.disabled(discardEdits && !canEdit)
					}
					if failure != nil {
						VaultBarButton(title: saving ? "Saving…" : "Retry save", filled: true, disabled: blocker != nil || !canEdit, height: 26, action: retrySave)
					} else {
						reviewButton(blocker: blocker)
					}
				}
			}
		}
		.padding(.horizontal, 14)
		.padding(.vertical, 10)
		.background(VaultPalette.headerRow)
		// ⌘S opens the review while the panel is open, after a failed save too, where the review saves again.
		.background(VaultSchemaShortcuts(review: openReview))
	}

	private func reviewButton(blocker: Blocker?) -> some View {
		let changes = store.schemaDraft(for: project.id)?.changeCount ?? 0
		return VaultBarButton(title: "Review & save", filled: true, disabled: changes == 0 || blocker?.blocksReview == true || !canEdit, height: 26,
			action: onReview)
			.help("Review the changes, then save them to lpm.json (⌘S)")
	}

	/// Opens the review when there's a draft to review and nothing blocks it; returns whether it did.
	private func openReview() -> Bool {
		guard (store.schemaDraft(for: project.id)?.changeCount ?? 0) > 0, canEdit,
			Self.blocker(store: store, projectID: project.id, item: item, pending: pending)?.blocksReview != true
		else { return false }
		onReview()
		return true
	}

	/// Saves the draft the review already showed, after a failure that didn't change it.
	private func retrySave() {
		Task {
			do throws(ProjectEnvSchemaFile.DraftSaveError) {
				try await store.saveSchemaDraft(in: project.id)
				onSaved()
			} catch {}
		}
	}
}

/// A failed save of the project's draft, with the draft kept.
struct VaultSchemaSaveFailureNotice: View {
	@Bindable var store: VaultStore
	let project: VaultProject

	var body: some View {
		if let failure = VaultSchemaEditorFooter.saveFailure(store: store, projectID: project.id) {
			HStack(alignment: .top, spacing: 8) {
				Image(systemName: "xmark.circle").font(.system(size: 11)).padding(.top, 1)
				VStack(alignment: .leading, spacing: 3) {
					Text("Couldn't save lpm.json").font(.system(size: 12, weight: .semibold))
					Text(failure.message + " Your draft is kept.")
						.font(.system(size: 11.5))
						.fixedSize(horizontal: false, vertical: true)
				}
			}
			.foregroundStyle(VaultPalette.redText)
			.padding(10)
			.frame(maxWidth: .infinity, alignment: .leading)
			.background(RoundedRectangle(cornerRadius: 8).fill(VaultPalette.redTint))
			.overlay { RoundedRectangle(cornerRadius: 8).stroke(VaultPalette.red.opacity(0.5), lineWidth: 1) }
			.padding(.horizontal, 16)
			.padding(.bottom, 12)
		}
	}
}
