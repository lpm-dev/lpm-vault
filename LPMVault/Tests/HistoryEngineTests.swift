import Foundation
import LPMEnv
import Testing

@testable import LPMVault

@Suite("History engine")
struct HistoryEngineTests {
	private struct Fixture: Decodable {
		struct State: Decodable {
			let name: String
			let records: [String: String]
			let values: String
		}

		let vaultId: String
		let states: [State]
	}

	private struct Head: Decodable {
		let parts: [Int]
	}

	private func fixture() throws -> Fixture {
		try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: #filePath)
			.deletingLastPathComponent().deletingLastPathComponent()
			.appending(path: "Vendor/EnvEngine/fixtures/companion/history.json")))
	}

	private func secret(_ data: Data) -> SecretBytes {
		data.withUnsafeBytes { SecretBytes(copying: $0) }
	}

	private func text(_ bytes: SecretBytes?) -> String? {
		bytes?.withUnsafeBytes { String(decoding: $0, as: UTF8.self) }
	}

	private func account(_ kind: String, _ vaultId: String, part: Int? = nil) throws -> String {
		try CompanionEngine.accountNames([.init(role: .record, vaultId: vaultId, kind: kind, part: part)])[0]
	}

	/// A fixture state's history as stored, its marker and its values payload.
	private func stored(_ name: String) throws -> (HistoryEngine.Stored, marker: SecretBytes?, values: SecretBytes) {
		let fixture = try fixture()
		let state = try #require(fixture.states.first { $0.name == name })
		let records = try state.records.mapValues { try #require(Data(base64Encoded: $0)) }
		let head = try #require(records[try account("history-head", fixture.vaultId)])
		let key = try #require(records[try account("key", fixture.vaultId)])
		let parts = try JSONDecoder().decode(Head.self, from: head).parts.map { part in
			(part: part, bytes: try records[account("history", fixture.vaultId, part: part)].map(secret))
		}
		let marker = try records[CompanionEngine.markerAccount(vaultId: fixture.vaultId)].map(secret)
		let values = secret(try #require(Data(base64Encoded: state.values)))
		return (HistoryEngine.Stored(vaultId: fixture.vaultId, head: secret(head), key: secret(key), parts: parts), marker, values)
	}

	@Test("a frame carries its JSON and every blob, in order, and reads back the same")
	func framesRoundTrip() throws {
		let blobs = [Data("one".utf8), Data(), Data(repeating: 7, count: 300)].map(secret)
		let frame = try HistoryEngine.frame(json: Data(#"{"a":1}"#.utf8), blobs: blobs)
		let (json, decoded) = try frame.withUnsafeBytes { try HistoryEngine.decodeFrame($0) }
		#expect(String(decoding: json, as: UTF8.self) == #"{"a":1}"#)
		#expect(decoded.items.count == 3)
		#expect(text(decoded[1]) == "one")
		#expect(decoded[2]?.count == 0)
		#expect(decoded[3]?.count == 300)
		#expect(decoded[0] == nil && decoded[4] == nil)
	}

	@Test("a frame past the engine's limits is refused before the engine sees it")
	func oversizedFramesAreRefused() {
		let tooMany = (0...HistoryEngine.maximumBlobs).map { _ in secret(Data("x".utf8)) }
		#expect(throws: HistoryEngine.Failure.self) { try HistoryEngine.frame(json: Data("{}".utf8), blobs: tooMany) }
		let tooLarge = secret(Data(count: HistoryEngine.inputLimit))
		#expect(throws: HistoryEngine.Failure.self) { try HistoryEngine.frame(json: Data("{}".utf8), blobs: [tooLarge]) }
	}

	@Test("an answer that isn't a whole frame is unreadable")
	func malformedAnswersAreUnreadable() throws {
		let frame = try HistoryEngine.frame(json: Data("{}".utf8), blobs: [secret(Data("value".utf8))])
		let bytes = frame.withUnsafeBytes { Array($0) }
		for broken in [Array(bytes.dropLast()), bytes + [0], Array("LPMX".utf8) + bytes.dropFirst(4)] {
			#expect(throws: HistoryEngine.Failure.self) {
				try broken.withUnsafeBytes { _ = try HistoryEngine.decodeFrame($0) }
			}
		}
	}

	@Test("the timeline of the engine's created history names its one change")
	func timelineReadsTheCreatedFixture() throws {
		let (stored, _, values) = try stored("created")
		let timeline = try HistoryEngine.timeline(stored, values: values)
		#expect(timeline.readable == 1)
		#expect(timeline.liveGap == nil, "the values are the ones history last recorded")
		guard case .entry(let entry)? = timeline.rows.first else {
			Issue.record("expected an entry, got \(timeline.rows)")
			return
		}
		#expect(entry.id.count == 32)
		#expect(entry.environments.map(\.name).contains("production"))
		#expect(entry.environments.first { $0.name == "production" }?.keys?.map(\.key) == ["API_KEY"])
	}

	@Test("revealing an entry gives its values as blobs of the answer")
	func revealGivesValuesAsBlobs() throws {
		let (stored, _, values) = try stored("created")
		guard case .entry(let entry)? = try HistoryEngine.timeline(stored, values: values).rows.first else {
			Issue.record("expected an entry")
			return
		}
		let revealed = try HistoryEngine.reveal(stored, ids: [entry.id])
		let production = try #require(revealed.response.first?.environments.firstIndex { $0.name == "production" })
		let sides = try #require(revealed.response.first?.values?[production].first)
		#expect(text(sides.after.flatMap { revealed.blobs[$0] }) == "one")
	}

	@Test("a marker that turned history on reads as on")
	func checkReadsTheMarker() throws {
		let (stored, marker, _) = try stored("created")
		let check = try HistoryEngine.check(vaultId: stored.vaultId, marker: marker, head: stored.head, key: stored.key, parts: stored.parts)
		#expect(check.history == "on")
		#expect(check.needsParts == nil)
		#expect(check.damage == [], "\(check)")
	}

	private func payload(_ environments: [String: [String: String]]) -> SecretBytes {
		secret(try! JSONSerialization.data(withJSONObject: ["environments": environments], options: .sortedKeys))
	}

	/// The stored history `writes` leave for `vaultId`, read back by account.
	private func stored(after writes: [HistoryEngine.RecordWrite], vaultId: String, previous: [String: SecretBytes] = [:]) throws
		-> (HistoryEngine.Stored, records: [String: SecretBytes])
	{
		var records = previous
		for write in writes {
			records[write.account] = write.bytes
		}
		let head = try #require(records[try account("history-head", vaultId)])
		let key = try #require(records[try account("key", vaultId)])
		let parts = try head.withUnsafeBytes { try JSONDecoder().decode(Head.self, from: Data($0)) }.parts.map { part in
			(part: part, bytes: records[try account("history", vaultId, part: part)])
		}
		return (HistoryEngine.Stored(vaultId: vaultId, head: head, key: key, parts: parts), records)
	}

	@Test("recording a project's first change creates history the timeline reads back")
	func recordCreatesHistory() throws {
		let change = HistoryEngine.Change(id: String(repeating: "a", count: 32), time: 1_762_300_000_000, action: "set")
		let plan = try HistoryEngine.record(
			vaultId: "fresh", change: change,
			before: payload(["production": [:]]), after: payload(["production": ["API_URL": "https://one.example"]]),
			recording: .create(marker: nil, approval: .automatic, ringLimit: 16))
		guard case .write(let writes, let journal, let entry, let gap, let valuesKept, _) = plan else {
			Issue.record("expected writes, got \(plan)")
			return
		}
		#expect(journal, "creation commits as one journal transaction")
		#expect(entry == change.id)
		#expect(!gap && valuesKept)
		#expect(writes.contains { $0.account == (try? CompanionEngine.markerAccount(vaultId: "fresh")) })

		let (stored, records) = try stored(after: writes, vaultId: "fresh")
		let timeline = try HistoryEngine.timeline(stored, values: payload(["production": ["API_URL": "https://one.example"]]))
		guard case .entry(let recorded)? = timeline.rows.first else {
			Issue.record("expected the entry, got \(timeline.rows)")
			return
		}
		#expect(recorded.id == change.id && recorded.action == "set" && recorded.actor == "app")

		let next = HistoryEngine.Change(id: String(repeating: "b", count: 32), time: 1_762_300_060_000, action: "set")
		let marker = try #require(records[try CompanionEngine.markerAccount(vaultId: "fresh")])
		let appended = try HistoryEngine.record(
			vaultId: "fresh", change: next,
			before: payload(["production": ["API_URL": "https://one.example"]]),
			after: payload(["production": ["API_URL": "https://two.example"]]),
			recording: .append(marker: marker, head: stored.head, key: stored.key, tail: stored.parts.last?.bytes, previous: nil, growth: .unasked))
		guard case .write(_, let appendJournal, let appendedEntry, _, _, let shape) = appended else {
			Issue.record("expected writes, got \(appended)")
			return
		}
		#expect(!appendJournal, "an append replaces the tail part, verified")
		#expect(appendedEntry == next.id)
		#expect(shape == "steady")
	}

	@Test("a rollback plans from the fixture's history and applies only with its fingerprint")
	func rollbackPlansAndApplies() throws {
		let (stored, _, values) = try stored("appended")
		guard case .entry(let newest)? = try HistoryEngine.timeline(stored, values: values).rows.first else {
			Issue.record("expected an entry")
			return
		}
		let target = HistoryEngine.RollbackTarget.undo(entry: newest.id, only: nil)
		let plan = try HistoryEngine.planRollback(stored, values: values, target: target)
		#expect(plan.response.kind == "undo")
		#expect(plan.response.environments.contains { $0.rows.contains(where: \.changes) })

		#expect {
			try HistoryEngine.applyRollback(stored, values: values, target: target, fingerprint: "stale")
		} throws: { error in
			(error as? HistoryEngine.Failure)?.code == "history.changed_since_review"
		}
		let writes = try HistoryEngine.applyRollback(stored, values: values, target: target, fingerprint: plan.response.fingerprint)
		#expect(!writes.isEmpty)
	}

	@Test("an empty service admits a full ring for a new project")
	func admissionOfAnEmptyService() throws {
		let admission = try HistoryEngine.admission(names: [], operation: .creation)
		#expect(admission.creation == "full")
		#expect(admission.existing == 0 && admission.trims.isEmpty)
		#expect(admission.ringLimit == 16)
	}

	@Test("an engine refusal keeps its code")
	func refusalsKeepTheirCode() {
		#expect {
			try HistoryEngine.check(vaultId: "proj", marker: secret(Data("not a marker".utf8)), head: nil, key: nil)
		} throws: { error in
			(error as? HistoryEngine.Failure)?.code == "history.invalid_marker"
		}
	}
}
