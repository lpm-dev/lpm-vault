import AppKit
import Foundation

/// Copies to a pasteboard, the system's in the app, and clears a copied
/// secret after a while or when the vault locks, unless something newer has
/// been copied since. Each store has its own, so a lock clears only its copies.
@MainActor
final class ClipboardManager {
	static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
	static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

	let pasteboard: NSPasteboard
	private var clearTask: Task<Void, Never>?
	private let clearDelay: TimeInterval
	private var ownedChangeCount: Int?

	init(pasteboard: NSPasteboard = .general, clearDelay: TimeInterval = VaultConstants.clipboardClearDelay) {
		self.pasteboard = pasteboard
		self.clearDelay = clearDelay
	}

	nonisolated static func dotenvText(for secrets: [String: String]) -> String {
		EnvFileCodec.format(secrets)
	}

	/// Copies a value and schedules auto-clear. Returns whether the clipboard accepted the value.
	@discardableResult
	func copy(_ value: String, clearAfter: TimeInterval? = nil) -> Bool {
		let delay = clearAfter ?? clearDelay

		pasteboard.clearContents()
		guard pasteboard.setString(value, forType: .string) else {
			ownedChangeCount = nil
			clearTask?.cancel()
			clearTask = nil
			return false
		}
		pasteboard.setData(Data(), forType: Self.concealedType)
		pasteboard.setData(Data(), forType: Self.transientType)
		ownedChangeCount = pasteboard.changeCount

		// Cancel any existing clear timer
		clearTask?.cancel()

		// Schedule new clear
		clearTask = Task {
			try? await Task.sleep(for: .seconds(delay))
			if !Task.isCancelled {
				clearClipboardIfOwned()
			}
		}
		return true
	}

	/// Copies text that isn't secret, such as a folder path or a command; it isn't cleared later.
	@discardableResult
	func copyText(_ text: String) -> Bool {
		pasteboard.clearContents()
		return pasteboard.setString(text, forType: .string)
	}

	private func clearClipboardIfOwned() {
		guard pasteboard.changeCount == ownedChangeCount else {
			ownedChangeCount = nil
			clearTask = nil
			return
		}
		clearClipboard()
	}

	/// Clear clipboard immediately
	func clearClipboard() {
		if let ownedChangeCount, pasteboard.changeCount == ownedChangeCount {
			pasteboard.clearContents()
		}
		ownedChangeCount = nil
		clearTask?.cancel()
		clearTask = nil
	}
}
