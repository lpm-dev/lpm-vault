import AppKit
import SwiftUI

/// What the Schema page's side panel shows.
enum VaultSchemaSelection: Hashable {
	case key(String)
}

/// The Schema page's side panel: one key's rule, edited into the project's
/// schema draft.
struct VaultSchemaPanel: View {
	@Bindable var store: VaultStore
	let project: VaultProject
	let environments: [String]
	let selection: VaultSchemaSelection
	let onSelect: (VaultSchemaSelection?) -> Void
	/// A key the panel renamed, so pages that show it follow the new name.
	var onRenamed: (String, String) -> Void = { _, _ in }

	var body: some View {
		Group {
			switch selection {
			case .key(let key):
				VaultSchemaKeyEditor(store: store, project: project, environments: environments, key: key,
					onSelect: onSelect, onRenamed: onRenamed)
					.id("\(project.id)/\(key)")
			}
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
		.background(VaultPalette.inspector)
	}
}

private typealias Rule = ProjectEnvSchemaRule
private typealias Field = ProjectEnvSchemaRule.Field
private typealias Draft = ProjectEnvSchemaDraft

private struct VaultSchemaKeyEditor: View {
	@Bindable var store: VaultStore
	let project: VaultProject
	let environments: [String]
	let key: String
	let onSelect: (VaultSchemaSelection?) -> Void
	let onRenamed: (String, String) -> Void

	/// Rows shown in this panel, which stay while their value is cleared.
	@State private var shownFields: Set<Field> = []
	/// An override is edited only after "Edit override", unless the draft changed it.
	@State private var editsOverride = false
	@State private var name = ""
	@State private var renaming = false
	@State private var renameError: String?
	@State private var saveError: String?
	@State private var addingRule = false
	@State private var scopeTarget: ScopeTarget?
	@State private var pickingKey = false
	/// Whether the panel still shows this key, which a rename finishing later checks.
	@State private var isPresented = false

	private struct ScopeTarget: Identifiable, Hashable {
		let field: Field
		/// The line being edited, as it read when editing began; nil adds one.
		let original: Rule.ScopedDefault?
		/// Where the line was, which anchors the editor.
		let index: Int?
		var id: String { "\(field)-\(index.map(String.init) ?? "new")" }
	}

	fileprivate enum Mode: Equatable {
		/// Editing the rule lpm.json declares, or an override of an imported one.
		case editing(isOverride: Bool)
		/// Declared in an imported schema or a preset; editing makes an override.
		case inherited(source: String)
		/// lpm.json overrides an imported declaration; editing it starts on request.
		case overridden(source: String)
		/// The draft removes lpm.json's override, so the imported rule applies again.
		case reset(source: String)
		/// The draft removes the key from lpm.json.
		case removed
		case missing

		var isOverridden: Bool { if case .overridden = self { true } else { false } }
	}

	// MARK: - State

	private var descriptions: ProjectKeyDescriptions? { store.keyDescriptions[project.id] }
	private var savedOverview: ProjectEnvSchemaOverview? { descriptions?.schema?.overview }
	private var pendingDraft: Draft? { store.schemaDraft(for: project.id) }
	private var draft: Draft { store.schemaDraftOrBase(for: project.id) }
	/// The latest evaluation, which can lag the draft while it's evaluated.
	private var evaluation: Draft.Evaluation? { store.latestSchemaDraftEvaluation(for: project.id) }
	private var overview: ProjectEnvSchemaOverview? { pendingDraft == nil ? savedOverview : evaluation?.overview ?? savedOverview }
	private var item: Draft.Item { .key(key) }
	private var savedRule: ProjectEnvSchemaOverview.Rule? { savedOverview?.rule(for: key) }
	private var saving: Bool { store.savingSchemaDrafts.contains(project.id) }
	private var importedSource: String { savedRule?.overrides ?? savedRule?.source ?? "an imported schema" }

	private var mode: Mode {
		switch draft.declaration(of: item) {
		case .declared: return .editing(isOverride: false)
		case .overridden:
			if case .overridden = draft.base(of: item), !draft.hasChange(to: item), !editsOverride { return .overridden(source: importedSource) }
			return .editing(isOverride: true)
		case .absent:
			switch draft.base(of: item) {
			case .declared: return .removed
			case .overridden: return .reset(source: importedSource)
			case .absent: return savedRule?.source.map { .inherited(source: $0) } ?? .missing
			}
		}
	}

	private var rule: Rule {
		switch draft.declaration(of: item) {
		case .declared(let json), .overridden(let json): return Rule(json)
		case .absent:
			// Only the engine knows the imported rule a removed override leaves.
			if case .overridden = draft.base(of: item) {
				return Rule(resolved: store.currentSchemaDraftEvaluation(for: project.id)?.overview?.declaration(of: key))
			}
			return Rule(resolved: savedOverview?.declaration(of: key))
		}
	}

	private var publicPrefix: String? {
		Rule.publicPrefix(of: key, clientPrefixes: overview?.clientPrefixes ?? [])
	}

	private var context: Rule.Context {
		let overview = overview
		return Rule.Context(
			key: key,
			publicPrefix: Rule.publicPrefix(of: key, clientPrefixes: overview?.clientPrefixes ?? []),
			secretKeys: overview?.secretKeys ?? [],
			comparedBy: overview?.keys(comparing: key) ?? [],
			declaredKeys: overview.map(\.declaredKeys)
		)
	}

	private var rejection: Draft.Rejection? {
		guard let rejection = evaluation?.rejection, rejection.item == item else { return nil }
		return rejection
	}

	private var canEdit: Bool { store.canEditSchema(of: project.id) }

	// MARK: - Body

