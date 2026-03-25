import SwiftUI

struct MenuBarView: View {
	@Bindable var store: VaultStore
	@Environment(\.openWindow) private var openWindow

	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			if store.projects.isEmpty {
				Text("No vaults yet")
					.foregroundStyle(.secondary)
					.padding(.horizontal, 12)
					.padding(.vertical, 8)
			} else {
				ForEach(store.projects.prefix(5)) { project in
					Button {
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
		// Menu bar apps (LSUIElement / MenuBarExtra-only) don't own the active
		// application state, so the window opens behind whatever is focused.
		// orderFrontRegardless() is the only reliable way to bring an accessory
		// app's window above all other windows.
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
			NSApplication.shared.activate(ignoringOtherApps: true)
			for window in NSApplication.shared.windows where window.title == "LPM Vault" {
				window.orderFrontRegardless()
			}
		}
	}
}
