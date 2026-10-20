import SwiftUI

struct VaultTitleBarView: View {
	@Bindable var store: VaultStore
	@Environment(UpdateChecker.self) private var updateChecker
	let mode: VaultWorkspaceMode
	let onConnectCLI: () -> Void
	let onPull: () -> Void
	let onPush: () -> Void
	var isConnectSheetPresented = false
	/// Opens the Publish sheet, on a saved destination's review or for a new one.
	var onPublish: (PublishDestination?) -> Void = { _ in }

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

			VaultBarButton(
				systemImage: "arrow.clockwise",
				title: "Refresh",
				disabled: store.isRefreshingLocalState || store.isChangingCliAccess
			) { Task { await store.refreshLocalState() } }
			.help("Reload local changes from the LPM CLI")
			.accessibilityIdentifier("vault-refresh-local-state")

			Spacer(minLength: 8)

			if let project {
				VaultBarButton(systemImage: "link", title: "Connect CLI", active: isConnectSheetPresented, action: onConnectCLI)
					.help("Connect \(project.name) to the LPM CLI")
			}

			syncMenu

			publishControl

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
						.font(VaultTypography.tabular(12))
						.foregroundStyle(VaultPalette.textTertiary)
				}
			}
		}
		.fixedSize(horizontal: false, vertical: true)
	}

	private var syncMenu: some View {
		VaultBarMenu(accessibilityLabel: "Sync status: \(syncLabel)") {
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
			if store.isSyncing {
				ProgressView().controlSize(.mini)
			} else {
				VaultStatusDot(color: syncColor)
			}
			Text(syncLabel).font(.system(size: 12.5))
		}
		.disabled(store.isSyncing || (store.isLoggedIn && project == nil))
	}

	@ViewBuilder
	private var publishControl: some View {
		if let project, !store.isShowingAccountPage {
			let saved = store.publishDestinations[project.id] ?? []
			Group {
				if saved.isEmpty {
					VaultBarButton(systemImage: "arrow.up.to.line", title: "Publish…") { onPublish(nil) }
				} else {
					VaultBarMenu(accessibilityLabel: "Publish") {
						Section("Saved destinations") {
							ForEach(saved) { summary in
								Button { onPublish(summary.destination) } label: {
									Text(Self.title(of: summary.destination))
									Text(Self.subtitle(of: summary))
								}
							}
						}
						Divider()
						Button("New destination…") { onPublish(nil) }
					} label: {
						Image(systemName: "arrow.up.to.line").font(.system(size: 11, weight: .medium))
						Text("Publish").font(.system(size: 12.5))
					}
				}
			}
			.help("Publish an environment to a platform")
			.task(id: project.id) { await store.loadPublishDestinations(for: project.id) }
		}
	}

	static func title(of destination: PublishDestination) -> String {
		let target = destination.target
		return "\(target.placeName) — \(target.platform.displayName) · \(target.accountName)"
	}

	static func subtitle(of summary: PublishDestinationSummary) -> String {
		let source = "from \(VaultProject.displayName(for: summary.destination.sourceEnvironment))"
		let when = summary.lastPublishedAt.map { RelativeTimestampFormatter.string(from: $0) } ?? "not published yet"
		let parts = [summary.destination.target.placeDetail ?? summary.accountDetail, source, when]
		return parts.compactMap { $0 }.joined(separator: " · ")
	}

	private var isOrganization: Bool {
		if case .org = store.selectedAccount { return true }
		return false
	}
}
