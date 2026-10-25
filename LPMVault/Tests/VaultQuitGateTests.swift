import AppKit
import Foundation
import Testing

@testable import LPMVault

/// A clock and timers the test moves forward by hand.
@MainActor
final class ManualQuitClock {
	private struct Timer {
		let id: Int
		let due: TimeInterval
		let work: @MainActor () -> Void
	}

	private(set) var now: TimeInterval = 1_000
	private var timers: [Timer] = []
	private var nextID = 0

	func schedule(_ delay: TimeInterval, _ work: @escaping @MainActor () -> Void) -> () -> Void {
		nextID += 1
		let id = nextID
		timers.append(Timer(id: id, due: now + delay, work: work))
		return { [weak self] in self?.timers.removeAll { $0.id == id } }
	}

	/// Moves time forward, running each timer that comes due, in order.
	func advance(by interval: TimeInterval) {
		let end = now + interval
		while let next = timers.filter({ $0.due <= end }).min(by: { $0.due < $1.due }) {
			timers.removeAll { $0.id == next.id }
			now = next.due
			next.work()
		}
		now = end
	}
}

@Suite("Quit shortcut")
@MainActor
struct VaultQuitGateTests {
	private let timing = VaultQuitGate.Timing()

	private final class Recorder {
		var quits = 0
		var hints: [VaultQuitGate.Hint?] = []
	}

	private func makeGate(_ mode: VaultQuitShortcut, keyRepeatDelay: TimeInterval = 0.5, keyRepeatInterval: TimeInterval = 0.05,
		isDeciding: @escaping () -> Bool = { false }) -> (VaultQuitGate, ManualQuitClock, Recorder)
	{
		let clock = ManualQuitClock()
		let recorder = Recorder()
		let gate = VaultQuitGate(
			mode: { mode },
			isDeciding: isDeciding,
			now: { clock.now },
			keyRepeatDelay: { keyRepeatDelay },
			keyRepeatInterval: { keyRepeatInterval },
			schedule: { clock.schedule($0, $1) },
			quit: { recorder.quits += 1 },
			showHint: { recorder.hints.append($0) },
			hideHint: { recorder.hints.append(nil) }
		)
		return (gate, clock, recorder)
	}

	@discardableResult
	private func press(_ gate: VaultQuitGate, _ clock: ManualQuitClock, repeat isRepeat: Bool = false) -> Bool {
		gate.handle(.quitKeyDown(isRepeat: isRepeat), at: clock.now)
	}

	@Test("Direct quits on the first press, with no hint")
	func direct() {
		let (gate, clock, recorder) = makeGate(.direct)
		#expect(press(gate, clock))
		#expect(recorder.quits == 1)
		#expect(recorder.hints.isEmpty)
	}

	@Test("Double press shows a hint and quits on a second press within two seconds")
	func doublePress() {
		let (gate, clock, recorder) = makeGate(.doublePress)
		#expect(press(gate, clock), "⌘Q never reaches the Quit menu item")
		#expect(recorder.quits == 0)
		#expect(gate.hint == .pressAgain)
		clock.advance(by: timing.doublePressWindow - 0.1)
		press(gate, clock)
		#expect(recorder.quits == 1)
		#expect(gate.hint == nil)
	}

	@Test("after two seconds the hint goes, and it takes two presses again")
	func doublePressTimesOut() {
		let (gate, clock, recorder) = makeGate(.doublePress)
		press(gate, clock)
		clock.advance(by: timing.doublePressWindow + 0.05)
		#expect(gate.hint == nil)
		#expect(recorder.hints == [.pressAgain, nil])
		press(gate, clock)
		#expect(recorder.quits == 0)
		#expect(gate.hint == .pressAgain)
	}

	@Test("a held key's repeats are never a second press")
	func repeatsDontCount() {
		let (gate, clock, recorder) = makeGate(.doublePress)
		press(gate, clock)
		for _ in 0..<20 {
			clock.advance(by: 0.05)
			#expect(press(gate, clock, repeat: true), "Repeats are used up so they can't reach the menu")
		}
		#expect(recorder.quits == 0)
		clock.advance(by: timing.doublePressWindow)
		#expect(gate.hint == nil)
	}

