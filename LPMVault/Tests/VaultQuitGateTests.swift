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
	private final class Recorder {
		var quits = 0
		var hints: [VaultQuitGate.Hint?] = []
	}

	private func makeGate(_ mode: VaultQuitShortcut, keyRepeatDelay: TimeInterval = 0.5, keyRepeatInterval: TimeInterval = 0.05)
		-> (VaultQuitGate, ManualQuitClock, Recorder)
	{
		let clock = ManualQuitClock()
		let recorder = Recorder()
		let gate = VaultQuitGate(
			mode: { mode },
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
		clock.advance(by: 1.9)
		press(gate, clock)
		#expect(recorder.quits == 1)
		#expect(gate.hint == nil)
	}

	@Test("after two seconds the hint goes, and it takes two presses again")
	func doublePressTimesOut() {
		let (gate, clock, recorder) = makeGate(.doublePress)
		press(gate, clock)
		clock.advance(by: 2.05)
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
		clock.advance(by: 1.5)
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
		press(gate, clock)
		#expect(gate.hint == .hold(1))
		clock.advance(by: 0.5)
		while clock.now < 1_001 {
			press(gate, clock, repeat: true)
			clock.advance(by: 0.05)
		}
		press(gate, clock, repeat: true)
		#expect(recorder.quits == 0, "A finished hold waits for the key to be let go")
		switch release {
		case "command released":
			gate.handle(.commandReleased, at: clock.now)
			clock.advance(by: 0.59)
			#expect(recorder.quits == 0)
			clock.advance(by: 0.02)
		case "repeats stop":
			clock.advance(by: 0.61)
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
		clock.advance(by: 0.61)
		#expect(gate.hint == nil)
		clock.advance(by: 3)
		#expect(recorder.quits == 0)
	}

	@Test("a tap in Hold mode shows the hint until the repeat delay passes, then hides it")
	func holdTap() {
		let (gate, clock, recorder) = makeGate(.hold, keyRepeatDelay: 0.5)
		press(gate, clock)
		clock.advance(by: 1.05)
		#expect(gate.hint == .hold(1), "Repeats may still start")
		clock.advance(by: 0.1)
		#expect(gate.hint == nil)
		#expect(recorder.quits == 0)
	}

	@Test("a long system repeat delay still lets a hold finish once repeats start")
	func holdWithSlowRepeats() {
		let (gate, clock, recorder) = makeGate(.hold, keyRepeatDelay: 1.5)
		press(gate, clock)
		clock.advance(by: 1.5)
		press(gate, clock, repeat: true)
		clock.advance(by: 0.61)
		#expect(recorder.quits == 1)
	}

	@Test("Hold also quits on two quick presses, but not two slow ones", arguments: [(0.3, 1), (0.7, 0)])
	func holdDoublePress(sample: (TimeInterval, Int)) {
		let (gate, clock, recorder) = makeGate(.hold)
		press(gate, clock)
		gate.handle(.commandReleased, at: clock.now)
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

	@Test("every way of quitting asks the app, and the shortcut doesn't ask again while it decides")
	func delegateRoutesQuitting() {
		let delegate = AppDelegate()
		#expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateNow)
		var asked = 0
		delegate.shouldTerminate = {
			asked += 1
			return .terminateLater
		}
		#expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateLater)
		#expect(asked == 1)
	}
}
