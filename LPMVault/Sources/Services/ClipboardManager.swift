import AppKit
import Foundation

@MainActor
final class ClipboardManager {
	static let shared = ClipboardManager()

	private var clearTask: Task<Void, Never>?
	private let clearDelay: TimeInterval

	init(clearDelay: TimeInterval = VaultConstants.clipboardClearDelay) {
		self.clearDelay = clearDelay
	}

	/// Copy a value to clipboard and schedule auto-clear
	func copy(_ value: String, clearAfter: TimeInterval? = nil) {
		let delay = clearAfter ?? clearDelay

		let pasteboard = NSPasteboard.general
		pasteboard.clearContents()
		pasteboard.setString(value, forType: .string)

		// Cancel any existing clear timer
		clearTask?.cancel()

		// Schedule new clear
		clearTask = Task {
			try? await Task.sleep(for: .seconds(delay))
			if !Task.isCancelled {
				clearClipboard()
			}
		}
	}

	/// Clear clipboard immediately
	func clearClipboard() {
		let pasteboard = NSPasteboard.general
		pasteboard.clearContents()
		clearTask?.cancel()
		clearTask = nil
	}
}
