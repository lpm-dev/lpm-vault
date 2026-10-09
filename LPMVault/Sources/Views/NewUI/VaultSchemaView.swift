import AppKit
import SwiftUI

/// A project's env rules from lpm.json: what the LPM CLI enforces, with the
/// unsaved schema draft applied, and what to do when there are no rules or
/// lpm.json can't be read. Selecting a key opens it in the side panel.
struct VaultSchemaView: View {
	let state: ProjectEnvSchemaState?
	/// The folder whose lpm.json holds the rules.
	let folder: String?
	let descriptions: [String: String]
	@Binding var sortOrder: VaultKeySortOrder
	var draft: ProjectEnvSchemaDraft? = nil
	/// The rules with the draft applied; nil while they're evaluated or rejected.
	var draftOverview: ProjectEnvSchemaOverview? = nil
	var selection: VaultSchemaSelection? = nil
	var onSelect: (VaultSchemaSelection?) -> Void = { _ in }
	/// The rules can be edited: lpm.json is read from the project's folder.
	var canEdit = false
	var onAddKey: () -> Void = {}
	var onAddGroup: () -> Void = {}
	/// Keys stored in some environment that lpm.json doesn't declare.
	var undeclared: [VaultStore.StoredSchemaKey] = []
	var onDeclare: (String) -> Void = { _ in }
	/// What merging the draft with changes on disk did, until dismissed.
	var rebase: ProjectEnvSchemaDraft.Rebase? = nil
	var onDismissRebase: () -> Void = {}
	/// Settles a conflict, keeping the draft's version or the file's.
	var onResolveConflict: (ProjectEnvSchemaDraft.Item, _ keepingMine: Bool) -> Void = { _, _ in }
	let onConnectCLI: () -> Void
	let onRecheck: () -> Void

	/// How a row differs from lpm.json in the draft.
	enum RowState: Equatable {
		case saved, draft, new, removed
		/// A group of lpm.json's the draft renames, from its name there, escaped.
		case renamed(from: String)
	}

	static let docsURL = URL(string: "https://cli.lpm.dev/docs/reference/lpm-json#envschema")!
	static let example = """
		{
		  "envSchema": {
		    "vars": {
		      "PORT": { "format": "port", "default": "3000" }
		    }
		  }
		}
		"""

	var body: some View {
		let listed = state?.overview.map(listed)
		VStack(spacing: 0) {
			header
			VaultHairline()
			changesOnDisk
			content(listed)
				.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
			VaultHairline()
			statusBar(listed)
		}
		.background(VaultPalette.content)
	}

	/// lpm.json, when the page can open it.
	private var configFile: URL? {
		switch state {
		case .loaded(_, let file)?: file
		case .unreadable?: folder.map { URL(fileURLWithPath: $0).appendingPathComponent("lpm.json") }
		case .noFolder?, nil: nil
		}
	}

	// MARK: - Header

	private var header: some View {
		HStack(spacing: 10) {
			Text("Schema")
				.font(.system(size: 19, weight: .bold))
				.tracking(-0.28)
				.foregroundStyle(VaultPalette.textPrimary)
			if case .noFolder? = state {
				Text("no project folder linked")
					.font(.system(size: 12.5))
					.foregroundStyle(VaultPalette.textTertiary)
			} else {
				HStack(spacing: 5) {
					Image(systemName: "doc").font(.system(size: 11))
					Text("lpm.json › envSchema").font(VaultTypography.mono(11.5))
					Text("· plain text, shared with the team").font(.system(size: 12.5))
				}
				.foregroundStyle(VaultPalette.textTertiary)
				.lineLimit(1)
			}
			Spacer(minLength: 8)
			if let configFile {
				VaultOutlineButton(systemImage: "doc", title: "Open lpm.json", help: "Open lpm.json in your JSON editor") {
					ProjectConfigOpener.open(configFile)
				}
				.fixedSize()
			}
			if canEdit {
				VaultBarButton(systemImage: "plus", title: "Add key", filled: true, height: 27, action: onAddKey)
					.help("Declare a new key in lpm.json")
			}
		}
		.padding(.horizontal, 20)
		.frame(height: 64)
	}

