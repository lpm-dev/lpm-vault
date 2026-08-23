import Darwin
import Foundation

/// Atomically replaces a file with explicit permissions. Sensitive exports use
/// the owner-only default; non-secret project metadata can request `0o644`.
enum SecureFileWriter {
	enum WriteError: LocalizedError {
		case createFailed(Int32)
		case writeFailed(Int32)
		case syncFailed(Int32)
		case replaceFailed(Int32)

		var errorDescription: String? {
			let code: Int32
			let operation: String
			switch self {
			case .createFailed(let value):
				(code, operation) = (value, "create the private export")
			case .writeFailed(let value):
				(code, operation) = (value, "write the private export")
			case .syncFailed(let value):
				(code, operation) = (value, "save the private export")
			case .replaceFailed(let value):
				(code, operation) = (value, "replace the destination")
			}
			return "Could not \(operation): \(String(cString: strerror(code)))"
		}
	}

	static func write(
		_ data: Data,
		to destination: URL,
		permissions: mode_t = mode_t(S_IRUSR | S_IWUSR)
	) throws {
		let directory = destination.deletingLastPathComponent()
		let temporary = directory.appendingPathComponent(".lpm-vault-\(UUID().uuidString).tmp")
		let descriptor: Int32 = temporary.withUnsafeFileSystemRepresentation { path in
			guard let path else { return -1 }
			return Darwin.open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, permissions)
		}
		guard descriptor >= 0 else { throw WriteError.createFailed(errno) }
		guard Darwin.fchmod(descriptor, permissions) == 0 else {
			let code = errno
			_ = Darwin.close(descriptor)
			temporary.withUnsafeFileSystemRepresentation { path in
				if let path { _ = Darwin.unlink(path) }
			}
			throw WriteError.createFailed(code)
		}

		var shouldRemoveTemporary = true
		var descriptorIsOpen = true
		defer {
			if descriptorIsOpen { _ = Darwin.close(descriptor) }
			if shouldRemoveTemporary {
				temporary.withUnsafeFileSystemRepresentation { path in
					if let path { _ = Darwin.unlink(path) }
				}
			}
		}

		try data.withUnsafeBytes { rawBuffer in
			guard var address = rawBuffer.baseAddress else { return }
			var remaining = rawBuffer.count
			while remaining > 0 {
				let count = Darwin.write(descriptor, address, remaining)
				if count < 0 {
					if errno == EINTR { continue }
					throw WriteError.writeFailed(errno)
				}
				guard count > 0 else { throw WriteError.writeFailed(EIO) }
				remaining -= count
				address = address.advanced(by: count)
			}
		}

		guard Darwin.fsync(descriptor) == 0 else { throw WriteError.syncFailed(errno) }
		guard Darwin.close(descriptor) == 0 else {
			descriptorIsOpen = false
			throw WriteError.syncFailed(errno)
		}
		descriptorIsOpen = false

		let renameStatus: Int32 = temporary.withUnsafeFileSystemRepresentation { sourcePath in
			destination.withUnsafeFileSystemRepresentation { destinationPath in
				guard let sourcePath, let destinationPath else { return -1 }
				return Darwin.rename(sourcePath, destinationPath)
			}
		}
		guard renameStatus == 0 else { throw WriteError.replaceFailed(errno) }
		shouldRemoveTemporary = false
	}
}
