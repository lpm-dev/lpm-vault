import Darwin
import Foundation

final class EnvFileExportAuthorization: @unchecked Sendable {
	private let lock = NSLock()
	private var valid = true

	func invalidate() {
		lock.withLock { valid = false }
	}

	func check() throws {
		guard !Task.isCancelled, lock.withLock({ valid }) else {
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
		@Sendable ([String: String], URL, EnvFileExportAuthorization) throws -> Void
	/// Keeps the destination out of git before anything is written, given the
	/// project folder; returns what the user should know.
	typealias Preparer = @Sendable (_ destination: URL, _ project: URL) throws -> [String]
	static let shared = EnvFileExportService()

	private let admission: EnvFileExportAdmission
	private let preparer: Preparer
	private let worker: Worker

	/// Readies the destination as `lpm env export` does, through the CLI's own
	/// code: git is made to ignore it, and a file git tracks is refused.
	static let keepOutOfGit: Preparer = { destination, project in
		do throws(CLIFiles.Refusal) {
			return try CLIFiles.prepareSecretFile(at: destination, project: project).warnings
		} catch {
			if error.code == "env.secret_tracked" {
				throw EnvFileExportError.trackedByGit(file: destination.lastPathComponent, untrack: error.untrack ?? "`git rm --cached`")
			}
			throw EnvFileExportError.notKeptOutOfGit(reason: error.message)
		}
	}

	init(
		maximumConcurrentExports: Int = 2,
		worker: @escaping Worker = { secrets, destination, authorization in
			try authorization.check()
			let content = EnvFileCodec.formatData(secrets)
			try authorization.check()
			try SecureFileWriter.write(
				content,
				to: destination,
				authorization: authorization
			)
		},
		preparer: @escaping Preparer = keepOutOfGit
	) {
		self.admission = EnvFileExportAdmission(limit: maximumConcurrentExports)
		self.preparer = preparer
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
				try await BlockingWork.run { [preparer, worker] in
					try authorization.check()
					var isDirectory: ObjCBool = false
					let project = !projectFolder.isEmpty
						&& FileManager.default.fileExists(atPath: projectFolder, isDirectory: &isDirectory) && isDirectory.boolValue
						? URL(fileURLWithPath: projectFolder, isDirectory: true)
						: destination.deletingLastPathComponent()
					let warnings = try preparer(destination, project)
					try authorization.check()
					try worker(secrets, destination, authorization)
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
		authorization: EnvFileExportAuthorization? = nil,
		replaceExisting: Bool = true,
		beforeReplacement: @escaping () throws -> Void = {},
		directorySynchronizer: ((URL) -> Int32?)? = nil,
		directoryDescriptor: Int32? = nil
	) throws {
		try authorization?.check()
		let directory = destination.deletingLastPathComponent()
		let temporary = directory.appendingPathComponent(".lpm-vault-\(UUID().uuidString).tmp")
		let descriptor: Int32 = temporary.withUnsafeFileSystemRepresentation { path in
			guard let path else { return -1 }
			if let directoryDescriptor {
				return openat(directoryDescriptor, temporary.lastPathComponent, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, permissions)
			}
			return Darwin.open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, permissions)
		}
		guard descriptor >= 0 else { throw WriteError.createFailed(errno) }
		if let code = removeExtendedACL(from: descriptor) {
			_ = Darwin.close(descriptor)
			temporary.withUnsafeFileSystemRepresentation { path in
				if let directoryDescriptor { _ = unlinkat(directoryDescriptor, temporary.lastPathComponent, 0) }
				else if let path { _ = Darwin.unlink(path) }
			}
			throw WriteError.createFailed(code)
		}
		guard Darwin.fchmod(descriptor, permissions) == 0 else {
			let code = errno
			_ = Darwin.close(descriptor)
			temporary.withUnsafeFileSystemRepresentation { path in
				if let directoryDescriptor { _ = unlinkat(directoryDescriptor, temporary.lastPathComponent, 0) }
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
					if let directoryDescriptor { _ = unlinkat(directoryDescriptor, temporary.lastPathComponent, 0) }
				else if let path { _ = Darwin.unlink(path) }
				}
			}
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
		let replace = {
			try beforeReplacement()
			if let directoryDescriptor {
				renameStatus = replaceExisting
					? renameat(directoryDescriptor, temporary.lastPathComponent, directoryDescriptor, destination.lastPathComponent)
					: renameatx_np(directoryDescriptor, temporary.lastPathComponent, directoryDescriptor, destination.lastPathComponent, UInt32(RENAME_EXCL))
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
		}
		if let authorization {
			try authorization.commit(replace)
		} else {
			try Task.checkCancellation()
			try replace()
		}
		guard renameStatus == 0 else { throw WriteError.replaceFailed(errno) }
		shouldRemoveTemporary = false
		let syncFailure: Int32?
		if let directorySynchronizer { syncFailure = directorySynchronizer(directory) }
		else if let directoryDescriptor { syncFailure = fsync(directoryDescriptor) == 0 ? nil : errno }
		else { syncFailure = synchronizeDirectory(directory) }
		if let code = syncFailure {
			throw WriteError.directorySyncFailed(code)
		}
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
