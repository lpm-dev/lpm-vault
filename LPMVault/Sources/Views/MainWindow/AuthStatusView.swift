import SwiftUI

struct AuthStatusView: View {
	@Bindable var store: VaultStore
	@State private var showLogoutConfirmation = false

	var body: some View {
		VStack(spacing: 0) {
			HStack {
				Text("Settings")
					.font(.headline)
				Spacer()
			}
			.padding(.horizontal, 12)
			.padding(.vertical, 10)

			Divider()

			if let user = store.currentUser {
				List {
					// Profile
					HStack(spacing: 12) {
						if let avatarUrl = user.avatarUrl, let url = URL(string: avatarUrl) {
							AsyncImage(url: url) { image in
								image.resizable().scaledToFill()
							} placeholder: {
								Circle().fill(.quaternary).overlay {
									Text(String(user.username.prefix(1)).uppercased())
										.font(.title2).fontWeight(.medium).foregroundStyle(.secondary)
								}
							}
							.frame(width: 40, height: 40)
							.clipShape(Circle())
						} else {
							Circle().fill(.quaternary).frame(width: 40, height: 40).overlay {
								Text(String(user.username.prefix(1)).uppercased())
									.font(.title2).fontWeight(.medium).foregroundStyle(.secondary)
							}
						}

						VStack(alignment: .leading, spacing: 2) {
							Text("@\(user.username)")
								.font(.callout)
								.fontWeight(.semibold)
							if let email = user.email {
								Text(email)
									.font(.caption)
									.foregroundStyle(.tertiary)
							}
						}
					}
					.padding(.vertical, 2)

					if let plan = user.plan {
						Section("Plan") {
							Label(plan.capitalized, systemImage: "creditcard")
						}
					}

					// Environment toggle
					Section("Server") {
						HStack {
							Label(
								store.appEnvironment == .production ? "Production (lpm.dev)" : "Development (localhost:3000)",
								systemImage: store.appEnvironment == .production ? "globe" : "laptopcomputer"
							)
							Spacer()
							if store.appEnvironment == .development {
								Text("DEV")
									.font(.system(size: 9, weight: .bold, design: .monospaced))
									.foregroundStyle(.white)
									.padding(.horizontal, 5)
									.padding(.vertical, 2)
									.background(.orange, in: RoundedRectangle(cornerRadius: 4))
							}
						}
						Button(store.appEnvironment == .production ? "Switch to Development" : "Switch to Production") {
							store.switchEnvironment(to: store.appEnvironment == .production ? .development : .production)
						}
					}

					Section {
						Button("Manage Account on lpm.dev") {
							let url = store.appEnvironment == .development
								? "http://localhost:3000/dashboard/settings"
								: "https://lpm.dev/dashboard/settings"
							NSWorkspace.shared.open(URL(string: url)!)
						}

						Button("Sign Out", role: .destructive) {
							showLogoutConfirmation = true
						}
					}
				}
			} else {
				VStack(spacing: 16) {
					Image(systemName: "person.crop.circle.badge.questionmark")
						.font(.system(size: 40))
						.foregroundStyle(.secondary)

					Text("Not logged in")
						.font(.title3)
						.foregroundStyle(.secondary)

					Button {
						Task { await store.login() }
					} label: {
						Label("Sign In with Browser", systemImage: "globe")
					}
					.buttonStyle(.borderedProminent)
					.disabled(store.isLoggingIn)

					if store.isLoggingIn {
						ProgressView().controlSize(.small)
						Text("Waiting for browser...")
							.font(.caption).foregroundStyle(.secondary)
					}

					if let error = store.error {
						Text(error)
							.font(.caption).foregroundStyle(.red)
							.multilineTextAlignment(.center)
							.frame(maxWidth: 240)
					}
				}
				.frame(maxWidth: .infinity, maxHeight: .infinity)
			}
		}
		.confirmationDialog("Sign out?", isPresented: $showLogoutConfirmation, titleVisibility: .visible) {
			Button("Sign Out", role: .destructive) { store.logout() }
			Button("Cancel", role: .cancel) {}
		} message: {
			Text("Your vault data stays in Keychain. You can sign in again anytime.")
		}
	}
}
