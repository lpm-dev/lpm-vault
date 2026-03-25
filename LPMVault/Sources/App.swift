import SwiftUI

@main
struct LPMVaultApp: App {
	@State private var store = VaultStore()

	var body: some Scene {
		MenuBarExtra("LPM Vault", systemImage: store.isUnlocked ? "lock.open.fill" : "lock.fill") {
			MenuBarView(store: store)
		}

		Window("LPM Vault", id: "main") {
			ContentView(store: store)
				.frame(minWidth: 700, minHeight: 450)
				.onAppear {
					store.loadProjects()
				}
		}
		.defaultSize(width: 900, height: 550)
	}
}
