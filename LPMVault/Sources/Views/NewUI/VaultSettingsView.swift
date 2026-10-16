import SwiftUI

/// The app's own settings, in the Settings window (⌘,). Nothing here needs
/// the vault unlocked or an account, so it all works on the lock screen and
/// signed out; the account and server are on the in-window Account page.
struct VaultSettingsView: View {
	var body: some View {
		TabView {
			VaultGeneralSettingsPane()
				.tabItem { Label("General", systemImage: "gearshape") }
			VaultAppearanceSettingsPane()
				.tabItem { Label("Appearance", systemImage: "paintpalette") }
			VaultUpdateSettingsPane()
				.tabItem { Label("Updates", systemImage: "arrow.down.circle") }
		}
		.frame(width: 520)
	}
}

struct VaultGeneralSettingsPane: View {
	@Environment(VaultQuitSettings.self) private var quitSettings

	var body: some View {
		@Bindable var quitSettings = quitSettings
		VaultSettingsPane {
			VaultSettingsRow(title: "Quit shortcut", detail: quitSettings.selection.explanation) {
				Picker("Quit shortcut", selection: $quitSettings.selection) {
					ForEach(VaultQuitShortcut.allCases) { Text($0.title).tag($0) }
				}
				.pickerStyle(.segmented)
				.labelsHidden()
				.fixedSize()
			}
		}
	}
}

struct VaultAppearanceSettingsPane: View {
	@Environment(VaultAppearanceSettings.self) private var appearanceSettings

	var body: some View {
		@Bindable var appearanceSettings = appearanceSettings
		VaultSettingsPane {
			VaultSettingsRow(title: "Theme", detail: "System follows macOS. Light and Dark apply only to Vault.") {
				Picker("Appearance", selection: $appearanceSettings.selection) {
					ForEach(VaultAppearance.allCases) { Text($0.title).tag($0) }
				}
				.pickerStyle(.segmented)
				.labelsHidden()
				.fixedSize()
			}
		}
	}
}

struct VaultUpdateSettingsPane: View {
	@Environment(UpdateChecker.self) private var updateChecker

	var body: some View {
		@Bindable var updates = updateChecker
		VaultSettingsPane {
			VaultSettingsRow(title: "Installed version", detail: updates.buildInfo.displayVersion) {
				VaultBarButton(title: "Check for Updates…", disabled: !updates.canCheckForUpdates, height: 28) {
					updates.checkForUpdates()
				}
			}
			VaultHairline(color: VaultPalette.rowDivider)
			VaultSettingsRow(title: "Update channel", detail: updates.channelDescription) {
				Picker("Update channel", selection: $updates.channel) {
					ForEach(VaultReleaseChannel.allCases) { Text($0.title).tag($0) }
				}
				.pickerStyle(.segmented)
				.labelsHidden()
				.fixedSize()
				.disabled(!updates.canChangeChannel)
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

/// A Settings tab's rows, with the spacing every tab shares.
private struct VaultSettingsPane<Content: View>: View {
	@ViewBuilder let content: Content

	var body: some View {
		VStack(alignment: .leading, spacing: 14) { content }
			.padding(.horizontal, 20)
			.padding(.top, 18)
			.padding(.bottom, 20)
			.frame(maxWidth: .infinity, alignment: .leading)
			.background(VaultPalette.content)
	}
}

/// A setting's name and explanation, with its control on the trailing side.
private struct VaultSettingsRow<Control: View>: View {
	let title: String
	let detail: String
	@ViewBuilder let control: Control

	var body: some View {
		HStack(alignment: .center, spacing: 12) {
			VStack(alignment: .leading, spacing: 3) {
				Text(title)
					.font(.system(size: 13))
					.foregroundStyle(VaultPalette.textPrimary)
				Text(detail)
					.font(.system(size: 11.5))
					.foregroundStyle(VaultPalette.textTertiary)
					.fixedSize(horizontal: false, vertical: true)
			}
			.frame(maxWidth: .infinity, alignment: .leading)
			control
		}
	}
}
