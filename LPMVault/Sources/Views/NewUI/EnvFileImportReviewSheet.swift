import SwiftUI

/// What an import changes, grouped as new, changed and unchanged keys, each
/// with its decision: new keys are added unless left out, and existing values
/// are kept unless replaced. Then what the import did, with a short while to
/// undo it.
struct EnvFileImportReviewSheet: View {
	private enum Filter: CaseIterable {
		case all, added, changed, unchanged
	}

	private struct Completion {
		enum Undo: Equatable {
			case available, undoing, undone, expired
			case failed(String)
		}

		let receipt: EnvImportReceipt
		let outcome: EnvFileImportReview.Outcome
		var undo: Undo
	}

	@Bindable var store: VaultStore
	@State private var review: EnvFileImportReview
	/// The import was applied without a review, keeping every existing value,
	/// so the sheet opens on what it did.
	private let importedWithoutReview: Bool
	@Environment(\.dismiss) private var dismiss
	@Environment(\.vaultContentObscured) private var isObscured
	@Environment(\.vaultImportUndoTimer) private var undoTimer
	@State private var filter = Filter.all
	@State private var revealed = false
	@State private var revealTask: Task<Void, Never>?
	@State private var revealRequestID: UUID?
	@State private var replacingKeys: Set<String> = []
	@State private var skippingKeys: Set<String> = []
	@State private var task: Task<Void, Never>?
	@State private var failure: String?
	@State private var completion: Completion?

	/// `receipt` is what an import without a review did, which the sheet opens on.
	init(store: VaultStore, review: EnvFileImportReview, importedWithoutReview receipt: EnvImportReceipt? = nil) {
		_store = Bindable(wrappedValue: store)
		_review = State(initialValue: review)
		importedWithoutReview = receipt != nil
		_completion = State(initialValue: receipt.map {
			Completion(receipt: $0, outcome: review.outcome(), undo: $0.changed ? .available : .expired)
		})
	}

	private var isWorking: Bool { task != nil }
	private var outcome: EnvFileImportReview.Outcome { review.outcome(replacing: replacingKeys, skipping: skippingKeys) }

	var body: some View {
		let isCurrent = store.isCurrentEnvFileImportReview(review)
		VStack(alignment: .leading, spacing: 0) {
			header
			VaultHairline()
			if let completion {
				completionBody(completion)
			} else {
				reviewBody(isCurrent: isCurrent)
			}
			footer
		}
		// An import without a review stays as wide as the import sheet it was made from.
		.frame(width: importedWithoutReview ? 520 : 640)
		.frame(height: completion == nil ? 560 : nil)
		.background(VaultPalette.content)
		.vaultUnsavedSheetWork(store, projectID: review.projectId, projectName: review.projectName, title: "Import review",
			detail: completion == nil
				? "\(review.source.name) into \(VaultProject.displayName(for: review.environment))" : nil)
		.task(id: completion?.undo == .available) {
			guard completion?.undo == .available else { return }
			do { try await undoTimer.wait() } catch { return }
			if completion?.undo == .available { completion?.undo = .expired }
		}
		.onDisappear {
			task?.cancel()
			task = nil
			replacingKeys.removeAll()
			skippingKeys.removeAll()
			hideValues()
		}
		.onChange(of: store.isUnlocked) { _, unlocked in if !unlocked { close() } }
		.onChange(of: store.selectedProjectId) { _, id in if id != review.projectId { close() } }
		.onChange(of: store.selectedEnvironment) { _, name in if name != review.environment { close() } }
		.onChange(of: store.selectedAccount) { _, _ in close() }
		.onChange(of: store.isShowingAccountPage) { _, showing in if showing { close() } }
		.onChange(of: isObscured) { _, obscured in if obscured { hideValues() } }
		.onChange(of: review.id) { _, _ in hideValues() }
	}

	// MARK: - Header

