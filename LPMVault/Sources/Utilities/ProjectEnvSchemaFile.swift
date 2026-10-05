import Darwin
import Foundation

/// The `envSchema` rules in a project folder's `lpm.json`, where the LPM CLI
/// keeps each key's validation rules and description.
///
/// Reads take no lock. Edits take the CLI's config lock, `.lpm/.config.lock`,
/// and render the file as the CLI does, so neither side loses the other's edit.
enum ProjectEnvSchemaFile {
	struct Rules: Equatable, Sendable {
		/// Keys that have a rule.
		var keys: Set<String> = []
		var descriptions: [String: String] = [:]
	}

	struct Change: Equatable, Sendable {
		struct Rename: Equatable, Sendable {
			let from: String
			let to: String
		}

		struct Description: Equatable, Sendable {
			let key: String
			/// The new description; empty removes it.
			let text: String
		}

		/// Moves the rule of a renamed key, unless the new name already has one.
		var rename: Rename?
		var description: Description?

		var isEmpty: Bool { rename == nil && description == nil }
	}

	enum FileError: LocalizedError, Equatable, Sendable {
		case noFolder
		case linkedToOtherVault
		case unsafeFile
		case tooLarge
		case invalidJSON
		case invalidSchema
		case readFailed
		case changed
		case writeFailed(String)

		var errorDescription: String? {
			switch self {
			case .noFolder: "Connect a project folder to keep descriptions in its lpm.json."
			case .linkedToOtherVault: "lpm.json in the project folder links another vault."
			case .unsafeFile: "lpm.json is a symbolic link or not a regular file."
			case .tooLarge: "lpm.json is too large to update safely."
			case .invalidJSON: "lpm.json is not valid JSON."
			case .invalidSchema: "lpm.json has an envSchema the LPM CLI cannot read."
			case .readFailed: "Could not read lpm.json."
			case .changed: "lpm.json changed while it was being saved. Save again."
			case .writeFailed(let reason): "Could not write lpm.json. \(reason)"
			}
		}
	}

	/// The CLI's limit for configuration files.
	private static let maximumBytes = 16 * 1024 * 1024

	/// The folder's rules, or none when it has no `lpm.json`.
	static func rules(inFolder folder: String, vaultID: String) throws(FileError) -> Rules {
		let folderURL = try existingFolder(folder)
		guard let data = try read(folderURL.appendingPathComponent("lpm.json")) else { return Rules() }
		let document = try parse(data)
		try checkVault(of: document, is: vaultID)
		return try rules(of: document)
	}

	/// Applies `change` under the CLI's config lock and returns the resulting
	/// rules. The file is written only when its contents change.
	static func apply(_ change: Change, inFolder folder: String, vaultID: String) throws(FileError) -> Rules {
		let folderURL = try existingFolder(folder)
		return try withConfigLock(in: folderURL) { () throws(FileError) -> Rules in
			let url = folderURL.appendingPathComponent("lpm.json")
			let original = try read(url)
			let document = try original.map(parse) ?? .object([])
			guard case .object = document else { throw .invalidJSON }
			try checkVault(of: document, is: vaultID)
			// A schema the CLI cannot read is left for the person to fix.
			let current = try rules(of: document)
			let updated = try applying(change, to: document)
			guard updated != document else { return current }
			try write(updated, to: url, replacing: original)
			return try rules(of: updated)
		}
	}

	static func applying(_ change: Change, to document: LPMConfigJSON) throws(FileError) -> LPMConfigJSON {
		let schemaBefore = document["envSchema"]
		var schema = schemaBefore ?? .object([])
		guard case .object = schema else { throw .invalidSchema }
		let varsBefore = schema["vars"]
		var vars = varsBefore ?? .object([])
		guard case .object = vars else { throw .invalidSchema }

		if let rename = change.rename, vars[rename.from] != nil, vars[rename.to] == nil {
			vars.renameKey(rename.from, to: rename.to)
		}
		if let description = change.description {
			var rule = vars[description.key] ?? .object([])
			guard case .object = rule else { throw .invalidSchema }
			if description.text.isEmpty {
				rule.removeValue(forKey: "description")
			} else {
				rule.set(.string(description.text), forKey: "description")
			}
			if rule.isEmptyObject {
				vars.removeValue(forKey: description.key)
			} else {
				vars.set(rule, forKey: description.key)
			}
		}

		// Containers this change emptied go away; ones that were already empty stay.
		if vars.isEmptyObject, varsBefore?.isEmptyObject != true {
			schema.removeValue(forKey: "vars")
		} else {
			schema.set(vars, forKey: "vars")
		}
		var updated = document
		if schema.isEmptyObject, schemaBefore?.isEmptyObject != true {
			updated.removeValue(forKey: "envSchema")
		} else {
			updated.set(schema, forKey: "envSchema")
		}
		return updated
	}

