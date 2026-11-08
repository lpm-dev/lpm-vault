import AppKit
import SwiftUI

// MARK: - Security

/// How long the vault stays unlocked, and when it locks regardless.
struct VaultLockingSettingsSection: View {
	@Bindable var settings: VaultSettings

	var body: some View {
		VaultSettingsRows {
			VaultSettingsRow(.lockAfter,
				detail: "Locks LPM Vault when it’s had no input this long. The title bar counts down the last 30 seconds.") {
				VaultSettingsMenu(.lockAfter, options: VaultLockInterval.allCases.map { ($0, $0.title) }, selection: $settings.lockAfter)
			}
			VaultHairline()
			VaultSettingsFact(.lockOnSleep)
			VaultSettingsFact(.hideInBackground)
			Text("Locking only forgets what was unlocked: your values stay in the Keychain, and unlocking asks for Touch ID or your password again.")
				.font(.system(size: 11.5))
				.foregroundStyle(VaultPalette.textTertiary)
				.fixedSize(horizontal: false, vertical: true)
		}
	}
}

/// When showing or copying a value asks again, and when shown values are masked again.
struct VaultValueSettingsSection: View {
	@Bindable var settings: VaultSettings

	var body: some View {
		VaultSettingsRows {
			VaultSettingsRow(.valueApproval,
				detail: "Asks for Touch ID or your Mac password once the last approval is this old, even while LPM Vault is unlocked. Unlocking counts as an approval.") {
				VaultSettingsMenu(.valueApproval, options: VaultValueApproval.allCases.map { ($0, $0.title) }, selection: $settings.valueApproval)
			}
			VaultSettingsRow(.rehideValues, detail: "Masks values you revealed once they’ve been shown this long.") {
				VaultSettingsMenu(.rehideValues, options: VaultRehideInterval.allCases.map { ($0, $0.title) }, selection: $settings.rehide)
			}
			VaultHairline()
			VaultSettingsFact(.sensitiveActions)
		}
	}
}

/// How long a copied value stays on the clipboard, and where it can go.
struct VaultClipboardSettingsSection: View {
	@Bindable var settings: VaultSettings

	var body: some View {
		VaultSettingsRows {
			VaultSettingsRow(.clipboardClear,
				detail: "Clears a copied value from the clipboard after this long, unless you’ve copied something else since.") {
				VaultSettingsMenu(.clipboardClear, options: VaultClipboardClear.allCases.map { ($0, $0.title) }, selection: $settings.clipboardClear)
			}
			VaultHairline()
			VaultSettingsFact(.clipboardStaysLocal)
		}
	}
}

/// Whether LPM Vault's windows can be captured.
struct VaultCaptureSettingsSection: View {
	@Bindable var settings: VaultSettings

	var body: some View {
		VaultSettingsRows {
			VaultSettingsRow(.hideFromCapture,
				detail: "LPM Vault’s windows show up blank in screenshots, recordings and shared screens. Turn this off to capture them.") {
				VaultSettingsSwitch(.hideFromCapture, isOn: $settings.hidesFromCapture)
			}
		}
	}
}

// MARK: - General

/// Whether new projects keep local history, and how much this Mac keeps.
struct VaultHistoryDefaultsSettingsSection: View {
	@Bindable var store: VaultStore
	@State private var usage: VaultHistoryUsage?
	@State private var usageRead = false

	var body: some View {
		@Bindable var settings = store.settings
		VaultSettingsRows {
			VaultSettingsRow(.newProjectHistory,
				detail: "New and imported projects keep an encrypted record of value changes on this Mac. Each project’s own setting is in its Project Settings.") {
				VaultSettingsSwitch(.newProjectHistory, isOn: $settings.newProjectsKeepHistory)
			}
			if usageRead {
				VaultHairline()
				Text(Self.usageText(usage))
					.font(.system(size: 11.5))
					.foregroundStyle(VaultPalette.textSecondary)
					.fixedSize(horizontal: false, vertical: true)
				if let crowded = store.history.crowded {
					Text(VaultHistoryText(now: Date()).crowded(crowded))
						.font(.system(size: 11.5))
						.foregroundStyle(VaultPalette.orangeTintText)
						.fixedSize(horizontal: false, vertical: true)
				}
			}
		}
		.task(id: store.isUnlocked) {
			usage = await store.historyUsage()
			usageRead = true
		}
	}

	/// "On this Mac, 3 projects keep history, in 41 Keychain records."
	static func usageText(_ usage: VaultHistoryUsage?) -> String {
		guard let usage else { return "How much history this Mac keeps can’t be read right now." }
		guard usage.projects > 0 else { return "No project keeps history on this Mac yet." }
		let projects = usage.projects == 1 ? "1 project keeps" : "\(usage.projects.formatted()) projects keep"
		return "On this Mac, \(projects) history, in \(usage.records.counted("Keychain record"))."
	}
}

// MARK: - CLI

/// The LPM CLI the person's shell runs, and its version, as the store last
/// found it this session.
struct VaultCLIStatusSettingsSection: View {
	let store: VaultStore

	private var status: LPMCLIStatus? { store.cliStatus }
	private var checking: Bool { store.isLocatingCLI }

	static let installURL = URL(string: "https://cli.lpm.dev/")!

