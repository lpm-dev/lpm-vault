import SwiftUI

struct VaultInspectorView: View {
	@Bindable var store: VaultStore
	let project: VaultProject
	let environments: [String]
	let mode: VaultWorkspaceMode
	let selectedKey: String?
	/// The environment whose value of the selected key was just copied.
	var copiedEnvironment: String?
	@Binding var revealedKeys: Set<String>
	let onClose: () -> Void
	let onCopy: (VaultValueCopy) -> Void
	let onDelete: (_ key: String, _ environment: String) -> Void
	let onAddElsewhere: (_ key: String, _ environment: String) -> Void
	let onRenamed: (_ key: String, _ newKey: String) -> Void

	var body: some View {
		Group {
			if let key = selectedKey, isEditable(key) {
				VaultKeyEditor(
					store: store,
					project: project,
					environments: environments,
					key: key,
					singleEnvironment: singleEnvironment,
					copiedEnvironment: copiedEnvironment,
					revealedKeys: $revealedKeys,
					onClose: onClose,
					onCopy: onCopy,
					onDelete: onDelete,
					onAddElsewhere: onAddElsewhere,
					onRenamed: onRenamed
				)
				// Reveal and focus state belong to one key in one view of the project.
				.id(VaultKeyEditor.Identity(projectID: project.id, key: key, environment: store.selectedEnvironment, singleEnvironment: singleEnvironment))
			} else {
				emptySelection
			}
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
		.background(VaultPalette.inspector)
	}

	private var singleEnvironment: String? {
		if case .environment(let environment) = mode { return environment }
		return nil
	}

	/// A key stays editable while any environment has it or the draft adds it somewhere.
	private func isEditable(_ key: String) -> Bool {
		project.environments.values.contains { $0[key] != nil }
			|| store.keyDrafts.draft(VaultKeyDraft.ID(projectID: project.id, key: key)).map { !$0.isOrphaned } == true
	}

	private var emptySelection: some View {
		VStack(alignment: .leading, spacing: 9) {
			HStack {
				Text("INSPECTOR").vaultSectionLabel()
				Spacer()
				VaultRowIconButton(systemImage: "xmark", help: "Hide inspector", action: onClose)
			}
			Text("Select a key to inspect or edit it.")
				.font(.system(size: 12.5))
				.foregroundStyle(VaultPalette.textTertiary)
		}
		.padding(18)
	}
}

private struct VaultKeyEditor: View {
	struct Identity: Hashable {
		let projectID: String
		let key: String
		let environment: String
		let singleEnvironment: String?
	}

	private enum Field: Hashable {
		case name
		case value(String)
		case description
	}

	@Bindable var store: VaultStore
	let project: VaultProject
	let environments: [String]
	let key: String
	/// The environment of the single-environment view, or nil in the project view.
	let singleEnvironment: String?
	let copiedEnvironment: String?
	@Binding var revealedKeys: Set<String>
	let onClose: () -> Void
	let onCopy: (VaultValueCopy) -> Void
	let onDelete: (String, String) -> Void
	let onAddElsewhere: (String, String) -> Void
	let onRenamed: (String, String) -> Void

	@State private var revealedEnvironments: Set<String> = []
	@State private var saveError: VaultKeyEditError?
	@FocusState private var focus: Field?

	private var id: VaultKeyDraft.ID { VaultKeyDraft.ID(projectID: project.id, key: key) }

	var body: some View {
		let draft = store.keyDrafts.draft(id)
		let issue = Self.issue(for: draft, in: project)
		let saved = environments.filter { project.value(for: key, in: $0) != nil }
		let cards = cardEnvironments(draft)
		let descriptions = store.keyDescriptions[project.id]
		VStack(spacing: 0) {
			ScrollView {
				VStack(alignment: .leading, spacing: 0) {
					header(saved: saved, cards: cards)
					nameSection(draft, issue: issue, saved: saved, descriptions: descriptions)
					VaultHairline()
					valuesSection(draft, cards: cards)
					VaultHairline()
					descriptionSection(draft, descriptions: descriptions)
				}
				.frame(maxWidth: .infinity, alignment: .leading)
			}
			VaultHairline()
			footer(draft, issue: issue)
		}
		.background(VaultEscapeResponder(onEscape: onClose))
	}

