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
	typealias FileWriter = (_ data: Data, _ url: URL, _ permissions: mode_t, _ replaceExisting: Bool, _ directoryDescriptor: Int32, _ check: @escaping () throws -> Void) throws -> Void

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
		requiresUniqueKeys: ((LPMConfigJSON) throws -> Bool)? = nil,
		validateSources: (() throws -> Void)? = nil,
		beforeWrite: (() throws -> Void)? = nil,
		onWriteFailure: (() throws -> Void)? = nil,
		_ change: (inout LPMConfigJSON) throws -> T
	) throws -> T {
		let directory = try DirectorySnapshot(url.deletingLastPathComponent())
		return try withConfigLock(in: directory) {
			try updateInDirectory(at: url, directory: directory, fileWriter: fileWriter, rejectDuplicateKeys: rejectDuplicateKeys, requiresUniqueKeys: requiresUniqueKeys, validateSources: validateSources, beforeWrite: beforeWrite, onWriteFailure: onWriteFailure, change)
		}
	}

	private static func updateInDirectory<T>(
		at url: URL, directory: DirectorySnapshot, fileWriter: FileWriter,
		rejectDuplicateKeys: Bool, requiresUniqueKeys: ((LPMConfigJSON) throws -> Bool)? = nil, maximumOutputBytes: Int = maximumBytes,
		additionalCheck: (() throws -> Void)? = nil, preservingMemberAt: [String]? = nil,
		validateSources: (() throws -> Void)? = nil,
		beforeWrite: (() throws -> Void)? = nil, onWriteFailure: (() throws -> Void)? = nil,
		_ change: (inout LPMConfigJSON) throws -> T
	) throws -> T {
		try directory.verifySelection()
		let original: Data?
		do {
			original = try readRegularFile(in: directory, name: url.lastPathComponent)
		} catch FileError.notFound {
			original = nil
		}
		var document = LPMConfigJSON.object([])
		if let original {
			do {
				let parsed = try LPMConfigJSON(parsing: original, rejectDuplicateKeys: rejectDuplicateKeys)
				guard case .object = parsed else { throw FileError.invalidJSON }
				document = parsed
				if let requiresUniqueKeys, try requiresUniqueKeys(document) { _ = try LPMConfigJSON(parsing: original, rejectDuplicateKeys: true) }
			} catch LPMConfigJSON.ParseError.duplicateKey {
				throw FileError.duplicateJSONKey
			} catch {
				throw FileError.invalidJSON
			}
		}
		let unchanged = document
		let result = try change(&document)
		let checkSnapshot = {
			let current: Data?
			try directory.verifySelection()
			do { current = try readRegularFile(in: directory, name: url.lastPathComponent) } catch FileError.notFound { current = nil }
			guard current == original else { throw FileError.changed }
			try additionalCheck?()
			try validateSources?()
		}
		guard document != unchanged else {
			try checkSnapshot()
			try beforeWrite?()
			do { try checkSnapshot() } catch {
				try onWriteFailure?()
				throw error
			}
			return result
		}

		let data: Data
		do {
			if let original, let path = preservingMemberAt {
				var rule: LPMConfigJSON? = document
				for part in path { rule = rule?[part] }
				data = try LPMConfigJSON.editingMember(in: original, path: path, key: "description", value: rule?["description"], maximumBytes: maximumOutputBytes)
				guard try LPMConfigJSON(parsing: data, rejectDuplicateKeys: true) == document else { throw FileError.invalidJSON }
			} else { data = try document.renderedData(maximumBytes: maximumOutputBytes) }
		} catch LPMConfigJSON.RenderError.tooLarge { throw FileError.tooLarge }
		var permissions = mode_t(0o644)
		var metadata = stat()
		if original != nil, fstatat(directory.descriptor, url.lastPathComponent, &metadata, AT_SYMLINK_NOFOLLOW) == 0 { permissions = metadata.st_mode & 0o777 }
		try checkSnapshot()
		try beforeWrite?()
		do {
			try fileWriter(data, url, permissions, original != nil, directory.descriptor) {
				// The lock orders CLI edits; an editor saving meanwhile does not take it.
				try checkSnapshot()
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

	final class RootTransaction {
		fileprivate let directory: DirectorySnapshot
		let document: LPMConfigJSON
		private let original: Data?

		fileprivate init(directory: DirectorySnapshot) throws {
			self.directory = directory
			do { original = try readRegularFile(in: directory, name: "lpm.json") } catch FileError.notFound { original = nil }
			if let original {
				do {
					document = try LPMConfigJSON(parsing: original)
					guard case .object = document else { throw FileError.invalidJSON }
				} catch LPMConfigJSON.ParseError.duplicateKey { throw FileError.duplicateJSONKey }
                catch is LPMConfigJSON.ParseError { throw FileError.invalidJSON }
			} else { document = .object([]) }
		}

		func requireUniqueKeys() throws {
			guard let original else { return }
			do { _ = try LPMConfigJSON(parsing: original, rejectDuplicateKeys: true) }
			catch LPMConfigJSON.ParseError.duplicateKey { throw FileError.duplicateJSONKey }
			catch { throw FileError.invalidJSON }
		}

		func verify() throws {
			try directory.verifySelection()
			let current: Data?
			do { current = try readRegularFile(in: directory, name: "lpm.json") } catch FileError.notFound { current = nil }
			guard current == original else { throw FileError.changed }
		}

		func update<T>(
			relativePath: String, fileWriter: FileWriter = writeSecurely, rejectDuplicateKeys: Bool = true, preservingMemberAt: [String]? = nil,
			validateSources: (() throws -> Void)? = nil,
			beforeWrite: (() throws -> Void)? = nil, onWriteFailure: (() throws -> Void)? = nil,
			_ change: (inout LPMConfigJSON) throws -> T
		) throws -> T {
			let parts = relativePath.split(separator: "/", omittingEmptySubsequences: false)
			guard let filename = parts.last, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\\") && !$0.contains("\0") }) else { throw FileError.unsafeFile }
			var target = directory
			var project = directory
			for part in parts.dropLast() {
				target = try DirectorySnapshot(parent: target, name: String(part))
				var metadata = stat()
				if fstatat(target.descriptor, "lpm.json", &metadata, AT_SYMLINK_NOFOLLOW) == 0, metadata.st_mode & S_IFMT == S_IFREG { project = target }
			}
			let url = target.url.appendingPathComponent(String(filename))
			if project.sameIdentity(as: directory) {
				return try updateInDirectory(at: url, directory: target, fileWriter: fileWriter, rejectDuplicateKeys: rejectDuplicateKeys,
					maximumOutputBytes: relativePath == "lpm.json" ? maximumBytes : 2 * 1024 * 1024,
					additionalCheck: { try self.verify() }, preservingMemberAt: preservingMemberAt, validateSources: validateSources,
					beforeWrite: beforeWrite, onWriteFailure: onWriteFailure, change)
			}
			return try withConfigLock(in: project) {
				return try updateInDirectory(at: url, directory: target, fileWriter: fileWriter, rejectDuplicateKeys: rejectDuplicateKeys,
					maximumOutputBytes: relativePath == "lpm.json" ? maximumBytes : 2 * 1024 * 1024,
					additionalCheck: { try self.verify() }, preservingMemberAt: preservingMemberAt, validateSources: validateSources,
					beforeWrite: beforeWrite, onWriteFailure: onWriteFailure, change)
			}
		}
	}

	static func withRootTransaction<T>(at url: URL, _ body: (RootTransaction) throws -> T) throws -> T {
		let directory = try DirectorySnapshot(url.deletingLastPathComponent())
		return try withConfigLock(in: directory) {
			try directory.verifySelection()
			return try body(RootTransaction(directory: directory))
		}
	}

	static func writeSecurely(_ data: Data, to url: URL, permissions: mode_t, replaceExisting: Bool, directoryDescriptor: Int32, check: @escaping () throws -> Void) throws {
		try SecureFileWriter.write(data, to: url, permissions: permissions, replaceExisting: replaceExisting, beforeReplacement: check, directoryDescriptor: directoryDescriptor)
	}

	fileprivate final class DirectorySnapshot {
		let descriptor: Int32
		let url: URL
		private let device: dev_t
		private let inode: ino_t
		private var parent: DirectorySnapshot?
		private var component: String?

		init(_ url: URL) throws {
			guard url.isFileURL else { throw FileError.unsafeFile }
			let descriptor = Darwin.open(url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
			guard descriptor >= 0 else { throw FileError.readFailed }
			var metadata = stat()
			guard fstat(descriptor, &metadata) == 0 else { close(descriptor); throw FileError.readFailed }
			self.descriptor = descriptor
			self.url = url
			device = metadata.st_dev
			inode = metadata.st_ino
		}

		init(parent: DirectorySnapshot, name: String) throws {
			let descriptor = openat(parent.descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
			guard descriptor >= 0 else { throw FileError.unsafeFile }
			var metadata = stat()
			guard fstat(descriptor, &metadata) == 0 else { close(descriptor); throw FileError.readFailed }
			self.descriptor = descriptor; url = parent.url.appendingPathComponent(name, isDirectory: true)
			device = metadata.st_dev; inode = metadata.st_ino
			self.parent = parent; component = name
		}

		func sameIdentity(as other: DirectorySnapshot) -> Bool { device == other.device && inode == other.inode }

		deinit { close(descriptor) }

		func verifySelection() throws {
			try parent?.verifySelection()
			let current: Int32
			if let parent, let component { current = openat(parent.descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
			else { current = Darwin.open(url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC) }
			guard current >= 0 else { throw FileError.changed }
			defer { close(current) }
			var metadata = stat()
			guard fstat(current, &metadata) == 0, metadata.st_dev == device, metadata.st_ino == inode else { throw FileError.changed }
		}
	}

	private static func withConfigLock<T>(in directory: DirectorySnapshot, _ body: () throws -> T) throws -> T {
		if mkdirat(directory.descriptor, ".lpm", 0o755) != 0, errno != EEXIST {
			throw FileError.writeFailed(String(cString: strerror(errno)))
		}
		let state = openat(directory.descriptor, ".lpm", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
		guard state >= 0 else { throw FileError.unsafeFile }
		defer { close(state) }
		let descriptor = openat(state, ".config.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o644)
		guard descriptor >= 0 else {
			throw errno == ELOOP ? FileError.unsafeFile : FileError.writeFailed(String(cString: strerror(errno)))
		}
		defer { close(descriptor) }
		var metadata = stat()
		guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG else { throw FileError.unsafeFile }
		while flock(descriptor, LOCK_EX) != 0 {
			guard errno == EINTR else { throw FileError.writeFailed(String(cString: strerror(errno))) }
		}
		return try body()
	}

	private static func readRegularFile(in directory: DirectorySnapshot, name: String) throws -> Data {
		try readRegularFile(descriptor: openat(directory.descriptor, name, O_RDONLY | O_CLOEXEC | O_NONBLOCK | O_NOFOLLOW))
	}

	static func readRegularFile(at url: URL) throws -> Data {
		guard url.isFileURL else { throw FileError.unsafeFile }
		let descriptor = url.withUnsafeFileSystemRepresentation { path in
			guard let path else { return Int32(-1) }
			return Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NONBLOCK | O_NOFOLLOW)
		}
		return try readRegularFile(descriptor: descriptor)
	}

	private static func readRegularFile(descriptor: Int32) throws -> Data {
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
