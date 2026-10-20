import AppKit
import SwiftUI

/// ↑, ↓, Return and Esc in a window, wherever focus is there, while a menu
/// shows over it; none while a sheet is attached.
struct VaultMenuKeys: NSViewRepresentable {
	var handle: (Key) -> Bool

	enum Key: Equatable, Sendable {
		case up, down, open, close
	}

	nonisolated static func key(modifiers: NSEvent.ModifierFlags, keyCode: UInt16) -> Key? {
		guard modifiers.intersection([.command, .option, .control, .shift]).isEmpty else { return nil }
		return switch keyCode {
		case 126: .up
		case 125: .down
		case 36, 76: .open
		case 53: .close
		default: nil
		}
	}

	func makeNSView(context: Context) -> MonitorView { MonitorView() }

	func updateNSView(_ view: MonitorView, context: Context) {
		view.handle = handle
	}

	final class MonitorView: NSView {
		var handle: (Key) -> Bool = { _ in false }
		private var monitor: Any?

		override func hitTest(_ point: NSPoint) -> NSView? { nil }

		override func viewDidMoveToWindow() {
			super.viewDidMoveToWindow()
			if let monitor {
				NSEvent.removeMonitor(monitor)
				self.monitor = nil
			}
			guard window != nil else { return }
			monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
				guard let key = VaultMenuKeys.key(modifiers: event.modifierFlags, keyCode: event.keyCode) else { return event }
				let windowNumber = event.windowNumber
				let handled = MainActor.assumeIsolated { self?.handle(key, inWindow: windowNumber) ?? false }
				return handled ? nil : event
			}
		}

		private func handle(_ key: Key, inWindow windowNumber: Int) -> Bool {
			guard let window, window.windowNumber == windowNumber, window.attachedSheet == nil else { return false }
			return handle(key)
		}
	}
}

/// Behind a menu shown over the window: the menu closes as anything else
/// takes the window, as a menu does. That's a click anywhere else, which goes
/// no further; a sheet; another window or app; or a command, chosen from a
/// menu or by its shortcut.
struct VaultMenuBackdrop: NSViewRepresentable {
	let onDismiss: () -> Void

	func makeNSView(context: Context) -> BackdropView { BackdropView() }

	func updateNSView(_ view: BackdropView, context: Context) {
		view.onDismiss = onDismiss
	}

	final class BackdropView: NSView {
		var onDismiss: () -> Void = {}
		private var observers: [any NSObjectProtocol] = []

		override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
		override func mouseDown(with event: NSEvent) { onDismiss() }
		override func rightMouseDown(with event: NSEvent) { onDismiss() }
		override func otherMouseDown(with event: NSEvent) { onDismiss() }

		override func viewDidMoveToWindow() {
			super.viewDidMoveToWindow()
			observers.forEach(NotificationCenter.default.removeObserver)
			observers.removeAll()
			guard let window else { return }
			let takeovers: [(Notification.Name, NSObject?)] = [
				(NSWindow.willBeginSheetNotification, window),
				(NSWindow.didResignKeyNotification, window),
				(NSMenu.willSendActionNotification, nil),
			]
			observers = takeovers.map { name, object in
				NotificationCenter.default.addObserver(forName: name, object: object, queue: nil) { [weak self] _ in
					MainActor.assumeIsolated { self?.onDismiss() }
				}
			}
		}
	}
}
