import SwiftUI

/// The quit shortcut, as the Settings page's General card shows it.
struct VaultGeneralSettingsSection: View {
	@Environment(VaultQuitSettings.self) private var quitSettings

	var body: some View {
		@Bindable var quitSettings = quitSettings
		VaultSettingsRows {
			VaultSettingsRow(title: "Quit shortcut", detail: quitSettings.selection.explanation) {
				VaultSegmentedPicker(title: "Quit shortcut", options: VaultQuitShortcut.allCases.map { ($0, $0.title) },
					selection: $quitSettings.selection, segmentWidth: VaultSettingsLayout.segment)
					.accessibilityHint(quitSettings.selection.explanation)
			}
		}
	}
}

/// The theme, as the Settings page's Appearance card shows it.
struct VaultAppearanceSettingsSection: View {
	@Environment(VaultAppearanceSettings.self) private var appearanceSettings

	private static let themeExplanation = "System follows macOS. Light and Dark apply only to Vault."

	var body: some View {
		@Bindable var appearanceSettings = appearanceSettings
		VaultSettingsRows {
			VaultSettingsRow(title: "Theme", detail: Self.themeExplanation) {
				VaultSegmentedPicker(title: "Appearance", options: VaultAppearance.allCases.map { ($0, $0.title) },
					selection: $appearanceSettings.selection, segmentWidth: VaultSettingsLayout.segment)
					.accessibilityHint(Self.themeExplanation)
			}
		}
	}
}

/// The installed version and the update channel, as the Settings page's Updates card shows them.
struct VaultUpdateSettingsSection: View {
	@Environment(UpdateChecker.self) private var updateChecker

	var body: some View {
		@Bindable var updates = updateChecker
		VaultSettingsRows {
			VaultSettingsRow(title: "Installed version", detail: updates.buildInfo.displayVersion, detailIsSelectable: true) {
				VaultBarButton(title: "Check for Updates…", disabled: !updates.canCheckForUpdates, height: 28) {
					updates.checkForUpdates()
				}
			}
			VaultHairline()
			VaultSettingsRow(title: "Update channel", detail: updates.channelDescription) {
				VaultSegmentedPicker(title: "Update channel", options: VaultReleaseChannel.allCases.map { ($0, $0.title) },
					selection: $updates.channel, segmentWidth: VaultSettingsLayout.segment)
					.disabled(!updates.canChangeChannel)
				.accessibilityHint(updates.channelDescription)
			}
			if updates.hasPendingUpdate {
				Text("Install or skip the pending update before changing channels. Use Check for Updates to reopen it.")
					.font(.system(size: 11.5))
					.foregroundStyle(VaultPalette.textTertiary)
					.fixedSize(horizontal: false, vertical: true)
			}
		}
	}
}

/// Where the LPM CLI keeps login and env projects, as the Settings page's LPM
/// Home card shows it, and the change to another home, which moves what the
/// current one holds there and relaunches the app.
struct VaultLPMHomeSettingsSection: View {
	@Bindable var store: VaultStore
	var folderPicker: @MainActor () -> URL? = Self.pickFolder

	/// A home to change to, with what it and the current one hold.
	struct Change: Identifiable {
		let target: LPMHome
		let current: LPMHomeMove.Contents
		let found: LPMHomeMove.Contents
		var id: String { target.url.path + (target.scope ?? "") }
	}

	@State private var change: Change?
	@State private var problem: String?
	@State private var isWorking = false
	@State private var leftovers: (home: String, items: [String])?

	private static let explanation = "Where the LPM CLI keeps your login and env projects. If your shell sets LPM_HOME, use the same folder."

	var body: some View {
		VaultSettingsRows {
			// A path in the code font, as a project's folder is, and what it is in the system font.
			VaultSettingsRow(
				titleText: Text(store.lpmHome.displayPath).font(VaultTypography.code(12.5, .medium))
					+ Text(store.lpmHome.isDefault ? "  (default)" : "").font(.system(size: 12)).foregroundColor(VaultPalette.textTertiary),
				detail: Self.explanation, detailIsSelectable: false
			) {
				HStack(spacing: 8) {
					if !store.lpmHome.isDefault {
						VaultBarButton(title: "Use Default", disabled: isWorking, height: 28) {
							begin { await consider(LPMHome(defaultIn: store.lpmHome.userHome)) }
						}
					}
					VaultBarButton(title: "Choose Folder…", disabled: isWorking, height: 28) { chooseFolder() }
				}
			}
			if let problem {
				Text(problem)
					.font(.system(size: 11.5))
					.foregroundStyle(VaultPalette.redText)
					.fixedSize(horizontal: false, vertical: true)
			}
			if let leftovers {
				HStack(alignment: .firstTextBaseline, spacing: 8) {
					Text("The last move couldn't remove \(leftovers.items.count.counted("item")) from \(leftovers.home). They are copies of what moved.")
						.font(.system(size: 11.5))
						.foregroundStyle(VaultPalette.orange)
						.fixedSize(horizontal: false, vertical: true)
					Spacer(minLength: 8)
					VaultBarButton(title: "Dismiss", height: 26) {
						LPMHome.recordLeftovers([], of: store.lpmHome, in: store.preferences)
						self.leftovers = nil
					}
				}
			}
		}
		.vaultConfirmation(item: $change) { change in confirmation(for: change) }
		.onAppear { leftovers = LPMHome.leftovers(in: store.preferences) }
	}

