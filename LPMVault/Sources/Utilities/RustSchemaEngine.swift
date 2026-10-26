import Foundation
import LPMEnv

/// The bundled engine is the authority for declarations in every native path.
enum RustSchemaEngine {
	// The handle is immutable after initialization. Rust verification only reads it;
	// release runs after the last Swift owner completes all verification calls.
	final class Snapshot: @unchecked Sendable {
		private let owned: OwnedResult
		fileprivate init(owned: OwnedResult) { self.owned = owned }

		func verify() throws(ProjectEnvSchemaFile.FileError) {
			guard lpm_env_verify(owned.result.snapshot) == 0 else { throw .changed }
		}
	}

	struct Origin: Equatable, Sendable {
		let source: String
		let pointer: String
	}

	/// Why the engine rejected a schema: a stable code and, when the engine
	/// knows it, the declaring file and JSON pointer. Never contains values.
	struct Diagnostic: Equatable, Sendable {
		let code: String
		let source: String?
		let pointer: String?
		let message: String?
	}

	struct Dependency: Equatable, Sendable {
		let path: String
		let digest: Data
		let bytes: Int
	}

	/// The inherited rules one of lpm.json's key overrides replaces, in summary.
	struct ReplacedRules: Equatable, Sendable {
		/// More than one when the override settles a conflict between imports.
		let count: Int
		/// The file the first one comes from: what lpm.json's imports resolve,
		/// which is an import's own override when one sits between.
		let source: String
		/// Whether every one marks the key public.
		let client: Bool
		/// The file the first one that marks the key secret comes from; nil when none does.
		let secret: String?
	}

	/// The inherited groups one of lpm.json's group overrides replaces, in summary.
	struct ReplacedGroups: Equatable, Sendable {
		/// More than one when the override settles a conflict between imports.
		let count: Int
		/// The file the first one comes from, as for `ReplacedRules`.
		let source: String
	}

	/// What the engine says about a resolved schema, apart from the snapshot it retains.
	struct Resolved: Equatable, Sendable {
		let effective: LPMConfigJSON
		let origins: [String: Origin]
		let groupOrigins: [String: Origin]
		/// Where an overridden key was declared before the override replaced it.
		let declaringOrigins: [String: Origin]
		/// The file that declared an overridden group before the override replaced it.
		let groupDeclaringSources: [String: String]
		/// The file each client prefix is listed in: the first schema to list it,
		/// so a prefix lpm.json shares with an import names the import.
		let clientPrefixSources: [String: String]
		/// What each of lpm.json's key overrides replaces.
		let replacedRules: [String: ReplacedRules]
		/// What each of lpm.json's group overrides replaces.
		let replacedGroups: [String: ReplacedGroups]
		let dependencies: [Dependency]
	}

	@dynamicMemberLookup
	struct Resolution: Sendable {
		let resolved: Resolved
		let snapshot: Snapshot
		subscript<Value>(dynamicMember path: KeyPath<Resolved, Value>) -> Value { resolved[keyPath: path] }
		func verify() throws(ProjectEnvSchemaFile.FileError) { try snapshot.verify() }
	}

	fileprivate final class OwnedResult {
		var result: LPMEnvResult
		init(_ result: LPMEnvResult) { self.result = result }
		deinit { lpm_env_release(result) }

		func decode() throws(ProjectEnvSchemaFile.FileError) -> LPMConfigJSON {
			defer { lpm_env_clear_output(&result) }
			guard result.status == 0 else {
				throw result.status == 4 ? .tooLarge : .invalidSchema
			}
			guard result.length > 0, result.length <= RustSchemaEngine.maximumOutputBytes, let data = result.data else { throw .invalidSchema }
			do { return try LPMConfigJSON(parsing: Data(bytesNoCopy: data, count: result.length, deallocator: .none), rejectDuplicateKeys: true) }
			catch { throw .invalidSchema }
		}

		/// The diagnostic of a rejected schema; nil for any other outcome.
		func diagnostic() -> Diagnostic? {
			defer { lpm_env_clear_output(&result) }
			guard result.status == 1, result.length > 0, result.length <= 64 * 1024, let data = result.data,
				let output = try? LPMConfigJSON(parsing: Data(bytesNoCopy: data, count: result.length, deallocator: .none)),
				case .string(let code)? = output["code"]
			else { return nil }
			func text(_ field: String) -> String? {
				if case .string(let value)? = output[field], !value.isEmpty { value } else { nil }
			}
			return Diagnostic(code: code, source: text("source"), pointer: text("pointer"), message: text("message"))
		}
	}

