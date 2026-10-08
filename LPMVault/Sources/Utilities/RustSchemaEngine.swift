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

	struct Dependency: Sendable {
		let path: String
		let digest: Data
		let bytes: Int
	}

	struct Resolution: Sendable {
		let effective: LPMConfigJSON
		let origins: [String: Origin]
		let groupOrigins: [String: Origin]
		let declaringOrigins: [String: Origin]
		let dependencies: [Dependency]
		let snapshot: Snapshot
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
			guard result.length > 0, result.length <= 8 * 1024 * 1024, let data = result.data else { throw .invalidSchema }
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
		let owned = try resolution(of: schema, inFolder: folder)
		let output = try owned.decode()
		guard output["abiVersion"] == .number("1"), let effective = output["effective"], owned.result.snapshot != nil else { throw .invalidSchema }
		guard case .object(let rawOrigins)? = output["origins"], case .array(let rawDependencies)? = output["dependencies"] else { throw .invalidSchema }
		var origins = Dictionary<String, Origin>(minimumCapacity: rawOrigins.count)
		for member in rawOrigins {
			guard case .string(let source)? = member.value["source"], case .string(let pointer)? = member.value["pointer"] else { throw .invalidSchema }
			origins[member.key] = Origin(source: source, pointer: pointer)
		}
		guard case .object(let rawGroupOrigins)? = output["groupOrigins"] else { throw .invalidSchema }
		var groupOrigins = Dictionary<String, Origin>(minimumCapacity: rawGroupOrigins.count)
		for member in rawGroupOrigins {
			guard case .string(let source)? = member.value["source"], case .string(let pointer)? = member.value["pointer"] else { throw .invalidSchema }
			groupOrigins[member.key] = Origin(source: source, pointer: pointer)
		}
        guard case .object(let rawDeclaringOrigins)? = output["declaringOrigins"] else { throw .invalidSchema }
        var declaringOrigins = Dictionary<String, Origin>(minimumCapacity: rawDeclaringOrigins.count)
        for member in rawDeclaringOrigins {
            guard case .string(let source)? = member.value["source"], case .string(let pointer)? = member.value["pointer"] else { throw .invalidSchema }
            declaringOrigins[member.key] = Origin(source: source, pointer: pointer)
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
		return Resolution(effective: effective, origins: origins, groupOrigins: groupOrigins, declaringOrigins: declaringOrigins, dependencies: dependencies, snapshot: Snapshot(owned: owned))
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