	// MARK: - Sections

	private func header(saved: [String], cards: [String]) -> some View {
		let allRevealed = store.canUseLocalSecrets
			&& (revealedKeys.contains(key) || (!cards.isEmpty && cards.allSatisfy(revealedEnvironments.contains)))
		return HStack(spacing: 6) {
			Text("KEY").vaultSectionLabel()
			VaultTagBadge(text: "ENCRYPTED", foreground: VaultPalette.accentForeground, background: VaultPalette.accentTint, size: 9)
			Text(saved.count == 1 ? "in 1 env" : "in \(saved.count) envs")
				.font(.system(size: 11))
				.foregroundStyle(VaultPalette.textTertiary)
				.lineLimit(1)
			Spacer(minLength: 4)
			VaultRowIconButton(systemImage: allRevealed ? "eye.slash" : "eye", help: allRevealed ? "Hide all values" : "Reveal all values") {
				toggleRevealAll(allRevealed)
			}
			.disabled(!store.canUseLocalSecrets)
			.opacity(store.canUseLocalSecrets ? 1 : 0.45)
			deleteControl(saved: saved)
			Rectangle().fill(VaultPalette.divider).frame(width: 1, height: 14)
			VaultRowIconButton(systemImage: "xmark", help: "Hide inspector", action: onClose)
		}
		.padding(.leading, 18)
		.padding(.trailing, 12)
		.padding(.top, 12)
		.padding(.bottom, 10)
	}

	@ViewBuilder
	private func deleteControl(saved: [String]) -> some View {
		let targets = singleEnvironment.map { environment in saved.filter { $0 == environment } } ?? saved
		if targets.count == 1, let environment = targets.first {
			VaultRowIconButton(systemImage: "trash", help: "Delete from \(VaultProject.displayName(for: environment))", destructive: true) {
				onDelete(key, environment)
			}
		} else if targets.count > 1 {
			Menu {
				ForEach(targets, id: \.self) { environment in
					Button("Delete from \(VaultProject.displayName(for: environment))") { onDelete(key, environment) }
				}
			} label: {
				Image(systemName: "trash")
					.font(.system(size: 12, weight: .medium))
					.foregroundStyle(VaultPalette.textTertiary)
					.frame(width: 26, height: 26)
					.contentShape(Rectangle())
			}
			.menuStyle(.button)
			.buttonStyle(.plain)
			.menuIndicator(.hidden)
			.fixedSize()
			.help("Delete from an environment")
			.accessibilityLabel("Delete from an environment")
		}
	}

