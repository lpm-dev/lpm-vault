import Darwin
import Foundation

/// Bounded, symlink-safe access to a project's `lpm.json` file.
enum ProjectConfigFile {
	private static let maximumBytes = 16 * 1024 * 1024

	enum FileError: Error {
		case notFound
		case unsafeFile
		case tooLarge
		case readFailed
		case invalidJSON
		case vaultChanged
	}

	enum VaultWritePolicy {
		case replaceAny
		case unlinked
		case replacing(String)
	}

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

	/// Adds or replaces the vault ID without following an existing symlink.
	/// Existing malformed or oversized files are left untouched.
	static func writeVaultID(
		_ vaultId: String,
		to url: URL,
		policy: VaultWritePolicy = .replaceAny,
		fileWriter: (Data, URL, Bool, @escaping () throws -> Void) throws -> Void = { data, url, replaceExisting, validation in
			try SecureFileWriter.write(data, to: url, permissions: 0o644, replaceExisting: replaceExisting, beforeReplacement: validation)
		}
	) throws {
		let object: [String: Any]
		let originalData: Data?
		do {
			let data = try readRegularFile(at: url)
			guard let existing = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
			else { throw FileError.invalidJSON }
			object = existing
			originalData = data
		} catch FileError.notFound {
			object = [:]
			originalData = nil
		}
		switch policy {
		case .replaceAny: break
		case .unlinked, .replacing:
			let existing = object["vault"]
			guard existing == nil || existing is NSNull || existing is String else {
				throw FileError.invalidJSON
			}
			let existingID = existing as? String
			switch policy {
			case .replaceAny: break
			case .unlinked:
				guard existingID == nil || existingID == vaultId else { throw FileError.vaultChanged }
			case .replacing(let expectedID):
				guard existingID == expectedID || existingID == vaultId else { throw FileError.vaultChanged }
			}
		}

		if object["vault"] as? String == vaultId { return }
		var updated = object
		updated["vault"] = vaultId
		guard JSONSerialization.isValidJSONObject(updated) else {
			throw FileError.invalidJSON
		}
		let data = try JSONSerialization.data(
			withJSONObject: updated,
			options: [.prettyPrinted, .sortedKeys]
		)
		do {
			try fileWriter(
				data, url, originalData != nil, {
					let current: Data?
					do { current = try readRegularFile(at: url) }
					catch FileError.notFound { current = nil }
					guard current == originalData else { throw FileError.vaultChanged }
				}
			)
		} catch SecureFileWriter.WriteError.replaceFailed(let code) where code == EEXIST {
			throw FileError.vaultChanged
		}
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