	var body: some View {
		let mode = mode
		let rule = rule
		let context = context
		let conflicts = mode == .editing(isOverride: false) || mode == .editing(isOverride: true) ? rule.conflicts(in: context) : [:]
		let visible = visibleFields(rule)
		VStack(spacing: 0) {
			ScrollView {
				VStack(alignment: .leading, spacing: 0) {
					header(mode)
					identity(mode, rule: rule, conflicts: conflicts, visible: visible)
					VaultHairline()
					VaultSchemaStoredValues(store: store, project: project, environments: environments, key: key,
						removed: mode == .removed)
					VaultHairline()
					switch mode {
					case .editing:
						editingSections(rule, context: context, conflicts: conflicts, visible: visible)
					case .inherited, .overridden, .reset:
						readOnlySections(rule, mode: mode)
						sourceNotice(mode)
					case .removed:
						removedNotice
					case .missing:
						Text("\(key) isn't declared in lpm.json or the schemas it imports.")
							.font(.system(size: 12))
							.foregroundStyle(VaultPalette.textTertiary)
							.padding(16)
					}
				}
				.frame(maxWidth: .infinity, alignment: .leading)
			}
			VaultHairline()
			footer(mode)
		}
		.background(VaultEscapeResponder(onEscape: { onSelect(nil) }))
		.background(VaultUndoShortcuts(undo: { undo(redo: false) }, redo: { undo(redo: true) }))
		.onAppear {
			name = key
			isPresented = true
		}
		.onDisappear { isPresented = false }
		.onChange(of: name) { renameError = nil }
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

	// MARK: - Header and identity

	private func header(_ mode: Mode) -> some View {
		HStack(spacing: 6) {
			Text("KEY").vaultSectionLabel()
			switch mode {
			case .inherited(let source), .overridden(let source), .reset(let source):
				VaultSourceBadge(source: source)
			case .editing(true):
				VaultSourceBadge(source: importedSource)
			default:
				HStack(spacing: 4) {
					Image(systemName: "doc").font(.system(size: 10))
					Text("lpm.json").font(VaultTypography.mono(11))
				}
				.foregroundStyle(VaultPalette.textTertiary)
			}
			if case .overridden = mode {
				VaultTagBadge(text: "Overridden", foreground: VaultPalette.accentForeground, background: VaultPalette.accentTint, size: 10)
			}
			if draft.hasChange(to: item), mode != .removed {
				VaultTagBadge(text: "Draft", foreground: VaultPalette.orangeTintText, background: VaultPalette.orangeTint, size: 10)
			}
			Spacer(minLength: 4)
			Rectangle().fill(VaultPalette.divider).frame(width: 1, height: 14)
			VaultRowIconButton(systemImage: "xmark", help: "Close") { onSelect(nil) }
		}
		.padding(.leading, 16)
		.padding(.trailing, 10)
		.padding(.top, 12)
		.padding(.bottom, 8)
	}

	@ViewBuilder
	private func identity(_ mode: Mode, rule: Rule, conflicts: [Field: Rule.Conflict], visible: Set<Field>) -> some View {
		VStack(alignment: .leading, spacing: 8) {
			nameField(mode, rule: rule)
			if case .editing = mode {
				descriptionField
				hiddenCharacters(in: rule.description)
			} else if let description = rule.description, !description.isEmpty {
				Text(description.escapingDirectionControls)
					.font(.system(size: 12))
					.foregroundStyle(VaultPalette.textSecondary)
					.fixedSize(horizontal: false, vertical: true)
			}
			if case .editing(true) = mode {
				notice(symbol: "square.stack.3d.up",
					text: "You're editing a copy of the rule from \(importedSource). Saving writes an override to lpm.json that replaces the original; it doesn't merge.")
			}
			if draft.conflicts.contains(where: { $0.item == item }) {
				conflictNotice
			}
			if let rejection, rejectionRow(rejection, mode: mode, visible: visible) == nil,
				!conflicts.contains(where: { visible.contains($0.key) && $0.value.kind == .blocking })
			{
				conflictLine(.init(kind: .blocking, message: rejection.reason, fixes: []))
			}
		}
		.padding(.horizontal, 16)
		.padding(.bottom, 12)
	}

	/// The row that shows the engine's rejection of this key: the first row
	/// it names that the panel shows. Nil shows it under the name.
	private func rejectionRow(_ rejection: Draft.Rejection, mode: Mode, visible: Set<Field>) -> Field? {
		guard case .editing = mode else { return nil }
		return rejection.fields.lazy.compactMap(Field.init(name:)).first(where: visible.contains)
	}

	private var conflictNotice: some View {
		VStack(alignment: .leading, spacing: 8) {
			HStack(alignment: .top, spacing: 8) {
				Image(systemName: "exclamationmark.triangle").font(.system(size: 11)).padding(.top, 1)
				Text("lpm.json changed on disk while you edited this key. Keep your version or take the one on disk.")
					.font(.system(size: 11.5))
					.fixedSize(horizontal: false, vertical: true)
			}
			HStack(spacing: 6) {
				VaultBarButton(title: "Keep mine", height: 24) { resolveConflict(keepingMine: true) }
					.disabled(!canEdit)
				VaultBarButton(title: "Take theirs", height: 24) { resolveConflict(keepingMine: false) }
					.disabled(!canEdit)
			}
			.padding(.leading, 19)
		}
		.foregroundStyle(VaultPalette.orangeTintText)
		.padding(10)
		.frame(maxWidth: .infinity, alignment: .leading)
		.background(RoundedRectangle(cornerRadius: 8).fill(VaultPalette.orangeTint))
	}

	private func resolveConflict(keepingMine: Bool) {
		store.editSchemaDraft(in: project.id) { $0.resolveConflict(item, keepingMine: keepingMine) }
	}

	private func nameField(_ mode: Mode, rule: Rule) -> some View {
		let renamable = mode == .editing(isOverride: false) && draft.base(of: item) != .absent
		let changed = name != key
		let issue = changed ? nameIssue(name, rule: rule) : nil
		let shownPrefix = changed && issue == nil ? Rule.publicPrefix(of: name, clientPrefixes: overview?.clientPrefixes ?? []) : publicPrefix
		return VStack(alignment: .leading, spacing: 6) {
			HStack(spacing: 6) {
				if renamable {
					TextField("KEY_NAME", text: $name)
						.textFieldStyle(.plain)
						.font(VaultTypography.mono(13.5, .bold))
						.autocorrectionDisabled()
						.disabled(!canEdit || renaming)
						.onSubmit { if changed, issue == nil, canRename { rename() } }
						.accessibilityLabel("Key name")
				} else {
					Text(key)
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
				if shownPrefix != nil, mode != .removed { VaultPublicBadge() }
			}
			.padding(.horizontal, 9)
			.frame(height: 32)
			.background(RoundedRectangle(cornerRadius: 8).fill(renamable ? VaultPalette.control : .clear))
			.overlay {
				RoundedRectangle(cornerRadius: 8)
					.stroke(issue != nil ? VaultPalette.red : (renamable ? VaultPalette.border : .clear), lineWidth: issue != nil ? 1.5 : 1)
			}
			if changed, renamable {
				if let issue {
					conflictLine(.init(kind: .blocking, message: issue, fixes: []))
				} else {
					renameDetails
				}
			}
			if let renameError {
				conflictLine(.init(kind: .blocking, message: renameError, fixes: []))
			}
		}
	}

	@ViewBuilder
	private var renameDetails: some View {
		if let note = exposureChange(renamingTo: name) {
			HStack(alignment: .top, spacing: 6) {
				Image(systemName: "globe").font(.system(size: 10)).padding(.top, 1)
				Text(note).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
			}
			.foregroundStyle(VaultPalette.accentText)
		}
		Text(renameSummary)
			.font(.system(size: 11))
			.foregroundStyle(VaultPalette.textTertiary)
			.fixedSize(horizontal: false, vertical: true)
		HStack(spacing: 6) {
			VaultBarButton(title: renaming ? "Renaming…" : "Rename", filled: true, disabled: renaming || !canRename, height: 24, action: rename)
			VaultBarButton(title: "Cancel", height: 24) { name = key }
		}
	}

	private var canRename: Bool { pendingDraft == nil && project.hasLoadedEnvironments && canEdit }

	private var renameSummary: String {
		if pendingDraft != nil { return "Save or discard your rule changes before renaming." }
		guard project.hasLoadedEnvironments else { return "Renaming waits until the project's values are loaded." }
		let stored = environments.filter { project.value(for: key, in: $0) != nil }.count
		return stored == 0 ? "Renames its rule in lpm.json." : "Renames its rule in lpm.json and its values in \(stored == 1 ? "1 environment" : "\(stored) environments")."
	}

	/// How renaming changes whether the key reaches the browser, which the
	/// LPM CLI decides by the name's prefix.
	private func exposureChange(renamingTo name: String) -> String? {
		let after = Rule.publicPrefix(of: name, clientPrefixes: overview?.clientPrefixes ?? [])
		switch (publicPrefix, after) {
		case (nil, let prefix?): return "Becomes public: \(prefix) exposes its value to the browser."
		case (let prefix?, nil): return "Becomes private: without \(prefix), its value stays out of the browser."
		default: return nil
		}
	}

	private func nameIssue(_ name: String, rule: Rule) -> String? {
		guard EnvValidation.isValidVariableName(name) else { return "Use letters, digits and underscores; a name can't start with a digit." }
		if let existing = overview?.keys(named: name, otherThan: key).first {
			return existing == name ? "\(name) is already declared." : "Conflicts with \(existing): names can't differ only in capitalisation."
		}
		if rule.secret, let prefix = Rule.publicPrefix(of: name, clientPrefixes: overview?.clientPrefixes ?? []) {
			return "Secret keys can't start with \(prefix), which makes a key public."
		}
		return nil
	}

	private func rename() {
		let target = name
		renaming = true
		renameError = nil
		Task {
			do {
				try await store.renameDeclaredKey(key, to: target, in: project.id)
				onRenamed(key, target)
				if isPresented { onSelect(.key(target)) }
			} catch {
				renameError = error.localizedDescription
			}
			renaming = false
		}
	}

	private var descriptionField: some View {
		TextField("Description — shown in CLI errors and .env.example", text: textBinding(\.description, field: "description"), axis: .vertical)
			.textFieldStyle(.plain)
			.font(.system(size: 12))
			.lineLimit(1...4)
			.padding(.horizontal, 9)
			.padding(.vertical, 8)
			.background(RoundedRectangle(cornerRadius: 8).fill(VaultPalette.control))
			.overlay { RoundedRectangle(cornerRadius: 8).stroke(VaultPalette.border, lineWidth: 1) }
			.disabled(!canEdit)
			.accessibilityLabel("Description")
	}

	private func notice(symbol: String, text: String, tint: Color = VaultPalette.accentText) -> some View {
		HStack(alignment: .top, spacing: 8) {
			Image(systemName: symbol).font(.system(size: 11)).padding(.top, 1)
			Text(text).font(.system(size: 11.5)).fixedSize(horizontal: false, vertical: true)
		}
		.foregroundStyle(tint)
		.padding(10)
		.frame(maxWidth: .infinity, alignment: .leading)
		.background(RoundedRectangle(cornerRadius: 8).fill(tint == VaultPalette.accentText ? VaultPalette.accentTint : VaultPalette.orangeTint))
	}

	// MARK: - Editing

	private func editingSections(_ rule: Rule, context: Rule.Context, conflicts: [Field: Rule.Conflict], visible: Set<Field>) -> some View {
		let engineRow = rejection.flatMap { rejectionRow($0, mode: mode, visible: visible) }
		return VStack(alignment: .leading, spacing: 0) {
			ForEach(ProjectEnvSchemaRule.Section.allCases, id: \.self) { section in
				let rows = Field.allCases.filter { $0.section == section && visible.contains($0) }
				if !rows.isEmpty {
					VStack(alignment: .leading, spacing: 9) {
						Text(section.title).vaultSectionLabel()
						ForEach(rows, id: \.self) { field in
							let conflict = conflicts[field]
							fieldRow(field, rule: rule, context: context, conflict: conflict,
								engineIssue: engineRow == field && conflict?.kind != .blocking ? rejection?.reason : nil)
						}
					}
					.padding(.horizontal, 16)
					.padding(.top, 12)
					.padding(.bottom, 4)
				}
			}
			addRuleButton(rule, context: context, shown: visible)
				.padding(.horizontal, 16)
				.padding(.vertical, 12)
		}
	}

	private func visibleFields(_ rule: Rule) -> Set<Field> {
		var fields = shownFields.union(Field.allCases.filter(rule.has))
		if publicPrefix != nil { fields.insert(.client) }
		return fields
	}

	@ViewBuilder
	private func fieldRow(_ field: Field, rule: Rule, context: Rule.Context, conflict: Rule.Conflict?, engineIssue: String?) -> some View {
		VStack(alignment: .leading, spacing: 5) {
			if field.isStacked {
				HStack(spacing: 8) {
					label(field)
					Spacer(minLength: 4)
					removeButton(field)
				}
				control(field, rule: rule, context: context)
			} else {
				HStack(alignment: .center, spacing: 8) {
					label(field).frame(width: 84, alignment: .leading)
					control(field, rule: rule, context: context)
						.frame(maxWidth: .infinity, alignment: .leading)
					removeButton(field)
				}
			}
			hiddenCharacters(in: Self.text(of: field, in: rule))
			if let conflict { conflictLine(conflict) }
			if let engineIssue { conflictLine(.init(kind: .blocking, message: engineIssue, fixes: [])) }
		}
		.opacity(conflict?.kind == .noEffect ? 0.55 : 1)
	}

	private func label(_ field: Field) -> some View {
		Text(field.title)
			.font(.system(size: 11.5))
			.foregroundStyle(VaultPalette.textTertiary)
			.lineLimit(1)
	}

	@ViewBuilder
	private func removeButton(_ field: Field) -> some View {
		if field != .client {
			Button {
				update { $0.remove(field) }
				shownFields.remove(field)
			} label: {
				Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)).foregroundStyle(VaultPalette.textFaint)
					.frame(width: 18, height: 18).contentShape(Rectangle())
			}
			.buttonStyle(.plain)
			.disabled(!canEdit)
			.help("Remove rule")
			.accessibilityLabel("Remove \(field.title)")
		} else {
			Color.clear.frame(width: 18, height: 18)
		}
	}