	@Test("another key, Esc, a click or leaving the app cancels, and only Esc is used up",
		arguments: ["other", "escape", "pointer", "resign"])
	func cancels(how: String) {
		let (gate, clock, recorder) = makeGate(.doublePress)
		press(gate, clock)
		clock.advance(by: 0.2)
		switch how {
		case "other": #expect(!gate.handle(.otherKey(isEscape: false), at: clock.now))
		case "escape": #expect(gate.handle(.otherKey(isEscape: true), at: clock.now))
		case "pointer": #expect(!gate.handle(.pointer, at: clock.now))
		default: gate.cancel()
		}
		#expect(gate.hint == nil)
		press(gate, clock)
		#expect(recorder.quits == 0, "The press after a cancel starts over")
		#expect(gate.hint == .pressAgain)
	}

	@Test("Esc and other keys pass through when nothing is waiting")
	func idleKeysPassThrough() {
		let (gate, clock, _) = makeGate(.doublePress)
		#expect(!gate.handle(.otherKey(isEscape: true), at: clock.now))
		#expect(!gate.handle(.otherKey(isEscape: false), at: clock.now))
		#expect(!gate.handle(.pointer, at: clock.now))
	}

	@Test("Hold quits once ⌘Q is held for a second and its repeats stop, or at once when Q's release arrives",
		arguments: ["command released", "repeats stop", "Q released"])
	func hold(release: String) {
		let (gate, clock, recorder) = makeGate(.hold)
		let start = clock.now
		press(gate, clock)
		#expect(gate.hint == .hold(timing.holdDuration))
		clock.advance(by: 0.5)
		while clock.now < start + timing.holdDuration {
			#expect(press(gate, clock, repeat: true))
			clock.advance(by: 0.05)
		}
		#expect(press(gate, clock, repeat: true))
		#expect(recorder.quits == 0, "A finished hold waits for the key to be let go")
		#expect(press(gate, clock, repeat: true), "Its repeats are still used up, so the menu never sees them")
		switch release {
		case "command released":
			gate.handle(.commandReleased, at: clock.now)
			clock.advance(by: timing.releaseGrace - 0.01)
			#expect(recorder.quits == 0)
			clock.advance(by: 0.02)
		case "repeats stop":
			clock.advance(by: timing.releaseGrace + 0.01)
		default:
			gate.handle(.quitKeyUp, at: clock.now)
		}
		#expect(recorder.quits == 1)
	}

	@Test("a hold let go too soon hides its hint and doesn't quit")
	func holdReleasedEarly() {
		let (gate, clock, recorder) = makeGate(.hold)
		press(gate, clock)
		clock.advance(by: 0.5)
		press(gate, clock, repeat: true)
		clock.advance(by: 0.1)
		gate.handle(.commandReleased, at: clock.now)
		#expect(gate.hint == nil)
		clock.advance(by: 3)
		#expect(recorder.quits == 0)
	}

	@Test("a hold whose repeats stop before a second counts as let go")
	func holdRepeatsStopEarly() {
		let (gate, clock, recorder) = makeGate(.hold)
		press(gate, clock)
		clock.advance(by: 0.5)
		press(gate, clock, repeat: true)
		clock.advance(by: timing.releaseGrace + 0.01)
		#expect(gate.hint == nil)
		clock.advance(by: 3)
		#expect(recorder.quits == 0)
	}

	@Test("a tap in Hold mode shows the hint until the repeat delay passes, then hides it")
	func holdTap() {
		let delay = 0.5
		let (gate, clock, recorder) = makeGate(.hold, keyRepeatDelay: delay)
		press(gate, clock)
		clock.advance(by: delay + timing.releaseGrace - 0.05)
		#expect(gate.hint == .hold(timing.holdDuration), "Repeats may still start")
		clock.advance(by: 0.1)
		#expect(gate.hint == nil)
		#expect(recorder.quits == 0)
	}

