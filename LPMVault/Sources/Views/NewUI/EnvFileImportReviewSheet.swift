import SwiftUI

struct EnvFileImportReviewSheet: View {
	@Bindable var store: VaultStore
	@State var review: EnvFileImportReview
	@Environment(\.dismiss) private var dismiss
	@Environment(\.vaultContentObscured) private var isObscured
	@State private var revealedKeys: Set<String> = []
	@State private var revealTask: Task<Void, Never>?
	@State private var revealRequestID: UUID?
	@State private var replacingKeys: Set<String> = []
	@State private var task: Task<Void, Never>?
	@State private var failure: String?
	@State private var completedReplacements: Set<String>?

	private var isWorking: Bool { task != nil }

	var body: some View {
		let isCurrent = store.isCurrentEnvFileImportReview(review)
		VStack(alignment: .leading, spacing: 0) {
			header
			VaultHairline()
			if let completedReplacements {
				completion(replacing: completedReplacements)
			} else {
				reviewBody(isCurrent: isCurrent)
			}
			footer
		}
		.frame(width: 600)
		.frame(height: completedReplacements == nil ? 510 : nil)
		.background(VaultPalette.content)
		.onDisappear {
			task?.cancel()
			task = nil
			replacingKeys.removeAll()
			hideValues()
		}
		.onChange(of: store.isUnlocked) { _, unlocked in if !unlocked { close() } }
		.onChange(of: store.selectedProjectId) { _, id in if id != review.projectId { close() } }
		.onChange(of: store.selectedEnvironment) { _, name in if name != review.environment { close() } }
		.onChange(of: store.selectedAccount) { _, _ in close() }
		.onChange(of: store.showAuthStatus) { _, showing in if showing { close() } }
		.onChange(of: isObscured) { _, obscured in if obscured { hideValues() } }
		.onChange(of: review.id) { _, _ in hideValues() }
	}

	// MARK: - Sections

	private var header: some View {
		HStack(alignment: .top, spacing: 12) {
			VStack(alignment: .leading, spacing: 3) {
				Text(completedReplacements == nil ? "Review import" : "Import complete")
					.font(.system(size: 17, weight: .bold))
					.foregroundStyle(VaultPalette.textPrimary)
				Text("\(Text(review.sourceURL.lastPathComponent).font(VaultTypography.mono(12)).foregroundStyle(VaultPalette.textSecondary)) into \(Text(review.projectName).fontWeight(.semibold).foregroundStyle(VaultPalette.textSecondary)) · \(VaultProject.displayName(for: review.environment))")
					.font(.system(size: 12.5))
					.foregroundStyle(VaultPalette.textTertiary)
					.lineLimit(1)
					.truncationMode(.middle)
			}
			Spacer(minLength: 12)
			VaultSheetCloseButton(action: cancel)
		}
		.padding(.horizontal, 24)
		.padding(.top, 20)
		.padding(.bottom, 16)
	}

	private func reviewBody(isCurrent: Bool) -> some View {
		VStack(alignment: .leading, spacing: 12) {
			HStack(spacing: 6) {
				VaultTagBadge(text: "\(review.addedCount) new", foreground: VaultPalette.greenTintText, background: VaultPalette.greenTint, size: 11)
				VaultTagBadge(text: "\(review.changedKeys.count) different", foreground: VaultPalette.orangeTintText, background: VaultPalette.orangeTint, size: 11)
				VaultTagBadge(text: "\(review.unchangedCount) unchanged", foreground: VaultPalette.textTertiary, background: VaultPalette.neutralTint, size: 11)
			}
			Text("Existing values stay unless you choose a replacement. Comparing values asks for macOS authentication.")
				.font(.system(size: 11.5))
				.foregroundStyle(VaultPalette.textTertiary)
				.fixedSize(horizontal: false, vertical: true)
			ScrollView {
				LazyVStack(spacing: 0) {
					ForEach(review.rows) { row in
						reviewRow(row, isCurrent: isCurrent)
						if row.id != review.rows.last?.id {
							VaultHairline(color: VaultPalette.rowDivider)
						}
					}
				}
			}
			.frame(maxHeight: .infinity, alignment: .top)
			.background(RoundedRectangle(cornerRadius: 10).fill(VaultPalette.control))
			.clipShape(RoundedRectangle(cornerRadius: 10))
			.overlay { RoundedRectangle(cornerRadius: 10).stroke(VaultPalette.border, lineWidth: 1) }
			.disabled(isWorking)
			if let failure {
				Text(failure)
					.font(.system(size: 11.5))
					.foregroundStyle(VaultPalette.redText)
					.lineLimit(3)
					.fixedSize(horizontal: false, vertical: true)
			}
		}
		.padding(.horizontal, 24)
		.padding(.vertical, 18)
		.frame(maxHeight: .infinity, alignment: .top)
	}