	@ViewBuilder
	private func control(_ field: Field, rule: Rule, context: Rule.Context) -> some View {
		switch field {
		case .required:
			toggle(\.required, label: "Required")
		case .secret:
			toggle(\.secret, label: "Secret", disabled: !rule.secret && !rule.availability(of: .secret, in: context).isAvailable)
		case .client:
			HStack(spacing: 6) {
				toggle(\.client, label: "Public", disabled: true)
				if publicPrefix != nil {
					Text("from the name").font(.system(size: 11)).foregroundStyle(VaultPalette.textTertiary)
				}
			}
		case .empty:
			segmented(Rule.EmptyPolicy.allCases, selection: rule.empty, title: \.title, label: "Empty values") { value in update { $0.empty = value } }
		case .ci:
			segmented(Rule.CIStorage.allCases, selection: rule.ci ?? .secret, title: \.rawValue, label: "CI storage",
				disabled: rule.secret ? [.variable] : []) { value in update { $0.ci = value } }
		case .format:
			Menu {
				ForEach(Rule.Format.allCases, id: \.self) { format in
					Button(format.title) { update { $0.format = format } }
				}
			} label: {
				fieldBox(rule.format?.title ?? "None", placeholder: rule.format == nil, chevron: true)
			}
			.menuStyle(.button)
			.buttonStyle(.plain)
			.menuIndicator(.hidden)
			.disabled(!canEdit)
			.accessibilityLabel("Format")
			.accessibilityValue(rule.format?.title ?? "None")
		case .bounds:
			HStack(spacing: 6) {
				textField("min", label: "Minimum value", text: \.min, field: "min")
				textField("max", label: "Maximum value", text: \.max, field: "max")
			}
		case .length:
			HStack(spacing: 6) {
				textField("min", label: "Minimum length", text: \.minLength, field: "minLength")
				textField("max", label: "Maximum length", text: \.maxLength, field: "maxLength")
			}
		case .pattern:
			textField("regular expression", label: "Pattern", text: \.pattern, field: "pattern")
		case .defaultValue:
			textField("value", label: "Default", text: \.defaultValue, field: "default")
		case .protocols:
			VaultChipField(values: rule.protocols ?? [], placeholder: "https", label: "Protocols", disabled: !canEdit,
				normalize: VaultChipField.scheme) { values in update { $0.protocols = values } }
		case .allowedValues:
			VaultChipField(values: rule.allowedValues ?? [], placeholder: "value", label: "Allowed values", disabled: !canEdit,
				normalize: VaultChipField.literal) { values in update { $0.allowedValues = values } }
				.help("Type \"\" for an empty value, or quote a value to keep its leading or trailing spaces.")
		case .requiredIn:
			scopeLines(rule.requiredIn.map { .init(scope: $0, value: "") }, field: .requiredIn)
		case .defaultsIn:
			scopeLines(rule.defaultsIn, field: .defaultsIn)
		case .requiredWhen:
			requiredWhenControl(rule, context: context)
		}
	}

	/// The text a row's field edits, if it has one.
	private static func text(of field: Field, in rule: Rule) -> String? {
		switch field {
		case .pattern: rule.pattern
		case .defaultValue: rule.defaultValue
		case .requiredWhen: if case .equals(let value)? = rule.requiredWhen?.condition { value } else { nil }
		default: nil
		}
	}

	// MARK: - Controls

	/// Reads and writes the rule as it is when asked, like `textBinding`.
	private func toggle(_ field: WritableKeyPath<Rule, Bool>, label: String, disabled: Bool = false) -> some View {
		Toggle(label, isOn: Binding(get: { rule[keyPath: field] }, set: { value in update { $0[keyPath: field] = value } }))
			.toggleStyle(.switch)
			.controlSize(.mini)
			.labelsHidden()
			.disabled(disabled || !canEdit)
	}

	private func segmented<Value: Hashable>(
		_ values: [Value], selection: Value, title: KeyPath<Value, String>, label: String,
		disabled: Set<Value> = [], _ set: @escaping (Value) -> Void
	) -> some View {
		HStack(spacing: 0) {
			ForEach(Array(values.enumerated()), id: \.element) { index, value in
				let selected = value == selection
				let off = disabled.contains(value)
				Button { set(value) } label: {
					Text(value[keyPath: title])
						.font(.system(size: 11, weight: selected ? .semibold : .regular))
						.foregroundStyle(selected ? VaultPalette.content : (off ? VaultPalette.textFaint : VaultPalette.textSecondary))
						.padding(.horizontal, 8)
						.frame(height: 24)
						.background(selected ? VaultPalette.textPrimary : .clear)
						.contentShape(Rectangle())
				}
				.buttonStyle(.plain)
				.disabled(off || !canEdit)
				.overlay(alignment: .leading) {
					if index > 0 { Rectangle().fill(VaultPalette.border).frame(width: 1) }
				}
				.accessibilityLabel("\(label): \(value[keyPath: title])")
				.accessibilityAddTraits(selected ? .isSelected : [])
			}
		}
		.clipShape(RoundedRectangle(cornerRadius: 6))
		.overlay { RoundedRectangle(cornerRadius: 6).stroke(VaultPalette.border, lineWidth: 1) }
		.fixedSize()
	}

	private func fieldBox(_ text: String, placeholder: Bool = false, chevron: Bool = false) -> some View {
		HStack(spacing: 6) {
			Text(text)
				.font(.system(size: 12))
				.foregroundStyle(placeholder ? VaultPalette.textFaint : VaultPalette.textPrimary)
				.lineLimit(1)
			Spacer(minLength: 4)
			if chevron { Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(VaultPalette.textTertiary) }
		}
		.padding(.horizontal, 9)
		.frame(height: 28)
		.frame(maxWidth: .infinity)
		.background(RoundedRectangle(cornerRadius: 7).fill(VaultPalette.control))
		.overlay { RoundedRectangle(cornerRadius: 7).stroke(VaultPalette.border, lineWidth: 1) }
		.contentShape(Rectangle())
	}

