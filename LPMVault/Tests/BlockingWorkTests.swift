import Foundation
import Testing
@testable import LPMVault

struct BlockingWorkTests {
	@Test("work runs off the cooperative pool and hands back its value or error")
	func runsOffPool() async throws {
		#expect(await BlockingWork.run { isOnCooperativePool() } == false)
		#expect(await BlockingWork.run { 42 } == 42)
		await #expect(throws: CancellationError.self) {
			try await BlockingWork.run { () throws -> Int in throw CancellationError() }
		}
	}

	@Test("work runs as part of its task, so it sees the task's cancellation and task-local values")
	func keepsTaskContext() async {
		let sawCancellation = await Task {
			withUnsafeCurrentTask { $0?.cancel() }
			return await BlockingWork.run { Task.isCancelled }
		}.value
		#expect(sawCancellation)
		let seen = await BlockingWorkProbe.$value.withValue("set") {
			await BlockingWork.run { BlockingWorkProbe.value }
		}
		#expect(seen == "set")
	}

	@Test("pieces of work never wait on each other, so one can release another")
	func runsConcurrently() async {
		let started = DispatchSemaphore(value: 0)
		let released = DispatchSemaphore(value: 0)
		async let waited = BlockingWork.run {
			started.signal()
			return released.wait(timeout: .now() + testWaitSeconds) == .success
		}
		let sawStart = await BlockingWork.run { started.wait(timeout: .now() + testWaitSeconds) == .success }
		_ = await BlockingWork.run { released.signal() }
		#expect(sawStart)
		#expect(await waited)
	}
}

private enum BlockingWorkProbe {
	@TaskLocal static var value = "unset"
}
