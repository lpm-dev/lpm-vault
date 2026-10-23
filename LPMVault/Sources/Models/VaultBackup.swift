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

/// A restored project whose sync stays paused because the backup didn't
/// carry its keys, with the binding the backup recorded for recovering them.
/// Pushing or pulling it now would encrypt with keys lpm.dev doesn't know, or
/// fail to read what it holds.
struct VaultSyncPause: Codable, Equatable, Sendable {
	static let defaultsKey = "lpm-vault-sync-paused"

	let registry: String
	/// "personal" or "organization".
	let scope: String
	let principalId: String
	let orgSlug: String?
	let restoredAt: Date

	init(_ sync: BackupPayload.Sync, restoredAt: Date) {
		registry = sync.registry
		principalId = sync.principalId
		switch sync.scope {
		case .personal:
			scope = "personal"
			orgSlug = nil
		case .organization(let slug):
			scope = "organization"
			orgSlug = slug
		}
		self.restoredAt = restoredAt
	}

	static func load(from defaults: UserDefaults) -> [String: VaultSyncPause] {
		guard let data = defaults.data(forKey: defaultsKey),
			let pauses = try? JSONDecoder().decode([String: VaultSyncPause].self, from: data)
		else { return [:] }
		return pauses.filter { EnvValidation.isSafeVaultId($0.key) }
	}

	static func save(_ pauses: [String: VaultSyncPause], to defaults: UserDefaults) {
		if pauses.isEmpty {
			defaults.removeObject(forKey: defaultsKey)
		} else if let data = try? JSONEncoder().encode(pauses) {
			defaults.set(data, forKey: defaultsKey)
		}
	}
}

/// A backup opened for review: the file it came from and the plan for
/// restoring it on this Mac, which holds only for the session it was opened in.
struct BackupRestoreReview: Sendable {
	let fileName: String
	let fileBytes: Int
	let fileModified: Date
	let plan: BackupRestorePlan
	let sessionGeneration: Int
}

/// The person's choices in a restore review.
struct BackupRestoreChoices: Equatable, Sendable {
	/// The projects to restore, by vault ID.
	var included: Set<String>
	/// The folder each new project links, by vault ID; one with none needs a folder later.
	var folders: [String: String] = [:]
	/// The keys whose backup value replaces this Mac's, by vault ID.
	var replacing: [String: Set<BackupRestorePlan.KeyDifference>] = [:]
	var applySettings: Bool

	/// Every project that can be restored except those the backup's Mac had
	/// removed from its sidebar; settings only on a Mac with no projects yet,
	/// since they'd replace this Mac's.
	static func defaults(for plan: BackupRestorePlan, hasLocalProjects: Bool) -> Self {
		let included = plan.projects.filter { project in
			switch project.status {
			case .new: !project.backup.hidden
			case .merge, .identical: true
			case .unusable: false
			}
		}.map(\.id)
		return Self(included: Set(included), applySettings: !hasLocalProjects && plan.contents.app?.settings != nil)
	}
}

/// What restoring did to one project.
enum BackupRestoreOutcome: Equatable, Sendable {
	case restored(keys: Int, environments: Int, needsFolder: Bool)
	case merged(added: Int, replaced: Int)
	case identical
	case notChosen
	case unusable(reason: String)
	/// The project changed on this Mac after the review read it, so nothing was written.
	case changedSinceReview
	case failed(String)
}

struct BackupRestoreResult: Sendable {
	struct Item: Equatable, Sendable {
		let vaultId: String
		let name: String
		let outcome: BackupRestoreOutcome
	}

	let items: [Item]
	let destinations: Int
	/// The backup's settings, when the person chose to use them, for the app
	/// settings the store doesn't own.
	let settings: BackupAppSection.Settings?
}

/// Why a backup couldn't be opened for review.
enum BackupRestoreFailure: Error, Equatable, Sendable {
	case file(BackupFileReader.Failure)
	case engine(BackupEngine.Failure)
	case contents(BackupContents.DecodingError)
	case unreadableProjects

	var message: String {
		switch self {
		case .file(let failure): failure.message
		case .engine(let failure): failure.message
		case .contents(.newerApp): "A newer LPM Vault made this backup. Update LPM Vault to restore it."
		case .contents(.unreadable): "This backup opened, but LPM Vault can’t read what it holds."
		case .unreadableProjects: "Your env projects on this Mac couldn’t be read to compare. Try again."
		}
	}
}