	/// Text from lpm.json with characters that hide or reorder what's shown,
	/// which an edit field can't escape, written out with them escaped.
	@ViewBuilder
	private func hiddenCharacters(in text: String?) -> some View {
		if let text, text.hasHiddenCharacters {
			HStack(alignment: .top, spacing: 6) {
				Image(systemName: "eye.trianglebadge.exclamationmark").font(.system(size: 10)).padding(.top, 1)
				Text("Has hidden or reordering characters: \(text.escapingDirectionControls)")
					.font(.system(size: 11))
					.fixedSize(horizontal: false, vertical: true)
			}
			.foregroundStyle(VaultPalette.orangeTintText)
		}
	}

	private func textField(_ placeholder: String, label: String, text: WritableKeyPath<Rule, String?>, field: String) -> some View {
		TextField(placeholder, text: textBinding(text, field: field))
			.textFieldStyle(.plain)
			.font(VaultTypography.mono(12))
			.autocorrectionDisabled()
			.padding(.horizontal, 9)
			.frame(height: 28)
			.background(RoundedRectangle(cornerRadius: 7).fill(VaultPalette.control))
			.overlay { RoundedRectangle(cornerRadius: 7).stroke(VaultPalette.border, lineWidth: 1) }
			.disabled(!canEdit)
			.accessibilityLabel(label)
	}

	/// Reads the rule as it is when asked, not when the panel last drew, so
	/// ending an edit before the panel redraws can't write an older value back.
	private func textBinding(_ text: WritableKeyPath<Rule, String?>, field: String) -> Binding<String> {
		Binding(get: { rule[keyPath: text] ?? "" }, set: { value in update(coalescing: field) { $0[keyPath: text] = value } })
	}

	private func requiredWhenControl(_ rule: Rule, context: Rule.Context) -> some View {
		let condition = rule.requiredWhen
		let hasCandidates = context.declaredKeys?.contains(where: { $0 != key }) ?? false
		return VStack(alignment: .leading, spacing: 6) {
			Button { pickingKey = true } label: {
				fieldBox(condition?.variable ?? "Choose a key", placeholder: condition == nil, chevron: true)
			}
			.buttonStyle(.plain)
			.disabled(!canEdit || !hasCandidates)
			.accessibilityLabel("Required when key")
			.accessibilityValue(condition?.variable ?? "None")
			.popover(isPresented: $pickingKey, arrowEdge: .leading) {
				VaultKeyPicker(keys: (overview?.rules ?? []).lazy.map(\.key).filter { $0 != key }, secretKeys: context.secretKeys) { picked in
					pickingKey = false
					update { $0.requiredWhen = Self.condition($0.requiredWhen, on: picked, secretKeys: context.secretKeys) }
				}
			}
			if let condition {
				HStack(spacing: 6) {
					Menu {
						if !context.secretKeys.contains(condition.variable) {
							Button("equals") {
								if case .equals = condition.condition { return }
								update { $0.requiredWhen = .init(variable: condition.variable, condition: .equals("")) }
							}
						}
						Button("is set") { update { $0.requiredWhen = .init(variable: condition.variable, condition: .present(true)) } }
						Button("is not set") { update { $0.requiredWhen = .init(variable: condition.variable, condition: .present(false)) } }
					} label: {
						fieldBox(Self.conditionTitle(condition.condition), chevron: true).frame(width: 110)
					}
					.menuStyle(.button)
					.buttonStyle(.plain)
					.menuIndicator(.hidden)
					.fixedSize()
					.disabled(!canEdit)
					.accessibilityLabel("Required when condition")
					.accessibilityValue(Self.conditionTitle(condition.condition))
					if case .equals = condition.condition {
						TextField("value", text: Binding(
							get: { if case .equals(let value)? = self.rule.requiredWhen?.condition { value } else { "" } },
							set: { text in
								update(coalescing: "requiredWhen") { rule in
									guard let variable = rule.requiredWhen?.variable else { return }
									rule.requiredWhen = .init(variable: variable, condition: .equals(text))
								}
							}
						))
						.textFieldStyle(.plain)
						.font(VaultTypography.mono(12))
						.padding(.horizontal, 9)
						.frame(height: 28)
						.background(RoundedRectangle(cornerRadius: 7).fill(VaultPalette.control))
						.overlay { RoundedRectangle(cornerRadius: 7).stroke(VaultPalette.border, lineWidth: 1) }
						.disabled(!canEdit)
						.accessibilityLabel("Required when value")
					}
				}
			}
		}
	}

	/// The condition on `variable`, keeping the current one unless it compares
	/// a secret key's value, which the LPM CLI rejects.
	private static func condition(_ current: Rule.RequiredWhen?, on variable: String, secretKeys: Set<String>) -> Rule.RequiredWhen {
		var condition = current?.condition ?? .present(true)
		if case .equals = condition, secretKeys.contains(variable) { condition = .present(true) }
		return .init(variable: variable, condition: condition)
	}

	private static func conditionTitle(_ condition: Rule.RequiredWhen.Condition) -> String {
		switch condition {
		case .equals: "equals"
		case .present(true): "is set"
		case .present(false): "is not set"
		}
	}

	private func scopeLines(_ lines: [Rule.ScopedDefault], field: Field) -> some View {
		VStack(alignment: .leading, spacing: 5) {
			ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
				HStack(alignment: .top, spacing: 4) {
					VStack(alignment: .leading, spacing: 2) {
						Text(line.scope.summary.escapingDirectionControls)
							.font(VaultTypography.mono(11.5))
							.foregroundStyle(VaultPalette.textPrimary)
							.fixedSize(horizontal: false, vertical: true)
						if field == .defaultsIn {
							Text("→ " + (line.value.isEmpty ? "\"\"" : line.value.escapingDirectionControls))
								.font(VaultTypography.mono(11))
								.foregroundStyle(VaultPalette.textSecondary)
								.lineLimit(2)
						}
					}
					Spacer(minLength: 4)
					VaultRowIconButton(systemImage: "pencil", help: "Edit scope \(line.scope.summary)") {
						scopeTarget = .init(field: field, original: line, index: index)
					}
					.disabled(!canEdit)
					VaultRowIconButton(systemImage: "xmark", help: "Remove scope \(line.scope.summary)") { removeScope(line, field: field) }
						.disabled(!canEdit)
				}
				.padding(.leading, 8)
				.padding(.vertical, 3)
				.background(RoundedRectangle(cornerRadius: 7).fill(VaultPalette.control))
				.overlay { RoundedRectangle(cornerRadius: 7).stroke(VaultPalette.border, lineWidth: 1) }
				.popover(item: popoverBinding(field: field, index: index), arrowEdge: .leading) { target in
					scopeEditor(target, lines: lines)
				}
			}
			Button { scopeTarget = .init(field: field, original: nil, index: nil) } label: {
				HStack(spacing: 4) {
					Image(systemName: "plus").font(.system(size: 9, weight: .semibold))
					Text("Scope").font(.system(size: 11))
				}
				.foregroundStyle(VaultPalette.textTertiary)
				.padding(.horizontal, 8)
				.frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
				.overlay { RoundedRectangle(cornerRadius: 6).stroke(VaultPalette.border, style: StrokeStyle(lineWidth: 1, dash: [3, 2])) }
				.contentShape(Rectangle())
			}
			.buttonStyle(.plain)
			.disabled(!canEdit)
			.accessibilityLabel(field == .requiredIn ? "Add a scope where the key is required" : "Add a scoped default")
			.popover(item: popoverBinding(field: field, index: nil), arrowEdge: .leading) { target in
				scopeEditor(target, lines: lines)
			}
		}
	}

	private func popoverBinding(field: Field, index: Int?) -> Binding<ScopeTarget?> {
		Binding(
			get: { scopeTarget?.field == field && scopeTarget?.index == index ? scopeTarget : nil },
			set: { if $0 == nil, scopeTarget?.field == field, scopeTarget?.index == index { scopeTarget = nil } }
		)
	}

