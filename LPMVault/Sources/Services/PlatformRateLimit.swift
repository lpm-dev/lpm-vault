import Foundation

/// Waiting out a platform's rate limit, for platforms that say when one lifts.
enum PlatformRateLimit {
	/// How long to wait for a rate limit that lifts at `reset`, or a minute
	/// when the platform doesn't say; nil when it lifts after `maximum`.
	static func wait(until reset: Date?, maximum: Duration) -> Duration? {
		let seconds = reset?.timeIntervalSinceNow ?? 60
		// Compared as a number first: a far-off or infinite reset traps as a duration.
		guard seconds.isFinite, seconds <= Double(maximum.components.seconds) else { return nil }
		// Rounded up: a wait cut short asks again just before the limit lifts.
		return .milliseconds(Int64((max(0, seconds) * 1_000).rounded(.up)))
	}

	/// Sleeps `wait`, then on until the wall clock passes `reset`, which the
	/// sleep's own clock can run ahead of.
	static func waitOut(_ wait: Duration, until reset: Date?) async throws {
		try await Task.sleep(for: wait)
		while let left = reset?.timeIntervalSinceNow, left > 0 {
			try await Task.sleep(for: .milliseconds(Int64((left * 1_000).rounded(.up))))
		}
	}
}
