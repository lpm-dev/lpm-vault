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
	@State private var summary: String?

	var body: some View {
		VStack(alignment: .leading, spacing: 16) {
			Text(summary == nil ? "Review .env Import" : "Import Complete").font(.title2.weight(.semibold))
			Text("\(review.projectName) · \(VaultProject.displayName(for: review.environment))").font(
				.headline)
			Text(review.sourceURL.lastPathComponent).foregroundStyle(VaultPalette.textSecondary)
			if let summary {
				Text(summary).textSelection(.enabled)
				Spacer()
			} else {
				Text(
					"\(review.addedCount) new · \(review.changedKeys.count) different · \(review.unchangedCount) unchanged"
				)
				Text("Existing values stay unless you select a replacement. Use the eye to compare values.").font(
					.callout
				).foregroundStyle(VaultPalette.textSecondary)
				ScrollView {
					LazyVStack(spacing: 0) {
						ForEach(review.rows) { row in reviewRow(row) }
					}
				}.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).background(
					VaultPalette.sidebar
				).clipShape(RoundedRectangle(cornerRadius: 8)).disabled(task != nil)
			}
			if let failure { Text(failure).foregroundStyle(VaultPalette.redText).font(.callout) }
			HStack {
				if summary == nil {
					Button("Cancel") {
						task?.cancel()
						hideValues()
						dismiss()
					}.keyboardShortcut(.cancelAction)
					if failure != nil { Button("Review Again", action: reload).disabled(task != nil) }
				}
				Spacer()
				if summary == nil {
					Text(
						"\(replacingKeys.count) \(replacingKeys.count == 1 ? "replacement" : "replacements") selected"
					).font(.caption).foregroundStyle(VaultPalette.textSecondary)
				}
				if task != nil { ProgressView().controlSize(.small) }
				if summary != nil {
					Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
				} else {
					Button("Import", action: apply).keyboardShortcut(.defaultAction).disabled(
						task != nil || failure != nil)
				}
			}
		}.padding(24).frame(width: 600, height: 510).foregroundStyle(VaultPalette.textPrimary).background(
			VaultPalette.content
		).onDisappear {
			task?.cancel()
			task = nil
			replacingKeys.removeAll()
			hideValues()
		}.onChange(of: store.isUnlocked) { _, unlocked in if !unlocked { hideValues(); dismiss() } }.onChange(
			of: store.selectedProjectId
		) { _, id in if id != review.projectId { hideValues(); dismiss() } }.onChange(of: store.selectedEnvironment) {
			_, name in if name != review.environment { hideValues(); dismiss() }
		}.onChange(of: store.selectedAccount) { _, _ in hideValues(); dismiss() }
		.onChange(of: store.showAuthStatus) { _, showing in if showing { hideValues(); dismiss() } }
		.onChange(of: isObscured) { _, obscured in if obscured { hideValues() } }
		.onChange(of: review.id) { _, _ in hideValues()
		}
	}

	@ViewBuilder
	private func reviewRow(_ row: EnvFileImportReview.Row) -> some View {
		let revealed = revealedKeys.contains(row.key) && !isObscured && store.isCurrentEnvFileImportReview(review)
		VStack(alignment: .leading, spacing: 10) {
			HStack {
				VStack(alignment: .leading, spacing: 4) {
					Text(row.key).font(.system(.body, design: .monospaced)).lineLimit(1).truncationMode(.middle)
					Text(row.change.rawValue).font(.caption).foregroundStyle(VaultPalette.textSecondary)
				}
				Spacer()
				Button { toggleReveal(row.key) } label: {
					Label(revealed ? "Hide" : "Reveal", systemImage: revealed ? "eye.slash" : "eye")
				}.buttonStyle(.plain).foregroundStyle(VaultPalette.accentForeground)
					.accessibilityLabel("\(revealed ? "Hide" : "Reveal") values for \(row.key)")
					.disabled((!revealed && revealTask != nil) || failure != nil || isObscured || !store.isCurrentEnvFileImportReview(review))
				if row.change == .changed {
					Toggle("Replace", isOn: Binding(
						get: { replacingKeys.contains(row.key) },
						set: { if $0 { replacingKeys.insert(row.key) } else { replacingKeys.remove(row.key) } }
					)).toggleStyle(.checkbox)
						.accessibilityLabel("Replace existing value for \(row.key)")
				}
			}
			if row.change == .changed {
				valueLine("Current", value: review.baseline[row.key] ?? "", revealed: revealed)
			}
			valueLine("Incoming", value: review.imported.secrets[row.key] ?? "", revealed: revealed)
		}.padding(12)
		VaultHairline()
	}

	private func valueLine(_ label: String, value: String, revealed: Bool) -> some View {
		HStack(alignment: .top, spacing: 12) {
			Text(label).font(.caption).foregroundStyle(VaultPalette.textSecondary).frame(width: 58, alignment: .leading)
			Text(revealed ? (value.isEmpty ? "(empty)" : value) : "••••••••")
				.font(.system(.callout, design: .monospaced))
				.frame(maxWidth: .infinity, alignment: .leading)
				.fixedSize(horizontal: false, vertical: true)
				.accessibilityLabel(revealed ? "\(label) value revealed visually" : "\(label) value hidden")
		}
	}

	private func toggleReveal(_ key: String) {
		if revealedKeys.remove(key) != nil { return }
		guard revealTask == nil, task == nil, summary == nil, failure == nil, !isObscured,
			store.isCurrentEnvFileImportReview(review) else { return }
		let requestID = UUID()
		let reviewID = review.id
		revealRequestID = requestID
		revealTask = Task {
			defer {
				if revealRequestID == requestID { revealTask = nil; revealRequestID = nil }
			}
			let approved = await store.authenticateForSensitiveAction(reason: "Compare imported secret values")
			guard approved, !Task.isCancelled, revealRequestID == requestID, review.id == reviewID,
				!isObscured, task == nil, summary == nil, store.isCurrentEnvFileImportReview(review)
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

	private func apply() {
		hideValues()
		let keys = replacingKeys
		task = Task {
			let result = await store.applyEnvFileImport(review, replacingKeys: keys)
			guard !Task.isCancelled else { return }
			task = nil
			switch result {
			case .success: summary = review.summary(replacing: keys)
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