	private func scopeEditor(_ target: ScopeTarget, lines: [Rule.ScopedDefault]) -> some View {
		var others = lines.map(\.scope)
		if let original = target.original, let index = lines.firstIndex(of: original) { others.remove(at: index) }
		return VaultScopeEditor(
			environments: environments,
			initial: target.original?.scope ?? Rule.Scope(),
			initialValue: target.field == .defaultsIn ? (target.original?.value ?? "") : nil,
			isNew: target.original == nil,
			others: others
		) { scope, value in
			update { rule in
				let entry = Rule.ScopedDefault(scope: scope, value: value ?? "")
				if target.field == .requiredIn {
					rule.requiredIn = rule.requiredIn.replacingEntry(target.original?.scope, with: scope)
				} else {
					rule.defaultsIn = rule.defaultsIn.replacingEntry(target.original, with: entry)
				}
			}
			scopeTarget = nil
		} onCancel: {
			scopeTarget = nil
		}
	}

	private func removeScope(_ line: Rule.ScopedDefault, field: Field) {
		update { rule in
			if field == .requiredIn {
				var scopes = rule.requiredIn
				if let index = scopes.firstIndex(of: line.scope) { scopes.remove(at: index) }
				rule.requiredIn = scopes
			} else {
				var defaults = rule.defaultsIn
				if let index = defaults.firstIndex(of: line) { defaults.remove(at: index) }
				rule.defaultsIn = defaults
			}
		}
	}

	private func conflictLine(_ conflict: Rule.Conflict) -> some View {
		VStack(alignment: .leading, spacing: 4) {
			HStack(alignment: .top, spacing: 6) {
				Image(systemName: conflict.kind == .blocking ? "lock" : "info.circle")
					.font(.system(size: 10))
					.padding(.top, 1)
				Text(conflict.message)
					.font(.system(size: 11))
					.fixedSize(horizontal: false, vertical: true)
			}
			.foregroundStyle(conflict.kind == .blocking ? VaultPalette.redText : VaultPalette.textTertiary)
			if !conflict.fixes.isEmpty {
				HStack(spacing: 10) {
					ForEach(conflict.fixes, id: \.self) { fix in
						Button(fix.title) { apply(fix) }
							.buttonStyle(.plain)
							.font(.system(size: 11, weight: .semibold))
							.foregroundStyle(VaultPalette.accentForeground)
							.disabled(!canEdit)
							.vaultPointingHand()
					}
				}
				.padding(.leading, 16)
			}
		}
	}

	private func apply(_ fix: Rule.Fix) {
		update { $0.apply(fix) }
		if case .remove(let field) = fix { shownFields.remove(field) }
	}

	// MARK: - Add rule

	private func addRuleButton(_ rule: Rule, context: Rule.Context, shown: Set<Field>) -> some View {
		Button { addingRule = true } label: {
			HStack(spacing: 5) {
				Image(systemName: "plus").font(.system(size: 10, weight: .semibold))
				Text("Add rule").font(.system(size: 12))
				Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
			}
			.foregroundStyle(VaultPalette.textSecondary)
			.padding(.horizontal, 10)
			.frame(height: 26)
			.background(RoundedRectangle(cornerRadius: 7).fill(addingRule ? VaultPalette.accentTint : VaultPalette.control))
			.overlay { RoundedRectangle(cornerRadius: 7).stroke(addingRule ? VaultPalette.accent.opacity(0.5) : VaultPalette.border, lineWidth: 1) }
			.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.disabled(!canEdit)
		.accessibilityLabel("Add rule")
		.popover(isPresented: $addingRule, arrowEdge: .bottom) {
			VaultAddRuleMenu(fields: Field.allCases.filter { !shown.contains($0) }.map { ($0, rule.availability(of: $0, in: context)) }) { field in
				addingRule = false
				add(field)
			}
		}
	}

	/// Shows a row. Rows that are a choice wait for it, so adding one writes
	/// nothing until a value is picked; a switch starts on.
	private func add(_ field: Field) {
		switch field {
		case .required: update { $0.required = true }
		case .secret: update { $0.secret = true }
		case .requiredIn, .defaultsIn: scopeTarget = .init(field: field, original: nil, index: nil)
		default: break
		}
		shownFields.insert(field)
	}

	// MARK: - Read-only

	@ViewBuilder
	private func readOnlySections(_ rule: Rule, mode: Mode) -> some View {
		if case .reset(let source) = mode, store.currentSchemaDraftEvaluation(for: project.id)?.overview == nil {
			Text(rejection == nil ? "Reading the rule from \(source)…" : "The rule from \(source) can't be shown until the rules are valid.")
				.font(.system(size: 12))
				.foregroundStyle(VaultPalette.textTertiary)
				.padding(16)
		}
		VStack(alignment: .leading, spacing: 0) {
			ForEach(ProjectEnvSchemaRule.Section.allCases, id: \.self) { section in
				let rows = Field.allCases.filter { $0.section == section && rule.has($0) }
				if !rows.isEmpty {
					VStack(alignment: .leading, spacing: 8) {
						Text(section.title).vaultSectionLabel()
						ForEach(rows, id: \.self) { field in
							HStack(alignment: .top, spacing: 8) {
								label(field).frame(width: 84, alignment: .leading).padding(.top, 3)
								VaultFlowLayout(spacing: 4, lineSpacing: 4) {
									ForEach(Self.badges(for: field, in: rule), id: \.self) { VaultRuleBadge(badge: $0) }
								}
							}
						}
					}
					.padding(.horizontal, 16)
					.padding(.top, 12)
					.padding(.bottom, 4)
				}
			}
		}
	}

	private static func badges(for field: Field, in rule: Rule) -> [ProjectEnvSchemaOverview.Badge] {
		switch field {
		case .client: return [.init(text: "Public")]
		case .ci: return [.init(text: rule.ci == .variable ? "CI variable" : "CI secret")]
		default:
			let members: [LPMConfigJSON.Member] = field.names.compactMap { name in rule.json[name].map { .init(key: name, value: $0) } }
			return ProjectEnvSchemaOverview.badges(for: .object(members)).map {
				.init(text: $0.text.escapingDirectionControls, help: $0.help?.escapingDirectionControls)
			}
		}
	}

	private func sourceNotice(_ mode: Mode) -> some View {
		VStack(alignment: .leading, spacing: 8) {
			switch mode {
			case .overridden(let source):
				Text("This override in lpm.json replaces the rule from \(source).")
					.font(.system(size: 11.5))
					.foregroundStyle(VaultPalette.textSecondary)
					.fixedSize(horizontal: false, vertical: true)
				HStack(spacing: 6) {
					VaultBarButton(systemImage: "arrow.uturn.backward", title: "Reset to original", height: 24) {
						update(declaration: .absent)
					}
					.disabled(!canEdit)
					Text("removes the override").font(.system(size: 11)).foregroundStyle(VaultPalette.textFaint)
				}
			case .reset(let source):
				Text("Saving removes the override from lpm.json, so the rule from \(source) applies again.")
					.font(.system(size: 11.5))
					.foregroundStyle(VaultPalette.textSecondary)
					.fixedSize(horizontal: false, vertical: true)
				VaultBarButton(systemImage: "arrow.uturn.backward", title: "Keep override", height: 24) {
					store.editSchemaDraft(in: project.id) { $0.discard(.key(key)) }
				}
				.disabled(!canEdit)
			case .inherited(let source):
				HStack(spacing: 5) {
					Image(systemName: "lock").font(.system(size: 10))
					Text("Declared in ").font(.system(size: 11.5)) + Text(source).font(VaultTypography.mono(11))
				}
				.foregroundStyle(VaultPalette.textSecondary)
				Text("Overriding saves a copy in lpm.json that replaces this rule. The key can't be renamed or removed here.")
					.font(.system(size: 11.5))
					.foregroundStyle(VaultPalette.textTertiary)
					.fixedSize(horizontal: false, vertical: true)
			default:
				EmptyView()
			}
		}
		.padding(12)
		.frame(maxWidth: .infinity, alignment: .leading)
		.overlay { RoundedRectangle(cornerRadius: 8).stroke(VaultPalette.border, style: StrokeStyle(lineWidth: 1, dash: [3, 2])) }
		.padding(16)
	}

	private var removedNotice: some View {
		VStack(alignment: .leading, spacing: 8) {
			Text("Its rules leave lpm.json when you save. Values stay in the Keychain.")
				.font(.system(size: 11.5))
				.foregroundStyle(VaultPalette.textSecondary)
				.fixedSize(horizontal: false, vertical: true)
			VaultBarButton(systemImage: "arrow.uturn.backward", title: "Keep in schema", height: 24) {
				store.editSchemaDraft(in: project.id) { $0.discard(.key(key)) }
			}
			.disabled(!canEdit)
		}
		.padding(16)
	}

	// MARK: - Footer

	/// Why Save is off while the draft has changes, and the item to show for it.
	private struct Blocker {
		let message: String
		var key: String?
	}

	private var blocker: Blocker? {
		guard let draft = pendingDraft else { return nil }
		if let conflict = draft.conflicts.first(where: { $0.item == item }) ?? draft.conflicts.first {
			if conflict.item == item { return Blocker(message: "Choose a version of this key above to save.") }
			return Blocker(message: "Can't save until you choose a version of \(Self.name(of: conflict.item)), which changed on disk.", key: conflict.item.key)
		}
		guard let current = store.currentSchemaDraftEvaluation(for: project.id) else { return Blocker(message: "Checking the rules…") }
		guard let rejection = current.rejection else { return nil }
		if rejection.item == item { return Blocker(message: "Fix the problem above to save.") }
		guard let other = rejection.item else { return Blocker(message: "Can't save: \(rejection.reason)") }
		return Blocker(message: "Can't save: \(Self.name(of: other)) has a problem. \(rejection.reason)", key: other.key)
	}

	private static func name(of item: Draft.Item) -> String {
		switch item {
		case .key(let key): key
		case .group(let name): "the group \(name)"
		case .clientPrefixes: "the client prefixes"
		}
	}

	private func footer(_ mode: Mode) -> some View {
		let changes = pendingDraft?.changeCount ?? 0
		let blocker = blocker
		return VStack(alignment: .leading, spacing: 6) {
			if let saveError {
				Text(saveError)
					.font(.system(size: 11))
					.foregroundStyle(VaultPalette.redText)
					.fixedSize(horizontal: false, vertical: true)
			}
			if let blocker {
				HStack(alignment: .firstTextBaseline, spacing: 6) {
					Text(blocker.message)
						.font(.system(size: 11))
						.foregroundStyle(VaultPalette.textTertiary)
						.fixedSize(horizontal: false, vertical: true)
					if let other = blocker.key {
						Button("Show") { onSelect(.key(other)) }
							.buttonStyle(.plain)
							.font(.system(size: 11, weight: .semibold))
							.foregroundStyle(VaultPalette.accentForeground)
							.vaultPointingHand()
							.accessibilityLabel("Show \(other)")
					}
				}
			}
			HStack(spacing: 8) {
				switch mode {
				case .inherited, .overridden:
					Text("Read-only").font(.system(size: 11)).foregroundStyle(VaultPalette.textFaint)
					Spacer(minLength: 4)
					VaultBarButton(systemImage: "pencil", title: mode.isOverridden ? "Edit override" : "Override rules", height: 26) {
						if mode.isOverridden { editsOverride = true } else { update(declaration: .overridden(rule.json)) }
					}
					.disabled(!canEdit)
				default:
					if changes > 0 {
						HStack(spacing: 4) {
							Image(systemName: "arrow.uturn.backward").font(.system(size: 9, weight: .semibold))
							Text(changes == 1 ? "1 change" : "\(changes) changes").font(.system(size: 11, weight: .medium))
						}
						.foregroundStyle(VaultPalette.orangeTintText)
						.help("⌘Z undoes the last change")
					} else {
						Text("No changes").font(.system(size: 11)).foregroundStyle(VaultPalette.textFaint)
					}
					Spacer(minLength: 4)
					if draft.hasChange(to: item) {
						VaultBarButton(title: "Discard", height: 26) {
							shownFields = []
							editsOverride = false
							saveError = nil
							store.editSchemaDraft(in: project.id) { $0.discard(.key(key)) }
						}
						.disabled(!canEdit)
					}
					VaultBarButton(title: saving ? "Saving…" : "Save", filled: true, disabled: changes == 0 || blocker != nil || !canEdit, height: 26, action: save)
				}
			}
		}
		.padding(.horizontal, 14)
		.padding(.vertical, 10)
		.background(VaultPalette.headerRow)
	}

	private func save() {
		saveError = nil
		Task {
			do throws(ProjectEnvSchemaFile.DraftSaveError) {
				try await store.saveSchemaDraft(in: project.id)
				shownFields = []
				editsOverride = false
			} catch .file(.changed) {
				saveError = "lpm.json changed on disk. Your changes were merged into it; check them and save again."
			} catch {
				saveError = error.message
			}
		}
	}

	// MARK: - Updates

	/// Changes the rule. Rows shown before the change stay, so clearing a
	/// field leaves its row to type into.
	private func update(coalescing field: String? = nil, _ change: (inout Rule) -> Void) {
		var rule = rule
		shownFields.formUnion(Field.allCases.filter(rule.has))
		change(&rule)
		let isOverride: Bool = switch mode {
		case .editing(true), .overridden: true
		default: false
		}
		update(declaration: isOverride ? .overridden(rule.json) : .declared(rule.json), coalescing: field)
	}

	private func update(declaration: Draft.Declaration, coalescing field: String? = nil) {
		saveError = nil
		store.editSchemaDraft(in: project.id, coalescing: field.map { "\(key)/\($0)" }) { $0.set(declaration, for: item) }
	}
}

extension Array where Element: Equatable {
	/// The entries with `original` replaced, or `entry` added when it's new or
	/// no longer there, as when lpm.json changed while it was edited.
	func replacingEntry(_ original: Element?, with entry: Element) -> [Element] {
		var entries = self
		if let original, let index = entries.firstIndex(of: original) { entries[index] = entry } else { entries.append(entry) }
		return entries
	}
}

private extension ProjectEnvSchemaDraft.Item {
	var key: String? { if case .key(let key) = self { key } else { nil } }
}

private extension ProjectEnvSchemaRule.Field {
	/// Rows whose control needs the panel's full width.
	var isStacked: Bool {
		switch self {
		case .requiredIn, .requiredWhen, .defaultsIn, .protocols, .allowedValues: true
		default: false
		}
	}
}

// MARK: - Undo shortcuts

/// ⌘Z and ⇧⌘Z undo and redo rule changes, except while a text field is
/// being edited, where they undo typing as everywhere else. Each closure
/// returns whether it did anything; when not, the keys go on as usual.
struct VaultUndoShortcuts: NSViewRepresentable {
	let undo: () -> Bool
	let redo: () -> Bool