	private var header: some View {
		HStack(alignment: .top, spacing: 14) {
			Image(systemName: completion?.undo == .undone ? "arrow.uturn.backward" : "square.and.arrow.down")
				.font(.system(size: 15, weight: .semibold))
				.foregroundStyle(VaultPalette.accentForeground)
				.frame(width: 38, height: 38)
				.background(RoundedRectangle(cornerRadius: 10).fill(VaultPalette.accentTint))
				.accessibilityHidden(true)
			VStack(alignment: .leading, spacing: 4) {
				Text(title)
					.font(.system(size: 17, weight: .bold))
					.foregroundStyle(VaultPalette.textPrimary)
				HStack(spacing: 6) {
					Text(sourceDescription)
						.font(VaultTypography.tabular(12.5))
						.foregroundStyle(VaultPalette.textSecondary)
						.lineLimit(1)
						.truncationMode(.head)
					Image(systemName: "arrow.right")
						.font(.system(size: 9, weight: .semibold))
						.foregroundStyle(VaultPalette.textFaint)
						.accessibilityLabel("into")
					Text("\(review.projectName) / \(Text(VaultProject.displayName(for: review.environment)).font(VaultTypography.tabular(12.5)).foregroundStyle(VaultPalette.textSecondary))")
						.font(.system(size: 12.5))
						.foregroundStyle(VaultPalette.textTertiary)
						.lineLimit(1)
						.fixedSize()
				}
			}
			Spacer(minLength: 12)
			VaultSheetCloseButton(action: cancel)
		}
		.padding(.horizontal, 24)
		.padding(.top, 20)
		.padding(.bottom, 16)
	}

	private var title: String {
		switch completion?.undo {
		case nil: "Review import"
		case .undone?: "Import undone"
		default: "Import complete"
		}
	}

	/// The file the variables came from, as its folder and name, or pasted text.
	private var sourceDescription: String {
		switch review.source {
		case .file(let url): (url.path as NSString).abbreviatingWithTildeInPath
		case .pastedText: review.source.name
		}
	}

	/// What the review calls the incoming value, after where it came from.
	private var incomingName: String {
		review.source == .pastedText ? "Pasted" : "File"
	}

	// MARK: - Review

	private func reviewBody(isCurrent: Bool) -> some View {
		VStack(alignment: .leading, spacing: 0) {
			filters(isCurrent: isCurrent)
				.padding(.horizontal, 24)
				.padding(.top, 14)
			ScrollView {
				LazyVStack(alignment: .leading, spacing: 14) {
					if shows(.added), !review.added.isEmpty { addedSection(isCurrent: isCurrent) }
					if shows(.changed), !review.changed.isEmpty { changedSection(isCurrent: isCurrent) }
					if shows(.unchanged), !review.unchanged.isEmpty { unchangedSection(isCurrent: isCurrent) }
				}
				.padding(.horizontal, 24)
				.padding(.vertical, 14)
			}
			.frame(maxHeight: .infinity, alignment: .top)
			.disabled(isWorking)
			if let failure {
				Text(failure)
					.font(.system(size: 11.5))
					.foregroundStyle(VaultPalette.redText)
					.lineLimit(3)
					.fixedSize(horizontal: false, vertical: true)
					.padding(.horizontal, 24)
					.padding(.bottom, 12)
			}
		}
		.frame(maxHeight: .infinity, alignment: .top)
	}

	private func shows(_ section: Filter) -> Bool { filter == .all || filter == section }

	private func filters(isCurrent: Bool) -> some View {
		HStack(spacing: 6) {
			VaultFilterChip(title: "All · \(review.rows.count)", selected: filter == .all) { filter = .all }
			filterChip(.added, "New", count: review.addedCount, dot: VaultPalette.green)
			filterChip(.changed, "Changed", count: review.changedKeys.count, dot: VaultPalette.orange)
			filterChip(.unchanged, "Unchanged", count: review.unchangedCount, dot: nil)
			Spacer(minLength: 8)
			Button(action: toggleReveal) {
				Label(revealed ? "Hide values" : "Reveal values", systemImage: revealed ? "eye.slash" : "eye")
					.font(.system(size: 11.5, weight: .medium))
					.foregroundStyle(VaultPalette.textTertiary)
			}
			.buttonStyle(.plain)
			.vaultPointingHand()
			.disabled((!revealed && revealTask != nil) || failure != nil || isObscured || !isCurrent || isWorking)
			.help(revealed ? "Hide the values" : "Show the values to compare them, after macOS authentication")
		}
	}

	private func filterChip(_ section: Filter, _ title: String, count: Int, dot: Color?) -> some View {
		VaultFilterChip(title: "\(title) · \(count)", dot: dot, selected: filter == section) { filter = section }
			.disabled(count == 0)
			.opacity(count == 0 ? 0.5 : 1)
	}

