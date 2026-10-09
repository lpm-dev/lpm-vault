import CryptoKit
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
		case metadataTooLarge
        case readOnlyPreset
		case multipleSourceEdit
		case readOnlyInstalled(String)
		case inheritedRename(String)
		case overriddenRename
		case presetRename(String)
		case renameCollision(String, String)
		case fragmentReference(String)
		case invalidVaultLink

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
			case .unsafeFile: "The schema file is a symbolic link or not a regular file."
			case .tooLarge: "The schema file is too large to update safely."
			case .invalidJSON: "lpm.json is not valid JSON."
			case .duplicateJSONKey: "lpm.json contains duplicate object keys. Remove the duplicate declaration."
			case .invalidSchema: "lpm.json has an invalid envSchema declaration."
			case .secretPublicPrefix(let prefix): "Secret keys cannot use the public prefix \(prefix.escapingDirectionControls). Rename the key with a private name."
			case .readFailed: "Could not read the schema file."
			case .changed: "A project schema file changed while it was being saved. Save again."
			case .writeFailed(let reason): "Could not write the schema file. \(reason.escapingDirectionControls)"
			case .metadataTooLarge: "Env metadata exceeds the cloud limit of 256 KiB."
            case .readOnlyPreset: "Preset declarations are read-only. Add a root envSchema.overrides entry."
			case .readOnlyInstalled(let source): "Installed schema \(source.escapingDirectionControls) is read-only. Add a root envSchema.overrides entry."
			case .inheritedRename(let source): "This key is declared in \(source.escapingDirectionControls). Rename it in the declaring file."
			case .overriddenRename: "This key is inherited and overridden in lpm.json. Rename its declaration in the imported schema, then update or remove the root override."
			case .presetRename(let source): "Keys from \(source.escapingDirectionControls) cannot be renamed. Declare a separate local key and update its uses."
			case .renameCollision(let key, let source): "The target key \(key.escapingDirectionControls) is declared in \(source.escapingDirectionControls). Choose a different key name."
			case .fragmentReference(let source): "This key is referenced in \(source.escapingDirectionControls). Update that declaration before a rename."
			case .multipleSourceEdit: "This rename and description change multiple schema files. Save the rename and description separately."
			case .invalidVaultLink: "lpm.json has a vault field that isn't a project ID. Fix it, then save again."
			}
		}
	}

	/// A folder's rules for editing and the same rules for display, from one read.
	struct Loaded: Sendable {
		let rules: Result<Rules, FileError>
		let schema: ProjectEnvSchemaState
		/// lpm.json's envSchema exactly as read, when `schema` is loaded; nil
		/// when the file has none. A schema draft starts and merges from it.
		var rootSchema: LPMConfigJSON? = nil
		var folderIdentity: ProjectConfigFile.DirectoryIdentity? = nil
		/// The schemas lpm.json imports, with their digests, when the rules
		/// resolved; empty when it imports none.
		var dependencies: [RustSchemaEngine.Dependency] = []
	}

	/// `load(inFolder:vaultID:)` off the main thread and the cooperative pool.
	static func loadRules(inFolder folder: String, vaultID: String) async -> Loaded {
		await withCheckedContinuation { continuation in
			DispatchQueue.global(qos: .userInitiated).async {
				continuation.resume(returning: load(inFolder: folder, vaultID: vaultID))
			}
		}
	}

	/// What an edit saved: the rules, and lpm.json's envSchema after it, which
	/// a schema draft merges without treating the app's own edit as a change on disk.
	struct SavedChange: Sendable {
		let rules: Rules
		/// nil when lpm.json has no envSchema.
		let rootSchema: LPMConfigJSON?
	}

	/// `applyChange(_:inFolder:vaultID:)` on the queue that orders the app's `lpm.json` edits.
	static func save(_ change: Change, inFolder folder: String, vaultID: String) async -> Result<SavedChange, FileError> {
		await withCheckedContinuation { continuation in
			ProjectConfigFile.editQueue.async {
				continuation.resume(returning: Result { () throws(FileError) in try applyChange(change, inFolder: folder, vaultID: vaultID) })
			}
		}
	}

	/// The folder's rules, or none when it has no `lpm.json`.
	static func rules(inFolder folder: String, vaultID: String) throws(FileError) -> Rules {
		try load(inFolder: folder, vaultID: vaultID).rules.get()
	}

	static func load(inFolder folder: String, vaultID: String) -> Loaded {
		let folderURL: URL
		do { folderURL = try existingFolder(folder) } catch { return Loaded(rules: .failure(error), schema: .noFolder) }
		let file = folderURL.appendingPathComponent("lpm.json")
		var schema: LPMConfigJSON?
		do throws(FileError) {
			guard let data = try read(file) else {
				return Loaded(rules: .success(Rules()), schema: .loaded(.empty, file: nil), folderIdentity: ProjectConfigFile.directoryIdentity(of: folderURL))
			}
			let document = try parse(data)
			try checkVault(of: document, is: vaultID)
			schema = document["envSchema"]
			let resolved = try RustSchemaEngine.resolve(schema ?? .object([]), inFolder: folder)
			guard try read(file) == data else { throw .changed }
			try resolved.verify()
			return Loaded(rules: .success(rules(fromEffective: resolved.effective)), schema: .loaded(ProjectEnvSchemaOverview(resolution: resolved), file: file),
				rootSchema: schema == .null ? nil : schema, folderIdentity: ProjectConfigFile.directoryIdentity(of: folderURL),
				dependencies: resolved.dependencies)
		} catch .invalidSchema {
			let diagnostic = schema.flatMap { RustSchemaEngine.diagnostic(for: $0, inFolder: folder) }
			return Loaded(rules: .failure(.invalidSchema), schema: .unreadable(ProjectEnvSchemaState.problem(diagnostic)))
		} catch {
			return Loaded(rules: .failure(error), schema: .unreadable(.init(location: "lpm.json", reason: error.localizedDescription)))
		}
	}

	/// Applies `change` under the CLI's config lock and returns the resulting
	/// rules. The file is written only when its contents change.
	static func apply(_ change: Change, inFolder folder: String, vaultID: String) throws(FileError) -> Rules {
		try applyChange(change, inFolder: folder, vaultID: vaultID).rules
	}

	/// `apply(_:inFolder:vaultID:)`, with lpm.json's envSchema after the edit.
	static func applyChange(_ change: Change, inFolder folder: String, vaultID: String) throws(FileError) -> SavedChange {
		let url = try existingFolder(folder).appendingPathComponent("lpm.json")
		do {
			var rootSchema: LPMConfigJSON?
			let rules = try edit(change, at: url, vaultID: vaultID, onRootSchema: { rootSchema = $0 }) ?? Rules()
			return SavedChange(rules: rules, rootSchema: rootSchema)
		} catch let error as FileError {
			throw error
		} catch let error as ProjectConfigFile.FileError {
			throw FileError(error)
		} catch {
			throw .writeFailed(error.localizedDescription)
		}
	}

	static func edit(
		_ change: Change, at url: URL, vaultID: String,
		fileWriter: ProjectConfigFile.FileWriter = ProjectConfigFile.writeSecurely,
		beforeWrite: (() throws -> Void)? = nil, onWriteFailure: (() throws -> Void)? = nil,
		onPrepared: ((Rules?, String) -> Void)? = nil, strictRename: Bool = false,
		onRootSchema: ((LPMConfigJSON?) -> Void)? = nil, folderIdentity: ProjectConfigFile.DirectoryIdentity? = nil
	) throws -> Rules? {
		try ProjectConfigFile.withRootTransaction(at: url) { transaction in
			if let folderIdentity, transaction.directoryIdentity != folderIdentity { throw FileError.changed }
			let root = transaction.document
			onRootSchema?(root["envSchema"] == .null ? nil : root["envSchema"])
			if try !requiresSchemaEdit(change, in: root, vaultID: vaultID) {
                return try transaction.update(relativePath: "lpm.json", fileWriter: fileWriter, rejectDuplicateKeys: false, beforeWrite: beforeWrite, onWriteFailure: onWriteFailure) { _ in
                    onPrepared?(nil, "lpm.json")
                    return nil
                }
            }
			try transaction.requireUniqueKeys()
			try checkVault(of: root, is: vaultID)
            let original = try RustSchemaEngine.resolve(root["envSchema"] ?? .object([]), inFolder: url.deletingLastPathComponent().path)
			if let description = change.description, let origin = original.origins[description.key],
				origin.source != "lpm.json" {
				guard !origin.source.hasPrefix("preset:") else { throw FileError.readOnlyPreset }
				guard !origin.source.split(separator: "/").contains(where: { $0.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX")) == "node_modules" }) else { throw FileError.readOnlyInstalled(origin.source) }
				if let rename = change.rename {
					let (renamed, _, _) = try validatedChange(.init(rename: rename), in: root, vaultID: vaultID, folder: url.deletingLastPathComponent().path, strictRename: strictRename)
					guard renamed == root else { throw FileError.multipleSourceEdit }
				}
				return try transaction.update(relativePath: origin.source, fileWriter: fileWriter, preservingMemberAt: pointerParts(origin.pointer),
					validateSources: { try original.verify() }, beforeWrite: beforeWrite, onWriteFailure: onWriteFailure) { source in
					try original.verify()
					try changeDescription(description, in: &source, pointer: origin.pointer)
					var effective = original.effective
					try changeDescription(description, in: &effective, pointer: "/vars/" + description.key)
					let rules = rules(fromEffective: try RustSchemaEngine.validate(effective))
					onPrepared?(rules, origin.source)
					return rules
				}
			}
			var snapshots: [RustSchemaEngine.Snapshot] = []
			return try transaction.update(relativePath: "lpm.json", fileWriter: fileWriter,
				validateSources: { for snapshot in snapshots { try snapshot.verify() } },
				beforeWrite: beforeWrite, onWriteFailure: onWriteFailure) { document in
				let (updated, rules, sources) = try validatedChange(change, in: document, vaultID: vaultID, folder: url.deletingLastPathComponent().path, strictRename: strictRename)
				snapshots = sources; document = updated
				onPrepared?(rules, "lpm.json")
				onRootSchema?(updated["envSchema"] == .null ? nil : updated["envSchema"])
				return rules
			}
		}
	}

	private static func pointerParts(_ pointer: String) -> [String] {
		pointer.dropFirst().split(separator: "/").map { $0.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~") }
	}

	private static func changeDescription(_ description: Change.Description, in document: inout LPMConfigJSON, pointer: String) throws(FileError) {
		guard safeMetadataText(description.text), pointer.hasPrefix("/") else { throw .invalidSchema }
		let parts = pointerParts(pointer)
		func update(_ node: inout LPMConfigJSON, parts: ArraySlice<String>) throws(FileError) {
			guard let key = parts.first, var child = node[key] else { throw .changed }
			if parts.count > 1 { try update(&child, parts: parts.dropFirst()) }
			else {
				guard case .object = child else { throw .invalidSchema }
				let current: String
				if case .string(let text)? = child["description"] { current = text } else { current = "" }
				if let expected = description.expectedText, !current.utf8.elementsEqual(expected.utf8) && !current.utf8.elementsEqual(description.text.utf8) { throw .changed }
				if description.text.isEmpty { child.removeValue(forKey: "description") }
				else { child.set(.string(description.text), forKey: "description") }
			}
			node.set(child, forKey: key)
		}
		try update(&document, parts: parts[...])
	}

	static func requiresSchemaEdit(_ change: Change, in document: LPMConfigJSON, vaultID: String) throws(FileError) -> Bool {
        if change.description != nil { return true }
        guard let schema = document["envSchema"], schema != .null else { return false }
        guard case .object = schema else { throw .invalidSchema }
        guard let rename = change.rename else { return false }
        if schema["extends"] != nil || schema["overrides"] != nil || schema["groupOverrides"] != nil { return true }
        let vars = schema["vars"] ?? .object([])
        if isReferenced(rename.from, schema: schema, vars: vars) || isReferenced(rename.to, schema: schema, vars: vars) { return true }
        if let vars = schema["vars"], case .object = vars {} else if schema["vars"] != nil { throw .invalidSchema }
        return schema["vars"]?[rename.from] != nil || schema["vars"]?[rename.to] != nil
    }



	static func validatedChange(_ change: Change, in document: LPMConfigJSON, vaultID: String, folder: String, strictRename: Bool = false) throws(FileError) -> (LPMConfigJSON, Rules, [RustSchemaEngine.Snapshot]) {
		try checkVault(of: document, is: vaultID)
		let original = try RustSchemaEngine.resolve(document["envSchema"] ?? .object([]), inFolder: folder)
		var prepared = document
		if let rename = change.rename, rename.from != rename.to {
			let source = document["envSchema"]
			if original.effective["vars"]?[rename.from] != nil {
				if source?["vars"]?[rename.from] == nil, let origin = original.declaringOrigins[rename.from] ?? original.origins[rename.from] {
					if origin.source.hasPrefix("preset:") { throw .presetRename(origin.source) }
					if source?["overrides"]?[rename.from] != nil { throw .overriddenRename }
					throw .inheritedRename(origin.source)
				}
				if original.effective["vars"]?[rename.to] != nil, source?["vars"]?[rename.to] == nil,
					let origin = original.declaringOrigins[rename.to] ?? original.origins[rename.to] { throw .renameCollision(rename.to, origin.source) }
				if case .object(let vars)? = original.effective["vars"] {
					for member in vars where member.value["requiredWhen"]?["variable"] == .string(rename.from) {
						if let origin = original.origins[member.key], origin.source != "lpm.json" { throw .fragmentReference(origin.source) }
					}
				}
				if case .object(let groups)? = original.effective["groups"] {
					for member in groups {
						if case .array(let vars)? = member.value["vars"], vars.contains(.string(rename.from)),
							let origin = original.groupOrigins[member.key], origin.source != "lpm.json" { throw .fragmentReference(origin.source) }
					}
				}
				guard source?["vars"]?[rename.from] != nil, source?["overrides"]?[rename.from] == nil,
					original.effective["vars"]?[rename.to] == nil || (!strictRename && source?["vars"]?[rename.to] != nil) else { throw .invalidSchema }
			}
		}
		var edit = change
		if let description = change.description, let origin = original.origins[description.key],
			origin.pointer.contains("/overrides/") || origin.source != "lpm.json" {
			guard origin.source == "lpm.json" else { throw .invalidSchema }
			try changeDescription(description, in: &prepared, pointer: origin.pointer)
			edit.description = nil
		}
		let updated = edit.isEmpty ? prepared : try applying(edit, to: prepared, referenceSchema: original.effective)
		if updated == document { return (document, rules(fromEffective: original.effective), [original.snapshot]) }
		let candidate = try RustSchemaEngine.resolve(updated["envSchema"] ?? .object([]), inFolder: folder)
		return (updated, rules(fromEffective: candidate.effective), [original.snapshot, candidate.snapshot])
	}

	static func applying(_ change: Change, to document: LPMConfigJSON, referenceSchema: LPMConfigJSON? = nil) throws(FileError) -> LPMConfigJSON {
		let schemaBefore = document["envSchema"]
		var schema = schemaBefore == .null ? .object([]) : schemaBefore ?? .object([])
		guard case .object = schema else { throw .invalidSchema }
		let varsBefore = schema["vars"]
		var vars = varsBefore ?? .object([])
		guard case .object = vars else { throw .invalidSchema }

		if let rename = change.rename, var rule = vars[rename.from], vars[rename.to] == nil {
			try classify(&rule, name: rename.to, schema: referenceSchema ?? schema)
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
			if case .object(var overrides)? = schema["overrides"] {
				for index in overrides.indices {
					guard var condition = overrides[index].value["requiredWhen"], condition["variable"] == .string(rename.from) else { continue }
					condition.set(.string(rename.to), forKey: "variable")
					overrides[index].value.set(condition, forKey: "requiredWhen")
				}
				schema.set(.object(overrides), forKey: "overrides")
			}
			for field in ["groups", "groupOverrides"] {
				if case .object(var groups)? = schema[field] {
					for index in groups.indices {
						guard case .array(let members)? = groups[index].value["vars"] else { continue }
						groups[index].value.set(.array(members.map { $0 == .string(rename.from) ? .string(rename.to) : $0 }), forKey: "vars")
					}
					schema.set(.object(groups), forKey: field)
				}
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
			if vars[description.key] == nil { try classify(&rule, name: description.key, schema: referenceSchema ?? schema) }
			if rule.isEmptyObject && !isReferenced(description.key, schema: schema, vars: vars) && !isReferenced(description.key, schema: referenceSchema ?? schema, vars: referenceSchema?["vars"] ?? vars) {

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

	#if DEBUG
	static func rules(of document: LPMConfigJSON) throws(FileError) -> Rules {
		guard let schema = document["envSchema"], schema != .null else { return Rules() }
		return rules(fromEffective: try RustSchemaEngine.validate(schema))
	}

	#endif
	private static func rules(fromEffective schema: LPMConfigJSON) -> Rules {
		guard case .object(let declarations)? = schema["vars"] else { return Rules() }
		var rules = Rules()
		for declaration in declarations {
			rules.keys.insert(declaration.key)
			if case .string(let text)? = declaration.value["description"] { rules.descriptions[declaration.key] = text }
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

	private static func integerBound(_ value: LPMConfigJSON?) throws(FileError) -> Int64? {
		guard let value, value != .null else { return nil }
		let text: String
		switch value {
		case .number(let raw): guard raw != "-0" else { throw .invalidSchema }; text = raw
		case .string(let raw): text = raw
		default: throw .invalidSchema
		}
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
			for field in ["required", "secret", "client"] where declarations[index].value[field] == .bool(false) { declarations[index].value.removeValue(forKey: field) }
			for field in ["description", "format", "pattern", "enum", "default"] where declarations[index].value[field] == .null { declarations[index].value.removeValue(forKey: field) }
			if declarations[index].value["empty"] == .string("missing") { declarations[index].value.removeValue(forKey: "empty") }
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

	static func validatedSyncConfig(inFolder folder: String, vaultID: String, beforeVerification: (() -> Void)? = nil) throws(FileError) -> LPMJSONValue? {
		do { return try validatedSyncSnapshot(inFolder: folder, vaultID: vaultID, beforeVerification: beforeVerification).config }
		catch .noFolder { return nil }
	}

	struct SyncSnapshot: Sendable {
		let config: LPMJSONValue?
		fileprivate let url: URL
		fileprivate let rootDigest: Data?
		fileprivate let sources: RustSchemaEngine.Snapshot

		func verify() throws(FileError) {
			let current = try ProjectEnvSchemaFile.read(url).map { Data(SHA256.hash(data: $0)) }
			guard current == rootDigest else { throw .changed }
			try sources.verify()
		}
	}

	static func validatedSyncSnapshot(inFolder folder: String, vaultID: String, beforeVerification: (() -> Void)? = nil) throws(FileError) -> SyncSnapshot {
		let url = try existingFolder(folder).appendingPathComponent("lpm.json")
		let data = try read(url)
		let document = try data.map(parse) ?? .object([])
		try checkVault(of: document, is: vaultID)
		let resolved = try RustSchemaEngine.resolve(document["envSchema"] ?? .object([]), inFolder: folder)
		try resolved.verify()
		var metadata: [String: LPMJSONValue] = [:]
		for key in ["envSchema", "environments", "env"] {
			if let value = document[key], value != .null { metadata[key] = try syncValue(key == "envSchema" ? canonicalBoundsForSync(resolved.effective) : value) }
		}
        try validateMetadataSize(pushMetadata(from: metadata))
		beforeVerification?()
		let captured = SyncSnapshot(config: data == nil ? nil : .object(metadata), url: url, rootDigest: data.map { Data(SHA256.hash(data: $0)) }, sources: resolved.snapshot)
		try captured.verify()
		return captured
	}

    static let maximumMetadataBytes = 256 * 1024
    static func validateMetadataSize(_ value: LPMJSONValue) throws(FileError) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { throw .invalidSchema }
        guard data.count <= maximumMetadataBytes else { throw .metadataTooLarge }
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
        for field in ["clientPrefixes", "groups"] {
          if let value = envSchema[field], value != .object([:]), value != .array([]) { policy[field] = value }
        }
        if !policy.isEmpty { schema["envSchemaConfig"] = .object(policy) }
      }
      if case .object(let environments) = root["environments"] {
        schema["environments"] = .object(environments.filter { name, definition in
          guard EnvValidation.isValidEnvironmentName(name) else { return false }
          switch definition {
          case .string(let path): return isPortableEnvironmentPath(path)
          case .object(let fields):
            if let file = fields["file"], file != .null {
              guard case .string(let path) = file, isPortableEnvironmentPath(path) else { return false }
            }
          default: return false
          }
          if case .object(let fields) = definition, let parent = fields["extends"], parent != .null {
            guard case .string(let name) = parent else { return false }
            return EnvValidation.isValidEnvironmentName(name)
          }
          return true
        })
      }
      if case .object(let env) = root["env"] {
        var envConfig: [String: LPMJSONValue] = [:]
			let declared: [String: LPMJSONValue]
			if case .object(let values)? = root["environments"] {
				declared = values
			} else {
				declared = [:]
			}
        for (alias, value) in env {
          guard case .string(let envPath) = value, isPortableEnvironmentPath(envPath) else { continue }
				let canonical =
					declared[alias] != nil
					? alias
					: envPath.hasPrefix(".env.") ? String(envPath.dropFirst(".env.".count)) : alias
				guard EnvValidation.isValidEnvironmentName(alias), EnvValidation.isValidEnvironmentName(canonical) else { continue }
          envConfig[alias] = .object([
					"canonical": .string(canonical),
            "file": .string(envPath),
          ])
        }
        if !envConfig.isEmpty { schema["envConfig"] = .object(envConfig) }
      }
      return .object(schema)
	}

    private static func isPortableEnvironmentPath(_ path: String) -> Bool {
        !path.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
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

	/// Like the LPM CLI, a `vault` field must be absent, null, or a project ID.
	private static func checkVault(of document: LPMConfigJSON, is vaultID: String) throws(FileError) {
		switch document["vault"] {
		case nil, .null?: return
		case .string(let linked)?: if linked != vaultID { throw .linkedToOtherVault }
		default: throw .invalidVaultLink
		}
	}

}

// MARK: - Schema drafts

extension ProjectEnvSchemaFile {
	enum DraftSaveError: Error, Equatable, Sendable {
		case file(FileError)
		/// The engine rejects the rules with the draft applied.
		case rejected(ProjectEnvSchemaDraft.Rejection)
		/// The draft has conflicts with lpm.json to settle first.
		case conflicts
		/// The rules can't be saved now, with the reason.
		case unavailable(String)
		/// A save of the draft is already running.
		case inProgress
		/// A schema lpm.json imports changed after the draft was evaluated, so
		/// what the review showed may no longer hold.
		case importsChanged

		var message: String {
			switch self {
			case .file(let error): error.localizedDescription
			case .rejected(let rejection): rejection.reason
			case .conflicts: "Choose a version for each conflicting change first."
			case .unavailable(let reason): reason
			case .inProgress: "Already saving."
			case .importsChanged: "An imported schema changed after you reviewed the rules. Check the changes again, then save."
			}
		}
	}

	/// What a saved draft wrote.
	struct SavedDraft: Sendable {
		let rules: Rules
		/// lpm.json's envSchema as written; nil when it has none.
		let schema: LPMConfigJSON?
		/// The rules as the engine resolved them under the CLI's lock.
		let overview: ProjectEnvSchemaOverview
		let file: URL
		/// The schemas the saved rules import, with their digests.
		let dependencies: [RustSchemaEngine.Dependency]
	}

	/// The rules with `draft` applied, resolved with the folder's imported
	/// schemas, and `environments` checked against them. Reads files; call
	/// it off the main thread.
	static func evaluate(_ draft: ProjectEnvSchemaDraft, inFolder folder: String, environments: [String: [String: String]]) -> ProjectEnvSchemaDraft.Evaluation {
		let schema: LPMConfigJSON
		do { schema = try draft.applied(to: draft.schema) ?? .object([]) } catch {
			return .init(overview: nil, rejection: ProjectEnvSchemaDraft.Rejection(error).attributed(to: draft), check: nil)
		}
		switch ProjectEnvSchemaDraftEvaluator.resolve(schema, inFolder: folder) {
		case .resolved(let overview, let dependencies):
			return .init(overview: overview, rejection: nil, check: overview.check(environments), dependencies: dependencies)
		case .rejected(let rejection):
			return .init(overview: nil, rejection: rejection.attributed(to: draft), check: nil)
		}
	}

	/// `apply(_:inFolder:vaultID:folderIdentity:reviewed:)` on the queue that orders the app's `lpm.json` edits.
	static func save(
		_ draft: ProjectEnvSchemaDraft, inFolder folder: String, vaultID: String,
		folderIdentity: ProjectConfigFile.DirectoryIdentity?, reviewed: [RustSchemaEngine.Dependency]?
	) async -> Result<SavedDraft, DraftSaveError> {
		await withCheckedContinuation { continuation in
			ProjectConfigFile.editQueue.async {
				continuation.resume(returning: Result { () throws(DraftSaveError) in
					try apply(draft, inFolder: folder, vaultID: vaultID, folderIdentity: folderIdentity, reviewed: reviewed)
				})
			}
		}
	}

	/// Writes `draft` into the folder's lpm.json under the CLI's config lock.
	/// Fails with `changed` when the file's envSchema is no longer the one the
	/// draft last read, so the draft can merge before it saves; when the folder
	/// is no longer the one `folderIdentity` names; or when the imported schemas
	/// differ from the `reviewed` ones the draft was checked with.
	static func apply(
		_ draft: ProjectEnvSchemaDraft, inFolder folder: String, vaultID: String,
		folderIdentity: ProjectConfigFile.DirectoryIdentity? = nil, reviewed: [RustSchemaEngine.Dependency]? = nil
	) throws(DraftSaveError) -> SavedDraft {
		do {
			let url = try existingFolder(folder).appendingPathComponent("lpm.json")
			return try edit(draft, at: url, vaultID: vaultID, folderIdentity: folderIdentity, reviewed: reviewed)
		} catch let error as DraftSaveError {
			throw error
		} catch let error as FileError {
			throw .file(error)
		} catch let error as ProjectConfigFile.FileError {
			throw .file(FileError(error))
		} catch {
			throw .file(.writeFailed(error.localizedDescription))
		}
	}

	static func edit(
		_ draft: ProjectEnvSchemaDraft, at url: URL, vaultID: String,
		folderIdentity: ProjectConfigFile.DirectoryIdentity? = nil, reviewed: [RustSchemaEngine.Dependency]? = nil,
		fileWriter: ProjectConfigFile.FileWriter = ProjectConfigFile.writeSecurely,
		beforeWrite: (() throws -> Void)? = nil
	) throws -> SavedDraft {
		guard draft.conflicts.isEmpty else { throw DraftSaveError.conflicts }
		return try ProjectConfigFile.withRootTransaction(at: url, rejectingDuplicateKeys: true) { transaction in
			if let folderIdentity, transaction.directoryIdentity != folderIdentity { throw FileError.changed }
			let root = transaction.document
			try checkVault(of: root, is: vaultID)
			let current = root["envSchema"] == .null ? nil : root["envSchema"]
			guard current == draft.schema else { throw FileError.changed }
			let updated = try draft.applied(to: current)
			let resolution: RustSchemaEngine.Resolution
			switch try RustSchemaEngine.resolveOrDiagnose(updated ?? .object([]), inFolder: url.deletingLastPathComponent().path) {
			case .success(let resolved): resolution = resolved
			case .failure(let rejected): throw DraftSaveError.rejected(ProjectEnvSchemaDraft.Rejection(rejected.diagnostic).attributed(to: draft))
			}
			if let reviewed, reviewed != resolution.dependencies { throw DraftSaveError.importsChanged }
			return try transaction.update(relativePath: "lpm.json", fileWriter: fileWriter,
				validateSources: { try resolution.verify() }, beforeWrite: beforeWrite) { document in
				if updated != current {
					if let updated { document.set(updated, forKey: "envSchema") } else { document.removeValue(forKey: "envSchema") }
				}
				return SavedDraft(rules: rules(fromEffective: resolution.effective), schema: updated,
					overview: ProjectEnvSchemaOverview(resolution: resolution), file: url, dependencies: resolution.dependencies)
			}
		}
	}
}

/// A project's key descriptions as last read from its `lpm.json`.
struct ProjectKeyDescriptions: Equatable, Sendable {
	let folder: String
	let rules: Result<ProjectEnvSchemaFile.Rules, ProjectEnvSchemaFile.FileError>
	/// What the Schema page and the tables show; nil until the folder is read.
	var schema: ProjectEnvSchemaState?
	/// The folder's identity when it was read.
	var folderIdentity: ProjectConfigFile.DirectoryIdentity?
	/// lpm.json's envSchema as last read, as compact JSON, which costs a
	/// fraction of the parsed tree for each project the app has read.
	private var rootSchemaData: Data?

	/// The schemas lpm.json imports, with their digests, when the rules were
	/// read; nil when the read didn't record them.
	var dependencies: [RustSchemaEngine.Dependency]?

	init(
		folder: String, rules: Result<ProjectEnvSchemaFile.Rules, ProjectEnvSchemaFile.FileError>, schema: ProjectEnvSchemaState? = nil,
		rootSchema: LPMConfigJSON? = nil, folderIdentity: ProjectConfigFile.DirectoryIdentity? = nil,
		dependencies: [RustSchemaEngine.Dependency]? = nil
	) {
		self.folder = folder
		self.rules = rules
		self.schema = schema
		self.folderIdentity = folderIdentity
		self.dependencies = dependencies
		rootSchemaData = try? rootSchema?.compactData(maximumBytes: 16 * 1024 * 1024)
	}

	init(folder: String, loaded: ProjectEnvSchemaFile.Loaded) {
		self.init(folder: folder, rules: loaded.rules, schema: loaded.schema, rootSchema: loaded.rootSchema, folderIdentity: loaded.folderIdentity,
			dependencies: loaded.dependencies)
	}

	/// lpm.json's envSchema as last read, when `schema` is loaded; nil when it has none.
	var rootSchema: LPMConfigJSON? {
		rootSchemaData.flatMap { try? LPMConfigJSON(parsing: $0) }
	}

	func description(of key: String) -> String? {
		if case .success(let rules) = rules { return rules.descriptions[key] }
		return nil
	}
}
