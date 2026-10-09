import SwiftUI

/// The review before a schema draft is written into lpm.json: each change as
/// lines of the file, and what it does to the values stored in each environment.
struct VaultSchemaReviewSheet: View {
	@Bindable var store: VaultStore
	let project: VaultProject
	let environments: [String]
	@Environment(\.dismiss) private var dismiss

	@State private var submitting = false
	@State private var error: String?
	/// The review as first shown, which tells whether it changed while open.
	@State private var shown: ProjectEnvSchemaReview?
	/// Lists of effects that show in full: a changed item's, or the other keys'.
	@State private var expanded: Set<ProjectEnvSchemaDraft.Item?> = []

	/// Effects an item shows before "Show all".
	private static let effectLimit = 12

	private var saving: Bool { submitting || store.savingSchemaDrafts.contains(project.id) }

	var body: some View {
		let draft = store.schemaDraft(for: project.id)
		let review = store.schemaDraftReview(for: project.id, environments: environments)
		let changedWhileOpen = shown != nil && review != nil && review != shown
		let clash = store.schemaDraftCaseClash(for: project.id)
		let blocked = saving || review == nil || review?.values == .checking || draft?.conflicts.isEmpty == false || clash != nil
		VStack(alignment: .leading, spacing: 0) {
			HStack(alignment: .top, spacing: 12) {
				VStack(alignment: .leading, spacing: 4) {
					Text("Review changes to lpm.json")
						.font(.system(size: 17, weight: .bold))
						.foregroundStyle(VaultPalette.textPrimary)
					Text("Plain text, shared with the team. The LPM CLI enforces these rules on its next run.")
						.font(.system(size: 12.5))
						.foregroundStyle(VaultPalette.textTertiary)
						.fixedSize(horizontal: false, vertical: true)
				}
				Spacer(minLength: 8)
				VaultSheetCloseButton { dismiss() }
					.keyboardShortcut(.cancelAction)
			}
			.padding(20)

			VaultHairline()

			ScrollView {
				LazyVStack(alignment: .leading, spacing: 18) {
					if let draft, !draft.conflicts.isEmpty {
						message("Choose a version for each change that conflicts with lpm.json first. The banner on the Schema page lists them.")
					} else if let review {
						if let clash {
							problem("Can't save: \(clash.message)")
						}
						if let summary = review.warningSummary {
							problem(summary)
						}
						if changedWhileOpen {
							notice("This review changed while it was open, because lpm.json, its imports, or the stored values changed. Check it again before saving.")
						}
						HStack(spacing: 8) {
							Text(review.items.count == 1 ? "1 CHANGE" : "\(review.items.count) CHANGES").vaultSectionLabel()
							Text("effects name problems only — values are never shown")
								.font(.system(size: 11))
								.foregroundStyle(VaultPalette.textTertiary)
						}
						ForEach(review.items) { itemView($0, values: review.values) }
						if review.values == .checked, !review.others.isEmpty || review.othersUnchanged > 0 {
							VStack(alignment: .leading, spacing: 6) {
								Text("OTHER KEYS").vaultSectionLabel()
								effectsView(review.others, unchanged: review.othersUnchanged, item: nil)
							}
						}
					} else if let rejection = store.currentSchemaDraftEvaluation(for: project.id)?.rejection {
						message("The LPM CLI would reject these rules: \(rejection.reason)")
					} else {
						HStack(spacing: 8) {
							ProgressView().controlSize(.small)
							Text("Checking the rules…").font(.system(size: 12)).foregroundStyle(VaultPalette.textTertiary)
						}
					}
				}
				.padding(20)
				.frame(maxWidth: .infinity, alignment: .leading)
			}
			.frame(maxHeight: 520)

			VaultSheetFooter {
				if let error {
					Text(error)
						.font(.system(size: 11.5))
						.foregroundStyle(VaultPalette.redText)
						.fixedSize(horizontal: false, vertical: true)
				} else if review?.values == .checking {
					Text("Checking the stored values…")
						.font(.system(size: 11.5))
						.foregroundStyle(VaultPalette.textTertiary)
				} else {
					Text("Nothing is written until you choose Save.")
						.font(.system(size: 11.5))
						.foregroundStyle(VaultPalette.textTertiary)
				}
			} actions: {
				VaultBarButton(title: (draft?.changeCount ?? 0) > 1 ? "Discard all" : "Discard", disabled: saving || draft == nil, height: 28) {
					store.discardSchemaDraft(in: project.id)
					dismiss()
				}
				// A review that changed while open, or gives up Secret, saves only with a click, not Return.
				if changedWhileOpen || review?.warningSummary != nil {
					VaultBarButton(title: saving ? "Saving…" : "Save to lpm.json", filled: true, disabled: blocked, height: 28, action: save)
				} else {
					VaultBarButton(title: saving ? "Saving…" : "Save to lpm.json", shortcut: "⏎", filled: true, disabled: blocked, height: 28, action: save)
						.keyboardShortcut(.defaultAction)
				}
			}
		}
		.frame(width: 580)
		.background(VaultPalette.content)
		.onAppear { shown = review }
		.onChange(of: review) { old, new in
			if shown == nil { shown = new }
			if old != new, !submitting { error = nil }
		}
		.onChange(of: draft == nil) { _, ended in if ended, !submitting { dismiss() } }
	}

