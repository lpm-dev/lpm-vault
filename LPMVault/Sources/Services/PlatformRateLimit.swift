import Foundation

/// Waiting out a platform's rate limit, for platforms that say when one lifts.
enum PlatformRateLimit {
	/// How long to wait at `now` for a rate limit that lifts at `reset`, or a
	/// minute when the platform doesn't say; nil when it lifts after `maximum`.
	static func wait(until reset: Date?, maximum: Duration, now: Date = Date()) -> Duration? {
		let seconds = reset?.timeIntervalSince(now) ?? 60
		// Compared as a number first: a far-off or infinite reset traps as a duration.
		guard seconds.isFinite, seconds <= Double(maximum.components.seconds) else { return nil }
		// Rounded up: a wait cut short asks again just before the limit lifts.
		return .milliseconds(Int64((max(0, seconds) * 1_000).rounded(.up)))
	}

	/// When a limit the platform says resets at `reset`, in seconds since 1970
	/// on its own clock, lifts on this Mac's: as long after `now` as `reset`
	/// is after `answered`'s `Date`. Without a `Date` to measure from, a
	/// reset this Mac's clock has passed says nothing of when the limit lifts.
	static func lifts(atReset reset: TimeInterval, answered: HTTPURLResponse, now: Date) -> Date? {
		guard reset.isFinite else { return nil }
		let resets = Date(timeIntervalSince1970: reset)
		guard let sent = date(of: answered) else { return resets > now ? resets : nil }
		return now.addingTimeInterval(resets.timeIntervalSince(sent))
	}

	/// When `answer` says it was sent, from its `Date` in HTTP's form.
	static func date(of answer: HTTPURLResponse) -> Date? {
		answer.value(forHTTPHeaderField: "Date").flatMap { try? Date($0, strategy: httpDate) }
	}

	private static let httpDate = Date.ParseStrategy(
		format: """
			\(weekday: .abbreviated), \(day: .twoDigits) \(month: .abbreviated) \(year: .padded(4)) \
			\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits):\(second: .twoDigits) GMT
			""",
		locale: Locale(identifier: "en_US_POSIX"),
		timeZone: .gmt,
		isLenient: false)

	/// Sleeps `wait`, then on until the wall clock passes `reset`, which the
	/// sleep's own clock can run ahead of, but never past `limit` in all: a
	/// wall clock set back meanwhile doesn't hold the caller that much longer.
	static func waitOut(
		_ wait: Duration,
		until reset: Date?,
		atMost limit: Duration,
		date: () -> Date = { Date() },
		sleep: (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
	) async throws {
		try await sleep(wait)
		var slept = wait
		while slept < limit, let left = reset?.timeIntervalSince(date()), left > 0 {
			let more = min(.milliseconds(Int64((left * 1_000).rounded(.up))), limit - slept)
			try await sleep(more)
			slept += more
		}
	}
}
