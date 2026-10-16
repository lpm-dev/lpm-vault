import Observation
import os

/// Waits on observable state without polling: what's waited for is read
/// again only when something it read changes.
@MainActor
enum ObservedWait {
	/// The first value `evaluate` gives that isn't nil, or nil when `timeout`
	/// passes or the task is cancelled first.
	static func value<Value>(within timeout: Duration? = nil, _ evaluate: @escaping @MainActor () -> Value?) async -> Value? {
		let deadline = timeout.map { ContinuousClock.now + $0 }
		while !Task.isCancelled {
			let change = Change()
			let value = withObservationTracking { evaluate() } onChange: { change.resume(changed: true) }
			if let value { return value }
			guard await change.wait(until: deadline) else { return nil }
		}
		return nil
	}

	/// One change of what was read, which can come on any thread, or the end
	/// of waiting for it; whichever comes first decides.
	private final class Change: Sendable {
		private struct State {
			var outcome: Bool?
			var continuation: CheckedContinuation<Bool, Never>?
		}

		private let state = OSAllocatedUnfairLock(initialState: State())

		func resume(changed: Bool) {
			let continuation = state.withLock { state -> CheckedContinuation<Bool, Never>? in
				guard state.outcome == nil else { return nil }
				state.outcome = changed
				defer { state.continuation = nil }
				return state.continuation
			}
			continuation?.resume(returning: changed)
		}

		/// True once what was read changes, which may already have happened;
		/// false at `deadline`, if there's one, or when the task is cancelled.
		func wait(until deadline: ContinuousClock.Instant?) async -> Bool {
			let timer = deadline.map { deadline in
				Task { [self] in
					try? await Task.sleep(until: deadline)
					resume(changed: false)
				}
			}
			defer { timer?.cancel() }
			return await withTaskCancellationHandler {
				await withCheckedContinuation { continuation in
					let outcome = state.withLock { state in
						if state.outcome == nil { state.continuation = continuation }
						return state.outcome
					}
					if let outcome { continuation.resume(returning: outcome) }
				}
			} onCancel: {
				resume(changed: false)
			}
		}
	}
}
