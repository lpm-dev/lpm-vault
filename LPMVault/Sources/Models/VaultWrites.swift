import Foundation

/// The writes running to the Keychain, a project's lpm.json, an exported
/// file or a platform, so quitting can let them finish first. Every write
/// begins and ends one here, so the count is the authority on whether
/// anything is still being written.
@MainActor
final class VaultWrites {
	/// A running write, which ends once however often it's ended.
	struct Write: Hashable {
		fileprivate let id: Int
	}

	private var nextID = 0
	private var running: Set<Int> = []
	private var waiters: [Int: CheckedContinuation<Bool, Never>] = [:]

	var isWriting: Bool { !running.isEmpty }

	/// Whether something is waiting for the writes to finish.
	var hasWaiters: Bool { !waiters.isEmpty }

	func begin() -> Write {
		nextID += 1
		running.insert(nextID)
		return Write(id: nextID)
	}

	func end(_ write: Write) {
		guard running.remove(write.id) != nil, running.isEmpty else { return }
		let finished = waiters
		waiters.removeAll()
		for continuation in finished.values { continuation.resume(returning: true) }
	}

	/// Returns true once no write is running, which may be at once, or false
	/// when `timeout` passes or the waiting task is cancelled first.
	func finish(within timeout: Duration) async -> Bool {
		guard isWriting else { return true }
		guard !Task.isCancelled else { return false }
		nextID += 1
		let id = nextID
		let timer = Task { [weak self] in
			try? await Task.sleep(for: timeout)
			self?.stopWaiting(id)
		}
		defer { timer.cancel() }
		return await withTaskCancellationHandler {
			await withCheckedContinuation { waiters[id] = $0 }
		} onCancel: {
			Task { @MainActor [weak self] in self?.stopWaiting(id) }
		}
	}

	private func stopWaiting(_ id: Int) {
		waiters.removeValue(forKey: id)?.resume(returning: false)
	}
}
