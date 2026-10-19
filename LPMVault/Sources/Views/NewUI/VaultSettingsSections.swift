import SwiftUI

/// The quit shortcut, as the Settings page's General card shows it.
struct VaultGeneralSettingsSection: View {
	@Environment(VaultQuitSettings.self) private var quitSettings

	var body: some View {
		@Bindable var quitSettings = quitSettings
		VaultSettingsRows {
			VaultSettingsRow(title: "Quit shortcut", detail: quitSettings.selection.explanation) {
				Picker("Quit shortcut", selection: $quitSettings.selection) {
					ForEach(VaultQuitShortcut.allCases) { Text($0.title).tag($0) }
				}
				.pickerStyle(.segmented)
				.labelsHidden()
				.fixedSize()
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
				Picker("Appearance", selection: $appearanceSettings.selection) {
					ForEach(VaultAppearance.allCases) { Text($0.title).tag($0) }
				}
				.pickerStyle(.segmented)
				.labelsHidden()
				.fixedSize()
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
			VaultHairline(color: VaultPalette.rowDivider)
			VaultSettingsRow(title: "Update channel", detail: updates.channelDescription) {
				Picker("Update channel", selection: $updates.channel) {
					ForEach(VaultReleaseChannel.allCases) { Text($0.title).tag($0) }
				}
				.pickerStyle(.segmented)
				.labelsHidden()
				.fixedSize()
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
	let title: String
	let detail: String
	var detailIsSelectable = false
	@ViewBuilder let control: Control

	var body: some View {
		HStack(alignment: .center, spacing: 12) {
			VStack(alignment: .leading, spacing: 3) {
				Text(title)
					.font(.system(size: 13))
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
				}
			}
			.frame(maxWidth: .infinity, alignment: .leading)
			control
		}
	}
}
