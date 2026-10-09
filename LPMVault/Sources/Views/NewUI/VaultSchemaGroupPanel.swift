import SwiftUI

/// The Schema page's side panel for a group: its name, how many of its
/// members must be set, and its members, edited into the project's draft.
struct VaultSchemaGroupEditor: View {
	private typealias Draft = ProjectEnvSchemaDraft
	private typealias SchemaGroup = ProjectEnvSchemaGroup

	@Bindable var store: VaultStore
	let project: VaultProject
	/// The group shown; empty for one being added.
	let name: String
	let onSelect: (VaultSchemaSelection?) -> Void
	let onFollow: (VaultSchemaSelection) -> Void
	let onReview: () -> Void

	@State private var field = ""
	/// A group being added keeps its mode and members here while the draft can't hold it.
	@State private var newGroup = SchemaGroup()
	/// Names this panel gave the group it adds, which undo and redo can bring back.
	@State private var adoptedNames: Set<String> = []
	@State private var editsOverride = false
	@State private var pickingMember = false
	@State private var elsewhere: VaultSchemaElsewhere?
	@FocusState private var nameFocused: Bool

	fileprivate enum Mode: Equatable {
		/// Editing the group lpm.json declares, or an override of an imported one.
		case editing(isOverride: Bool)
		/// Declared in an imported schema; editing makes an override.
		case inherited(source: String)
		/// lpm.json overrides an imported group; editing it starts on request.
		case overridden(source: String)
		/// The draft removes lpm.json's override, so the imported group applies again.
		case reset(source: String)
		/// The draft removes the group from lpm.json.
		case removed
		case missing
	}

	/// Why a name can't be the group's, with ways out.
	private enum NameStatus: Equatable {
		case empty
		case invalid(suggestion: String?)
		case tooLong
		/// lpm.json or a schema it imports declares a group with the name.
		case declared(source: String)
		/// The draft adds another group with the name.
		case added
		/// The draft removes the group lpm.json declares with the name.
		case removed
		case available
	}

	// MARK: - State

	private var savedOverview: ProjectEnvSchemaOverview? { store.keyDescriptions[project.id]?.schema?.overview }
	private var draft: Draft { store.schemaDraftOrBase(for: project.id) }
	private var item: Draft.Item { .group(name) }
	private var canEdit: Bool { store.canEditSchema(of: project.id) }

	private func savedGroup(_ name: String) -> ProjectEnvSchemaOverview.Group? {
		savedOverview?.groups.first { $0.name == name }
	}

	private var importedSource: String {
		let saved = savedGroup(name)
		return saved?.overrides ?? saved?.source
			?? store.currentSchemaDraftEvaluation(for: project.id)?.overview?.groups.first { $0.name == name }?.source
			?? "an imported schema"
	}

	/// Whether the draft declares `name` in lpm.json's groups without lpm.json having it.
	private static func isAdded(_ name: String, in draft: Draft) -> Bool {
		guard draft.base(of: .group(name)) == .absent, case .declared = draft.declaration(of: .group(name)) else { return false }
		return true
	}

	/// A group the draft adds, or one being added: its name changes as it's typed.
	private var isNew: Bool {
		name.isEmpty || (savedGroup(name) == nil && Self.isAdded(name, in: draft))
	}

	/// The name the draft holds the group this panel adds under; nil while it holds none.
	private var heldName: String? {
		let draft = draft
		if adoptedNames.contains(name), Self.isAdded(name, in: draft) { return name }
		return adoptedNames.first { Self.isAdded($0, in: draft) }
	}

	private var mode: Mode {
		if name.isEmpty { return .editing(isOverride: false) }
		switch draft.declaration(of: item) {
		case .declared: return .editing(isOverride: false)
		case .overridden:
			if case .overridden = draft.base(of: item), !draft.hasChange(to: item), !editsOverride { return .overridden(source: importedSource) }
			return .editing(isOverride: true)
		case .absent:
			switch draft.base(of: item) {
			case .declared: return .removed
			case .overridden: return .reset(source: importedSource)
			case .absent: return savedGroup(name)?.source.map { .inherited(source: $0) } ?? .missing
			}
		}
	}

