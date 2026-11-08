import AppKit
import Foundation
import Testing

@testable import LPMVault

/// Defaults of their own for one test, which never touch the app's.
func isolatedDefaults() throws -> UserDefaults {
	let domain = "dev.lpm.vault.tests.\(UUID().uuidString)"
	let defaults = try #require(UserDefaults(suiteName: domain))
	defaults.removePersistentDomain(forName: domain)
	return defaults
}

@Suite("Security settings")
@MainActor
struct VaultSecuritySettingsTests {
	@Test("every setting starts at its default and is saved as it changes")
	func defaultsAndSaving() throws {
		let defaults = try isolatedDefaults()
		let settings = VaultSettings(defaults: defaults)
		#expect(settings.snapshot == VaultSettings.standard)
		#expect(settings.lockAfter == .twoMinutes)
		#expect(settings.valueApproval == .never)
		#expect(settings.clipboardClear == .tenSeconds)
		#expect(settings.rehide == .never)
		#expect(settings.hidesFromCapture)
		#expect(settings.newProjectsKeepHistory)
		#expect(!settings.newProjectsAskBeforeCLIReads)
		#expect(settings.remindsToBackUp)

		let changed = VaultSettings.Snapshot(
			security: .init(lockAfter: .fifteenMinutes, valueApproval: .afterFiveMinutes, clipboardClear: .oneMinute,
				rehide: .thirtySeconds, hidesFromCapture: false),
			newProjectsKeepHistory: false, newProjectsAskBeforeCLIReads: true, remindsToBackUp: false)
		settings.snapshot = changed
		#expect(VaultSettings(defaults: defaults).snapshot == changed)
	}

	@Test("a saved value that isn't one of the choices reads as the default")
	func unknownSavedValues() throws {
		let defaults = try isolatedDefaults()
		defaults.set(7, forKey: VaultSettings.Key.lockAfter)
		defaults.set("often", forKey: VaultSettings.Key.valueApproval)
		defaults.set(true, forKey: VaultSettings.Key.clipboardClear)
		defaults.set(1, forKey: VaultSettings.Key.hidesFromCapture)
		defaults.set("yes", forKey: VaultSettings.Key.backupReminder)
		let settings = VaultSettings(defaults: defaults)
		#expect(settings.lockAfter == .standard)
		#expect(settings.valueApproval == .standard)
		#expect(settings.clipboardClear == .standard)
		#expect(settings.hidesFromCapture, "A number isn't a switch's saved state")
		#expect(settings.remindsToBackUp)
	}

	@Test("choices name their durations as the menus show them")
	func choiceTitles() {
		#expect(VaultLockInterval.allCases.map(\.title) == ["1 min", "2 min", "5 min", "15 min", "30 min"])
		#expect(VaultValueApproval.allCases.map(\.title) == ["Never", "After 5 min", "After 15 min"])
		#expect(VaultClipboardClear.allCases.map(\.title) == ["10 sec", "30 sec", "1 min", "2 min"])
		#expect(VaultClipboardClear.allCases.map(\.countdown) == ["10s", "30s", "1 min", "2 min"])
		#expect(VaultRehideInterval.allCases.map(\.title) == ["Never", "After 30 sec", "After 1 min", "After 5 min"])
	}

	@Test("only a change the running app acts on is announced, once")
	func changeAnnouncements() throws {
		let settings = VaultSettings(defaults: try isolatedDefaults())
		var changes: [VaultSettings.Change] = []
		settings.onChange = { changes.append($0) }
		settings.lockAfter = .fiveMinutes
		settings.lockAfter = .fiveMinutes
		settings.clipboardClear = .thirtySeconds
		settings.newProjectsKeepHistory = false
		settings.remindsToBackUp = false
		settings.hidesFromCapture = false
		#expect(changes == [.lockAfter, .clipboardClear, .hidesFromCapture])
	}

	// MARK: - Clipboard

	@Test("a copied value stays on this Mac, out of Universal Clipboard")
	func copiesStayOnThisMac() {
		let pasteboard = NSPasteboard(name: NSPasteboard.Name("vault-tests-\(UUID().uuidString)"))
		defer { pasteboard.releaseGlobally() }
		var options: [NSPasteboard.ContentsOptions] = []
		let clipboard = ClipboardManager(pasteboard: pasteboard, sleep: { _ in try await Task.sleep(for: .seconds(3600)) }) {
			options.append($1)
			$0.prepareForNewContents(with: $1)
		}
		#expect(clipboard.copy("secret"))
		#expect(options == [.currentHostOnly])
		#expect(pasteboard.string(forType: .string) == "secret")
		#expect(pasteboard.data(forType: ClipboardManager.concealedType) != nil)
		#expect(pasteboard.data(forType: ClipboardManager.transientType) != nil)
		clipboard.clearClipboard()
	}

