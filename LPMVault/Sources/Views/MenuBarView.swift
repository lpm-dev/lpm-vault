import SwiftUI

struct MenuBarView: View {
	@Bindable var store: VaultStore
	@Environment(\.openWindow) private var openWindow

	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			// Expiring tokens warning
			if !store.expiringTokens.isEmpty {
				Button {
					store.selectedSidebarItem = .personalTokens
					showMainWindow()
				} label: {
					Label(
						"\(store.expiringTokens.count) token\(store.expiringTokens.count == 1 ? "" : "s") expiring soon",
						systemImage: "exclamationmark.triangle.fill"
					)
				}

				Divider()
			}

			// Projects
			if store.projects.isEmpty {
				Text("No vaults yet")
					.foregroundStyle(.secondary)
					.padding(.horizontal, 12)
					.padding(.vertical, 8)
			} else {
				ForEach(store.projects.prefix(5)) { project in
					Button {
						store.selectedSidebarItem = .project(project.id)
						store.selectedProjectId = project.id
						showMainWindow()
					} label: {
						HStack {
							Text(project.name)
							Spacer()
							Text("\(project.secretCount)")
								.foregroundStyle(.secondary)
								.font(.caption)
						}
					}
				}

				if store.projects.count > 5 {
					Divider()
					Text("\(store.projects.count - 5) more...")
						.font(.caption)
						.foregroundStyle(.secondary)
						.padding(.horizontal, 12)
						.padding(.vertical, 4)
				}
			}

			Divider()

			// Auth status
			if let user = store.currentUser {
				Button {
					store.selectedSidebarItem = .authStatus
					showMainWindow()
				} label: {
					HStack {
						Text("@\(user.username)")
						if let email = user.email {
							Text("·")
								.foregroundStyle(.tertiary)
							Text(email)
								.foregroundStyle(.secondary)
						}
					}
				}
				Divider()
			}

			Button {
				showMainWindow()
			} label: {
				HStack {
					Image(systemName: "macwindow")
					Text("Open Vault")
				}
			}

			Divider()

			Button("Quit LPM Vault") {
				NSApplication.shared.terminate(nil)
			}
			.keyboardShortcut("q", modifiers: .command)
		}
	}

	private func showMainWindow() {
		// Regular app — just open window and activate. No policy dance needed.
		openWindow(id: "main")
		NSApplication.shared.activate(ignoringOtherApps: true)
	}
}