	private func sectionHeader(_ title: String, count: Int, dot: Color, caption: String) -> some View {
		HStack(spacing: 8) {
			VaultStatusDot(color: dot)
			Text("\(title) · \(count)").vaultSectionLabel()
			Text(caption)
				.font(.system(size: 11))
				.foregroundStyle(VaultPalette.textFaint)
				.lineLimit(1)
		}
		.padding(.horizontal, 2)
	}

	private func rows<Content: View>(_ rows: [EnvFileImportReview.Row], @ViewBuilder row: @escaping (EnvFileImportReview.Row) -> Content) -> some View {
		LazyVStack(spacing: 0) {
			ForEach(rows) { item in
				row(item)
				if item.id != rows.last?.id {
					VaultHairline(color: VaultPalette.rowDivider)
				}
			}
		}
		.background(RoundedRectangle(cornerRadius: 9).fill(VaultPalette.control))
		.clipShape(RoundedRectangle(cornerRadius: 9))
		.overlay { RoundedRectangle(cornerRadius: 9).stroke(VaultPalette.border, lineWidth: 1) }
	}

	private func addedSection(isCurrent: Bool) -> some View {
		VStack(alignment: .leading, spacing: 6) {
			sectionHeader("NEW", count: review.addedCount, dot: VaultPalette.green,
				caption: skippingKeys.isEmpty ? "will be added" : "will be added, except those you turn off")
			rows(review.added) { row in
				let skipped = skippingKeys.contains(row.key)
				HStack(spacing: 12) {
					keyText(row.key, faded: skipped)
					value(review.imported.secrets[row.key] ?? "", named: incomingName, of: row.key, isCurrent: isCurrent, faded: skipped, labeled: false)
					Toggle("Add", isOn: inclusion(of: row.key))
						.toggleStyle(AddToggleStyle())
						.accessibilityLabel("Add \(row.key)")
						.frame(width: 120, alignment: .trailing)
				}
				.padding(.horizontal, 12)
				.frame(minHeight: 42)
			}
		}
	}

	private func changedSection(isCurrent: Bool) -> some View {
		let replacesAll = review.changedKeys.isSubset(of: replacingKeys)
		return VStack(alignment: .leading, spacing: 6) {
			HStack(spacing: 8) {
				sectionHeader("CHANGED", count: review.changedKeys.count, dot: VaultPalette.orange,
					caption: "existing value kept unless you choose Replace")
				Spacer(minLength: 8)
				Button(replacesAll ? "Keep all" : "Replace all") {
					replacingKeys = replacesAll ? [] : review.changedKeys
				}
				.buttonStyle(.plain)
				.font(.system(size: 11, weight: .semibold))
				.foregroundStyle(VaultPalette.accentForeground)
				.vaultPointingHand()
				.help(replacesAll ? "Keep every existing value" : "Replace every existing value that differs")
			}
			rows(review.changed) { row in
				let replacing = replacingKeys.contains(row.key)
				HStack(spacing: 12) {
					keyText(row.key, faded: false)
					VStack(alignment: .leading, spacing: 3) {
						value(review.baseline[row.key] ?? "", named: "Vault", of: row.key, isCurrent: isCurrent, faded: replacing, struck: replacing)
						value(review.imported.secrets[row.key] ?? "", named: incomingName, of: row.key, isCurrent: isCurrent, faded: !replacing,
							emphasized: replacing)
					}
					.frame(maxWidth: .infinity, alignment: .leading)
					KeepReplaceControl(key: row.key, replacing: replacement(of: row.key))
						.frame(width: 120, alignment: .trailing)
				}
				.padding(.horizontal, 12)
				.padding(.vertical, 8)
				.frame(minHeight: 56)
				.background(replacing ? VaultPalette.accent.opacity(0.08) : .clear)
			}
		}
	}

