import Foundation

/// When the monthly backup reminder shows: a month after the last backup,
/// or, on a Mac that has never made one, a month after LPM Vault first saw
/// it hold a project; a week after the person puts it off.
enum VaultBackupReminder {
	static let interval: TimeInterval = 30 * 86_400
	static let postponement: TimeInterval = 7 * 86_400
	static let startedKey = "lpm-vault-backup-reminder-started"
	static let postponedKey = "lpm-vault-backup-reminder-postponed"

	static func isDue(now: Date, lastBackup: Date?, started: Date?, postponedUntil: Date?) -> Bool {
		if let postponedUntil, now < postponedUntil { return false }
		guard let since = lastBackup ?? started else { return false }
		return now.timeIntervalSince(since) >= interval
	}

	/// What the reminder says about the last backup.
	static func detail(lastBackup: Date?, now: Date) -> String {
		guard let lastBackup else { return "This Mac has no backup of your projects yet." }
		let days = max(1, Int(now.timeIntervalSince(lastBackup) / 86_400))
		return "Your last backup was \(days.counted("day")) ago."
	}
}