	var body: some View {
		VaultSettingsRows {
			VaultSettingsRow(.cliStatus, titleText: title, detail: detail) {
				HStack(spacing: 8) {
					if checking { ProgressView().controlSize(.small) }
					if status == .notFound {
						VaultBarButton(systemImage: "globe", title: "Install…", height: 28) { NSWorkspace.shared.open(Self.installURL) }
					}
					VaultBarButton(title: "Check Again", disabled: checking, height: 28) { store.refreshCLIStatus() }
				}
			}
		}
		.task { if status == nil { store.refreshCLIStatus() } }
	}

	private var title: Text {
		let text: String = switch status {
		case .found(_, let version?): "lpm \(version)"
		case .found: "lpm"
		case .notFound: "Not found"
		case .unavailable: "Can’t tell"
		case nil: "Looking for the LPM CLI…"
		}
		return Text(text).font(.system(size: 13, weight: .semibold))
	}

	private var detail: String {
		switch status {
		case .found(let path, let version):
			let place = (path as NSString).abbreviatingWithTildeInPath
			return version == nil ? "At \(place), as your shell finds it. Its version can’t be read." : "At \(place), as your shell finds it."
		case .notFound: return "Your shell doesn’t find an lpm command. Install the LPM CLI, then check again."
		case .unavailable: return "Your shell didn’t answer in time. Check again once it’s set up."
		case nil: return "Asking your shell, as Terminal would."
		}
	}
}

/// Whether new projects ask before the CLI reads their values.
struct VaultCLIApprovalSettingsSection: View {
	@Bindable var settings: VaultSettings

	var body: some View {
		VaultSettingsRows {
			VaultSettingsRow(.cliApproval,
				detail: "New and imported projects ask for Touch ID or your Mac password each time the LPM CLI reads their values. Each project’s own setting is in its Project Settings.") {
				VaultSettingsSwitch(.cliApproval, isOn: $settings.newProjectsAskBeforeCLIReads)
			}
		}
	}
}

// MARK: - Backup

/// Whether LPM Vault reminds the person to back up.
struct VaultBackupReminderSettingsSection: View {
	@Bindable var settings: VaultSettings

	var body: some View {
		VaultSettingsRows {
			VaultSettingsRow(.backupReminder, detail: "The sidebar reminds you a month after your last backup.") {
				VaultSettingsSwitch(.backupReminder, isOn: $settings.remindsToBackUp)
			}
		}
	}
}

// MARK: - About

/// Where LPM Vault's notes, documentation and feedback live.
enum VaultAboutLinks {
	static let releaseNotes = URL(string: "https://github.com/lpm-dev/lpm-vault/releases")!
	static let documentation = URL(string: "https://cli.lpm.dev/docs/dev/lpm-vault")!

	/// A new GitHub issue that says which LPM Vault and macOS it's about, and nothing else.
	/// `system` is as `operatingSystemVersionString` gives it: "Version 15.4.1 (Build 24E263)".
	static func feedback(build: VaultBuildInfo, system: String = ProcessInfo.processInfo.operatingSystemVersionString) -> URL {
		let version = system.hasPrefix("Version ") ? system.dropFirst("Version ".count) : Substring(system)
		let body = "What happened, and what did you expect?\n\n\n---\nLPM Vault \(build.displayVersion)\nmacOS \(version)\n"
		var components = URLComponents(string: "https://github.com/lpm-dev/lpm-vault/issues/new")!
		components.queryItems = [URLQueryItem(name: "body", value: body)]
		return components.url!
	}
}

/// The app, its version, and where to read and write about it.
struct VaultAboutSettingsSection: View {
	var build = VaultBuildInfo()

	var body: some View {
		VaultSettingsRows {
			HStack(spacing: 14) {
				VaultAppMark(size: 44)
				VStack(alignment: .leading, spacing: 3) {
					Text("LPM Vault")
						.font(.system(size: 15, weight: .semibold))
						.foregroundStyle(VaultPalette.textPrimary)
					Text(build.displayVersion)
						.font(VaultTypography.tabular(11.5))
						.foregroundStyle(VaultPalette.textTertiary)
						.textSelection(.enabled)
					Text("Values are encrypted in the macOS Keychain.")
						.font(.system(size: 11.5))
						.foregroundStyle(VaultPalette.textTertiary)
				}
			}
			.accessibilityElement(children: .combine)
		}
	}
}

/// Release notes, documentation, feedback and acknowledgements.
struct VaultAboutLinksSection: View {
	var build = VaultBuildInfo()
	var open: @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) }
	var showAcknowledgements: @MainActor () -> Void = { NSApp.orderFrontStandardAboutPanel(nil) }

	var body: some View {
		VaultSettingsRows {
			VaultSettingsRow(.releaseNotes, detail: "What changed in each version.") {
				VaultBarButton(title: "Open", height: 28) { open(VaultAboutLinks.releaseNotes) }
					.accessibilityLabel("Open release notes")
			}
			VaultSettingsRow(.documentation, detail: "Using LPM Vault with the LPM CLI.") {
				VaultBarButton(title: "Open", height: 28) { open(VaultAboutLinks.documentation) }
					.accessibilityLabel("Open documentation")
			}
			VaultSettingsRow(.feedback,
				detail: "Opens a GitHub issue that says which LPM Vault and macOS you use, never your values.") {
				VaultBarButton(title: "Write…", height: 28) { open(VaultAboutLinks.feedback(build: build)) }
					.accessibilityHint("Opens a new GitHub issue for your feedback")
			}
			VaultSettingsRow(.acknowledgements, detail: "The open-source software LPM Vault includes, and its licenses.") {
				VaultBarButton(title: "Show", height: 28) { showAcknowledgements() }
					.accessibilityLabel("Show acknowledgements")
			}
		}
	}
}
