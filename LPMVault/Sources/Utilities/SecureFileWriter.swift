import Darwin
import Foundation

final class FileWriteAuthorization: @unchecked Sendable {
	private let lock = NSLock()
	private var valid = true

	func invalidate() {
		lock.withLock { valid = false }
	}

	var isValid: Bool { !Task.isCancelled && lock.withLock { valid } }

	func check() throws {
		guard isValid else {
			throw CancellationError()
		}
	}

	func commit(_ operation: () throws -> Void) throws {
		try lock.withLock {
			guard valid, !Task.isCancelled else { throw CancellationError() }
			try operation()
		}
	}
}

typealias EnvFileExportAuthorization = FileWriteAuthorization

/// Why an export wrote nothing: git would have committed the file.
enum EnvFileExportError: LocalizedError, Equatable, Sendable {
	/// Git tracks the file; `untrack` holds the commands that untrack it.
	case trackedByGit(file: String, untrack: String)
	/// The file couldn't be kept out of git, for `reason`.
	case notKeptOutOfGit(reason: String)

	var errorDescription: String? {
		switch self {
		case .trackedByGit(let file, let untrack):
			"Git tracks \(file), so the secrets exported there would be committed. Untrack it with \(untrack), then export again."
		case .notKeptOutOfGit(let reason):
			"\(reason.prefix(1).uppercased())\(reason.dropFirst()). Nothing was exported."
		}
	}
}

struct EnvFileExportService: Sendable {
	typealias Worker =
		@Sendable ([String: String], URL, URL, Int32, EnvFileExportAuthorization) throws -> Void
	/// Keeps the destination and its private staging directory out of git before
	/// anything is written, given the project folder; returns what the user should know.
	typealias Preparer = @Sendable (_ destination: URL, _ stagingDirectory: URL, _ project: URL) throws -> [String]
	static let shared = EnvFileExportService()
	static let stagingDirectoryName = ".lpm-vault-export-staging"

	private let admission: EnvFileExportAdmission
	private let preparer: Preparer
	private let preparationLock: EnvFileExportPreparationLock
	private let worker: Worker

	/// Readies the destination and staging directory through the CLI's own code:
	/// git is made to ignore both, and a tracked destination is refused.
	static let keepOutOfGit: Preparer = { destination, stagingDirectory, project in
		let destinationWarnings = try prepareSecretFile(destination, project: project, isDestination: true)
		let stagingWarnings = try prepareSecretFile(stagingDirectory, project: project, isDestination: false)
		return (destinationWarnings + stagingWarnings).reduce(into: []) { warnings, warning in
			if !warnings.contains(warning) { warnings.append(warning) }
		}
	}

	init(
		maximumConcurrentExports: Int = 2,
		worker: @escaping Worker = { secrets, destination, stagingDirectory, directoryDescriptor, authorization in
			try authorization.check()
			let content = EnvFileCodec.formatData(secrets)
			try authorization.check()
			try SecureFileWriter.write(
				content,
				to: destination,
				stagingDirectory: stagingDirectory,
				authorization: authorization,
				directoryDescriptor: directoryDescriptor
			)
		},
		preparer: @escaping Preparer = keepOutOfGit
	) {
		self.admission = EnvFileExportAdmission(limit: maximumConcurrentExports)
		self.preparer = preparer
		self.preparationLock = EnvFileExportPreparationLock()
		self.worker = worker
	}

