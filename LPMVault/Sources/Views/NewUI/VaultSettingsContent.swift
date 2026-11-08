import SwiftUI

/// One part of Settings, as the Settings overlay shows it: the app's own
/// settings, the account and server, where the CLI keeps its state, backups,
/// updates, or the platforms values are published to. It's in the window,
/// behind the lock, so ⌘, unlocks first.
struct VaultSettingsContent: View {
	@Bindable var store: VaultStore
	let category: VaultSettingsCategory
	@Environment(\.vaultContentObscured) private var isObscured
	@State private var showLogoutConfirmation = false
	@State private var showBackupExport = false
	@State private var showBackupRestore = false

	var body: some View {
		Group {
			if category == .platforms {
				PlatformsView(store: store, showsHeader: false)
			} else {
				ScrollView {
					VStack(alignment: .leading, spacing: 22) {
						sections
					}
					.frame(maxWidth: VaultMetrics.formWidth, alignment: .leading)
					.padding(.horizontal, 28)
					.padding(.vertical, 24)
					.frame(maxWidth: .infinity, alignment: .leading)
				}
			}
		}
		.background(VaultPalette.content)
		.vaultConfirmation(isPresented: $showLogoutConfirmation) { .signOut(store) }
		.sheet(isPresented: $showBackupExport) { BackupExportSheet(store: store).vaultPrivacyProtected(isObscured) }
		.sheet(isPresented: $showBackupRestore) { VaultBackupRestorePresentation(store: store).vaultPrivacyProtected(isObscured) }
		.onChange(of: isObscured) { _, obscured in
			if obscured { showLogoutConfirmation = false }
		}
		.onChange(of: store.isUnlocked) { _, unlocked in
			if !unlocked {
				showBackupExport = false
				showBackupRestore = false
			}
		}
	}

	/// The category's sections, each under its label, except a page's opening
	/// card about what the overlay's header already names.
	@ViewBuilder
	private var sections: some View {
		switch category {
		case .general:
			settingsSection { VaultGeneralSettingsSection() }
			settingsSection("LOCAL HISTORY") { VaultHistoryDefaultsSettingsSection(store: store) }
		case .security:
			settingsSection("LOCKING") { VaultLockingSettingsSection(settings: store.settings) }
			settingsSection("VALUES") { VaultValueSettingsSection(settings: store.settings) }
			settingsSection("CLIPBOARD") { VaultClipboardSettingsSection(settings: store.settings) }
			settingsSection("SCREEN") { VaultCaptureSettingsSection(settings: store.settings) }
		case .appearance: settingsSection { VaultAppearanceSettingsSection() }
		case .account: accountSections
		case .cli:
			settingsSection("LPM CLI") { VaultCLIStatusSettingsSection(locate: store.locateCLI) }
			settingsSection("APPROVAL") { VaultCLIApprovalSettingsSection(settings: store.settings) }
			settingsSection("LPM HOME") { VaultLPMHomeSettingsSection(store: store) }
		case .backup:
			settingsSection {
				VaultBackupSettingsSection(store: store, exportBackup: { showBackupExport = true }, restoreBackup: { showBackupRestore = true })
			}
			settingsSection("REMINDER") { VaultBackupReminderSettingsSection(settings: store.settings) }
		case .updates: settingsSection { VaultUpdateSettingsSection() }
		case .about:
			settingsSection { VaultAboutSettingsSection() }
			settingsSection("LINKS") { VaultAboutLinksSection() }
		case .platforms: EmptyView()
		}
	}

