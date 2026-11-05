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

	@Test("an engine refusal keeps its code")
	func refusalsKeepTheirCode() {
		#expect {
			try HistoryEngine.check(vaultId: "proj", marker: secret(Data("not a marker".utf8)), head: nil, key: nil)
		} throws: { error in
			(error as? HistoryEngine.Failure)?.code == "history.invalid_marker"
		}
	}
}