	private func nameSection(
		_ draft: VaultKeyDraft?, issue: VaultKeyEditError?, saved: [String], descriptions: ProjectKeyDescriptions?
	) -> some View {
		let name = draft?.name ?? key
		let renamed = name != key
		let focused = focus == .name
		let stroke = issue != nil ? VaultPalette.red : (focused ? VaultPalette.accent : (renamed ? VaultPalette.border : .clear))
		return VStack(alignment: .leading, spacing: 6) {
			HStack(spacing: 6) {
				TextField("KEY_NAME", text: nameBinding)
					.textFieldStyle(.plain)
					.font(VaultTypography.mono(14, .bold))
					.foregroundStyle(VaultPalette.textPrimary)
					.autocorrectionDisabled()
					.focused($focus, equals: .name)
					.disabled(draft?.isSaveInFlight == true)
					.onSubmit(save)
					.accessibilityLabel("Key name")
				if !focused && !renamed {
					Button { focus = .name } label: {
						Image(systemName: "pencil")
							.font(.system(size: 10, weight: .semibold))
							.foregroundStyle(VaultPalette.textFaint)
							.frame(width: 20, height: 20)
							.contentShape(Rectangle())
					}
					.buttonStyle(.plain)
					.disabled(draft?.isSaveInFlight == true)
					.help("Rename key")
					.accessibilityLabel("Rename key")
					.vaultPointingHand()
				}
			}
			.padding(.horizontal, 9)
			.frame(height: 32)
			.background(RoundedRectangle(cornerRadius: 8).fill(focused || renamed ? VaultPalette.control : .clear))
			.overlay { RoundedRectangle(cornerRadius: 8).stroke(stroke, lineWidth: focused || issue != nil ? 1.5 : 1) }

			if renamed {
				HStack(spacing: 5) {
					Text(key).strikethrough()
					Image(systemName: "arrow.right").font(.system(size: 8, weight: .bold))
					Text(name).foregroundStyle(VaultPalette.textSecondary)
				}
				.font(VaultTypography.mono(10.5))
				.foregroundStyle(VaultPalette.textFaint)
				.lineLimit(1)
				.truncationMode(.middle)
				if let scope = renameScope(saved) {
					Text(scope)
						.font(.system(size: 11))
						.foregroundStyle(VaultPalette.textTertiary)
				}
				if case .success(let rules)? = descriptions?.rules, rules.keys.contains(key) {
					Text(rules.keys.contains(name)
						? "lpm.json already has a rule for \(name), so the rule for \(key) stays."
						: "Also moves its rule in lpm.json.")
						.font(.system(size: 11))
						.foregroundStyle(VaultPalette.textTertiary)
						.fixedSize(horizontal: false, vertical: true)
				}
			}
			if let issue {
				Text(issue.localizedDescription)
					.font(.system(size: 11))
					.foregroundStyle(VaultPalette.redText)
					.fixedSize(horizontal: false, vertical: true)
			}
		}
		.padding(.horizontal, 18)
		.padding(.bottom, 14)
	}

	private func valuesSection(_ draft: VaultKeyDraft?, cards: [String]) -> some View {
		let addable = environments.filter { project.value(for: key, in: $0) == nil && draft?.values[$0] == nil }
		return VStack(alignment: .leading, spacing: 14) {
			HStack(spacing: 8) {
				Text(singleEnvironment == nil ? "VALUES" : "VALUE").vaultSectionLabel()
				Spacer(minLength: 4)
				if singleEnvironment == nil, environments.count > 1 {
					sameValueMenu(draft, cards: cards)
				}
			}
			ForEach(cards, id: \.self) { environment in
				card(environment, draft: draft, cards: cards)
			}
			addRows(addable, draft: draft)
		}
		.padding(.horizontal, 18)
		.padding(.vertical, 14)
	}

	private func sameValueMenu(_ draft: VaultKeyDraft?, cards: [String]) -> some View {
		let sources = cards.filter { environments.contains($0) && !currentValue(in: $0, draft: draft).isEmpty }
		return Menu {
			ForEach(sources, id: \.self) { source in
				Button("Use the \(VaultProject.displayName(for: source)) value") {
					let value = currentValue(in: source, draft: draft)
					edit { $0.setValue(value, in: environments) }
				}
			}
		} label: {
			Text("Same value in all")
				.font(.system(size: 11.5, weight: .semibold))
				.foregroundStyle(sources.isEmpty ? VaultPalette.textFaint : VaultPalette.accentForeground)
		}
		.menuStyle(.button)
		.buttonStyle(.plain)
		.menuIndicator(.hidden)
		.fixedSize()
		.disabled(sources.isEmpty || draft?.isSaveInFlight == true)
		.help("Give every environment the same value")
	}

