import Foundation
import Observation
import Testing

@testable import LPMVault

@Suite("Waiting on observable state")
@MainActor
struct ObservedWaitTests {
	@Observable
	@MainActor
	final class Model {
		var value = 0
		var other = 0
	}

	@MainActor
	final class Reads {
		var count = 0
	}

	@Test("a condition that already holds returns at once, read once")
	func alreadyHolds() async {
		let model = Model(), reads = Reads()
		model.value = 3
		let value = await ObservedWait.value { () -> Int? in
			reads.count += 1
			return model.value == 3 ? model.value : nil
		}
		#expect(value == 3)
		#expect(reads.count == 1)
	}

	@Test("a condition is read again only when what it read changes, not on a timer")
	func readsOnChange() async throws {
		let model = Model(), reads = Reads()
		let waiting = Task {
			await ObservedWait.value { () -> Int? in
				reads.count += 1
				return model.value == 3 ? model.value : nil
			}
		}
		try await Task.sleep(for: .milliseconds(150))
		#expect(reads.count == 1, "Nothing it read changed, so it wasn't read again")
		model.other += 1
		try await Task.sleep(for: .milliseconds(20))
		#expect(reads.count == 1, "A change to what it didn't read doesn't wake it")
		model.value = 1
		try await Task.sleep(for: .milliseconds(20))
		#expect(reads.count == 2)
		model.value = 3
		#expect(await waiting.value == 3)
		#expect(reads.count == 3)
	}

	@Test("waiting gives up when its time runs out or its task is cancelled")
	func givesUp() async throws {
		let model = Model()
		#expect(await ObservedWait.value(within: .milliseconds(20)) { model.value == 1 ? true : nil } == nil)
		let waiting = Task { await ObservedWait.value { model.value == 1 ? true : nil } }
		try await Task.sleep(for: .milliseconds(20))
		waiting.cancel()
		#expect(await waiting.value == nil)
	}
}
