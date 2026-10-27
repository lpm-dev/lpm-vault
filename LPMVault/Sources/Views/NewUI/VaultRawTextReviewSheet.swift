import SwiftUI

/// What a Raw text edit changes, grouped as new, changed and removed keys,
/// each with a switch to leave it out, then Apply makes the rest. Values
/// stay hidden until revealed. Back to editor keeps the edit as it is.
struct VaultRawTextReviewSheet: View {
	@Bindable var store: VaultStore
	@State private var review: VaultRawTextReview
	/// Told what was saved, and how it's described, once the changes are made.
	let onApplied: (EnvironmentChangeReceipt, String) -> Void
	@Environment(\.dismiss) private var dismiss
	@Environment(\.vaultContentObscured) private var isObscured
	@State private var skipping: Set<String> = []
	@State private var revealed = false
	@State private var showsUnchanged = false
	@State private var task: Task<Void, Never>?
	@State private var failure: VaultRawTextFailure?
	/// What each new or changed value holds that's hard to see, by key.
	@State private var characters: [String: ValueCharacterChecker.Inspection] = [:]

	init(store: VaultStore, review: VaultRawTextReview, onApplied: @escaping (EnvironmentChangeReceipt, String) -> Void) {
		_store = Bindable(wrappedValue: store)
		_review = State(initialValue: review)
		self.onApplied = onApplied
	}

