import Foundation
import Testing

@testable import LPMVault

/// A store of named records that counts what recording does with it, and
/// checks each journal commit as the shared Keychain store does.
private final class FakeHistoryStorage: HistoryStorage {
	var records: [String: Data] = [:]
	var approval: HistoryEngine.Approval? = .automatic
	var extraNames: [String] = []
	private(set) var reads: [String] = []
	private(set) var replaced: [String] = []
	private(set) var commits = 0
	let vaultId: String
	let markerAccount: String

	init(vaultId: String) throws {
		self.vaultId = vaultId
		markerAccount = try CompanionEngine.markerAccount(vaultId: vaultId)
	}

	func historyMarker(vaultId: String) throws -> Data? { records[markerAccount] }

	func historyRecord(_ account: String) throws -> Data? {
		reads.append(account)
		return records[account]
	}

	func historyNames() throws -> [String] { Array(records.keys) + extraNames }

	func historyApproval(vaultId: String) throws -> HistoryEngine.Approval? { approval }

	func historyReplace(_ account: String, with data: Data) throws {
		replaced.append(account)
		records[account] = data
	}

	func historyDelete(_ account: String) throws { records[account] = nil }

	func historyCommit(_ writes: [HistoryEngine.RecordWrite]) throws {
		commits += 1
		let changes = writes.map { write in
			CompanionEngine.Change(account: write.account, bytes: write.bytes.map { bytes in bytes.withUnsafeBytes { Data($0) } })
		}
		try CompanionEngine.checkTransaction(changes, markers: [vaultId: records[markerAccount]], names: Array(records.keys))
		for write in writes {
			records[write.account] = write.bytes.map { bytes in bytes.withUnsafeBytes { Data($0) } }
		}
	}

	func resetCounts() {
		reads = []
		replaced = []
		commits = 0
	}
}

@Suite("History recorder")
struct HistoryRecorderTests {
	private let vaultId = "recorder-proj"

	private func payload(_ environments: [String: [String: String]]) -> Data {
		try! JSONSerialization.data(withJSONObject: ["environments": environments], options: .sortedKeys)
	}

	@Test("a project's first value change creates history in one journal transaction")
	func firstChangeCreatesHistory() throws {
		let storage = try FakeHistoryStorage(vaultId: vaultId)
		let source = VaultHistorySource(.set)
		let outcome = HistoryRecorder.record(
			storage, vaultId: vaultId,
			before: payload(["production": [:]]), after: payload(["production": ["API_URL": "one"]]),
			source: source)
		#expect(outcome == .recorded(entry: source.id, gap: false, crowded: nil))
		#expect(storage.commits == 1)
		#expect(storage.records[storage.markerAccount] != nil)
		#expect(storage.records[try HistoryRecorder.account("history-head", vaultId)] != nil)
		#expect(storage.records[try HistoryRecorder.account("key", vaultId)] != nil)
	}

	@Test("the next change appends by reading the head, the key and the tail once each")
	func nextChangeAppends() throws {
		let storage = try FakeHistoryStorage(vaultId: vaultId)
		_ = HistoryRecorder.record(
			storage, vaultId: vaultId,
			before: payload(["production": [:]]), after: payload(["production": ["API_URL": "one"]]),
			source: VaultHistorySource(.set))
		storage.resetCounts()

		let source = VaultHistorySource(.editKey)
		let outcome = HistoryRecorder.record(
			storage, vaultId: vaultId,
			before: payload(["production": ["API_URL": "one"]]), after: payload(["production": ["API_URL": "two"]]),
			source: source)
		#expect(outcome == .recorded(entry: source.id, gap: false, crowded: nil))
		#expect(storage.commits == 0, "an append is a verified replacement, not a journal")
		#expect(storage.reads.count == 3, "\(storage.reads)")
		#expect(storage.replaced == [try HistoryRecorder.account("history", vaultId, part: 0)])

		let head = try #require(storage.records[try HistoryRecorder.account("history-head", vaultId)])
		let key = try #require(storage.records[try HistoryRecorder.account("key", vaultId)])
		let stored = try HistoryRecorder.stored(
			storage, vaultId: vaultId,
			head: head.withUnsafeBytes { SecretBytes(copying: $0) }, key: key.withUnsafeBytes { SecretBytes(copying: $0) })
		let timeline = try HistoryEngine.timeline(stored, values: nil)
		let entries = timeline.rows.compactMap { row -> HistoryEngine.Entry? in
			if case .entry(let entry) = row { return entry }
			return nil
		}
		#expect(entries.map(\.action) == ["editKey", "set"])
		#expect(entries.allSatisfy { $0.actor == "app" })
	}

	@Test("a write that changes nothing records nothing and reads nothing")
	func noNetChangeRecordsNothing() throws {
		let storage = try FakeHistoryStorage(vaultId: vaultId)
		let same = payload(["production": ["API_URL": "one"]])
		#expect(HistoryRecorder.record(storage, vaultId: vaultId, before: same, after: same, source: VaultHistorySource(.set)) == .nothing)
		#expect(storage.reads.isEmpty && storage.commits == 0)
	}

	@Test("a project whose history is off records nothing")
	func historyOffRecordsNothing() throws {
		struct Fixture: Decodable {
			struct State: Decodable { let name: String; let records: [String: String] }
			let vaultId: String
			let states: [State]
		}
		let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: #filePath)
			.deletingLastPathComponent().deletingLastPathComponent()
			.appending(path: "Vendor/EnvEngine/fixtures/companion/history.json")))
		let off = try #require(fixture.states.first { $0.name == "off" })
		let storage = try FakeHistoryStorage(vaultId: fixture.vaultId)
		storage.records = off.records.compactMapValues { Data(base64Encoded: $0) }
		let before = storage.records
		let outcome = HistoryRecorder.record(
			storage, vaultId: fixture.vaultId,
			before: payload(["production": [:]]), after: payload(["production": ["A": "1"]]),
			source: VaultHistorySource(.set))
		#expect(outcome == .off)
		#expect(storage.records == before && storage.commits == 0)
	}

	@Test("history doesn't start when the values' approval can't be confirmed")
	func unconfirmedApprovalDoesNotStartHistory() throws {
		let storage = try FakeHistoryStorage(vaultId: vaultId)
		storage.approval = nil
		let outcome = HistoryRecorder.record(
			storage, vaultId: vaultId,
			before: payload(["production": [:]]), after: payload(["production": ["A": "1"]]),
			source: VaultHistorySource(.set))
		guard case .notRecorded("unavailable", _) = outcome else {
			Issue.record("expected unavailable, got \(outcome)")
			return
		}
		#expect(storage.records.isEmpty && storage.commits == 0)
	}

	@Test("a service at the record limit refuses to start another project's history")
	func fullServiceRefusesCreation() throws {
		let storage = try FakeHistoryStorage(vaultId: vaultId)
		storage.extraNames = try CompanionEngine.accountNames((0..<8_192).map { index in
			.init(role: .record, vaultId: "crowded-\(index)", kind: "key", part: nil)
		})
		let outcome = HistoryRecorder.record(
			storage, vaultId: vaultId,
			before: payload(["production": [:]]), after: payload(["production": ["A": "1"]]),
			source: VaultHistorySource(.set))
		guard case .notRecorded("limit", _) = outcome else {
			Issue.record("expected limit, got \(outcome)")
			return
		}
		#expect(storage.commits == 0)
	}
}
