import Darwin
import Foundation

/// Bounded, symlink-safe access to a project's `lpm.json` file.
enum ProjectConfigFile {
	private static let maximumBytes = 16 * 1024 * 1024

	enum FileError: Error, Equatable {
		case notFound
		case unsafeFile
		case tooLarge
		case readFailed
		case invalidJSON
		case duplicateJSONKey
		/// The file changed while it was being updated, or no longer matches what the edit expects.
		case changed
		case writeFailed(String)
	}

	enum VaultWritePolicy {
		case replaceAny
		case unlinked
		case replacing(String)
	}

	/// Writes `data` over `url` with `permissions`, running the check right before the replacement.
	typealias FileWriter = (_ data: Data, _ url: URL, _ permissions: mode_t, _ replaceExisting: Bool, _ check: @escaping () throws -> Void) throws -> Void

	/// The app's `lpm.json` edits run in order here, off the main thread and
	/// Swift's cooperative pool, because each waits for the CLI's config lock for
	/// as long as the CLI holds it.
	static let editQueue = DispatchQueue(label: "dev.lpm.vault.lpm-json", qos: .userInitiated)

	static func readObject(at url: URL) -> [String: Any]? {
		guard let data = try? readRegularFile(at: url),
			let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
		else { return nil }
		return object
	}

	static func readJSON(at url: URL) -> LPMJSONValue? {
		guard let data = try? readRegularFile(at: url) else { return nil }
		return try? JSONDecoder().decode(LPMJSONValue.self, from: data)
	}

	/// Returns the parsed file, or `nil` when it does not exist.
	static func readJSONIfPresent(at url: URL) throws(FileError) -> LPMJSONValue? {
		let data: Data
		do {
			data = try readRegularFile(at: url)
		} catch FileError.notFound {
			return nil
		} catch let error as FileError {
			throw error
		} catch {
			throw .readFailed
		}
		do {
			return try JSONDecoder().decode(LPMJSONValue.self, from: data)
		} catch {
			throw .invalidJSON
		}
	}

