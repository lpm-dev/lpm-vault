import SwiftUI

/// Handles dock click and prevents quit on window close.
final class AppDelegate: NSObject, NSApplicationDelegate {
	var openWindow: (() -> Void)?
	var lockVault: (() -> Void)?

	func applicationDidFinishLaunching(_ notification: Notification) {
		// When launched from Xcode (bare executable, no .app bundle),
		// the asset catalog icon isn't available. Set it programmatically.
		if NSApplication.shared.applicationIconImage == nil || Bundle.main.url(forResource: "AppIcon", withExtension: "icns") == nil {
			if let iconURL = Bundle.main.url(forResource: "LPMVault", withExtension: "icns"),
				let icon = NSImage(contentsOf: iconURL)
			{
				NSApplication.shared.applicationIconImage = icon
			}
		}

		// Compact traffic lights
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
			for window in NSApplication.shared.windows {
				window.titlebarAppearsTransparent = true
				window.titleVisibility = .hidden
				window.styleMask.insert(.fullSizeContentView)
				// Use unified compact toolbar for smaller traffic lights
				let toolbar = NSToolbar(identifier: "main")
				toolbar.showsBaselineSeparator = false
				toolbar.displayMode = .iconOnly
				window.toolbar = toolbar
				window.toolbarStyle = .unifiedCompact
				// Move traffic lights closer together
				if let closeButton = window.standardWindowButton(.closeButton) {
					closeButton.superview?.superview?.frame.size.height = 28
				}
			}
		}
	}

	func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
		// Hide on red traffic light close, don't quit — but lock immediately
		lockVault?()
		return false
	}

	func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
		if !flag {
			openWindow?()
		}
		return true
	}
}

@main
struct LPMVaultApp: App {
	@NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
	@Environment(\.openWindow) private var openWindow
	@State private var store = VaultStore()

	var body: some Scene {
		// Main window — opens automatically on launch
		Window("LPM Vault", id: "main") {
			ContentView(store: store)
				.onAppear {
					store.loadProjects()
					Task { await store.loadTokens() }
					appDelegate.openWindow = { [openWindow] in
						openWindow(id: "main")
					}
					appDelegate.lockVault = { [store] in
						store.lock()
					}
				}
		}
		.defaultSize(width: 900, height: 550)
		.windowStyle(.hiddenTitleBar)
		.commands {
			CommandGroup(replacing: .newItem) {}
		}
	}
}