	private func card(_ environment: String, draft: VaultKeyDraft?, cards: [String]) -> some View {
		let entry = draft?.values[environment]
		let isAddition = draft?.additions.contains(environment) == true
		let isOrphan = draft?.orphanedEnvironments.contains(environment) == true
		let hasConflict = entry?.hasExternalConflict == true
		let isChanged = !isAddition && !isOrphan && entry?.isDirty == true
		let isSaving = draft?.isSaveInFlight == true
		let revealed = isRevealed(environment)
		let displayName = VaultProject.displayName(for: environment)
		return VStack(alignment: .leading, spacing: 6) {
			HStack(spacing: 6) {
				VaultEnvSwatch(color: environments.firstIndex(of: environment).map(VaultPalette.environment) ?? VaultPalette.textFaint)
				Text(displayName)
					.font(VaultTypography.mono(11.5, .bold))
					.foregroundStyle(VaultPalette.textPrimary)
					.lineLimit(1)
					.truncationMode(.middle)
				if isOrphan {
					VaultTagBadge(text: "DELETED", foreground: VaultPalette.redText, background: VaultPalette.redTint, size: 9)
				} else if isAddition {
					VaultTagBadge(text: "NEW", foreground: VaultPalette.greenTintText, background: VaultPalette.greenTint, size: 9)
				} else if isChanged {
					VaultTagBadge(text: "CHANGED", foreground: VaultPalette.orangeTintText, background: VaultPalette.orangeTint, size: 9)
				}
				Spacer(minLength: 4)
				if copiedEnvironment == environment {
					Label("Copied", systemImage: "checkmark")
						.font(.system(size: 11, weight: .medium))
						.foregroundStyle(VaultPalette.greenTintText)
				}
			}

			HStack(spacing: 0) {
				valueField(environment, revealed: revealed, disabled: isSaving)
				VaultRowIconButton(systemImage: revealed ? "eye.slash" : "eye", help: "\(revealed ? "Hide" : "Show") \(displayName) value") {
					toggleReveal(environment, cards: cards)
				}
				.disabled(!store.canUseLocalSecrets)
				.opacity(store.canUseLocalSecrets ? 1 : 0.45)
				copyControl(environment)
				SecretGeneratorButton(
					disabled: !store.canUseLocalSecrets || isSaving || hasConflict || isOrphan,
					compact: true
				) { generated in
					edit { $0.setValue(generated, in: environment) }
				}
			}
			.padding(.leading, 10)
			.padding(.trailing, 3)
			.frame(minHeight: 34)
			.vaultInputField(focused: focus == .value(environment), invalid: hasConflict || isOrphan)

			if hasConflict {
				cardMessage("Changed outside the editor.") {
					cardAction("Use latest") { edit { $0.revert(environment) } }
					cardAction("Keep mine") { edit { $0.keepEdit(in: environment) } }
				}
			} else if isOrphan {
				let environmentExists = project.environments[environment] != nil
				cardMessage(environmentExists ? "Deleted outside the editor." : "\(displayName) was deleted outside the editor.") {
					if environmentExists {
						cardAction("Add again") { edit { $0.readd(environment, environments: project.environments) } }
					}
					cardAction("Discard") { edit { $0.revert(environment) } }
				}
			}
		}
	}

	@ViewBuilder
	private func valueField(_ environment: String, revealed: Bool, disabled: Bool) -> some View {
		let binding = valueBinding(environment)
		let label = "Value in \(VaultProject.displayName(for: environment))"
		Group {
			if revealed {
				TextField(label, text: binding, prompt: Text("Empty"), axis: .vertical)
					.lineLimit(1...4)
			} else {
				SecureField(label, text: binding, prompt: Text("Empty"))
			}
		}
		.textFieldStyle(.plain)
		.font(VaultTypography.mono(11.5))
		.foregroundStyle(VaultPalette.textPrimary)
		.autocorrectionDisabled()
		.focused($focus, equals: .value(environment))
		.disabled(disabled)
		.onSubmit(save)
		.padding(.vertical, 8)
		.frame(maxWidth: .infinity, alignment: .leading)
	}

