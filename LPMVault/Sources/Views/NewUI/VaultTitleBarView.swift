import SwiftUI

struct VaultTitleBarView: View {
	@Bindable var store: VaultStore
	@Environment(UpdateChecker.self) private var updateChecker
	let mode: VaultWorkspaceMode
	var sidebarVisible = true
	var onToggleSidebar: () -> Void = {}
	let onConnectCLI: () -> Void
	let onPull: () -> Void
	let onPush: () -> Void
	var isConnectSheetPresented = false
	/// Opens the Publish sheet, on a saved destination's review or for a new one.
	var onPublish: (PublishDestination?) -> Void = { _ in }
	/// Whether the menu of saved destinations shows under Publish….
	var showsPublishMenu: Binding<Bool> = .constant(false)

	private var project: VaultProject? { store.selectedProject }

	@State private var showsSyncMenu = false
	@State private var syncHovering = false

	private enum SyncChoice: Hashable { case pull, push, signIn }

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
		HStack(spacing: 6) {
			VaultTrafficLights()
			VaultBarButton(systemImage: "sidebar.left", borderless: true, active: false, action: onToggleSidebar)
				.keyboardShortcut("s", modifiers: [.control, .command])
				.help(sidebarVisible ? "Hide Sidebar (⌃⌘S)" : "Show Sidebar (⌃⌘S)")
				.accessibilityLabel(sidebarVisible ? "Hide sidebar" : "Show sidebar")
				.padding(.leading, 10)
			breadcrumb.padding(.leading, 6)

			Spacer(minLength: 8)

			// Where the vault's state comes from, and reloading it, before the line;
			// what to do with the project after it.
			VaultBarButton(
				systemImage: "arrow.clockwise",
				borderless: true,
				disabled: store.isRefreshingLocalState || store.isChangingCliAccess
			) { Task { await store.refreshLocalState() } }
			.help("Reload local changes from the LPM CLI")
			.accessibilityLabel("Refresh")
			.accessibilityIdentifier("vault-refresh-local-state")

			syncMenu

			Rectangle()
				.fill(VaultPalette.divider)
				.frame(width: 1, height: 16)
				.padding(.horizontal, 4)
				.accessibilityHidden(true)

			if let project {
				VaultBarButton(systemImage: "link", title: "Connect CLI", borderless: true, active: isConnectSheetPresented, action: onConnectCLI)
					.help("Connect \(project.name) to the LPM CLI")
			}

			if let version = updateChecker.availableUpdateVersion {
				VaultBarButton(
					systemImage: "arrow.down.circle",
					title: "Update available",
					borderless: true,
					disabled: !updateChecker.canCheckForUpdates
				) {
					updateChecker.checkForUpdates()
				}
				.help("LPM Vault \(version) is available. Show update details.")
				.accessibilityIdentifier("vault-update-available")
				.accessibilityLabel("Update available: LPM Vault \(version)")
			}

			publishControl
				.padding(.horizontal, 2)

			// The shortcut is in the tooltip and the menu; the bar keeps to words.
			VaultBarButton(
				systemImage: "lock",
				title: lockTitle,
				borderless: true
			) {
				store.lock()
			}
			.help("Lock LPM Vault (⌘L)")
			.accessibilityLabel(lockAccessibilityLabel)
		}
		.padding(.leading, 14)
		.padding(.trailing, 10)
		.frame(height: VaultMetrics.titleBar)
		.background {
			VaultPalette.titleBar
			VaultWindowDragArea()
		}
	}

	private var breadcrumb: some View {
		HStack(spacing: 7) {
			VaultAppMark(size: 18)
			Text("LPM Vault")
				.font(.system(size: 13, weight: .semibold))
				.foregroundStyle(VaultPalette.textPrimary)
				.fixedSize()

			if let page = accountPageName {
				Text("— \(page)")
					.font(.system(size: 13))
					.foregroundStyle(VaultPalette.textTertiary)
					.lineLimit(1)
			} else if let project {
				Text("— \(project.name)")
					.font(.system(size: 13))
					.foregroundStyle(VaultPalette.textTertiary)
					.lineLimit(1)

				if case .environment(let environment) = mode {
					Text("/")
						.font(.system(size: 13))
						.foregroundStyle(VaultPalette.textFaint)
					Text(VaultProject.displayName(for: environment))
						.font(.system(size: 13))
						.foregroundStyle(VaultPalette.textTertiary)
						.lineLimit(1)
				}
			}
		}
		.fixedSize(horizontal: false, vertical: true)
	}

	/// The vault's sync state, which opens what can be done about it. Pull and
	/// Push keep their shortcuts in the Env Project menu.
	private var syncMenu: some View {
		Button { showsSyncMenu.toggle() } label: {
			HStack(spacing: 6) {
				if store.isSyncing {
					ProgressView().controlSize(.mini)
				} else {
					VaultStatusDot(color: syncColor)
				}
				Text(syncLabel).font(.system(size: 12.5, weight: .medium))
				Image(systemName: "chevron.down")
					.font(.system(size: 8, weight: .bold))
					.foregroundStyle(VaultPalette.textTertiary)
			}
			.foregroundStyle(VaultPalette.textSecondary)
			.padding(.horizontal, 8)
			.frame(height: 28)
			.background(RoundedRectangle(cornerRadius: 7).fill(syncHovering || showsSyncMenu ? VaultPalette.controlHover : .clear))
			.contentShape(Rectangle())
			.vaultHoverAnimation(syncHovering)
		}
		.buttonStyle(VaultPressStyle())
		.disabled(store.isSyncing || (store.isLoggedIn && project == nil))
		.onHover { syncHovering = $0 }
		.accessibilityLabel("Sync status: \(syncLabel)")
		.accessibilityHint("Shows how to sync this project")
		.vaultPopover(isPresented: $showsSyncMenu, arrowEdge: .bottom) {
			VaultMenuList(rows: syncRows, width: 220, label: "Sync") { choice in
				showsSyncMenu = false
				switch choice {
				case .pull: onPull()
				case .push: onPush()
				case .signIn: store.showSettings()
				}
			}
		}
	}

	private var syncRows: [VaultMenuList<SyncChoice>.Row] {
		guard store.isLoggedIn else {
			return [.init(id: .signIn, title: "Sign In to Sync…", detail: "Settings")]
		}
		return [
			.init(id: .pull, title: "Pull…", detail: "⇧⌘L", detailIsShortcut: true),
			.init(id: .push, title: isOrganization ? "Share…" : "Push…", detail: "⇧⌘P", detailIsShortcut: true),
		]
	}

	@ViewBuilder
	private var publishControl: some View {
		if let project, !store.isShowingAccountPage {
			let hasSaved = !(store.publishDestinations[project.id] ?? []).isEmpty
			VaultBarButton(systemImage: "arrow.up.to.line", title: "Publish…", borderless: true, active: showsPublishMenu.wrappedValue) {
				if hasSaved {
					showsPublishMenu.wrappedValue.toggle()
				} else {
					onPublish(nil)
				}
			}
			.anchorPreference(key: VaultPublishButtonAnchor.self, value: .bounds) { $0 }
			.help(hasSaved ? "Publish to a saved destination or a new one" : "Publish an environment to a platform")
			.task(id: project.id) { await store.loadPublishDestinations(for: project.id) }
		}
	}

	/// The app-level page the window shows, which the title names instead of the project.
	private var accountPageName: String? {
		switch store.accountPage {
		case .settings?: "Settings"
		case .platforms?: "Platforms"
		case nil: nil
		}
	}

	private var isOrganization: Bool {
		if case .org = store.selectedAccount { return true }
		return false
	}
}