	func makeNSView(context: Context) -> MonitorView { MonitorView() }

	func updateNSView(_ view: MonitorView, context: Context) {
		view.undo = undo
		view.redo = redo
	}

	final class MonitorView: NSView {
		var undo: () -> Bool = { false }
		var redo: () -> Bool = { false }
		private var monitor: Any?

		override func hitTest(_ point: NSPoint) -> NSView? { nil }

		override func viewDidMoveToWindow() {
			super.viewDidMoveToWindow()
			if let monitor {
				NSEvent.removeMonitor(monitor)
				self.monitor = nil
			}
			guard window != nil else { return }
			monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
				let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
				guard modifiers == .command || modifiers == [.command, .shift], event.charactersIgnoringModifiers?.lowercased() == "z" else { return event }
				let windowNumber = event.windowNumber
				let handled = MainActor.assumeIsolated { self?.handle(redo: modifiers.contains(.shift), inWindow: windowNumber) ?? false }
				return handled ? nil : event
			}
		}

		private func handle(redo: Bool, inWindow windowNumber: Int) -> Bool {
			guard let window, window.windowNumber == windowNumber, window.attachedSheet == nil, !(window.firstResponder is NSText) else { return false }
			return redo ? self.redo() : undo()
		}
	}
}

// MARK: - Stored values

/// How a key's stored values fare against its rules, with the draft applied
/// while there is one. Names problems, never values.
struct VaultSchemaStoredValues: View {
	@Bindable var store: VaultStore
	let project: VaultProject
	let environments: [String]
	let key: String
	var removed = false

	var body: some View {
		let draft = store.schemaDraft(for: project.id)
		VStack(alignment: .leading, spacing: 6) {
			HStack(spacing: 8) {
				Text("STORED VALUES").vaultSectionLabel()
				Text(removed ? "after saving" : (draft == nil ? "checked against these rules" : "with your draft"))
					.font(.system(size: 11))
					.foregroundStyle(VaultPalette.textTertiary)
					.lineLimit(1)
			}
			if let unavailable {
				Text(unavailable)
					.font(.system(size: 11.5))
					.foregroundStyle(VaultPalette.textTertiary)
			} else {
				let presentations = presentations(draft: draft)
				ForEach(Array(environments.enumerated()), id: \.element) { index, environment in
					let status = status(in: environment, presentations: presentations)
					HStack(alignment: .top, spacing: 7) {
						VaultStatusDot(color: VaultPalette.environment(index))
							.padding(.top, 4)
						Text(VaultProject.displayName(for: environment))
							.font(VaultTypography.mono(11))
							.foregroundStyle(VaultPalette.textSecondary)
							.frame(width: 86, alignment: .leading)
							.lineLimit(1)
							.truncationMode(.middle)
						Image(systemName: status.symbol)
							.font(.system(size: 10, weight: .semibold))
							.foregroundStyle(status.tint)
							.frame(width: 12)
							.padding(.top, 1)
							.opacity(status.symbol.isEmpty ? 0 : 1)
						Text(status.text)
							.font(.system(size: 11.5, weight: status.emphasized ? .semibold : .regular))
							.foregroundStyle(status.emphasized ? status.tint : VaultPalette.textTertiary)
							.fixedSize(horizontal: false, vertical: true)
					}
					.accessibilityElement(children: .combine)
				}
			}
		}
		.padding(.horizontal, 16)
		.padding(.vertical, 10)
	}

