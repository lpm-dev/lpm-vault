import Foundation
import Testing

@testable import LPMVault

@Suite("What local history's page, inspector and reviews say")
struct VaultHistoryTextTests {
	private static let calendar: Calendar = {
		var calendar = Calendar(identifier: .gregorian)
		calendar.timeZone = TimeZone(identifier: "UTC")!
		return calendar
	}()

	private static func time(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, _ second: Int = 0) -> Int64 {
		let date = calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second))!
		return Int64(date.timeIntervalSince1970 * 1000)
	}

	/// Wednesday, 4 November 2026, 13:40:07 UTC, in British English, whose
	/// times have no AM or PM.
	private let text = VaultHistoryText(
		now: VaultHistoryText.date(VaultHistoryTextTests.time(2026, 11, 4, 13, 40, 7)), calendar: VaultHistoryTextTests.calendar,
		locale: Locale(identifier: "en_GB"))

	private func clock(_ hour: Int, _ minute: Int) -> String {
		text.clock(VaultHistoryText.date(Self.time(2026, 11, 4, hour, minute)))
	}

	private func entry(_ json: String) throws -> HistoryEngine.Entry {
		try JSONDecoder().decode(HistoryEngine.Entry.self, from: Data(json.utf8))
	}

	private func entry(
		action: String, source: String = "app", actor: String = "app", time: Int64 = VaultHistoryTextTests.time(2026, 11, 4, 13, 40),
		extra: String = "", environments: String = #"[{"name": "production", "change": "unchanged", "keys": [{"key": "API_URL", "change": "changed", "before": "value", "after": "value"}]}]"#
	) throws -> HistoryEngine.Entry {
		try entry("""
			{"id": "\(String(repeating: "a", count: 32))", "seq": 1, "time": \(time), "actor": "\(actor)", "action": "\(action)",
			 "source": "\(source)", "valuesKept": true, "oversized": false, "pasted": false, "environments": \(environments)\(extra)}
			""")
	}

	@Test("times read as the clock under a day, with the year only outside this year")
	func times() {
		let date = { VaultHistoryText.date(Self.time($0, $1, $2, $3, $4)) }
		// The clock is the locale's own, which the OS's locale data can change.
		let clock = { text.clock(date(2026, 11, 4, $0, $1)) }
		#expect(clock(14, 2).hasPrefix("14:02") && clock(9, 5).contains("9:05"))
		#expect(text.day(date(2026, 11, 4, 0, 1)) == "Today")
		#expect(text.day(date(2026, 11, 3, 23, 59)) == "Yesterday")
		#expect(text.day(date(2026, 11, 2, 12, 0)) == "2 Nov")
		#expect(text.day(date(2025, 11, 2, 12, 0)) == "2 Nov 2025")
		#expect(text.moment(date(2026, 11, 3, 14, 2)) == "Yesterday, \(clock(14, 2))")
		#expect(text.moment(date(2026, 10, 30, 14, 2)) == "30 Oct, \(clock(14, 2))")
		#expect(text.since(date(2026, 11, 4, 13, 0)) == "since \(clock(13, 0)) today")
		#expect(text.since(date(2026, 10, 30, 9, 10)) == "since 30 Oct, \(clock(9, 10))")
		let full = text.full(date(2026, 11, 4, 13, 40))
		#expect(full.hasPrefix("Today, ") && full.contains("2026") && full.contains("13:40:00"), "\(full)")
		#expect(!text.full(date(2026, 11, 2, 13, 40)).hasPrefix("Today"))
	}

	@Test("an entry reads as one line naming what it did")
	func descriptions() throws {
		#expect(text.describe(try entry(action: "set")) == "Set API_URL")
		let pull = try entry(
			action: "pull", source: "pull", extra: #", "remote": {"org": "acme"}, "remoteVersion": 14"#,
			environments: #"[{"name": "production", "change": "unchanged", "keys": [{"key": "A", "change": "changed", "before": "value", "after": "value"}, {"key": "B", "change": "added", "before": "absent", "after": "value"}]}]"#)
		#expect(text.describe(pull) == "Pulled from lpm.dev (acme, v14) · 2 keys changed")
		let imported = try entry(action: "import", source: "import", extra: #", "fileName": ".env.local""#)
		let undo = try entry(
			action: "undo", source: "rollback",
			extra: #", "related": {"id": "\#(imported.id)", "side": "after", "time": \#(Self.time(2026, 11, 4, 13, 0))}"#)
		#expect(text.describe(undo) { $0 == imported.id ? imported : nil } == "Undid the import of .env.local")
		#expect(text.describe(undo) == "Undid the change from Today, \(clock(13, 0))")
		let outside = try entry(action: "outside", source: "outside", actor: "outside", extra: #", "since": \#(Self.time(2026, 11, 4, 9, 10))"#)
		#expect(text.describe(outside) == "Changed outside local history · \(clock(9, 10)) to \(clock(13, 40))")
	}

	@Test("a gap says when the change outside history happened")
	func gaps() {
		#expect(text.gap(.init(since: Self.time(2026, 10, 30, 9, 10), until: Self.time(2026, 10, 30, 13, 40)))
			== "This also replaces a change made outside local history between 30 Oct, \(clock(9, 10)) and \(clock(13, 40)).")
		#expect(text.gap(.init(since: Self.time(2026, 10, 30, 9, 10), until: Self.time(2026, 10, 31, 8, 0)))
			== "This also replaces a change made outside local history between 30 Oct, \(clock(9, 10)) and 31 Oct, \(clock(8, 0)).")
		#expect(text.gap(.init(since: Self.time(2026, 11, 4, 9, 10), until: nil))
			== "This also replaces a change made outside local history since \(clock(9, 10)) today.")
		#expect(text.gap(.init(since: nil, until: nil)) == "This also replaces a change made outside local history.")
	}

	@Test("a pulled value's notice follows the pull's own remote: the team for an org, other Macs for personal")
	func pulledNotices() {
		let time = Self.time(2026, 11, 3, 14, 2)
		let org = text.pulled(.init(remote: .org("acme"), version: 14, time: time), key: "API_KEY")
		#expect(org == "API_KEY’s current value came from lpm.dev (pulled 3 Nov, v14). If you push this rollback, it replaces that value for everyone on the team, and the value it replaces then stays only in this Mac’s history. Until you push, pulling again brings lpm.dev’s value back.")
		let personal = text.pulled(.init(remote: .personal, version: nil, time: time), key: "API_KEY")
		#expect(personal.contains("(pulled 3 Nov).") && personal.contains("on lpm.dev and on your other Macs when they pull,") && !personal.contains("team"))
		#expect(text.changedAgain(.init(time: Self.time(2026, 11, 4, 9, 0), actor: "cli", action: "set"))
			== "Changed again on 4 Nov by the LPM CLI. Undoing this replaces that change too.")
	}

	@Test("a removal's places list their occurrences newest first")
	func occurrences() {
		let occurrences: [HistoryEngine.Occurrence] = [
			.init(set: Self.time(2026, 10, 1, 9, 0), replaced: Self.time(2026, 10, 12, 9, 0)),
			.init(set: Self.time(2026, 11, 3, 14, 2), replaced: nil),
			.init(set: nil, replaced: Self.time(2026, 8, 1, 9, 0)),
		]
		#expect(text.occurrences(occurrences) == "set 3 Nov; set 1 Oct, replaced 12 Oct; replaced 1 Aug")
	}

	@Test("the settings line says what history holds, why it's paused, or nothing while it's off")
	func stateLines() {
		let on = VaultHistoryState(history: "on", damage: [])
		let timeline = { (readable: Int, oldest: Int64?, unreadable: Int) in
			HistoryEngine.Timeline(
				rows: [], liveGap: nil, readable: readable, counts: [:], oldest: oldest, damagedTail: false,
				unreadableParts: unreadable, environments: [], keyGeneration: 1)
		}
		let summary = { (state: VaultHistoryState, timeline: HistoryEngine.Timeline?) in VaultLocalHistory.Summary(state: state, timeline: timeline) }
		#expect(text.stateLine(summary(.init(history: "off", damage: []), nil), notRecorded: nil, readFailed: false) == nil)
		#expect(text.stateLine(summary(on, timeline(312, Self.time(2026, 10, 2, 9, 0), 0)), notRecorded: nil, readFailed: false)?.text
			== "312 changes kept since 2 Oct")
		#expect(text.stateLine(summary(.init(history: "default", damage: []), timeline(0, nil, 0)), notRecorded: nil, readFailed: false)?.text
			== "History starts with the next change made on this Mac.")
		let unreadable = text.stateLine(summary(on, timeline(198, Self.time(2026, 10, 2, 9, 0), 1)), notRecorded: nil, readFailed: false)
		#expect(unreadable == .init(text: "198 changes readable. Part of this project’s history couldn’t be read.", warns: true, retries: true))
		#expect(text.stateLine(summary(on, timeline(3, Self.time(2026, 10, 2, 9, 0), 0)), notRecorded: "tooManyValues", readFailed: false)?.text
			== "Paused — this project has too many values to keep history.")
		#expect(text.stateLine(summary(on, nil), notRecorded: "limit", readFailed: false)?.text
			== "Paused — this Mac holds too much LPM data to keep history for this project.")
		#expect(text.stateLine(summary(.init(history: "unsupported", damage: []), nil), notRecorded: nil, readFailed: false)?.text
			== "Recorded by a newer version of LPM. Update LPM Vault to see it.")
		#expect(text.stateLine(nil, notRecorded: nil, readFailed: true)?.retries == true)
	}

	@Test("a crowded Mac's note gives the record count as the locale writes numbers")
	func crowdedNote() {
		#expect(text.crowded(4_120) == "This Mac holds a lot of LPM data (4,120 records), so LPM keeps less local history for each project.")
	}

	private func review(_ target: HistoryEngine.RollbackTarget, kind: String, environments: String) throws -> VaultLocalHistory.RollbackReview {
		let plan = try JSONDecoder().decode(HistoryEngine.Plan.self, from: Data("""
			{"kind": "\(kind)", "point": {"entry": "e", "side": "after", "time": \(Self.time(2026, 11, 3, 14, 2))}, "generation": 1,
			 "fingerprint": "f", "environments": \(environments)}
			""".utf8))
		return VaultLocalHistory.RollbackReview(projectID: "p", target: target, plan: plan, values: plan.environments.map { $0.rows.map { _ in (nil, nil) } })
	}

	private static func rows(_ changes: [String]) -> String {
		"[" + changes.enumerated().map { index, change in
			#"{"key": "K\#(index)", "change": "\#(change)", "changes": \#(change != "unknown"), "gaps": [], "linked": []}"#
		}.joined(separator: ", ") + "]"
	}

	private static func environment(current: String?, target: String?, rows: [String], recreates: Bool = false, offersDeletion: Bool = false) -> String {
		let name = { (name: String?) in name.map { "\"\($0)\"" } ?? "null" }
		return #"{"current": \#(name(current)), "target": \#(name(target)), "recreates": \#(recreates), "offersDeletion": \#(offersDeletion), "renames": \#(current != nil && target != nil && current != target), "unnamedKeys": null, "rows": \#(Self.rows(rows))}"#
	}

	@Test("a rollback's title and detail name its kind, its point and what changes")
	func rollbackHeadings() throws {
		let environment = HistoryEngine.RollbackTarget.environment("production", entry: "e", side: "after")
		#expect(text.rollbackTitle(environment, at: Self.time(2026, 11, 3, 14, 2)) == "Roll back production to Yesterday, \(clock(14, 2))?")
		#expect(text.rollbackTitle(.environment("production", entry: "e", side: "before"), at: Self.time(2026, 10, 30, 14, 2))
			== "Roll back production to before 30 Oct, \(clock(14, 2))?")
		#expect(text.rollbackTitle(.key("API_KEY", environment: "production", entry: "e"), at: Self.time(2026, 11, 4, 13, 40))
			== "Roll back API_KEY in production to its value before Today, \(clock(13, 40))?")
		#expect(text.rollbackTitle(.undo(entry: "e", only: nil), at: 0) == "Undo this change?")

		var rollback = try review(environment, kind: "environment", environments: "[\(Self.environment(current: "production", target: "production", rows: ["changed", "changed", "added", "removed", "unknown"]))]")
		#expect(text.rollbackDetail(rollback, entry: nil)
			== "production goes back to its state after that change. 4 of 5 keys change; switch any off to keep its current value.")
		rollback.setApplies(false, environment: 0, row: 0)
		#expect(text.rollbackDetail(rollback, entry: nil).contains("3 of 5 keys change"))

		let key = try review(.key("API_KEY", environment: "production", entry: "e"), kind: "key", environments: "[\(Self.environment(current: "production", target: "production", rows: ["changed"]))]")
		let pull = try entry(action: "pull", source: "pull")
		#expect(text.rollbackDetail(key, entry: pull) == "Only this key changes. The value from before the pull is restored.")

		let undo = try review(.undo(entry: "e", only: nil), kind: "undo", environments: "[\(Self.environment(current: "production", target: "production", rows: ["changed"])), \(Self.environment(current: "staging", target: "staging", rows: ["removed"]))]")
		#expect(text.rollbackDetail(undo, entry: try entry(action: "set"))
			== "Set API_URL · Yesterday, \(clock(14, 2)). Keys in both environments go back to their values before it.")
	}

	@Test("an environment the rollback recreates, deletes or renames says so")
	func environmentNotes() throws {
		let plan = try JSONDecoder().decode(HistoryEngine.Plan.self, from: Data("""
			{"kind": "environment", "point": {"entry": "e", "side": "after", "time": 0}, "generation": 1, "fingerprint": "f",
			 "environments": [\(Self.environment(current: nil, target: "local", rows: ["added", "added", "added"], recreates: true)),
			  \(Self.environment(current: "preview", target: nil, rows: ["removed", "removed"], offersDeletion: true)),
			  \(Self.environment(current: "live", target: "production", rows: []))]}
			""".utf8))
		#expect(text.environmentNote(plan.environments[0], deletedAt: Self.time(2026, 10, 29, 9, 0))
			== "local was deleted on 29 Oct. Rolling back recreates it with 3 keys.")
		#expect(text.environmentNote(plan.environments[0], deletedAt: nil) == "local doesn’t exist now. Rolling back recreates it with 3 keys.")
		#expect(text.environmentNote(plan.environments[1], deletedAt: nil) == "preview didn’t exist at that point. Its 2 keys are removed.")
		#expect(text.environmentNote(plan.environments[1], deletedAt: nil, undoes: true)
			== "preview didn’t exist before that change. Its 2 keys are removed.")
		#expect(text.environmentNote(plan.environments[2], deletedAt: nil) == "live goes back to its earlier name, production.")
	}
}