	private func reviewRow(_ row: EnvFileImportReview.Row, isCurrent: Bool) -> some View {
		let revealed = isCurrent && !isObscured && revealedKeys.contains(row.key)
		let replacing = replacingKeys.contains(row.key)
		return VStack(alignment: .leading, spacing: 8) {
			HStack(spacing: 10) {
				Text(row.key)
					.font(VaultTypography.mono(12.5, .semibold))
					.foregroundStyle(VaultPalette.textPrimary)
					.lineLimit(1)
					.truncationMode(.middle)
				changeBadge(row.change)
				Spacer(minLength: 8)
				VaultOutlineButton(
					systemImage: revealed ? "eye.slash" : "eye",
					title: revealed ? "Hide" : "Reveal",
					reservedTitles: ["Reveal", "Hide"],
					help: revealed ? "Hide values for \(row.key)" : "Compare values for \(row.key)",
					disabled: (!revealed && revealTask != nil) || failure != nil || isObscured || !isCurrent
				) { toggleReveal(row.key) }
				.accessibilityLabel("\(revealed ? "Hide" : "Reveal") values for \(row.key)")
				if row.change == .changed {
					Toggle("Replace", isOn: replacementBinding(for: row.key))
						.toggleStyle(ReplaceToggleStyle())
						.accessibilityLabel("Replace existing value for \(row.key)")
				}
			}
			VStack(alignment: .leading, spacing: 4) {
				if row.change == .changed {
					valueLine("Current", value: review.baseline[row.key] ?? "", revealed: revealed, superseded: replacing)
				}
				valueLine(
					"Incoming",
					value: review.imported.secrets[row.key] ?? "",
					revealed: revealed,
					superseded: row.change == .changed && !replacing
				)
			}
		}
		.padding(.horizontal, 14)
		.padding(.vertical, 12)
		.background(replacing ? VaultPalette.rowSelected : .clear)
	}

	private func changeBadge(_ change: EnvFileImportReview.Change) -> some View {
		switch change {
		case .added:
			VaultTagBadge(text: change.rawValue, foreground: VaultPalette.greenTintText, background: VaultPalette.greenTint)
		case .changed:
			VaultTagBadge(text: change.rawValue, foreground: VaultPalette.orangeTintText, background: VaultPalette.orangeTint)
		case .unchanged:
			VaultTagBadge(text: change.rawValue, foreground: VaultPalette.textTertiary, background: VaultPalette.neutralTint)
		}
	}

	/// One labeled value. A superseded value is the one the import will not keep.
	private func valueLine(_ label: String, value: String, revealed: Bool, superseded: Bool) -> some View {
		HStack(alignment: .firstTextBaseline, spacing: 12) {
			Text(label)
				.font(.system(size: 11, weight: .medium))
				.foregroundStyle(VaultPalette.textTertiary)
				.frame(width: 60, alignment: .leading)
			Text(revealed ? (value.isEmpty ? "(empty)" : value) : "••••••••")
				.font(VaultTypography.mono(12))
				.foregroundStyle(superseded ? VaultPalette.textFaint : (revealed ? VaultPalette.textPrimary : VaultPalette.masked))
				.frame(maxWidth: .infinity, alignment: .leading)
				.fixedSize(horizontal: false, vertical: true)
				.accessibilityLabel(revealed ? "\(label) value revealed visually" : "\(label) value hidden")
		}
	}

	private func completion(replacing keys: Set<String>) -> some View {
		let replaced = review.changedKeys.intersection(keys).count
		let wroteChanges = review.addedCount + replaced > 0
		return VStack(alignment: .leading, spacing: 12) {
			Label {
				Text(wroteChanges ? "Imported into \(review.projectName) · \(VaultProject.displayName(for: review.environment))" : "Nothing needed to change")
					.font(.system(size: 13, weight: .semibold))
					.foregroundStyle(VaultPalette.textPrimary)
			} icon: {
				Image(systemName: "checkmark.circle.fill")
					.foregroundStyle(VaultPalette.green)
			}
			Text(review.summary(replacing: keys))
				.font(.system(size: 12.5))
				.foregroundStyle(VaultPalette.textSecondary)
				.textSelection(.enabled)
		}
		.padding(.horizontal, 24)
		.padding(.vertical, 20)
		.frame(maxWidth: .infinity, alignment: .leading)
	}

