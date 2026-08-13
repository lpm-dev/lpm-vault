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
	@State private var isObscured = false

	var body: some Scene {
		// Main window — opens automatically on launch
		Window("LPM Vault", id: "main") {
			ContentView(store: store)
				.overlay {
					if isObscured {
						ZStack {
							Color(nsColor: .windowBackgroundColor)
							VStack(spacing: 12) {
								Image(systemName: "lock.shield")
									.font(.system(size: 40))
									.foregroundStyle(.secondary)
								Text("LPM Vault")
									.font(.headline)
									.foregroundStyle(.secondary)
							}
						}
						.ignoresSafeArea()
					}
				}
				.onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
					isObscured = true
				}
				.onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
					isObscured = false
				}
				.task {
					await store.loadTokens()
				}
				.onAppear {
					appDelegate.openWindow = { [openWindow] in
						openWindow(id: "main")
					}
					appDelegate.lockVault = { [store] in
						store.lock()
					}
				}
		}
		.defaultSize(width: 900, height: 550)
		.windowToolbarStyle(.unifiedCompact)
		.commands {
			CommandGroup(replacing: .newItem) {}
			CommandMenu("Env Project") {
				Button("New Secret") {
					NotificationCenter.default.post(name: .newSecret, object: nil)
				}
				.keyboardShortcut("n", modifiers: .command)
				.disabled(!store.isUnlocked || store.selectedProject == nil)

				Button("Find Secrets") {
					NotificationCenter.default.post(name: .findSecrets, object: nil)
				}
				.keyboardShortcut("f", modifiers: .command)
				.disabled(!store.isUnlocked || store.selectedProject == nil)

				Divider()

				Button("Lock LPM Vault") { store.lock() }
					.keyboardShortcut("l", modifiers: [.command, .control])
					.disabled(!store.isUnlocked)
			}
		}
	}
}

extension Notification.Name {
	static let newSecret = Notification.Name("dev.lpm.vault.new-secret")
	static let findSecrets = Notification.Name("dev.lpm.vault.find-secrets")
}