	private func copyControl(_ environment: String) -> some View {
		let displayName = VaultProject.displayName(for: environment)
		return HStack(spacing: 0) {
			VaultRowIconButton(systemImage: "doc.on.doc", help: "Copy \(displayName) value") {
				copy(environment, as: .value)
			}
			Menu {
				ForEach(VaultCopyFormat.allCases) { format in
					Button(format.title) { copy(environment, as: format) }
				}
			} label: {
				Image(systemName: "chevron.down")
					.font(.system(size: 7, weight: .bold))
					.foregroundStyle(VaultPalette.textTertiary)
					.frame(width: 12, height: 26)
					.contentShape(Rectangle())
			}
			.menuStyle(.button)
			.buttonStyle(.plain)
			.menuIndicator(.hidden)
			.fixedSize()
			.help("More copy formats")
			.accessibilityLabel("More ways to copy the \(displayName) value")
		}
		.disabled(!store.canUseLocalSecrets)
		.opacity(store.canUseLocalSecrets ? 1 : 0.45)
	}

	@ViewBuilder
	private func addRows(_ addable: [String], draft: VaultKeyDraft?) -> some View {
		let isSaving = draft?.isSaveInFlight == true
		if let singleEnvironment {
			if addable.contains(singleEnvironment) {
				addRow("Add to \(VaultProject.displayName(for: singleEnvironment))", disabled: isSaving) { add(singleEnvironment) }
			}
			if let other = addable.first(where: { $0 != singleEnvironment }) {
				addRow("Add to another environment", disabled: false) { onAddElsewhere(key, other) }
			}
		} else {
			ForEach(addable, id: \.self) { environment in
				addRow("Add to \(VaultProject.displayName(for: environment))", disabled: isSaving) { add(environment) }
			}
		}
	}