	@Test("the clipboard clears after the time the setting gives, read at each copy")
	func clipboardClearsAfterTheSetting() async throws {
		let pasteboard = NSPasteboard(name: NSPasteboard.Name("vault-tests-\(UUID().uuidString)"))
		defer { pasteboard.releaseGlobally() }
		let waits = DurationLog()
		let clipboard = ClipboardManager(pasteboard: pasteboard, sleep: { duration in
			await waits.append(duration)
			try await Task.sleep(for: .seconds(3600))
		})
		let settings = VaultSettings(defaults: try isolatedDefaults())
		let store = VaultStore(keychainService: MockKeychainService(), biometricService: MockBiometricService(),
			apiService: MockAPIService(), settings: settings, clipboard: clipboard)
		#expect(clipboard.clearDelay == 10)
		settings.clipboardClear = .twoMinutes
		#expect(clipboard.clearDelay == 120)
		clipboard.copy("secret")
		#expect(try await waitUntil { await waits.values == [.seconds(120)] })
		clipboard.clearClipboard()
		_ = store
	}
}

@Suite("Asking again and masking again")
@MainActor
struct VaultValueAccessTests {
	@Test("with Never, a copy runs at once and nothing asks")
	func neverAsks() {
		let prompt = ApprovalPrompt()
		let access = prompt.access(approval: .never)
		var copied = 0
		access.copy { copied += 1 }
		#expect(copied == 1)
		#expect(prompt.asked == 0)
	}

	@Test("an approval holds for the setting's time, then the next copy asks once and holds again")
	func approvalLapses() async throws {
		let prompt = ApprovalPrompt()
		let access = prompt.access(approval: .afterFiveMinutes)
		var copied = 0
		#expect(access.needsApproval, "Nothing has approved yet")
		access.noteUnlocked()
		access.copy { copied += 1 }
		#expect(copied == 1 && prompt.asked == 0, "Unlocking approves")

		prompt.now = 299
		access.copy { copied += 1 }
		#expect(copied == 2 && prompt.asked == 0)

		prompt.now = 300
		access.copy { copied += 1 }
		#expect(copied == 2)
		#expect(try await waitUntil { prompt.asked == 1 })
		prompt.answer(true)
		#expect(try await waitUntil { copied == 3 })

		prompt.now = 599
		access.copy { copied += 1 }
		#expect(copied == 4 && prompt.asked == 1, "The new approval holds from when it was given")
	}

	@Test("a declined approval runs nothing")
	func declinedRunsNothing() async throws {
		let prompt = ApprovalPrompt()
		let access = prompt.access(approval: .afterFifteenMinutes)
		var revealed = false
		access.reveal { revealed = true }
		#expect(try await waitUntil { prompt.asked == 1 })
		prompt.answer(false)
		#expect(try await waitUntil { prompt.waiting == 0 })
		await Task.yield()
		#expect(!revealed)
		#expect(access.needsApproval)
	}

	@Test("actions while one approval is asked share it")
	func sharedPrompt() async throws {
		let prompt = ApprovalPrompt()
		let access = prompt.access(approval: .afterFiveMinutes)
		var done: [String] = []
		access.reveal { done.append("reveal") }
		access.copy { done.append("copy") }
		#expect(try await waitUntil { prompt.asked == 1 })
		prompt.answer(true)
		#expect(try await waitUntil { done.count == 2 })
		#expect(prompt.asked == 1)
		#expect(Set(done) == ["reveal", "copy"])
	}

	@Test("locking while an approval is asked drops what waited on it")
	func lockingDropsWaitingActions() async throws {
		let prompt = ApprovalPrompt()
		let access = prompt.access(approval: .afterFiveMinutes)
		var copied = false
		access.copy { copied = true }
		#expect(try await waitUntil { prompt.asked == 1 })
		access.reset()
		prompt.answer(true)
		#expect(try await waitUntil { prompt.waiting == 0 })
		await Task.yield()
		#expect(!copied)
	}