	// MARK: - Changes on disk

	@ViewBuilder
	private var changesOnDisk: some View {
		if let conflicts = draft?.conflicts, !conflicts.isEmpty {
			conflictBanner(conflicts)
				.padding(.horizontal, 20)
				.padding(.top, 12)
		} else if let rebase, !rebase.isEmpty {
			HStack(spacing: 8) {
				Image(systemName: "checkmark").font(.system(size: 10.5, weight: .bold)).foregroundStyle(VaultPalette.greenTintText)
				Text("lpm.json changed on disk — your draft was re-applied.")
					.font(.system(size: 12))
					.foregroundStyle(VaultPalette.textSecondary)
				Spacer(minLength: 8)
				Text(rebase.summary)
					.font(.system(size: 11.5))
					.foregroundStyle(VaultPalette.textTertiary)
					.lineLimit(1)
					.truncationMode(.tail)
				VaultRowIconButton(systemImage: "xmark", help: "Dismiss", action: onDismissRebase)
			}
			.padding(.leading, 12)
			.padding(.trailing, 4)
			.frame(height: 36)
			.background(RoundedRectangle(cornerRadius: 8).fill(VaultPalette.headerRow))
			.overlay { RoundedRectangle(cornerRadius: 8).stroke(VaultPalette.border, lineWidth: 1) }
			.padding(.horizontal, 20)
			.padding(.top, 12)
			.accessibilityElement(children: .combine)
		}
	}