	private func addRow(_ title: String, disabled: Bool, action: @escaping () -> Void) -> some View {
		Button(action: action) {
			Label(title, systemImage: "plus")
				.font(.system(size: 11.5, weight: .medium))
				.foregroundStyle(disabled ? VaultPalette.textFaint : VaultPalette.accentForeground)
				.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.disabled(disabled)
		.vaultPointingHand()
	}

	private func cardMessage<Actions: View>(_ message: String, @ViewBuilder actions: () -> Actions) -> some View {
		VStack(alignment: .leading, spacing: 4) {
			Text(message)
				.font(.system(size: 11))
				.foregroundStyle(VaultPalette.redText)
				.fixedSize(horizontal: false, vertical: true)
			HStack(spacing: 14) { actions() }
		}
	}

	private func cardAction(_ title: String, action: @escaping () -> Void) -> some View {
		Button(title, action: action)
			.buttonStyle(.plain)
			.font(.system(size: 11, weight: .semibold))
			.foregroundStyle(VaultPalette.accentForeground)
			.fixedSize()
			.vaultPointingHand()
	}

	private func descriptionSection(_ draft: VaultKeyDraft?, descriptions: ProjectKeyDescriptions?) -> some View {
		let entry = draft?.keyDescription
		let hasConflict = entry?.hasExternalConflict == true
		return VStack(alignment: .leading, spacing: 8) {
			HStack(spacing: 6) {
				Text("DESCRIPTION").vaultSectionLabel()
				if entry?.isDirty == true, !hasConflict {
					VaultTagBadge(text: "CHANGED", foreground: VaultPalette.orangeTintText, background: VaultPalette.orangeTint, size: 9)
				}
				Spacer(minLength: 0)
			}
			switch descriptions?.rules {
			case nil:
				Text("Reading lpm.json…")
					.font(.system(size: 11.5))
					.foregroundStyle(VaultPalette.textTertiary)
			case .failure(let failure)?:
				Text(failure.localizedDescription)
					.font(.system(size: 11.5))
					.foregroundStyle(VaultPalette.textTertiary)
					.fixedSize(horizontal: false, vertical: true)
			case .success(let rules)?:
				if EnvValidation.isValidVariableName(draft?.name ?? key) {
					TextField(
						"Description",
						text: descriptionBinding(saved: rules.descriptions[key] ?? ""),
						prompt: Text("What it is for, who owns it, when to rotate it"),
						axis: .vertical
					)
					.lineLimit(2...6)
					.textFieldStyle(.plain)
					.font(.system(size: 12))
					.foregroundStyle(VaultPalette.textPrimary)
					.focused($focus, equals: .description)
					.disabled(draft?.isSaveInFlight == true)
					.padding(.horizontal, 10)
					.padding(.vertical, 8)
					.vaultInputField(focused: focus == .description, invalid: hasConflict)
					if hasConflict {
						cardMessage("Changed in lpm.json.") {
							cardAction("Use latest") { edit { $0.revertKeyDescription() } }
							cardAction("Keep mine") { edit { $0.keepKeyDescription() } }
						}
					} else {
						Text("Stored in lpm.json, not encrypted")
							.font(.system(size: 10.5))
							.foregroundStyle(VaultPalette.textFaint)
							.help(descriptions.map { "\($0.folder)/lpm.json, which the LPM CLI reads" } ?? "")
					}
				} else {
					Text("Descriptions need a key name of letters, numbers, and underscores.")
						.font(.system(size: 11.5))
						.foregroundStyle(VaultPalette.textTertiary)
						.fixedSize(horizontal: false, vertical: true)
				}
			}
		}
		.padding(.horizontal, 18)
		.padding(.vertical, 14)
	}

	private func footer(_ draft: VaultKeyDraft?, issue: VaultKeyEditError?) -> some View {
		let changes = draft?.unsavedChangeCount ?? 0
		let isSaving = draft?.isSaveInFlight == true
		let canSave = draft?.canSave == true && issue == nil && store.canUseLocalSecrets
		return VStack(alignment: .leading, spacing: 8) {
			if let saveError = draft?.saveError ?? saveError {
				Text(saveError.localizedDescription)
					.font(.system(size: 11))
					.foregroundStyle(VaultPalette.redText)
					.fixedSize(horizontal: false, vertical: true)
			}
			HStack(spacing: 8) {
				HStack(spacing: 6) {
					if changes > 0 { VaultStatusDot(color: VaultPalette.orange) }
					Text(changes == 0 ? "No unsaved changes" : (changes == 1 ? "1 unsaved change" : "\(changes) unsaved changes"))
						.font(.system(size: 11.5, weight: changes > 0 ? .medium : .regular))
						.foregroundStyle(changes > 0 ? VaultPalette.orangeTintText : VaultPalette.textTertiary)
						.lineLimit(1)
						.minimumScaleFactor(0.8)
				}
				.layoutPriority(-1)
				Spacer(minLength: 0)
				VaultBarButton(title: "Revert", disabled: changes == 0 || isSaving, height: 28) {
					edit { $0.revert() }
				}
				VaultBarButton(title: isSaving ? "Saving…" : "Save", shortcut: "⌘S", filled: true, disabled: !canSave, height: 28, action: save)
					.keyboardShortcut("s", modifiers: .command)
			}
		}
		.padding(.horizontal, 18)
		.padding(.vertical, 12)
	}

	// MARK: - State

	private var nameBinding: Binding<String> {
		Binding(
			get: { store.keyDrafts.draft(id)?.name ?? key },
			set: { name in edit { $0.name = name } }
		)
	}

	private func descriptionBinding(saved: String) -> Binding<String> {
		Binding(
			get: { store.keyDrafts.draft(id)?.keyDescription?.draft ?? saved },
			set: { text in edit { $0.setKeyDescription(text, saved: saved) } }
		)
	}

	private func valueBinding(_ environment: String) -> Binding<String> {
		Binding(
			get: { currentValue(in: environment, draft: store.keyDrafts.draft(id)) },
			set: { value in edit { $0.setValue(value, in: environment) } }
		)
	}

	private func currentValue(in environment: String, draft: VaultKeyDraft?) -> String {
		draft?.value(in: environment) ?? project.value(for: key, in: environment) ?? ""
	}

	/// Environments with a value card, in project order. The single-environment
	/// view adds other environments only while they hold unsaved edits, so a save
	/// never includes changes the person cannot see.
	private func cardEnvironments(_ draft: VaultKeyDraft?) -> [String] {
		var listed = environments.filter { project.value(for: key, in: $0) != nil || draft?.values[$0] != nil }
		if let draft {
			let known = Set(environments)
			listed += draft.values.keys.filter { !known.contains($0) }.sorted()
		}
		guard let singleEnvironment else { return listed }
		return listed.filter { environment in
			guard environment != singleEnvironment else { return true }
			guard let draft, let entry = draft.values[environment] else { return false }
			return entry.isDirty || entry.hasExternalConflict
				|| draft.additions.contains(environment) || draft.orphanedEnvironments.contains(environment)
		}
	}

	private func renameScope(_ saved: [String]) -> String? {
		switch saved.count {
		case 0: nil
		case 1: "Renames it in \(VaultProject.displayName(for: saved[0]))"
		default: "Renames it in all \(saved.count) environments that have it"
		}
	}

	/// A problem with the draft's name that saving would report, shown while typing.
	static func issue(for draft: VaultKeyDraft?, in project: VaultProject) -> VaultKeyEditError? {
		guard let draft, draft.isRenamed || !draft.additions.isEmpty else { return nil }
		switch draft.keyEdit().applied(to: project.environments) {
		case .failure(.invalidName): return .invalidName
		case .failure(.collision(let environment, let existingKey)):
			return .collision(environment: environment, existingKey: existingKey, newKey: draft.name)
		case .failure(.changed), .success: return nil
		}
	}

	private func isRevealed(_ environment: String) -> Bool {
		store.canUseLocalSecrets && (revealedKeys.contains(key) || revealedEnvironments.contains(environment))
	}

	private func toggleRevealAll(_ allRevealed: Bool) {
		guard store.canUseLocalSecrets else { return }
		if allRevealed {
			revealedKeys.remove(key)
			revealedEnvironments.removeAll()
		} else {
			revealedKeys.insert(key)
		}
	}

	private func toggleReveal(_ environment: String, cards: [String]) {
		guard store.canUseLocalSecrets else { return }
		if revealedKeys.contains(key) {
			revealedKeys.remove(key)
			revealedEnvironments = Set(cards)
		}
		if revealedEnvironments.contains(environment) {
			revealedEnvironments.remove(environment)
		} else {
			revealedEnvironments.insert(environment)
		}
	}

	private func edit(_ change: (inout VaultKeyDraft) -> Void) {
		saveError = nil
		store.keyDrafts.edit(project, key: key, change)
	}

	private func add(_ environment: String) {
		edit { $0.add(environment) }
		// The field appears with the next render.
		Task { @MainActor in focus = .value(environment) }
	}

	private func copy(_ environment: String, as format: VaultCopyFormat) {
		onCopy(VaultValueCopy(projectID: project.id, key: key, environment: environment, format: format))
	}

	private func save() {
		guard let draft = store.keyDrafts.draft(id), draft.canSave,
			Self.issue(for: draft, in: project) == nil, store.canUseLocalSecrets
		else { return }
		let renamedTo = draft.isRenamed ? draft.name : nil
		let generation = store.keyDrafts.generation
		saveError = nil
		Task { @MainActor in
			guard generation == store.keyDrafts.generation else { return }
			do throws(VaultKeyEditError) {
				try await store.saveKeyDraft(id)
				guard generation == store.keyDrafts.generation else { return }
				if let renamedTo { onRenamed(key, renamedTo) }
			} catch {
				guard generation == store.keyDrafts.generation else { return }
				if case .description(_, keySaved: true) = error, let renamedTo { onRenamed(key, renamedTo) }
				saveError = error
			}
		}
	}
}

/// Unsaved key edits whose project or key disappeared, kept so their values can
/// be copied before they are discarded.
struct VaultKeyRecoveryView: View {
	@Bindable var store: VaultStore
	var copied: VaultCopyFeedback.Target?
	let onCopy: (VaultKeyDraft.ID, String) -> Void
	let onDiscard: (VaultKeyDraft.ID) -> Void

