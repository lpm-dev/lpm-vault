import SwiftUI

struct AddVariableSheet: View {
	@Bindable var store: VaultStore
	let projectId: String
	@Environment(\.dismiss) private var dismiss

	@State private var draft: AddVariableDraft
	@State private var value = ""
	@State private var isValueRevealed = false
	@State private var submitTask: Task<Void, Never>?
	@State private var submitError: String?
	@State private var lastAddedKey: String?
	/// The highlighted declared-key suggestion.
	@State private var highlightedSuggestion = 0
	/// Hides the suggestions until the key changes from `suggestionsHiddenFor`.
	@State private var suggestionsHiddenFor: String?
	@FocusState private var focusedField: Field?

	private enum Field: Hashable {
		case key, value
	}

	init(store: VaultStore, projectId: String, environment: String, initialKey: String = "", initialValueRevealed: Bool = false) {
		self.store = store
		self.projectId = projectId
		_isValueRevealed = State(initialValue: initialValueRevealed)
		let project = store.projects.first { $0.id == projectId }
		let environments = project.map(store.orderedEnvironmentNames(for:)) ?? []
		let initialEnvironment = environments.contains(environment) ? environment : environments.first
		_draft = State(initialValue: Self.makeDraft(
			store: store,
			project: project,
			key: initialKey,
			selection: initialEnvironment.map { [$0] } ?? []
		))
	}

	private var project: VaultProject? {
		store.projects.first { $0.id == projectId }
	}

