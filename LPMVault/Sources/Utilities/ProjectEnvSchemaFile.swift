import Darwin
import Foundation

/// The `envSchema` rules in a project folder's `lpm.json`, where the LPM CLI
/// keeps each key's validation rules and description.
///
/// Reads take no lock. Edits go through `ProjectConfigFile.update`, which takes
/// the CLI's config lock and renders the file as the CLI does.
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
			var expectedText: String?
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
		case duplicateJSONKey
		case invalidSchema
		case readFailed
		case changed
		case writeFailed(String)

		init(_ error: ProjectConfigFile.FileError) {
			switch error {
			case .notFound, .readFailed: self = .readFailed
			case .unsafeFile: self = .unsafeFile
			case .tooLarge: self = .tooLarge
			case .invalidJSON: self = .invalidJSON
			case .duplicateJSONKey: self = .duplicateJSONKey
			case .changed: self = .changed
			case .writeFailed(let reason): self = .writeFailed(reason)
			}
		}

		var errorDescription: String? {
			switch self {
			case .noFolder: "Connect a project folder to keep descriptions in its lpm.json."
			case .linkedToOtherVault: "lpm.json in the project folder links another env project."
			case .unsafeFile: "lpm.json is a symbolic link or not a regular file."
			case .tooLarge: "lpm.json is too large to update safely."
			case .invalidJSON: "lpm.json is not valid JSON."
			case .duplicateJSONKey: "lpm.json contains duplicate object keys. Remove the duplicate declaration."
			case .invalidSchema: "lpm.json has an invalid envSchema declaration."
			case .readFailed: "Could not read lpm.json."
			case .changed: "lpm.json changed while it was being saved. Save again."
			case .writeFailed(let reason): "Could not write lpm.json. \(reason)"
			}
		}
	}

	/// `rules(inFolder:vaultID:)` off the main thread and the cooperative pool.
	static func loadRules(inFolder folder: String, vaultID: String) async -> Result<Rules, FileError> {
		await withCheckedContinuation { continuation in
			DispatchQueue.global(qos: .userInitiated).async {
				continuation.resume(returning: Result { () throws(FileError) in try rules(inFolder: folder, vaultID: vaultID) })
			}
		}
	}

	/// `apply(_:inFolder:vaultID:)` on the queue that orders the app's `lpm.json` edits.
	static func save(_ change: Change, inFolder folder: String, vaultID: String) async -> Result<Rules, FileError> {
		await withCheckedContinuation { continuation in
			ProjectConfigFile.editQueue.async {
				continuation.resume(returning: Result { () throws(FileError) in try apply(change, inFolder: folder, vaultID: vaultID) })
			}
		}
	}

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
		let url = try existingFolder(folder).appendingPathComponent("lpm.json")
		do {
			return try ProjectConfigFile.update(at: url, rejectDuplicateKeys: true) { document in
				try checkVault(of: document, is: vaultID)
				// A schema the CLI cannot read is left for the person to fix.
				let current = try rules(of: document)
				let updated = try applying(change, to: document)
				guard updated != document else { return current }
				document = updated
				return try rules(of: updated)
			}
		} catch let error as FileError {
			throw error
		} catch let error as ProjectConfigFile.FileError {
			throw FileError(error)
		} catch {
			throw .writeFailed(error.localizedDescription)
		}
	}

	static func applying(_ change: Change, to document: LPMConfigJSON) throws(FileError) -> LPMConfigJSON {
		let schemaBefore = document["envSchema"]
		var schema = schemaBefore == .null ? .object([]) : schemaBefore ?? .object([])
		guard case .object = schema else { throw .invalidSchema }
		let varsBefore = schema["vars"]
		var vars = varsBefore ?? .object([])
		guard case .object = vars else { throw .invalidSchema }

		if let rename = change.rename, vars[rename.from] != nil, vars[rename.to] == nil {
			vars.renameKey(rename.from, to: rename.to)
		}
		if let description = change.description {
			guard safeMetadataText(description.text) else { throw .invalidSchema }
			var rule = vars[description.key] ?? .object([])
			guard case .object = rule else { throw .invalidSchema }
			if let expected = description.expectedText {
				let current: String
				if case .string(let text)? = rule["description"] { current = text } else { current = "" }
				guard current.utf8.elementsEqual(expected.utf8) || current.utf8.elementsEqual(description.text.utf8)
				else { throw .changed }
			}
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
		guard let schema = document["envSchema"], schema != .null else { return Rules() }
		guard case .object(let fields) = schema, fields.allSatisfy({ $0.key == "vars" }) else { throw .invalidSchema }
		guard let vars = schema["vars"] else { return Rules() }
		guard case .object(let members) = vars, members.count <= 4096 else { throw .invalidSchema }
		var rules = Rules()
		for member in members {
			try validateRule(member.value, name: member.key)
			rules.keys.insert(member.key)
			switch member.value["description"] {
			case .string(let text)?: rules.descriptions[member.key] = text
			case nil, .null?: break
			case _?: throw .invalidSchema
			}
		}
		return rules
	}

	private static func safeMetadataText(_ text: String) -> Bool {
		!text.unicodeScalars.contains { scalar in
			switch scalar.value {
			case 0...8, 11...12, 14...31, 127...159: true
			default: false
			}
		}
	}

	private static let allowedRuleFields: Set<String> = ["required", "format", "pattern", "enum", "default", "secret", "client", "description", "empty"]

	private static func validateRule(_ rule: LPMConfigJSON, name: String) throws(FileError) {
		let bytes = name.utf8
		guard let first = bytes.first, bytes.count <= 256,
			first == 95 || (65...90).contains(first) || (97...122).contains(first),
			bytes.allSatisfy({ $0 == 95 || (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) }),
			case .object(let fields) = rule
		else { throw .invalidSchema }
		guard fields.allSatisfy({ allowedRuleFields.contains($0.key) }) else { throw .invalidSchema }
		for field in ["required", "secret", "client"] {
			if let value = rule[field], case .bool = value {} else if rule[field] != nil { throw .invalidSchema }
		}
		for field in ["description", "pattern", "default", "format"] {
			switch rule[field] {
			case .string(let text)?: guard safeMetadataText(text) else { throw .invalidSchema }
			case nil, .null?: break
			default: throw .invalidSchema
			}
		}
		if case .string(let format)? = rule["format"], !["url", "port", "email", "boolean", "integer", "hostname", "ip"].contains(format) { throw .invalidSchema }
		if let empty = rule["empty"] {
			guard case .string(let text) = empty, ["missing", "allow", "reject"].contains(text) else { throw .invalidSchema }
		}
		if let values = rule["enum"], values != .null {
			guard case .array(let items) = values, !items.isEmpty, items.allSatisfy({
				if case .string(let text) = $0 { return safeMetadataText(text) }
				return false
			}) else { throw .invalidSchema }
		}
		if rule["secret"] == .bool(true), ["default", "enum"].contains(where: { rule[$0] != nil && rule[$0] != .null }) { throw .invalidSchema }
	}

	static func validatedSyncConfig(inFolder folder: String, vaultID: String) throws(FileError) -> LPMJSONValue? {
		let folderURL: URL
		do { folderURL = try existingFolder(folder) }
		catch .noFolder { return nil }
		let url = folderURL.appendingPathComponent("lpm.json")
		guard let data = try read(url) else { return nil }
		let document = try parse(data)
		try checkVault(of: document, is: vaultID)
		_ = try rules(of: document)
		var metadata: [String: LPMJSONValue] = [:]
		for key in ["envSchema", "environments", "env"] {
			if let value = document[key], value != .null { metadata[key] = try syncValue(value) }
		}
		return .object(metadata)
	}

	private static func syncValue(_ value: LPMConfigJSON) throws(FileError) -> LPMJSONValue {
		switch value {
		case .object(let fields):
			var object = Dictionary<String, LPMJSONValue>(minimumCapacity: fields.count)
			for field in fields { object[field.key] = try syncValue(field.value) }
			return .object(object)
		case .array(let values): return .array(try values.map(syncValue))
		case .string(let text): return .string(text)
		case .bool(let flag): return .bool(flag)
		case .null: return .null
		case .number(let text):
			if let integer = Int64(text) { return .integer(integer) }
			do { return try JSONDecoder().decode(LPMJSONValue.self, from: Data(text.utf8)) }
			catch { throw .invalidJSON }
		}
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
			let document = try LPMConfigJSON(parsing: data, rejectDuplicateKeys: true)
			guard case .object = document else { throw FileError.invalidJSON }
			return document
		} catch LPMConfigJSON.ParseError.duplicateKey {
			throw .duplicateJSONKey
		} catch {
			throw .invalidJSON
		}
	}

	private static func checkVault(of document: LPMConfigJSON, is vaultID: String) throws(FileError) {
		if case .string(let linked)? = document["vault"], linked != vaultID { throw .linkedToOtherVault }
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
