import Foundation

/// The person's go-ahead to export a backup, from authenticating as they
/// asked to. It holds only while the session it was given in stays unlocked.
struct BackupExportAuthorization: Sendable {
	let sessionGeneration: Int
}

/// A backup just saved.
struct BackupExportResult: Equatable, Sendable {
	let file: URL
	let bytes: Int
	let summary: BackupExporter.Summary
}

/// When the last backup was made and how large it was, which Settings shows.
struct VaultBackupRecord: Codable, Equatable, Sendable {
	static let defaultsKey = "lpm-vault-last-backup"

	let date: Date
	let bytes: Int

	init(date: Date, bytes: Int) {
		self.date = date
		self.bytes = bytes
	}

	init?(defaults: UserDefaults) {
		guard let data = defaults.data(forKey: Self.defaultsKey),
			let record = try? JSONDecoder().decode(Self.self, from: data),
			record.bytes > 0, record.date.timeIntervalSinceReferenceDate.isFinite
		else { return nil }
		self = record
	}

	func save(to defaults: UserDefaults) {
		guard let data = try? JSONEncoder().encode(self) else { return }
		defaults.set(data, forKey: Self.defaultsKey)
	}
}
