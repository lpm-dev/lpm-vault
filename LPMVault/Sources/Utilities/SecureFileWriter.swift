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

struct EnvFileExportService: Sendable {
	typealias Worker =
		@Sendable ([String: String], URL, EnvFileExportAuthorization) throws -> Void
	static let shared = EnvFileExportService()

	private let admission: EnvFileExportAdmission
	private let worker: Worker

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
		}
	) {
		self.admission = EnvFileExportAdmission(limit: maximumConcurrentExports)
		self.worker = worker
	}

	func export(
		secrets: [String: String],
		to destination: URL,
		authorization: EnvFileExportAuthorization = EnvFileExportAuthorization()
	) async throws {
		try authorization.check()
		try await admission.acquire()
		do {
			try authorization.check()
		} catch {
			await admission.release()
			throw error
		}

		let backgroundTask = Task.detached(priority: .userInitiated) { [worker] in
			try authorization.check()
			try worker(secrets, destination, authorization)
		}
		do {
			try await withTaskCancellationHandler {
				try await backgroundTask.value
			} onCancel: {
				authorization.invalidate()
				backgroundTask.cancel()
			}
			await admission.release()
		} catch {
			authorization.invalidate()
			backgroundTask.cancel()
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
				(code, operation) = (value, "create the private export")
			case .writeFailed(let value):
				(code, operation) = (value, "write the private export")
			case .syncFailed(let value):
				(code, operation) = (value, "save the private export")
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
		directorySynchronizer: (URL) -> Int32? = synchronizeDirectory
	) throws {
		try authorization?.check()
		let directory = destination.deletingLastPathComponent()
		let temporary = directory.appendingPathComponent(".lpm-vault-\(UUID().uuidString).tmp")
		let descriptor: Int32 = temporary.withUnsafeFileSystemRepresentation { path in
			guard let path else { return -1 }
			return Darwin.open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, permissions)
		}
		guard descriptor >= 0 else { throw WriteError.createFailed(errno) }
		if let code = removeExtendedACL(from: descriptor) {
			_ = Darwin.close(descriptor)
			temporary.withUnsafeFileSystemRepresentation { path in
				if let path { _ = Darwin.unlink(path) }
			}
			throw WriteError.createFailed(code)
		}
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
			renameStatus = temporary.withUnsafeFileSystemRepresentation { sourcePath in
				destination.withUnsafeFileSystemRepresentation { destinationPath in
					guard let sourcePath, let destinationPath else { return -1 }
					return Darwin.rename(sourcePath, destinationPath)
				}
			}
		}
		if let authorization {
			try authorization.commit(replace)
		} else {
			try Task.checkCancellation()
			replace()
		}
		guard renameStatus == 0 else { throw WriteError.replaceFailed(errno) }
		shouldRemoveTemporary = false
		if let code = directorySynchronizer(directory) {
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

	private static func removeExtendedACL(from descriptor: Int32) -> Int32? {
		guard let acl = acl_init(0) else { return errno }
		defer { acl_free(UnsafeMutableRawPointer(acl)) }
		guard acl_set_fd_np(descriptor, acl, ACL_TYPE_EXTENDED) == 0 else { return errno }
		return nil
	}
}
