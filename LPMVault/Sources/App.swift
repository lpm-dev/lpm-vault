import SwiftUI

private enum TrafficLightStyle {
	static let buttonSize: CGFloat = 6
	static let buttonSpacing: CGFloat = 12
	static let leadingInset: CGFloat = 14
	static let topInset: CGFloat = 11

	static func apply(to window: NSWindow) {
		guard
			let closeButton = window.standardWindowButton(.closeButton),
			let miniaturizeButton = window.standardWindowButton(.miniaturizeButton),
			let zoomButton = window.standardWindowButton(.zoomButton),
			let titlebarContainer = closeButton.superview
		else {
			return
		}

		window.titleVisibility = .hidden
		window.titlebarAppearsTransparent = true
		window.toolbarStyle = .unifiedCompact

		let buttons = [closeButton, miniaturizeButton, zoomButton]
		let originY = titlebarContainer.bounds.height - topInset - buttonSize

		for (index, button) in buttons.enumerated() {
			button.setFrameSize(NSSize(width: buttonSize, height: buttonSize))
			button.setFrameOrigin(
				NSPoint(
					x: leadingInset + CGFloat(index) * (buttonSize + buttonSpacing),
					y: originY
				)
			)
		}
	}
}

private struct WindowConfigurator: NSViewRepresentable {
	let configure: (NSWindow) -> Void

	func makeNSView(context: Context) -> NSView {
		let view = NSView()
		DispatchQueue.main.async {
			if let window = view.window {
				configure(window)
			}
		}
		return view
	}

	func updateNSView(_ nsView: NSView, context: Context) {
		DispatchQueue.main.async {
			if let window = nsView.window {
				configure(window)
			}
		}
	}
}

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
				.background(
					WindowConfigurator { window in
						TrafficLightStyle.apply(to: window)
					}
				)
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
		.windowToolbarStyle(.unifiedCompact)
		.commands {
			CommandGroup(replacing: .newItem) {}
		}
	}
}
