import AppKit
import SwiftUI

/// A project's env rules from lpm.json, read-only. People edit rules in
/// lpm.json; this page shows what the LPM CLI enforces, and what to do when
/// there are no rules or lpm.json can't be read.
struct VaultSchemaView: View {
	let state: ProjectEnvSchemaState?
	/// The folder whose lpm.json holds the rules.
	let folder: String?
	let descriptions: [String: String]
	@Binding var sortOrder: VaultKeySortOrder
	let onConnectCLI: () -> Void
	let onRecheck: () -> Void

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
		VStack(spacing: 0) {
			header
			VaultHairline()
			content
				.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
			VaultHairline()
			statusBar
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
	private var content: some View {
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
		case .loaded(let overview, _)? where overview.isEmpty:
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
			rulesTable(overview)
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

	private func rulesTable(_ overview: ProjectEnvSchemaOverview) -> some View {
		let rules = sortOrder == .ascending ? overview.rules : overview.rules.reversed()
		return ScrollView {
			LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
				Section {
					ForEach(rules, id: \.key) { rule in
						ruleRow(rule)
							.overlay(alignment: .bottom) { VaultHairline(color: VaultPalette.rowDivider) }
					}
					if !overview.groups.isEmpty {
						groupsRow(overview.groups)
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

	private func ruleRow(_ rule: ProjectEnvSchemaOverview.Rule) -> some View {
		HStack(alignment: .top, spacing: 0) {
			VStack(alignment: .leading, spacing: 3) {
				HStack(spacing: 7) {
					Text(rule.key)
						.font(VaultTypography.mono(12.5, .semibold))
						.foregroundStyle(VaultPalette.textPrimary)
						.lineLimit(1)
						.truncationMode(.middle)
					if rule.isPublic { VaultPublicBadge() }
				}
				if let description = descriptions[rule.key], !description.isEmpty {
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
				if rule.badges.isEmpty, rule.source == nil {
					Text("No rules")
						.font(.system(size: 11.5).italic())
						.foregroundStyle(VaultPalette.textFaint)
				} else {
					VaultFlowLayout {
						ForEach(rule.badges, id: \.self) { VaultRuleBadge(badge: $0) }
						if let source = rule.source { VaultSourceBadge(source: source) }
					}
				}
			}
			.padding(.horizontal, 14)
			.frame(maxWidth: .infinity, alignment: .leading)
		}
		.padding(.vertical, 10)
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

	private var statusBar: some View {
		HStack(spacing: 12) {
			switch state {
			case .loaded(let overview, _)? where !overview.isEmpty:
				Text(Self.count(overview.rules.count, "declared key"))
				Text("·")
				Text(Self.count(overview.groups.count, "group"))
				Text("·")
				Text("\(overview.inheritedCount) inherited")
				Text("·")
				Text("enforced by LPM CLI")
			case .unreadable?:
				Text("Checks paused: lpm.json can't be read")
					.foregroundStyle(VaultPalette.redText)
			case .loaded?:
				Text("No rules · values stay in the Keychain")
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

	private static func count(_ value: Int, _ noun: String) -> String {
		"\(value) \(noun)\(value == 1 ? "" : "s")"
	}
}
