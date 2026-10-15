import Dispatch

/// Runs blocking work, such as a Keychain call, the transaction lock shared
/// with the LPM CLI, or a disk write, on a queue of its own. Swift's
/// cooperative pool has about one thread per core, and every task needs
/// them to make progress, so work that waits there can stall the app.
///
/// The work still runs as part of the calling task, so it sees that task's
/// cancellation, priority and task-local values.
enum BlockingWork {
	static func run<Value: Sendable>(_ work: @Sendable () throws -> Value) async throws -> Value {
		try await Lane().run(work)
	}

	static func run<Value: Sendable>(_ work: @Sendable () -> Value) async -> Value {
		await Lane().run(work)
	}
}

/// A queue for one piece of work, so pieces never wait on each other; how
/// many run at once is for the caller to bound.
private actor Lane {
	private let queue = DispatchSerialQueue(label: "dev.lpm.vault.blocking-work", qos: .userInitiated)

	nonisolated var unownedExecutor: UnownedSerialExecutor {
		queue.asUnownedSerialExecutor()
	}

	func run<Value: Sendable>(_ work: @Sendable () throws -> Value) throws -> Value {
		try work()
	}

	func run<Value: Sendable>(_ work: @Sendable () -> Value) -> Value {
		work()
	}
}