	private func conflictBanner(_ conflicts: [ProjectEnvSchemaDraft.Conflict]) -> some View {
		VStack(alignment: .leading, spacing: 10) {
			HStack(alignment: .top, spacing: 10) {
				Image(systemName: "exclamationmark.triangle.fill")
					.foregroundStyle(VaultPalette.orange)
					.padding(.top, 1)
				VStack(alignment: .leading, spacing: 3) {
					Text(conflicts.count == 1 ? "lpm.json changed on disk — 1 change conflicts with your draft" : "lpm.json changed on disk — \(conflicts.count) changes conflict with your draft")
						.font(.system(size: 13, weight: .semibold))
						.foregroundStyle(VaultPalette.textPrimary)
					Text("The rest of your draft was re-applied. Choose a version for each; saving waits until every one is settled.")
						.font(.system(size: 11.5))
						.foregroundStyle(VaultPalette.textSecondary)
						.fixedSize(horizontal: false, vertical: true)
				}
				Spacer(minLength: 8)
				if let configFile {
					VaultBarButton(systemImage: "doc", title: "Open lpm.json", height: 26) { ProjectConfigOpener.open(configFile) }
				}
			}
			VStack(spacing: 0) {
				ForEach(Array(conflicts.enumerated()), id: \.element.item) { index, conflict in
					let summary = conflict.summary
					HStack(spacing: 10) {
						VStack(alignment: .leading, spacing: 2) {
							Text(ProjectEnvSchemaReview.title(of: conflict.item))
								.font(VaultTypography.mono(12, .semibold))
								.foregroundStyle(VaultPalette.textPrimary)
							Text("Yours: \(summary.mine) · Theirs: \(summary.theirs)")
								.font(.system(size: 11))
								.foregroundStyle(VaultPalette.textTertiary)
								.lineLimit(2)
						}
						Spacer(minLength: 8)
						VaultBarButton(title: "Keep mine", height: 24) { onResolveConflict(conflict.item, true) }
						VaultBarButton(title: "Take theirs", height: 24) { onResolveConflict(conflict.item, false) }
					}
					.padding(.horizontal, 10)
					.padding(.vertical, 8)
					.overlay(alignment: .top) { if index > 0 { VaultHairline() } }
				}
			}
			.background(RoundedRectangle(cornerRadius: 8).fill(VaultPalette.content))
			.overlay { RoundedRectangle(cornerRadius: 8).stroke(VaultPalette.border, lineWidth: 1) }
		}
		.padding(12)
		.background(RoundedRectangle(cornerRadius: 10).fill(VaultPalette.orangeTint))
		.overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(VaultPalette.orange.opacity(0.6)) }
	}

	// MARK: - Content

	@ViewBuilder
	private func content(_ listed: Listed?) -> some View {
		switch state {
		case nil:
			VStack(spacing: 10) {
				ProgressView()
				Text("Reading lpm.json…").font(.system(size: 12)).foregroundStyle(VaultPalette.textTertiary)
			}
			.frame(maxWidth: .infinity, maxHeight: .infinity)
		case .noFolder?:
			emptyState(
				symbol: "terminal",
				title: "Rules live in your project's lpm.json",
				message: "This project isn't linked to a folder yet, so LPM Vault can't read its rules. Connect the CLI to link the folder; rules appear here read-only."
			) {
				VaultBarButton(systemImage: "link", title: "Connect CLI", filled: true, height: 28, action: onConnectCLI)
				VaultBarButton(title: "Learn about envSchema", height: 28) { NSWorkspace.shared.open(Self.docsURL) }
			}
		case .loaded(let overview, _)? where overview.isEmpty && draft == nil:
			emptyState(
				symbol: "curlybraces",
				title: "No rules yet",
				message: "lpm.json declares no env rules. Add keys to declare formats, defaults, and required keys; the LPM CLI enforces them and this page shows them."
			) {
				if let configFile {
					VaultBarButton(systemImage: "doc", title: "Open lpm.json", height: 28) { ProjectConfigOpener.open(configFile) }
				}
				VaultBarButton(title: "Docs: envSchema", height: 28) { NSWorkspace.shared.open(Self.docsURL) }
			} footer: {
				if undeclared.isEmpty {
					example
				} else {
					VStack(spacing: 0) {
						undeclaredHeader
						ScrollView {
							LazyVStack(spacing: 0) {
								ForEach(sortedUndeclared, id: \.key, content: undeclaredRow)
							}
						}
						.frame(height: min(CGFloat(undeclared.count) * Self.undeclaredRowHeight, 300))
					}
					.frame(maxWidth: 640)
					.clipShape(RoundedRectangle(cornerRadius: 8))
					.overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(VaultPalette.border))
				}
			}
		case .loaded(let overview, _)?:
			rulesTable(listed ?? self.listed(overview), saved: overview)
		case .unreadable(let problem)?:
			VStack(alignment: .leading, spacing: 0) {
				problemBanner(problem)
				Spacer(minLength: 0)
			}
			.padding(20)
		}
	}

	private var example: some View {
		Text(Self.example)
			.font(VaultTypography.mono(11.5))
			.foregroundStyle(VaultPalette.textSecondary)
			.textSelection(.enabled)
			.padding(14)
			.frame(maxWidth: 420, alignment: .leading)
			.background(RoundedRectangle(cornerRadius: 8).fill(VaultPalette.inspector))
			.overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(VaultPalette.border))
	}

	private func emptyState<Actions: View, Footer: View>(
		symbol: String,
		title: String,
		message: String,
		@ViewBuilder actions: () -> Actions,
		@ViewBuilder footer: () -> Footer = { EmptyView() }
	) -> some View {
		VStack(spacing: 12) {
			Image(systemName: symbol)
				.font(.system(size: 18, weight: .medium))
				.foregroundStyle(VaultPalette.textTertiary)
				.frame(width: 44, height: 44)
				.background(RoundedRectangle(cornerRadius: 10).fill(VaultPalette.neutralTint))
			Text(title)
				.font(.system(size: 15, weight: .semibold))
				.foregroundStyle(VaultPalette.textPrimary)
			Text(message)
				.font(.system(size: 12.5))
				.foregroundStyle(VaultPalette.textTertiary)
				.multilineTextAlignment(.center)
				.frame(maxWidth: 440)
			HStack(spacing: 8) { actions() }
				.padding(.top, 4)
			footer()
				.padding(.top, 10)
		}
		.padding(24)
		.frame(maxWidth: .infinity, maxHeight: .infinity)
	}

	private func problemBanner(_ problem: ProjectEnvSchemaState.Problem) -> some View {
		HStack(alignment: .top, spacing: 10) {
			Image(systemName: "exclamationmark.triangle.fill")
				.foregroundStyle(VaultPalette.red)
				.padding(.top, 1)
			VStack(alignment: .leading, spacing: 4) {
				Text("Schema can't be read")
					.font(.system(size: 13, weight: .semibold))
					.foregroundStyle(VaultPalette.textPrimary)
				(Text(problem.location).font(VaultTypography.mono(11.5)).foregroundColor(VaultPalette.accentForeground)
					+ Text(": " + problem.reason).font(.system(size: 12)).foregroundColor(VaultPalette.textSecondary))
					.textSelection(.enabled)
				Text("Values are unaffected; checks are paused until lpm.json can be read.")
					.font(.system(size: 11.5))
					.foregroundStyle(VaultPalette.textTertiary)
			}
			Spacer(minLength: 8)
			if let configFile {
				VaultBarButton(systemImage: "doc", title: "Open lpm.json", height: 28) { ProjectConfigOpener.open(configFile) }
			}
			VaultBarButton(title: "Recheck", filled: true, height: 28, action: onRecheck)
		}
		.padding(14)
		.background(RoundedRectangle(cornerRadius: 10).fill(VaultPalette.redTint))
		.overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(VaultPalette.red.opacity(0.55)))
	}

	// MARK: - Rules

	private func rulesTable(_ listed: Listed, saved: ProjectEnvSchemaOverview) -> some View {
		let rules = sortOrder == .ascending ? listed.rules : listed.rules.reversed()
		return ScrollView {
			LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
				Section {
					ForEach(rules, id: \.key) { rule in
						ruleRow(rule, state: rowState(rule.key, in: saved), description: description(of: rule.key))
							.overlay(alignment: .bottom) { VaultHairline(color: VaultPalette.rowDivider) }
					}
					if !listed.groups.isEmpty || canEdit {
						groupsHeader(count: listed.groupCount)
						ForEach(listed.groups, id: \.name) { group in
							groupRow(group, state: groupState(group.name, in: saved))
								.overlay(alignment: .bottom) { VaultHairline(color: VaultPalette.rowDivider) }
						}
					}
					// Rows go straight into the lazy stack, so only those on screen are built.
					if !undeclared.isEmpty {
						undeclaredHeader
						ForEach(sortedUndeclared, id: \.key, content: undeclaredRow)
					}
				} header: {
					HStack(spacing: 0) {
						VaultKeySortHeader(order: $sortOrder)
							.frame(width: Self.keyWidth, height: VaultMetrics.tableHeader)
						VaultHairline(axis: .vertical)
						HStack(spacing: 8) {
							Text("RULES").vaultSectionLabel()
							Text("only what differs from the default")
								.font(.system(size: 11))
								.foregroundStyle(VaultPalette.textFaint)
						}
						.padding(.horizontal, 14)
						.frame(maxWidth: .infinity, alignment: .leading)
					}
					.frame(height: VaultMetrics.tableHeader)
					.background(VaultPalette.headerRow)
					.overlay(alignment: .bottom) { VaultHairline(color: VaultPalette.sidebarBorder) }
				}
			}
		}
	}

	private static let keyWidth: CGFloat = 260

	/// What the page lists: the rules with the draft applied, from A to Z.
	private struct Listed {
		/// With the keys the draft removes kept, so they show as removed.
		var rules: [ProjectEnvSchemaOverview.Rule]
		/// With the groups the draft removes kept, so they show as removed.
		var groups: [ProjectEnvSchemaOverview.Group]
		/// Keys declared once the draft is saved.
		var declaredCount: Int
		/// Groups declared once the draft is saved.
		var groupCount: Int
		var inheritedCount: Int
	}

	/// The rules the draft leaves. Until the engine resolves the draft, the
	/// keys it changes show as it writes them.
	private func listed(_ saved: ProjectEnvSchemaOverview) -> Listed {
		guard let draft, !draft.isEmpty else {
			return Listed(rules: saved.rules, groups: saved.groups, declaredCount: saved.rules.count, groupCount: saved.groups.count,
				inheritedCount: saved.inheritedCount)
		}
		let shown = draftOverview ?? saved
		let changed = draft.changedItems
		var rules = shown.rules
		var added: [ProjectEnvSchemaOverview.Rule] = []
		var removed = 0
		for item in changed {
			guard case .key(let key) = item else { continue }
			let declaration = draft.declaration(of: item)
			if let json = declaration.json {
				guard draftOverview == nil else { continue }
				let isOverride = if case .overridden = declaration { true } else { false }
				let rule = ProjectEnvSchemaOverview.Rule(key: key, draft: json, isOverride: isOverride, saved: saved.rule(for: key))
				if let index = shown.position(of: key) { rules[index] = rule } else { added.append(rule) }
			} else if case .declared = draft.base(of: item) {
				removed += 1
				if shown.rule(for: key) == nil, let rule = saved.rule(for: key) { added.append(rule) }
			}
		}
		rules = VaultKeySortOrder.mergingAscending(added, into: rules, by: \.key)
		var groups = shown.groups
		var removedGroups = 0
		var appendedGroups = false
		for item in changed {
			guard case .group(let name) = item else { continue }
			let declaration = draft.declaration(of: item)
			if let json = declaration.json {
				guard draftOverview == nil else { continue }
				let isOverride = if case .overridden = declaration { true } else { false }
				let saved = saved.groups.first { $0.name == name }
				guard let row = ProjectEnvSchemaOverview.Group(name: name, draft: json, isOverride: isOverride, saved: saved) else { continue }
				if let index = groups.firstIndex(where: { $0.name == name }) {
					groups[index] = row
				} else {
					groups.append(row)
					appendedGroups = true
				}
			} else if case .declared = draft.base(of: item), draft.newName(ofGroup: name) == nil {
				// A renamed group shows once, under its new name.
				removedGroups += 1
				if !groups.contains(where: { $0.name == name }), let row = saved.groups.first(where: { $0.name == name }) {
					groups.append(row)
					appendedGroups = true
				}
			}
		}
		if appendedGroups { groups.sort { $0.name < $1.name } }
		return Listed(rules: rules, groups: groups, declaredCount: rules.count - removed, groupCount: groups.count - removedGroups,
			inheritedCount: shown.inheritedCount)
	}

	private func groupState(_ name: String, in saved: ProjectEnvSchemaOverview) -> RowState {
		guard let draft, draft.hasChange(to: .group(name)) else { return .saved }
		if let original = draft.originalName(ofGroup: name) { return .renamed(from: original.escapingDirectionControls) }
		switch (draft.base(of: .group(name)), draft.declaration(of: .group(name))) {
		case (.declared, .absent): return .removed
		case (.absent, .declared) where !saved.groups.contains(where: { $0.name == name }): return .new
		default: return .draft
		}
	}

	private func rowState(_ key: String, in saved: ProjectEnvSchemaOverview) -> RowState {
		guard let draft, draft.hasChange(to: .key(key)) else { return .saved }
		switch (draft.base(of: .key(key)), draft.declaration(of: .key(key))) {
		case (.declared, .absent): return .removed
		case (.absent, .declared) where saved.rule(for: key) == nil: return .new
		default: return .draft
		}
	}

	private func description(of key: String) -> String? {
		Self.rowDescription(of: key, saved: descriptions, draft: draft, draftOverview: draftOverview)
	}

	/// The description the draft gives a key it changes, or lpm.json's, escaped
	/// because lpm.json and the schemas it imports are shared files.
	static func rowDescription(
		of key: String, saved descriptions: [String: String], draft: ProjectEnvSchemaDraft?, draftOverview: ProjectEnvSchemaOverview?
	) -> String? {
		var text = descriptions[key]
		if let draft, draft.hasChange(to: .key(key)) {
			switch draft.declaration(of: .key(key)) {
			case .declared(let json), .overridden(let json):
				text = if case .string(let described)? = json["description"] { described } else { nil }
			case .absent:
				if case .overridden = draft.base(of: .key(key)), let overview = draftOverview {
					text = if case .string(let described)? = overview.declaration(of: key)?["description"] { described } else { nil }
				}
			}
		}
		return text?.escapingDirectionControls
	}

	private func ruleRow(_ rule: ProjectEnvSchemaOverview.Rule, state: RowState, description: String?) -> some View {
		let selected = selection == .key(rule.key)
		return Button { onSelect(selected ? nil : .key(rule.key)) } label: {
			ruleRowContent(rule, state: state, description: description, selected: selected)
		}
		.buttonStyle(.plain)
		.accessibilityAddTraits(selected ? .isSelected : [])
	}

	private func ruleRowContent(_ rule: ProjectEnvSchemaOverview.Rule, state: RowState, description: String?, selected: Bool) -> some View {
		HStack(alignment: .top, spacing: 0) {
			VStack(alignment: .leading, spacing: 3) {
				HStack(spacing: 7) {
					Text(rule.key)
						.font(VaultTypography.mono(12.5, .semibold))
						.foregroundStyle(state == .removed ? VaultPalette.textFaint : VaultPalette.textPrimary)
						.strikethrough(state == .removed)
						.lineLimit(1)
						.truncationMode(.middle)
					if rule.isPublic, state != .removed { VaultPublicBadge() }
					switch state {
					case .saved: EmptyView()
					case .draft: VaultTagBadge(text: "Draft", foreground: VaultPalette.orangeTintText, background: VaultPalette.orangeTint, size: 10)
					case .new: VaultTagBadge(text: "New", foreground: VaultPalette.orangeTintText, background: VaultPalette.orangeTint, size: 10)
					case .removed: VaultTagBadge(text: "Removed", foreground: VaultPalette.redText, background: VaultPalette.redTint, size: 10)
					case .renamed(let original):
						VaultTagBadge(text: "Renamed", foreground: VaultPalette.orangeTintText, background: VaultPalette.orangeTint, size: 10)
							.help("Renamed from \(original) in your draft")
					}
				}
				if let description, !description.isEmpty {
					Text(description)
						.font(.system(size: 11.5))
						.foregroundStyle(VaultPalette.textTertiary)
						.lineLimit(2)
				}
			}
			.padding(.leading, 20)
			.padding(.trailing, 12)
			.frame(width: Self.keyWidth, alignment: .leading)

			Group {
				if rule.badges.isEmpty, rule.source == nil, rule.overrides == nil {
					Text("No rules")
						.font(.system(size: 11.5).italic())
						.foregroundStyle(VaultPalette.textFaint)
				} else {
					VaultFlowLayout {
						ForEach(rule.badges, id: \.self) { VaultRuleBadge(badge: $0) }
						if let source = rule.source { VaultSourceBadge(source: source) }
						if let source = rule.overrides { VaultSourceBadge(source: source, isOverridden: true) }
					}
				}
			}
			.padding(.horizontal, 14)
			.frame(maxWidth: .infinity, alignment: .leading)
			.opacity(state == .removed ? 0.6 : 1)
		}
		.padding(.vertical, 10)
		.background(selected ? VaultPalette.selectedEnvCell : .clear)
		.overlay(alignment: .leading) {
			if selected { Rectangle().fill(VaultPalette.accent).frame(width: 2) }
		}
		.contentShape(Rectangle())
		.accessibilityElement(children: .combine)
	}

	/// Stored keys lpm.json doesn't declare, in the table's order.
	private var sortedUndeclared: [VaultStore.StoredSchemaKey] {
		sortOrder == .ascending ? undeclared : undeclared.reversed()
	}

	private var undeclaredHeader: some View {
		HStack(spacing: 8) {
			Text("STORED, NOT DECLARED · \(undeclared.count)").vaultSectionLabel()
			Text("in the Keychain but not in lpm.json — the LPM CLI doesn't check them")
				.font(.system(size: 11))
				.foregroundStyle(VaultPalette.textFaint)
				.lineLimit(1)
		}
		.padding(.horizontal, 20)
		.padding(.vertical, 8)
		.frame(maxWidth: .infinity, alignment: .leading)
		.background(VaultPalette.headerRow)
		.overlay(alignment: .bottom) { VaultHairline(color: VaultPalette.rowDivider) }
	}

	private func undeclaredRow(_ stored: VaultStore.StoredSchemaKey) -> some View {
		HStack(spacing: 0) {
			HStack(spacing: 8) {
				Text(stored.key.escapingDirectionControls)
					.font(VaultTypography.mono(12.5))
					.foregroundStyle(VaultPalette.textSecondary)
					.lineLimit(1)
					.truncationMode(.middle)
				Text(stored.environments == 1 ? "set in 1 env" : "set in \(stored.environments) envs")
					.font(.system(size: 11))
					.foregroundStyle(VaultPalette.textFaint)
					.fixedSize()
			}
			.padding(.leading, 20)
			.padding(.trailing, 12)
			.frame(width: Self.keyWidth, alignment: .leading)
			HStack(spacing: 8) {
				if stored.isIgnored {
					Text("The LPM CLI never passes it to a process")
						.font(.system(size: 11.5).italic())
						.foregroundStyle(VaultPalette.textFaint)
						.lineLimit(1)
				} else if let conflict = stored.conflict {
					Text("Differs from \(conflict.escapingDirectionControls) only in letter case")
						.font(.system(size: 11.5))
						.foregroundStyle(VaultPalette.orangeTintText)
						.lineLimit(1)
						.help("Windows reads both as one name, so the LPM CLI can't tell them apart there. Rename the stored key to match.")
				} else {
					Text("Not in schema")
						.font(.system(size: 11.5).italic())
						.foregroundStyle(VaultPalette.textFaint)
				}
				Spacer(minLength: 8)
				if let conflict = stored.conflict, !stored.isIgnored {
					VaultBarButton(title: "Open \(conflict)", height: 24) { onSelect(.key(conflict)) }
						.accessibilityLabel("Open \(conflict.escapingDirectionControls)")
				} else if canEdit, !stored.isIgnored {
					VaultBarButton(systemImage: "plus", title: "Declare", height: 24) { onDeclare(stored.key) }
						.accessibilityLabel("Declare \(stored.key.escapingDirectionControls)")
				}
			}
			.padding(.horizontal, 14)
		}
		.frame(height: Self.undeclaredRowHeight)
		.overlay(alignment: .bottom) { VaultHairline(color: VaultPalette.rowDivider) }
	}

	private static let undeclaredRowHeight: CGFloat = 42

	private func groupsHeader(count: Int) -> some View {
		HStack(spacing: 8) {
			Text("GROUPS · \(count)").vaultSectionLabel()
			Text("keys the LPM CLI checks together")
				.font(.system(size: 11))
				.foregroundStyle(VaultPalette.textFaint)
				.lineLimit(1)
			Spacer(minLength: 8)
			if canEdit {
				let full = count >= ProjectEnvSchemaGroup.maximumGroups
				Button(action: onAddGroup) {
					HStack(spacing: 4) {
						Image(systemName: "plus").font(.system(size: 9, weight: .semibold))
						Text("Add group").font(.system(size: 11.5, weight: .semibold))
					}
					.foregroundStyle(VaultPalette.accentForeground)
				}
				.buttonStyle(.plain)
				.disabled(full)
				.opacity(full ? 0.4 : 1)
				.vaultPointingHand()
				.help(full ? "The LPM CLI accepts at most \(ProjectEnvSchemaGroup.maximumGroups) groups" : "Declare a group of keys in lpm.json")
			}
		}
		.padding(.horizontal, 20)
		.padding(.vertical, 8)
		.frame(maxWidth: .infinity, alignment: .leading)
		.background(VaultPalette.headerRow)
		.overlay(alignment: .bottom) { VaultHairline(color: VaultPalette.rowDivider) }
	}

	private func groupRow(_ group: ProjectEnvSchemaOverview.Group, state: RowState) -> some View {
		let selected = selection == .group(group.name)
		let mode = ProjectEnvSchemaGroup.Mode(rawValue: group.mode)
		return Button { onSelect(selected ? nil : .group(group.name)) } label: {
			HStack(spacing: 8) {
				Image(systemName: "square.stack.3d.up").font(.system(size: 11)).foregroundStyle(VaultPalette.textTertiary)
				Text(group.name.escapingDirectionControls)
					.font(VaultTypography.mono(12.5, .semibold))
					.foregroundStyle(state == .removed ? VaultPalette.textFaint : VaultPalette.textPrimary)
					.strikethrough(state == .removed)
					.lineLimit(1)
				Text("·").foregroundStyle(VaultPalette.textFaint)
				(Text(mode?.title ?? group.mode).font(.system(size: 12)).foregroundColor(VaultPalette.textTertiary)
					+ Text(" " + group.memberPreview).font(VaultTypography.mono(12)).foregroundColor(VaultPalette.textSecondary))
					.lineLimit(1)
					.truncationMode(.tail)
					.opacity(state == .removed ? 0.6 : 1)
				if let source = group.source { VaultSourceBadge(source: source, declares: "the group") }
				if let source = group.overrides { VaultSourceBadge(source: source, isOverridden: true, declares: "the group") }
				switch state {
				case .saved: EmptyView()
				case .draft: VaultTagBadge(text: "Draft", foreground: VaultPalette.orangeTintText, background: VaultPalette.orangeTint, size: 10)
				case .new: VaultTagBadge(text: "New", foreground: VaultPalette.orangeTintText, background: VaultPalette.orangeTint, size: 10)
				case .removed: VaultTagBadge(text: "Removed", foreground: VaultPalette.redText, background: VaultPalette.redTint, size: 10)
				case .renamed(let original):
					VaultTagBadge(text: "Renamed", foreground: VaultPalette.orangeTintText, background: VaultPalette.orangeTint, size: 10)
						.help("Renamed from \(original) in your draft")
				}
				Spacer(minLength: 0)
			}
			.padding(.horizontal, 20)
			.frame(minHeight: 38)
			.background(selected ? VaultPalette.selectedEnvCell : .clear)
			.overlay(alignment: .leading) {
				if selected { Rectangle().fill(VaultPalette.accent).frame(width: 2) }
			}
			.contentShape(Rectangle())
			.accessibilityElement(children: .combine)
		}
		.buttonStyle(.plain)
		.accessibilityAddTraits(selected ? .isSelected : [])
	}

	// MARK: - Status bar

	private func statusBar(_ listed: Listed?) -> some View {
		HStack(spacing: 12) {
			switch state {
			case .loaded?:
				if let listed, !listed.rules.isEmpty || !listed.groups.isEmpty {
					loadedStatus(listed)
				} else {
					Text("No rules · values stay in the Keychain")
				}
			case .unreadable?:
				Text("Checks paused: lpm.json can't be read")
					.foregroundStyle(VaultPalette.redText)
			case .noFolder?:
				Text("No project folder · values stay in the Keychain")
			case nil:
				EmptyView()
			}
			Spacer(minLength: 0)
		}
		.font(.system(size: 11))
		.foregroundStyle(VaultPalette.textTertiary)
		.lineLimit(1)
		.padding(.horizontal, 20)
		.frame(height: VaultMetrics.statusBar)
		.background(VaultPalette.headerRow)
	}

	@ViewBuilder
	private func loadedStatus(_ listed: Listed) -> some View {
		Text(Self.count(listed.declaredCount, "declared key"))
		Text("·")
		Text(Self.count(listed.groupCount, "group"))
		Text("·")
		Text("\(listed.inheritedCount) inherited")
		if let changes = draft?.changeCount, changes > 0 {
			Text("·")
			Text(changes == 1 ? "1 unsaved change" : "\(changes) unsaved changes")
				.fontWeight(.semibold)
				.foregroundStyle(VaultPalette.orangeTintText)
		}
		Text("·")
		Text("enforced by LPM CLI")
	}

	private static func count(_ value: Int, _ noun: String) -> String {
		"\(value) \(noun)\(value == 1 ? "" : "s")"
	}
}
