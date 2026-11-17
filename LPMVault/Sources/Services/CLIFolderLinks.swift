import Foundation

/// The folders on this Mac that may use a project's values through the LPM
/// CLI. A project's `lpm.json` names it by vault ID, which is committed and
/// public, so the CLI gives a folder the values only once the folder is
/// linked here. Each project keeps its own record, apart from its values and
/// readable without approval, so the CLI checks a folder without asking.
///
/// The record is the CLI's: `{"schemaVersion":1,"folders":[…]}`, with each
/// folder at its real path.
struct CLIFolderLinkRecord: Codable, Equatable, Sendable {
	static let currentSchemaVersion = 1

	let schemaVersion: Int
	/// Sorted and unique, as the CLI keeps them.
	private(set) var folders: [String]

	init(folders: some Sequence<String>) {
		schemaVersion = Self.currentSchemaVersion
		self.folders = Array(Set(folders)).sorted()
	}

	init(from decoder: any Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
		guard schemaVersion == Self.currentSchemaVersion else {
			throw DecodingError.dataCorruptedError(
				forKey: .schemaVersion, in: container,
				debugDescription: "Folder links use schema version \(schemaVersion), which LPM Vault doesn't support")
		}
		folders = Array(Set(try container.decode([String].self, forKey: .folders))).sorted()
	}

	static func decode(_ data: Data) throws -> CLIFolderLinkRecord {
		try JSONDecoder().decode(CLIFolderLinkRecord.self, from: data)
	}

	func encoded() throws -> Data {
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
		return try encoder.encode(self)
	}

	func contains(_ folder: String) -> Bool { folders.contains(folder) }

	/// Whether it added `folder`.
	@discardableResult
	mutating func insert(_ folder: String) -> Bool {
		guard !folders.contains(folder) else { return false }
		folders.append(folder)
		folders.sort()
		return true
	}

	/// Whether it removed `folder`.
	@discardableResult
	mutating func remove(_ folder: String) -> Bool {
		guard let index = folders.firstIndex(of: folder) else { return false }
		folders.remove(at: index)
		return true
	}
}

/// Where the projects' link records live.
protocol CLIFolderLinkStoring: Sendable {
	func record(vaultId: String) throws -> CLIFolderLinkRecord?
	func write(_ record: CLIFolderLinkRecord, vaultId: String) throws
	func delete(vaultId: String) throws
}

/// The records as the CLI keeps them: one item per project in the group the
/// app shares with the CLI, under the home's links service.
struct KeychainCLIFolderLinks: CLIFolderLinkStoring {
	let service: String
	private let backend: any KeychainStoreBackend & Sendable

	init(home: LPMHome, backend: any KeychainStoreBackend & Sendable = SecurityKeychainStoreBackend()) {
		service = home.service(VaultConstants.cliFolderLinksKeychainService)
		self.backend = backend
	}

	func record(vaultId: String) throws -> CLIFolderLinkRecord? {
		guard let data = try backend.read(service: service, account: vaultId) else { return nil }
		do {
			return try CLIFolderLinkRecord.decode(data)
		} catch {
			throw KeychainStoreError.status(operation: "read folder links", code: errSecDecode)
		}
	}

	func write(_ record: CLIFolderLinkRecord, vaultId: String) throws {
		try backend.write(service: service, account: vaultId, data: try record.encoded())
	}

	func delete(vaultId: String) throws {
		try backend.delete(service: service, account: vaultId)
	}
}

/// Records in memory, so tests never reach the Keychain through them.
final class MemoryCLIFolderLinks: CLIFolderLinkStoring, @unchecked Sendable {
	private let lock = NSLock()
	private var records: [String: CLIFolderLinkRecord] = [:]

	init(_ records: [String: CLIFolderLinkRecord] = [:]) {
		self.records = records
	}

	func record(vaultId: String) throws -> CLIFolderLinkRecord? {
		lock.withLock { records[vaultId] }
	}

	func write(_ record: CLIFolderLinkRecord, vaultId: String) throws {
		lock.withLock { records[vaultId] = record }
	}

	func delete(vaultId: String) throws {
		_ = lock.withLock { records.removeValue(forKey: vaultId) }
	}
}

enum CLIFolderLinks {
	/// Whether the LPM CLI lets `folder` use `vaultId`'s values, by the CLI's
	/// rule. A project without a record predates links: with no values on
	/// this Mac nothing is kept from any folder, and otherwise only the
	/// folder its metadata records, `recordedFolder`, is linked.
	static func isLinked(
		_ folder: String,
		vaultId: String,
		recordedFolder: String?,
		holdsValues: () throws -> Bool,
		in store: any CLIFolderLinkStoring
	) throws -> Bool {
		let folder = realPath(folder)
		if let record = try store.record(vaultId: vaultId) {
			return record.contains(folder)
		}
		guard try holdsValues() else { return true }
		return recordedFolder.map(realPath) == folder
	}

	/// Links `folder` to `vaultId`, and unlinks it from `previousVaultId`,
	/// whose ID its `lpm.json` no longer names. A project's first record
	/// keeps the folder its metadata records, which the CLI links on its own.
	static func link(
		_ folder: String,
		vaultId: String,
		recordedFolder: String?,
		unlinkingFrom previousVaultId: String?,
		in store: any CLIFolderLinkStoring
	) throws {
		let folder = realPath(folder)
		let existing = try store.record(vaultId: vaultId)
		var record = existing ?? CLIFolderLinkRecord(
			folders: [recordedFolder].compactMap { $0 }.filter { !$0.isEmpty }.map(realPath))
		if record.insert(folder) || existing == nil {
			try store.write(record, vaultId: vaultId)
		}
		guard let previousVaultId, previousVaultId != vaultId,
			var previous = try store.record(vaultId: previousVaultId)
		else { return }
		if previous.remove(folder) {
			try store.write(previous, vaultId: previousVaultId)
		}
	}

	/// `path` with symbolic links resolved, as the CLI keeps a folder; as
	/// given when it doesn't exist.
	static func realPath(_ path: String) -> String {
		guard let resolved = Darwin.realpath(path, nil) else { return path }
		defer { free(resolved) }
		return String(cString: resolved)
	}
}