	/// Writes `secrets` to `destination`, kept out of git first for the project
	/// in `projectFolder`, or else for the destination's own folder, as `lpm
	/// env export` run there would be. Returns what the user should know.
	@discardableResult
	func export(
		secrets: [String: String],
		to destination: URL,
		projectFolder: String = "",
		authorization: EnvFileExportAuthorization = EnvFileExportAuthorization()
	) async throws -> [String] {
		try authorization.check()
		try await admission.acquire()
		do {
			try authorization.check()
		} catch {
			await admission.release()
			throw error
		}

		do {
			let warnings = try await withTaskCancellationHandler {
				try await BlockingWork.run { [preparer, preparationLock, worker] in
					try authorization.check()
					var isDirectory: ObjCBool = false
					let project = !projectFolder.isEmpty
						&& FileManager.default.fileExists(atPath: projectFolder, isDirectory: &isDirectory) && isDirectory.boolValue
						? URL(fileURLWithPath: projectFolder, isDirectory: true)
						: destination.deletingLastPathComponent()
					let stagingDirectory = Self.stagingDirectory(for: destination)
					let destinationDirectory = destination.deletingLastPathComponent()
					let directoryDescriptor = try SecureFileWriter.openDirectory(at: destinationDirectory)
					defer { _ = Darwin.close(directoryDescriptor) }
					let warnings = try preparationLock.withLock {
						let warnings = try preparer(destination, stagingDirectory, project)
						guard SecureFileWriter.directoryAtPath(destinationDirectory, matches: directoryDescriptor) else {
							throw EnvFileExportError.notKeptOutOfGit(reason: "the export folder changed while Git protection was prepared")
						}
						return warnings
					}
					try authorization.check()
					try worker(secrets, destination, stagingDirectory, directoryDescriptor, authorization)
					return warnings
				}
			} onCancel: {
				authorization.invalidate()
			}
			await admission.release()
			return warnings
		} catch {
			authorization.invalidate()
			await admission.release()
			throw error
		}
	}

	static func stagingDirectory(for destination: URL) -> URL {
		let parent = destination.deletingLastPathComponent()
		for index in 0..<64 {
			let name = index == 0 ? stagingDirectoryName : "\(stagingDirectoryName)-\(index)"
			if equivalentFileName(destination.lastPathComponent, name) { continue }
			let candidate = parent.appendingPathComponent(name, isDirectory: true)
			if stagingCandidateIsAvailable(candidate) { return candidate }
		}
		return parent.appendingPathComponent("\(stagingDirectoryName)-\(UUID().uuidString)", isDirectory: true)
	}

	private static func equivalentFileName(_ left: String, _ right: String) -> Bool {
		left.compare(right, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) == .orderedSame
	}

	private static func stagingCandidateIsAvailable(_ candidate: URL) -> Bool {
		candidate.withUnsafeFileSystemRepresentation { path in
			guard let path else { return false }
			var status = stat()
			if lstat(path, &status) != 0 { return errno == ENOENT }
			return status.st_mode & S_IFMT == S_IFDIR
		}
	}

	private static func prepareSecretFile(
		_ file: URL,
		project: URL,
		isDestination: Bool
	) throws -> [String] {
		do throws(CLIFiles.Refusal) {
			return try CLIFiles.prepareSecretFile(at: file, project: project).warnings
		} catch {
			if isDestination, error.code == "env.secret_tracked" {
				throw EnvFileExportError.trackedByGit(file: file.lastPathComponent, untrack: error.untrack ?? "`git rm --cached`")
			}
			throw EnvFileExportError.notKeptOutOfGit(reason: error.message)
		}
	}
}

private final class EnvFileExportPreparationLock: @unchecked Sendable {
	private let lock = NSLock()

	func withLock<Result>(_ operation: () throws -> Result) rethrows -> Result {
		try lock.withLock(operation)
	}
}