	private var isSubmitting: Bool { submitTask != nil }

	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			header
			VaultHairline()
			VStack(alignment: .leading, spacing: 18) {
				keyField
				valueField
				environmentsField
				if let submitError {
					Text(submitError)
						.font(.system(size: 11.5))
						.foregroundStyle(VaultPalette.redText)
						.lineLimit(3)
						.help(submitError)
						.fixedSize(horizontal: false, vertical: true)
				}
			}
			.padding(.horizontal, 24)
			.padding(.vertical, 20)
			footer
		}
		.frame(width: 560)
		.background(VaultPalette.content)
		.overlayPreferenceValue(KeyFieldBounds.self) { anchor in
			let suggestions = suggestions
			if let anchor, !suggestions.isEmpty {
				GeometryReader { sheet in
					// Drawn over the whole sheet so the list can cover the footer, and
					// bounded by the sheet's bottom edge, which would otherwise clip it.
					let field = sheet[anchor].insetBy(dx: -1, dy: 0)
					suggestionList(suggestions)
						.frame(width: field.width)
						.frame(maxHeight: max(0, sheet.size.height - field.maxY - 16), alignment: .top)
						.offset(x: field.minX, y: field.maxY + 4)
				}
			}
		}
		.interactiveDismissDisabled(isSubmitting)
		.onKeyPress(.return, phases: .down, action: handleReturn)
		.onAppear { focusedField = .key }
		.onChange(of: draft.key) { _, key in
			submitError = nil
			if !key.isEmpty { lastAddedKey = nil }
			highlightedSuggestion = 0
			if key != suggestionsHiddenFor { suggestionsHiddenFor = nil }
		}
		.onChange(of: draft.selection) { _, _ in submitError = nil }
		.onChange(of: value) { _, _ in submitError = nil }
		.onChange(of: project?.workspaceSnapshotIdentity) { _, _ in refreshDraft() }
		.onChange(of: store.isUnlocked) { _, unlocked in if !unlocked { dismissAndClear() } }
		.onChange(of: store.selectedProjectId) { _, id in if id != projectId { dismissAndClear() } }
		.onDisappear {
			submitTask?.cancel()
			value = ""
		}
	}

	// MARK: - Sections

	private var header: some View {
		HStack(alignment: .top, spacing: 12) {
			VStack(alignment: .leading, spacing: 3) {
				Text("Add variable")
					.font(.system(size: 17, weight: .bold))
					.foregroundStyle(VaultPalette.textPrimary)
				Text("to \(Text(project?.name ?? "").fontWeight(.semibold).foregroundStyle(VaultPalette.textSecondary)) · stored encrypted locally")
					.font(.system(size: 12.5))
					.foregroundStyle(VaultPalette.textTertiary)
					.lineLimit(1)
			}
			Spacer(minLength: 12)
			VaultSheetCloseButton(action: close)
				.disabled(isSubmitting)
		}
		.padding(.horizontal, 24)
		.padding(.top, 20)
		.padding(.bottom, 16)
	}

	/// The project's rules, when its lpm.json was read.
	private var overview: ProjectEnvSchemaOverview? {
		store.keyDescriptions[projectId]?.schema?.overview
	}

	private var suggestions: [ProjectEnvSchemaOverview.Rule] {
		guard focusedField == .key, suggestionsHiddenFor == nil, let overview, let project else { return [] }
		return overview.suggestions(matching: draft.key, unsetIn: draft.selection, of: project)
	}

	private var keyField: some View {
		let suggestions = suggestions
		return VStack(alignment: .leading, spacing: 7) {
			HStack(spacing: 8) {
				VaultFieldLabel(title: "Key")
				Spacer()
				if let rule = overview?.rule(for: draft.key) {
					Label("declared in \(rule.source ?? "lpm.json")", systemImage: "doc")
						.font(.system(size: 11))
						.foregroundStyle(VaultPalette.textTertiary)
						.lineLimit(1)
						.truncationMode(.middle)
				}
			}
			TextField("DATABASE_URL", text: $draft.key)
				.textFieldStyle(.plain)
				.font(VaultTypography.mono(13))
				.foregroundStyle(VaultPalette.textPrimary)
				.autocorrectionDisabled()
				.focused($focusedField, equals: .key)
				.disabled(isSubmitting)
				.onKeyPress(.return, phases: .down, action: handleReturn)
				.onKeyPress(.downArrow) { moveSuggestion(by: 1, in: suggestions) }
				.onKeyPress(.upArrow) { moveSuggestion(by: -1, in: suggestions) }
				.onKeyPress(.escape) {
					guard !suggestions.isEmpty else { return .ignored }
					suggestionsHiddenFor = draft.key
					return .handled
				}
				.onSubmit { focusedField = .value }
				.padding(.horizontal, 12)
				.frame(height: 36)
				.vaultInputField(focused: focusedField == .key, invalid: draft.keyIssue != nil)
				.accessibilityLabel("Key")
				.anchorPreference(key: KeyFieldBounds.self, value: .bounds) { $0 }
			if let issue = draft.keyIssue {
				Text(issue.message)
					.font(.system(size: 11.5))
					.foregroundStyle(VaultPalette.redText)
					.lineLimit(3)
					.help(issue.message)
					.fixedSize(horizontal: false, vertical: true)
			}
		}
	}

	/// Declared keys not set in the selected environments, picked by click or Return.
	/// The rows scroll when the sheet is too short to show them all.
	private func suggestionList(_ suggestions: [ProjectEnvSchemaOverview.Rule]) -> some View {
		let target = draft.selection.count == 1 ? draft.selection.first.map(VaultProject.displayName(for:))?.uppercased() ?? "" : "EVERY SELECTED ENV"
		return VStack(alignment: .leading, spacing: 2) {
			Text("DECLARED, NOT SET IN \(target)")
				.vaultSectionLabel()
				.lineLimit(1)
				.padding(.horizontal, 10)
				.padding(.top, 6)
				.padding(.bottom, 4)
			ViewThatFits(in: .vertical) {
				suggestionRows(suggestions)
				ScrollViewReader { scroller in
					ScrollView(.vertical) { suggestionRows(suggestions) }
						.onAppear { scrollToHighlight(in: suggestions, with: scroller) }
						.onChange(of: highlightedSuggestion) { _, _ in scrollToHighlight(in: suggestions, with: scroller) }
				}
			}
			VaultHairline().padding(.horizontal, 8).padding(.vertical, 2)
			SuggestionButton {
				suggestionsHiddenFor = draft.key
				focusedField = .value
			} label: {
				Label("Create \(draft.key.trimmingCharacters(in: .whitespaces)) as a new key", systemImage: "plus")
					.font(.system(size: 12))
					.foregroundStyle(VaultPalette.textSecondary)
					.lineLimit(1)
					.truncationMode(.middle)
			}
		}
		.padding(6)
		.frame(maxWidth: .infinity, alignment: .leading)
		.background(RoundedRectangle(cornerRadius: 10).fill(VaultPalette.control))
		.overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(VaultPalette.border))
		.shadow(color: VaultPalette.shadow.opacity(0.22), radius: 14, y: 8)
	}

	private func scrollToHighlight(in suggestions: [ProjectEnvSchemaOverview.Rule], with scroller: ScrollViewProxy) {
		guard suggestions.indices.contains(highlightedSuggestion) else { return }
		scroller.scrollTo(suggestions[highlightedSuggestion].key)
	}

	private func suggestionRows(_ suggestions: [ProjectEnvSchemaOverview.Rule]) -> some View {
		VStack(alignment: .leading, spacing: 2) {
			ForEach(Array(suggestions.enumerated()), id: \.element.key) { index, rule in
				SuggestionButton(isHighlighted: index == highlightedSuggestion) { pickSuggestion(rule.key) } label: {
					HStack(spacing: 8) {
						Text(rule.key)
							.font(VaultTypography.mono(12.5, .semibold))
							.foregroundStyle(VaultPalette.textPrimary)
							.lineLimit(1)
							.truncationMode(.middle)
						if rule.isPublic { VaultPublicBadge(compact: true) }
						ForEach(rule.badges.prefix(2), id: \.self) { VaultRuleBadge(badge: $0) }
						if rule.badges.isEmpty, !rule.isPublic {
							Text("no rules")
								.font(.system(size: 11).italic())
								.foregroundStyle(VaultPalette.textFaint)
						}
						Spacer(minLength: 4)
						if index == highlightedSuggestion {
							Image(systemName: "return")
								.font(.system(size: 10, weight: .semibold))
								.foregroundStyle(VaultPalette.textFaint)
						}
					}
				}
				.accessibilityLabel("\(rule.key), declared")
				.id(rule.key)
			}
		}
	}

	private var valueField: some View {
		VStack(alignment: .leading, spacing: 7) {
			HStack(spacing: 8) {
				VaultFieldLabel(title: "Value")
				if let rule = overview?.rule(for: draft.key) {
					ruleSummary(rule)
				} else {
					VaultTagBadge(
						text: "SECRET",
						foreground: VaultPalette.accentForeground,
						background: VaultPalette.accentTint
					)
				}
				Spacer()
				if !value.isEmpty {
					Text(value.count == 1 ? "1 char" : "\(value.count) chars")
						.font(.system(size: 11))
						.foregroundStyle(VaultPalette.textFaint)
						.monospacedDigit()
				}
			}
			HStack(spacing: 6) {
				Group {
					if isValueRevealed {
						TextField("Paste a value or generate one", text: $value)
					} else {
						SecureField("Paste a value or generate one", text: $value)
					}
				}
				.textFieldStyle(.plain)
				.font(VaultTypography.mono(12.5))
				.foregroundStyle(VaultPalette.textPrimary)
				.autocorrectionDisabled()
				.focused($focusedField, equals: .value)
				.disabled(isSubmitting)
				.onKeyPress(.return, phases: .down, action: handleReturn)
				.onSubmit { submit(keepOpen: false) }
				.accessibilityLabel("Value")

				FieldIconButton(
					systemImage: isValueRevealed ? "eye.slash" : "eye",
					label: isValueRevealed ? "Hide value" : "Show value"
				) {
					isValueRevealed.toggle()
					focusedField = .value
				}

				SecretGeneratorButton(disabled: isSubmitting) { generated in
					value = generated
					isValueRevealed = true
				}
			}
			.padding(.leading, 12)
			.padding(.trailing, 4)
			.frame(height: 36)
			.vaultInputField(focused: focusedField == .value)
		}
	}

	/// A declared key's rules beside the value: a few badges, the rest in a tooltip.
	private func ruleSummary(_ rule: ProjectEnvSchemaOverview.Rule) -> some View {
		let shown = rule.badges.prefix(3)
		let hidden = rule.badges.dropFirst(3)
		return HStack(spacing: 5) {
			if rule.isPublic { VaultPublicBadge() }
			ForEach(Array(shown), id: \.self) { VaultRuleBadge(badge: $0) }
			if !hidden.isEmpty {
				Text("+\(hidden.count)")
					.font(.system(size: 11))
					.foregroundStyle(VaultPalette.textTertiary)
					.help(hidden.map(\.text).joined(separator: "\n"))
			}
			if rule.badges.isEmpty, !rule.isPublic {
				Text("no rules")
					.font(.system(size: 11).italic())
					.foregroundStyle(VaultPalette.textFaint)
			}
		}
		.lineLimit(1)
	}

	private var environmentsField: some View {
		VStack(alignment: .leading, spacing: 7) {
			HStack(spacing: 8) {
				VaultFieldLabel(title: "Environments")
				Spacer()
				if draft.environments.count > 1 {
					Button(draft.allSelected ? "Clear" : "Select all") { draft.toggleAll() }
						.buttonStyle(.plain)
						.font(.system(size: 11))
						.foregroundStyle(VaultPalette.accentForeground)
						.disabled(isSubmitting)
						.vaultPointingHand()
				}
			}
			ScrollView(.vertical) {
				LazyVGrid(
					columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3),
					alignment: .leading,
					spacing: 8
				) {
					ForEach(Array(draft.environments.enumerated()), id: \.element) { index, environment in
						Toggle(isOn: selectionBinding(for: environment)) {
							Text(VaultProject.displayName(for: environment))
						}
						.toggleStyle(EnvironmentChipToggleStyle(
							color: VaultPalette.environment(index),
							hasConflict: draft.selection.contains(environment) && draft.conflicts(in: environment)
						))
						.disabled(isSubmitting)
						.help(VaultProject.displayName(for: environment))
					}
				}
			}
			.frame(height: min(156, max(33, CGFloat((draft.environments.count + 2) / 3) * 41 - 8)))
			Text("Same value in each selected file. You can change them per environment later.")
				.font(.system(size: 11))
				.foregroundStyle(VaultPalette.textFaint)
				.fixedSize(horizontal: false, vertical: true)
		}
	}

	private var footer: some View {
		VaultSheetFooter {
			if let lastAddedKey {
				Label("Added \(lastAddedKey)", systemImage: "checkmark.circle.fill")
					.font(.system(size: 11.5))
					.foregroundStyle(VaultPalette.greenTintText)
					.lineLimit(1)
					.truncationMode(.middle)
			} else {
				Text("⇧⏎ adds and keeps the sheet open")
					.font(.system(size: 11.5))
					.foregroundStyle(VaultPalette.textTertiary)
					.lineLimit(1)
			}
		} actions: {
			VaultBarButton(title: "Cancel", disabled: isSubmitting, height: 30, action: close)
				.keyboardShortcut(.cancelAction)
			VaultBarButton(
				title: isSubmitting ? "Adding…" : draft.submitTitle,
				shortcut: "⏎",
				filled: true,
				disabled: !draft.canSubmit || isSubmitting,
				height: 30
			) { submit(keepOpen: false) }
			.keyboardShortcut(.defaultAction)
		}
	}

	// MARK: - Actions

	private func selectionBinding(for environment: String) -> Binding<Bool> {
		Binding(
			get: { draft.selection.contains(environment) },
			set: { selected in
				if selected { draft.selection.insert(environment) } else { draft.selection.remove(environment) }
			}
		)
	}

	private func handleReturn(_ press: KeyPress) -> KeyPress.Result {
		let modifiers = press.modifiers.intersection([.shift, .control, .option, .command])
		let suggestions = suggestions
		if modifiers.isEmpty, suggestions.indices.contains(highlightedSuggestion) {
			pickSuggestion(suggestions[highlightedSuggestion].key)
			return .handled
		}
		guard modifiers == .shift else { return .ignored }
		submit(keepOpen: true)
		return .handled
	}

	private func moveSuggestion(by offset: Int, in suggestions: [ProjectEnvSchemaOverview.Rule]) -> KeyPress.Result {
		guard !suggestions.isEmpty else { return .ignored }
		highlightedSuggestion = (highlightedSuggestion + offset + suggestions.count) % suggestions.count
		return .handled
	}

	private func pickSuggestion(_ key: String) {
		suggestionsHiddenFor = key
		draft.key = key
		focusedField = .value
	}

	private func submit(keepOpen: Bool) {
		guard draft.canSubmit, !isSubmitting else { return }
		let key = draft.key
		let submittedValue = value
		let environments = draft.selection
		submitError = nil
		submitTask = Task {
			let result = await store.addSecret(
				to: projectId,
				environments: environments,
				key: key,
				value: submittedValue
			)
			guard !Task.isCancelled else { return }
			submitTask = nil
			switch result {
			case .success where keepOpen:
				draft.key = ""
				value = ""
				isValueRevealed = false
				lastAddedKey = key
				refreshDraft()
				focusedField = .key
			case .success:
				close()
			case .failure(let error):
				submitError = error.localizedDescription
			}
		}
	}

	private func refreshDraft() {
		draft = Self.makeDraft(store: store, project: project, key: draft.key, selection: draft.selection)
	}

	private func close() {
		guard !isSubmitting else { return }
		dismissAndClear()
	}

	private func dismissAndClear() {
		submitTask?.cancel()
		submitTask = nil
		value = ""
		dismiss()
	}

	private static func makeDraft(
		store: VaultStore,
		project: VaultProject?,
		key: String,
		selection: Set<String>
	) -> AddVariableDraft {
		var draft = AddVariableDraft(
			environments: project.map(store.orderedEnvironmentNames(for:)) ?? [],
			secretsByEnvironment: project?.environments ?? [:],
			selection: selection
		)
		draft.key = key
		return draft
	}
}

