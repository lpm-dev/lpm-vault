import Foundation
import Testing

@testable import LPMVault

@Suite("Backup passphrase meter")
@MainActor
struct BackupPassphraseMeterTests {
	/// Estimates as the engine would, recording each text and holding the
	/// texts in `held` until the test releases them.
	private final class Engine: @unchecked Sendable {
		private let lock = NSLock()
		private var texts: [String] = []
		private let release = DispatchSemaphore(value: 0)
		let held: Set<String>

		init(holding held: Set<String> = []) {
			self.held = held
		}

		var estimated: [String] { lock.withLock { texts } }

		func open() { release.signal() }

		func estimate(_ text: String) -> Result<BackupEngine.Strength, BackupEngine.Failure> {
			lock.withLock { texts.append(text) }
			if held.contains(text) { release.wait() }
			let strong = text.count >= 20
			return .success(.init(guessesLog10: strong ? 20 : 9.05, acceptable: strong, minimumGuessesLog10: 18.1))
		}
	}

	@Test("while an estimate runs, only the latest text waits, and its estimate is the one shown")
	func latestWins() async throws {
		let engine = Engine(holding: ["a"])
		let meter = BackupPassphraseMeter(estimate: engine.estimate)
		meter.update("a")
		#expect(try await waitUntil { engine.estimated == ["a"] })
		meter.update("ab")
		meter.update("abc")
		meter.update("a strong enough phrase")
		engine.open()
		#expect(try await waitUntil { meter.level == .strong })
		#expect(engine.estimated == ["a", "a strong enough phrase"], "Texts replaced while one ran are never estimated")
		#expect(meter.estimates == 2)
	}

	@Test("text whose first 100 characters, once normalized, don't change isn't estimated again")
	func samePrefix() async throws {
		let engine = Engine()
		let meter = BackupPassphraseMeter(estimate: engine.estimate)
		let prefix = String(repeating: "x", count: 99)
		meter.update(prefix + "e\u{301}")
		#expect(try await waitUntil { meter.level == .strong })
		meter.update(prefix + "é")
		meter.update(prefix + "é and more after the hundredth character")
		#expect(BackupPassphraseMeter.key(prefix + "e\u{301}") == BackupPassphraseMeter.key(prefix + "é tail"))
		meter.update("short")
		#expect(try await waitUntil { meter.level == .weak(segments: 2) })
		#expect(engine.estimated == [prefix + "e\u{301}", "short"])
	}

	@Test("emptying the field clears the level, and an estimate finishing after doesn't bring it back")
	func emptied() async throws {
		let engine = Engine(holding: ["password123"])
		let meter = BackupPassphraseMeter(estimate: engine.estimate)
		meter.update("password123")
		#expect(try await waitUntil { engine.estimated.count == 1 })
		meter.update("")
		engine.open()
		#expect(try await waitUntil { meter.estimates == 1 })
		#expect(meter.level == nil)
	}

	@Test("levels follow how far an estimate is from the floor")
	func levels() {
		func level(_ guesses: Double, _ acceptable: Bool = false) -> BackupPassphraseMeter.Level {
			BackupPassphraseMeter.level(.init(guessesLog10: guesses, acceptable: acceptable, minimumGuessesLog10: 18.1))
		}
		#expect(level(0) == .weak(segments: 1))
		#expect(level(9.05) == .weak(segments: 2))
		#expect(level(18) == .weak(segments: 3))
		#expect(level(18.1, true) == .strong)
	}
}