	var body: some View {
		ScrollView {
			VStack(alignment: .leading, spacing: 0) {
				ForEach(store.keyDrafts.orphanIDs, id: \.self) { id in
					if let draft = store.keyDrafts.draft(id) {
						section(draft)
						VaultHairline()
					}
				}
			}
			.frame(maxWidth: .infinity, alignment: .leading)
		}
		.background(VaultPalette.inspector)
	}

	private func section(_ draft: VaultKeyDraft) -> some View {
		VStack(alignment: .leading, spacing: 10) {
			Text("UNSAVED EDITS").vaultSectionLabel()
			Text(draft.isRenamed ? "\(draft.key) → \(draft.name)" : draft.key)
				.font(VaultTypography.mono(14, .bold))
				.foregroundStyle(VaultPalette.textPrimary)
				.fixedSize(horizontal: false, vertical: true)
			Text(draft.projectName)
				.font(.system(size: 12))
				.foregroundStyle(VaultPalette.textSecondary)
			Text("The env project or this key was deleted outside the editor. Your unsaved values are kept here so you can copy them before you discard them.")
				.font(.system(size: 12))
				.foregroundStyle(VaultPalette.redText)
				.fixedSize(horizontal: false, vertical: true)
			ForEach(draft.changedEnvironments, id: \.self) { environment in
				HStack(spacing: 8) {
					Text(VaultProject.displayName(for: environment))
						.font(VaultTypography.mono(11.5, .bold))
						.foregroundStyle(VaultPalette.textPrimary)
						.lineLimit(1)
						.truncationMode(.middle)
					Spacer(minLength: 4)
					VaultValueText(text: "••••••••", size: 11)
					let isCopied = copied == .unsaved(draft.id, environment: environment)
					VaultBarButton(
						systemImage: isCopied ? "checkmark" : "doc.on.doc",
						title: isCopied ? "Copied" : "Copy value",
						height: 24
					) { onCopy(draft.id, environment) }
				}
			}
			VaultBarButton(title: "Discard", height: 28) { onDiscard(draft.id) }
		}
		.padding(18)
	}
}

/// Esc in the key inspector: the first leaves the field being edited and keeps
/// its edit as a draft, and the next closes the inspector. An AppKit responder
/// handles it because SwiftUI can only focus a container while system keyboard
/// navigation is on. Esc anywhere else, such as in the sidebar search, is left alone.
private struct VaultEscapeResponder: NSViewRepresentable {
	let onEscape: () -> Void

