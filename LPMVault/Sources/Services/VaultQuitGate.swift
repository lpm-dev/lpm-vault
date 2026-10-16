import AppKit

/// What ⌘Q, and the keys and clicks around it, mean for quitting.
///
/// Direct quits at once. Double press shows a hint and quits on a second
/// press within two seconds. Hold quits once ⌘Q has been held for a second
/// and let go, or on a second press within half a second. A held key's
/// repeats are never another press. Any other key, a click, or leaving the
/// app cancels, and Esc is used up doing so. While quitting is already being
/// decided, ⌘Q does nothing.
///
/// macOS sends no key-up for Q while ⌘ is down, so a hold is proven by a
/// repeat that comes once the hold's time is up, and a finished hold quits
/// only once the repeats stop: quitting while the key still repeats would
/// send ⌘Q to the app that comes forward. With key repeat off nothing can
/// prove a hold, so Hold takes two presses instead.
@MainActor
final class VaultQuitGate {
	enum Hint: Equatable {
		case pressAgain
		case hold(TimeInterval)
	}

	/// An input the gate acts on.
	enum Input: Equatable {
		case quitKeyDown(isRepeat: Bool)
		case quitKeyUp
		case commandReleased
		case otherKey(isEscape: Bool)
		case pointer
	}

	struct Timing: Sendable {
		var doublePressWindow: TimeInterval = 2
		var quickPressWindow: TimeInterval = 0.5
		var holdDuration: TimeInterval = 1
		/// How long a finished hold waits after the last repeat before quitting.
		var releaseGrace: TimeInterval = 0.6
		/// The longest repeat delay a hold waits for; longer means key repeat is off.
		var longestRepeatDelay: TimeInterval = 3
	}

	typealias Schedule = @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> () -> Void

	private let timing: Timing
	private let mode: () -> VaultQuitShortcut
	/// Whether the app is already deciding whether to quit, with its sheet up.
	private let isDeciding: () -> Bool
	private let now: () -> TimeInterval
	/// How long a held key waits before it starts repeating, as set in System Settings.
	private let keyRepeatDelay: () -> TimeInterval
	/// How often a held key repeats once it has started, as set in System Settings.
	private let keyRepeatInterval: () -> TimeInterval
	private let schedule: Schedule
	private let quit: () -> Void
	private let showHint: (Hint) -> Void
	private let hideHint: () -> Void

	private(set) var hint: Hint?
	private var lastPressAt: TimeInterval?
	private var heldSince: TimeInterval?
	private var lastRepeatAt: TimeInterval?
	private var repeatCadence: TimeInterval = 0
	private var quitsOnRelease = false
	private var timers: [String: () -> Void] = [:]

	init(
		timing: Timing = Timing(),
		mode: @escaping () -> VaultQuitShortcut,
		isDeciding: @escaping () -> Bool = { false },
		now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
		keyRepeatDelay: @escaping () -> TimeInterval = { NSEvent.keyRepeatDelay },
		keyRepeatInterval: @escaping () -> TimeInterval = { NSEvent.keyRepeatInterval },
		schedule: @escaping Schedule = VaultQuitGate.dispatchAfter,
		quit: @escaping () -> Void,
		showHint: @escaping (Hint) -> Void,
		hideHint: @escaping () -> Void
	) {
		self.timing = timing
		self.mode = mode
		self.isDeciding = isDeciding
		self.now = now
		self.keyRepeatDelay = keyRepeatDelay
		self.keyRepeatInterval = keyRepeatInterval
		self.schedule = schedule
		self.quit = quit
		self.showHint = showHint
		self.hideHint = hideHint
	}

	/// The input `event` is, if the gate acts on it.
	static func input(for event: NSEvent) -> Input? {
		switch event.type {
		case .keyDown:
			if isQuitKey(event) { return .quitKeyDown(isRepeat: event.isARepeat) }
			return .otherKey(isEscape: event.keyCode == 53)
		case .keyUp:
			return event.charactersIgnoringModifiers?.lowercased() == "q" ? .quitKeyUp : nil
		case .flagsChanged:
			return event.modifierFlags.contains(.command) ? nil : .commandReleased
		case .leftMouseDown, .rightMouseDown, .otherMouseDown:
			return .pointer
		default:
			return nil
		}
	}

	/// ⌘Q alone, as the Quit menu item takes it, whatever the keyboard layout.
	static func isQuitKey(_ event: NSEvent) -> Bool {
		event.modifierFlags.intersection([.command, .option, .control, .shift]) == .command
			&& event.charactersIgnoringModifiers?.lowercased() == "q"
	}

	/// Acts on `input` at `time`, in seconds since startup like an event's
	/// timestamp; returns whether the input is used up.
	@discardableResult
	func handle(_ input: Input, at time: TimeInterval) -> Bool {
		if isDeciding() {
			cancel()
			if case .quitKeyDown = input { return true }
			return false
		}
		switch input {
		case .quitKeyDown(let isRepeat):
			return quitKeyDown(isRepeat: isRepeat, at: time)
		case .quitKeyUp:
			if quitsOnRelease {
				quitNow()
			} else if heldSince != nil {
				releaseHold()
			}
			return false
		case .commandReleased:
			if quitsOnRelease {
				quitAfterRepeatsStop()
			} else if heldSince != nil {
				releaseHold()
			}
			return false
		case .otherKey(let isEscape):
			guard isActive else { return false }
			cancel()
			return isEscape
		case .pointer:
			cancel()
			return false
		}
	}

