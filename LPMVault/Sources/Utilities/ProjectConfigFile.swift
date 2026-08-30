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

	/// Adds or replaces the vault ID without following an existing symlink.
	/// Existing malformed or oversized files are left untouched.
	static func writeVaultID(_ vaultId: String, to url: URL) throws {
		let object: [String: Any]
		do {
			let data = try readRegularFile(at: url)
			guard let existing = try JSONSerialization.jsonObject(with: data) as? [String: Any]
			else { throw FileError.invalidJSON }
			object = existing
		} catch FileError.notFound {
			object = [:]
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
		try SecureFileWriter.write(data, to: url, permissions: 0o644)
	}

	private static func readRegularFile(at url: URL) throws -> Data {
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