	func makeNSView(context: Context) -> ResponderView { ResponderView() }

	func updateNSView(_ view: ResponderView, context: Context) {
		view.onEscape = onEscape
	}

	final class ResponderView: NSView {
		var onEscape: () -> Void = {}
		private var monitor: Any?

		override var acceptsFirstResponder: Bool { true }

		override func hitTest(_ point: NSPoint) -> NSView? { nil }

		override func viewDidMoveToWindow() {
			super.viewDidMoveToWindow()
			if let monitor {
				NSEvent.removeMonitor(monitor)
				self.monitor = nil
			}
			guard window != nil else { return }
			monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
				guard event.keyCode == 53,
					event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
				else { return event }
				let windowNumber = event.windowNumber
				let handled = MainActor.assumeIsolated { self?.handleEscape(inWindow: windowNumber) ?? false }
				return handled ? nil : event
			}
		}

		private func handleEscape(inWindow windowNumber: Int) -> Bool {
			guard let window, window.windowNumber == windowNumber, window.attachedSheet == nil else { return false }
			if window.firstResponder === self {
				onEscape()
				return true
			}
			// The field editor's delegate is the field being edited; only fields inside the inspector count.
			guard let editor = window.firstResponder as? NSText, let field = editor.delegate as? NSView,
				convert(bounds, to: nil).contains(field.convert(field.bounds, to: nil))
			else { return false }
			window.makeFirstResponder(self)
			return true
		}
	}
}
