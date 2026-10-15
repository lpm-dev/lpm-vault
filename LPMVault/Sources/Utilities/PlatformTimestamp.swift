import Foundation

/// Times platforms send in their API answers.
enum PlatformTimestamp {
	/// An ISO 8601 time in UTC, such as Laravel's `2026-10-14T12:34:56.123456Z`
	/// or Netlify's `2026-10-14T12:34:56.123Z`, with a `T` or a space before the
	/// time and `Z` or `+00:00` after it. Anything else reads as nil.
	static func utc(_ text: String) -> Date? {
		let bytes = Array(text.utf8)
		func number(_ range: Range<Int>) -> Int? {
			guard range.upperBound <= bytes.count, bytes[range].allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else { return nil }
			return bytes[range].reduce(0) { $0 * 10 + Int($1 - 0x30) }
		}
		guard bytes.count >= 20, bytes[4] == 0x2D, bytes[7] == 0x2D, bytes[10] == 0x54 || bytes[10] == 0x20,
			bytes[13] == 0x3A, bytes[16] == 0x3A,
			let year = number(0..<4), let month = number(5..<7), let day = number(8..<10),
			let hour = number(11..<13), let minute = number(14..<16), let second = number(17..<19)
		else { return nil }
		var index = 19
		var fraction = 0.0
		if bytes[index] == 0x2E {
			index += 1
			var scale = 0.1
			let start = index
			while index < bytes.count, bytes[index] >= 0x30, bytes[index] <= 0x39 {
				fraction += Double(bytes[index] - 0x30) * scale
				scale /= 10
				index += 1
			}
			guard index > start else { return nil }
		}
		guard bytes[index...].elementsEqual("Z".utf8) || bytes[index...].elementsEqual("+00:00".utf8) else { return nil }
		let components = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
		guard components.isValidDate(in: utcCalendar), let date = utcCalendar.date(from: components) else { return nil }
		return date.addingTimeInterval(fraction)
	}

	private static let utcCalendar: Calendar = {
		var calendar = Calendar(identifier: .gregorian)
		calendar.timeZone = TimeZone(identifier: "UTC")!
		return calendar
	}()
}
