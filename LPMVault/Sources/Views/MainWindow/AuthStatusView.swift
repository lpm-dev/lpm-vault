import SwiftUI

struct AuthStatusView: View {
	@Bindable var store: VaultStore
	@Environment(\.vaultContentObscured) private var isObscured
	@State private var showLogoutConfirmation = false

	var body: some View {
		VStack(spacing: 0) {
			HStack {
				Text("Settings")
					.font(.system(size: 19, weight: .bold))
					.foregroundStyle(VaultPalette.textPrimary)
				Spacer()
			}
			.padding(.horizontal, 20)
			.frame(height: 58)

			VaultHairline()

			if let user = store.currentUser {
				ScrollView {
					VStack(alignment: .leading, spacing: 18) {
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
									VaultTagBadge(text: plan.uppercased(), foreground: VaultPalette.accent, background: VaultPalette.accentTint)
								}
							}
						}

						settingsSection("SERVER") {
							HStack(spacing: 10) {
								Image(systemName: store.appEnvironment == .production ? "globe" : "laptopcomputer")
									.foregroundStyle(VaultPalette.accent)
								VStack(alignment: .leading, spacing: 2) {
									Text(store.appEnvironment == .production ? "Production" : "Local development")
										.font(.system(size: 13, weight: .semibold))
									Text(store.appEnvironment == .production ? "lpm.dev" : "localhost:3000")
										.font(VaultTypography.mono(11))
										.foregroundStyle(VaultPalette.textTertiary)
								}
								Spacer()
								#if DEBUG
								VaultBarButton(
									title: store.appEnvironment == .production ? "Use local" : "Use production"
								) {
									store.switchEnvironment(to: store.appEnvironment == .production ? .development : .production)
								}
								#endif
							}
						}

						settingsSection("ACTIONS") {
							HStack(spacing: 8) {
								VaultBarButton(systemImage: "globe", title: "Manage on lpm.dev") {
									if let url = URL(string: "/dashboard/settings", relativeTo: store.appEnvironment.baseURL)?.absoluteURL {
										NSWorkspace.shared.open(url)
									}
								}
								VaultBarButton(systemImage: "rectangle.portrait.and.arrow.right", title: "Sign out") {
									showLogoutConfirmation = true
								}
							}
						}
					}
					.padding(20)
				}
			} else {
				VStack(spacing: 16) {
					VaultAppMark(size: 42)

					Text("Not logged in")
						.font(.system(size: 18, weight: .bold))
						.foregroundStyle(VaultPalette.textPrimary)
					Text("Sign in to sync personal and organization env projects.")
						.font(.system(size: 12.5))
						.foregroundStyle(VaultPalette.textTertiary)

					VaultBarButton(systemImage: "globe", title: store.isLoggingIn ? "Waiting for browser…" : "Sign in with browser", filled: true, disabled: store.isLoggingIn) {
						Task { await store.login() }
					}

					if store.isLoggingIn {
						ProgressView().controlSize(.small)
					}

					if let error = store.error {
						Text(error)
							.font(.system(size: 11.5)).foregroundStyle(VaultPalette.redText)
							.multilineTextAlignment(.center)
							.frame(maxWidth: 320)
					}
				}
				.frame(maxWidth: .infinity, maxHeight: .infinity)
			}
		}
		.background(VaultPalette.content)
		.confirmationDialog("Sign out?", isPresented: $showLogoutConfirmation, titleVisibility: .visible) {
			Button("Sign Out", role: .destructive) {
				Task { await store.logout() }
			}
			Button("Cancel", role: .cancel) {}
		} message: {
			Text("Your local env data stays in Keychain. You can sign in again anytime.")
		}
		.onChange(of: isObscured) { _, obscured in
			if obscured { showLogoutConfirmation = false }
		}
	}

	private func settingsSection<Content: View>(
		_ title: String,
		@ViewBuilder content: () -> Content
	) -> some View {
		VStack(alignment: .leading, spacing: 8) {
			Text(title).vaultSectionLabel()
			content()
				.padding(14)
				.frame(maxWidth: .infinity, alignment: .leading)
				.background(RoundedRectangle(cornerRadius: 10).fill(VaultPalette.sidebar))
				.overlay { RoundedRectangle(cornerRadius: 10).stroke(VaultPalette.border, lineWidth: 1) }
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