actor EnvFileExportAdmission {
	private struct Waiter {
		let continuation: CheckedContinuation<Bool, Never>
		var previous: UUID?
		var next: UUID?
	}

	private let limit: Int
	private var active = 0
	private var head: UUID?
	private var tail: UUID?
	private var waiters: [UUID: Waiter] = [:]

	var queuedNodeCount: Int { waiters.count }

	init(limit: Int) {
		self.limit = max(1, limit)
	}

	func acquire() async throws {
		try Task.checkCancellation()
		if active < limit {
			active += 1
			return
		}

		let id = UUID()
		let admitted = await withTaskCancellationHandler {
			await withCheckedContinuation { continuation in
				if Task.isCancelled {
					continuation.resume(returning: false)
				} else {
					enqueue(id: id, continuation: continuation)
				}
			}
		} onCancel: {
			Task { await self.cancel(id) }
		}

		guard admitted else { throw CancellationError() }
		if Task.isCancelled {
			release()
			throw CancellationError()
		}
	}

	func release() {
		if let continuation = removeFirst() {
			continuation.resume(returning: true)
			return
		}
		active = max(0, active - 1)
	}

	private func cancel(_ id: UUID) {
		guard let continuation = remove(id: id) else { return }
		continuation.resume(returning: false)
	}

	private func enqueue(id: UUID, continuation: CheckedContinuation<Bool, Never>) {
		let previous = tail
		waiters[id] = Waiter(continuation: continuation, previous: previous, next: nil)
		if let previous, var waiter = waiters[previous] {
			waiter.next = id
			waiters[previous] = waiter
		} else {
			head = id
		}
		tail = id
	}

	private func removeFirst() -> CheckedContinuation<Bool, Never>? {
		guard let head else { return nil }
		return remove(id: head)
	}

	private func remove(id: UUID) -> CheckedContinuation<Bool, Never>? {
		guard let waiter = waiters.removeValue(forKey: id) else { return nil }
		if let previous = waiter.previous, var previousWaiter = waiters[previous] {
			previousWaiter.next = waiter.next
			waiters[previous] = previousWaiter
		} else {
			head = waiter.next
		}
		if let next = waiter.next, var nextWaiter = waiters[next] {
			nextWaiter.previous = waiter.previous
			waiters[next] = nextWaiter
		} else {
			tail = waiter.previous
		}
		return waiter.continuation
	}
}

/// Atomically replaces a file with explicit permissions. Sensitive exports use
/// the owner-only default; non-secret project metadata can request `0o644`.
enum SecureFileWriter {
	enum WriteError: LocalizedError, Equatable {
		case createFailed(Int32)
		case writeFailed(Int32)
		case syncFailed(Int32)
		case replaceFailed(Int32)
		case directorySyncFailed(Int32)

		var errorDescription: String? {
			let code: Int32
			let operation: String
			switch self {
			case .createFailed(let value):
				(code, operation) = (value, "create the file")
			case .writeFailed(let value):
				(code, operation) = (value, "write the file")
			case .syncFailed(let value):
				(code, operation) = (value, "save the file to disk")
			case .replaceFailed(let value):
				(code, operation) = (value, "replace the destination")
			case .directorySyncFailed(let value):
				(code, operation) = (value, "make the replacement crash-durable")
			}
			return "Could not \(operation): \(String(cString: strerror(code)))"
		}
	}