	static func rules(of document: LPMConfigJSON) throws(FileError) -> Rules {
		guard let schema = document["envSchema"] else { return Rules() }
		guard case .object = schema else { throw .invalidSchema }
		guard let vars = schema["vars"] else { return Rules() }
		guard case .object(let members) = vars else { throw .invalidSchema }
		var rules = Rules()
		for member in members {
			guard case .object = member.value else { throw .invalidSchema }
			rules.keys.insert(member.key)
			switch member.value["description"] {
			case .string(let text)?: rules.descriptions[member.key] = text
			case nil, .null?: break
			case _?: throw .invalidSchema
			}
		}
		return rules
	}

	// MARK: - Files

	private static func existingFolder(_ folder: String) throws(FileError) -> URL {
		var isDirectory: ObjCBool = false
		guard !folder.isEmpty, FileManager.default.fileExists(atPath: folder, isDirectory: &isDirectory), isDirectory.boolValue
		else { throw .noFolder }
		return URL(fileURLWithPath: folder, isDirectory: true)
	}

	private static func read(_ url: URL) throws(FileError) -> Data? {
		do {
			return try ProjectConfigFile.readRegularFile(at: url)
		} catch ProjectConfigFile.FileError.notFound {
			return nil
		} catch ProjectConfigFile.FileError.unsafeFile {
			throw .unsafeFile
		} catch ProjectConfigFile.FileError.tooLarge {
			throw .tooLarge
		} catch {
			throw .readFailed
		}
	}

	private static func parse(_ data: Data) throws(FileError) -> LPMConfigJSON {
		do {
			let document = try LPMConfigJSON(parsing: data)
			guard case .object = document else { throw FileError.invalidJSON }
			return document
		} catch {
			throw .invalidJSON
		}
	}

	private static func checkVault(of document: LPMConfigJSON, is vaultID: String) throws(FileError) {
		if case .string(let linked)? = document["vault"], linked != vaultID { throw .linkedToOtherVault }
	}

	private static func write(_ document: LPMConfigJSON, to url: URL, replacing original: Data?) throws(FileError) {
		let data = Data((document.rendered() + "\n").utf8)
		guard data.count <= maximumBytes else { throw .tooLarge }
		var permissions = mode_t(0o644)
		var metadata = stat()
		if original != nil, lstat(url.path, &metadata) == 0 { permissions = metadata.st_mode & 0o777 }
		do {
			try SecureFileWriter.write(data, to: url, permissions: permissions, replaceExisting: original != nil) {
				// The lock orders CLI writes; an editor saving meanwhile does not take it.
				let current: Data?
				do { current = try ProjectConfigFile.readRegularFile(at: url) } catch ProjectConfigFile.FileError.notFound { current = nil }
				guard current == original else { throw FileError.changed }
			}
		} catch let error as FileError {
			throw error
		} catch SecureFileWriter.WriteError.replaceFailed(let code) where code == EEXIST {
			throw .changed
		} catch {
			throw .writeFailed(error.localizedDescription)
		}
	}

	/// Runs `body` holding the exclusive `flock` the CLI takes on `.lpm/.config.lock`.
	private static func withConfigLock<T>(in folder: URL, _ body: () throws(FileError) -> T) throws(FileError) -> T {
		let stateDirectory = folder.appendingPathComponent(".lpm", isDirectory: true)
		if mkdir(stateDirectory.path, 0o755) != 0, errno != EEXIST {
			throw .writeFailed(String(cString: strerror(errno)))
		}
		var metadata = stat()
		guard lstat(stateDirectory.path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFDIR else { throw .unsafeFile }
		let lockPath = stateDirectory.appendingPathComponent(".config.lock").path
		let descriptor = open(lockPath, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o644)
		guard descriptor >= 0 else {
			throw errno == ELOOP ? .unsafeFile : .writeFailed(String(cString: strerror(errno)))
		}
		defer { close(descriptor) }
		guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG else { throw .unsafeFile }
		while flock(descriptor, LOCK_EX) != 0 {
			guard errno == EINTR else { throw .writeFailed(String(cString: strerror(errno))) }
		}
		return try body()
	}
}

/// A project's key descriptions as last read from its `lpm.json`.
struct ProjectKeyDescriptions: Equatable, Sendable {
	let folder: String
	let rules: Result<ProjectEnvSchemaFile.Rules, ProjectEnvSchemaFile.FileError>

	func description(of key: String) -> String? {
		if case .success(let rules) = rules { return rules.descriptions[key] }
		return nil
	}
}