	/// Why the values can't be checked now: they're loading, or the vault
	/// can't use them, as when it can't reveal them.
	private var unavailable: String? {
		if !project.hasLoadedEnvironments || store.isLoadingSelectedProject { return "Loading the project's values…" }
		return store.canUseLocalSecrets ? nil : "Stored values can't be checked right now."
	}

	private struct Presentations {
		let saved: VaultValueCheckPresentation
		/// With the draft applied; nil without a draft.
		let draft: VaultValueCheckPresentation?
		let hasDraft: Bool
		/// Why the draft's results aren't shown yet.
		let pending: String?
	}

	/// The saved rules' and the draft's results, built once for every environment.
	private func presentations(draft: ProjectEnvSchemaDraft?) -> Presentations {
		let saved = VaultValueCheckPresentation(check: store.valueChecks[project.id], rules: store.keyDescriptions[project.id]?.schema?.overview, project: project)
		guard draft != nil else { return Presentations(saved: saved, draft: nil, hasDraft: false, pending: nil) }
		guard let evaluation = store.latestSchemaDraftEvaluation(for: project.id) else {
			return Presentations(saved: saved, draft: nil, hasDraft: true, pending: "Checking…")
		}
		guard let check = evaluation.check else {
			return Presentations(saved: saved, draft: nil, hasDraft: true, pending: "Not checked until the rules are valid")
		}
		return Presentations(saved: saved, draft: VaultValueCheckPresentation(check: check, rules: evaluation.overview, project: project), hasDraft: true, pending: nil)
	}

	private struct Status {
		var symbol = ""
		var tint = VaultPalette.textTertiary
		var text: String
		var emphasized = false
	}

	private func status(in environment: String, presentations: Presentations) -> Status {
		let saved = presentations.saved
		let stored = project.value(for: key, in: environment) != nil
		if removed {
			return Status(text: stored ? "Kept, no longer checked" : "No value")
		}
		if let pending = presentations.pending { return Status(text: pending) }
		let presentation: VaultValueCheckPresentation
		if let draft = presentations.draft {
			presentation = draft
		} else {
			guard saved.hasCheck else { return Status(text: "Not checked") }
			presentation = saved
		}
		let problems = presentation.problems(of: key, in: environment)
		if let problem = problems.first {
			let message = presentation.message(for: problem, in: environment)
			let isNew = presentations.hasDraft && !saved.problems(of: key, in: environment).contains(problem)
			return Status(symbol: "xmark.circle", tint: VaultPalette.redText, text: isNew ? "Would fail: \(message.lowercasedFirst)" : message, emphasized: isNew)
		}
		if stored || presentation.readsDefaultEnvironment(environment) && project.value(for: key, in: "default") != nil {
			let fixed = presentations.hasDraft && !saved.problems(of: key, in: environment).isEmpty
			return Status(symbol: "checkmark", tint: VaultPalette.greenTintText, text: fixed ? "Would pass" : "Passes", emphasized: fixed)
		}
		if presentation.defaultValue(of: key, in: environment) != nil {
			return Status(symbol: "checkmark", tint: VaultPalette.greenTintText, text: "Uses the default")
		}
		return Status(text: "Not required here")
	}
}

private extension String {
	var lowercasedFirst: String { prefix(1).lowercased() + dropFirst() }
}

// MARK: - Scope editor

/// Picks a scope's environments, stages and services, and a scoped default's value.
private struct VaultScopeEditor: View {
	let environments: [String]
	let initial: ProjectEnvSchemaRule.Scope
	/// The scoped default's value; nil for a scope without one.
	let initialValue: String?
	let isNew: Bool
	/// The rule's other scopes in the same list, which this one can't repeat or overlap.
	let others: [ProjectEnvSchemaRule.Scope]
	let onDone: (ProjectEnvSchemaRule.Scope, String?) -> Void
	let onCancel: () -> Void

	@State private var scope = ProjectEnvSchemaRule.Scope()
	@State private var value = ""

	/// Why the scope can't be used as it is.
	private var issue: String? {
		if scope.isEmpty { return nil }
		if let issue = scope.issue { return issue }
		if initialValue != nil {
			return others.contains(where: scope.overlaps) ? "Overlaps another scoped default, so both could apply. Narrow one of them." : nil
		}
		return others.contains(where: scope.isEquivalent) ? "Another scope here is the same." : nil
	}

	var body: some View {
		let issue = issue
		VStack(alignment: .leading, spacing: 10) {
			Text(isNew ? "Add scope" : "Edit scope").font(.system(size: 12.5, weight: .semibold))
			dimension("Environment", options: environments + scope.environments.filter { !environments.contains($0) }, selected: scope.environments) {
				scope.environments = toggled(scope.environments, $0)
			}
			VaultChipField(values: [], placeholder: "other environment", label: "Other environment", disabled: false,
				normalize: VaultChipField.trimmed, issue: Self.nameIssue) { added in
				scope.environments += added.filter { !scope.environments.contains($0) }
			}
			dimension("Stage", options: ProjectEnvSchemaRule.Stage.allCases.map(\.rawValue), selected: scope.stages.map(\.rawValue)) { name in
				guard let stage = ProjectEnvSchemaRule.Stage(rawValue: name) else { return }
				scope.stages = scope.stages.contains(stage) ? scope.stages.filter { $0 != stage } : scope.stages + [stage]
			}
			VStack(alignment: .leading, spacing: 5) {
				Text("Service").font(.system(size: 11)).foregroundStyle(VaultPalette.textTertiary)
				VaultChipField(values: scope.services, placeholder: "any service", label: "Services", disabled: false,
					normalize: VaultChipField.trimmed, issue: Self.nameIssue) { scope.services = $0 }
			}
			if initialValue != nil {
				VStack(alignment: .leading, spacing: 5) {
					Text("Value").font(.system(size: 11)).foregroundStyle(VaultPalette.textTertiary)
					TextField("value", text: $value)
						.textFieldStyle(.roundedBorder)
						.font(VaultTypography.mono(12))
						.accessibilityLabel("Scoped default value")
					if value.hasHiddenCharacters {
						Text("Has hidden or reordering characters: \(value.escapingDirectionControls)")
							.font(.system(size: 11))
							.foregroundStyle(VaultPalette.orangeTintText)
							.fixedSize(horizontal: false, vertical: true)
					}
				}
			}
			if let issue {
				Text(issue)
					.font(.system(size: 11))
					.foregroundStyle(VaultPalette.redText)
					.fixedSize(horizontal: false, vertical: true)
			} else {
				Text("Several values in one dimension mean any of them; dimensions combine with AND.")
					.font(.system(size: 10.5))
					.foregroundStyle(VaultPalette.textFaint)
					.fixedSize(horizontal: false, vertical: true)
			}
			HStack {
				Spacer()
				VaultBarButton(title: "Cancel", height: 24, action: onCancel)
				VaultBarButton(title: isNew ? "Add" : "Done", filled: true, disabled: scope.isEmpty || issue != nil, height: 24) {
					onDone(scope, initialValue == nil ? nil : value)
				}
			}
		}
		.padding(14)
		.frame(width: 300)
		.onAppear {
			scope = initial
			value = initialValue ?? ""
		}
	}

	private static func nameIssue(_ name: String) -> String? {
		EnvValidation.isValidEnvironmentName(name) ? nil : "Use letters, digits, “.”, “_” and “-”, up to 64 characters."
	}

	private func toggled(_ values: [String], _ value: String) -> [String] {
		values.contains(value) ? values.filter { $0 != value } : values + [value]
	}

