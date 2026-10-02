import SwiftUI

struct AddVariableSheet: View {
	@Bindable var store: VaultStore
	let projectId: String
	@Environment(\.dismiss) private var dismiss

	@State private var draft: AddVariableDraft
	@State private var value = ""
	@State private var isValueRevealed = false
	@State private var showsGenerator = false
	@State private var generatorKind: SecretValueKind = .base64
	@State private var generatorLength = SecretValueGenerator.defaultLength
	@State private var submitTask: Task<Void, Never>?
	@State private var submitError: String?
	@State private var lastAddedKey: String?
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
		.background {
			Button("Add and keep open") { submit(keepOpen: true) }
				.keyboardShortcut(.return, modifiers: .shift)
				.opacity(0)
				.allowsHitTesting(false)
				.accessibilityHidden(true)
		}
		.interactiveDismissDisabled(isSubmitting)
		.onAppear { focusedField = .key }
		.onChange(of: draft.key) { _, key in
			submitError = nil
			if !key.isEmpty { lastAddedKey = nil }
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

	private var keyField: some View {
		VStack(alignment: .leading, spacing: 7) {
			HStack(spacing: 8) {
				VaultFieldLabel(title: "Key")
				Spacer()
				Text("UPPER_SNAKE_CASE")
					.font(.system(size: 11))
					.foregroundStyle(VaultPalette.textFaint)
			}
			TextField("DATABASE_URL", text: $draft.key)
				.textFieldStyle(.plain)
				.font(VaultTypography.mono(13))
				.foregroundStyle(VaultPalette.textPrimary)
				.autocorrectionDisabled()
				.focused($focusedField, equals: .key)
				.disabled(isSubmitting)
				.onKeyPress(.return, phases: .down, action: handleReturn)
				.onSubmit { focusedField = .value }
				.padding(.horizontal, 12)
				.frame(height: 36)
				.vaultInputField(focused: focusedField == .key, invalid: draft.keyIssue != nil)
				.accessibilityLabel("Key")
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

	private var valueField: some View {
		VStack(alignment: .leading, spacing: 7) {
			HStack(spacing: 8) {
				VaultFieldLabel(title: "Value")
				VaultTagBadge(
					text: "SECRET",
					foreground: VaultPalette.accentForeground,
					background: VaultPalette.accentTint
				)
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

				generateButton
			}
			.padding(.leading, 12)
			.padding(.trailing, 4)
			.frame(height: 36)
			.vaultInputField(focused: focusedField == .value)
		}
	}

	private var generateButton: some View {
		Button { showsGenerator.toggle() } label: {
			HStack(spacing: 5) {
				Image(systemName: "sparkles")
					.font(.system(size: 11, weight: .semibold))
				Text("Generate")
					.font(.system(size: 12, weight: .semibold))
				Image(systemName: "chevron.down")
					.font(.system(size: 8, weight: .bold))
			}
			.foregroundStyle(VaultPalette.accentDeep)
			.padding(.horizontal, 9)
			.frame(height: 28)
			.background(RoundedRectangle(cornerRadius: 6).fill(VaultPalette.accentTint))
		}
		.buttonStyle(.plain)
		.disabled(isSubmitting)
		.vaultPointingHand()
		.accessibilityLabel("Generate value")
		.popover(isPresented: $showsGenerator, arrowEdge: .trailing) {
			SecretGeneratorPanel(kind: $generatorKind, length: $generatorLength, onGenerate: generateValue)
		}
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

	private func generateValue() {
		value = SecretValueGenerator.generate(generatorKind, length: generatorLength)
		isValueRevealed = true
	}

	private func handleReturn(_ press: KeyPress) -> KeyPress.Result {
		guard press.modifiers.intersection([.shift, .control, .option, .command]) == .shift else { return .ignored }
		submit(keepOpen: true)
		return .handled
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

struct SecretGeneratorPanel: View {
	@Binding var kind: SecretValueKind
	@Binding var length: Int
	let onGenerate: () -> Void

	var body: some View {
		VStack(alignment: .leading, spacing: 1) {
			Text("GENERATE VALUE")
				.vaultSectionLabel()
				.padding(.horizontal, 8)
				.padding(.top, 5)
				.padding(.bottom, 6)

			ForEach(SecretValueKind.allCases) { candidate in
				GeneratorKindRow(
					tag: candidate.tag,
					title: candidate.title,
					subtitle: candidate.subtitle(length: length),
					usesMonospacedSubtitle: candidate.hasCommandSubtitle,
					selected: candidate == kind
				) {
					kind = candidate
					onGenerate()
				}
			}

			Rectangle()
				.fill(VaultPalette.divider)
				.frame(height: 1)
				.padding(.horizontal, 4)
				.padding(.vertical, 5)

			lengthRow
				.opacity(kind.lengthUnit == nil ? 0.4 : 1)
				.disabled(kind.lengthUnit == nil)

			HStack(spacing: 6) {
				Text("Generated locally, never sent.")
					.font(.system(size: 11))
					.foregroundStyle(VaultPalette.textFaint)
					.lineLimit(1)
				Spacer(minLength: 6)
				Button(action: onGenerate) {
					Label("Regenerate", systemImage: "arrow.clockwise")
						.labelStyle(TrailingIconLabelStyle())
						.font(.system(size: 11, weight: .semibold))
						.foregroundStyle(VaultPalette.accentForeground)
				}
				.buttonStyle(.plain)
				.vaultPointingHand()
			}
			.padding(.horizontal, 8)
			.padding(.top, 4)
			.padding(.bottom, 6)
		}
		.padding(6)
		.frame(width: 300)
		.background(VaultPalette.control)
	}

	private var lengthRow: some View {
		HStack(spacing: 10) {
			Text("Length")
				.font(.system(size: 12))
				.foregroundStyle(VaultPalette.textSecondary)
			Spacer(minLength: 0)
			HStack(spacing: 0) {
				ForEach(Array(SecretValueGenerator.presetLengths.enumerated()), id: \.element) { index, preset in
					if index > 0 { segmentDivider }
					Button { select(length: preset) } label: {
						segmentLabel("\(preset)", selected: length == preset)
					}
					.buttonStyle(.plain)
					.accessibilityLabel("\(preset) \(kind.lengthUnit?.label ?? "")")
				}
				segmentDivider
				Menu {
					ForEach(SecretValueGenerator.additionalLengths, id: \.self) { option in
						Button("\(option)") { select(length: option) }
					}
				} label: {
					segmentLabel(customLengthLabel, selected: !SecretValueGenerator.presetLengths.contains(length))
				}
				.menuStyle(.button)
				.buttonStyle(.plain)
				.menuIndicator(.hidden)
				.fixedSize()
				.accessibilityLabel("Other length")
			}
			.overlay { RoundedRectangle(cornerRadius: 6).stroke(VaultPalette.border, lineWidth: 1) }
			.clipShape(RoundedRectangle(cornerRadius: 6))
			Text(kind.lengthUnit?.label ?? "bytes")
				.font(.system(size: 10.5))
				.foregroundStyle(VaultPalette.textFaint)
				.frame(width: 58, alignment: .leading)
		}
		.padding(.horizontal, 8)
		.padding(.top, 6)
		.padding(.bottom, 4)
	}

	private var customLengthLabel: String {
		SecretValueGenerator.presetLengths.contains(length) ? "…" : "\(length)"
	}

	private var segmentDivider: some View {
		Rectangle().fill(VaultPalette.border).frame(width: 1, height: 20)
	}

	private func segmentLabel(_ text: String, selected: Bool) -> some View {
		Text(text)
			.font(VaultTypography.mono(11, selected ? .bold : .regular))
			.foregroundStyle(selected ? .white : VaultPalette.masked)
			.padding(.horizontal, 8)
			.frame(height: 20)
			.background(selected ? VaultPalette.strongFill : .clear)
			.contentShape(Rectangle())
	}

	private func select(length newLength: Int) {
		length = newLength
		if kind.lengthUnit != nil { onGenerate() }
	}
}

private struct GeneratorKindRow: View {
	let tag: String
	let title: String
	let subtitle: String
	let usesMonospacedSubtitle: Bool
	let selected: Bool
	let action: () -> Void

	@State private var hovering = false

	var body: some View {
		Button(action: action) {
			HStack(spacing: 10) {
				Text(tag)
					.font(VaultTypography.mono(10, .bold))
					.foregroundStyle(selected ? VaultPalette.accentDeep : VaultPalette.masked)
					.frame(width: 30)
				VStack(alignment: .leading, spacing: 1) {
					Text(title)
						.font(.system(size: 12.5, weight: selected ? .semibold : .regular))
						.foregroundStyle(selected ? VaultPalette.accentText : VaultPalette.textPrimary)
					Text(subtitle)
						.font(usesMonospacedSubtitle ? VaultTypography.mono(10.5) : .system(size: 10.5))
						.foregroundStyle(VaultPalette.textFaint)
						.lineLimit(1)
				}
				Spacer(minLength: 0)
				if selected {
					Image(systemName: "checkmark")
						.font(.system(size: 10, weight: .bold))
						.foregroundStyle(VaultPalette.accentForeground)
				}
			}
			.padding(.horizontal, 8)
			.padding(.vertical, 7)
			.contentShape(Rectangle())
			.background(
				RoundedRectangle(cornerRadius: 7)
					.fill(selected ? VaultPalette.accentTint : (hovering ? VaultPalette.neutralTint : .clear))
			)
		}
		.buttonStyle(.plain)
		.onHover { hovering = $0 }
		.accessibilityAddTraits(selected ? .isSelected : [])
	}
}

private struct TrailingIconLabelStyle: LabelStyle {
	func makeBody(configuration: Configuration) -> some View {
		HStack(spacing: 4) {
			configuration.title
			configuration.icon
		}
	}
}

private extension SecretValueKind {
	var tag: String {
		switch self {
		case .base64: "b64"
		case .hex: "hex"
		case .uuid: "uuid"
		case .alphanumeric: "a-Z9"
		case .password: "@%^"
		}
	}

	var title: String {
		switch self {
		case .base64: "Base64 random"
		case .hex: "Hexadecimal"
		case .uuid: "UUID v4"
		case .alphanumeric: "Alphanumeric"
		case .password: "Password"
		}
	}

	var hasCommandSubtitle: Bool {
		self == .base64 || self == .hex
	}

	func subtitle(length: Int) -> String {
		switch self {
		case .base64: "openssl rand -base64 \(length)"
		case .hex: "openssl rand -hex \(length)"
		case .uuid: "Random, RFC 9562"
		case .alphanumeric: "URL-safe, no symbols"
		case .password: "Letters, digits, symbols"
		}
	}
}