	static func write(
		_ data: Data,
		to destination: URL,
		permissions: mode_t = mode_t(S_IRUSR | S_IWUSR),
		stagingDirectory: URL? = nil,
		authorization: FileWriteAuthorization? = nil,
		replaceExisting: Bool = true,
		beforeWrite: @escaping (URL) throws -> Void = { _ in },
		beforeReplacement: @escaping () throws -> Void = {},
		directorySynchronizer: ((URL) -> Int32?)? = nil,
		directoryDescriptor: Int32? = nil
	) throws {
		try authorization?.check()
		let directory = destination.deletingLastPathComponent()
		if let stagingDirectory,
			stagingDirectory.deletingLastPathComponent().standardizedFileURL != directory.standardizedFileURL
		{
			throw WriteError.createFailed(EINVAL)
		}
		let temporaryDirectory = stagingDirectory ?? directory
		let temporary = temporaryDirectory.appendingPathComponent(".lpm-vault-\(UUID().uuidString).tmp")
		let openedDirectoryDescriptor: Int32?
		if stagingDirectory != nil, directoryDescriptor == nil {
			openedDirectoryDescriptor = directory.withUnsafeFileSystemRepresentation { path in
				guard let path else { return -1 }
				return Darwin.open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
			}
			guard let openedDirectoryDescriptor, openedDirectoryDescriptor >= 0 else {
				throw WriteError.createFailed(errno)
			}
		} else {
			openedDirectoryDescriptor = nil
		}
		defer {
			if let openedDirectoryDescriptor { _ = Darwin.close(openedDirectoryDescriptor) }
		}
		let replacementDirectoryDescriptor = directoryDescriptor ?? openedDirectoryDescriptor
		let stagingDescriptor = try stagingDirectory.map { stagingDirectory in
			guard let replacementDirectoryDescriptor else { throw WriteError.createFailed(EINVAL) }
			return try openSecureStagingDirectory(stagingDirectory, parentDescriptor: replacementDirectoryDescriptor)
		}
		defer {
			if let stagingDescriptor { _ = Darwin.close(stagingDescriptor) }
		}
		let temporaryDirectoryDescriptor = stagingDescriptor ?? directoryDescriptor
		let descriptor: Int32 = temporary.withUnsafeFileSystemRepresentation { path in
			guard let path else { return -1 }
			if let temporaryDirectoryDescriptor {
				return openat(temporaryDirectoryDescriptor, temporary.lastPathComponent, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, permissions)
			}
			return Darwin.open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, permissions)
		}
		guard descriptor >= 0 else { throw WriteError.createFailed(errno) }
		if let code = removeExtendedACL(from: descriptor) {
			_ = Darwin.close(descriptor)
			temporary.withUnsafeFileSystemRepresentation { path in
				if let temporaryDirectoryDescriptor { _ = unlinkat(temporaryDirectoryDescriptor, temporary.lastPathComponent, 0) }
				else if let path { _ = Darwin.unlink(path) }
			}
			throw WriteError.createFailed(code)
		}
		guard Darwin.fchmod(descriptor, permissions) == 0 else {
			let code = errno
			_ = Darwin.close(descriptor)
			temporary.withUnsafeFileSystemRepresentation { path in
				if let temporaryDirectoryDescriptor { _ = unlinkat(temporaryDirectoryDescriptor, temporary.lastPathComponent, 0) }
				else if let path { _ = Darwin.unlink(path) }
			}
			throw WriteError.createFailed(code)
		}

		var shouldRemoveTemporary = true
		var descriptorIsOpen = true
		defer {
			if descriptorIsOpen { _ = Darwin.close(descriptor) }
			if shouldRemoveTemporary {
				temporary.withUnsafeFileSystemRepresentation { path in
					if let temporaryDirectoryDescriptor { _ = unlinkat(temporaryDirectoryDescriptor, temporary.lastPathComponent, 0) }
				else if let path { _ = Darwin.unlink(path) }
				}
			}
		}
		try beforeWrite(temporary)
		if stagingDescriptor != nil, let replacementDirectoryDescriptor,
			!directoryAtPath(directory, matches: replacementDirectoryDescriptor)
		{
			throw WriteError.replaceFailed(ESTALE)
		}