	private func unchangedSection(isCurrent: Bool) -> some View {
		VStack(alignment: .leading, spacing: 6) {
			sectionHeader("UNCHANGED", count: review.unchangedCount, dot: VaultPalette.textFaint.opacity(0.5),
				caption: "identical, skipped")
			rows(review.unchanged) { row in
				HStack(spacing: 12) {
					keyText(row.key, faded: true)
					value(review.imported.secrets[row.key] ?? "", named: incomingName, of: row.key, isCurrent: isCurrent, faded: true, labeled: false)
					Text("Skip")
						.font(.system(size: 11))
						.foregroundStyle(VaultPalette.textFaint)
						.frame(width: 120, alignment: .trailing)
				}
				.padding(.horizontal, 12)
				.frame(minHeight: 42)
				.opacity(0.75)
			}
		}
	}

	private func keyText(_ key: String, faded: Bool) -> some View {
		Text(key)
			.font(VaultTypography.tabular(12.5, .semibold))
			.foregroundStyle(faded ? VaultPalette.textTertiary : VaultPalette.textPrimary)
			.lineLimit(1)
			.truncationMode(.middle)
			.frame(maxWidth: .infinity, alignment: .leading)
	}

	/// A value, hidden until the person reveals the review's values. `named`
	/// says whose it is, the vault's or the import's, which a changed key,
	/// showing both, labels.
	private func value(
		_ value: String, named name: String, of key: String, isCurrent: Bool,
		faded: Bool, struck: Bool = false, emphasized: Bool = false, labeled: Bool = true
	) -> some View {
		let shown = revealed && isCurrent && !isObscured
		return HStack(spacing: 6) {
			if labeled {
				Text(name.uppercased())
					.font(.system(size: 10, weight: .bold))
					.tracking(0.5)
					.foregroundStyle(emphasized ? VaultPalette.accentForeground : VaultPalette.textFaint)
					.frame(width: 44, alignment: .leading)
					.accessibilityHidden(true)
			}
			Text(shown ? (value.isEmpty ? "(empty)" : value) : "••••••••••")
				.font(shown ? VaultTypography.code(12) : VaultTypography.tabular(12))
				.tracking(shown ? 0 : 1.5)
				.strikethrough(struck)
				.foregroundStyle(faded ? VaultPalette.textFaint : (shown ? VaultPalette.textPrimary : VaultPalette.masked))
				.lineLimit(1)
				.truncationMode(.tail)
				.accessibilityLabel("\(name) value for \(key) \(shown ? "revealed visually" : "hidden")")
		}
		.frame(maxWidth: .infinity, alignment: .leading)
	}

	// MARK: - Completion

	private func completionBody(_ completion: Completion) -> some View {
		let outcome = completion.outcome
		return VStack(alignment: .leading, spacing: 12) {
			Label {
				Text(completionHeadline(completion))
					.font(.system(size: 13, weight: .semibold))
					.foregroundStyle(VaultPalette.textPrimary)
			} icon: {
				Image(systemName: completion.undo == .undone ? "arrow.uturn.backward.circle.fill" : "checkmark.circle.fill")
					.foregroundStyle(completion.undo == .undone ? VaultPalette.accentForeground : VaultPalette.green)
			}
			if completion.undo != .undone {
				Text(outcome.summary)
					.font(.system(size: 12.5))
					.foregroundStyle(VaultPalette.textSecondary)
					.textSelection(.enabled)
			}
			if importedWithoutReview, completion.undo != .undone, outcome.kept > 0 {
				Text(outcome.kept == 1
					? "1 existing value differs and was kept. To replace it, import again with Review before applying on."
					: "\(outcome.kept) existing values differ and were kept. To replace them, import again with Review before applying on.")
					.font(.system(size: 11.5))
					.foregroundStyle(VaultPalette.textTertiary)
					.fixedSize(horizontal: false, vertical: true)
			}
			switch completion.undo {
			case .available, .undoing:
				HStack(spacing: 10) {
					VaultBarButton(
						systemImage: "arrow.uturn.backward", title: completion.undo == .undoing ? "Undoing…" : "Undo import",
						disabled: completion.undo == .undoing, height: 28, action: undo)
					Text("Puts \(VaultProject.displayName(for: review.environment)) back as it was. Available for 30 seconds.")
						.font(.system(size: 11))
						.foregroundStyle(VaultPalette.textFaint)
						.fixedSize(horizontal: false, vertical: true)
				}
			case .failed(let message):
				Text(message)
					.font(.system(size: 11.5))
					.foregroundStyle(VaultPalette.redText)
					.fixedSize(horizontal: false, vertical: true)
			case .undone, .expired:
				EmptyView()
			}
		}
		.padding(.horizontal, 24)
		.padding(.vertical, 20)
		.frame(maxWidth: .infinity, alignment: .leading)
	}

