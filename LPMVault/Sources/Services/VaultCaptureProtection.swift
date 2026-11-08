import AppKit

/// Keeps LPM Vault's windows out of screenshots, screen recordings and screen
/// sharing while the Security setting asks for it, by marking each window's
/// contents as not shared. Sheets, popovers and menus are windows of their
/// own, so every window the app has is marked, each pass of the event loop,
/// as soon as it exists.
@MainActor
final class VaultCaptureProtection {
	private(set) var isEnabled = false
	private let windows: @MainActor () -> [NSWindow]
	private let notifications: NotificationCenter
	private var observer: (any NSObjectProtocol)?

	init(
		windows: @escaping @MainActor () -> [NSWindow] = { NSApp.windows },
		notifications: NotificationCenter = .default
	) {
		self.windows = windows
		self.notifications = notifications
	}

	func setEnabled(_ enabled: Bool) {
		isEnabled = enabled
		apply()
		if enabled, observer == nil {
			observer = notifications.addObserver(forName: NSApplication.didUpdateNotification, object: nil, queue: .main) { [weak self] _ in
				MainActor.assumeIsolated { self?.apply() }
			}
		} else if !enabled, let observer {
			notifications.removeObserver(observer)
			self.observer = nil
		}
	}

	/// Marks each window as the setting says; it only compares while nothing
	/// changed, cheap enough for every pass of the event loop.
	func apply() {
		let sharing: NSWindow.SharingType = isEnabled ? .none : .readOnly
		for window in windows() where window.sharingType != sharing {
			window.sharingType = sharing
		}
	}
}