	/// Returns the `vault` field, or `nil` when the file has no vault ID.
	/// Throws `FileError.notFound` when the file does not exist.
	static func vaultID(at url: URL) throws -> String? {
		let data = try readRegularFile(at: url)
		guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
			throw FileError.invalidJSON
		}
		guard let vault = object["vault"], !(vault is NSNull) else { return nil }
		guard let vaultId = vault as? String else { throw FileError.invalidJSON }
		return vaultId
	}

	/// Adds or replaces the vault ID, keeping the rest of the file. Like the CLI,
	/// a new `vault` field goes last and an existing one keeps its place.
	static func writeVaultID(
		_ vaultId: String,
		to url: URL,
		policy: VaultWritePolicy = .replaceAny,
		fileWriter: FileWriter = writeSecurely
	) throws {
		try update(at: url, fileWriter: fileWriter) { document in
			if case .replaceAny = policy {} else {
				let linked: String?
				switch document["vault"] {
				case nil, .null?: linked = nil
				case .string(let id)?: linked = id
				case _?: throw FileError.invalidJSON
				}
				switch policy {
				case .replaceAny: break
				case .unlinked:
					guard linked == nil || linked == vaultId else { throw FileError.changed }
				case .replacing(let expected):
					guard linked == expected || linked == vaultId else { throw FileError.changed }
				}
			}
			document.set(.string(vaultId), forKey: "vault")
		}
	}

	/// Changes the `lpm.json` at `url` the way the CLI does: under its config
	/// lock, keeping member order, rendered like serde_json, and written only
	/// when the content changes. `change` gets the document, or an empty object
	/// when the file is missing; its errors pass through.
	static func update<T>(
		at url: URL,
		fileWriter: FileWriter = writeSecurely,
		rejectDuplicateKeys: Bool = false,
		beforeWrite: (() throws -> Void)? = nil,
		onWriteFailure: (() throws -> Void)? = nil,
		_ change: (inout LPMConfigJSON) throws -> T
	) throws -> T {
		try withConfigLock(in: url.deletingLastPathComponent()) {
			let original: Data?
			do {
				original = try readRegularFile(at: url)
			} catch FileError.notFound {
				original = nil
			}
			var document = LPMConfigJSON.object([])
			if let original {
				do {
					let parsed = try LPMConfigJSON(parsing: original, rejectDuplicateKeys: rejectDuplicateKeys)
					guard case .object = parsed else { throw FileError.invalidJSON }
					document = parsed
				} catch LPMConfigJSON.ParseError.duplicateKey {
					throw FileError.duplicateJSONKey
				} catch {
					throw FileError.invalidJSON
				}
			}
			let unchanged = document
			let result = try change(&document)
			guard document != unchanged else { try beforeWrite?(); return result }

			let data: Data
			do { data = try document.renderedData(maximumBytes: maximumBytes) } catch { throw FileError.tooLarge }
			var permissions = mode_t(0o644)
			var metadata = stat()
			if original != nil, lstat(url.path, &metadata) == 0 { permissions = metadata.st_mode & 0o777 }
			try beforeWrite?()
			do {
				try fileWriter(data, url, permissions, original != nil) {
					// The lock orders CLI edits; an editor saving meanwhile does not take it.
					let current: Data?
					do { current = try readRegularFile(at: url) } catch FileError.notFound { current = nil }
					guard current == original else { throw FileError.changed }
				}
			} catch {
				// Directory sync follows replacement; reverting only external state would break alignment.
				if case SecureFileWriter.WriteError.directorySyncFailed = error { throw error }
				try onWriteFailure?()
				if case SecureFileWriter.WriteError.replaceFailed(let code) = error, code == EEXIST { throw FileError.changed }
				throw error
			}
			return result
		}
	}

	static func writeSecurely(_ data: Data, to url: URL, permissions: mode_t, replaceExisting: Bool, check: @escaping () throws -> Void) throws {
		try SecureFileWriter.write(data, to: url, permissions: permissions, replaceExisting: replaceExisting, beforeReplacement: check)
	}

	/// Runs `body` holding the exclusive `flock` the CLI takes on `.lpm/.config.lock`.
	private static func withConfigLock<T>(in folder: URL, _ body: () throws -> T) throws -> T {
		let stateDirectory = folder.appendingPathComponent(".lpm", isDirectory: true)
		if mkdir(stateDirectory.path, 0o755) != 0, errno != EEXIST {
			throw FileError.writeFailed(String(cString: strerror(errno)))
		}
		var metadata = stat()
		guard lstat(stateDirectory.path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFDIR else { throw FileError.unsafeFile }
		let lockPath = stateDirectory.appendingPathComponent(".config.lock").path
		let descriptor = open(lockPath, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o644)
		guard descriptor >= 0 else {
			throw errno == ELOOP ? FileError.unsafeFile : FileError.writeFailed(String(cString: strerror(errno)))
		}
		defer { close(descriptor) }
		guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG else { throw FileError.unsafeFile }
		while flock(descriptor, LOCK_EX) != 0 {
			guard errno == EINTR else { throw FileError.writeFailed(String(cString: strerror(errno))) }
		}
		return try body()
	}

	static func readRegularFile(at url: URL) throws -> Data {
		guard url.isFileURL else { throw FileError.unsafeFile }
		let descriptor = url.withUnsafeFileSystemRepresentation { path in
			guard let path else { return Int32(-1) }
			return Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NONBLOCK | O_NOFOLLOW)
		}
		guard descriptor >= 0 else {
			if errno == ENOENT { throw FileError.notFound }
			if errno == ELOOP { throw FileError.unsafeFile }
			throw FileError.readFailed
		}
		defer { _ = Darwin.close(descriptor) }

		var metadata = stat()
		guard Darwin.fstat(descriptor, &metadata) == 0 else {
			throw FileError.readFailed
		}
		guard (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
			throw FileError.unsafeFile
		}
		guard metadata.st_size >= 0, metadata.st_size <= Int64(maximumBytes) else {
			throw FileError.tooLarge
		}

		var data = Data()
		data.reserveCapacity(Int(metadata.st_size))
		var buffer = [UInt8](repeating: 0, count: 64 * 1024)
		while true {
			let count = buffer.withUnsafeMutableBytes { bytes in
				Darwin.read(descriptor, bytes.baseAddress, bytes.count)
			}
			if count == 0 { break }
			if count < 0 {
				if errno == EINTR { continue }
				throw FileError.readFailed
			}
			guard data.count + count <= maximumBytes else { throw FileError.tooLarge }
			data.append(buffer, count: count)
		}
		return data
	}
}
