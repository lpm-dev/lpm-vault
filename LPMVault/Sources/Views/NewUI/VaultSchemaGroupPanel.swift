import SwiftUI

/// The Schema page's side panel for a group: its name, how many of its
/// members must be set, and its members, edited into the project's draft.
struct VaultSchemaGroupEditor: View {
	typealias Draft = ProjectEnvSchemaDraft
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
	/// Names a group of lpm.json had in this panel as it was renamed, which undo and redo can bring back.
	@State private var renamedNames: Set<String> = []
	@State private var editsOverride = false
	@State private var pickingMember = false
	@State private var memberFilter = ""
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

	/// A group the draft adds, or one being added: its name changes as it's
	/// typed. A group of lpm.json the draft renames isn't one.
	private var isNew: Bool {
		let draft = draft
		return name.isEmpty || (savedGroup(name) == nil && Self.isAdded(name, in: draft) && draft.originalName(ofGroup: name) == nil)
	}

	/// The name the draft gives the group of lpm.json this panel renamed; nil while it has none of them.
	private var renamedHeld: String? {
		let draft = draft
		if renamedNames.contains(name), draft.declaration(of: item) != .absent { return name }
		return renamedNames.first { draft.declaration(of: .group($0)) != .absent }
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
				store.latestSchemaDraftEvaluation(for: project.id)?.overview?.groups.first { $0.name == name }
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
					if mode != .missing {
						VaultHairline()
						Group {
							modeSection(group)
							membersSection(group)
						}
						.opacity(mode == .removed ? 0.5 : 1)
						rejectionNotice
					}
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
		.onChange(of: renamedHeld) { _, held in
			// Undo, redo, and discarding move a rename; the panel stays with the group.
			guard let held else { return }
			if field != held { field = held }
			if held != name { onFollow(.group(held)) }
		}
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
				VaultSourceBadge(source: source, declares: "the group")
			case .overridden(let source):
				VaultSourceBadge(source: source, isOverridden: true, declares: "the group")
			case .editing(isOverride: true):
				VaultSourceBadge(source: importedSource, isOverridden: true, declares: "the group")
			case .missing:
				EmptyView()
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
				VaultRowIconButton(systemImage: "trash", help: "Remove the group \(name.escapingDirectionControls) from the schema (⌘⌫)", destructive: true,
					label: "Remove the group \(name.escapingDirectionControls) from the schema") { remove(mode) }
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
		let draft = draft
		if name == self.name, !isNew { return .available }
		if name == heldName { return .available }
		// Renaming back to the name lpm.json has ends the rename.
		if name == draft.originalName(ofGroup: self.name) { return .available }
		let saved = savedGroup(name)
		switch draft.declaration(of: .group(name)) {
		case .declared, .overridden:
			if draft.base(of: .group(name)) == .absent, saved == nil { return .added }
			return .declared(source: saved?.source ?? "lpm.json")
		case .absent:
			switch draft.base(of: .group(name)) {
			case .declared: return .removed
			case .overridden: return .declared(source: saved?.overrides ?? saved?.source ?? "an imported schema")
			case .absent: if let saved { return .declared(source: saved.source ?? "lpm.json") }
			}
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
					Text(name.escapingDirectionControls)
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
					issueLine("Your draft removes a group with this name. Open it to keep it.",
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

	/// Renames a group lpm.json declares, in the draft: groups aren't named
	/// elsewhere in the rules. The group keeps its place in lpm.json.
	private func rename() {
		let target = field
		guard target != name, nameStatus(target) == .available else { return }
		let previous = name
		store.editSchemaDraft(in: project.id) { $0.renameGroup(previous, to: target) }
		guard draft.declaration(of: .group(target)) != .absent else { return }
		renamedNames.formUnion([previous, target])
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
		guard nameStatus(candidate) == .available, !current.members.isEmpty, !atGroupLimit || held != nil else {
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

	/// Takes the group being added out of the draft while it can't be saved,
	/// keeping `group` in the panel: the draft's version unless given.
	private func park(_ held: String?, keeping group: SchemaGroup? = nil) {
		guard let held else {
			if !name.isEmpty, !Self.isAdded(name, in: draft) { onFollow(.newGroup) }
			return
		}
		let kept = group ?? SchemaGroup(draft.declaration(of: .group(held)).json) ?? SchemaGroup()
		store.editSchemaDraft(in: project.id, coalescing: "new-group") { $0.set(.absent, for: .group(held)) }
		guard !Self.isAdded(held, in: draft) else { return }
		newGroup = kept
		onFollow(.newGroup)
	}

	/// Whether lpm.json and its imports already have as many groups as the LPM CLI accepts.
	private var atGroupLimit: Bool {
		let draft = draft
		var names = Set((currentOverview?.groups ?? []).map(\.name))
		for case .group(let name) in draft.changedItems {
			if draft.declaration(of: .group(name)) == .absent { names.remove(name) } else { names.insert(name) }
		}
		return names.count >= SchemaGroup.maximumGroups
	}

	/// Members every group has together, which the LPM CLI limits.
	private var memberCount: Int {
		(currentOverview?.groups ?? []).reduce(0) { $0 + $1.members.count }
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
				.accessibilityLabel("\(option.title): \(option.detail)")
				.accessibilityAddTraits(selected ? .isSelected : [])
			}
		}
		.padding(16)
	}

	private func membersSection(_ group: SchemaGroup) -> some View {
		let declared = declaredKeys
		let isLarge = group.members.count > Self.shownMemberLimit
		let needle = memberFilter.trimmingCharacters(in: .whitespaces)
		let matching = isLarge && !needle.isEmpty ? group.members.filter { $0.range(of: needle, options: .caseInsensitive) != nil } : group.members
		let shown = Array(matching.prefix(Self.shownMemberLimit))
		return VStack(alignment: .leading, spacing: 8) {
			HStack(spacing: 8) {
				Text(group.members.isEmpty ? "MEMBERS" : "MEMBERS · \(group.members.count.formatted())").vaultSectionLabel()
				Spacer(minLength: 8)
				if isEditable { addMemberButton(group) }
			}
			if isLarge {
				TextField("Filter \(group.members.count.formatted()) members", text: $memberFilter)
					.textFieldStyle(.roundedBorder)
					.font(VaultTypography.mono(12))
					.accessibilityLabel("Filter the group's members")
				Group {
					if matching.count > shown.count {
						Text(needle.isEmpty ? "Showing the first \(shown.count). Filter to find the others."
							: "Showing \(shown.count) of \(matching.count.formatted()) that match.")
					} else if matching.isEmpty {
						Text("No members match.")
					}
				}
				.font(.system(size: 11))
				.foregroundStyle(VaultPalette.textTertiary)
			}
			VaultGroupMemberChips(members: shown, undeclared: Set(shown.lazy.filter { !declared.contains($0) }), isEditable: isEditable) { member in
				update { $0.members.removeAll { $0 == member } }
			}
			if isEditable {
				Text("Declared keys only.").font(.system(size: 11)).foregroundStyle(VaultPalette.textTertiary)
			}
			if isEditable, group.members.isEmpty, !name.isEmpty {
				hintLine("A group needs at least one key.", symbol: "exclamationmark.triangle", tint: VaultPalette.orangeTintText)
			} else if let hint = group.hint {
				hintLine(hint, symbol: "info.circle", tint: VaultPalette.textTertiary)
			}
			if isNew, name.isEmpty, atGroupLimit {
				hintLine("The LPM CLI accepts at most \(SchemaGroup.maximumGroups) groups, and lpm.json and its imports have that many.",
					symbol: "exclamationmark.triangle", tint: VaultPalette.orangeTintText)
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

	/// Member chips the panel draws at most; a larger group is filtered to find the rest.
	private static let shownMemberLimit = 40

	/// Keys the draft declares and undeclares besides those of the latest evaluation.
	private nonisolated static func declaredChanges(in draft: Draft) -> (added: [String], removed: Set<String>) {
		var added: [String] = []
		var removed: Set<String> = []
		for case .key(let key) in draft.changedItems {
			// A removed override leaves the imported key declared; only lpm.json's own removal undeclares it.
			if draft.declaration(of: .key(key)) == .absent {
				if case .declared = draft.base(of: .key(key)) { removed.insert(key) }
			} else {
				added.append(key)
			}
		}
		return (added, removed)
	}

	/// Keys a group can list: those declared once the draft is saved, by the
	/// latest evaluation, with keys the draft adds since.
	private var declaredKeys: Set<String> {
		let changes = Self.declaredChanges(in: draft)
		var keys = currentOverview?.declaredKeys ?? []
		keys.subtract(changes.removed)
		keys.formUnion(changes.added)
		return keys
	}

	/// The keys a group can add, from A to Z: the evaluated `rules` are in
	/// that order already, so only the draft's own additions are placed.
	nonisolated static func pickableKeys(evaluated rules: [ProjectEnvSchemaOverview.Rule], draft: Draft, excluding members: Set<String>) -> [String] {
		let changes = declaredChanges(in: draft)
		let listed = rules.lazy.map(\.key).filter { !changes.removed.contains($0) && !members.contains($0) }
		return VaultKeySortOrder.mergingAscending(changes.added.lazy.filter { !members.contains($0) }, into: Array(listed))
	}

	private func addMemberButton(_ group: SchemaGroup) -> some View {
		let full = memberCount >= SchemaGroup.maximumMembers
		return Button { pickingMember = true } label: {
			HStack(spacing: 4) {
				Image(systemName: "plus").font(.system(size: 9, weight: .semibold))
				Text("Add member").font(.system(size: 11.5, weight: .semibold))
			}
			.foregroundStyle(VaultPalette.accentForeground)
			.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.disabled(full)
		.opacity(full ? 0.4 : 1)
		.vaultPointingHand()
		.help(full ? "The LPM CLI accepts at most \(SchemaGroup.maximumMembers) group members in all" : "Add a declared key to the group")
		.accessibilityLabel("Add a key to the group")
		.popover(isPresented: $pickingMember, arrowEdge: .leading) {
			VaultKeyPicker(keys: Self.pickableKeys(evaluated: currentOverview?.rules ?? [], draft: draft, excluding: Set(group.members)), secretKeys: currentOverview?.secretKeys ?? []) { picked in
				pickingMember = false
				update { if !$0.members.contains(picked) { $0.members.append(picked) } }
			}
			.frame(width: 260, height: 300)
			.padding(10)
		}
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
			let renamed = draft.newName(ofGroup: name)
			VStack(alignment: .leading, spacing: 8) {
				HStack(spacing: 6) {
					VaultTagBadge(text: renamed == nil ? "Removed" : "Renamed", foreground: VaultPalette.redText, background: VaultPalette.redTint, size: 10)
					Text("in your draft").font(.system(size: 12, weight: .semibold)).foregroundStyle(VaultPalette.textPrimary)
				}
				Text(renamed.map { "Your draft renames it to \($0.escapingDirectionControls)." }
					?? "The group leaves lpm.json when you save, and the LPM CLI stops checking its keys together.")
					.font(.system(size: 11.5))
					.foregroundStyle(VaultPalette.textSecondary)
					.fixedSize(horizontal: false, vertical: true)
				HStack(spacing: 6) {
					if let renamed {
						VaultBarButton(title: "Open \(renamed.escapingDirectionControls)", height: 24) { onSelect(.group(renamed)) }
						VaultBarButton(systemImage: "arrow.uturn.backward", title: "Keep the name", height: 24) {
							discardChanges(of: renamed)
						}
						.disabled(!canEdit)
					} else {
						VaultBarButton(systemImage: "arrow.uturn.backward", title: "Keep group", height: 24) { discardChanges(of: name) }
							.disabled(!canEdit)
					}
				}
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
				VaultBarButton(title: "Keep override", height: 24) { discardChanges(of: name) }
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
			VStack(alignment: .leading, spacing: 8) {
				noticeContent(symbol: "square.stack.3d.up", text: "This override in lpm.json replaces the group from \(source).")
				VaultBarButton(systemImage: "arrow.uturn.backward", title: "Reset to original", height: 24) { update(declaration: .absent) }
					.disabled(!canEdit)
					.help("Removes the override, so the group from \(source) applies")
			}
			.foregroundStyle(VaultPalette.accentText)
			.padding(10)
			.frame(maxWidth: .infinity, alignment: .leading)
			.background(RoundedRectangle(cornerRadius: 8).fill(VaultPalette.accentTint))
			.padding(.horizontal, 16)
			.padding(.bottom, 12)
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
		} else if draft.hasChange(to: item), hasChangesToDiscard {
			{
				let wasNew = isNew
				editsOverride = false
				discardChanges(of: name)
				if wasNew { onSelect(nil) }
			}
		} else {
			nil
		}
		// Saving now would leave out the group being added, which the draft can't hold yet.
		let pending: String? = if name.isEmpty, !field.isEmpty || !newGroup.members.isEmpty {
			nameStatus(field) == .available ? "Add a key to add the group to your draft." : "Name the group and add a key to add it to your draft."
		} else {
			nil
		}
		return VaultSchemaEditorFooter(store: store, project: project, item: item, readOnlyAction: readOnlyAction, discard: discard,
			discardEdits: !name.isEmpty, pending: pending, onSelect: onSelect, onReview: onReview) {
			editsOverride = false
		}
	}

	/// Whether discarding changes anything: not when the group's only change
	/// is dropping keys the draft removes, which it has to keep.
	private var hasChangesToDiscard: Bool {
		let draft = draft
		var discarded = draft
		Self.discardChanges(of: name, in: &discarded)
		let original = draft.originalName(ofGroup: name)
		let items = [item] + (original.map { [Draft.Item.group($0)] } ?? [])
		return original != nil || items.contains { !discarded.declaration(of: $0).isEquivalent(to: draft.declaration(of: $0)) }
	}

	/// Takes back the draft's changes to the group named `name`, and its rename.
	private func discardChanges(of name: String) {
		let original = draft.originalName(ofGroup: name)
		store.editSchemaDraft(in: project.id) { Self.discardChanges(of: name, in: &$0) }
		if let original, name == self.name { onFollow(.group(original)) }
	}

	/// Keys the draft removes stay out of the group, since lpm.json can't
	/// list a key it doesn't declare.
	private static func discardChanges(of name: String, in draft: inout Draft) {
		let original = draft.originalName(ofGroup: name)
		draft.discardGroup(name)
		let restored = Draft.Item.group(original ?? name)
		guard case .array(let members)? = draft.declaration(of: restored).json?["vars"] else { return }
		let kept = members.filter { member in
			guard case .string(let key) = member, draft.declaration(of: .key(key)) == .absent, case .declared = draft.base(of: .key(key)) else { return true }
			return false
		}
		guard kept.count != members.count else { return }
		draft.set(draft.declaration(of: restored).replacingJSON { $0.set(.array(kept), forKey: "vars") }, for: restored)
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
			park(name, keeping: updated)
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

/// The chips of the members a group panel shows.
private struct VaultGroupMemberChips: View {
	let members: [String]
	/// Members that aren't declared, which the LPM CLI rejects.
	let undeclared: Set<String>
	let isEditable: Bool
	let onRemove: (String) -> Void

	var body: some View {
		VaultFlowLayout(spacing: 6, lineSpacing: 6) {
			ForEach(members, id: \.self) { member in
				let shown = member.escapingDirectionControls
				let isDeclared = !undeclared.contains(member)
				HStack(spacing: 5) {
					Text(shown)
						.font(VaultTypography.mono(11.5, .medium))
						.foregroundStyle(isDeclared ? VaultPalette.textPrimary : VaultPalette.redText)
						.lineLimit(1)
					if isEditable {
						Button { onRemove(member) } label: {
							Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(VaultPalette.textFaint)
						}
						.buttonStyle(.plain)
						.accessibilityLabel("Remove \(shown) from the group")
					}
				}
				.padding(.horizontal, 7)
				.frame(height: 24)
				.overlay { RoundedRectangle(cornerRadius: 5).stroke(VaultPalette.border, lineWidth: 1) }
				.help(isDeclared ? "" : "\(shown) isn't declared, which the LPM CLI rejects")
			}
		}
	}
}