	private func message(_ text: String) -> some View {
		Text(text)
			.font(.system(size: 12.5))
			.foregroundStyle(VaultPalette.textSecondary)
			.fixedSize(horizontal: false, vertical: true)
	}

	private func problem(_ text: String) -> some View {
		HStack(alignment: .top, spacing: 8) {
			Image(systemName: "xmark.circle").font(.system(size: 11)).padding(.top, 1)
			Text(text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
		}
		.foregroundStyle(VaultPalette.redText)
		.padding(10)
		.frame(maxWidth: .infinity, alignment: .leading)
		.background(RoundedRectangle(cornerRadius: 8).fill(VaultPalette.redTint))
	}

	private func notice(_ text: String) -> some View {
		HStack(alignment: .top, spacing: 8) {
			Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 11)).padding(.top, 1)
			Text(text).font(.system(size: 11.5)).fixedSize(horizontal: false, vertical: true)
		}
		.foregroundStyle(VaultPalette.orangeTintText)
		.padding(10)
		.frame(maxWidth: .infinity, alignment: .leading)
		.background(RoundedRectangle(cornerRadius: 8).fill(VaultPalette.orangeTint))
	}

	private func save() {
		error = nil
		submitting = true
		Task {
			defer {
				submitting = false
				if store.schemaDraft(for: project.id) == nil { dismiss() }
			}
			do throws(ProjectEnvSchemaFile.DraftSaveError) {
				try await store.saveSchemaDraft(in: project.id)
			} catch .file(.changed) {
				// The merge left conflicts; the Schema page's banner settles them.
				if store.schemaDraft(for: project.id)?.conflicts.isEmpty == false {
					dismiss()
				} else {
					error = "lpm.json changed on disk. Your changes were merged with it; check them again, then save."
				}
			} catch .conflicts {
				dismiss()
			} catch .inProgress {
			} catch {
				self.error = error.message
			}
		}
	}

	// MARK: - Items

	private func itemView(_ item: ProjectEnvSchemaReview.Item, values: ProjectEnvSchemaReview.Values) -> some View {
		VStack(alignment: .leading, spacing: 7) {
			HStack(spacing: 7) {
				switch item.item {
				case .group: Image(systemName: "square.stack.3d.up").font(.system(size: 11)).foregroundStyle(VaultPalette.textTertiary)
				case .clientPrefixes: Image(systemName: "globe").font(.system(size: 11)).foregroundStyle(VaultPalette.publicText)
				case .key: EmptyView()
				}
				Text(item.title)
					.font(VaultTypography.mono(12.5, .bold))
					.foregroundStyle(VaultPalette.textPrimary)
				stateBadge(item.state)
				Text(item.diff.path)
					.font(VaultTypography.mono(10.5))
					.foregroundStyle(VaultPalette.textFaint)
					.lineLimit(1)
					.truncationMode(.middle)
			}
			if let warning = item.warning {
				HStack(alignment: .top, spacing: 6) {
					Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10)).padding(.top, 1)
					Text(warning).font(.system(size: 11.5, weight: .medium)).fixedSize(horizontal: false, vertical: true)
				}
				.foregroundStyle(VaultPalette.redText)
				.padding(9)
				.frame(maxWidth: .infinity, alignment: .leading)
				.background(RoundedRectangle(cornerRadius: 7).fill(VaultPalette.redTint))
				.accessibilityElement(children: .combine)
			}
			if let note = note(for: item) {
				HStack(alignment: .top, spacing: 6) {
					Image(systemName: "square.stack.3d.up").font(.system(size: 10)).padding(.top, 1)
					Text(note).font(.system(size: 11.5)).fixedSize(horizontal: false, vertical: true)
				}
				.foregroundStyle(VaultPalette.accentText)
				.padding(9)
				.frame(maxWidth: .infinity, alignment: .leading)
				.background(RoundedRectangle(cornerRadius: 7).fill(VaultPalette.accentTint))
			}
			diffView(item.diff)
			switch values {
			case .checked:
				effectsView(item.effects, unchanged: item.unchanged, item: item.item)
			case .checking:
				Text("Checking the stored values…")
					.font(.system(size: 11.5))
					.foregroundStyle(VaultPalette.textTertiary)
			case .unchecked:
				Text("Stored values weren't checked: the project's values aren't loaded, or the rules are too large to check here.")
					.font(.system(size: 11.5))
					.foregroundStyle(VaultPalette.textTertiary)
					.fixedSize(horizontal: false, vertical: true)
			}
		}
		.accessibilityElement(children: .contain)
	}

	private func note(for item: ProjectEnvSchemaReview.Item) -> String? {
		if case .group(let name) = item.item, let draft = store.schemaDraft(for: project.id) {
			if let original = draft.originalName(ofGroup: name) { return "Renamed from \(original.escapingDirectionControls); it keeps its place in lpm.json." }
			if let renamed = draft.newName(ofGroup: name) { return "Renamed to \(renamed.escapingDirectionControls)." }
		}
		return switch item.state {
		case .override(let source): "Adds an override. The rule from \(source) is replaced, not merged."
		case .resetOverride(let source): "Removes the override, so the rule from \(source) applies again."
		default: item.diff.previousPath.map { "Moves from \($0)." }
		}
	}

	@ViewBuilder
	private func stateBadge(_ state: ProjectEnvSchemaReview.State) -> some View {
		switch state {
		case .changed, .resetOverride: VaultTagBadge(text: "Draft", foreground: VaultPalette.orangeTintText, background: VaultPalette.orangeTint, size: 10)
		case .new: VaultTagBadge(text: "New", foreground: VaultPalette.orangeTintText, background: VaultPalette.orangeTint, size: 10)
		case .override: VaultTagBadge(text: "Override", foreground: VaultPalette.accentForeground, background: VaultPalette.accentTint, size: 10)
		case .removed: VaultTagBadge(text: "Removed", foreground: VaultPalette.redText, background: VaultPalette.redTint, size: 10)
		}
	}

	private func diffView(_ diff: ProjectEnvSchemaDraft.Diff) -> some View {
		VStack(alignment: .leading, spacing: 0) {
			ForEach(Array(diff.lines.enumerated()), id: \.offset) { _, line in
				HStack(alignment: .top, spacing: 8) {
					Text(marker(line.kind))
						.frame(width: 10, alignment: .leading)
						.foregroundStyle(tint(line.kind))
					Text(line.text)
						.foregroundStyle(line.kind == .unchanged || line.kind == .omitted ? VaultPalette.textTertiary : VaultPalette.textPrimary)
						.italic(line.kind == .omitted)
						.fixedSize(horizontal: false, vertical: true)
				}
				.font(VaultTypography.mono(11))
				.padding(.horizontal, 10)
				.padding(.vertical, 1.5)
				.frame(maxWidth: .infinity, alignment: .leading)
				.background(background(line.kind))
			}
		}
		.padding(.vertical, 6)
		.textSelection(.enabled)
		.background(RoundedRectangle(cornerRadius: 8).fill(VaultPalette.control))
		.overlay { RoundedRectangle(cornerRadius: 8).stroke(VaultPalette.border, lineWidth: 1) }
		.clipShape(RoundedRectangle(cornerRadius: 8))
		.accessibilityElement(children: .combine)
		.accessibilityLabel("Changes to lpm.json")
	}

	private func marker(_ kind: ProjectEnvSchemaDraft.Diff.Line.Kind) -> String {
		switch kind {
		case .added: "+"
		case .removed: "−"
		case .unchanged: ""
		case .omitted: "…"
		}
	}

	private func tint(_ kind: ProjectEnvSchemaDraft.Diff.Line.Kind) -> Color {
		switch kind {
		case .added: VaultPalette.greenTintText
		case .removed: VaultPalette.redText
		default: VaultPalette.textFaint
		}
	}

	private func background(_ kind: ProjectEnvSchemaDraft.Diff.Line.Kind) -> Color {
		switch kind {
		case .added: VaultPalette.greenTint
		case .removed: VaultPalette.redTint
		default: .clear
		}
	}

	private func effectsView(_ effects: [ProjectEnvSchemaReview.Effect], unchanged: Int, item: ProjectEnvSchemaDraft.Item?) -> some View {
		let limit = expanded.contains(item) ? effects.count : Self.effectLimit
		return LazyVStack(alignment: .leading, spacing: 0) {
			if effects.isEmpty, unchanged == 0 {
				Text("No change to stored values")
					.font(.system(size: 11.5))
					.foregroundStyle(VaultPalette.textTertiary)
					.padding(.horizontal, 11)
					.padding(.vertical, 8)
			}
			ForEach(Array(effects.prefix(limit).enumerated()), id: \.offset) { index, effect in
				HStack(alignment: .top, spacing: 8) {
					VaultStatusDot(color: environmentColor(effect.environment)).padding(.top, 5)
					Text(VaultProject.displayName(for: effect.environment))
						.font(VaultTypography.mono(11))
						.foregroundStyle(VaultPalette.textSecondary)
						.frame(width: 96, alignment: .leading)
						.lineLimit(1)
						.truncationMode(.middle)
					HStack(spacing: 4) {
						Image(systemName: symbol(effect.kind)).font(.system(size: 10, weight: .semibold))
						Text(title(effect.kind)).font(.system(size: 11.5, weight: .semibold))
					}
					.foregroundStyle(effectTint(effect.kind))
					.fixedSize()
					Text("· " + effect.message)
						.font(.system(size: 11.5))
						.foregroundStyle(VaultPalette.textTertiary)
						.fixedSize(horizontal: false, vertical: true)
				}
				.padding(.horizontal, 11)
				.padding(.vertical, 7)
				.frame(maxWidth: .infinity, alignment: .leading)
				.overlay(alignment: .top) { if index > 0 { VaultHairline() } }
				.accessibilityElement(children: .combine)
			}
			if effects.count > limit {
				Button {
					expanded.insert(item)
				} label: {
					Text("Show \(effects.count - limit) more")
						.font(.system(size: 11.5, weight: .semibold))
						.foregroundStyle(VaultPalette.accentForeground)
						.padding(.horizontal, 11)
						.padding(.vertical, 7)
						.frame(maxWidth: .infinity, alignment: .leading)
						.contentShape(Rectangle())
				}
				.buttonStyle(.plain)
				.overlay(alignment: .top) { VaultHairline() }
			}
			if unchanged > 0 {
				HStack(spacing: 6) {
					Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).foregroundStyle(VaultPalette.textFaint)
					Text(unchanged == 1 ? "1 problem already there, not caused by this change" : "\(unchanged) problems already there, not caused by this change")
						.font(.system(size: 11.5))
						.foregroundStyle(VaultPalette.textTertiary)
				}
				.padding(.horizontal, 11)
				.padding(.vertical, 7)
				.frame(maxWidth: .infinity, alignment: .leading)
				.overlay(alignment: .top) { if !effects.isEmpty { VaultHairline() } }
			}
		}
		.frame(maxWidth: .infinity, alignment: .leading)
		.overlay { RoundedRectangle(cornerRadius: 8).stroke(VaultPalette.border, lineWidth: 1) }
	}

	private func environmentColor(_ environment: String) -> Color {
		VaultPalette.environment(environments.firstIndex(of: environment) ?? environments.count)
	}

	private func symbol(_ kind: ProjectEnvSchemaReview.Effect.Kind) -> String {
		switch kind {
		case .newlyFailing: "xmark.circle"
		case .nowPasses: "checkmark"
		case .noLongerChecked: "minus.circle"
		case .defaultChanged: "arrow.triangle.2.circlepath"
		}
	}

	private func title(_ kind: ProjectEnvSchemaReview.Effect.Kind) -> String {
		switch kind {
		case .newlyFailing: "Newly failing"
		case .nowPasses: "Now passes"
		case .noLongerChecked: "No longer checked"
		case .defaultChanged: "Default"
		}
	}

	private func effectTint(_ kind: ProjectEnvSchemaReview.Effect.Kind) -> Color {
		switch kind {
		case .newlyFailing: VaultPalette.redText
		case .nowPasses: VaultPalette.greenTintText
		case .noLongerChecked, .defaultChanged: VaultPalette.textTertiary
		}
	}
}