	private var name: String { VaultProject.displayName(for: review.target.environment) }
	private var applied: VaultEnvChanges { review.applied(skipping: skipping) }
	private var isWorking: Bool { task != nil }

	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			header
			ScrollView {
				VStack(alignment: .leading, spacing: 16) {
					counts
					if review.changes.count == 0 {
						Text("The edit matches \(name)'s values now, so there's nothing to apply.")
							.font(.system(size: 12.5))
							.foregroundStyle(VaultPalette.textTertiary)
					}
					if !review.changes.added.isEmpty {
						group("New", keys: review.changes.added, tint: VaultPalette.greenTint, text: VaultPalette.greenTintText) { key in
							"Line \(review.lines[key] ?? 0)"
						}
					}
					if !review.changes.changed.isEmpty {
						group("Changed", keys: review.changes.changed, tint: VaultPalette.orangeTint, text: VaultPalette.orangeTintText) { key in
							"Line \(review.lines[key] ?? 0) · was a different value"
						}
					}
					if !review.changes.removed.isEmpty {
						group("Removed", keys: review.changes.removed, tint: VaultPalette.redTint, text: VaultPalette.redText) { _ in
							"Line deleted · the key leaves \(name) and the Keychain"
						}
					}
					if !review.changes.unchanged.isEmpty { unchanged }
				}
				.padding(.horizontal, 24)
				.padding(.bottom, 18)
			}
			.frame(maxHeight: .infinity, alignment: .top)
			.disabled(isWorking)
			if let failure { failureNote(failure) }
			VaultSheetFooter {
				HStack(spacing: 6) {
					Image(systemName: "info.circle").accessibilityHidden(true)
					Text("Comments, blank lines and line order aren't kept.")
				}
				.font(.system(size: 11.5))
				.foregroundStyle(VaultPalette.textTertiary)
			} actions: {
				VaultBarButton(title: "Back to editor", disabled: isWorking, height: 28) { dismiss() }
					.keyboardShortcut(.cancelAction)
				VaultBarButton(title: applyTitle, filled: true, disabled: isWorking || applied.count == 0 || failure == .changed, height: 28,
					action: apply)
					.keyboardShortcut(.defaultAction)
			}
		}
		.frame(width: 600, height: 560)
		.background(VaultPalette.content)
		.task(id: review.id) { await inspectCharacters() }
		.onDisappear {
			task?.cancel()
			revealed = false
			characters = [:]
		}
		.onChange(of: store.isUnlocked) { _, unlocked in if !unlocked { dismiss() } }
		.onChange(of: store.selectedProjectId) { _, id in if id != review.target.projectId { dismiss() } }
		.onChange(of: store.selectedEnvironment) { _, environment in if environment != review.target.environment { dismiss() } }
		.onChange(of: store.selectedAccount) { _, _ in dismiss() }
		.onChange(of: isObscured) { _, obscured in if obscured { revealed = false } }
	}

	private var applyTitle: String {
		if isWorking { return "Applying…" }
		return applied.count == 0 ? "Nothing to apply" : "Apply \(applied.count.counted("change"))"
	}

	private var header: some View {
		HStack(alignment: .top, spacing: 12) {
			VStack(alignment: .leading, spacing: 3) {
				Text("Review changes to \(name)")
					.font(.system(size: 17, weight: .bold))
					.foregroundStyle(VaultPalette.textPrimary)
				Text(revealed ? "Switch off any line you don't want to apply." : "Switch off any line you don't want to apply. Values stay hidden.")
					.font(.system(size: 12.5))
					.foregroundStyle(VaultPalette.textTertiary)
			}
			Spacer(minLength: 12)
			VaultSheetCloseButton(label: "Back to editor") { dismiss() }
				.disabled(isWorking)
		}
		.padding(.horizontal, 24)
		.padding(.top, 18)
		.padding(.bottom, 14)
	}

	private var counts: some View {
		HStack(spacing: 6) {
			if !review.changes.added.isEmpty { pill("\(review.changes.added.count) new", VaultPalette.greenTint, VaultPalette.greenTintText) }
			if !review.changes.changed.isEmpty {
				pill("\(review.changes.changed.count) changed", VaultPalette.orangeTint, VaultPalette.orangeTintText)
			}
			if !review.changes.removed.isEmpty { pill("\(review.changes.removed.count) removed", VaultPalette.redTint, VaultPalette.redText) }
			if !review.changes.unchanged.isEmpty {
				pill("\(review.changes.unchanged.count) unchanged", VaultPalette.neutralTint, VaultPalette.textSecondary)
			}
			Spacer(minLength: 8)
			Button { revealed.toggle() } label: {
				Label(revealed ? "Hide values" : "Reveal values", systemImage: revealed ? "eye.slash" : "eye")
					.font(.system(size: 11.5, weight: .medium))
					.foregroundStyle(VaultPalette.textTertiary)
			}
			.buttonStyle(.plain)
			.vaultPointingHand()
			.disabled(isObscured || review.changes.count == 0)
			.help(revealed ? "Hide the values" : "Show the values to compare them")
		}
	}

	private func pill(_ title: String, _ tint: Color, _ text: Color) -> some View {
		Text(title)
			.font(.system(size: 11, weight: .semibold))
			.foregroundStyle(text)
			.padding(.horizontal, 7)
			.frame(height: 20)
			.background(RoundedRectangle(cornerRadius: 6).fill(tint))
	}

	private func group(_ title: String, keys: [String], tint: Color, text: Color, detail: @escaping (String) -> String) -> some View {
		VStack(spacing: 0) {
			HStack(spacing: 8) {
				pill(title, tint, text)
				Text(keys.count.counted("key"))
					.font(.system(size: 11.5))
					.foregroundStyle(VaultPalette.textTertiary)
				Spacer(minLength: 8)
				Text("APPLY").vaultSectionLabel()
			}
			.padding(.horizontal, 14)
			.padding(.vertical, 8)
			.background(VaultPalette.headerRow)
			VaultHairline()
			ForEach(keys, id: \.self) { key in
				row(key, removed: title == "Removed", detail: detail(key))
				if key != keys.last { VaultHairline(color: VaultPalette.rowDivider) }
			}
		}
		.background(RoundedRectangle(cornerRadius: 10).fill(VaultPalette.control))
		.clipShape(RoundedRectangle(cornerRadius: 10))
		.overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(VaultPalette.border, lineWidth: 1) }
	}

	private func row(_ key: String, removed: Bool, detail: String) -> some View {
		let applies = !skipping.contains(key)
		return HStack(alignment: .center, spacing: 10) {
			VStack(alignment: .leading, spacing: 3) {
				Text(key)
					.font(VaultTypography.tabular(12.5, .semibold))
					.foregroundStyle(removed ? VaultPalette.redText : VaultPalette.textPrimary)
					.strikethrough(removed, color: VaultPalette.redText)
					.lineLimit(1)
					.truncationMode(.middle)
				if revealed && !isObscured { values(of: key, removed: removed) }
				if !removed, let inspection = characters[key], let found = inspection.found {
					VaultValueCharacterWarning(found: found, subject: "the edited value of \(key)",
						shown: revealed && !isObscured ? inspection.shown : nil)
				}
			}
			.opacity(applies ? 1 : 0.5)
			Text(detail)
				.font(.system(size: 11.5))
				.foregroundStyle(VaultPalette.textTertiary)
				.lineLimit(1)
				.frame(maxWidth: .infinity, alignment: .leading)
			Toggle("Apply \(key)", isOn: Binding(
				get: { !skipping.contains(key) },
				set: { if $0 { skipping.remove(key) } else { skipping.insert(key) } }
			))
			.toggleStyle(.switch)
			.controlSize(.mini)
			.labelsHidden()
			.help(applies ? "Leave this change out" : "Make this change")
		}
		.padding(.horizontal, 14)
		.padding(.vertical, 9)
	}

	/// A key's value now and as edited, as far as each is there.
	@ViewBuilder
	private func values(of key: String, removed: Bool) -> some View {
		let before = review.current[key]
		let after = review.edited[key]
		HStack(spacing: 6) {
			if let before {
				Text(before.isEmpty ? "(empty)" : before)
					.strikethrough(after != nil || removed)
					.foregroundStyle(VaultPalette.textFaint)
					.accessibilityLabel("Value for \(key) now, \(before)")
			}
			if before != nil, after != nil {
				Image(systemName: "arrow.right").font(.system(size: 8, weight: .bold)).foregroundStyle(VaultPalette.textFaint)
					.accessibilityHidden(true)
			}
			if let after {
				Text(after.isEmpty ? "(empty)" : after)
					.foregroundStyle(VaultPalette.textPrimary)
					.accessibilityLabel("Edited value for \(key), \(after)")
			}
		}
		.font(VaultTypography.code(11.5))
		.lineLimit(1)
		.truncationMode(.tail)
	}

	private var unchanged: some View {
		VStack(alignment: .leading, spacing: 0) {
			Button { showsUnchanged.toggle() } label: {
				HStack(spacing: 8) {
					pill("Unchanged", VaultPalette.neutralTint, VaultPalette.textSecondary)
					Text(review.changes.unchanged.joined(separator: ", "))
						.font(.system(size: 11.5))
						.foregroundStyle(VaultPalette.textTertiary)
						.lineLimit(1)
						.truncationMode(.tail)
						.frame(maxWidth: .infinity, alignment: .leading)
					Image(systemName: showsUnchanged ? "chevron.up" : "chevron.down")
						.font(.system(size: 10, weight: .semibold))
						.foregroundStyle(VaultPalette.textTertiary)
						.accessibilityHidden(true)
				}
				.padding(.horizontal, 14)
				.padding(.vertical, 8)
				.contentShape(Rectangle())
			}
			.buttonStyle(.plain)
			.vaultPointingHand()
			.help(showsUnchanged ? "Hide the unchanged keys" : "List the unchanged keys")
			if showsUnchanged {
				VaultHairline()
				ForEach(review.changes.unchanged, id: \.self) { key in
					Text(key)
						.font(VaultTypography.tabular(12))
						.foregroundStyle(VaultPalette.textSecondary)
						.padding(.horizontal, 14)
						.padding(.vertical, 5)
				}
				.padding(.vertical, 4)
			}
		}
		.background(RoundedRectangle(cornerRadius: 10).fill(VaultPalette.control))
		.clipShape(RoundedRectangle(cornerRadius: 10))
		.overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(VaultPalette.border, lineWidth: 1) }
	}

	private func failureNote(_ failure: VaultRawTextFailure) -> some View {
		HStack(spacing: 8) {
			switch failure {
			case .changed:
				Text("\(name) changed meanwhile, as by the LPM CLI, so nothing was saved.")
				Spacer(minLength: 8)
				VaultBarButton(title: "Review again", height: 26, action: reviewAgain)
			case .failed(let message):
				Text(message)
				Spacer(minLength: 0)
			}
		}
		.font(.system(size: 11.5))
		.foregroundStyle(VaultPalette.redText)
		.lineLimit(2)
		.padding(.horizontal, 24)
		.padding(.bottom, 12)
	}

	private func apply() {
		guard task == nil, applied.count > 0, failure != .changed else { return }
		failure = nil
		let summary = applied.summary
		let review = review
		let skipping = skipping
		task = Task {
			defer { task = nil }
			switch await store.applyRawTextReview(review, skipping: skipping) {
			case .saved(let receipt):
				onApplied(receipt, summary)
				dismiss()
			case .changed: failure = .changed
			case .unavailable: dismiss()
			case .failed(let message): failure = .failed(message)
			}
		}
	}

	/// Checks the edit's new and changed values, the ones applying writes.
	private func inspectCharacters() async {
		let written = Set(review.changes.added + review.changes.changed)
		let values = review.edited.filter { written.contains($0.key) }
		guard let inspections = await store.characterChecker.inspect(values: values), !Task.isCancelled else { return }
		characters = inspections
	}

	/// Compares the edit with the environment's values now, choosing every change again.
	private func reviewAgain() {
		guard let fresh = store.reviewRawTextDraft(review.target) else { return dismiss() }
		review = fresh
		skipping = []
		revealed = false
		failure = nil
	}
}