	@Test("a long system repeat delay still lets a hold finish once repeats start")
	func holdWithSlowRepeats() {
		let delay = timing.holdDuration + 0.5
		let (gate, clock, recorder) = makeGate(.hold, keyRepeatDelay: delay)
		press(gate, clock)
		clock.advance(by: delay)
		press(gate, clock, repeat: true)
		clock.advance(by: timing.releaseGrace + 0.01)
		#expect(recorder.quits == 1)
	}

	/// Holds ⌘Q with repeats every `interval` after `delay` until `until`, from the press.
	private func hold(_ gate: VaultQuitGate, _ clock: ManualQuitClock, delay: TimeInterval, interval: TimeInterval, until end: TimeInterval) {
		let start = clock.now
		press(gate, clock)
		var count = 0.0
		while delay + count * interval <= end + 0.000_1 {
			clock.advance(by: start + delay + count * interval - clock.now)
			press(gate, clock, repeat: true)
			count += 1
		}
	}

	@Test("a finished hold is cancelled by Esc, another key or a click, and only Esc is used up",
		arguments: ["escape", "other", "pointer"])
	func finishedHoldCancels(how: String) {
		let (gate, clock, recorder) = makeGate(.hold)
		hold(gate, clock, delay: 0.5, interval: 0.05, until: 1.05)
		switch how {
		case "escape": #expect(gate.handle(.otherKey(isEscape: true), at: clock.now))
		case "other": #expect(!gate.handle(.otherKey(isEscape: false), at: clock.now), "Typing reaches the app")
		default: #expect(!gate.handle(.pointer, at: clock.now))
		}
		clock.advance(by: 5)
		#expect(recorder.quits == 0)
		#expect(gate.hint == nil)
	}

	@Test("with slow key repeats, a finished hold waits longer than the gap between repeats before it quits")
	func slowRepeatsDontQuitWhileHeld() {
		let (gate, clock, recorder) = makeGate(.hold, keyRepeatDelay: 1.2, keyRepeatInterval: 0.8)
		hold(gate, clock, delay: 1.2, interval: 0.8, until: 2.8)
		#expect(recorder.quits == 0, "The key repeated at 2.0 and 2.8 s, so it's still held")
		clock.advance(by: 1.7)
		#expect(recorder.quits == 1, "Once the repeats stop for two of their gaps, the key was let go")
	}

	@Test("a hold let go before a second never quits, whatever the repeat rate", arguments: [(0.5, 0.5, 0.51), (0.5, 0.05, 0.96), (0.25, 0.03, 0.99)])
	func shortHoldDoesntQuit(sample: (TimeInterval, TimeInterval, TimeInterval)) {
		let (delay, interval, released) = sample
		let (gate, clock, recorder) = makeGate(.hold, keyRepeatDelay: delay, keyRepeatInterval: interval)
		hold(gate, clock, delay: delay, interval: interval, until: released)
		clock.advance(by: 5)
		#expect(recorder.quits == 0)
		#expect(gate.hint == nil)
	}