	private var group: SchemaGroup {
		if name.isEmpty { return newGroup }
		switch draft.declaration(of: item) {
		case .declared(let json), .overridden(let json): return SchemaGroup(json) ?? SchemaGroup()
		case .absent:
			if case .declared(let json) = draft.base(of: item) { return SchemaGroup(json) ?? SchemaGroup() }
			// Only the engine knows the imported group a removed override leaves.
			let resolved = if case .overridden = draft.base(of: item) {
				store.currentSchemaDraftEvaluation(for: project.id)?.overview?.groups.first { $0.name == name }
			} else {
				savedGroup(name)
			}
			return resolved.map { SchemaGroup(mode: SchemaGroup.Mode(rawValue: $0.mode) ?? .allOrNone, members: $0.members) } ?? SchemaGroup()
		}
	}

	private var isEditable: Bool {
		if case .editing = mode { canEdit } else { false }
	}

	// MARK: - Body

	var body: some View {
		let mode = mode
		let group = group
		VStack(spacing: 0) {
			ScrollView {
				VStack(alignment: .leading, spacing: 0) {
					header(mode)
					nameSection(mode)
					VaultSchemaSaveFailureNotice(store: store, project: project)
					if draft.conflicts.contains(where: { $0.item == item }) {
						conflictNotice
					}
					notice(mode)
					VaultHairline()
					Group {
						modeSection(group)
						membersSection(group)
					}
					.opacity(mode == .removed ? 0.5 : 1)
					rejectionNotice
				}
				.frame(maxWidth: .infinity, alignment: .leading)
			}
			VaultHairline()
			footer(mode, group: group)
		}
		.background(VaultEscapeResponder(onEscape: { onSelect(nil) }))
		.background(VaultSchemaShortcuts(undo: { undo(redo: false) }, redo: { undo(redo: true) }, remove: {
			guard canEdit, removalAvailable(mode) else { return false }
			remove(mode)
			return true
		}))
		.sheet(item: $elsewhere) { elsewhere in
			VaultSchemaElsewhereSheet(name: name, elsewhere: elsewhere, folder: store.keyDescriptions[project.id]?.folder) {
				let current = self.group
				update(declaration: elsewhere.isOverridden ? .absent : .overridden(current.json()))
			}
		}
		.onAppear {
			field = name
			if isNew, !name.isEmpty { adoptedNames = [name] }
			if name.isEmpty { Task { @MainActor in nameFocused = true } }
		}
		.onChange(of: field) { _, _ in if isNew { adopt() } }
		.onChange(of: heldName) { _, held in follow(held) }
	}

	private func undo(redo: Bool) -> Bool {
		if redo {
			guard store.canRedoSchemaDraft(in: project.id) else { return false }
			store.redoSchemaDraft(in: project.id)
		} else {
			guard store.canUndoSchemaDraft(in: project.id) else { return false }
			store.undoSchemaDraft(in: project.id)
		}
		return true
	}

	// MARK: - Header

