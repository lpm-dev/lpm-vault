import Foundation

enum RelativeTimestampFormatter {
	static func string(fromRFC3339 value: String, now: Date = Date()) -> String {
		guard let date = AuthSessionTimestamp.parse(value) else { return value }
		let seconds = max(0, Int(now.timeIntervalSince(date)))
		if seconds < 60 { return "just now" }
		let minutes = seconds / 60
		if minutes < 60 { return "\(minutes)m ago" }
		let hours = minutes / 60
		if hours < 24 { return "\(hours)h ago" }
		return "\(hours / 24)d ago"
	}
}
