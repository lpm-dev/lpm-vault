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
	private(set) var listings = 0
	private(set) var approvalChecks = 0
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

	func historyNames() throws -> [String] {
		listings += 1
		return Array(records.keys) + extraNames
	}

	func historyApproval(vaultId: String) throws -> HistoryEngine.Approval? {
		approvalChecks += 1
		return approval
	}

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

	var values: Data?

	func historyValues(vaultId: String) throws -> Data? { values }

	func historyProjectNames(vaultId: String) throws -> [String] {
		Array(records.keys)
	}

	func historyTrimmable(own vaultId: String) throws -> [String] { [vaultId] }

	func historyClaimedApproval(vaultId: String) throws -> HistoryEngine.Approval { approval ?? .automatic }

	func historyWithoutApprovalPrompts<T>(_ body: () throws -> T) rethrows -> T { try body() }

	func historyRings() throws -> [String] { [vaultId] }

	func historyRun(_ plan: CompanionEngine.Plan, vaultId: String) throws {
		for transaction in plan.transactions {
			for account in transaction.deletes { records[account] = nil }
			if let marker = transaction.writesMarker { records[markerAccount] = marker }
			if transaction.deletesMarker { records[markerAccount] = nil }
		}
	}

	func resetCounts() {
		reads = []
		replaced = []
		commits = 0
		listings = 0
		approvalChecks = 0
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

	@Test("removing a value from a ring of several parts reads each part once, however many the key rotation rewrites")
	func removalReadsEachPartOnce() throws {
		let storage = try FakeHistoryStorage(vaultId: vaultId)
		let value = { (index: Int) in String(repeating: String(index % 10), count: 4096) }
		var current = payload(["production": [:]])
		for index in 0...12 {
			let next = payload(["production": ["BIG": value(index)]])
			_ = HistoryRecorder.record(storage, vaultId: vaultId, before: current, after: next, source: VaultHistorySource(.set))
			current = next
		}
		storage.values = current
		let headAccount = try HistoryRecorder.account("history-head", vaultId)
		struct Head: Decodable { let parts: [Int] }
		let parts = try JSONDecoder().decode(Head.self, from: try #require(storage.records[headAccount])).parts
		#expect(parts.count >= 3, "\(parts)")
		let partAccounts = Set(try parts.map { try HistoryRecorder.account("history", vaultId, part: $0) })
		let newest = try #require(try HistoryOperations.timeline(storage, vaultId: vaultId, filter: nil)?.rows.first)
		guard case .entry(let entry) = newest else {
			Issue.record("expected an entry")
			return
		}
		let review = try HistoryOperations.reviewRemoval(
			storage, vaultId: vaultId, entry: entry.id, environment: "production", key: "BIG", side: "before")
		storage.resetCounts()

		try HistoryOperations.remove(storage, vaultId: vaultId, review: review, selection: review.defaultSelection)

		let partReads = storage.reads.filter(partAccounts.contains)
		#expect(partReads.count == parts.count, "each part once: \(partReads.count) reads of \(parts.count) parts")
		#expect(Set(storage.replaced).isSuperset(of: partAccounts), "the rotation rewrites every part")
	}

	@Test("a change to no key before history exists asks no admission and no approval")
	func changeWithoutKeysStartsNothing() throws {
		let storage = try FakeHistoryStorage(vaultId: vaultId)
		let outcome = HistoryRecorder.record(
			storage, vaultId: vaultId,
			before: payload(["production": [:]]), after: payload(["staging": [:]]),
			source: VaultHistorySource(.renameEnvironment, renames: [.environment(from: "production", to: "staging")]))
		#expect(outcome == .nothing)
		#expect(storage.listings == 0 && storage.approvalChecks == 0, "listings \(storage.listings), approval checks \(storage.approvalChecks)")
		#expect(storage.commits == 0)
	}

	@Test("reading history finishes a removal another operation started and left running")
	func readingFinishesARunningRemoval() throws {
		let storage = try FakeHistoryStorage(vaultId: vaultId)
		let before = payload(["production": ["A": "one"]])
		let after = payload(["production": ["A": "two"]])
		_ = HistoryRecorder.record(storage, vaultId: vaultId, before: payload(["production": [:]]), after: before, source: VaultHistorySource(.set))
		_ = HistoryRecorder.record(storage, vaultId: vaultId, before: before, after: after, source: VaultHistorySource(.set))
		storage.values = after
		guard case .entry(let edit)? = try HistoryOperations.timeline(storage, vaultId: vaultId, filter: nil)?.rows.first else {
			Issue.record("expected an entry")
			return
		}
		let review = try HistoryOperations.reviewRemoval(storage, vaultId: vaultId, entry: edit.id, environment: "production", key: "A", side: "before")
		/// The history as stored, read without maintaining anything.
		func asStored() throws -> HistoryEngine.Stored {
			let head = try #require(storage.records[try HistoryRecorder.account("history-head", vaultId)])
			let key = try #require(storage.records[try HistoryRecorder.account("key", vaultId)])
			return try HistoryRecorder.stored(
				storage, vaultId: vaultId, head: head.withUnsafeBytes { SecretBytes(copying: $0) },
				key: key.withUnsafeBytes { SecretBytes(copying: $0) })
		}
		try storage.historyCommit(try HistoryEngine.startRemoval(
			try asStored(), values: after.withUnsafeBytes { SecretBytes(copying: $0) }, review: review,
			selection: review.defaultSelection, approval: .automatic))
		#expect(try HistoryEngine.maintenance(try asStored(), step: .check(approval: .automatic)).needsFinishing)

		_ = try HistoryOperations.timeline(storage, vaultId: vaultId, filter: nil)

		#expect(try !HistoryEngine.maintenance(try asStored(), step: .check(approval: .automatic)).needsFinishing)
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
