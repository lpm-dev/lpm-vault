import SwiftUI

/// Handles dock click and prevents quit on window close.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
	static let userActivityEvents: NSEvent.EventTypeMask = [
		.keyDown,
		.leftMouseDown,
		.rightMouseDown,
		.otherMouseDown,
		.scrollWheel,
		.gesture,
		.magnify,
		.rotate,
		.swipe,
	]

	var openWindow: (() -> Void)?
	var lockVault: (() -> Void)? {
		didSet {
			guard lockVault != nil, hasPendingSecurityLock else { return }
			hasPendingSecurityLock = false
			lockVault?()
		}
	}
	var recordUserActivity: (() -> Void)?
	private var localEventMonitor: Any?
	private var hasPendingSecurityLock = false

	func applicationDidFinishLaunching(_ notification: Notification) {
		// Swift Package launches have no app bundle for macOS to discover the icon.
		if Bundle.main.url(forResource: "AppIcon", withExtension: "icns") == nil {
			NSApplication.shared.applicationIconImage = VaultBranding.appIcon
		}

		localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: Self.userActivityEvents) {
			[weak self] event in
			self?.recordUserActivity?()
			return event
		}

		let workspaceCenter = NSWorkspace.shared.notificationCenter
		for name in [
			NSWorkspace.sessionDidResignActiveNotification,
			NSWorkspace.willSleepNotification,
			NSWorkspace.screensDidSleepNotification,
		] {
			workspaceCenter.addObserver(
				self,
				selector: #selector(handleSecurityNotification(_:)),
				name: name,
				object: nil
			)
		}
	}

	@objc private func handleSecurityNotification(_ notification: Notification) {
		handleSecurityStateChange()
	}

	func handleSecurityStateChange() {
		guard let lockVault else {
			hasPendingSecurityLock = true
			return
		}
		lockVault()
	}

	func applicationWillTerminate(_ notification: Notification) {
		lockVault?()
		if let localEventMonitor { NSEvent.removeMonitor(localEventMonitor) }
		localEventMonitor = nil
		NSWorkspace.shared.notificationCenter.removeObserver(self)
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
				.environment(\.vaultContentObscured, isObscured)
				.preferredColorScheme(.light)
				.vaultPrivacyProtected(isObscured)
				.onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
					isObscured = true
				}
				.onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
					isObscured = false
				}
				.task {
					await store.loadAccount()
				}
				.onAppear {
					appDelegate.openWindow = { [openWindow] in
						openWindow(id: "main")
					}
					appDelegate.lockVault = { [store] in
						store.lock()
					}
					appDelegate.recordUserActivity = { [store] in
						store.recordUserActivity()
					}
				}
		}
		.defaultSize(width: 1200, height: 760)
		.windowStyle(.hiddenTitleBar)
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
	static let dismissVaultSearch = Notification.Name("dev.lpm.vault.dismiss-search")
}
