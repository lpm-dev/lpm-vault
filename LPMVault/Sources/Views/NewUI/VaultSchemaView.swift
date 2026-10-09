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
	let onConnectCLI: () -> Void
	let onRecheck: () -> Void

	/// How a row differs from lpm.json in the draft.
	enum RowState: Equatable {
		case saved, draft, new, removed
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
				VaultOutlineButton(systemImage: "doc", title: "Open lpm.json", help: "Open lpm.json in its default editor") {
					NSWorkspace.shared.open(configFile)
				}
				.fixedSize()
			}
		}
		.padding(.horizontal, 20)
		.frame(height: 64)
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
				message: "lpm.json has no envSchema. Add one to declare formats, defaults, and required keys; the LPM CLI enforces them and this page shows them."
			) {
				if let configFile {
					VaultBarButton(systemImage: "doc", title: "Open lpm.json", height: 28) { NSWorkspace.shared.open(configFile) }
				}
				VaultBarButton(title: "Docs: envSchema", height: 28) { NSWorkspace.shared.open(Self.docsURL) }
			} footer: {
				Text(Self.example)
					.font(VaultTypography.mono(11.5))
					.foregroundStyle(VaultPalette.textSecondary)
					.textSelection(.enabled)
					.padding(14)
					.frame(maxWidth: 420, alignment: .leading)
					.background(RoundedRectangle(cornerRadius: 8).fill(VaultPalette.inspector))
					.overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(VaultPalette.border))
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
				VaultBarButton(systemImage: "doc", title: "Open lpm.json", height: 28) { NSWorkspace.shared.open(configFile) }
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
					if !listed.groups.isEmpty {
						groupsRow(listed.groups)
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
		var groups: [ProjectEnvSchemaOverview.Group]
		/// Keys declared once the draft is saved.
		var declaredCount: Int
		var inheritedCount: Int
	}

	/// The rules the draft leaves. Until the engine resolves the draft, the
	/// keys it changes show as it writes them.
	private func listed(_ saved: ProjectEnvSchemaOverview) -> Listed {
		guard let draft, !draft.isEmpty else {
			return Listed(rules: saved.rules, groups: saved.groups, declaredCount: saved.rules.count, inheritedCount: saved.inheritedCount)
		}
		let shown = draftOverview ?? saved
		var rules = shown.rules
		var added: [ProjectEnvSchemaOverview.Rule] = []
		var removed = 0
		for item in draft.changedItems {
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
		return Listed(rules: rules, groups: shown.groups, declaredCount: rules.count - removed, inheritedCount: shown.inheritedCount)
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

	private func groupsRow(_ groups: [ProjectEnvSchemaOverview.Group]) -> some View {
		HStack(alignment: .firstTextBaseline, spacing: 12) {
			Text("GROUPS").vaultSectionLabel()
			VStack(alignment: .leading, spacing: 4) {
				ForEach(groups, id: \.name) { group in
					Text(group.summary)
						.font(.system(size: 12))
						.foregroundStyle(VaultPalette.textSecondary)
				}
			}
		}
		.padding(.horizontal, 20)
		.padding(.vertical, 12)
		.frame(maxWidth: .infinity, alignment: .leading)
		.overlay(alignment: .bottom) { VaultHairline(color: VaultPalette.rowDivider) }
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
		Text(Self.count(listed.groups.count, "group"))
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