	@ViewBuilder
	private var accountSections: some View {
		if let user = store.currentUser {
			settingsSection("ACCOUNT") {
				HStack(spacing: 12) {
					profileAvatar(user)
					VStack(alignment: .leading, spacing: 2) {
						Text("@\(user.username)")
							.font(.system(size: 14, weight: .semibold))
							.foregroundStyle(VaultPalette.textPrimary)
						if let email = user.email {
							Text(email).font(.system(size: 11.5)).foregroundStyle(VaultPalette.textTertiary)
						}
					}
					Spacer()
					if let plan = user.plan {
						VaultTagBadge(text: plan.uppercased(), foreground: VaultPalette.accentForeground, background: VaultPalette.accentTint)
					}
					// The account's own actions, on its row rather than a card of their own.
					VaultBarButton(systemImage: "globe", title: "Manage on lpm.dev") {
						if let url = store.accountManagementURL { NSWorkspace.shared.open(url) }
					}
					VaultBarButton(title: "Sign Out…") {
						showLogoutConfirmation = true
					}
				}
			}
			serverSettings
		} else {
			settingsSection("ACCOUNT") {
				VStack(alignment: .leading, spacing: 12) {
					HStack(spacing: 12) {
						VaultCardIcon(systemImage: "person")
						VStack(alignment: .leading, spacing: 2) {
							Text("Not logged in")
								.font(.system(size: 13.5, weight: .semibold))
								.foregroundStyle(VaultPalette.textPrimary)
							Text("Sign in to sync personal and organization env projects.")
								.font(.system(size: 12))
								.foregroundStyle(VaultPalette.textTertiary)
						}
					}
					HStack(spacing: 10) {
						VaultBarButton(systemImage: "globe", title: store.isLoggingIn ? "Waiting for Browser…" : "Sign In with Browser", filled: true, disabled: store.isLoggingIn) {
							Task { await store.login() }
						}
						if store.isLoggingIn {
							ProgressView().controlSize(.small)
						}
					}
					if let error = store.error {
						Text(error)
							.font(.system(size: 11.5)).foregroundStyle(VaultPalette.redText)
							.fixedSize(horizontal: false, vertical: true)
					}
				}
			}
			serverSettings
		}
	}

	private var serverSettings: some View {
		// The registry the account signs in to and syncs with, not a project's environment.
		settingsSection("REGISTRY SERVER") {
			HStack(spacing: 12) {
				VStack(alignment: .leading, spacing: 2) {
					Text(store.appEnvironment == .production ? "lpm.dev" : "Local development")
						.font(.system(size: 13, weight: .semibold))
						.foregroundStyle(VaultPalette.textPrimary)
					Text(store.appEnvironment == .production ? "Used for account access and cloud sync" : "localhost:3000, for account access and cloud sync")
						.font(.system(size: 11.5))
						.foregroundStyle(VaultPalette.textTertiary)
				}
				Spacer()
				#if DEBUG
				VaultBarButton(
					title: store.appEnvironment == .production ? "Use Local" : "Use lpm.dev"
				) {
					store.switchEnvironment(to: store.appEnvironment == .production ? .development : .production)
				}
				#endif
			}
		}
	}

	private func settingsSection<Content: View>(
		_ title: String? = nil,
		@ViewBuilder content: () -> Content
	) -> some View {
		VStack(alignment: .leading, spacing: 8) {
			if let title { Text(title).vaultSectionLabel() }
			content()
				.padding(.horizontal, 16)
				.padding(.vertical, 14)
				.frame(maxWidth: .infinity, alignment: .leading)
				.background(RoundedRectangle(cornerRadius: 10).fill(VaultPalette.card))
				.overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(VaultPalette.border, lineWidth: 1) }
		}
	}

	@ViewBuilder
	private func profileAvatar(_ user: LPMUser) -> some View {
		if AvatarURLPolicy.validatedURL(user.avatarUrl) != nil {
			SecureAvatarImage(urlString: user.avatarUrl) {
				VaultInitialsAvatar(
					initials: String(user.username.prefix(1)).uppercased(), size: 42)
			}
			.frame(width: 42, height: 42)
			.clipShape(Circle())
		} else {
			VaultInitialsAvatar(initials: String(user.username.prefix(1)).uppercased(), size: 42)
		}
	}
}

extension VaultConfirmation {
	/// Signing out, asked the same way wherever it's offered.
	@MainActor
	static func signOut(_ store: VaultStore) -> VaultConfirmation {
		VaultConfirmation(
			symbol: "rectangle.portrait.and.arrow.right",
			title: "Sign out of LPM?",
			message: "Your local env data stays in Keychain. You can sign in again anytime.",
			subject: store.currentUser.map { user in
				.init(mark: .initials(String(user.username.prefix(1)).uppercased()), name: "@\(user.username)", detail: user.email)
			},
			actions: [.init(title: "Sign Out") { Task { await store.logout() } }])
	}
}