	@Test("revealed values are masked again after the setting's time, from the latest reveal")
	func rehideAfterInterval() async throws {
		let prompt = ApprovalPrompt()
		prompt.rehide = .oneMinute
		let access = prompt.access(approval: .never)
		var hidden = 0
		access.onHide = { hidden += 1 }
		access.reveal {}
		#expect(try await waitUntil { prompt.sleeps.count == 1 })
		access.reveal {}
		#expect(try await waitUntil { prompt.sleeps.count == 2 })
		#expect(prompt.sleeps.map(\.duration) == [.seconds(60), .seconds(60)])
		prompt.wake(0)
		await Task.yield()
		#expect(access.hideGeneration == 0, "The first reveal's time was replaced by the second's")
		prompt.wake(1)
		#expect(try await waitUntil { access.hideGeneration == 1 })
		#expect(hidden == 1)
	}

	@Test("with Never, revealed values stay shown, and switching to Never stops a running time")
	func rehideNever() async throws {
		let prompt = ApprovalPrompt()
		prompt.rehide = .thirtySeconds
		let access = prompt.access(approval: .never)
		access.reveal {}
		#expect(try await waitUntil { prompt.sleeps.count == 1 })
		prompt.rehide = .never
		access.rehideSettingChanged()
		prompt.wake(0)
		await Task.yield()
		#expect(access.hideGeneration == 0)
		access.reveal {}
		await Task.yield()
		#expect(prompt.sleeps.count == 1, "Never starts no time")
	}
}

/// A Touch ID prompt a test answers, a clock it moves and sleeps it ends.
@MainActor
final class ApprovalPrompt {
	var now: TimeInterval = 0
	var rehide: VaultRehideInterval = .never
	private(set) var asked = 0
	private var answers: [CheckedContinuation<Bool, Never>] = []
	var waiting: Int { answers.count }
	struct Sleep {
		let duration: Duration
		let continuation: CheckedContinuation<Void, any Error>
	}
	private(set) var sleeps: [Sleep] = []
	private var woken = Set<Int>()

	func access(approval: VaultValueApproval) -> VaultValueAccess {
		let clock = UncheckedBox(self)
		return VaultValueAccess(
			approval: { approval },
			rehide: { [unowned self] in rehide },
			confirm: { [unowned self] _ in
				asked += 1
				return await withCheckedContinuation { answers.append($0) }
			},
			now: { MainActor.assumeIsolated { clock.value.now } },
			sleep: { duration in
				try await withCheckedThrowingContinuation { continuation in
					Task { @MainActor in clock.value.sleeps.append(Sleep(duration: duration, continuation: continuation)) }
				}
			})
	}

	func answer(_ approved: Bool) {
		guard !answers.isEmpty else { return }
		answers.removeFirst().resume(returning: approved)
	}

	func wake(_ index: Int) {
		guard sleeps.indices.contains(index), woken.insert(index).inserted else { return }
		sleeps[index].continuation.resume()
	}
}

/// A main-actor object handed to a closure that can't say it runs there.
struct UncheckedBox<Value: AnyObject>: @unchecked Sendable {
	let value: Value
	init(_ value: Value) { self.value = value }
}

/// The durations a fake sleep was asked for, in order.
actor DurationLog {
	private(set) var values: [Duration] = []
	func append(_ duration: Duration) { values.append(duration) }
}

@Suite("Hiding from screenshots")
@MainActor
struct VaultCaptureProtectionTests {
	@Test("every window, including one opened later, is left out of capture while the setting is on")
	func marksEveryWindow() {
		let center = NotificationCenter()
		let first = Self.window()
		let second = Self.window()
		let list = WindowList(windows: [first])
		let protection = VaultCaptureProtection(windows: { list.windows }, notifications: center)
		protection.setEnabled(true)
		#expect(first.sharingType == .none)

		list.windows.append(second)
		#expect(second.sharingType == .readOnly)
		center.post(name: NSApplication.didUpdateNotification, object: nil)
		#expect(second.sharingType == .none, "A sheet or popover opened later is marked within one pass of the event loop")

		protection.setEnabled(false)
		#expect(first.sharingType == .readOnly)
		#expect(second.sharingType == .readOnly)
		second.sharingType = .none
		center.post(name: NSApplication.didUpdateNotification, object: nil)
		#expect(second.sharingType == .none, "Off, it stops looking at windows")
	}

	@MainActor
	private final class WindowList {
		var windows: [NSWindow]
		init(windows: [NSWindow]) { self.windows = windows }
	}

	private static func window() -> NSWindow {
		let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 40, height: 40), styleMask: [.titled], backing: .buffered, defer: true)
		window.isReleasedWhenClosed = false
		return window
	}
}
