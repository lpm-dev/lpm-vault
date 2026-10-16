import SwiftUI

/// Handles dock click, prevents quit on window close, and decides what ⌘Q
/// and quitting take.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
	static let quitShortcutEvents: NSEvent.EventTypeMask = [
		.keyDown,
		.keyUp,
		.flagsChanged,
		.leftMouseDown,
		.rightMouseDown,
		.otherMouseDown,
	]

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
	/// The answer to quitting, once the app's window has connected it.
	var shouldTerminate: (() -> NSApplication.TerminateReply)?
	/// Whether quitting is already deciding, so ⌘Q doesn't ask again meanwhile.
	var isQuitting: () -> Bool = { false }
	var quitShortcut: () -> VaultQuitShortcut = { VaultQuitShortcut.saved(in: .standard) }
	let quitHUD = VaultQuitHUDController()
	private(set) lazy var quitGate = VaultQuitGate(
		mode: { [weak self] in self?.quitShortcut() ?? VaultQuitShortcut.standard },
		quit: { [weak self] in self?.quitFromShortcut() },
		showHint: { [weak self] in self?.quitHUD.show($0) },
		hideHint: { [weak self] in self?.quitHUD.hide() }
	)
	private var localEventMonitor: Any?
	private var quitShortcutMonitor: Any?
	private var hasPendingSecurityLock = false

	func applicationDidFinishLaunching(_ notification: Notification) {
		ProcessLimits.raiseOpenFiles()

		// Swift Package launches have no app bundle for macOS to discover the icon.
		if Bundle.main.url(forResource: "AppIcon", withExtension: "icns") == nil {
			NSApplication.shared.applicationIconImage = VaultBranding.appIcon
		}

		localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: Self.userActivityEvents) {
			[weak self] event in
			self?.recordUserActivity?()
			return event
		}
		// Sees ⌘Q before the Quit menu item does, so the gate decides when it quits.
		quitShortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: Self.quitShortcutEvents) {
			[weak self] event in
			guard let self, let input = VaultQuitGate.input(for: event) else { return event }
			return quitGate.handle(input, at: event.timestamp) ? nil : event
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

	func applicationDidResignActive(_ notification: Notification) {
		quitGate.cancel()
	}

	/// Every way of quitting arrives here: the shortcut once its gate allows
	/// it, the menu, the Dock, logging out, shutting down and update restarts.
	func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
		quitGate.cancel()
		return shouldTerminate?() ?? .terminateNow
	}

	private func quitFromShortcut() {
		guard !isQuitting() else { return }
		NSApp.terminate(nil)
	}

	func applicationWillTerminate(_ notification: Notification) {
		lockVault?()
		for monitor in [localEventMonitor, quitShortcutMonitor].compactMap({ $0 }) { NSEvent.removeMonitor(monitor) }
		localEventMonitor = nil
		quitShortcutMonitor = nil
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
	@State private var updateChecker = UpdateChecker()
	@State private var appearanceSettings = VaultAppearanceSettings()
	@State private var quitSettings = VaultQuitSettings()
	@State private var quitCoordinator = VaultQuitCoordinator(store: nil, presenter: VaultQuitSheetPresenter())
	@State private var isObscured = false

	var body: some Scene {
		// Main window — opens automatically on launch
		Window("LPM Vault", id: "main") {
			ContentView(store: store)
				.environment(updateChecker)
				.environment(appearanceSettings)
				.environment(\.vaultContentObscured, isObscured)
				.vaultAppearance(appearanceSettings.selection)
				.tint(VaultPalette.accent)
				.vaultPrivacyProtected(isObscured)
				.onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
					isObscured = true
				}
				.onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
					isObscured = false
				}
				.task {
					updateChecker.start()
					await store.loadAccount()
				}
				.task { await store.projectIcons.collectUnusedImages() }
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
					quitCoordinator.attach(store)
					appDelegate.shouldTerminate = { [quitCoordinator] in quitCoordinator.shouldTerminate() }
					appDelegate.isQuitting = { [quitCoordinator] in quitCoordinator.isQuitting }
				}
		}
		.defaultSize(width: 1200, height: 760)
		.windowStyle(.hiddenTitleBar)
		.commands {
			CommandGroup(replacing: .newItem) {}
			CommandGroup(after: .appInfo) {
				Button("Check for Updates…") { updateChecker.checkForUpdates() }
					.disabled(!updateChecker.canCheckForUpdates)
			}
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

				Button("Project Settings…") {
					NotificationCenter.default.post(name: .showProjectSettings, object: nil)
				}
				.keyboardShortcut("i", modifiers: .command)
				.disabled(!store.isUnlocked || store.selectedProject == nil)

				Divider()

				Button(store.isUnlocked ? "Lock LPM Vault" : "Unlock LPM Vault") {
					if store.isUnlocked {
						store.lock()
					} else {
						Task { await store.unlock() }
					}
				}
					.keyboardShortcut("l", modifiers: .command)
					.disabled(store.isUnlocking)
			}
		}

		Settings {
			VaultSettingsView()
				.environment(updateChecker)
				.environment(appearanceSettings)
				.environment(quitSettings)
				.vaultAppearance(appearanceSettings.selection)
				.tint(VaultPalette.accent)
		}
	}

}

extension Notification.Name {
	static let newSecret = Notification.Name("dev.lpm.vault.new-secret")
	static let findSecrets = Notification.Name("dev.lpm.vault.find-secrets")
	static let showProjectSettings = Notification.Name("dev.lpm.vault.show-project-settings")
	static let dismissVaultSearch = Notification.Name("dev.lpm.vault.dismiss-search")
}
