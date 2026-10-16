import Darwin
import Foundation

/// The folder copied icon images are kept in. It's LPM Vault's own, so it's
/// used only as the user's private folder: never through a link, and made
/// private again when found open to others. Each operation goes through one
/// descriptor of it, so the folder can't be swapped for another midway.
enum ProjectIconImageFolder {
	/// Writes a new copied image; false when it can't be, or one has that name.
	static func write(_ data: Data, named name: String, in folder: URL) -> Bool {
		guard ProjectIconStore.isStoredImageName(name), let directory = try? open(folder, creating: true) else { return false }
		defer { Darwin.close(directory) }
		let file = openat(directory, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
		guard file >= 0 else { return false }
		let written = data.withUnsafeBytes { writeAll($0, to: file) }
		let closed = Darwin.close(file) == 0
		guard written, closed else {
			unlinkat(directory, name, 0)
			return false
		}
		return true
	}

	static func read(_ name: String, in folder: URL, maximumBytes: Int) throws(ProjectIconFile.Failure) -> (data: Data, signature: ProjectIconFileSignature) {
		guard ProjectIconStore.isStoredImageName(name) else { throw .unsafe }
		let directory = try open(folder, creating: false)
		defer { Darwin.close(directory) }
		return try ProjectIconFile.read(descriptor: openat(directory, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC), maximumBytes: maximumBytes)
	}

	static func signature(of name: String, in folder: URL) -> ProjectIconFileSignature? {
		guard ProjectIconStore.isStoredImageName(name), let directory = try? open(folder, creating: false) else { return nil }
		defer { Darwin.close(directory) }
		var info = stat()
		guard fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
		return ProjectIconFileSignature(info)
	}

	static func delete(_ names: some Sequence<String>, in folder: URL) {
		guard let directory = try? open(folder, creating: false) else { return }
		defer { Darwin.close(directory) }
		for name in names where ProjectIconStore.isStoredImageName(name) { unlinkat(directory, name, 0) }
	}

	/// Deletes the copied images not in `kept` that were last changed before `cutoff`.
	static func deleteImages(except kept: Set<String>, changedBefore cutoff: Date, in folder: URL) {
		guard let directory = try? open(folder, creating: false) else { return }
		defer { Darwin.close(directory) }
		let listing = dup(directory)
		guard listing >= 0, let entries = fdopendir(listing) else {
			if listing >= 0 { Darwin.close(listing) }
			return
		}
		defer { closedir(entries) }
		let cutoffNanoseconds = Int64(cutoff.timeIntervalSince1970 * 1_000_000_000)
		while let entry = readdir(entries) {
			let name = withUnsafeBytes(of: entry.pointee.d_name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
			guard ProjectIconStore.isStoredImageName(name), !kept.contains(name) else { continue }
			var info = stat()
			guard fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0, info.st_mode & S_IFMT == S_IFREG,
				ProjectIconFileSignature(info).modified < cutoffNanoseconds
			else { continue }
			unlinkat(directory, name, 0)
		}
	}

	/// The folder, opened without following a link, owned by the user and
	/// readable by no one else.
	private static func open(_ folder: URL, creating: Bool) throws(ProjectIconFile.Failure) -> Int32 {
		if creating { try? FileManager.default.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true) }
		let descriptor = folder.withUnsafeFileSystemRepresentation { path -> Int32 in
			guard let path else { return -1 }
			if creating, mkdir(path, 0o700) != 0, errno != EEXIST { return -1 }
			return Darwin.open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
		}
		guard descriptor >= 0 else { throw errno == ENOENT ? .missing : .unsafe }
		var info = stat()
		guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(),
			info.st_mode & 0o077 == 0 || fchmod(descriptor, 0o700) == 0
		else {
			Darwin.close(descriptor)
			throw .unsafe
		}
		return descriptor
	}

	private static func writeAll(_ bytes: UnsafeRawBufferPointer, to file: Int32) -> Bool {
		guard var next = bytes.baseAddress else { return bytes.isEmpty }
		var remaining = bytes.count
		while remaining > 0 {
			let count = Darwin.write(file, next, remaining)
			if count < 0 {
				if errno == EINTR { continue }
				return false
			}
			next += count
			remaining -= count
		}
		return true
	}
}
