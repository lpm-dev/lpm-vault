import SwiftUI

struct VaultTitleBarView: View {
	@Bindable var store: VaultStore
	@Environment(UpdateChecker.self) private var updateChecker
	let mode: VaultWorkspaceMode
	let onShowVaultID: () -> Void
	let onPull: () -> Void
	let onPush: () -> Void

	private var project: VaultProject? { store.selectedProject }

	private var syncLabel: String {
		if store.isSyncing { return "Syncing" }
		guard let project else { return store.isLoggedIn ? "Select project" : "Local" }
		switch store.syncStatus(for: project.id) {
		case .synced: return "Synced"
		case .localChanges: return "Local changes"
		case .neverSynced: return store.isLoggedIn ? "Not synced" : "Local"
		}
	}

	private var syncColor: Color {
		guard let project else { return VaultPalette.textFaint }
		switch store.syncStatus(for: project.id) {
		case .synced: return VaultPalette.green
		case .localChanges: return VaultPalette.orange
		case .neverSynced: return VaultPalette.textFaint
		}
	}

	private var lockTitle: String {
		guard let seconds = store.autoLockCountdownSeconds else { return "Lock" }
		return "Lock \(seconds)s"
	}

	private var lockAccessibilityLabel: String {
		guard let seconds = store.autoLockCountdownSeconds else { return "Lock LPM Vault" }
		return "Lock LPM Vault, auto-lock in \(seconds) \(seconds == 1 ? "second" : "seconds")"
	}

	var body: some View {
		HStack(spacing: 10) {
			VaultTrafficLights()
			breadcrumb.padding(.leading, 8)

			if let project {
				Button(action: onShowVaultID) {
					HStack(spacing: 6) {
						Image(systemName: "link")
							.font(.system(size: 9, weight: .bold))
							.foregroundStyle(VaultPalette.accentForeground)
						Text("vault \(shortVaultID(project.id))")
							.font(VaultTypography.mono(10.5))
							.foregroundStyle(VaultPalette.vaultChipText)
					}
					.padding(.horizontal, 8)
					.frame(height: 22)
					.background(RoundedRectangle(cornerRadius: 6).fill(VaultPalette.vaultChip))
					.overlay { RoundedRectangle(cornerRadius: 6).stroke(VaultPalette.border, lineWidth: 1) }
				}
				.buttonStyle(.plain)
				.help("Show env project configuration")
				.accessibilityLabel("Show env project configuration for \(project.name)")
				.vaultPointingHand()
			}

			Spacer(minLength: 8)

			syncMenu

			if let version = updateChecker.availableUpdateVersion {
				VaultBarButton(
					systemImage: "arrow.down.circle",
					title: "Update available",
					disabled: !updateChecker.canCheckForUpdates
				) {
					updateChecker.checkForUpdates()
				}
				.help("LPM Vault \(version) is available. Show update details.")
				.accessibilityIdentifier("vault-update-available")
				.accessibilityLabel("Update available: LPM Vault \(version)")
			}

			VaultBarButton(
				systemImage: "lock.fill",
				title: lockTitle,
				shortcut: "⌘L",
				invertsOnHover: true
			) {
				store.lock()
			}
			.accessibilityLabel(lockAccessibilityLabel)
		}
		.padding(.horizontal, 14)
		.frame(height: VaultMetrics.titleBar)
		.background {
			VaultPalette.titleBar
			VaultWindowDragArea()
		}
	}

	private var breadcrumb: some View {
		HStack(spacing: 8) {
			VaultAppMark()
			Text("LPM Vault")
				.font(.system(size: 13, weight: .semibold))
				.foregroundStyle(VaultPalette.textPrimary)
				.fixedSize()

			if let project {
				Text("— \(project.name)")
					.font(.system(size: 13))
					.foregroundStyle(VaultPalette.textTertiary)
					.lineLimit(1)

				if case .environment(let environment) = mode {
					Text("/")
						.foregroundStyle(VaultPalette.textTertiary)
					Text(VaultProject.displayName(for: environment))
						.font(VaultTypography.mono(12))
						.foregroundStyle(VaultPalette.textTertiary)
				}
			}
		}
		.fixedSize(horizontal: false, vertical: true)
	}

	private var syncMenu: some View {
		Menu {
			if store.isLoggedIn, project != nil {
				Button("Pull…", action: onPull)
					.keyboardShortcut("l", modifiers: [.command, .shift])
				Button(isOrganization ? "Share…" : "Push…", action: onPush)
					.keyboardShortcut("p", modifiers: [.command, .shift])
			} else if !store.isLoggedIn {
				Button("Sign in to sync…") { store.showSettings() }
			} else {
				Button("Select an env project") {}
					.disabled(true)
			}
		} label: {
			HStack(spacing: 6) {
				if store.isSyncing {
					ProgressView().controlSize(.mini)
				} else {
					VaultStatusDot(color: syncColor)
				}
				Text(syncLabel)
					.font(.system(size: 12))
					.foregroundStyle(VaultPalette.textSecondary)
				Image(systemName: "chevron.down")
					.font(.system(size: 8, weight: .bold))
					.foregroundStyle(VaultPalette.textQuaternary)
			}
			.foregroundStyle(VaultPalette.textSecondary)
			.padding(.horizontal, 10)
			.frame(height: 26)
			.background(RoundedRectangle(cornerRadius: 7).fill(VaultPalette.control))
			.overlay { RoundedRectangle(cornerRadius: 7).stroke(VaultPalette.border, lineWidth: 1) }
		}
		.menuStyle(.borderlessButton)
		.menuIndicator(.hidden)
		.fixedSize()
		.disabled(store.isSyncing || (store.isLoggedIn && project == nil))
		.accessibilityLabel("Sync status: \(syncLabel)")
	}

	private var isOrganization: Bool {
		if case .org = store.selectedAccount { return true }
		return false
	}

	private func shortVaultID(_ id: String) -> String {
		guard id.count > 16 else { return id }
		return "\(id.prefix(8))…\(id.suffix(6))"
	}
}