	static func validate(_ schema: LPMConfigJSON) throws(ProjectEnvSchemaFile.FileError) -> LPMConfigJSON {
		let schema = schema == .null ? .object([]) : schema
		guard lpm_env_abi_version() == 1, case .object = schema else { throw .invalidSchema }
		let input: Data
		do { input = try schema.compactData(maximumBytes: 2 * 1024 * 1024) } catch { throw .tooLarge }
		let owned = input.withUnsafeBytes { bytes in
			OwnedResult(lpm_env_validate(bytes.bindMemory(to: UInt8.self).baseAddress, input.count))
		}
		return try owned.decode()
	}

	static func resolve(_ schema: LPMConfigJSON, inFolder folder: String) throws(ProjectEnvSchemaFile.FileError) -> Resolution {
		try resolved(try resolution(of: schema, inFolder: folder))
	}

	/// `resolve`, or why the engine rejects `schema`, from one resolution.
	static func resolveOrDiagnose(_ schema: LPMConfigJSON, inFolder folder: String) throws(ProjectEnvSchemaFile.FileError) -> Result<Resolution, RejectedSchema> {
		let owned = try resolution(of: schema, inFolder: folder)
		guard owned.result.status != 1 else { return .failure(RejectedSchema(diagnostic: owned.diagnostic())) }
		return .success(try resolved(owned))
	}

	/// The engine rejected a schema; the diagnostic is nil when it gave none.
	struct RejectedSchema: Error, Sendable {
		let diagnostic: Diagnostic?
	}

	private static func resolved(_ owned: OwnedResult) throws(ProjectEnvSchemaFile.FileError) -> Resolution {
		let output = try owned.decode()
		guard owned.result.snapshot != nil else { throw .invalidSchema }
		return Resolution(resolved: try resolved(from: output), snapshot: Snapshot(owned: owned))
	}

	/// The engine's output budget, with the allowance on top of it that a
	/// resolution's provenance has, which the engine bounds.
	static let maximumOutputBytes = (8 + 2) * 1024 * 1024

