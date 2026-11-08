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
	/// How long a copied secret stays, from the Security setting; a change
	/// applies to the next copy.
	var clearDelay: TimeInterval
	private let sleep: @Sendable (Duration) async throws -> Void
	private let prepare: @MainActor (NSPasteboard, NSPasteboard.ContentsOptions) -> Void
	private var ownedChangeCount: Int?

	/// `sleep` waits out the time before a copy is cleared; `prepare` empties
	/// the pasteboard for a secret with the options it's copied with.
	init(
		pasteboard: NSPasteboard = .general, clearDelay: TimeInterval = VaultClipboardClear.standard.seconds,
		sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
		prepare: @escaping @MainActor (NSPasteboard, NSPasteboard.ContentsOptions) -> Void = { $0.prepareForNewContents(with: $1) }
	) {
		self.pasteboard = pasteboard
		self.clearDelay = clearDelay
		self.sleep = sleep
		self.prepare = prepare
	}

	/// Whether a copied secret is still to be cleared once its time is up.
	var isClearScheduled: Bool { clearTask != nil }

	nonisolated static func dotenvText(for secrets: [String: String]) -> String {
		EnvFileCodec.format(secrets)
	}

	/// Copies a value, kept to this Mac rather than offered to the person's
	/// other devices through Universal Clipboard, marked for clipboard
	/// managers to skip, and clears it after `clearDelay`. Returns whether the
	/// clipboard accepted the value.
	@discardableResult
	func copy(_ value: String) -> Bool {
		prepare(pasteboard, .currentHostOnly)
		guard pasteboard.setString(value, forType: .string) else {
			ownedChangeCount = nil
			clearTask?.cancel()
			clearTask = nil
			return false
		}
		pasteboard.setData(Data(), forType: Self.concealedType)
		pasteboard.setData(Data(), forType: Self.transientType)
		ownedChangeCount = pasteboard.changeCount

		clearTask?.cancel()
		clearTask = Task { [sleep, clearDelay] in
			try? await sleep(.seconds(clearDelay))
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
