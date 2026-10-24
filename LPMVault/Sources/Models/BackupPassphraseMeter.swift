import Foundation
import Observation

/// How strong a typed backup passphrase is, as the engine estimates it.
/// Estimates run off the main actor one at a time; typing while one runs
/// queues only the latest text, and a result is shown only when no newer text
/// waits. The engine reads only the first 100 characters once normalized, so
/// text that keeps them asks nothing new.
@Observable
@MainActor
final class BackupPassphraseMeter {
	enum Level: Equatable, Sendable {
		/// Below the floor a backup needs, with how far along it is, from 1 to 3 of 4.
		case weak(segments: Int)
		case strong
	}

	/// The latest estimate's level, or nil while there's none for the text.
	private(set) var level: Level?
	/// How many estimates the engine has made, for tests.
	@ObservationIgnored private(set) var estimates = 0

	@ObservationIgnored private let estimate: @Sendable (String) -> Result<BackupEngine.Strength, BackupEngine.Failure>
	@ObservationIgnored private var estimatedKey: String?
	@ObservationIgnored private var pending: String?
	@ObservationIgnored private var running = false
	@ObservationIgnored private var generation = 0

	init(estimate: @escaping @Sendable (String) -> Result<BackupEngine.Strength, BackupEngine.Failure> = BackupEngine.strength(of:)) {
		self.estimate = estimate
	}

	/// The part of `passphrase` the engine reads.
	nonisolated static func key(_ passphrase: String) -> String {
		var key = String.UnicodeScalarView()
		key.append(contentsOf: passphrase.precomposedStringWithCanonicalMapping.unicodeScalars.prefix(100))
		return String(key)
	}

	func update(_ passphrase: String) {
		let key = Self.key(passphrase)
		guard key != estimatedKey || pending != nil else { return }
		generation &+= 1
		guard !passphrase.isEmpty else {
			estimatedKey = key
			pending = nil
			level = nil
			return
		}
		if key == estimatedKey {
			pending = nil
			return
		}
		pending = passphrase
		guard !running else { return }
		runNext()
	}

	/// Forgets the text and any estimate of it, as when the passphrase is
	/// replaced by a generated one or the sheet closes.
	func reset() {
		generation &+= 1
		pending = nil
		estimatedKey = nil
		level = nil
	}

	private func runNext() {
		guard let passphrase = pending else {
			running = false
			return
		}
		pending = nil
		running = true
		let generation = generation
		let estimate = estimate
		Task {
			let result = await BlockingWork.run { estimate(passphrase) }
			self.estimates += 1
			if self.pending == nil, generation == self.generation {
				self.estimatedKey = Self.key(passphrase)
				self.level = (try? result.get()).map(Self.level)
			}
			self.runNext()
		}
	}

	nonisolated static func level(_ strength: BackupEngine.Strength) -> Level {
		guard !strength.acceptable else { return .strong }
		let progress = strength.guessesLog10 / max(strength.minimumGuessesLog10, 1)
		return .weak(segments: min(3, max(1, Int(progress * 4))))
	}
}