	/// The engine's resolve output, checked field by field: provenance has to
	/// name what the effective schema declares, so a malformed output is
	/// rejected rather than shown.
	static func resolved(from output: LPMConfigJSON) throws(ProjectEnvSchemaFile.FileError) -> Resolved {
		guard output["abiVersion"] == .number("1"), let effective = output["effective"],
			case .array(let rawDependencies)? = output["dependencies"], case .object(let rawReplaced)? = output["replacedVars"],
			case .object(let rawReplacedGroups)? = output["replacedGroups"], case .array(let rawSources)? = output["sources"]
		else { throw .invalidSchema }
		func origin(_ value: LPMConfigJSON?) throws(ProjectEnvSchemaFile.FileError) -> Origin {
			guard case .string(let source)? = value?["source"], case .string(let pointer)? = value?["pointer"] else { throw .invalidSchema }
			return Origin(source: source, pointer: pointer)
		}
		func origins(_ field: String) throws(ProjectEnvSchemaFile.FileError) -> [String: Origin] {
			guard case .object(let members)? = output[field] else { throw .invalidSchema }
			var origins = Dictionary<String, Origin>(minimumCapacity: members.count)
			for member in members { origins[member.key] = try origin(member.value) }
			return origins
		}
		// Provenance names each file once in `sources`, and by its index elsewhere.
		var sources: [String] = []
		sources.reserveCapacity(rawSources.count)
		for value in rawSources {
			guard case .string(let source) = value else { throw .invalidSchema }
			sources.append(source)
		}
		func source(_ value: LPMConfigJSON?) throws(ProjectEnvSchemaFile.FileError) -> String {
			guard case .number(let raw)? = value, let index = Int(raw), sources.indices.contains(index) else { throw .invalidSchema }
			return sources[index]
		}
		func sourcesByName(_ field: String) throws(ProjectEnvSchemaFile.FileError) -> [String: String] {
			guard case .object(let members)? = output[field] else { throw .invalidSchema }
			var named = Dictionary<String, String>(minimumCapacity: members.count)
			for member in members { named[member.key] = try source(member.value) }
			return named
		}
		let keyOrigins = try origins("origins")
		let groupOrigins = try origins("groupOrigins")
		let groupDeclaringSources = try sourcesByName("groupDeclaringOrigins")
		let clientPrefixSources = try sourcesByName("clientPrefixOrigins")
		guard groupDeclaringSources.keys.allSatisfy({ groupOrigins[$0] != nil }) else { throw .invalidSchema }
		var prefixes: Set<String> = []
		if case .array(let values)? = effective["clientPrefixes"] {
			for value in values {
				guard case .string(let prefix) = value else { throw .invalidSchema }
				prefixes.insert(prefix)
			}
		}
		guard Set(clientPrefixSources.keys) == prefixes else { throw .invalidSchema }
		var replacedRules = Dictionary<String, ReplacedRules>(minimumCapacity: rawReplaced.count)
		for member in rawReplaced {
			// Only lpm.json's own overrides replace anything it shows.
			guard let override = keyOrigins[member.key], override.source == "lpm.json", override.pointer.hasPrefix("/envSchema/overrides/"),
				case .number(let rawCount)? = member.value["count"], let count = Int(rawCount), count >= 1,
				case .bool(let client)? = member.value["client"]
			else { throw .invalidSchema }
			let secret: String? = if let value = member.value["secret"] { try source(value) } else { nil }
			replacedRules[member.key] = ReplacedRules(count: count, source: try source(member.value["origin"]), client: client, secret: secret)
		}
		var replacedGroups = Dictionary<String, ReplacedGroups>(minimumCapacity: rawReplacedGroups.count)
		for member in rawReplacedGroups {
			guard let override = groupOrigins[member.key], override.source == "lpm.json", override.pointer.hasPrefix("/envSchema/groupOverrides/"),
				case .number(let rawCount)? = member.value["count"], let count = Int(rawCount), count >= 1
			else { throw .invalidSchema }
			replacedGroups[member.key] = ReplacedGroups(count: count, source: try source(member.value["origin"]))
		}
		var dependencies: [Dependency] = []
		dependencies.reserveCapacity(rawDependencies.count)
		for dependency in rawDependencies {
			guard case .string(let path)? = dependency["path"] else { throw .invalidSchema }
			guard case .number(let count)? = dependency["bytes"], let bytes = Int(count), bytes >= 0 else { throw .invalidSchema }
			let digest = try byteArray(dependency["digest"])
			guard digest.count == 32 else { throw .invalidSchema }
			dependencies.append(Dependency(path: path, digest: digest, bytes: bytes))
		}
		return Resolved(effective: effective, origins: keyOrigins, groupOrigins: groupOrigins, declaringOrigins: try origins("declaringOrigins"),
			groupDeclaringSources: groupDeclaringSources, clientPrefixSources: clientPrefixSources, replacedRules: replacedRules,
			replacedGroups: replacedGroups, dependencies: dependencies)
	}

	/// The engine's evaluation of stored values against a flat schema, such as
	/// a resolution's `effective` schema; nil when it rejects either input.
	static func check(schema: Data, values: Data) -> LPMConfigJSON? {
		guard lpm_env_abi_version() == 1, !schema.isEmpty, !values.isEmpty else { return nil }
		let owned = schema.withUnsafeBytes { schema in
			values.withUnsafeBytes { values in
				OwnedResult(lpm_env_check(
					schema.bindMemory(to: UInt8.self).baseAddress, schema.count,
					values.bindMemory(to: UInt8.self).baseAddress, values.count
				))
			}
		}
		guard let output = try? owned.decode(), output["abiVersion"] == .number("1") else { return nil }
		return output
	}

	/// The characters in each environment's values that are hard to see, by
	/// the rule the LPM CLI uses. It needs no schema. Nil when the engine
	/// refuses the input, such as a key that isn't a valid name.
	static func checkCharacters(_ environments: [String: [String: String]]) -> ValueCharacterCheck? {
		guard lpm_env_abi_version() == 1 else { return nil }
		guard !environments.isEmpty else { return ValueCharacterCheck() }
		var members: [LPMConfigJSON.Member] = []
		members.reserveCapacity(environments.count)
		for (environment, values) in environments {
			members.append(.init(key: environment, value: .object(values.map { .init(key: $0.key, value: .string($0.value)) })))
		}
		let input: Data
		do { input = try LPMConfigJSON.object([.init(key: "environments", value: .object(members))]).compactData(maximumBytes: inputLimit) }
		catch { return nil }
		let owned = input.withUnsafeBytes { bytes in
			OwnedResult(lpm_env_check_characters(bytes.bindMemory(to: UInt8.self).baseAddress, input.count))
		}
		guard let output = try? owned.decode() else { return nil }
		return ValueCharacterCheck(output: output)
	}