	private func completionHeadline(_ completion: Completion) -> String {
		let environment = VaultProject.displayName(for: review.environment)
		if completion.undo == .undone { return "\(environment) is back as it was before the import" }
		return completion.receipt.changed ? "Imported into \(review.projectName) · \(environment)" : "Nothing needed to change"
	}

	// MARK: - Footer

	private var footer: some View {
		VaultSheetFooter {
			if completion == nil {
				VStack(alignment: .leading, spacing: 2) {
					outcomeSummary(outcome)
						.font(.system(size: 12))
						.foregroundStyle(VaultPalette.textSecondary)
						.lineLimit(1)
					Text("Values stay hidden and are encrypted on import. Undo available for 30s.")
						.font(.system(size: 11))
						.foregroundStyle(VaultPalette.textFaint)
						.lineLimit(2)
						.fixedSize(horizontal: false, vertical: true)
				}
			}
		} actions: {
			if completion != nil {
				VaultBarButton(title: "Done", filled: true, disabled: completion?.undo == .undoing, height: 30) { dismiss() }
					.keyboardShortcut(.defaultAction)
			} else {
				VaultBarButton(title: "Cancel", height: 30, action: cancel)
					.keyboardShortcut(.cancelAction)
				if failure != nil {
					VaultBarButton(title: isWorking ? "Reviewing…" : "Review again", filled: true, disabled: isWorking, height: 30, action: reload)
						.keyboardShortcut(.defaultAction)
				} else {
					VaultBarButton(title: importTitle, shortcut: "⏎", filled: true, disabled: isWorking || outcome.changes == 0, height: 30, action: apply)
						.keyboardShortcut(.defaultAction)
				}
			}
		}
	}

	private var importTitle: String {
		if isWorking { return "Importing…" }
		let changes = outcome.changes
		return changes == 0 ? "Nothing to import" : "Import \(changes) \(changes == 1 ? "change" : "changes")"
	}

	private func outcomeSummary(_ outcome: EnvFileImportReview.Outcome) -> Text {
		let added = Text("+\(outcome.added) added").fontWeight(.semibold).foregroundStyle(outcome.added > 0 ? VaultPalette.greenTintText : VaultPalette.textSecondary)
		let replaced = Text("\(outcome.replaced) replaced").fontWeight(.semibold).foregroundStyle(outcome.replaced > 0 ? VaultPalette.orangeTintText : VaultPalette.textSecondary)
		return Text("\(added) · \(replaced) · \(outcome.kept) kept · \(outcome.skipped) skipped")
	}

	// MARK: - Actions

	private func inclusion(of key: String) -> Binding<Bool> {
		Binding(
			get: { !skippingKeys.contains(key) },
			set: { included in
				if included { skippingKeys.remove(key) } else { skippingKeys.insert(key) }
			}
		)
	}

	private func replacement(of key: String) -> Binding<Bool> {
		Binding(
			get: { replacingKeys.contains(key) },
			set: { replacing in
				if replacing { replacingKeys.insert(key) } else { replacingKeys.remove(key) }
			}
		)
	}

	private func toggleReveal() {
		if revealed { return hideValues() }
		guard revealTask == nil, task == nil, completion == nil, failure == nil, !isObscured,
			store.isCurrentEnvFileImportReview(review)
		else { return }
		let requestID = UUID()
		let reviewID = review.id
		revealRequestID = requestID
		revealTask = Task {
			defer {
				if revealRequestID == requestID {
					revealTask = nil
					revealRequestID = nil
				}
			}
			let approved = await store.authenticateForSensitiveAction(reason: "Compare imported secret values")
			guard approved, !Task.isCancelled, revealRequestID == requestID, review.id == reviewID,
				!isObscured, task == nil, completion == nil, store.isCurrentEnvFileImportReview(review)
			else { return }
			revealed = true
		}
	}

	private func hideValues() {
		revealTask?.cancel()
		revealTask = nil
		revealRequestID = nil
		revealed = false
	}

	private func cancel() {
		task?.cancel()
		hideValues()
		dismiss()
	}

	private func close() {
		hideValues()
		dismiss()
	}