/// Where the key field is, so the suggestions can be drawn over the whole sheet.
private struct KeyFieldBounds: PreferenceKey {
	static var defaultValue: Anchor<CGRect>? { nil }
	static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
		value = value ?? nextValue()
	}
}

/// A row in the suggestions. Hover only tints it; the keyboard highlight,
/// which Return picks, stays put under a resting pointer.
private struct SuggestionButton<Content: View>: View {
	var isHighlighted = false
	let action: () -> Void
	@ViewBuilder let label: Content

	@State private var hovering = false

	var body: some View {
		Button(action: action) {
			label
				.padding(.horizontal, 10)
				.padding(.vertical, 6)
				.frame(maxWidth: .infinity, alignment: .leading)
				.background(RoundedRectangle(cornerRadius: 6).fill(isHighlighted ? VaultPalette.accentTint : hovering ? VaultPalette.neutralTint : .clear))
				.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.onHover { hovering = $0 }
	}
}

private struct FieldIconButton: View {
	let systemImage: String
	let label: String
	let action: () -> Void

	@State private var hovering = false

	var body: some View {
		Button(action: action) {
			Image(systemName: systemImage)
				.font(.system(size: 12, weight: .medium))
				.foregroundStyle(hovering ? VaultPalette.textPrimary : VaultPalette.textTertiary)
				.frame(width: 28, height: 28)
				.background(RoundedRectangle(cornerRadius: 6).fill(hovering ? VaultPalette.neutralTint : .clear))
		}
		.buttonStyle(.plain)
		.onHover { hovering = $0 }
		.help(label)
		.accessibilityLabel(label)
	}
}

private struct EnvironmentChipToggleStyle: ToggleStyle {
	let color: Color
	let hasConflict: Bool

