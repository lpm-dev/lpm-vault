import SwiftUI

@main
struct LPMVaultApp: App {
	@State private var store = VaultStore()

	init() {
		// Force regular app mode — shows in dock + Cmd+Tab
		NSApplication.shared.setActivationPolicy(.regular)

		// Set dock icon from bundled .icns
		if let iconURL = Bundle.module.url(forResource: "LPMVault", withExtension: "icns"),
			let icon = NSImage(contentsOf: iconURL)
		{
			NSApplication.shared.applicationIconImage = icon
		}
	}

	var body: some Scene {
		// Menu bar quick access (always visible)
		MenuBarExtra {
			MenuBarView(store: store)
		} label: {
			let hasExpiring = !store.expiringTokens.isEmpty
			Image(systemName: store.isUnlocked ? "lock.open.fill" : "lock.fill")
				.symbolRenderingMode(hasExpiring ? .multicolor : .monochrome)
			if hasExpiring {
				Text("\(store.expiringTokens.count)")
			}
		}

		// Main window
		Window("", id: "main") {
			ContentView(store: store)
				.onAppear {
					store.loadProjects()
					Task { await store.loadTokens() }
				}
		}
		.defaultSize(width: 900, height: 550)
		.windowStyle(.hiddenTitleBar)
		.commands {
			CommandGroup(replacing: .newItem) {}
		}
	}
}