	@Test("the hold's hint lasts as long as a hold takes to prove, which a long repeat delay lengthens",
		arguments: [(0.5, 0.05, 1.0), (0.25, 0.3, 1.15), (1.8, 0.1, 1.8)])
	func holdHintLasts(sample: (TimeInterval, TimeInterval, TimeInterval)) throws {
		let (gate, clock, recorder) = makeGate(.hold, keyRepeatDelay: sample.0, keyRepeatInterval: sample.1)
		press(gate, clock)
		guard case .hold(let duration) = try #require(gate.hint) else {
			Issue.record("Hold shows its ring")
			return
		}
		#expect(abs(duration - sample.2) < 0.001)
		hold(gate, clock, delay: sample.0, interval: sample.1, until: sample.2)
		gate.handle(.commandReleased, at: clock.now)
		clock.advance(by: 5)
		#expect(recorder.quits == 1, "A hold as long as its hint quits")
	}

	@Test("with key repeat off, Hold takes two presses instead, as its hint says")
	func holdWithoutKeyRepeat() {
		let off = timing.longestRepeatDelay + 1
		let (gate, clock, recorder) = makeGate(.hold, keyRepeatDelay: off, keyRepeatInterval: off)
		press(gate, clock)
		#expect(gate.hint == .pressAgain)
		gate.handle(.commandReleased, at: clock.now)
		clock.advance(by: timing.doublePressWindow - 0.5)
		press(gate, clock)
		#expect(recorder.quits == 1)
	}

	@Test("while quitting is being decided, ⌘Q shows nothing and Esc reaches the sheet", arguments: [VaultQuitShortcut.doublePress, .hold])
	func ignoredWhileDeciding(mode: VaultQuitShortcut) {
		var deciding = true
		let (gate, clock, recorder) = makeGate(mode, isDeciding: { deciding })
		#expect(press(gate, clock), "⌘Q is used up, so the menu doesn't ask again")
		#expect(gate.hint == nil)
		#expect(!gate.handle(.otherKey(isEscape: true), at: clock.now))
		clock.advance(by: 5)
		#expect(recorder.quits == 0)
		deciding = false
		press(gate, clock)
		#expect(gate.hint != nil)
	}

	@Test("Hold also quits on two quick presses, but not two slow ones, whether ⌘ is let go between them or held",
		arguments: [VaultQuitGate.Input.commandReleased, .quitKeyUp], [(VaultQuitGate.Timing().quickPressWindow - 0.2, 1), (VaultQuitGate.Timing().quickPressWindow + 0.2, 0)])
	func holdDoublePress(between: VaultQuitGate.Input, sample: (TimeInterval, Int)) {
		let (gate, clock, recorder) = makeGate(.hold)
		press(gate, clock)
		gate.handle(between, at: clock.now)
		clock.advance(by: sample.0)
		press(gate, clock)
		#expect(recorder.quits == sample.1)
	}

	@Test("⌘Q alone is the quit key; repeats, releases, other keys, modifiers and clicks are told apart")
	func eventClassification() throws {
		func key(_ type: NSEvent.EventType, _ characters: String, _ flags: NSEvent.ModifierFlags, repeat isRepeat: Bool = false, code: UInt16 = 12) throws -> NSEvent {
			try #require(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
				characters: characters, charactersIgnoringModifiers: characters, isARepeat: isRepeat, keyCode: code))
		}
		#expect(VaultQuitGate.input(for: try key(.keyDown, "q", .command)) == .quitKeyDown(isRepeat: false))
		#expect(VaultQuitGate.input(for: try key(.keyDown, "q", .command, repeat: true)) == .quitKeyDown(isRepeat: true))
		#expect(VaultQuitGate.input(for: try key(.keyDown, "Q", [.command, .capsLock])) == .quitKeyDown(isRepeat: false))
		#expect(VaultQuitGate.input(for: try key(.keyDown, "q", [.command, .shift])) == .otherKey(isEscape: false))
		#expect(VaultQuitGate.input(for: try key(.keyDown, "q", [])) == .otherKey(isEscape: false))
		#expect(VaultQuitGate.input(for: try key(.keyDown, "\u{1b}", [], code: 53)) == .otherKey(isEscape: true))
		#expect(VaultQuitGate.input(for: try key(.keyUp, "q", .command)) == .quitKeyUp)
		let commandUp = try #require(NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
			context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 55))
		#expect(VaultQuitGate.input(for: commandUp) == .commandReleased)
		let click = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
			context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
		#expect(VaultQuitGate.input(for: click) == .pointer)
	}

	@Test("the setting defaults to Double press, persists, and reads back while locked")
	func setting() throws {
		let domain = "quit-shortcut-\(UUID().uuidString)"
		let defaults = try #require(UserDefaults(suiteName: domain))
		defer { defaults.removePersistentDomain(forName: domain) }
		#expect(VaultQuitShortcut.saved(in: defaults) == .doublePress)
		let settings = VaultQuitSettings(defaults: defaults)
		#expect(settings.selection == .doublePress)
		settings.selection = .hold
		#expect(VaultQuitShortcut.saved(in: defaults) == .hold)
		#expect(VaultQuitSettings(defaults: defaults).selection == .hold)
		defaults.set("unknown", forKey: VaultQuitShortcut.defaultsKey)
		#expect(VaultQuitShortcut.saved(in: defaults) == .doublePress)
		#expect(VaultQuitShortcut.allCases.map(\.explanation) == ["⌘Q quits immediately.", "Press ⌘Q twice.", "Hold ⌘Q, or press it twice."])
	}

	@Test("every way of quitting asks the app, saying whether the session is ending, and cancels a hint the shortcut shows")
	func delegateRoutesQuitting() {
		let delegate = AppDelegate()
		#expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateNow, "Before the window connects, quitting goes ahead")
		var asked: [Bool] = []
		delegate.shouldTerminate = {
			asked.append($0)
			return .terminateCancel
		}
		delegate.quitShortcut = { .doublePress }
		delegate.quitGate.handle(.quitKeyDown(isRepeat: false), at: 0)
		#expect(delegate.quitGate.hint == .pressAgain)
		#expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateCancel)
		#expect(asked == [false], "Quitting from the menu doesn't end the session")
		#expect(delegate.quitGate.hint == nil, "Quitting another way cancels the shortcut's hint")
	}

	@Test("while quitting is being decided, the shortcut asks nothing again")
	func shortcutWaitsWhileDeciding() async throws {
		let delegate = AppDelegate()
		delegate.quitShortcut = { .direct }
		var deciding = true
		delegate.isQuitting = { deciding }
		var terminations = 0
		delegate.terminate = { terminations += 1 }
		#expect(delegate.quitGate.handle(.quitKeyDown(isRepeat: false), at: 0), "⌘Q is used up, so the Quit command doesn't see it")
		deciding = false
		#expect(delegate.quitGate.handle(.quitKeyDown(isRepeat: false), at: 1))
		#expect(try await waitUntil { terminations > 0 })
		#expect(terminations == 1)
	}

	@Test("logging out, restarting, shutting down and quitting every app end the session; the Dock's Quit and an update's don't",
		arguments: [(OSType(kAEReallyLogOut), true), (OSType(kAERestart), true), (OSType(kAEShutDown), true), (OSType(kAEQuitAll), true), (nil, false)])
	func sessionEnding(reason: OSType?, ends: Bool) {
		let quit = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEQuitApplication),
			targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
		if let reason { quit.setParam(NSAppleEventDescriptor(enumCode: reason), forKeyword: AEKeyword(kAEQuitReason)) }
		#expect(AppDelegate.isSessionEnding(quit) == ends)
		#expect(!AppDelegate.isSessionEnding(nil), "Quitting from the menu has no Apple event")
		let open = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEReopenApplication),
			targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
		open.setParam(NSAppleEventDescriptor(enumCode: OSType(kAEReallyLogOut)), forKeyword: AEKeyword(kAEQuitReason))
		#expect(!AppDelegate.isSessionEnding(open), "Only a quit ends the session")
	}

	@Test("closing the main window locks the vault, whatever other window stays open")
	func mainWindowCloseLocks() {
		let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled, .closable], backing: .buffered, defer: true)
		window.isReleasedWhenClosed = false
		let settings = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
		settings.isReleasedWhenClosed = false
		let previous = (VaultMainWindow.current, VaultMainWindow.onClose)
		defer {
			settings.close()
			VaultMainWindow.current = previous.0
			VaultMainWindow.onClose = previous.1
		}
		var closes = 0
		VaultMainWindow.onClose = { closes += 1 }
		VaultMainWindow.current = window
		settings.orderBack(nil)
		window.orderBack(nil)
		settings.close()
		#expect(closes == 0)
		window.close()
		#expect(closes == 1)
	}

	@Test("clicking the Dock icon opens the main window when it's closed, even with Settings open")
	func reopenOpensMainWindow() {
		let delegate = AppDelegate()
		var opened = 0
		delegate.openWindow = { opened += 1 }
		let previous = VaultMainWindow.current
		defer { VaultMainWindow.current = previous }
		VaultMainWindow.current = nil
		#expect(delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: true))
		#expect(opened == 1, "Settings being visible doesn't stand in for the main window")
		let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
		window.isReleasedWhenClosed = false
		defer { window.close() }
		VaultMainWindow.current = window
		window.orderBack(nil)
		#expect(delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: true))
		#expect(opened == 1)
	}
}

