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

/// Behind a menu shown over the window: a click anywhere else closes the
/// menu, and goes no further, as a click outside a menu does.
struct VaultClickCatcher: NSViewRepresentable {
	let onClick: () -> Void

	func makeNSView(context: Context) -> CatcherView { CatcherView() }

	func updateNSView(_ view: CatcherView, context: Context) {
		view.onClick = onClick
	}

	final class CatcherView: NSView {
		var onClick: () -> Void = {}

		override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
		override func mouseDown(with event: NSEvent) { onClick() }
		override func rightMouseDown(with event: NSEvent) { onClick() }
		override func otherMouseDown(with event: NSEvent) { onClick() }
	}
}