	/// `value` with each character that's hard to see written as its escape,
	/// for showing someone who sees the value; nil when the engine can't.
	static func showCharacters(in value: String) -> ShownValueCharacters? {
		guard lpm_env_abi_version() == 1 else { return nil }
		var value = value
		let owned = value.withUTF8 { bytes in OwnedResult(lpm_env_show_characters(bytes.baseAddress, bytes.count)) }
		guard let output = try? owned.decode(), output["abiVersion"] == .number("1"),
			case .string(let text)? = output["text"], case .array(let rawMarks)? = output["marks"]
		else { return nil }
		let length = text.utf16.count
		var marks: [NSRange] = []
		marks.reserveCapacity(rawMarks.count)
		for mark in rawMarks {
			guard case .array(let bounds) = mark, bounds.count == 2,
				case .number(let rawStart) = bounds[0], let start = Int(rawStart),
				case .number(let rawLength) = bounds[1], let markLength = Int(rawLength),
				start >= 0, markLength > 0, start + markLength <= length
			else { return nil }
			marks.append(NSRange(location: start, length: markLength))
		}
		return ShownValueCharacters(text: text, marks: marks)
	}

	/// A fix a person chooses for a value's characters that are hard to see.
	enum CharacterFix: UInt32, Sendable {
		/// Removes each one other than whitespace at an end; makes a space other
		/// than U+0020 or a tab a plain space, a line break other than `\n` a
		/// `\n`, and drops the carriage return of each `\r\n`.
		case removeHiddenCharacters = 1
		/// Removes the whitespace at either end, keeping a multiline value's
		/// single final line break.
		case trimEnds = 2
	}

	/// `value` fixed as `fix` says; nil when the engine can't.
	static func fixCharacters(in value: String, _ fix: CharacterFix) -> String? {
		guard lpm_env_abi_version() == 1 else { return nil }
		var value = value
		let owned = value.withUTF8 { bytes in OwnedResult(lpm_env_fix_characters(bytes.baseAddress, bytes.count, fix.rawValue)) }
		defer { lpm_env_clear_output(&owned.result) }
		guard owned.result.status == 0, owned.result.length <= inputLimit else { return nil }
		guard owned.result.length > 0 else { return "" }
		guard let data = owned.result.data else { return nil }
		return String(decoding: UnsafeBufferPointer(start: data, count: owned.result.length), as: UTF8.self)
	}

	/// The most one engine call reads, `LPM_ENV_INPUT_LIMIT`.
	private static let inputLimit = 2 * 1024 * 1024

	/// Why `resolve` rejects `schema`, for showing the problem; nil when the
	/// schema resolves or fails for another reason.
	static func diagnostic(for schema: LPMConfigJSON, inFolder folder: String) -> Diagnostic? {
		(try? resolution(of: schema, inFolder: folder))?.diagnostic()
	}

	private static func resolution(of schema: LPMConfigJSON, inFolder folder: String) throws(ProjectEnvSchemaFile.FileError) -> OwnedResult {
		let schema = schema == .null ? .object([]) : schema
		guard lpm_env_abi_version() == 1, case .object = schema else { throw .invalidSchema }
		let input: Data
		do { input = try schema.compactData(maximumBytes: 2 * 1024 * 1024) } catch { throw .tooLarge }
		let path = Data(folder.utf8)
		return input.withUnsafeBytes { bytes in
			path.withUnsafeBytes { directory in
				OwnedResult(lpm_env_resolve(bytes.bindMemory(to: UInt8.self).baseAddress, input.count, directory.bindMemory(to: UInt8.self).baseAddress, path.count))
			}
		}
	}
	private static func byteArray(_ value: LPMConfigJSON?) throws(ProjectEnvSchemaFile.FileError) -> Data {
		guard case .array(let values)? = value else { throw .invalidSchema }
		var bytes = Data(); bytes.reserveCapacity(values.count)
		for value in values {
			guard case .number(let raw) = value, let byte = UInt8(raw) else { throw .invalidSchema }
			bytes.append(byte)
		}
		return bytes
	}

}