	private func dimension(_ title: String, options: [String], selected: [String], _ toggle: @escaping (String) -> Void) -> some View {
		VStack(alignment: .leading, spacing: 5) {
			Text(title).font(.system(size: 11)).foregroundStyle(VaultPalette.textTertiary)
			VaultFlowLayout(spacing: 5, lineSpacing: 5) {
				ForEach(options, id: \.self) { option in
					let on = selected.contains(option)
					Button { toggle(option) } label: {
						Text(option.escapingDirectionControls)
							.font(VaultTypography.mono(11))
							.foregroundStyle(on ? VaultPalette.accentText : VaultPalette.textSecondary)
							.padding(.horizontal, 7)
							.frame(height: 22)
							.background(RoundedRectangle(cornerRadius: 5).fill(on ? VaultPalette.accentTint : .clear))
							.overlay { RoundedRectangle(cornerRadius: 5).stroke(on ? VaultPalette.accent.opacity(0.6) : VaultPalette.border, lineWidth: 1) }
							.contentShape(Rectangle())
					}
					.buttonStyle(.plain)
					.accessibilityLabel("\(title) \(option)")
					.accessibilityAddTraits(on ? .isSelected : [])
				}
			}
		}
	}
}

// MARK: - Chip field

/// Values as removable chips, with a field that adds one on Return or when
/// it loses focus.
struct VaultChipField: View {
	let values: [String]
	let placeholder: String
	/// Names the field for VoiceOver.
	let label: String
	let disabled: Bool
	/// The value an entry adds, or nil when it adds nothing.
	let normalize: (String) -> String?
	/// Why a value can't be added, shown under the field.
	var issue: (String) -> String? = { _ in nil }
	let onChange: ([String]) -> Void

	@State private var entry = ""
	@State private var problem: String?
	@FocusState private var focused: Bool

	/// An entry without its surrounding spaces.
	nonisolated static func trimmed(_ entry: String) -> String? {
		let value = entry.trimmingCharacters(in: .whitespaces)
		return value.isEmpty ? nil : value
	}

	/// A URL scheme as typed, such as "HTTPS://", the way lpm.json lists it.
	nonisolated static func scheme(_ entry: String) -> String? {
		var scheme = entry.trimmingCharacters(in: .whitespaces).lowercased()
		if scheme.hasSuffix("://") { scheme.removeLast(3) } else if scheme.hasSuffix(":") { scheme.removeLast() }
		return scheme.isEmpty ? nil : scheme
	}

	/// An entry as written, where quotes keep spaces at its ends and "" is
	/// the empty value.
	nonisolated static func literal(_ entry: String) -> String? {
		let value = entry.trimmingCharacters(in: .whitespaces)
		if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") { return String(value.dropFirst().dropLast()) }
		return value.isEmpty ? nil : value
	}

	/// A value as a chip shows it, quoted when its spaces or emptiness would otherwise hide.
	nonisolated static func display(_ value: String) -> String {
		let shown = value.isEmpty || value.first?.isWhitespace == true || value.last?.isWhitespace == true ? "\"\(value)\"" : value
		return shown.escapingDirectionControls
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 4) {
			VaultFlowLayout(spacing: 5, lineSpacing: 5) {
				ForEach(Array(values.enumerated()), id: \.offset) { index, value in
					HStack(spacing: 4) {
						Text(Self.display(value))
							.font(VaultTypography.mono(11))
							.foregroundStyle(VaultPalette.textPrimary)
							.lineLimit(1)
						Button {
							var updated = values
							updated.remove(at: index)
							onChange(updated)
						} label: {
							Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(VaultPalette.textFaint)
						}
						.buttonStyle(.plain)
						.disabled(disabled)
						.accessibilityLabel("Remove \(Self.display(value))")
					}
					.padding(.horizontal, 7)
					.frame(height: 22)
					.overlay { RoundedRectangle(cornerRadius: 5).stroke(VaultPalette.border, lineWidth: 1) }
				}
				TextField(values.isEmpty ? placeholder : "Add", text: $entry)
					.textFieldStyle(.plain)
					.font(VaultTypography.mono(11))
					.frame(width: 110, height: 22)
					.padding(.horizontal, 6)
					.overlay { RoundedRectangle(cornerRadius: 5).stroke(problem == nil ? VaultPalette.border : VaultPalette.red, style: StrokeStyle(lineWidth: 1, dash: [3, 2])) }
					.disabled(disabled)
					.focused($focused)
					.onSubmit(commit)
					.onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
					.onChange(of: entry) { problem = nil }
					.accessibilityLabel(label)
			}
			if let problem {
				Text(problem)
					.font(.system(size: 11))
					.foregroundStyle(VaultPalette.redText)
					.fixedSize(horizontal: false, vertical: true)
			}
		}
	}

	private func commit() {
		guard let value = normalize(entry) else { entry = ""; return }
		if let problem = issue(value) {
			self.problem = problem
			return
		}
		if !values.contains(value) { onChange(values + [value]) }
		entry = ""
	}
}

// MARK: - Key picker

/// Finds a declared key by name: names that start with the search first.
struct VaultKeyPicker: View {
	/// From A to Z.
	let keys: [String]
	let secretKeys: Set<String>
	let onPick: (String) -> Void

	@State private var query = ""
	private static let shownLimit = 50

	nonisolated static func matches(_ query: String, in keys: [String]) -> [String] {
		let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
		guard !needle.isEmpty else { return keys }
		var leading: [String] = []
		var inner: [String] = []
		for key in keys {
			let name = key.lowercased()
			if name.hasPrefix(needle) { leading.append(key) } else if name.contains(needle) { inner.append(key) }
		}
		return leading + inner
	}

	var body: some View {
		let matches = Self.matches(query, in: keys)
		VStack(alignment: .leading, spacing: 6) {
			TextField("Search keys", text: $query)
				.textFieldStyle(.roundedBorder)
				.font(VaultTypography.mono(12))
				.onSubmit { if let first = matches.first { onPick(first) } }
				.accessibilityLabel("Search keys")
			ScrollView {
				LazyVStack(alignment: .leading, spacing: 0) {
					ForEach(matches.prefix(Self.shownLimit), id: \.self) { key in
						Button { onPick(key) } label: {
							HStack(spacing: 6) {
								Text(key).font(VaultTypography.mono(12)).foregroundStyle(VaultPalette.textPrimary).lineLimit(1).truncationMode(.middle)
								Spacer(minLength: 4)
								if secretKeys.contains(key) {
									Text("secret").font(.system(size: 10.5)).foregroundStyle(VaultPalette.textFaint)
								}
							}
							.padding(.horizontal, 8)
							.frame(height: 24)
							.contentShape(Rectangle())
						}
						.buttonStyle(.plain)
					}
				}
			}
			.frame(maxHeight: 260)
			if matches.isEmpty {
				Text("No keys match.").font(.system(size: 11)).foregroundStyle(VaultPalette.textTertiary)
			} else if matches.count > Self.shownLimit {
				Text("\(matches.count - Self.shownLimit) more; keep typing to narrow them.").font(.system(size: 11)).foregroundStyle(VaultPalette.textTertiary)
			}
		}
		.padding(10)
		.frame(width: 260)
	}
}

// MARK: - Add rule menu

/// The rows a rule can add, by section, with why unavailable ones can't be added.
private struct VaultAddRuleMenu: View {
	let fields: [(field: ProjectEnvSchemaRule.Field, availability: ProjectEnvSchemaRule.Availability)]
	let onAdd: (ProjectEnvSchemaRule.Field) -> Void

	var body: some View {
		VStack(alignment: .leading, spacing: 1) {
			ForEach(ProjectEnvSchemaRule.Section.allCases, id: \.self) { section in
				let rows = fields.filter { $0.field.section == section }
				if !rows.isEmpty {
					Text(section.title).vaultSectionLabel()
						.padding(.horizontal, 8)
						.padding(.top, 6)
						.padding(.bottom, 2)
					ForEach(rows, id: \.field) { row in
						Button { onAdd(row.field) } label: {
							HStack(spacing: 10) {
								Text(row.field.title).font(.system(size: 12)).foregroundStyle(VaultPalette.textPrimary)
								Spacer(minLength: 8)
								Text(row.availability.hint).font(.system(size: 10.5)).foregroundStyle(VaultPalette.textFaint)
							}
							.padding(.horizontal, 8)
							.frame(height: 24)
							.contentShape(Rectangle())
						}
						.buttonStyle(.plain)
						.disabled(!row.availability.isAvailable)
						.opacity(row.availability.isAvailable ? 1 : 0.45)
						.accessibilityLabel(row.field.title)
						.accessibilityHint(row.availability.hint)
					}
				}
			}
		}
		.padding(6)
		.frame(width: 260)
	}
}
