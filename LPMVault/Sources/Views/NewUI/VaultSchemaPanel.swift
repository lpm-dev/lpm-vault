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

	var body: some View {
		Group {
			switch selection {
			case .key(let key):
				VaultSchemaKeyEditor(store: store, project: project, environments: environments, key: key, onSelect: onSelect)
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

	/// Rows opened in this panel, which stay while their value is unset.
	@State private var shownFields: Set<Field> = []
	/// An override is edited only after "Edit override", unless the draft changed it.
	@State private var editsOverride = false
	@State private var name = ""
	@State private var renaming = false
	@State private var renameError: String?
	@State private var saveError: String?
	@State private var saving = false
	@State private var addingRule = false
	@State private var scopeTarget: ScopeTarget?

	private struct ScopeTarget: Identifiable, Hashable {
		let field: Field
		/// The line being edited; nil adds one.
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
		/// The draft removes the key from lpm.json.
		case removed
		case missing

		var isOverridden: Bool { if case .overridden = self { true } else { false } }
	}

	// MARK: - State

	private var descriptions: ProjectKeyDescriptions? { store.keyDescriptions[project.id] }
	private var savedOverview: ProjectEnvSchemaOverview? { descriptions?.schema?.overview }
	private var pendingDraft: Draft? { store.schemaDraft(for: project.id) }
	private var draft: Draft { pendingDraft ?? Draft(schema: descriptions?.rootSchema) }
	/// The latest evaluation, which can lag the draft while it's evaluated.
	private var evaluation: Draft.Evaluation? { store.latestSchemaDraftEvaluation(for: project.id) }
	private var overview: ProjectEnvSchemaOverview? { pendingDraft == nil ? savedOverview : evaluation?.overview ?? savedOverview }
	private var item: Draft.Item { .key(key) }
	private var savedRule: ProjectEnvSchemaOverview.Rule? { savedOverview?.rule(for: key) }

	private var mode: Mode {
		switch draft.declaration(of: item) {
		case .declared: return .editing(isOverride: false)
		case .overridden:
			let source = savedRule?.overrides ?? "an imported schema"
			if case .overridden = draft.base(of: item), !draft.hasChange(to: item), !editsOverride { return .overridden(source: source) }
			return .editing(isOverride: true)
		case .absent:
			if case .declared = draft.base(of: item) { return .removed }
			if let source = savedRule?.source { return .inherited(source: source) }
			return .missing
		}
	}

	private var rule: Rule {
		switch draft.declaration(of: item) {
		case .declared(let json), .overridden(let json): Rule(json)
		case .absent: Rule(resolved: savedOverview?.declaration(of: key))
		}
	}

	private var publicPrefix: String? {
		Rule.publicPrefix(of: key, clientPrefixes: overview?.clientPrefixes ?? [])
	}

	private var secretKeys: Set<String> {
		Set((overview?.rules ?? []).lazy.filter(\.isSecret).map(\.key))
	}

	private var rejection: Draft.Rejection? {
		guard let rejection = evaluation?.rejection, rejection.item == item else { return nil }
		return rejection
	}

	private var canEdit: Bool { store.canEditSchema(of: project.id) && !saving }

	// MARK: - Body

	var body: some View {
		let mode = mode
		let rule = rule
		VStack(spacing: 0) {
			ScrollView {
				VStack(alignment: .leading, spacing: 0) {
					header(mode)
					identity(mode, rule: rule)
					VaultHairline()
					VaultSchemaStoredValues(store: store, project: project, environments: environments, key: key,
						removed: mode == .removed)
					VaultHairline()
					switch mode {
					case .editing:
						editingSections(rule)
					case .inherited, .overridden:
						readOnlySections(rule)
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
		.background { undoShortcuts }
		.onAppear { name = key }
		.onChange(of: store.savingSchemaDrafts.contains(project.id)) { _, isSaving in saving = isSaving }
	}

	private var undoShortcuts: some View {
		ZStack {
			Button("Undo rule change") { store.undoSchemaDraft(in: project.id) }
				.keyboardShortcut("z", modifiers: .command)
				.disabled(!store.canUndoSchemaDraft(in: project.id))
			Button("Redo rule change") { store.redoSchemaDraft(in: project.id) }
				.keyboardShortcut("z", modifiers: [.command, .shift])
				.disabled(!store.canRedoSchemaDraft(in: project.id))
		}
		.opacity(0)
		.frame(width: 0, height: 0)
		.accessibilityHidden(true)
	}

	// MARK: - Header and identity

	private func header(_ mode: Mode) -> some View {
		HStack(spacing: 6) {
			Text("KEY").vaultSectionLabel()
			switch mode {
			case .inherited(let source), .overridden(let source):
				VaultSourceBadge(source: source)
			case .editing(true):
				VaultSourceBadge(source: savedRule?.overrides ?? savedRule?.source ?? "imported")
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
	private func identity(_ mode: Mode, rule: Rule) -> some View {
		VStack(alignment: .leading, spacing: 8) {
			nameField(mode)
			if case .editing = mode {
				descriptionField(rule)
			} else if let description = rule.description, !description.isEmpty {
				Text(description.escapingDirectionControls)
					.font(.system(size: 12))
					.foregroundStyle(VaultPalette.textSecondary)
					.fixedSize(horizontal: false, vertical: true)
			}
			if case .editing(true) = mode {
				notice(symbol: "square.stack.3d.up",
					text: "You're editing a copy of the rule from \(savedRule?.overrides ?? savedRule?.source ?? "an imported schema"). Saving writes an override to lpm.json that replaces the original; it doesn't merge.")
			}
			if draft.conflicts.contains(where: { $0.item == item }) {
				notice(symbol: "exclamationmark.triangle", text: "Conflicts with a change on disk. Choose a version in the banner.", tint: VaultPalette.orangeTintText)
			}
			if let rejection, rejection.field.flatMap(Field.init(name:)) == nil, !hasBlockingConflict(rule) {
				conflictLine(.init(kind: .blocking, message: rejection.reason, fixes: []))
			}
		}
		.padding(.horizontal, 16)
		.padding(.bottom, 12)
	}

	private func nameField(_ mode: Mode) -> some View {
		let renamable = mode == .editing(isOverride: false) && draft.base(of: item) != .absent
		let changed = name != key
		let issue = changed ? nameIssue(name) : nil
		return VStack(alignment: .leading, spacing: 6) {
			HStack(spacing: 6) {
				if renamable {
					TextField("KEY_NAME", text: $name)
						.textFieldStyle(.plain)
						.font(VaultTypography.mono(13.5, .bold))
						.autocorrectionDisabled()
						.disabled(!canEdit || renaming)
						.onSubmit { if changed, issue == nil { rename() } }
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
				if publicPrefix != nil, mode != .removed { VaultPublicBadge() }
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
					let stored = environments.filter { project.value(for: key, in: $0) != nil }.count
					Text(stored == 0 ? "Renames its rule in lpm.json." : "Renames its rule in lpm.json and its values in \(stored == 1 ? "1 environment" : "\(stored) environments").")
						.font(.system(size: 11))
						.foregroundStyle(VaultPalette.textTertiary)
						.fixedSize(horizontal: false, vertical: true)
					HStack(spacing: 6) {
						VaultBarButton(title: renaming ? "Renaming…" : "Rename", filled: true, disabled: renaming || pendingDraft != nil, height: 24, action: rename)
						VaultBarButton(title: "Cancel", height: 24) { name = key; renameError = nil }
					}
					if pendingDraft != nil {
						Text("Save or discard your rule changes before renaming.")
							.font(.system(size: 11))
							.foregroundStyle(VaultPalette.textTertiary)
					}
				}
			}
			if let renameError {
				conflictLine(.init(kind: .blocking, message: renameError, fixes: []))
			}
		}
	}

	/// A reason the panel shows next to a row, which explains the engine's
	/// rejection better than its own message.
	private func hasBlockingConflict(_ rule: Rule) -> Bool {
		rule.conflicts(key: key, publicPrefix: publicPrefix, secretKeys: secretKeys).values.contains { $0.kind == .blocking }
	}

	private func nameIssue(_ name: String) -> String? {
		guard EnvValidation.isValidVariableName(name) else { return "Use letters, digits and underscores; a name can't start with a digit." }
		let folded = name.uppercased()
		if let existing = overview?.rules.first(where: { $0.key != key && $0.key.uppercased() == folded }) {
			return existing.key == name ? "\(name) is already declared." : "Conflicts with \(existing.key): names can't differ only in capitalisation."
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
				onSelect(.key(target))
			} catch {
				renameError = error.localizedDescription
			}
			renaming = false
		}
	}

	private func descriptionField(_ rule: Rule) -> some View {
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

	private func editingSections(_ rule: Rule) -> some View {
		let conflicts = rule.conflicts(key: key, publicPrefix: publicPrefix, secretKeys: secretKeys)
		let fields = visibleFields(rule)
		return VStack(alignment: .leading, spacing: 0) {
			ForEach(ProjectEnvSchemaRule.Section.allCases, id: \.self) { section in
				let rows = Field.allCases.filter { $0.section == section && fields.contains($0) }
				if !rows.isEmpty {
					VStack(alignment: .leading, spacing: 9) {
						Text(section.title).vaultSectionLabel()
						ForEach(rows, id: \.self) { field in
							fieldRow(field, rule: rule, conflict: conflicts[field])
						}
					}
					.padding(.horizontal, 16)
					.padding(.top, 12)
					.padding(.bottom, 4)
				}
			}
			addRuleButton(rule, shown: fields)
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
	private func fieldRow(_ field: Field, rule: Rule, conflict: Rule.Conflict?) -> some View {
		let engineIssue = rejection.flatMap { $0.field.flatMap(Field.init(name:)) == field ? $0.reason : nil }
		VStack(alignment: .leading, spacing: 5) {
			if field.isStacked {
				HStack(spacing: 8) {
					label(field)
					Spacer(minLength: 4)
					removeButton(field)
				}
				control(field, rule: rule)
			} else {
				HStack(alignment: .center, spacing: 8) {
					label(field).frame(width: 84, alignment: .leading)
					control(field, rule: rule)
						.frame(maxWidth: .infinity, alignment: .leading)
					removeButton(field)
				}
			}
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
				shownFields.remove(field)
				update { $0.remove(field) }
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
	private func control(_ field: Field, rule: Rule) -> some View {
		switch field {
		case .required:
			toggle(\.required, label: "Required")
		case .secret:
			toggle(\.secret, label: "Secret", disabled: publicPrefix != nil && !rule.secret)
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
		case .bounds:
			HStack(spacing: 6) {
				numberField("min", text: \.min, field: "min")
				numberField("max", text: \.max, field: "max")
			}
		case .length:
			HStack(spacing: 6) {
				numberField("min", text: \.minLength, field: "minLength")
				numberField("max", text: \.maxLength, field: "maxLength")
			}
		case .pattern:
			textField("regular expression", text: \.pattern, field: "pattern")
		case .defaultValue:
			textField("value", text: \.defaultValue, field: "default")
		case .protocols:
			VaultChipField(values: rule.protocols ?? [], placeholder: "https", disabled: !canEdit,
				normalize: { $0.lowercased() }) { values in update { $0.protocols = values } }
		case .allowedValues:
			VaultChipField(values: rule.allowedValues ?? [], placeholder: "value", disabled: !canEdit,
				normalize: { $0 }) { values in update { $0.allowedValues = values } }
		case .requiredIn:
			scopeLines(rule.requiredIn.map { ($0, nil) }, field: .requiredIn)
		case .defaultsIn:
			scopeLines(rule.defaultsIn.map { ($0.scope, $0.value) }, field: .defaultsIn)
		case .requiredWhen:
			requiredWhenControl(rule)
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

	private func textField(_ placeholder: String, text: WritableKeyPath<Rule, String?>, field: String) -> some View {
		TextField(placeholder, text: textBinding(text, field: field))
			.textFieldStyle(.plain)
			.font(VaultTypography.mono(12))
			.autocorrectionDisabled()
			.padding(.horizontal, 9)
			.frame(height: 28)
			.background(RoundedRectangle(cornerRadius: 7).fill(VaultPalette.control))
			.overlay { RoundedRectangle(cornerRadius: 7).stroke(VaultPalette.border, lineWidth: 1) }
			.disabled(!canEdit)
			.accessibilityLabel(placeholder)
	}

	private func numberField(_ placeholder: String, text: WritableKeyPath<Rule, String?>, field: String) -> some View {
		textField(placeholder, text: text, field: field)
			.accessibilityLabel("\(field) \(placeholder)")
	}

	/// Reads the rule as it is when asked, not when the panel last drew, so
	/// ending an edit before the panel redraws can't write an older value back.
	private func textBinding(_ text: WritableKeyPath<Rule, String?>, field: String) -> Binding<String> {
		Binding(get: { rule[keyPath: text] ?? "" }, set: { value in update(coalescing: field) { $0[keyPath: text] = value } })
	}

	private func requiredWhenControl(_ rule: Rule) -> some View {
		let condition = rule.requiredWhen
		let candidates = (overview?.rules ?? []).map(\.key).filter { $0 != key }
		return VStack(alignment: .leading, spacing: 6) {
			Menu {
				ForEach(candidates, id: \.self) { candidate in
					Button(candidate) {
						update { $0.requiredWhen = .init(variable: candidate, condition: condition?.condition ?? .present(true)) }
					}
				}
			} label: {
				fieldBox(condition?.variable ?? "Choose a key", placeholder: condition == nil, chevron: true)
			}
			.menuStyle(.button)
			.buttonStyle(.plain)
			.menuIndicator(.hidden)
			.disabled(!canEdit || candidates.isEmpty)
			.accessibilityLabel("Required when key")
			if let condition {
				HStack(spacing: 6) {
					Menu {
						Button("equals") { update { $0.requiredWhen = .init(variable: condition.variable, condition: .equals("")) } }
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
					if case .equals = condition.condition {
						TextField("value", text: Binding(
							get: { if case .equals(let value)? = rule.requiredWhen?.condition { value } else { "" } },
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

	private static func conditionTitle(_ condition: Rule.RequiredWhen.Condition) -> String {
		switch condition {
		case .equals: "equals"
		case .present(true): "is set"
		case .present(false): "is not set"
		}
	}

	private func scopeLines(_ lines: [(scope: Rule.Scope, value: String?)], field: Field) -> some View {
		VStack(alignment: .leading, spacing: 5) {
			ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
				HStack(alignment: .top, spacing: 4) {
					VStack(alignment: .leading, spacing: 2) {
						Text(line.scope.summary)
							.font(VaultTypography.mono(11.5))
							.foregroundStyle(VaultPalette.textPrimary)
							.fixedSize(horizontal: false, vertical: true)
						if let value = line.value {
							Text("→ " + (value.isEmpty ? "\"\"" : value.escapingDirectionControls))
								.font(VaultTypography.mono(11))
								.foregroundStyle(VaultPalette.textSecondary)
								.lineLimit(2)
						}
					}
					Spacer(minLength: 4)
					VaultRowIconButton(systemImage: "pencil", help: "Edit scope") { scopeTarget = .init(field: field, index: index) }
						.disabled(!canEdit)
					VaultRowIconButton(systemImage: "xmark", help: "Remove scope") { removeScope(at: index, field: field) }
						.disabled(!canEdit)
				}
				.padding(.leading, 8)
				.padding(.vertical, 3)
				.background(RoundedRectangle(cornerRadius: 7).fill(VaultPalette.control))
				.overlay { RoundedRectangle(cornerRadius: 7).stroke(VaultPalette.border, lineWidth: 1) }
				.popover(item: popoverBinding(field: field, index: index), arrowEdge: .leading) { _ in
					scopeEditor(field: field, index: index)
				}
			}
			Button { scopeTarget = .init(field: field, index: nil) } label: {
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
			.popover(item: popoverBinding(field: field, index: nil), arrowEdge: .leading) { _ in
				scopeEditor(field: field, index: nil)
			}
		}
	}

	private func popoverBinding(field: Field, index: Int?) -> Binding<ScopeTarget?> {
		Binding(
			get: { scopeTarget?.field == field && scopeTarget?.index == index ? scopeTarget : nil },
			set: { if $0 == nil, scopeTarget?.field == field, scopeTarget?.index == index { scopeTarget = nil } }
		)
	}

	private func scopeEditor(field: Field, index: Int?) -> some View {
		let rule = rule
		let current: Rule.ScopedDefault? = switch field {
		case .requiredIn: index.map { .init(scope: rule.requiredIn[$0], value: "") }
		default: index.map { rule.defaultsIn[$0] }
		}
		return VaultScopeEditor(
			environments: environments,
			initial: current?.scope ?? Rule.Scope(),
			initialValue: field == .defaultsIn ? (current?.value ?? "") : nil,
			isNew: index == nil
		) { scope, value in
			update { rule in
				switch field {
				case .requiredIn:
					var scopes = rule.requiredIn
					if let index { scopes[index] = scope } else { scopes.append(scope) }
					rule.requiredIn = scopes
				default:
					var defaults = rule.defaultsIn
					let entry = Rule.ScopedDefault(scope: scope, value: value ?? "")
					if let index { defaults[index] = entry } else { defaults.append(entry) }
					rule.defaultsIn = defaults
				}
			}
			scopeTarget = nil
		} onCancel: {
			scopeTarget = nil
		}
	}

	private func removeScope(at index: Int, field: Field) {
		update { rule in
			if field == .requiredIn {
				var scopes = rule.requiredIn
				scopes.remove(at: index)
				rule.requiredIn = scopes
			} else {
				var defaults = rule.defaultsIn
				defaults.remove(at: index)
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
		if case .remove(let field) = fix { shownFields.remove(field) }
		update { $0.apply(fix) }
	}

	// MARK: - Add rule

	private func addRuleButton(_ rule: Rule, shown: Set<Field>) -> some View {
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
			VaultAddRuleMenu(fields: Field.allCases.filter { !shown.contains($0) }.map { ($0, rule.availability(of: $0, publicPrefix: publicPrefix)) }) { field in
				addingRule = false
				add(field)
			}
		}
	}

	private func add(_ field: Field) {
		shownFields.insert(field)
		switch field {
		case .required: update { $0.required = true }
		case .secret: update { $0.secret = true }
		case .ci: update { $0.ci = $0.secret ? .secret : .variable }
		case .requiredWhen:
			if let candidate = (overview?.rules ?? []).map(\.key).first(where: { $0 != key }) {
				update { $0.requiredWhen = .init(variable: candidate, condition: .present(true)) }
			}
		case .requiredIn, .defaultsIn: scopeTarget = .init(field: field, index: nil)
		default: break
		}
	}

	// MARK: - Read-only

	private func readOnlySections(_ rule: Rule) -> some View {
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

	private func footer(_ mode: Mode) -> some View {
		let changes = pendingDraft?.changedItems.count ?? 0
		let current = store.currentSchemaDraftEvaluation(for: project.id)
		let blocked = current == nil || current?.rejection != nil || pendingDraft?.conflicts.isEmpty == false
		return VStack(alignment: .leading, spacing: 6) {
			if let saveError {
				Text(saveError)
					.font(.system(size: 11))
					.foregroundStyle(VaultPalette.redText)
					.fixedSize(horizontal: false, vertical: true)
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
							store.editSchemaDraft(in: project.id) { $0.discard(.key(key)) }
						}
						.disabled(!canEdit)
					}
					VaultBarButton(title: saving ? "Saving…" : "Save", filled: true, disabled: changes == 0 || blocked || !canEdit, height: 26, action: save)
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
			} catch .file(.changed) {
				saveError = "lpm.json changed on disk. Your changes were merged into it; check them and save again."
			} catch {
				saveError = error.message
			}
		}
	}

	// MARK: - Updates

	private func update(coalescing field: String? = nil, _ change: (inout Rule) -> Void) {
		var rule = rule
		change(&rule)
		let isOverride: Bool = if case .editing(true) = mode { true } else if case .overridden = mode { true } else { false }
		update(declaration: isOverride ? .overridden(rule.json) : .declared(rule.json), coalescing: field)
	}

	private func update(declaration: Draft.Declaration, coalescing field: String? = nil) {
		saveError = nil
		store.editSchemaDraft(in: project.id, coalescing: field.map { "\(key)/\($0)" }) { $0.set(declaration, for: item) }
	}
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
		let evaluation = store.latestSchemaDraftEvaluation(for: project.id)
		VStack(alignment: .leading, spacing: 6) {
			HStack(spacing: 8) {
				Text("STORED VALUES").vaultSectionLabel()
				Text(removed ? "after saving" : (draft == nil ? "checked against these rules" : "with your draft"))
					.font(.system(size: 11))
					.foregroundStyle(VaultPalette.textTertiary)
					.lineLimit(1)
			}
			ForEach(Array(environments.enumerated()), id: \.element) { index, environment in
				let status = status(in: environment, draft: draft, evaluation: evaluation)
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
		.padding(.horizontal, 16)
		.padding(.vertical, 10)
	}

	private struct Status {
		var symbol = ""
		var tint = VaultPalette.textTertiary
		var text: String
		var emphasized = false
	}

	private func status(in environment: String, draft: ProjectEnvSchemaDraft?, evaluation: ProjectEnvSchemaDraft.Evaluation?) -> Status {
		let saved = VaultValueCheckPresentation(check: store.valueChecks[project.id], rules: store.keyDescriptions[project.id]?.schema?.overview, project: project)
		let stored = project.value(for: key, in: environment) != nil
		if removed {
			return Status(text: stored ? "Kept, no longer checked" : "No value")
		}
		let presentation: VaultValueCheckPresentation
		if draft != nil {
			guard let evaluation else { return Status(text: "Checking…") }
			guard evaluation.check != nil else { return Status(text: "Not checked until the rules are valid") }
			presentation = VaultValueCheckPresentation(check: evaluation.check, rules: evaluation.overview, project: project)
		} else {
			guard saved.hasCheck else { return Status(text: "Not checked") }
			presentation = saved
		}
		let problems = presentation.problems(of: key, in: environment)
		if let problem = problems.first {
			let message = presentation.message(for: problem, in: environment)
			let isNew = draft != nil && !saved.problems(of: key, in: environment).contains(problem)
			return Status(symbol: "xmark.circle", tint: VaultPalette.redText, text: isNew ? "Would fail: \(message.lowercasedFirst)" : message, emphasized: isNew)
		}
		if stored || presentation.readsDefaultEnvironment(environment) && project.value(for: key, in: "default") != nil {
			let fixed = draft != nil && !saved.problems(of: key, in: environment).isEmpty
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
	let onDone: (ProjectEnvSchemaRule.Scope, String?) -> Void
	let onCancel: () -> Void

	@State private var scope = ProjectEnvSchemaRule.Scope()
	@State private var value = ""
	@State private var service = ""

	var body: some View {
		VStack(alignment: .leading, spacing: 10) {
			Text(isNew ? "Add scope" : "Edit scope").font(.system(size: 12.5, weight: .semibold))
			dimension("Environment", options: environments + scope.environments.filter { !environments.contains($0) }, selected: scope.environments) {
				scope.environments = toggled(scope.environments, $0)
			}
			dimension("Stage", options: ProjectEnvSchemaRule.Stage.allCases.map(\.rawValue), selected: scope.stages.map(\.rawValue)) { name in
				guard let stage = ProjectEnvSchemaRule.Stage(rawValue: name) else { return }
				scope.stages = ProjectEnvSchemaRule.Stage.allCases.filter { ($0 == stage) != scope.stages.contains($0) }
			}
			VStack(alignment: .leading, spacing: 5) {
				Text("Service").font(.system(size: 11)).foregroundStyle(VaultPalette.textTertiary)
				VaultChipField(values: scope.services, placeholder: "any service", disabled: false, normalize: { $0 }) { scope.services = $0 }
			}
			if initialValue != nil {
				VStack(alignment: .leading, spacing: 5) {
					Text("Value").font(.system(size: 11)).foregroundStyle(VaultPalette.textTertiary)
					TextField("value", text: $value)
						.textFieldStyle(.roundedBorder)
						.font(VaultTypography.mono(12))
						.accessibilityLabel("Scoped default value")
				}
			}
			Text("Several values in one dimension mean any of them; dimensions combine with AND.")
				.font(.system(size: 10.5))
				.foregroundStyle(VaultPalette.textFaint)
				.fixedSize(horizontal: false, vertical: true)
			HStack {
				Spacer()
				VaultBarButton(title: "Cancel", height: 24, action: onCancel)
				VaultBarButton(title: isNew ? "Add" : "Done", filled: true, disabled: scope.isEmpty, height: 24) {
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
						Text(option)
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

/// Values as removable chips, with a field that adds one on Return.
struct VaultChipField: View {
	let values: [String]
	let placeholder: String
	let disabled: Bool
	let normalize: (String) -> String
	let onChange: ([String]) -> Void

	@State private var entry = ""

	var body: some View {
		VaultFlowLayout(spacing: 5, lineSpacing: 5) {
			ForEach(Array(values.enumerated()), id: \.offset) { index, value in
				HStack(spacing: 4) {
					Text(value.escapingDirectionControls)
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
					.accessibilityLabel("Remove \(value)")
				}
				.padding(.horizontal, 7)
				.frame(height: 22)
				.overlay { RoundedRectangle(cornerRadius: 5).stroke(VaultPalette.border, lineWidth: 1) }
			}
			TextField(values.isEmpty ? placeholder : "Add", text: $entry)
				.textFieldStyle(.plain)
				.font(VaultTypography.mono(11))
				.frame(width: 90, height: 22)
				.padding(.horizontal, 6)
				.overlay { RoundedRectangle(cornerRadius: 5).stroke(VaultPalette.border, style: StrokeStyle(lineWidth: 1, dash: [3, 2])) }
				.disabled(disabled)
				.onSubmit {
					let value = normalize(entry.trimmingCharacters(in: .whitespaces))
					guard !value.isEmpty, !values.contains(value) else { entry = ""; return }
					onChange(values + [value])
					entry = ""
				}
				.accessibilityLabel(placeholder)
		}
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