		try data.withUnsafeBytes { rawBuffer in
			guard var address = rawBuffer.baseAddress else { return }
			var remaining = rawBuffer.count
			while remaining > 0 {
				try authorization?.check()
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

		try authorization?.check()
		guard Darwin.fsync(descriptor) == 0 else { throw WriteError.syncFailed(errno) }
		guard Darwin.close(descriptor) == 0 else {
			descriptorIsOpen = false
			throw WriteError.syncFailed(errno)
		}
		descriptorIsOpen = false

		var renameStatus: Int32 = -1
		var renameFailure = EIO
		let replace = {
			try beforeReplacement()
			if let stagingDescriptor, let replacementDirectoryDescriptor {
				guard directoryAtPath(directory, matches: replacementDirectoryDescriptor) else {
					throw WriteError.replaceFailed(ESTALE)
				}
				renameStatus = replaceExisting
					? renameat(stagingDescriptor, temporary.lastPathComponent, replacementDirectoryDescriptor, destination.lastPathComponent)
					: renameatx_np(stagingDescriptor, temporary.lastPathComponent, replacementDirectoryDescriptor, destination.lastPathComponent, UInt32(RENAME_EXCL))
				if renameStatus != 0 { renameFailure = errno }
				return
			}
			if let directoryDescriptor {
				renameStatus = replaceExisting
					? renameat(directoryDescriptor, temporary.lastPathComponent, directoryDescriptor, destination.lastPathComponent)
					: renameatx_np(directoryDescriptor, temporary.lastPathComponent, directoryDescriptor, destination.lastPathComponent, UInt32(RENAME_EXCL))
				if renameStatus != 0 { renameFailure = errno }
				return
			}
			renameStatus = temporary.withUnsafeFileSystemRepresentation { sourcePath in
				destination.withUnsafeFileSystemRepresentation { destinationPath in
					guard let sourcePath, let destinationPath else { return -1 }
					return replaceExisting
						? Darwin.rename(sourcePath, destinationPath)
						: Darwin.renamex_np(sourcePath, destinationPath, UInt32(RENAME_EXCL))
				}
			}
			if renameStatus != 0 { renameFailure = errno }
		}
		if let authorization {
			try authorization.commit(replace)
		} else {
			try Task.checkCancellation()
			try replace()
		}
		guard renameStatus == 0 else { throw WriteError.replaceFailed(renameFailure) }
		shouldRemoveTemporary = false
		let syncFailure: Int32?
		if let directorySynchronizer {
			syncFailure = directorySynchronizer(directory)
				?? stagingDirectory.flatMap { directorySynchronizer($0) }
		} else if let replacementDirectoryDescriptor {
			syncFailure = fsync(replacementDirectoryDescriptor) == 0
				? stagingDescriptor.flatMap { fsync($0) == 0 ? nil : errno }
				: errno
		}
		else { syncFailure = synchronizeDirectory(directory) }
		if let code = syncFailure {
			throw WriteError.directorySyncFailed(code)
		}
	}

	private static func openSecureStagingDirectory(_ directory: URL, parentDescriptor: Int32) throws -> Int32 {
		let name = directory.lastPathComponent
		let createStatus = Darwin.mkdirat(parentDescriptor, name, mode_t(S_IRWXU))
		if createStatus != 0, errno != EEXIST { throw WriteError.createFailed(errno) }
		let descriptor = Darwin.openat(parentDescriptor, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
		guard descriptor >= 0 else { throw WriteError.createFailed(errno) }
		var status = stat()
		guard fstat(descriptor, &status) == 0 else {
			let code = errno
			_ = Darwin.close(descriptor)
			throw WriteError.createFailed(code)
		}
		guard status.st_uid == geteuid() else {
			_ = Darwin.close(descriptor)
			throw WriteError.createFailed(EPERM)
		}
		if let code = removeExtendedACL(from: descriptor) {
			_ = Darwin.close(descriptor)
			throw WriteError.createFailed(code)
		}
		guard Darwin.fchmod(descriptor, mode_t(S_IRWXU)) == 0 else {
			let code = errno
			_ = Darwin.close(descriptor)
			throw WriteError.createFailed(code)
		}
		do {
			try ensureStagingContentsAreIgnored(in: descriptor)
		} catch {
			_ = Darwin.close(descriptor)
			throw error
		}
		return descriptor
	}

	private static func ensureStagingContentsAreIgnored(in directoryDescriptor: Int32) throws {
		guard flock(directoryDescriptor, LOCK_EX) == 0 else { throw WriteError.createFailed(errno) }
		defer { _ = flock(directoryDescriptor, LOCK_UN) }
		let name = ".gitignore"
		var created = true
		var descriptor = Darwin.openat(
			directoryDescriptor,
			name,
			O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
			mode_t(S_IRUSR | S_IWUSR)
		)
		if descriptor < 0, errno == EEXIST {
			created = false
			descriptor = Darwin.openat(directoryDescriptor, name, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
		}
		guard descriptor >= 0 else { throw WriteError.createFailed(errno) }
		var completed = false
		defer {
			_ = Darwin.close(descriptor)
			if created, !completed { _ = unlinkat(directoryDescriptor, name, 0) }
		}
		var status = stat()
		guard fstat(descriptor, &status) == 0 else { throw WriteError.createFailed(errno) }
		guard status.st_mode & S_IFMT == S_IFREG, status.st_uid == geteuid(), status.st_nlink == 1 else {
			throw WriteError.createFailed(EPERM)
		}
		if let code = removeExtendedACL(from: descriptor) { throw WriteError.createFailed(code) }
		guard Darwin.fchmod(descriptor, mode_t(S_IRUSR | S_IWUSR)) == 0 else { throw WriteError.createFailed(errno) }
		let rule = Data("*\n".utf8)
		if created || status.st_size == 0 {
			guard Darwin.ftruncate(descriptor, 0) == 0 else { throw WriteError.writeFailed(errno) }
			try rule.withUnsafeBytes { bytes in
				guard let address = bytes.baseAddress else { return }
				var written = 0
				while written < bytes.count {
					let count = Darwin.pwrite(descriptor, address.advanced(by: written), bytes.count - written, off_t(written))
					if count < 0 {
						if errno == EINTR { continue }
						throw WriteError.writeFailed(errno)
					}
					guard count > 0 else { throw WriteError.writeFailed(EIO) }
					written += count
				}
			}
		} else {
			guard status.st_size == rule.count else { throw WriteError.createFailed(EEXIST) }
			var existing = Data(count: rule.count)
			try existing.withUnsafeMutableBytes { bytes in
				guard let address = bytes.baseAddress else { return }
				var readCount = 0
				while readCount < bytes.count {
					let count = Darwin.pread(descriptor, address.advanced(by: readCount), bytes.count - readCount, off_t(readCount))
					if count < 0 {
						if errno == EINTR { continue }
						throw WriteError.createFailed(errno)
					}
					guard count > 0 else { throw WriteError.createFailed(EIO) }
					readCount += count
				}
			}
			guard existing == rule else { throw WriteError.createFailed(EEXIST) }
		}
		guard Darwin.fsync(descriptor) == 0, Darwin.fsync(directoryDescriptor) == 0 else {
			throw WriteError.syncFailed(errno)
		}
		completed = true
	}

	static func openDirectory(at directory: URL) throws -> Int32 {
		let descriptor: Int32 = directory.withUnsafeFileSystemRepresentation { path in
			guard let path else { return -1 }
			return Darwin.open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
		}
		guard descriptor >= 0 else { throw WriteError.createFailed(errno) }
		return descriptor
	}

	static func directoryAtPath(_ directory: URL, matches retainedDescriptor: Int32) -> Bool {
		let currentDescriptor: Int32 = directory.withUnsafeFileSystemRepresentation { path in
			guard let path else { return -1 }
			return Darwin.open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
		}
		guard currentDescriptor >= 0 else { return false }
		defer { _ = Darwin.close(currentDescriptor) }
		var current = stat()
		var retained = stat()
		guard fstat(currentDescriptor, &current) == 0, fstat(retainedDescriptor, &retained) == 0 else { return false }
		return current.st_dev == retained.st_dev && current.st_ino == retained.st_ino
	}

	private static func synchronizeDirectory(_ directory: URL) -> Int32? {
		let descriptor: Int32 = directory.withUnsafeFileSystemRepresentation { path in
			guard let path else { return -1 }
			return Darwin.open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
		}
		guard descriptor >= 0 else { return errno }
		defer { _ = Darwin.close(descriptor) }
		guard Darwin.fsync(descriptor) == 0 else { return errno }
		return nil
	}

	/// Removes every extended access list entry from an open file, such as
	/// those it inherited from its directory; returns the errno on failure.
	static func removeExtendedACL(from descriptor: Int32) -> Int32? {
		guard let acl = acl_init(0) else { return errno }
		defer { acl_free(UnsafeMutableRawPointer(acl)) }
		guard acl_set_fd_np(descriptor, acl, ACL_TYPE_EXTENDED) == 0 else { return errno }
		return nil
	}
}