	private var footer: some View {
		VaultSheetFooter {
			if completedReplacements == nil {
				Text("\(replacingKeys.count) \(replacingKeys.count == 1 ? "replacement" : "replacements") selected")
					.font(.system(size: 11.5))
					.foregroundStyle(VaultPalette.textTertiary)
					.lineLimit(1)
			}
		} actions: {
			if completedReplacements != nil {
				VaultBarButton(title: "Done", filled: true, height: 30) { dismiss() }
					.keyboardShortcut(.defaultAction)
			} else {
				VaultBarButton(title: "Cancel", height: 30, action: cancel)
					.keyboardShortcut(.cancelAction)
				if failure != nil {
					VaultBarButton(title: isWorking ? "Reviewing…" : "Review again", filled: true, disabled: isWorking, height: 30, action: reload)
						.keyboardShortcut(.defaultAction)
				} else {
					VaultBarButton(title: isWorking ? "Importing…" : "Import", shortcut: "⏎", filled: true, disabled: isWorking, height: 30, action: apply)
						.keyboardShortcut(.defaultAction)
				}
			}
		}
	}

	// MARK: - Actions

	private func replacementBinding(for key: String) -> Binding<Bool> {
		Binding(
			get: { replacingKeys.contains(key) },
			set: { replacing in
				if replacing { replacingKeys.insert(key) } else { replacingKeys.remove(key) }
			}
		)
	}

	private func toggleReveal(_ key: String) {
		if revealedKeys.remove(key) != nil { return }
		guard revealTask == nil, task == nil, completedReplacements == nil, failure == nil, !isObscured,
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
				!isObscured, task == nil, completedReplacements == nil, store.isCurrentEnvFileImportReview(review)
			else { return }
			revealedKeys.insert(key)
		}
	}

	private func hideValues() {
		revealTask?.cancel()
		revealTask = nil
		revealRequestID = nil
		revealedKeys.removeAll()
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
		hideValues()
		let keys = replacingKeys
		task = Task {
			let result = await store.applyEnvFileImport(review, replacingKeys: keys)
			guard !Task.isCancelled else { return }
			task = nil
			switch result {
			case .success: completedReplacements = keys
			case .failure(.cancelled), .failure(.vaultLocked): dismiss()
			case .failure(let error): failure = error.localizedDescription
			}
		}
	}

	private func reload() {
		hideValues()
		task = Task {
			let result = await store.prepareEnvFileImport(
				at: review.sourceURL, to: review.projectId, environment: review.environment)
			guard !Task.isCancelled else { return }
			task = nil
			switch result {
			case .success(let updated):
				review = updated
				replacingKeys.removeAll()
				failure = nil
			case .failure(.cancelled), .failure(.vaultLocked): dismiss()
			case .failure(let error): failure = error.localizedDescription
			}
		}
	}
}

/// Checkbox matching the environment chips in the add-variable sheet.
private struct ReplaceToggleStyle: ToggleStyle {
	func makeBody(configuration: Configuration) -> some View {
		let selected = configuration.isOn
		return Button { configuration.isOn.toggle() } label: {
			HStack(spacing: 6) {
				ZStack {
					RoundedRectangle(cornerRadius: 4)
						.fill(selected ? VaultPalette.accent : VaultPalette.control)
					RoundedRectangle(cornerRadius: 4)
						.stroke(selected ? VaultPalette.accent : VaultPalette.textFaint.opacity(0.6), lineWidth: 1.5)
					if selected {
						Image(systemName: "checkmark")
							.font(.system(size: 8, weight: .heavy))
							.foregroundStyle(.white)
					}
				}
				.frame(width: 15, height: 15)
				configuration.label
					.font(.system(size: 12, weight: .medium))
					.foregroundStyle(selected ? VaultPalette.accentForeground : VaultPalette.textSecondary)
			}
			.padding(.horizontal, 4)
			.frame(height: 27)
			.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.vaultPointingHand()
		.accessibilityAddTraits(selected ? .isSelected : [])
	}
}