	private func chooseFolder() {
		guard let url = folderPicker() else { return }
		begin {
			guard let target = await store.lpmHome(at: url) else {
				problem = "LPM Vault can't use \((url.path as NSString).abbreviatingWithTildeInPath) as an LPM home."
				return
			}
			await consider(target)
		}
	}

	/// Runs `work` with the buttons disabled, clearing the last problem first.
	private func begin(_ work: @escaping @MainActor () async -> Void) {
		problem = nil
		isWorking = true
		Task {
			await work()
			isWorking = false
		}
	}

	/// Reads what the current home and `target` hold, then asks how to change to it.
	private func consider(_ target: LPMHome) async {
		guard target.scope != store.lpmHome.scope else {
			problem = "\(target.displayPath) is the LPM home LPM Vault uses already."
			return
		}
		let found = await store.lpmHomeContents(target)
		let held = await store.lpmHomeContents(store.lpmHome)
		guard let found, let held else {
			problem = "LPM Vault couldn't read what the LPM homes hold, so it changed nothing."
			return
		}
		change = Change(target: target, current: held, found: found)
	}

	private func confirmation(for change: Change) -> VaultConfirmation {
		let target = change.target.displayPath
		let current = store.lpmHome.displayPath
		let relaunches = "LPM Vault then relaunches to use it."
		if !change.found.isEmpty {
			return VaultConfirmation(
				symbol: "folder", tone: .standard,
				title: "Use \(target)?",
				message: "It already holds \(Self.describe(change.found)). \(relaunches) What \(current) holds stays there.",
				actions: [.init(title: "Use and Relaunch") { apply(change.target, moving: false) }])
		}
		if change.current.isEmpty {
			return VaultConfirmation(
				symbol: "folder", tone: .standard,
				title: "Use \(target)?",
				message: "Neither home holds a login or env projects. \(relaunches)",
				actions: [.init(title: "Use and Relaunch") { apply(change.target, moving: false) }])
		}
		return VaultConfirmation(
			symbol: "folder", tone: .standard,
			title: "Move to \(target)?",
			message: "LPM Vault moves \(Self.describe(change.current)) from \(current) there, where the LPM CLI finds them, and asks you to confirm first. \(relaunches)",
			actions: [
				.init(title: "Use Without Moving", role: .secondary) { apply(change.target, moving: false) },
				.init(title: "Move and Relaunch") { apply(change.target, moving: true) },
			])
	}

	private static func describe(_ contents: LPMHomeMove.Contents) -> String {
		var parts: [String] = []
		if contents.projects > 0 { parts.append(contents.projects.counted("env project")) }
		if contents.signedIn { parts.append("a login") }
		return parts.isEmpty ? "login and env data" : parts.joined(separator: " and ")
	}

	private func apply(_ target: LPMHome, moving: Bool) {
		begin {
			do {
				try await store.changeLPMHome(to: target, moving: moving)
			} catch is CancellationError {
			} catch {
				problem = error.localizedDescription
			}
		}
	}

	private static func pickFolder() -> URL? {
		let panel = NSOpenPanel()
		panel.canChooseFiles = false
		panel.canChooseDirectories = true
		panel.canCreateDirectories = true
		panel.allowsMultipleSelection = false
		panel.prompt = "Use as LPM Home"
		panel.message = "Choose the folder your shell's LPM_HOME names"
		guard runVaultPrivacyAwareModal(panel) == .OK else { return nil }
		return panel.url
	}
}

/// A settings card's rows, with the spacing every card shares.
private struct VaultSettingsRows<Content: View>: View {
	@ViewBuilder let content: Content

	var body: some View {
		VStack(alignment: .leading, spacing: 12) { content }
			.frame(maxWidth: .infinity, alignment: .leading)
	}
}

/// A setting's name and explanation, with its control on the trailing side.
/// A detail that's a value, such as the version, can be selected and copied.
private struct VaultSettingsRow<Control: View>: View {
	let title: Text
	let detail: String
	var detailIsSelectable = false
	@ViewBuilder let control: Control

	init(title: String, detail: String, detailIsSelectable: Bool = false, @ViewBuilder control: () -> Control) {
		self.init(titleText: Text(title).font(.system(size: 13, weight: .semibold)), detail: detail,
			detailIsSelectable: detailIsSelectable, control: control)
	}

	/// A title drawn its own way, such as a path in the code font.
	init(titleText: Text, detail: String, detailIsSelectable: Bool = false, @ViewBuilder control: () -> Control) {
		title = titleText
		self.detail = detail
		self.detailIsSelectable = detailIsSelectable
		self.control = control()
	}

	var body: some View {
		HStack(alignment: .center, spacing: 12) {
			VStack(alignment: .leading, spacing: 3) {
				title
					.foregroundStyle(VaultPalette.textPrimary)
				if detailIsSelectable {
					Text(detail)
						.font(VaultTypography.tabular(11))
						.foregroundStyle(VaultPalette.textTertiary)
						.textSelection(.enabled)
				} else {
					Text(detail)
						.font(.system(size: 11.5))
						.foregroundStyle(VaultPalette.textTertiary)
						.fixedSize(horizontal: false, vertical: true)
						.frame(maxWidth: VaultMetrics.explanationWidth, alignment: .leading)
				}
			}
			.frame(maxWidth: .infinity, alignment: .leading)
			control
		}
	}
}

/// What the Settings page's controls share, so they line up down the page.
enum VaultSettingsLayout {
	/// Each segment's width in the page's segmented pickers: "Double press" with room to spare.
	static let segment: CGFloat = 104
}
