import Darwin
import Foundation

/// Reads a backup file the person chose through one descriptor: a regular
/// file, not a link, no larger than a backup can be, read to exactly the size
/// it had when opened.
enum BackupFileReader {
	struct File: Equatable, Sendable {
		let data: Data
		let name: String
		let modified: Date
	}

	enum Failure: Error, Equatable, Sendable {
		case unreadable
		case notAFile
		case tooLarge

		var message: String {
			switch self {
			case .unreadable: "That file can’t be read. Check it’s still there, then choose it again."
			case .notAFile: "Choose a backup file, not a folder or a link."
			case .tooLarge: BackupEngine.Failure.tooLarge.message
			}
		}
	}

	static func read(_ url: URL) throws(Failure) -> File {
		let descriptor = url.withUnsafeFileSystemRepresentation { path in
			path.map { Darwin.open($0, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC) } ?? -1
		}
		guard descriptor >= 0 else { throw errno == ELOOP ? .notAFile : .unreadable }
		defer { Darwin.close(descriptor) }
		var status = stat()
		guard fstat(descriptor, &status) == 0 else { throw .unreadable }
		guard status.st_mode & S_IFMT == S_IFREG else { throw .notAFile }
		guard status.st_size <= BackupEngine.maximumFileBytes else { throw .tooLarge }
		let size = Int(status.st_size)
		var data = Data(count: size)
		let complete = data.withUnsafeMutableBytes { buffer -> Bool in
			var offset = 0
			while offset < size {
				let count = Darwin.read(descriptor, buffer.baseAddress! + offset, size - offset)
				if count < 0, errno == EINTR { continue }
				guard count > 0 else { return false }
				offset += count
			}
			var extra: UInt8 = 0
			return Darwin.read(descriptor, &extra, 1) == 0
		}
		guard complete else { throw .unreadable }
		let modified = Date(
			timeIntervalSince1970: TimeInterval(status.st_mtimespec.tv_sec) + TimeInterval(status.st_mtimespec.tv_nsec) / 1e9)
		return File(data: data, name: url.lastPathComponent, modified: modified)
	}
}
