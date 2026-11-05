import Foundation
import Testing

@testable import LPMVault

@Suite("Local history's rings on a crowded Mac")
struct HistoryRingTests {
	private struct Head: Decodable {
		let ringLimit: Int
		let parts: [Int]
	}

	private let backend = InMemoryKeychainBackend()
	private let name = "dev.lpm.vault.history-rings.\(UUID().uuidString)"
	private var service: KeychainService { KeychainService(testingService: name, backend: backend) }

	/// `vaultId` with a ring of several parts: each edit replaces a value
	/// large enough that a part holds only a few entries.
	private func grownRing(_ vaultId: String, edits: Int = 12) throws {
		let service = service
		let value = { (index: Int) in String(repeating: String(index % 10), count: 4096) }
		guard case .success = service.createEnvironments(
			vaultId: vaultId, projectName: vaultId, projectPath: "", environments: ["default": ["BIG": value(0)]],
			source: VaultHistorySource(.set))
		else { throw KeychainError.encodingFailed }
		for index in 1...edits {
			guard case .success = service.applyVaultTransaction(
				project: .update(vaultId: vaultId, environments: ["default": ["BIG": value(index)]], source: VaultHistorySource(.set)),
				data: [])
			else { throw KeychainError.encodingFailed }
		}
	}

	private func head(_ vaultId: String) throws -> Head {
		let data = try #require(try backend.read(service: name, account: HistoryRecorder.account("history-head", vaultId)))
		return try JSONDecoder().decode(Head.self, from: data)
	}

	/// Records of projects that are gone, counted as the Mac's records until
	/// companion maintenance collects them.
	private func crowd(_ count: Int) throws -> [String] {
		let names = try CompanionEngine.accountNames((0..<count).map { .init(role: .record, vaultId: "gone-\($0)", kind: "overrides", part: nil) })
		for account in names { try backend.write(service: name, account: account, data: Data("x".utf8)) }
		return names
	}

	@Test("the pass after unlock trims the largest ring while the Mac is crowded, and raises it back once it isn't")
	func upkeepTrimsThenRaises() throws {
		try grownRing("big")
		let grown = try head("big")
		#expect(grown.parts.count >= 3 && grown.ringLimit == 16, "\(grown)")

		let filler = try crowd(4_100)
		let crowded = try service.historyUpkeepResult(raising: false).get()
		#expect(crowded.trimmed == grown.parts.count - 2)
		#expect(crowded.crowded && crowded.mayBeShrunk)
		#expect(try head("big").parts.count == 2)
		#expect(try head("big").parts == Array(grown.parts.suffix(2)), "the oldest parts go first")

		for account in filler { try backend.delete(service: name, account: account) }
		let calm = try service.historyUpkeepResult(raising: crowded.mayBeShrunk).get()
		#expect(!calm.crowded && !calm.mayBeShrunk && calm.trimmed == 0)
		#expect(try head("big").ringLimit == 16)
	}

	@Test("a pass on a Mac that isn't crowded trims nothing and leaves nothing to raise")
	func upkeepOnACalmMac() throws {
		try grownRing("small", edits: 1)
		let upkeep = try service.historyUpkeepResult(raising: false).get()
		#expect(upkeep == .init(records: upkeep.records, trimmed: 0, crowded: false, mayBeShrunk: false))
	}

	@Test("admission decides from what trims left when a planned trim couldn't be made")
	func admissionCountsOnlyTrimsMade() throws {
		try grownRing("big")
		let grown = try head("big")
		let headAccount = try HistoryRecorder.account("history-head", "big")
		try backend.write(service: name, account: headAccount, data: Data("not a head".utf8))
		// 8,191 records: creating history's 3 would pass the hard limit of
		// 8,192, unless the big ring's planned trims were made, which they can't be.
		_ = try crowd(8_191 - (2 + grown.parts.count))
		let service = service
		guard case .success = service.createEnvironments(
			vaultId: "new", projectName: "new", projectPath: "", environments: ["default": ["A": "1"]], source: VaultHistorySource(.set))
		else { throw KeychainError.encodingFailed }
		guard case .notRecorded("limit", _)? = service.takeHistoryOutcomes()["new"] else {
			Issue.record("with nothing trimmed, the Mac is past the limit, so history can't start")
			return
		}
		#expect(try backend.read(service: name, account: HistoryRecorder.account("history-head", "new")) == nil)
	}

	@Test("creating history on a crowded Mac trims another project's ring first, and the new ring starts smaller")
	func creationTrimsFirst() throws {
		try grownRing("big")
		let grown = try head("big")
		_ = try crowd(4_100)
		let service = service
		let created = VaultHistorySource(.set)
		guard case .success = service.createEnvironments(
			vaultId: "new", projectName: "new", projectPath: "", environments: ["default": ["A": "1"]], source: created)
		else { throw KeychainError.encodingFailed }
		guard case .recorded(let entry, _, let crowded?)? = service.takeHistoryOutcomes()["new"] else {
			Issue.record("history should start, smaller, and say the Mac is crowded")
			return
		}
		#expect(entry == created.id)
		#expect(crowded > 4_096)
		#expect(try head("big").parts.count == 2, "trimmed from \(grown.parts.count)")
		#expect(try head("new").ringLimit == 2)
	}
}