	func makeBody(configuration: Configuration) -> some View {
		let selected = configuration.isOn
		let stroke = hasConflict ? VaultPalette.red : (selected ? VaultPalette.accent : VaultPalette.border)
		return Button { configuration.isOn.toggle() } label: {
			HStack(spacing: 7) {
				ZStack {
					RoundedRectangle(cornerRadius: 4)
						.fill(selected ? VaultPalette.accent : .clear)
					RoundedRectangle(cornerRadius: 4)
						.stroke(selected ? VaultPalette.accent : VaultPalette.textFaint.opacity(0.6), lineWidth: 1.5)
					if selected {
						Image(systemName: "checkmark")
							.font(.system(size: 8, weight: .heavy))
							.foregroundStyle(.white)
					}
				}
				.frame(width: 15, height: 15)
				VaultEnvSwatch(color: color, size: 6)
				configuration.label
					.font(VaultTypography.mono(12))
					.foregroundStyle(VaultPalette.textPrimary)
					.lineLimit(1)
					.truncationMode(.middle)
			}
			.frame(maxWidth: .infinity, alignment: .leading)
			.padding(.horizontal, 9)
			.padding(.vertical, 9)
			.contentShape(Rectangle())
			.background(RoundedRectangle(cornerRadius: 8).fill(selected ? VaultPalette.rowSelected : VaultPalette.control))
			.overlay { RoundedRectangle(cornerRadius: 8).stroke(stroke, lineWidth: 1.5) }
		}
		.buttonStyle(.plain)
		.accessibilityAddTraits(selected ? .isSelected : [])
		.accessibilityValue(hasConflict ? "Key already exists" : "")
	}
}