@Suite("Quit hint placement")
@MainActor
struct VaultQuitHUDPlacementTests {
	private let size = NSSize(width: 240, height: 84)
	private let screen = NSRect(x: 0, y: 25, width: 1440, height: 875)

	@Test("the hint is centered 44 points above the bottom of the window")
	func aboveWindow() {
		let frame = VaultQuitHUDController.frame(for: size, anchor: NSRect(x: 100, y: 100, width: 1000, height: 700), screen: screen)
		#expect(frame.midX == 600)
		#expect(frame.minY + VaultQuitHUDController.shadowMargin == 144)
	}

	@Test("a window partly off the screen, or across two, keeps the hint on the screen it's on",
		arguments: [NSRect(x: -900, y: -500, width: 1000, height: 700), NSRect(x: 1200, y: 200, width: 1000, height: 700)])
	func staysOnScreen(anchor: NSRect) {
		let frame = VaultQuitHUDController.frame(for: size, anchor: anchor, screen: screen)
		let drawn = frame.insetBy(dx: VaultQuitHUDController.shadowMargin, dy: VaultQuitHUDController.shadowMargin)
		#expect(screen.contains(drawn), "\(drawn) is outside \(screen)")
	}

	@Test("with no window, the hint sits at the bottom of the screen")
	func noWindow() {
		let frame = VaultQuitHUDController.frame(for: size, anchor: nil, screen: screen)
		#expect(frame.midX == screen.midX)
		#expect(frame.minY + VaultQuitHUDController.shadowMargin == screen.minY + VaultQuitHUDController.bottomInset)
	}
}

