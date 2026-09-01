import AppKit
import Foundation

@MainActor
final class ClipboardManager {
	static let shared = ClipboardManager()
	static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
	static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

	private var clearTask: Task<Void, Never>?
	private let clearDelay: TimeInterval
	private var ownedChangeCount: Int?

	init(clearDelay: TimeInterval = VaultConstants.clipboardClearDelay) {
		self.clearDelay = clearDelay
	}

	nonisolated static func dotenvText(for secrets: [String: String]) -> String {
		EnvFileCodec.format(secrets)
	}

	/// Copy a value to clipboard and schedule auto-clear
	func copy(_ value: String, clearAfter: TimeInterval? = nil) {
		let delay = clearAfter ?? clearDelay

		let pasteboard = NSPasteboard.general
		pasteboard.clearContents()
		guard pasteboard.setString(value, forType: .string) else {
			ownedChangeCount = nil
			clearTask?.cancel()
			clearTask = nil
			return
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
	}

	private func clearClipboardIfOwned() {
		let pasteboard = NSPasteboard.general
		guard pasteboard.changeCount == ownedChangeCount else {
			ownedChangeCount = nil
			clearTask = nil
			return
		}
		clearClipboard()
	}

	/// Clear clipboard immediately
	func clearClipboard() {
		let pasteboard = NSPasteboard.general
		if let ownedChangeCount, pasteboard.changeCount == ownedChangeCount {
			pasteboard.clearContents()
		}
		ownedChangeCount = nil
		clearTask?.cancel()
		clearTask = nil
	}
}