	private func header(_ mode: Mode) -> some View {
		HStack(spacing: 6) {
			Text(isNew ? "NEW GROUP" : "GROUP").vaultSectionLabel()
			switch mode {
			case .inherited(let source), .reset(let source):
				VaultSourceBadge(source: source)
			case .overridden(let source):
				VaultSourceBadge(source: source, isOverridden: true)
			case .editing(isOverride: true):
				VaultSourceBadge(source: importedSource, isOverridden: true)
			default:
				HStack(spacing: 4) {
					Image(systemName: "doc").font(.system(size: 10))
					Text("lpm.json").font(VaultTypography.mono(11))
				}
				.foregroundStyle(VaultPalette.textTertiary)
			}
			if draft.hasChange(to: item), mode != .removed, !isNew {
				VaultTagBadge(text: "Draft", foreground: VaultPalette.orangeTintText, background: VaultPalette.orangeTint, size: 10)
			}
			Spacer(minLength: 4)
			if removalAvailable(mode) {
				VaultRowIconButton(systemImage: "trash", help: "Remove the group \(name) from the schema (⌘⌫)", destructive: true,
					label: "Remove the group \(name) from the schema") { remove(mode) }
					.disabled(!canEdit)
			}
			Rectangle().fill(VaultPalette.divider).frame(width: 1, height: 14)
			VaultRowIconButton(systemImage: "xmark", help: "Close") { onSelect(nil) }
		}
		.padding(.leading, 16)
		.padding(.trailing, 10)
		.padding(.top, 12)
		.padding(.bottom, 8)
	}

	// MARK: - Name

