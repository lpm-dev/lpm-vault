import SwiftUI

struct MenuBarView: View {
	@Bindable var store: VaultStore
	@Environment(\.openWindow) private var openWindow

	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			// Projects
			if store.projects.isEmpty {
				Text("No env projects yet")
					.foregroundStyle(.secondary)
					.padding(.horizontal, 12)
					.padding(.vertical, 8)
			} else {
				ForEach(store.projects.prefix(5)) { project in
					Button {
						store.openProject(id: project.id)
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
					store.showSettings()
					showMainWindow()
				} label: {
					Text("@\(user.username)")
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
		openWindow(id: "main")
		NSApplication.shared.activate(ignoringOtherApps: true)
	}
}
