import SwiftUI

struct AuthStatusView: View {
	@Bindable var store: VaultStore
	@State private var showLogoutConfirmation = false

	var body: some View {
		VStack(spacing: 0) {
			// Custom header bar (consistent with SecretListView / TokenListView)
			HStack(spacing: 8) {
				Text("Auth Status")
					.font(.title3)
					.fontWeight(.semibold)

				Spacer()

				if store.isLoggedIn {
					ToolbarButtonGroup {
						ToolbarIconButton(icon: "arrow.up.right.square", help: "Manage account on lpm.dev") {
							NSWorkspace.shared.open(URL(string: "https://lpm.dev/dashboard/settings")!)
						}
					}

					ToolbarButtonGroup {
						ToolbarIconButton(icon: "rectangle.portrait.and.arrow.right", help: "Sign out") {
							showLogoutConfirmation = true
						}
					}
				}
			}
			.padding(.horizontal, 16)
			.padding(.vertical, 10)

			Divider()

			if let user = store.currentUser {
				List {
					HStack(spacing: 12) {
						// Avatar
						if let avatarUrl = user.avatarUrl, let url = URL(string: avatarUrl) {
							AsyncImage(url: url) { image in
								image.resizable().scaledToFill()
							} placeholder: {
								Circle()
									.fill(.quaternary)
									.overlay {
										Text(String(user.username.prefix(1)).uppercased())
											.font(.title2)
											.fontWeight(.medium)
											.foregroundStyle(.secondary)
									}
							}
							.frame(width: 48, height: 48)
							.clipShape(Circle())
						} else {
							Circle()
								.fill(.quaternary)
								.frame(width: 48, height: 48)
								.overlay {
									Text(String(user.username.prefix(1)).uppercased())
										.font(.title2)
										.fontWeight(.medium)
										.foregroundStyle(.secondary)
								}
						}

						VStack(alignment: .leading, spacing: 2) {
							Text("@\(user.username)")
								.font(.title3)
								.fontWeight(.semibold)
							if let name = user.name, !name.isEmpty {
								Text(name)
									.foregroundStyle(.secondary)
							}
							if let email = user.email {
								Text(email)
									.font(.caption)
									.foregroundStyle(.tertiary)
							}
						}
					}
					.padding(.vertical, 4)

					if let plan = store.currentUser?.plan {
						Section("Plan") {
							Label(plan.capitalized, systemImage: "creditcard")
						}
					}

					Section("Token Summary") {
						LabeledContent("Personal tokens") {
							Text("\(store.personalTokens.count)")
						}
						LabeledContent("Organizations") {
							Text("\(store.userOrgs.count)")
						}

						if !store.expiringTokens.isEmpty {
							Label(
								"\(store.expiringTokens.count) token\(store.expiringTokens.count == 1 ? "" : "s") expiring soon",
								systemImage: "exclamationmark.triangle.fill"
							)
							.foregroundStyle(.orange)
						}
					}
				}
			} else {
				VStack(spacing: 16) {
					Image(systemName: "person.crop.circle.badge.questionmark")
						.font(.system(size: 48))
						.foregroundStyle(.secondary)

					Text("Not logged in")
						.font(.title2)
						.foregroundStyle(.secondary)

					Text("Sign in to sync secrets with the cloud, manage tokens, and share vaults with your team.")
						.font(.callout)
						.foregroundStyle(.tertiary)
						.multilineTextAlignment(.center)
						.frame(maxWidth: 320)

					Button {
						Task { await store.login() }
					} label: {
						Label("Sign In with Browser", systemImage: "globe")
					}
					.buttonStyle(.borderedProminent)
					.controlSize(.large)
					.disabled(store.isLoggingIn)

					if store.isLoggingIn {
						VStack(spacing: 8) {
							ProgressView()
								.controlSize(.small)
							Text("Waiting for browser login...")
								.font(.caption)
								.foregroundStyle(.secondary)
						}
					}

					if let error = store.error {
						Text(error)
							.font(.caption)
							.foregroundStyle(.red)
							.multilineTextAlignment(.center)
							.frame(maxWidth: 300)
					}

					Text("Or run `lpm login` in your terminal")
						.font(.caption)
						.foregroundStyle(.quaternary)
				}
				.frame(maxWidth: .infinity, maxHeight: .infinity)
			}
		}
		.confirmationDialog(
			"Sign out?",
			isPresented: $showLogoutConfirmation,
			titleVisibility: .visible
		) {
			Button("Sign Out", role: .destructive) {
				store.logout()
			}
			Button("Cancel", role: .cancel) {}
		} message: {
			Text("This will remove your auth token from this device. Your vault data stays in Keychain. You can sign in again anytime.")
		}
	}
}