	private func nameStatus(_ name: String) -> NameStatus {
		guard !name.isEmpty else { return .empty }
		guard EnvValidation.isValidVariableName(name) else {
			var fixed = String(name.unicodeScalars.map { scalar -> Character in
				(scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || scalar == "_")) ? Character(scalar) : "_"
			})
			if fixed.first?.isNumber == true { fixed = "_" + fixed }
			return .invalid(suggestion: EnvValidation.isValidVariableName(fixed) && fixed != name ? fixed : nil)
		}
		guard name.utf8.count <= EnvValidation.maximumSchemaKeyNameBytes else { return .tooLong }
		if name == self.name, !isNew { return .available }
		if name == heldName { return .available }
		let draft = draft
		let saved = savedGroup(name)
		switch draft.declaration(of: .group(name)) {
		case .declared, .overridden:
			if draft.base(of: .group(name)) == .absent, saved == nil { return .added }
			return .declared(source: saved?.source ?? "lpm.json")
		case .absent:
			if case .declared = draft.base(of: .group(name)) { return .removed }
			if let saved { return .declared(source: saved.source ?? "lpm.json") }
		}
		return .available
	}

	/// lpm.json's own groups are renamed by the name field; imported ones can't be.
	private var renamable: Bool {
		guard isEditable else { return false }
		return isNew || mode == .editing(isOverride: false)
	}

	@ViewBuilder
	private func nameSection(_ mode: Mode) -> some View {
		let status = renamable && field != name || isNew ? nameStatus(field) : .available
		let invalid = switch status { case .empty, .available: false; default: true }
		VStack(alignment: .leading, spacing: 6) {
			HStack(spacing: 6) {
				if renamable {
					TextField("group_name", text: $field)
						.textFieldStyle(.plain)
						.font(VaultTypography.mono(13.5, .bold))
						.autocorrectionDisabled()
						.focused($nameFocused)
						.onSubmit { if !isNew, field != name, status == .available { rename() } }
						.accessibilityLabel("Group name")
					Text("name").font(.system(size: 11)).foregroundStyle(VaultPalette.textFaint)
				} else {
					Text(name)
						.font(VaultTypography.mono(13.5, .bold))
						.foregroundStyle(VaultPalette.textPrimary)
						.lineLimit(1)
						.truncationMode(.middle)
					Spacer(minLength: 4)
					if case .inherited = mode {
						Image(systemName: "lock").font(.system(size: 10)).foregroundStyle(VaultPalette.textFaint)
							.help("Declared elsewhere, so it can't be renamed here")
					}
				}
			}
			.padding(.horizontal, 9)
			.frame(height: 32)
			.background(RoundedRectangle(cornerRadius: 8).fill(renamable ? VaultPalette.control : .clear))
			.overlay {
				RoundedRectangle(cornerRadius: 8)
					.stroke(invalid ? VaultPalette.red : (renamable ? (nameFocused ? VaultPalette.accent : VaultPalette.border) : .clear),
						lineWidth: invalid || nameFocused ? 1.5 : 1)
			}
			if renamable {
				switch status {
				case .empty, .available:
					Text("Letters, digits and underscores; can't start with a digit; unique among groups.")
						.font(.system(size: 11))
						.foregroundStyle(VaultPalette.textTertiary)
						.fixedSize(horizontal: false, vertical: true)
				case .invalid(let suggestion):
					issueLine("Use letters, digits and underscores; a name can't start with a digit.",
						actions: suggestion.map { fixed in [("Use \(fixed)", true, { field = fixed })] } ?? [])
				case .tooLong:
					issueLine("Names can be at most \(EnvValidation.maximumSchemaKeyNameBytes) characters long.", actions: [])
				case .declared(let source):
					issueLine("A group with this name is already declared in \(source.escapingDirectionControls).",
						actions: [("Open that group", false, { let target = field; onSelect(.group(target)) })])
				case .added:
					issueLine("A group with this name is already added in your draft.",
						actions: [("Open that group", false, { let target = field; onSelect(.group(target)) })])
				case .removed:
					issueLine("Your draft removes a group with this name. Keep it in the schema to edit it.",
						actions: [("Open that group", false, { let target = field; onSelect(.group(target)) })])
				}
				if !isNew, field != name, status == .available {
					HStack(spacing: 6) {
						VaultBarButton(title: "Rename", filled: true, disabled: !canEdit, height: 24, action: rename)
						VaultBarButton(title: "Cancel", height: 24) { field = name }
					}
				}
			}
		}
		.padding(.horizontal, 16)
		.padding(.bottom, 12)
	}

	private func issueLine(_ message: String, actions: [(title: String, edits: Bool, run: () -> Void)]) -> some View {
		VStack(alignment: .leading, spacing: 4) {
			HStack(alignment: .top, spacing: 6) {
				Image(systemName: "xmark.circle").font(.system(size: 10)).padding(.top, 1)
				Text(message).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
			}
			.foregroundStyle(VaultPalette.redText)
			if !actions.isEmpty {
				HStack(spacing: 10) {
					ForEach(Array(actions.enumerated()), id: \.offset) { _, action in
						Button(action.title, action: action.run)
							.buttonStyle(.plain)
							.font(.system(size: 11, weight: .semibold))
							.foregroundStyle(VaultPalette.accentForeground)
							.disabled(action.edits && !canEdit)
							.vaultPointingHand()
					}
				}
				.padding(.leading, 16)
			}
		}
	}

	/// Renames a group lpm.json declares, in the draft: groups aren't named elsewhere in the rules.
	private func rename() {
		let target = field
		guard target != name, nameStatus(target) == .available else { return }
		let declaration = draft.declaration(of: item)
		store.editSchemaDraft(in: project.id) { draft in
			draft.set(.absent, for: .group(name))
			draft.set(declaration, for: .group(target))
		}
		guard draft.declaration(of: .group(target)) != .absent else { return }
		onFollow(.group(target))
	}

	// MARK: - New groups

	/// Keeps the group being added under the name typed while it's a name a
	/// new group can have and the group has a member, which the LPM CLI
	/// requires. Otherwise the group leaves the draft, and its mode and
	/// members wait in the panel: the draft never holds a group it can't save.
	private func adopt() {
		let held = heldName
		let candidate = field
		let current = held.map { SchemaGroup(draft.declaration(of: .group($0)).json) ?? SchemaGroup() } ?? newGroup
		guard nameStatus(candidate) == .available, !current.members.isEmpty else {
			park(held)
			return
		}
		guard candidate != held else {
			if name != candidate { onFollow(.group(candidate)) }
			return
		}
		let json = current.json(updating: held.flatMap { draft.declaration(of: .group($0)).json })
		store.editSchemaDraft(in: project.id, coalescing: "new-group") { draft in
			if let held { draft.set(.absent, for: .group(held)) }
			draft.set(.declared(json), for: .group(candidate))
		}
		// The store ignores edits while the rules can't be edited.
		guard Self.isAdded(candidate, in: draft) else { return }
		adoptedNames.insert(candidate)
		onFollow(.group(candidate))
	}

	/// Takes the group being added out of the draft while it can't be saved.
	private func park(_ held: String?) {
		guard let held else {
			if !name.isEmpty, !Self.isAdded(name, in: draft) { onFollow(.newGroup) }
			return
		}
		let kept = SchemaGroup(draft.declaration(of: .group(held)).json) ?? SchemaGroup()
		store.editSchemaDraft(in: project.id, coalescing: "new-group") { $0.set(.absent, for: .group(held)) }
		guard !Self.isAdded(held, in: draft) else { return }
		newGroup = kept
		onFollow(.newGroup)
	}

	/// Follows the group being added when the draft moves it, as undo and
	/// redo do: to the name the draft now holds it under, or back to an empty one.
	private func follow(_ held: String?) {
		guard !adoptedNames.isEmpty else { return }
		if let held {
			if held != field { field = held }
			if name != held { onFollow(.group(held)) }
		} else if !name.isEmpty, draft.declaration(of: item) != .absent {
			// Saved, or changed on disk: the group is lpm.json's now.
			adoptedNames = []
		} else if !name.isEmpty {
			field = ""
			newGroup = SchemaGroup()
			onFollow(.newGroup)
		}
	}

	// MARK: - Mode and members

	private func modeSection(_ group: SchemaGroup) -> some View {
		VStack(alignment: .leading, spacing: 8) {
			Text("MODE").vaultSectionLabel()
			ForEach(SchemaGroup.Mode.allCases, id: \.self) { option in
				let selected = group.mode == option
				Button {
					update { $0.mode = option }
				} label: {
					HStack(alignment: .top, spacing: 10) {
						Image(systemName: selected ? "largecircle.fill.circle" : "circle")
							.font(.system(size: 13))
							.foregroundStyle(selected ? VaultPalette.accent : VaultPalette.textFaint)
							.padding(.top, 1)
						VStack(alignment: .leading, spacing: 2) {
							Text(option.title).font(.system(size: 12.5, weight: .medium)).foregroundStyle(VaultPalette.textPrimary)
							Text(option.detail).font(.system(size: 11)).foregroundStyle(VaultPalette.textTertiary)
						}
						Spacer(minLength: 0)
					}
					.padding(10)
					.frame(maxWidth: .infinity, alignment: .leading)
					.background(RoundedRectangle(cornerRadius: 8).fill(selected ? VaultPalette.accentTint : VaultPalette.content))
					.overlay { RoundedRectangle(cornerRadius: 8).stroke(selected ? VaultPalette.accent : VaultPalette.border, lineWidth: selected ? 1.5 : 1) }
					.contentShape(Rectangle())
				}
				.buttonStyle(.plain)
				.disabled(!isEditable)
				.accessibilityLabel(option.title)
				.accessibilityValue(selected ? "selected" : "")
				.accessibilityAddTraits(selected ? .isSelected : [])
			}
		}
		.padding(16)
	}

	private func membersSection(_ group: SchemaGroup) -> some View {
		let declared = declaredKeys
		return VStack(alignment: .leading, spacing: 8) {
			Text("MEMBERS").vaultSectionLabel()
			VaultFlowLayout(spacing: 6, lineSpacing: 6) {
				ForEach(group.members, id: \.self) { member in
					HStack(spacing: 5) {
						Text(member.escapingDirectionControls)
							.font(VaultTypography.mono(11.5, .medium))
							.foregroundStyle(declared.contains(member) ? VaultPalette.textPrimary : VaultPalette.redText)
							.lineLimit(1)
						if isEditable {
							Button {
								update { $0.members.removeAll { $0 == member } }
							} label: {
								Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(VaultPalette.textFaint)
							}
							.buttonStyle(.plain)
							.accessibilityLabel("Remove \(member) from the group")
						}
					}
					.padding(.horizontal, 7)
					.frame(height: 24)
					.overlay { RoundedRectangle(cornerRadius: 5).stroke(VaultPalette.border, lineWidth: 1) }
					.help(declared.contains(member) ? "" : "\(member) isn't declared, which the LPM CLI rejects")
				}
				if isEditable {
					Button { pickingMember = true } label: {
						HStack(spacing: 4) {
							Image(systemName: "plus").font(.system(size: 9, weight: .semibold))
							Text("Key").font(.system(size: 11.5))
						}
						.foregroundStyle(VaultPalette.textTertiary)
						.padding(.horizontal, 7)
						.frame(height: 24)
						.overlay { RoundedRectangle(cornerRadius: 5).stroke(VaultPalette.border, style: StrokeStyle(lineWidth: 1, dash: [3, 2])) }
						.contentShape(Rectangle())
					}
					.buttonStyle(.plain)
					.accessibilityLabel("Add a key to the group")
					.popover(isPresented: $pickingMember, arrowEdge: .leading) {
						VaultKeyPicker(keys: declared.sortedAscending.filter { !group.members.contains($0) },
							secretKeys: currentOverview?.secretKeys ?? []) { picked in
							pickingMember = false
							update { if !$0.members.contains(picked) { $0.members.append(picked) } }
						}
						.frame(width: 260, height: 300)
						.padding(10)
					}
				}
			}
			if isEditable {
				Text("Declared keys only.").font(.system(size: 11)).foregroundStyle(VaultPalette.textTertiary)
			}
			if group.members.isEmpty, !name.isEmpty {
				hintLine("A group needs at least one key.", symbol: "exclamationmark.triangle", tint: VaultPalette.orangeTintText)
			} else if let hint = group.hint {
				hintLine(hint, symbol: "info.circle", tint: VaultPalette.textTertiary)
			}
		}
		.padding(.horizontal, 16)
		.padding(.bottom, 16)
	}

	private func hintLine(_ text: String, symbol: String, tint: Color) -> some View {
		HStack(alignment: .top, spacing: 6) {
			Image(systemName: symbol).font(.system(size: 10)).padding(.top, 1)
			Text(text).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
		}
		.foregroundStyle(tint)
	}

	/// The rules with the draft applied, as last evaluated.
	private var currentOverview: ProjectEnvSchemaOverview? { store.schemaOverview(for: project.id) }

	/// Keys a group can list: those declared once the draft is saved, by the
	/// latest evaluation, with keys the draft adds since.
	private var declaredKeys: Set<String> {
		let draft = draft
		var keys = currentOverview?.declaredKeys ?? []
		for case .key(let key) in draft.changedItems {
			if draft.declaration(of: .key(key)) == .absent, draft.base(of: .key(key)) != .absent { keys.remove(key) } else if draft.declaration(of: .key(key)) != .absent { keys.insert(key) }
		}
		return keys
	}

	// MARK: - Notices

	@ViewBuilder
	private func notice(_ mode: Mode) -> some View {
		switch mode {
		case .editing(isOverride: true):
			noticeBox(symbol: "square.stack.3d.up",
				text: "You're editing a copy of the group from \(importedSource). Saving writes an override to lpm.json that replaces the original.",
				tint: VaultPalette.accentText, background: VaultPalette.accentTint)
		case .removed:
			VStack(alignment: .leading, spacing: 8) {
				HStack(spacing: 6) {
					VaultTagBadge(text: "Removed", foreground: VaultPalette.redText, background: VaultPalette.redTint, size: 10)
					Text("in your draft").font(.system(size: 12, weight: .semibold)).foregroundStyle(VaultPalette.textPrimary)
				}
				Text("The group leaves lpm.json when you save, and the LPM CLI stops checking its keys together.")
					.font(.system(size: 11.5))
					.foregroundStyle(VaultPalette.textSecondary)
					.fixedSize(horizontal: false, vertical: true)
				VaultBarButton(systemImage: "arrow.uturn.backward", title: "Keep group", height: 24) {
					store.editSchemaDraft(in: project.id) { $0.discard(item) }
				}
				.disabled(!canEdit)
			}
			.padding(12)
			.frame(maxWidth: .infinity, alignment: .leading)
			.background(RoundedRectangle(cornerRadius: 8).fill(VaultPalette.redTint.opacity(0.6)))
			.overlay { RoundedRectangle(cornerRadius: 8).stroke(VaultPalette.red.opacity(0.6), lineWidth: 1) }
			.padding(.horizontal, 16)
			.padding(.bottom, 12)
		case .reset(let source):
			VStack(alignment: .leading, spacing: 8) {
				noticeContent(symbol: "arrow.uturn.backward", text: "Your draft removes lpm.json's override, so the group from \(source) applies again.")
				VaultBarButton(title: "Keep override", height: 24) { store.editSchemaDraft(in: project.id) { $0.discard(item) } }
					.disabled(!canEdit)
			}
			.foregroundStyle(VaultPalette.accentText)
			.padding(10)
			.frame(maxWidth: .infinity, alignment: .leading)
			.background(RoundedRectangle(cornerRadius: 8).fill(VaultPalette.accentTint))
			.padding(.horizontal, 16)
			.padding(.bottom, 12)
		case .inherited(let source):
			noticeBox(symbol: "lock", text: "Declared in \(source). Override it to change it in lpm.json, which replaces the original.",
				tint: VaultPalette.textSecondary, background: VaultPalette.neutralTint)
		case .overridden(let source):
			noticeBox(symbol: "square.stack.3d.up", text: "lpm.json overrides the group from \(source).",
				tint: VaultPalette.accentText, background: VaultPalette.accentTint)
		case .missing:
			Text("No group named \(name.escapingDirectionControls) is declared in lpm.json or the schemas it imports.")
				.font(.system(size: 12))
				.foregroundStyle(VaultPalette.textTertiary)
				.padding(.horizontal, 16)
				.padding(.bottom, 12)
		case .editing(isOverride: false):
			EmptyView()
		}
	}

	private func noticeContent(symbol: String, text: String) -> some View {
		HStack(alignment: .top, spacing: 8) {
			Image(systemName: symbol).font(.system(size: 11)).padding(.top, 1)
			Text(text).font(.system(size: 11.5)).fixedSize(horizontal: false, vertical: true)
		}
	}

	private func noticeBox(symbol: String, text: String, tint: Color, background: Color) -> some View {
		noticeContent(symbol: symbol, text: text)
			.foregroundStyle(tint)
			.padding(10)
			.frame(maxWidth: .infinity, alignment: .leading)
			.background(RoundedRectangle(cornerRadius: 8).fill(background))
			.padding(.horizontal, 16)
			.padding(.bottom, 12)
	}

	private var conflictNotice: some View {
		VStack(alignment: .leading, spacing: 8) {
			noticeContent(symbol: "exclamationmark.triangle", text: "lpm.json changed on disk while you edited this group. Keep your version or take the one on disk.")
			HStack(spacing: 6) {
				VaultBarButton(title: "Keep mine", height: 24) { store.editSchemaDraft(in: project.id) { $0.resolveConflict(item, keepingMine: true) } }
					.disabled(!canEdit)
				VaultBarButton(title: "Take theirs", height: 24) { store.editSchemaDraft(in: project.id) { $0.resolveConflict(item, keepingMine: false) } }
					.disabled(!canEdit)
			}
			.padding(.leading, 19)
		}
		.foregroundStyle(VaultPalette.orangeTintText)
		.padding(10)
		.frame(maxWidth: .infinity, alignment: .leading)
		.background(RoundedRectangle(cornerRadius: 8).fill(VaultPalette.orangeTint))
		.padding(.horizontal, 16)
		.padding(.bottom, 12)
	}

	/// The engine's rejection of this group, in its words.
	@ViewBuilder
	private var rejectionNotice: some View {
		if let rejection = store.latestSchemaDraftEvaluation(for: project.id)?.rejection, rejection.item == item {
			hintLine(rejection.reason, symbol: "lock", tint: VaultPalette.redText)
				.padding(.horizontal, 16)
				.padding(.bottom, 16)
		}
	}

	// MARK: - Removing

	private func removalAvailable(_ mode: Mode) -> Bool {
		switch mode {
		case .editing, .inherited, .overridden: !name.isEmpty
		case .reset, .removed, .missing: false
		}
	}

	/// Removes the group from lpm.json in the draft, or explains why it can't be removed here.
	private func remove(_ mode: Mode) {
		switch mode {
		case .editing(isOverride: false):
			if isNew {
				store.editSchemaDraft(in: project.id) { $0.discard(item) }
				onSelect(nil)
			} else {
				// Nothing else in the rules names a group, so there's nothing to settle.
				store.editSchemaDraft(in: project.id) { $0.set(.absent, for: item) }
			}
		case .inherited(let source):
			elsewhere = VaultSchemaElsewhere(source: source, path: VaultSchemaElsewhere.editable(savedGroup(name)?.sourcePath), isOverridden: false,
				isGroup: true)
		case .overridden(let source):
			elsewhere = VaultSchemaElsewhere(source: source, path: nil, isOverridden: true, isGroup: true)
		case .editing(isOverride: true):
			elsewhere = VaultSchemaElsewhere(source: importedSource, path: VaultSchemaElsewhere.editable(savedGroup(name)?.sourcePath),
				isOverridden: true, isGroup: true)
		case .reset, .removed, .missing:
			break
		}
	}

	// MARK: - Footer

	private func footer(_ mode: Mode, group: SchemaGroup) -> some View {
		let readOnlyAction: (systemImage: String, title: String, run: () -> Void)? = switch mode {
		case .inherited: ("pencil", "Override group", { update(declaration: .overridden(group.json())) })
		case .overridden: ("pencil", "Edit override", { editsOverride = true })
		default: nil
		}
		let discard: (() -> Void)? = if name.isEmpty {
			{ onSelect(nil) }
		} else if draft.hasChange(to: item) {
			{
				let wasNew = isNew
				editsOverride = false
				store.editSchemaDraft(in: project.id) { $0.discard(item) }
				if wasNew { onSelect(nil) }
			}
		} else {
			nil
		}
		// Saving now would leave out the group being added, which the draft can't hold yet.
		let pending: String? = name.isEmpty && (!field.isEmpty || !newGroup.members.isEmpty)
			? "Name the group and add a key to add it to your draft." : nil
		return VaultSchemaEditorFooter(store: store, project: project, item: item, readOnlyAction: readOnlyAction, discard: discard,
			pending: pending, onSelect: onSelect, onReview: onReview)
	}

	// MARK: - Updates

	/// Changes the group: in the panel while it's being added, otherwise in the draft.
	private func update(_ change: (inout SchemaGroup) -> Void) {
		var updated = group
		change(&updated)
		guard !name.isEmpty else {
			newGroup = updated
			adopt()
			return
		}
		if isNew, updated.members.isEmpty {
			// A group being added that loses its last member waits in the panel again.
			newGroup = updated
			park(name)
			return
		}
		let current = draft.declaration(of: item)
		let isOverride = if case .overridden = current { true } else if case .editing(isOverride: true) = mode { true } else { false }
		let json = updated.json(updating: current.json)
		update(declaration: isOverride ? .overridden(json) : .declared(json))
	}

	private func update(declaration: Draft.Declaration) {
		store.editSchemaDraft(in: project.id) { $0.set(declaration, for: item) }
	}
}

private extension Set where Element == String {
	/// From A to Z, as the Schema page lists keys.
	var sortedAscending: [String] { VaultKeySortOrder.sortedAscending(self) }
}