	/// Stops waiting for a second press or a hold, as leaving the app does.
	func cancel() {
		guard isActive else { return }
		reset()
	}

	private var isActive: Bool { hint != nil || lastPressAt != nil || heldSince != nil || quitsOnRelease }

	private func quitKeyDown(isRepeat: Bool, at time: TimeInterval) -> Bool {
		if isRepeat {
			noteRepeat(at: time)
			if quitsOnRelease {
				quitAfterRepeatsStop()
			} else if let heldSince {
				if time - heldSince >= timing.holdDuration {
					finishHold()
				} else {
					// Repeats that stop before the hold is long enough mean the key was let go.
					start("released", after: heldGap) { [weak self] in self?.releaseHold() }
				}
			}
			return true
		}
		if quitsOnRelease { return true }
		let mode = mode()
		if mode == .direct {
			quitNow()
			return true
		}
		let holds = mode == .hold && keyRepeatDelay() <= timing.longestRepeatDelay
		let window = holds ? timing.quickPressWindow : timing.doublePressWindow
		if let lastPressAt, time - lastPressAt <= window {
			quitNow()
			return true
		}
		reset()
		lastPressAt = time
		if holds {
			heldSince = time
			show(.hold(provenHoldDuration))
			start("hold", after: timing.holdDuration) { [weak self] in self?.holdElapsed() }
			start("press", after: timing.quickPressWindow) { [weak self] in self?.lastPressAt = nil }
		} else {
			show(.pressAgain)
			start("press", after: timing.doublePressWindow) { [weak self] in self?.reset() }
		}
		return true
	}

	/// When the first repeat that can prove a hold comes: the first once the
	/// hold's time is up, which a long repeat delay puts later.
	private var provenHoldDuration: TimeInterval {
		let delay = keyRepeatDelay(), interval = max(keyRepeatInterval(), 0.001)
		guard delay < timing.holdDuration else { return delay }
		return delay + ((timing.holdDuration - delay) / interval - 0.000_001).rounded(.up) * interval
	}

	/// The first repeat comes after the system's initial delay, so the
	/// cadence is measured between repeats.
	private func noteRepeat(at time: TimeInterval) {
		if let lastRepeatAt { repeatCadence = max(0, time - lastRepeatAt) }
		lastRepeatAt = time
	}

	/// The longest gap between repeats of a key that's still held.
	private var heldGap: TimeInterval { max(2 * max(repeatCadence, keyRepeatInterval()), 0.1) }

	/// The hold's time is up: a repeat from now on finishes it. Until one comes,
	/// it waits for as long as the key could still be held: one gap between
	/// repeats, or before its first repeat, the system's repeat delay.
	private func holdElapsed() {
		guard let heldSince else { return }
		let time = now()
		if let lastRepeatAt {
			start("released", after: max(0, lastRepeatAt + heldGap - time)) { [weak self] in self?.releaseHold() }
			return
		}
		let firstRepeatDeadline = heldSince + keyRepeatDelay() + timing.releaseGrace
		guard time < firstRepeatDeadline else {
			releaseHold()
			return
		}
		start("hold", after: firstRepeatDeadline - time) { [weak self] in
			guard let self, self.heldSince != nil else { return }
			if self.lastRepeatAt == nil { self.releaseHold() } else { self.holdElapsed() }
		}
	}

	private func finishHold() {
		guard !quitsOnRelease else { return }
		quitsOnRelease = true
		heldSince = nil
		cancelTimer("hold")
		cancelTimer("released")
		cancelTimer("press")
		quitAfterRepeatsStop()
	}

	/// How long a finished hold waits for another repeat before taking the key as let go.
	private var quietPeriod: TimeInterval { max(timing.releaseGrace, 2 * max(repeatCadence, keyRepeatInterval())) }

	private func quitAfterRepeatsStop() {
		start("quit", after: quietPeriod) { [weak self] in self?.quitNow() }
	}

	/// A hold let go too soon: the hint goes, and a quick second press still quits.
	private func releaseHold() {
		heldSince = nil
		lastRepeatAt = nil
		cancelTimer("hold")
		cancelTimer("released")
		if hint != nil {
			hint = nil
			hideHint()
		}
	}

	private func quitNow() {
		reset()
		quit()
	}

	private func reset() {
		for cancel in timers.values { cancel() }
		timers.removeAll()
		lastPressAt = nil
		heldSince = nil
		lastRepeatAt = nil
		repeatCadence = 0
		quitsOnRelease = false
		if hint != nil {
			hint = nil
			hideHint()
		}
	}

	private func show(_ hint: Hint) {
		self.hint = hint
		showHint(hint)
	}

	private func start(_ name: String, after delay: TimeInterval, _ work: @escaping @MainActor () -> Void) {
		timers[name]?()
		timers[name] = schedule(delay) { [weak self] in
			self?.timers[name] = nil
			work()
		}
	}

	private func cancelTimer(_ name: String) {
		timers.removeValue(forKey: name)?()
	}

	static func dispatchAfter(_ delay: TimeInterval, _ work: @escaping @MainActor () -> Void) -> () -> Void {
		let item = DispatchWorkItem { MainActor.assumeIsolated { work() } }
		DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
		return { item.cancel() }
	}
}