extension SheetInteractionTests {
	/// AppKit's run loop, as quitting waits on it; in the UI suite, so no other
	/// test's nested run loops interleave with it.
	@Suite("Quitting from the shortcut's timer")
	@MainActor
	struct QuitShortcutRunLoopTests {
		@MainActor
		final class TerminationWait {
			var answered = false
			/// Whether the answer came while AppKit waited, once the wait is over.
			var answeredWhileWaiting: Bool?
		}

		@Test("a quit the gate's timer decides leaves room for the main-actor work that answers it, as AppKit's wait needs")
		func shortcutQuitsOutsideTheMainQueue() async throws {
			// The application makes its modal waits part of the run loop's common modes, as in the app.
			_ = NSApplication.shared
			UITestSuite.require()
			let delegate = AppDelegate()
			delegate.quitShortcut = { .direct }
			let wait = TerminationWait()
			delegate.terminate = {
				// AppKit waits for a later answer in a modal run loop, and the answer comes from main-actor work.
				Task { @MainActor in wait.answered = true }
				let deadline = Date(timeIntervalSinceNow: testWaitSeconds)
				while !wait.answered, Date() < deadline {
					_ = RunLoop.current.run(mode: .modalPanel, before: Date(timeIntervalSinceNow: 0.01))
				}
				wait.answeredWhileWaiting = wait.answered
			}
			// The gate's timers run as blocks on the main queue.
			DispatchQueue.main.async { delegate.quitGate.handle(.quitKeyDown(isRepeat: false), at: 0) }
			// The test resumes on the main queue, which AppKit's wait drains, so it can resume inside the wait.
			#expect(try await waitUntil { wait.answeredWhileWaiting != nil })
			#expect(wait.answeredWhileWaiting == true, "Main-actor work runs while AppKit waits for the answer")
		}
	}
}
