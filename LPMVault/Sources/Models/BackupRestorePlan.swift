import Foundation

/// What an opened backup holds, read once from the payload the engine
/// checked, into values the restore review and apply use as they are.
struct BackupContents: Sendable {
	struct Project: Equatable, Sendable {
		let vaultId: String
		let name: String
		let folder: String?
		/// Removed from the sidebar on the Mac the backup came from.
		let hidden: Bool
		let cliAccess: VaultCliAccess
		let environments: [String: [String: String]]
		let sync: BackupPayload.Sync?
	}

	enum DecodingError: Error, Equatable, Sendable {
		case unreadable
		/// LPM Vault's own section was written by a newer LPM Vault.
		case newerApp
	}

	let createdAt: Date
	let producerName: String
	let producerVersion: String
	let deviceName: String?
	let projects: [Project]
	let app: BackupAppSection?

	/// The payload's contents. The engine already checked it, so a payload
	/// that doesn't read is one this version and that engine disagree on.
	static func decode(_ payload: SecretBytes) throws(DecodingError) -> BackupContents {
		let json: LPMConfigJSON
		do {
			json = try payload.withUnsafeBytes { bytes in
				guard let base = bytes.baseAddress else { throw DecodingError.unreadable }
				let data = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: base), count: bytes.count, deallocator: .none)
				return try LPMConfigJSON(parsing: data, rejectDuplicateKeys: true)
			}
		} catch {
			throw .unreadable
		}
		guard case .number(let created)? = json["createdAt"], let seconds = Int64(created), seconds >= 0,
			case .string(let producerName)? = json["producer"]?["name"],
			case .string(let producerVersion)? = json["producer"]?["version"],
			case .array(let items)? = json["projects"]
		else { throw .unreadable }
		var deviceName: String?
		if case .string(let name)? = json["deviceName"] { deviceName = name }
		var projects: [Project] = []
		projects.reserveCapacity(items.count)
		for item in items { projects.append(try project(item)) }
		var app: BackupAppSection?
		if let section = json["app"], section != .null {
			do { app = try BackupAppSection(json: section) }
			catch .newerVersion { throw .newerApp }
			catch { throw .unreadable }
		}
		return BackupContents(
			createdAt: Date(timeIntervalSince1970: TimeInterval(seconds)), producerName: producerName,
			producerVersion: producerVersion, deviceName: deviceName, projects: projects, app: app)
	}

	private static func project(_ json: LPMConfigJSON) throws(DecodingError) -> Project {
		guard case .string(let vaultId)? = json["vaultId"], case .string(let name)? = json["name"],
			case .bool(let hidden)? = json["hidden"], case .string(let access)? = json["cliAccess"],
			case .object(let environmentMembers)? = json["environments"]
		else { throw .unreadable }
		var folder: String?
		if case .string(let path)? = json["folder"] { folder = path }
		var environments: [String: [String: String]] = [:]
		for environment in environmentMembers {
			guard case .object(let variables) = environment.value else { throw .unreadable }
			var values: [String: String] = [:]
			values.reserveCapacity(variables.count)
			for variable in variables {
				guard case .string(let value) = variable.value else { throw .unreadable }
				values[variable.key] = value
			}
			environments[environment.key] = values
		}
		return Project(
			vaultId: vaultId, name: name, folder: folder, hidden: hidden,
			cliAccess: access == "automatic" ? .automatic : .requireApproval,
			environments: environments.isEmpty ? ["default": [:]] : environments,
			sync: try sync(json["sync"]))
	}

	private static func sync(_ json: LPMConfigJSON?) throws(DecodingError) -> BackupPayload.Sync? {
		guard let json, json != .null else { return nil }
		guard case .string(let registry)? = json["registry"], case .string(let scope)? = json["scope"],
			case .string(let principal)? = json["principalId"]
		else { throw .unreadable }
		switch scope {
		case "personal":
			return .init(registry: registry, principalId: principal, scope: .personal)
		case "organization":
			guard case .string(let slug)? = json["orgSlug"] else { throw .unreadable }
			return .init(registry: registry, principalId: principal, scope: .organization(slug: slug))
		default:
			throw .unreadable
		}
	}
}

