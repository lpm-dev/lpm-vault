import Foundation
import Testing

/// How long a test waits for state that another task, queue or process
/// changes. It only bounds a failure: a loaded CI runner can pause the test
/// process for tens of seconds, and a wait returns as soon as its condition holds.
let testWaitLimit: Duration = .seconds(testWaitSeconds)

/// `testWaitLimit` in seconds, for timeouts and deadlines that take a `TimeInterval`.
let testWaitSeconds: TimeInterval = 120

/// Waits until `condition` holds, checking it again every few milliseconds;
/// false when it still doesn't after `testWaitLimit`.
func waitUntil(isolation: isolated (any Actor)? = #isolation, _ condition: () async throws -> Bool) async throws -> Bool {
	let deadline = ContinuousClock.now.advanced(by: testWaitLimit)
	while !(try await condition()) {
		guard ContinuousClock.now < deadline else { return false }
		try await Task.sleep(for: .milliseconds(5))
	}
	return true
}

/// Gives something that mustn't happen the time to, before a test checks it
/// didn't, where no state says the work that could do it is over: on an idle
/// machine it would within this. Under load the check can only miss it,
/// never report it falsely.
func quietPeriod() async throws {
	try await Task.sleep(for: .milliseconds(500))
}

/// Lets work a test just started get ahead, to a point nothing observable
/// marks, so the test usually checks the moment it names. Under load the
/// work may not have got there yet, and the test then checks an earlier
/// moment, which has the same outcome: this can't fail a run.
func letStartedWorkGetAhead() async throws {
	try await Task.sleep(for: .milliseconds(50))
}

/// An ephemeral session configuration for requests a test answers, whose
/// timeouts, like a wait's limit, only bound a failure.
func testSessionConfiguration() -> URLSessionConfiguration {
	let configuration = URLSessionConfiguration.ephemeral
	configuration.timeoutIntervalForRequest = testWaitSeconds
	configuration.timeoutIntervalForResource = testWaitSeconds
	return configuration
}

extension Trait where Self == TimeLimitTrait {
	/// The time limit of a test whose work, done right, takes a moment, and
	/// done wrong takes hours or never ends, such as scanning a large input:
	/// far enough off that a loaded runner's pauses don't reach it.
	static var hangLimit: Self { .timeLimit(.minutes(5)) }
}
