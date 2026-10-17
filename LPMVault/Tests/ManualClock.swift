import Foundation

/// A clock a test moves by hand, for code that measures the time between
/// events, such as edits made close enough together to undo as one.
final class ManualClock: @unchecked Sendable {
	private let lock = NSLock()
	private var instant = ContinuousClock.now

	var now: ContinuousClock.Instant { lock.withLock { instant } }

	func advance(by duration: Duration) {
		lock.withLock { instant += duration }
	}
}