/// What restoring a backup would do on this Mac, project by project, and the
/// choices the person makes in the review. Nothing it describes is written
/// until the person restores.
struct BackupRestorePlan: Sendable {
	/// A key whose value differs between the backup and this Mac. The values
	/// themselves stay out of the review.
	struct KeyDifference: Hashable, Sendable {
		let environment: String
		let key: String
	}

	enum Status: Equatable, Sendable {
		/// Not on this Mac.
		case new
		/// On this Mac with the same values.
		case identical
		/// On this Mac: `added` keys only the backup has, `differing` keys whose values differ.
		case merge(added: Int, differing: [KeyDifference])
		/// It can't be restored here, for `reason`.
		case unusable(reason: String)
	}

	struct Project: Identifiable, Sendable {
		let backup: BackupContents.Project
		let status: Status
		/// This Mac's values for a project already here.
		let local: [String: [String: String]]?
		/// This Mac's name for it, while the sidebar lists it here.
		let localName: String?

		var id: String { backup.vaultId }
		var keyCount: Int { backup.environments.values.reduce(0) { $0 + $1.count } }
	}

	let contents: BackupContents
	let projects: [Project]

	/// The plan for `contents` on a Mac that holds `local`.
	static func make(_ contents: BackupContents, local: VaultBackupInventory) -> BackupRestorePlan {
		let here = Dictionary(uniqueKeysWithValues: local.projects.map { ($0.vaultId, $0) })
		let projects = contents.projects.map { backup -> Project in
			if let reason = unusableReason(backup) {
				return Project(backup: backup, status: .unusable(reason: reason), local: nil, localName: nil)
			}
			guard let existing = here[backup.vaultId] else {
				return Project(backup: backup, status: .new, local: nil, localName: nil)
			}
			return Project(
				backup: backup, status: status(backup.environments, against: existing.environments),
				local: existing.environments, localName: existing.listing?.name)
		}
		return BackupRestorePlan(contents: contents, projects: projects)
	}

	/// Why LPM Vault can't keep this project as the backup holds it, if it can't.
	static func unusableReason(_ project: BackupContents.Project) -> String? {
		guard EnvValidation.isSafeVaultId(project.vaultId) else { return "Its ID isn’t one LPM Vault can use." }
		guard EnvValidation.areValidEnvironments(project.environments) else { return "It holds a name LPM Vault doesn’t accept." }
		return nil
	}

	static func status(_ backup: [String: [String: String]], against local: [String: [String: String]]) -> Status {
		var added = 0
		var differing: [KeyDifference] = []
		for environment in backup.keys.sorted() {
			let values = backup[environment] ?? [:]
			let mine = local[environment]
			for key in values.keys.sorted() {
				switch mine?[key] {
				case nil: added += 1
				case values[key]: continue
				default: differing.append(KeyDifference(environment: environment, key: key))
				}
			}
		}
		let newEnvironments = backup.keys.contains { local[$0] == nil }
		if added == 0, differing.isEmpty, !newEnvironments { return .identical }
		return .merge(added: added, differing: differing)
	}

	/// A project's values once merged: this Mac's, with the keys and
	/// environments only the backup has, and the backup's value for each key
	/// in `replacing`.
	static func merged(
		_ backup: [String: [String: String]], into local: [String: [String: String]], replacing: Set<KeyDifference>
	) -> [String: [String: String]] {
		var merged = local
		for (environment, values) in backup {
			var target = merged[environment] ?? [:]
			for (key, value) in values {
				if target[key] == nil || replacing.contains(KeyDifference(environment: environment, key: key)) {
					target[key] = value
				}
			}
			merged[environment] = target
		}
		return merged
	}
}
