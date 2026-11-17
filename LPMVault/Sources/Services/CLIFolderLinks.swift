import Foundation

/// The folders on this Mac that may use a project's values through the LPM
/// CLI, which uses a project's values only in folders linked to it. Each
/// project keeps its own record, apart from its values and readable without
/// approval, so the CLI checks a folder without asking.
///
/// The record is the CLI's: `{"schemaVersion":1,"folders":[…]}`, with each
/// folder at its real path. The CLI compares folders by their bytes, so
/// this does too.
struct CLIFolderLinkRecord: Codable, Equatable, Sendable {
	static let currentSchemaVersion = 1

	let schemaVersion: Int
	/// Unique and sorted by their UTF-8 bytes, as the CLI keeps them.
	private(set) var folders: [String]

	init(folders: some Sequence<String>) {
		schemaVersion = Self.currentSchemaVersion
		self.folders = Self.sortedUnique(folders)
	}

	init(from decoder: any Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
		folders = Self.sortedUnique(try container.decode([String].self, forKey: .folders))
	}

	/// The record in `data`. A field a later version adds is read past, as
	/// the CLI reads past it; a record from a later version isn't read.
	/// The version is read first, so a later version's record, whatever
	/// shape its other fields take, is never mistaken for a damaged one.
	static func decode(_ data: Data) throws(CLIFolderLinkRecordError) -> CLIFolderLinkRecord {
		struct Version: Decodable { let schemaVersion: Int }
		guard let version = try? JSONDecoder().decode(Version.self, from: data) else { throw .damaged }
		guard version.schemaVersion <= currentSchemaVersion else { throw .newerVersion }
		guard version.schemaVersion == currentSchemaVersion,
			let record = try? JSONDecoder().decode(CLIFolderLinkRecord.self, from: data)
		else { throw .damaged }
		return record
	}

	func encoded() throws -> Data {
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
		return try encoder.encode(self)
	}

	func contains(_ folder: String) -> Bool {
		folders.contains { $0.utf8.elementsEqual(folder.utf8) }
	}

	/// Whether it added `folder`.
	@discardableResult
	mutating func insert(_ folder: String) -> Bool {
		guard !contains(folder) else { return false }
		folders = Self.sortedUnique(folders + [folder])
		return true
	}

	/// Whether it removed `folder`.
	@discardableResult
	mutating func remove(_ folder: String) -> Bool {
		let before = folders.count
		folders.removeAll { $0.utf8.elementsEqual(folder.utf8) }
		return folders.count != before
	}

	private static func sortedUnique(_ folders: some Sequence<String>) -> [String] {
		var seen = Set<[UInt8]>()
		return folders
			.filter { seen.insert(Array($0.utf8)).inserted }
			.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
	}
}

enum CLIFolderLinkRecordError: Error, Equatable, Sendable {
	/// The record can't be read; linking a folder replaces it.
	case damaged
	/// A later LPM CLI or LPM Vault wrote it; it's left as it is.
	case newerVersion
}

/// Where the projects' link records live.
protocol CLIFolderLinkStoring: Sendable {
	/// The raw record, so a caller can tell a damaged one from none.
	func data(vaultId: String) throws -> Data?
	func write(_ record: CLIFolderLinkRecord, vaultId: String) throws
	func delete(vaultId: String) throws
}

extension CLIFolderLinkStoring {
	func record(vaultId: String) throws -> CLIFolderLinkRecord? {
		try data(vaultId: vaultId).map { data throws in try CLIFolderLinkRecord.decode(data) }
	}
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

	func data(vaultId: String) throws -> Data? {
		try backend.read(service: service, account: vaultId)
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
	private var stored: [String: Data] = [:]
	/// Makes writes fail, as a Keychain that refuses them would.
	var failWrites = false

	init(_ records: [String: CLIFolderLinkRecord] = [:]) {
		stored = records.compactMapValues { try? $0.encoded() }
	}

	func data(vaultId: String) throws -> Data? {
		lock.withLock { stored[vaultId] }
	}

	func setData(_ data: Data?, vaultId: String) {
		lock.withLock { stored[vaultId] = data }
	}

	func write(_ record: CLIFolderLinkRecord, vaultId: String) throws {
		let data = try record.encoded()
		try lock.withLock {
			if failWrites { throw KeychainStoreError.status(operation: "write", code: errSecNotAvailable) }
			stored[vaultId] = data
		}
	}

	func delete(vaultId: String) throws {
		_ = lock.withLock { stored.removeValue(forKey: vaultId) }
	}
}

/// What the LPM CLI knows of a project without a link record: whether this
/// Mac holds its values, and the folder its metadata records. Both are read
/// only when the project has no record.
struct CLIFolderLinkProject {
	let vaultId: String
	let holdsValues: () throws -> Bool
	/// The recorded folder at its real path; nil when there's none, or it
	/// isn't absolute.
	let recordedFolder: () -> String?
}

enum CLIFolderLinks {
	/// Whether the LPM CLI lets `folder`, a real path, use the project's
	/// values, by the CLI's rule. A project without a record predates links:
	/// with no values on this Mac nothing is kept from any folder, and
	/// otherwise only the folder its metadata records is linked.
	static func isLinked(
		_ folder: String,
		project: CLIFolderLinkProject,
		in store: any CLIFolderLinkStoring
	) throws -> Bool {
		if let decided = try decidedWithoutRecordedFolder(
			folder, vaultId: project.vaultId, holdsValues: project.holdsValues, in: store)
		{
			return decided
		}
		return isRecordedFolder(folder, project.recordedFolder())
	}