	private func apply() {
		guard outcome.changes > 0 else { return }
		hideValues()
		let replacing = replacingKeys
		let skipping = skippingKeys
		let outcome = outcome
		task = Task {
			let result = await store.applyEnvFileImport(review, replacingKeys: replacing, skippingKeys: skipping)
			guard !Task.isCancelled else { return }
			task = nil
			switch result {
			case .success(let receipt): completion = Completion(receipt: receipt, outcome: outcome, undo: receipt.changed ? .available : .expired)
			case .failure(.cancelled), .failure(.vaultLocked): dismiss()
			case .failure(let error): failure = error.description(for: review.source)
			}
		}
	}

	private func undo() {
		guard let receipt = completion?.receipt, completion?.undo == .available else { return }
		completion?.undo = .undoing
		task = Task {
			let outcome = await store.undoEnvImport(receipt)
			guard !Task.isCancelled else { return }
			task = nil
			switch outcome {
			case .saved: completion?.undo = .undone
			case .changed:
				completion?.undo = .failed("\(VaultProject.displayName(for: receipt.environment)) changed after the import, so it can't be undone.")
			case .unavailable: completion?.undo = .failed("The import can't be undone now.")
			case .failed(let message): completion?.undo = .failed("The import couldn't be undone. \(message)")
			}
		}
	}

	private func reload() {
		hideValues()
		task = Task {
			let result = await store.prepareEnvImport(
				review.imported, from: review.source, to: review.projectId, environment: review.environment)
			guard !Task.isCancelled else { return }
			task = nil
			switch result {
			case .success(let updated):
				review = updated
				replacingKeys.removeAll()
				skippingKeys.removeAll()
				failure = nil
			case .failure(.cancelled), .failure(.vaultLocked): dismiss()
			case .failure(let error): failure = error.description(for: review.source)
			}
		}
	}
}

/// Add, with a check while the key is added, as the review's new keys show it.
private struct AddToggleStyle: ToggleStyle {
	func makeBody(configuration: Configuration) -> some View {
		let on = configuration.isOn
		return Button { configuration.isOn.toggle() } label: {
			HStack(spacing: 5) {
				Image(systemName: on ? "checkmark" : "plus")
					.font(.system(size: 9, weight: .bold))
				configuration.label
					.font(.system(size: 11, weight: .semibold))
			}
			.foregroundStyle(on ? VaultPalette.greenTintText : VaultPalette.textTertiary)
			.padding(.horizontal, 8)
			.frame(height: 24)
			.background(RoundedRectangle(cornerRadius: 6).fill(on ? VaultPalette.greenTint : .clear))
			.overlay { RoundedRectangle(cornerRadius: 6).stroke(on ? .clear : VaultPalette.border, lineWidth: 1) }
			.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.vaultPointingHand()
		.accessibilityAddTraits(on ? .isSelected : [])
		.help(on ? "Leave this key out of the import" : "Add this key")
	}
}

/// Keep or Replace an existing value that differs, as two halves of one control.
private struct KeepReplaceControl: View {
	let key: String
	@Binding var replacing: Bool

	var body: some View {
		HStack(spacing: 0) {
			half("Keep", selected: !replacing, filled: VaultPalette.neutralTint, foreground: VaultPalette.textPrimary) { replacing = false }
				.accessibilityLabel("Keep \(key)")
			Rectangle().fill(VaultPalette.border).frame(width: 1)
			half("Replace", selected: replacing, filled: VaultPalette.accent, foreground: .white) { replacing = true }
				.accessibilityLabel("Replace \(key)")
		}
		.fixedSize()
		.clipShape(RoundedRectangle(cornerRadius: 6))
		.overlay { RoundedRectangle(cornerRadius: 6).stroke(VaultPalette.border, lineWidth: 1) }
	}

	private func half(_ title: String, selected: Bool, filled: Color, foreground: Color, action: @escaping () -> Void) -> some View {
		Button(action: action) {
			Text(title)
				.font(.system(size: 11, weight: selected ? .semibold : .regular))
				.foregroundStyle(selected ? foreground : VaultPalette.textTertiary)
				.padding(.horizontal, 8)
				.frame(height: 24)
				.background(selected ? filled : .clear)
				.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.vaultPointingHand()
		.accessibilityAddTraits(selected ? .isSelected : [])
	}
}
