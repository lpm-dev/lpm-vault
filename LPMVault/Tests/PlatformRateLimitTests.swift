import Foundation
import Testing
@testable import LPMVault

struct PlatformRateLimitTests {
	private func answer(_ headers: [String: String]) -> HTTPURLResponse {
		HTTPURLResponse(url: URL(string: "https://api.example.com")!, statusCode: 429, httpVersion: "HTTP/1.1", headerFields: headers)!
	}

	@Test("an answer's Date is read in HTTP's form, and nothing else is taken for one")
	func readsAnswerDate() {
		#expect(PlatformRateLimit.date(of: answer(["Date": "Thu, 09 Oct 2025 08:52:50 GMT"])) == Date(timeIntervalSince1970: 1_759_999_970))
		#expect(PlatformRateLimit.date(of: answer([:])) == nil)
		for value in ["Thursday, 09-Oct-25 08:52:50 GMT", "Thu Oct  9 08:52:50 2025", "yesterday", "", "Thu, 09 Oct 2025 08:52:50 PST", "Thu, 32 Oct 2025 08:52:50 GMT"] {
			#expect(PlatformRateLimit.date(of: answer(["Date": value])) == nil, "\(value)")
		}
	}

	@Test("a reset on the platform's clock lifts as long after now as it was after the answer's Date, whichever way the Mac's clock is off")
	func measuresResetFromAnswer() {
		let now = SleepingTestClock.start
		let macAhead = answer(["Date": "Thu, 09 Oct 2025 08:52:50 GMT"])
		#expect(PlatformRateLimit.lifts(atReset: 1_760_000_000, answered: macAhead, now: now) == now.addingTimeInterval(30))
		let macBehind = answer(["Date": "Thu, 09 Oct 2025 09:53:20 GMT"])
		#expect(PlatformRateLimit.lifts(atReset: 1_760_003_610, answered: macBehind, now: now) == now.addingTimeInterval(10))
	}

	@Test("without a Date to measure from, a reset is taken as it is while it's ahead, and as saying nothing once this Mac's clock is past it")
	func readsResetWithoutAnswerDate() {
		let now = SleepingTestClock.start
		#expect(PlatformRateLimit.lifts(atReset: 1_760_000_042, answered: answer([:]), now: now) == Date(timeIntervalSince1970: 1_760_000_042))
		#expect(PlatformRateLimit.lifts(atReset: 1_759_999_999, answered: answer(["Date": "soon"]), now: now) == nil)
		for reset in [TimeInterval.infinity, -.infinity, .nan] {
			#expect(PlatformRateLimit.lifts(atReset: reset, answered: answer(["Date": "Thu, 09 Oct 2025 08:52:50 GMT"]), now: now) == nil)
		}
	}

	@Test("a wait sleeps on until the wall clock passes the limit's end, when the sleep's own clock runs ahead of it")
	func waitsForWallClock() async throws {
		let clock = SleepingTestClock(rate: 0.9)
		let lifts = clock.date.addingTimeInterval(10)
		try await PlatformRateLimit.waitOut(.seconds(10), until: lifts, atMost: .seconds(66), date: { clock.date }, sleep: { clock.sleep($0) })
		#expect(clock.date >= lifts)
		#expect(clock.sleeps.count > 1 && clock.totalSlept < .seconds(12))
	}

	@Test("a wall clock set back mid-wait holds the wait no longer than its longest")
	func capsWallClockWait() async throws {
		let clock = SleepingTestClock()
		let lifts = clock.date.addingTimeInterval(10)
		try await PlatformRateLimit.waitOut(.seconds(10), until: lifts, atMost: .seconds(66), date: { clock.date }, sleep: {
			if clock.sleeps.isEmpty { clock.setBack(by: 3_600) }
			clock.sleep($0)
		})
		#expect(clock.totalSlept == .seconds(66))
	}
}