	/// The rule's answer from the project's record and whether this Mac
	/// holds its values; nil when it turns on the folder the project records.
	static func decidedWithoutRecordedFolder(
		_ folder: String,
		vaultId: String,
		holdsValues: () throws -> Bool,
		in store: any CLIFolderLinkStoring
	) throws -> Bool? {
		if let record = try store.record(vaultId: vaultId) {
			return record.contains(folder)
		}
		return try holdsValues() ? nil : true
	}

	/// Whether `folder` is `recordedFolder`, both real paths.
	static func isRecordedFolder(_ folder: String, _ recordedFolder: String?) -> Bool {
		recordedFolder.map { $0.utf8.elementsEqual(folder.utf8) } ?? false
	}

	/// Unlinks `folder`, a real path, from `previous`, whose ID its lpm.json
	/// named, then links it to `project`. Unlinking comes first, so a
	/// failure leaves the folder linked to no more than it was, and doing it
	/// again finishes the job. A project's first record keeps the folder its
	/// metadata records, which the CLI links on its own; a record that can't
	/// be read is replaced, as the CLI's `lpm env link` replaces it.
	static func link(
		_ folder: String,
		to project: CLIFolderLinkProject,
		unlinkingFrom previous: CLIFolderLinkProject?,
		in store: any CLIFolderLinkStoring
	) throws {
		if let previous, previous.vaultId != project.vaultId {
			try unlink(folder, from: previous, in: store)
		}
		let existing: CLIFolderLinkRecord?
		do {
			existing = try store.record(vaultId: project.vaultId)
		} catch CLIFolderLinkRecordError.damaged {
			existing = CLIFolderLinkRecord(folders: [])
		}
		var record = existing ?? CLIFolderLinkRecord(folders: [project.recordedFolder()].compactMap { $0 })
		if record.insert(folder) || existing == nil {
			try store.write(record, vaultId: project.vaultId)
		}
	}

	/// A project whose record can't be read keeps its folders refused by the
	/// CLI, so it's left as it is.
	private static func unlink(
		_ folder: String,
		from previous: CLIFolderLinkProject,
		in store: any CLIFolderLinkStoring
	) throws {
		let existing: CLIFolderLinkRecord?
		do {
			existing = try store.record(vaultId: previous.vaultId)
		} catch is CLIFolderLinkRecordError {
			return
		}
		if var record = existing {
			if record.remove(folder) {
				try store.write(record, vaultId: previous.vaultId)
			}
			return
		}
		// Without a record the CLI links the recorded folder of a project with
		// values; an empty record keeps it from linking this one.
		guard try previous.holdsValues(),
			previous.recordedFolder().map({ $0.utf8.elementsEqual(folder.utf8) }) == true
		else { return }
		try store.write(CLIFolderLinkRecord(folders: []), vaultId: previous.vaultId)
	}

	/// `path` with symbolic links resolved, as the CLI keeps a folder. A
	/// folder that doesn't exist is resolved through its nearest existing
	/// ancestor, as the CLI resolves it. Blocking file work.
	static func realPath(_ path: String) -> String {
		var missing: [String] = []
		var current = path
		while true {
			if let resolved = Darwin.realpath(current, nil) {
				defer { free(resolved) }
				return ([String(cString: resolved)] + missing.reversed())
					.joined(separator: "/")
					.replacingOccurrences(of: "//", with: "/")
			}
			let parent = (current as NSString).deletingLastPathComponent
			guard !parent.isEmpty, parent != current else { return path }
			missing.append((current as NSString).lastPathComponent)
			current = parent
		}
	}
}
