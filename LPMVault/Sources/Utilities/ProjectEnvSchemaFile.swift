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
		case secretPublicPrefix(String)
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
			case .secretPublicPrefix(let prefix): "Secret keys cannot use the public prefix \(prefix). Rename the key with a private name."
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

	static func requiresSchemaEdit(_ change: Change, in document: LPMConfigJSON, vaultID: String) throws(FileError) -> Bool {
        if change.description != nil { return true }
        guard let schema = document["envSchema"], schema != .null else { return false }
        guard case .object = schema else { throw .invalidSchema }
        guard let rename = change.rename else { return false }
        if let vars = schema["vars"], case .object = vars {} else if schema["vars"] != nil { throw .invalidSchema }
        return schema["vars"]?[rename.from] != nil || schema["vars"]?[rename.to] != nil
    }

	static func validatedRename(_ change: Change, in document: LPMConfigJSON, vaultID: String) throws(FileError) -> (LPMConfigJSON, Rules) {
		try checkVault(of: document, is: vaultID)
		_ = try rules(of: document)
		if let rename = change.rename, rename.from != rename.to,
			document["envSchema"]?["vars"]?[rename.from] != nil,
			document["envSchema"]?["vars"]?[rename.to] != nil { throw .invalidSchema }
		let updated = try applying(change, to: document)
		return (updated, try rules(of: updated))
	}

	static func applying(_ change: Change, to document: LPMConfigJSON) throws(FileError) -> LPMConfigJSON {
		let schemaBefore = document["envSchema"]
		var schema = schemaBefore == .null ? .object([]) : schemaBefore ?? .object([])
		guard case .object = schema else { throw .invalidSchema }
		let varsBefore = schema["vars"]
		var vars = varsBefore ?? .object([])
		guard case .object = vars else { throw .invalidSchema }

		if let rename = change.rename, var rule = vars[rename.from], vars[rename.to] == nil {
			try classify(&rule, name: rename.to, schema: schema)
			vars.set(rule, forKey: rename.from)
			vars.renameKey(rename.from, to: rename.to)
			if case .object(var members) = vars {
				for index in members.indices where members[index].value["requiredWhen"]?["variable"] == .string(rename.from) {
					var condition = members[index].value["requiredWhen"]!
					condition.set(.string(rename.to), forKey: "variable")
					members[index].value.set(condition, forKey: "requiredWhen")
				}
				vars = .object(members)
			}
			if case .object(var groups)? = schema["groups"] {
				for index in groups.indices {
					guard case .array(let members)? = groups[index].value["vars"] else { continue }
					groups[index].value.set(.array(members.map { $0 == .string(rename.from) ? .string(rename.to) : $0 }), forKey: "vars")
				}
				schema.set(.object(groups), forKey: "groups")
			}
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
			if vars[description.key] == nil { try classify(&rule, name: description.key, schema: schema) }
            if rule.isEmptyObject && !isReferenced(description.key, schema: schema, vars: vars) {
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

	private static func publicPrefix(_ name: String, schema: LPMConfigJSON) -> String? {
		let cra = name.utf8.prefix(10).elementsEqual("REACT_APP_".utf8, by: { ($0 >= 97 && $0 <= 122 ? $0 - 32 : $0) == $1 })
		if cra { return "REACT_APP_" }
		if let prefix = ["NEXT_PUBLIC_", "VITE_", "PUBLIC_", "EXPO_PUBLIC_", "GATSBY_", "NUXT_PUBLIC_"].first(where: name.hasPrefix) { return prefix }
		guard case .array(let prefixes)? = schema["clientPrefixes"] else { return nil }
		for value in prefixes { if case .string(let prefix) = value, name.hasPrefix(prefix) { return prefix } }
		return nil
	}

	private static func classify(_ rule: inout LPMConfigJSON, name: String, schema: LPMConfigJSON) throws(FileError) {
		if let prefix = publicPrefix(name, schema: schema) {
			guard rule["secret"] != .bool(true) else { throw .secretPublicPrefix(prefix) }
			rule.set(.bool(true), forKey: "client")
		} else { rule.removeValue(forKey: "client") }
	}

	static func rules(of document: LPMConfigJSON) throws(FileError) -> Rules {
		guard let schema = document["envSchema"], schema != .null else { return Rules() }
		guard case .object(let fields) = schema, fields.allSatisfy({ ["vars", "clientPrefixes", "groups"].contains($0.key) }) else { throw .invalidSchema }
		var prefixes: [String] = ["NEXT_PUBLIC_", "VITE_", "PUBLIC_", "EXPO_PUBLIC_", "GATSBY_", "NUXT_PUBLIC_"]
		if let value = schema["clientPrefixes"] {
			guard case .array(let values) = value, values.count <= 32 else { throw .invalidSchema }
			var unique: Set<String> = []
			for value in values {
				guard case .string(let prefix) = value, portableName(prefix), prefix.hasSuffix("_"), unique.insert(prefix).inserted else { throw .invalidSchema }
				prefixes.append(prefix)
			}
		}
		let vars = schema["vars"] ?? .object([])
		guard case .object(let members) = vars, members.count <= 4096 else { throw .invalidSchema }
		var rules = Rules()
		for member in members {
			try validateRule(member.value, name: member.key)
			let cra = member.key.utf8.prefix(10).elementsEqual("REACT_APP_".utf8, by: { ($0 >= 97 && $0 <= 122 ? $0 - 32 : $0) == $1 })
			let isPublic = cra || prefixes.contains(where: member.key.hasPrefix)
			guard isPublic == (member.value["client"] == .bool(true)) else { throw .invalidSchema }
			rules.keys.insert(member.key)
			switch member.value["description"] {
			case .string(let text)?: rules.descriptions[member.key] = text
			case nil, .null?: break
			case _?: throw .invalidSchema
			}
		}
		try validateRelations(schema: schema, vars: vars)
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

	private static let allowedRuleFields: Set<String> = ["required", "format", "pattern", "enum", "default", "secret", "client", "description", "empty", "ci", "min", "max", "minLength", "maxLength", "protocols", "requiredWhen"]

	private static func portableName(_ name: String) -> Bool {
		let bytes = name.utf8
		guard let first = bytes.first, bytes.count <= 256,
			first == 95 || (65...90).contains(first) || (97...122).contains(first) else { return false }
		return bytes.allSatisfy({ $0 == 95 || (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) })
	}

	private static func validateRule(_ rule: LPMConfigJSON, name: String) throws(FileError) {
		guard portableName(name), case .object(let fields) = rule else { throw .invalidSchema }
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
		if let ci = rule["ci"], ci != .null {
			guard case .string(let text) = ci, ["secret", "variable"].contains(text) else { throw .invalidSchema }
		}
		if rule["secret"] == .bool(true), rule["client"] == .bool(true) || rule["ci"] == .string("variable") { throw .invalidSchema }
		if let empty = rule["empty"] {
			guard case .string(let text) = empty, ["missing", "allow", "reject"].contains(text) else { throw .invalidSchema }
		}
		if let values = rule["enum"], values != .null {
			guard case .array(let items) = values, !items.isEmpty, items.allSatisfy({
				if case .string(let text) = $0 { return safeMetadataText(text) }
				return false
			}) else { throw .invalidSchema }
		}
		try validateConstraints(rule)
		if rule["secret"] == .bool(true), ["default", "enum"].contains(where: { rule[$0] != nil && rule[$0] != .null }) { throw .invalidSchema }
	}

	private static func integerBound(_ value: LPMConfigJSON?) throws(FileError) -> Int64? {
		guard let value, value != .null else { return nil }
		let text: String
		switch value { case .number(let raw), .string(let raw): text = raw; default: throw .invalidSchema }
		let digits = text.utf8.drop(while: { $0 == 43 || $0 == 45 })
		guard !digits.isEmpty, digits.count <= 19, digits.allSatisfy({ (48...57).contains($0) }), let integer = Int64(text) else { throw .invalidSchema }
		return integer
	}

	private static func lengthBound(_ value: LPMConfigJSON?) throws(FileError) -> UInt32? {
		guard let value, value != .null else { return nil }
		let text: String
		switch value { case .number(let raw), .string(let raw): text = raw; default: throw .invalidSchema }
		guard !text.isEmpty, text.utf8.count <= 10, text.utf8.allSatisfy({ (48...57).contains($0) }), let integer = UInt32(text) else { throw .invalidSchema }
		return integer
	}

	private static func validateConstraints(_ rule: LPMConfigJSON) throws(FileError) {
		let min = try integerBound(rule["min"])
		let max = try integerBound(rule["max"])
		if min != nil || max != nil {
			guard rule["format"] == .string("integer") || rule["format"] == .string("port") else { throw .invalidSchema }
			if let min, let max, min > max { throw .invalidSchema }
			if rule["format"] == .string("port"), (min ?? 1) > 65535 || (max ?? 65535) < 1 { throw .invalidSchema }
		}
		let minLength = try lengthBound(rule["minLength"])
		let maxLength = try lengthBound(rule["maxLength"])
		if let minLength, let maxLength, minLength > maxLength { throw .invalidSchema }
		if let protocols = rule["protocols"], protocols != .null {
			guard rule["format"] == .string("url"), case .array(let values) = protocols, !values.isEmpty, values.count <= 32 else { throw .invalidSchema }
			var unique = Set<String>(minimumCapacity: values.count)
			for value in values {
				guard case .string(let scheme) = value, scheme.utf8.count <= 256, let first = scheme.utf8.first, (97...122).contains(first), scheme.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || [43,45,46].contains($0) }), unique.insert(scheme).inserted else { throw .invalidSchema }
			}
		}
	}

	private static func validateRelations(schema: LPMConfigJSON, vars: LPMConfigJSON) throws(FileError) {
		guard case .object(let declarations) = vars else { throw .invalidSchema }
		let names = Set(declarations.map(\.key))
		let secretNames = Set(declarations.lazy.filter { $0.value["secret"] == .bool(true) }.map(\.key))
		for declaration in declarations {
			guard let condition = declaration.value["requiredWhen"], condition != .null else { continue }
			guard case .object(let fields) = condition, fields.count == 2, case .string(let variable)? = condition["variable"], portableName(variable), names.contains(variable) else { throw .invalidSchema }
			if let equals = condition["equals"], condition["present"] == nil {
				guard case .string(let text) = equals, safeMetadataText(text), !secretNames.contains(variable) else { throw .invalidSchema }
			} else if case .bool? = condition["present"], condition["equals"] == nil {} else { throw .invalidSchema }
		}
		guard let groups = schema["groups"] else { return }
		guard case .object(let definitions) = groups, definitions.count <= 128 else { throw .invalidSchema }
		var totalMembers = 0
		for definition in definitions {
			guard portableName(definition.key), case .object(let fields) = definition.value, fields.count == 2,
				case .string(let mode)? = definition.value["mode"], ["allOrNone", "exactlyOne", "atLeastOne"].contains(mode),
				case .array(let members)? = definition.value["vars"], !members.isEmpty, members.count <= 4096 - totalMembers else { throw .invalidSchema }
			totalMembers += members.count
			var unique = Set<String>(minimumCapacity: members.count)
			for member in members {
				guard case .string(let name) = member, names.contains(name), unique.insert(name).inserted else { throw .invalidSchema }
			}
		}
	}

	private static func isReferenced(_ key: String, schema: LPMConfigJSON, vars: LPMConfigJSON) -> Bool {
		if case .object(let declarations) = vars, declarations.contains(where: { $0.value["requiredWhen"]?["variable"] == .string(key) }) { return true }
		if case .object(let groups)? = schema["groups"] {
			return groups.contains { group in
				if case .array(let members)? = group.value["vars"] { return members.contains(.string(key)) }
				return false
			}
		}
		return false
	}

	private static func canonicalBoundsForSync(_ schema: LPMConfigJSON) throws(FileError) -> LPMConfigJSON {
		guard case .object(var declarations)? = schema["vars"] else { return schema }
		var result = schema
		for index in declarations.indices {
			for field in ["min", "max"] {
				if let integer = try integerBound(declarations[index].value[field]) { declarations[index].value.set(.string(String(integer)), forKey: field) }
			}
			for field in ["minLength", "maxLength"] {
				if let integer = try lengthBound(declarations[index].value[field]) { declarations[index].value.set(.string(String(integer)), forKey: field) }
			}
		}
		result.set(.object(declarations), forKey: "vars")
		return result
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
			if let value = document[key], value != .null { metadata[key] = try syncValue(key == "envSchema" ? canonicalBoundsForSync(value) : value) }
		}
		return .object(metadata)
	}

	static func pushMetadata(from root: [String: LPMJSONValue]) -> LPMJSONValue {
      var schema: [String: LPMJSONValue] = ["version": .integer(2)]
      if case .object(let envSchema) = root["envSchema"] {
        if case .object(var vars) = envSchema["vars"] {
          for (name, value) in vars {
            guard case .object(var rule) = value else { continue }
            for field in ["min", "max", "minLength", "maxLength"] {
              if case .integer(let bound)? = rule[field] { rule[field] = .string(String(bound)) }
            }
            vars[name] = .object(rule)
          }
          schema["envSchema"] = .object(vars)
        } else { schema["envSchema"] = .object([:]) }
        var policy: [String: LPMJSONValue] = [:]
        for field in ["clientPrefixes", "groups"] { if let value = envSchema[field] { policy[field] = value } }
        if !policy.isEmpty { schema["envSchemaConfig"] = .object(policy) }
      }
      if case .object(let environments) = root["environments"] {
        schema["environments"] = .object(environments)
      }
      if case .object(let env) = root["env"] {
        var envConfig: [String: LPMJSONValue] = [:]
        for (alias, value) in env {
          guard case .string(let envPath) = value else { continue }
          guard envPath.hasPrefix(".env."), envPath.count > ".env.".count else {
            continue
          }
          envConfig[alias] = .object([
            "canonical": .string(String(envPath.dropFirst(".env.".count))),
            "file": .string(envPath),
          ])
        }
        if !envConfig.isEmpty { schema["envConfig"] = .object(envConfig) }
      }
      return .object(schema)
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
