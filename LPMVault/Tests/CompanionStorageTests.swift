import Foundation
import Security
import Testing

@testable import LPMVault

/// A shared Keychain service that records what companion storage does with
/// it: reads per account, the order of deletions and approval changes, and
/// the protection a probe finds, which can differ from what an item claims.
private final class CompanionTestBackend: KeychainStoreBackend, @unchecked Sendable {
	private let lock = NSLock()
	private var items: [String: Data] = [:]
	private var claims: [String: VaultCliAccess] = [:]
	private var enforced: [String: VaultCliAccess] = [:]
	private var readCounts: [String: Int] = [:]
	private var deletions: [String] = []
	private var changes: [(account: String, access: VaultCliAccess)] = []
	private var accessWrites: [(account: String, access: VaultCliAccess)] = []
	private var listingCount = 0
	private var failingWrites: Set<String> = []
	private var probesInconclusive = false
	private var contradictory: Set<String> = []
	/// Durable changes left before the process "dies"; nil while it runs on.
	private var mutationsBeforeCrash: Int?
	private var mutationCount = 0

	func reads(of account: String) -> Int { lock.withLock { readCounts[account] ?? 0 } }
	var deleted: [String] { lock.withLock { deletions } }
	var accessChanges: [(account: String, access: VaultCliAccess)] { lock.withLock { changes } }
	var writesWithAccess: [(account: String, access: VaultCliAccess)] { lock.withLock { accessWrites } }
	var listings: Int { lock.withLock { listingCount } }
	var names: Set<String> { lock.withLock { Set(items.keys) } }
	func data(_ account: String) -> Data? { lock.withLock { items[account] } }
	func claim(_ account: String) -> VaultCliAccess? { lock.withLock { items[account] == nil ? nil : claims[account] ?? .automatic } }
	func failWrites(to accounts: Set<String>) { lock.withLock { failingWrites = accounts } }
	func makeProbesInconclusive() { lock.withLock { probesInconclusive = true } }
	/// Makes `account`'s approval attributes contradict each other, as an
	/// approval marker without an access control does.
	func makeContradictory(_ account: String) { lock.withLock { _ = contradictory.insert(account) } }
	/// Lets `count` more writes, deletions and approval changes through, then
	/// refuses every one, as a process that died after them would leave things.
	func crash(after count: Int?) { lock.withLock { mutationsBeforeCrash = count } }
	var mutations: Int { lock.withLock { mutationCount } }

	/// Counts one durable change, or refuses it once the process has "died".
	private func mutateUnlocked() throws {
		if let left = mutationsBeforeCrash {
			guard left > 0 else { throw KeychainStoreError.status(operation: "crash", code: errSecIO) }
			mutationsBeforeCrash = left - 1
		}
		mutationCount += 1
	}
	func resetCounts() { lock.withLock { readCounts = [:]; deletions = []; changes = []; accessWrites = []; listingCount = 0 } }

	/// Stores `data` as `account`, claiming `access`, and enforcing `enforcing`
	/// when it differs, as an item whose attributes don't match its access control.
	func store(_ account: String, _ data: Data, access: VaultCliAccess = .automatic, enforcing: VaultCliAccess? = nil) {
		lock.withLock {
			items[account] = data
			claims[account] = access
			enforced[account] = enforcing ?? access
		}
	}

	func read(service: String, account: String) throws -> Data? {
		lock.withLock {
			readCounts[account, default: 0] += 1
			return items[account]
		}
	}

	func write(service: String, account: String, data: Data) throws {
		try lock.withLock {
			if failingWrites.contains(account) { throw KeychainStoreError.status(operation: "write", code: errSecIO) }
			try mutateUnlocked()
			items[account] = data
		}
	}

	func write(service: String, account: String, data: Data, access: VaultCliAccess) throws {
		try lock.withLock {
			if failingWrites.contains(account) { throw KeychainStoreError.status(operation: "write", code: errSecIO) }
			try mutateUnlocked()
			items[account] = data
			claims[account] = access
			enforced[account] = access
			accessWrites.append((account, access))
		}
	}

	func add(service: String, account: String, data: Data) throws {
		try lock.withLock {
			guard items[account] == nil else { throw KeychainStoreError.status(operation: "add", code: errSecDuplicateItem) }
			try mutateUnlocked()
			items[account] = data
		}
	}

	func delete(service: String, account: String) throws -> Bool {
		try lock.withLock {
			try mutateUnlocked()
			let found = items.removeValue(forKey: account) != nil
			if found { deletions.append(account) }
			claims.removeValue(forKey: account)
			enforced.removeValue(forKey: account)
			return found
		}
	}

	func accounts(service: String) throws -> [String: VaultCliAccess] {
		try lock.withLock {
			listingCount += 1
			guard contradictory.isDisjoint(with: items.keys) else { throw KeychainStoreError.contradictoryApproval }
			return Dictionary(uniqueKeysWithValues: items.keys.map { ($0, claims[$0] ?? .automatic) })
		}
	}

	func listing(service: String) throws -> [String: Result<VaultCliAccess, KeychainStoreError>] {
		lock.withLock {
			listingCount += 1
			return Dictionary(uniqueKeysWithValues: items.keys.map { account in
				(account, contradictory.contains(account) ? .failure(.contradictoryApproval) : .success(claims[account] ?? .automatic))
			})
		}
	}

	func cliAccess(service: String, account: String) throws -> VaultCliAccess {
		try lock.withLock {
			if contradictory.contains(account), items[account] != nil { throw KeychainStoreError.contradictoryApproval }
			return claims[account] ?? .automatic
		}
	}

	func setCliAccess(service: String, account: String, access: VaultCliAccess) throws -> VaultCliAccess {
		try lock.withLock {
			guard items[account] != nil else { throw KeychainStoreError.status(operation: "change CLI approval", code: errSecItemNotFound) }
			try mutateUnlocked()
			contradictory.remove(account)
			claims[account] = access
			enforced[account] = access
			changes.append((account, access))
			return access
		}
	}

	func probe(service: String, account: String, openAccounts: [String]) -> KeychainProbeOutcome {
		lock.withLock {
			if probesInconclusive { return .inconclusive }
			guard items[account] != nil else { return .absent }
			return (enforced[account] ?? .automatic) == .requireApproval ? .protected : .automatic
		}
	}
}

private let vault = "proj"
private let values = Data(#"{"environments":{"default":{"TOKEN":"team"}}}"#.utf8)

private func marker(_ features: String, state: String = "active", restore: String? = nil) -> Data {
	let restored = restore.map { ",\"restore\":\($0)" } ?? ""
	return Data(#"{"schemaVersion":1,"vaultId":"proj","state":"\#(state)","features":{\#(features)}\#(restored)}"#.utf8)
}

private let overridesV1 = #""overrides":{"version":1,"ifUnsupported":"refuse","kinds":["overrides"],"state":"active"}"#
private let overridesV2 = #""overrides":{"version":2,"ifUnsupported":"refuse","kinds":["overrides"],"state":"active"}"#
private let futureReadOnly = #""future":{"version":1,"ifUnsupported":"readOnly","kinds":["future-log"],"state":"active"}"#
private let overridesRecord = Data(#"{"schemaVersion":1,"vaultId":"proj","environments":{"default":{"set":{"TOKEN":"mine"},"unset":[]}}}"#.utf8)

private func markerName(_ vaultId: String = vault) throws -> String {
	try CompanionEngine.markerAccount(vaultId: vaultId)
}

private func recordName(_ kind: String, part: Int? = nil, vaultId: String = vault, staged: Bool = false) throws -> String {
	try CompanionEngine.accountNames([.init(role: staged ? .staged : .record, vaultId: vaultId, kind: kind, part: part)])[0]
}

private func vendoredFixture(_ name: String) throws -> Data {
	try Data(contentsOf: URL(fileURLWithPath: #filePath)
		.deletingLastPathComponent().deletingLastPathComponent()
		.appending(path: "Vendor/EnvEngine/fixtures/companion/\(name).json"))
}

/// A Keychain service holding one indexed project, `proj`, with `values`.
private func makeService() throws -> (KeychainService, CompanionTestBackend, String) {
	let backend = CompanionTestBackend()
	let name = "dev.lpm.vault.companion.\(UUID().uuidString)"
	let service = KeychainService(testingService: name, backend: backend)
	guard case .success = service.createEnvironments(
		vaultId: vault, projectName: "Project", projectPath: "", environments: ["default": ["TOKEN": "team"]])
	else { throw KeychainError.encodingFailed }
	return (service, backend, name)
}

private func refusal<T>(_ result: Result<T, KeychainError>) -> CompanionRefusal? {
	if case .failure(.companion(let refusal)) = result { refusal } else { nil }
}

private func refusal(_ result: KeychainResult) -> CompanionRefusal? {
	if case .failure(.companion(let refusal)) = result { refusal } else { nil }
}

@Suite("Companion storage", .serialized)
struct CompanionStorageTests {
	// MARK: - The engine's contract

	@Test("every account fixture is described the way the CLI parses it")
	func accountFixtures() throws {
		struct Case: Decodable {
			let account: String
			let valid: Bool
			let type: String?
			let vaultId: String?
			let kind: String?
			let part: Int?
			let accessClass: String?
		}
		struct Fixture: Decodable { let cases: [Case] }
		let fixture = try JSONDecoder().decode(Fixture.self, from: vendoredFixture("accounts"))
		let described = try CompanionEngine.describe(fixture.cases.map(\.account))
		for (entry, description) in zip(fixture.cases, described) {
			switch description {
			case .outside:
				#expect(!entry.valid && !entry.account.hasPrefix("__vault_"), "\(entry.account)")
			case .invalid:
				#expect(!entry.valid, "\(entry.account)")
			case .account(let account):
				#expect(entry.valid, "\(entry.account)")
				#expect(account.role.rawValue == entry.type, "\(entry.account)")
				#expect(account.vaultId == entry.vaultId, "\(entry.account)")
				#expect(account.kind == entry.kind, "\(entry.account)")
				#expect(account.part == entry.part, "\(entry.account)")
				#expect(account.access.rawValue == (entry.accessClass ?? "open"), "\(entry.account)")
			}
		}
	}

	@Test("every marker fixture assesses with the level the CLI records")
	func markerFixtures() throws {
		struct Case: Decodable {
			let name: String
			let vaultId: String
			let json: String
			let valid: Bool
			let level: CompanionEngine.Level?
			let needsResume: Bool?
		}
		struct Fixture: Decodable { let cases: [Case] }
		let fixture = try JSONDecoder().decode(Fixture.self, from: vendoredFixture("markers"))
		#expect(!fixture.cases.isEmpty)
		for entry in fixture.cases {
			let assessment = try CompanionEngine.assess(vaultId: entry.vaultId, .init(marker: Data(entry.json.utf8)))
			#expect(assessment.marker == (entry.valid ? .valid : .invalid), "\(entry.name)")
			#expect(assessment.level == entry.level, "\(entry.name)")
			if let needsResume = entry.needsResume { #expect(assessment.needsResume == needsResume, "\(entry.name)") }
		}
	}

	// MARK: - The gate

	@Test("a newer overrides version refuses reads and writes, and the project can still be deleted")
	func unsupportedOverridesRefuse() throws {
		let (service, backend, _) = try makeService()
		backend.store(try markerName(), marker(overridesV2))
		backend.store(try recordName("overrides"), Data("v2".utf8))

		#expect(refusal(service.getProjectResult(vaultId: vault)) == .unsupported(feature: "overrides", version: 2, level: .refuse))
		#expect(refusal(service.updateEnvironments(vaultId: vault, environments: ["default": ["TOKEN": "new"]])) != nil)
		#expect(backend.data(vault) == values)
		#expect(refusal(service.getProjectResult(vaultId: vault))?.message.contains("doesn’t support") == true)

		guard case .success = service.applyVaultTransaction(project: .delete(vaultId: vault, deletePayload: true), data: [])
		else { Issue.record("deletion is allowed in every state"); return }
		#expect(backend.names.allSatisfy { !$0.hasPrefix("__vault_companion") && !$0.hasPrefix("__vault_features") && $0 != vault })
	}

	@Test("a feature this version can only read lets values load and refuses changes")
	func readOnlyFeature() throws {
		let (service, backend, _) = try makeService()
		backend.store(try markerName(), marker(futureReadOnly))
		backend.store(try recordName("future-log", part: 0), Data("entry".utf8))

		#expect(try service.getProjectResult(vaultId: vault).get()?.secrets(for: "default") == ["TOKEN": "team"])
		let refused = refusal(service.updateEnvironments(vaultId: vault, environments: ["default": ["TOKEN": "new"]]))
		#expect(refused == .unsupported(feature: "future", version: 1, level: .readOnly))
		#expect(refused?.message.contains("can only read") == true)
		#expect(backend.data(vault) == values)
	}

	@Test("an invalid marker hides values until a project-wide discard, which keeps them")
	func invalidMarkerIsDiscarded() throws {
		let (service, backend, _) = try makeService()
		backend.store(try markerName(), Data(#"{"schemaVersion":1}"#.utf8))
		backend.store(try recordName("future-kind"), Data("stray".utf8))

		guard case .damaged? = refusal(service.getProjectResult(vaultId: vault)) else {
			Issue.record("an invalid marker blocks reads")
			return
		}
		let states = try service.projectStatesResult(vaultIds: [vault]).get()
		let reviewed = try #require(states.companion[vault])
		let damage = try #require(reviewed.damage.first)
		#expect(damage.code == "invalidMarker")
		#expect(reviewed.repairs == [.init(action: .discardProject, feature: nil)])

		#expect(try service.repairCompanionData(vaultId: vault, reviewed: reviewed).get() == .repaired(nil))

		#expect(backend.data(try markerName()) == nil)
		#expect(backend.data(try recordName("future-kind")) == nil)
		#expect(try service.getProjectResult(vaultId: vault).get()?.secrets(for: "default") == ["TOKEN": "team"])
		#expect(try service.projectStatesResult(vaultIds: [vault]).get().companion.isEmpty)
	}

	@Test("a deletion a crash left unfinished is finished before the project is read")
	func unfinishedDeletionIsFinished() throws {
		let (service, backend, _) = try makeService()
		backend.store(try markerName(), marker("", state: "deleting"))
		for part in 0..<40 { backend.store(try recordName("future-log", part: part), Data("x".utf8)) }

		#expect(try service.getProjectResult(vaultId: vault).get() != nil)

		#expect(backend.data(try markerName()) == nil)
		#expect(!backend.names.contains { $0.hasPrefix("__vault_companion") })
		#expect(backend.data(vault) == values, "finishing a deletion never deletes values a client wrote since")
	}

	@Test("an operation reads the marker once per lock scope")
	func markerIsReadOncePerScope() throws {
		let (service, backend, _) = try makeService()
		backend.store(try markerName(), marker(overridesV1))
		backend.store(try recordName("overrides"), overridesRecord)
		backend.resetCounts()

		_ = try service.withKeychainTransaction {
			_ = service.getProjectResult(vaultId: vault)
			_ = service.getProjectResult(vaultId: vault)
			_ = service.updateEnvironments(vaultId: vault, environments: ["default": ["TOKEN": "new"]])
		}.get()
		#expect(backend.reads(of: try markerName()) == 1)

		_ = service.getProjectResult(vaultId: vault)
		#expect(backend.reads(of: try markerName()) == 2, "absence is never trusted from an earlier scope")
	}

	@Test("deleting a project deletes its newer data, the shared key before any part")
	func deletionShredsTheKeyFirst() throws {
		let (service, backend, _) = try makeService()
		let history = #""history":{"version":1,"ifUnsupported":"ignore","kinds":["history-head","history","key"],"state":"active"}"#
		backend.store(try markerName(), marker("\(overridesV1),\(history)"))
		backend.store(try recordName("overrides"), overridesRecord)
		backend.store(try recordName("key"), Data(repeating: 7, count: 58))
		backend.store(try recordName("history-head"), Data("head".utf8))
		for part in 0..<16 { backend.store(try recordName("history", part: part), Data(repeating: UInt8(part), count: 64)) }
		backend.resetCounts()

		guard case .success = service.applyVaultTransaction(project: .delete(vaultId: vault, deletePayload: true), data: [])
		else { Issue.record("the project was kept"); return }

		#expect(!backend.names.contains { $0.hasPrefix("__vault_companion") || $0.hasPrefix("__vault_features") || $0 == vault })
		let deleted = backend.deleted
		let key = try #require(deleted.firstIndex(of: try recordName("key")))
		let firstPart = try #require(deleted.firstIndex(of: try recordName("history", part: 0)))
		#expect(key < firstPart)
	}

	@Test("values and companion records never go through the generic data calls")
	func genericCallsRefuseGatedAccounts() throws {
		let (service, backend, _) = try makeService()
		let record = try recordName("overrides")
		backend.store(record, overridesRecord)

		#expect(service.readDataResult(account: vault) == .failure(.accessDenied))
		#expect(service.readDataResult(account: record) == .failure(.accessDenied))
		#expect(!service.writeData(account: record, data: Data()))
		#expect(!service.deleteData(account: try markerName()))
		guard case .failure(.accessDenied) = service.applyVaultTransaction(project: nil, data: [.write(account: record, data: Data())])
		else { Issue.record("a generic transaction wrote a companion record"); return }
		#expect(backend.data(record) == overridesRecord)
		#expect(service.writeData(account: "__org_associations__", data: Data("{}".utf8)))
	}

	// MARK: - Transactions and recovery

	@Test("a transaction can't write a record no feature of the marker it leaves lists")
	func unlistedWritesAreRefused() throws {
		let backend = CompanionTestBackend()
		let store = SharedKeychainStore(service: "companion-\(UUID().uuidString)", backend: backend)
		backend.store(vault, values)
		let record = try recordName("overrides")

		#expect(throws: KeychainStoreError.integrityValidationFailed) {
			try store.applyVaultTransaction([.write(account: record, data: overridesRecord)])
		}
		#expect(backend.data(record) == nil)

		try store.applyVaultTransaction([
			.write(account: try markerName(), data: marker(overridesV1)),
			.write(account: record, data: overridesRecord),
		])
		#expect(backend.data(record) == overridesRecord)
	}

	@Test("recovery replays a committed journal over a stray record it doesn't touch")
	func recoveryOverStrayRecord() throws {
		let backend = CompanionTestBackend()
		let store = SharedKeychainStore(service: "companion-\(UUID().uuidString)", backend: backend)
		backend.store(vault, values)
		backend.store(try markerName(), marker(overridesV1))
		backend.store(try recordName("future-kind"), Data("stray".utf8))
		let record = try recordName("overrides")
		backend.failWrites(to: [record])

		#expect(throws: KeychainStoreError.self) { try store.applyVaultTransaction([.write(account: record, data: overridesRecord)]) }
		#expect(backend.data("__vault_transaction_v3__") != nil, "the committed journal waits for recovery")

		backend.failWrites(to: [])
		try store.recoverVaultTransaction()

		#expect(backend.data(record) == overridesRecord)
		#expect(backend.data(try recordName("future-kind")) == Data("stray".utf8))
		#expect(backend.data("__vault_transaction_v3__") == nil)
	}

	@Test("a staged record a resumed restore moves takes its values item's verified approval")
	func movedRecordFollowsValues() throws {
		let (service, backend, _) = try makeService()
		backend.store(vault, values, access: .automatic, enforcing: .requireApproval)
		let restore = #"{"phase":"activating","replaces":[],"features":{\#(overridesV1)}}"#
		backend.store(try markerName(), marker("", state: "restoring", restore: restore))
		backend.store(try recordName("overrides", staged: true), overridesRecord)
		backend.resetCounts()

		#expect(try service.getProjectResult(vaultId: vault).get() != nil)

		let live = try recordName("overrides")
		#expect(backend.data(live) == overridesRecord)
		#expect(backend.data(try recordName("overrides", staged: true)) == nil)
		#expect(backend.writesWithAccess.contains { $0.account == live && $0.access == .requireApproval })
		#expect(backend.claim(live) == .requireApproval)
	}

	// MARK: - Maintenance

	@Test("newer data whose project is gone is collected, and a hidden project keeps its own")
	func orphansAreCollected() throws {
		let (service, backend, _) = try makeService()
		backend.store(try markerName("gone"), marker(overridesV1).replacing(Data("proj".utf8), with: Data("gone".utf8)))
		backend.store(try recordName("overrides", vaultId: "gone"), Data("orphan".utf8))
		backend.store("hidden", values)
		backend.store(try markerName("hidden"), marker(overridesV1).replacing(Data("proj".utf8), with: Data("hidden".utf8)))
		backend.store(try recordName("overrides", vaultId: "hidden"), Data("kept".utf8))

		let maintenance = try service.maintainCompanionStorage().get()

		#expect(maintenance.orphanDeletions == 2)
		#expect(backend.data(try recordName("overrides", vaultId: "gone")) == nil)
		#expect(backend.data(try markerName("gone")) == nil)
		#expect(backend.data(try recordName("overrides", vaultId: "hidden")) == Data("kept".utf8))
	}

	@Test("turning approval on protects newer data first, and turning it off unprotects the values first")
	func approvalSwitchOrder() throws {
		let (service, backend, _) = try makeService()
		let record = try recordName("overrides")
		backend.store(try markerName(), marker(overridesV1))
		backend.store(record, overridesRecord)
		backend.resetCounts()

		#expect(try service.setCliAccess(vaultId: vault, access: .requireApproval).get() == .requireApproval)
		#expect(backend.accessChanges.map(\.account) == [record, vault])
		backend.resetCounts()
		#expect(try service.setCliAccess(vaultId: vault, access: .automatic).get() == .automatic)
		#expect(backend.accessChanges.map(\.account) == [vault, record])
		#expect(!backend.accessChanges.contains { $0.account == (try? markerName()) }, "the marker stays open")
	}

	@Test("reconciling changes only records whose approval differs from their values item's")
	func reconcileFixesMismatches() throws {
		let (service, backend, _) = try makeService()
		backend.store(vault, values, access: .requireApproval)
		backend.store(try markerName(), marker("\(overridesV1),\(futureReadOnly.replacingOccurrences(of: "readOnly", with: "ignore"))"))
		backend.store(try recordName("overrides"), overridesRecord, access: .requireApproval)
		backend.store(try recordName("future-log", part: 0), Data("x".utf8), access: .requireApproval, enforcing: .automatic)
		backend.resetCounts()

		#expect(try service.maintainCompanionStorage().get().accessFixes == 1)
		#expect(backend.accessChanges.map(\.account) == [try recordName("future-log", part: 0)])
		#expect(try service.maintainCompanionStorage().get().accessFixes == 0)
	}

	@Test("an inconclusive probe changes nothing")
	func inconclusiveProbeChangesNothing() throws {
		let (service, backend, _) = try makeService()
		backend.store(vault, values, access: .requireApproval)
		backend.store(try markerName(), marker(overridesV1))
		backend.store(try recordName("overrides"), overridesRecord)
		backend.makeProbesInconclusive()

		#expect(try service.maintainCompanionStorage().get().accessFixes == 0)
		#expect(backend.claim(try recordName("overrides")) == .automatic)
	}

	// MARK: - Display and backups

	@Test("project states come from one listing and name only projects with newer data")
	func projectStatesUseOneListing() throws {
		let (service, backend, _) = try makeService()
		backend.store(try markerName(), marker(overridesV1))
		backend.store(try recordName("overrides"), overridesRecord)
		backend.store("plain", values)
		backend.resetCounts()

		let states = try service.projectStatesResult(vaultIds: [vault, "plain"]).get()

		#expect(backend.listings == 1)
		#expect(Set(states.cliAccess.keys) == [vault, "plain"])
		#expect(Set(states.companion.keys) == [vault])
		#expect(states.companion[vault]?.damage == [])
		#expect(backend.reads(of: try markerName("plain")) == 0, "the listing settles a marker's absence")
	}

	@Test("a project whose interrupted change can't be finished shows as interrupted, and the others still load")
	func failedResumeStaysWithItsProject() throws {
		let (service, backend, _) = try makeService()
		backend.store(try markerName(), marker("", state: "deleting"))
		backend.store(try recordName("future-kind"), Data("x".utf8))
		guard case .success = service.createEnvironments(vaultId: "other", projectName: "Other", projectPath: "", environments: ["default": [:]])
		else { Issue.record("couldn't create the second project"); return }
		backend.store(try markerName("other"), marker(overridesV2).replacing(Data("proj".utf8), with: Data("other".utf8)))
		backend.failWrites(to: ["__vault_transaction_v3__"])

		let states = try service.projectStatesResult(vaultIds: [vault, "other"]).get()

		#expect(states.companion[vault]?.needsResume == true)
		let reason = try #require(states.unfinished[vault])
		#expect(states.companion["other"]?.unsupported?.feature == "overrides")
		let state = try #require(states.companion[vault])
		let interrupted = try #require(CompanionStatePresentation(state, unfinished: reason))
		#expect(interrupted.tone == .interrupted)
		#expect(interrupted.detail.hasSuffix("It couldn’t be finished: \(reason)."), "the banner says why")

		backend.failWrites(to: [])
		let finished = try service.projectStatesResult(vaultIds: [vault]).get()
		#expect(finished.companion[vault] == nil, "Try Again finishes the deletion")
		#expect(backend.data(try recordName("future-kind")) == nil)
	}

	@Test("a refresh keeps a project whose newer data hides its values, with its state, instead of failing")
	func refreshKeepsRefusedProject() async throws {
		let keychain = MockKeychainService()
		keychain.storage[vault] = ("Project", "", ["TOKEN": "team"])
		keychain.storage["plain"] = ("Plain", "", [:])
		let newer = try CompanionEngine.assess(vaultId: vault, .init(marker: marker(overridesV2)))
		keychain.companionStates[vault] = newer
		keychain.companionRefusals[vault] = CompanionRefusal(newer)
		let persistence = VaultPersistenceCoordinator(service: keychain)

		let snapshot = try await persistence.refreshSnapshot(selectedProjectID: vault).get()

		#expect(snapshot.companion[vault] == newer)
		#expect(snapshot.projects.first { $0.id == vault }?.hasLoadedEnvironments == false)
		#expect(snapshot.projects.count == 2)
	}

	@Test("damage only a listing sees is shown, and reads still authorize against the marker alone")
	func listingDamageIsDisplayOnly() throws {
		let (service, backend, _) = try makeService()
		backend.store(try markerName(), marker(overridesV1))
		backend.store(try recordName("overrides"), overridesRecord)
		backend.store(try recordName("notes"), Data("stray".utf8))

		let (states, project) = try service.withKeychainTransaction {
			(service.projectStatesResult(vaultIds: [vault]), service.getProjectResult(vaultId: vault))
		}.get()

		let reviewed = try #require(try states.get().companion[vault])
		let damage = try #require(reviewed.damage.first)
		#expect(damage.code == "unlistedRecord" && damage.kind == "notes")
		#expect(reviewed.repairs == [.init(action: .removeUnlisted, feature: nil)])
		#expect(try project.get()?.secrets(for: "default") == ["TOKEN": "team"], "the read in the same scope isn't refused")

		_ = try service.repairCompanionData(vaultId: vault, reviewed: reviewed).get()
		#expect(backend.data(try recordName("notes")) == nil)
		#expect(backend.data(try recordName("overrides")) == overridesRecord)
	}

	@Test("a backup leaves out a project its newer data keeps on the Mac, with why, and notes newer data it doesn't carry")
	func backupExclusions() throws {
		let (service, backend, _) = try makeService()
		backend.store(try markerName(), marker(overridesV1))
		backend.store(try recordName("overrides"), overridesRecord)
		guard case .success = service.createEnvironments(vaultId: "newer", projectName: "Newer", projectPath: "", environments: ["default": [:]])
		else { Issue.record("couldn't create the second project"); return }
		backend.store(try markerName("newer"), marker(overridesV2).replacing(Data("proj".utf8), with: Data("newer".utf8)))

		let inventory = try service.backupInventoryResult().get()

		#expect(inventory.projects.map(\.vaultId) == [vault])
		#expect(inventory.companion.withNewerData == [vault])
		#expect(inventory.companion.excluded.map(\.vaultId) == ["newer"])
		#expect(inventory.companion.excluded.first?.listing?.name == "Newer")
		#expect(inventory.companion.excluded.first?.reason.contains("personal overrides v2") == true)
		#expect(try service.backupCompanionNotesResult().get() == inventory.companion, "the export sheet's note before export says the same")
	}

	@Test("the banner says what newer data means, and nothing for a healthy project")
	func presentation() throws {
		let damaged = try CompanionEngine.assess(vaultId: vault, .init(marker: Data(#"{"schemaVersion":1}"#.utf8)))
		let shown = try #require(CompanionStatePresentation(damaged))
		#expect(shown.tone == .damaged)
		#expect(shown.title == "This project’s newer data is damaged")
		#expect(shown.detail == "Its feature marker is invalid. Its values stay hidden, and LPM won’t run it, until it’s repaired.")
		#expect(shown.repairs == [.init(action: .discardProject, feature: nil)])
		let confirmation = shown.repairConfirmation(subject: .init(mark: .symbol("folder"), name: "Project")) {}
		#expect(confirmation.title == "Repair this project’s newer data?")
		#expect(confirmation.message.contains("Its values stay as they are."))

		let newer = try CompanionEngine.assess(vaultId: vault, .init(marker: marker(overridesV2)))
		let update = try #require(CompanionStatePresentation(newer))
		#expect(update.tone == .update)
		#expect(update.repairs.isEmpty)
		#expect(update.detail.contains("personal overrides v2, which this version of LPM Vault doesn’t support"))

		let missing = try CompanionEngine.assess(vaultId: vault, .init(marker: marker(overridesV1), inventory: []))
		#expect(CompanionStatePresentation(missing)?.repairs == [.init(action: .removeFeature, feature: "overrides")])
		#expect(CompanionStatePresentation(try CompanionEngine.assess(vaultId: vault, .init(marker: marker(overridesV1)))) == nil)
	}

	@Test("a failed home move says when the copies it left include newer data")
	func homeMoveNamesNewerData() throws {
		#expect(LPMHomeMove.holdsNewerData([vault, try recordName("overrides")]))
		#expect(!LPMHomeMove.holdsNewerData([vault, "__vault_project_index_marker__"]))
		let error = LPMHomeMoveError.copiesLeft(reason: "It failed.", home: "~/other", includesNewerData: true)
		#expect(error.errorDescription == "It failed. Some copies stayed in ~/other, among them env projects’ newer data; LPM Vault removes them the next time it unlocks.")
	}

	@Test("the export result names projects backed up without their newer data")
	func exportNote() {
		#expect(BackupExportSheet.newerDataNote([]) == nil)
		#expect(BackupExportSheet.newerDataNote(["Web"]) == "Backups don’t carry newer data yet, such as personal overrides, so Web was backed up without it.")
		#expect(BackupExportSheet.newerDataNote(["Web", "API"])?.hasSuffix("were backed up without it.") == true)
	}

	// MARK: - The store and the coordinator

	@Test("a project whose newer data refuses reads can still be deleted")
	func refusedProjectIsDeletable() async {
		let keychain = MockKeychainService()
		keychain.storage[vault] = ("Project", "", [:])
		keychain.companionRefusals[vault] = .unsupported(feature: "overrides", version: 2, level: .refuse)
		let persistence = VaultPersistenceCoordinator(service: keychain)

		guard case .success = await persistence.deleteProjectAndMetadata(vaultId: vault) else {
			Issue.record("deleting needs no read of values")
			return
		}
		#expect(keychain.storage[vault] == nil)
		#expect(keychain.companionMaintenanceCount == 1, "a deletion collects orphans")
	}

	@Test("repairing asks again, then clears the project's damage")
	@MainActor
	func storeRepairs() async throws {
		let keychain = MockKeychainService()
		keychain.storage[vault] = ("Project", "", ["TOKEN": "team"])
		let damaged = try CompanionEngine.assess(vaultId: vault, .init(marker: Data(#"{"schemaVersion":1}"#.utf8)))
		keychain.companionStates[vault] = damaged
		let biometric = MockBiometricService()
		let store = VaultStore(
			keychainService: keychain, biometricService: biometric, apiService: MockAPIService(),
			envFileImportService: MockEnvFileImportService(), preferences: .standard,
			authTokenProvider: { _, _ in "session-token" }, authSessionClearer: { _ in })
		await store.unlock()
		store.selectedProjectId = vault
		#expect(store.projectCompanionStates[vault] == damaged)
		#expect(try await waitUntil { keychain.companionMaintenanceCount == 1 }, "unlocking runs companion maintenance")

		#expect(await store.repairCompanionData(projectId: vault, reviewed: damaged))

		#expect(biometric.confirmationReasons == ["repair this env project’s newer data"])
		#expect(keychain.companionRepairs.map(\.vaultId) == [vault])
		#expect(store.projectCompanionStates[vault] == nil)
		#expect(!store.isRepairingCompanionData)
	}

	@Test("a repair the person doesn't confirm changes nothing")
	@MainActor
	func unconfirmedRepair() async throws {
		let keychain = MockKeychainService()
		keychain.storage[vault] = ("Project", "", [:])
		let damaged = try CompanionEngine.assess(vaultId: vault, .init(marker: Data(#"{"schemaVersion":1}"#.utf8)))
		keychain.companionStates[vault] = damaged
		let biometric = MockBiometricService()
		let store = VaultStore(
			keychainService: keychain, biometricService: biometric, apiService: MockAPIService(),
			envFileImportService: MockEnvFileImportService(), preferences: .standard,
			authTokenProvider: { _, _ in "session-token" }, authSessionClearer: { _ in })
		await store.unlock()
		store.selectedProjectId = vault
		biometric.shouldSucceed = false

		#expect(!(await store.repairCompanionData(projectId: vault, reviewed: damaged)))
		#expect(keychain.companionRepairs.isEmpty)
		#expect(store.projectCompanionStates[vault] == damaged)
	}

	@Test("a refused project's load failure says why in the app's words")
	func loadFailureMessage() {
		let failure = VaultLoadFailure(.companion(.unsupported(feature: "history", version: 3, level: .refuse)))
		#expect(failure.message == "This env project uses local history v3, which this version of LPM Vault doesn’t support. Update LPM Vault to open it.")
	}
}

@MainActor
private func makeReviewStore(_ keychain: MockKeychainService, biometric: MockBiometricService = MockBiometricService()) throws -> VaultStore {
	VaultStore(
		keychainService: keychain, biometricService: biometric, apiService: MockAPIService(),
		envFileImportService: MockEnvFileImportService(),
		preferences: try #require(UserDefaults(suiteName: "companion-review-\(UUID().uuidString)")),
		authTokenProvider: { _, _ in "session-token" }, authSessionClearer: { _ in })
}

private let invalidMarker = Data(#"{"schemaVersion":1}"#.utf8)

private func ownMetadataNames(_ count: Int) -> [String] {
	(0..<count).map {
		"__vault_project_metadata__:00000000-0000-4000-8000-000000000000:\(String($0, radix: 16).padding(toLength: 40, withPad: "0", startingAt: 0))"
	}
}

/// Regressions for the review of companion storage, each failing on the
/// code it reviewed.
@Suite("Companion storage review", .serialized)
struct CompanionStorageReviewTests {
	// MARK: - Repairs

	@Test("a feature removal reviewed before another client restored the record changes nothing")
	func staleFeatureRemoval() throws {
		let (service, backend, _) = try makeService()
		backend.store(try markerName(), marker(overridesV1))
		let reviewed = try #require(try service.projectStatesResult(vaultIds: [vault]).get().companion[vault])
		#expect(reviewed.repairs == [.init(action: .removeFeature, feature: "overrides")])
		backend.store(try recordName("overrides"), overridesRecord)

		#expect(service.repairCompanionData(vaultId: vault, reviewed: reviewed) == .failure(.companion(.changedSinceReview)))

		#expect(backend.data(try recordName("overrides")) == overridesRecord)
		#expect(backend.data(try markerName()) == marker(overridesV1))
	}

	@Test("a discard reviewed while the marker was invalid changes nothing once a valid one is written")
	func staleDiscard() throws {
		let (service, backend, _) = try makeService()
		backend.store(try markerName(), invalidMarker)
		let reviewed = try #require(try service.projectStatesResult(vaultIds: [vault]).get().companion[vault])
		#expect(reviewed.repairs == [.init(action: .discardProject, feature: nil)])
		backend.store(try markerName(), marker(overridesV1))
		backend.store(try recordName("overrides"), overridesRecord)

		#expect(service.repairCompanionData(vaultId: vault, reviewed: reviewed) == .failure(.companion(.changedSinceReview)))

		#expect(backend.data(try recordName("overrides")) == overridesRecord)
		#expect(backend.data(try markerName()) == marker(overridesV1))
	}

	@Test("a repair runs every repair its review lists, each once")
	func everyRepairRuns() throws {
		let (service, backend, _) = try makeService()
		backend.store(try markerName(), marker(overridesV1))
		backend.store(try recordName("notes"), Data("stray".utf8))
		backend.store(try recordName("future-log", part: 0), Data("stray".utf8))
		let reviewed = try #require(try service.projectStatesResult(vaultIds: [vault]).get().companion[vault])
		#expect(reviewed.repairs == [.init(action: .removeUnlisted, feature: nil), .init(action: .removeFeature, feature: "overrides")])

		#expect(try service.repairCompanionData(vaultId: vault, reviewed: reviewed).get() == .repaired(nil))

		#expect(!backend.names.contains { $0.hasPrefix("__vault_companion") || $0.hasPrefix("__vault_features") })
		#expect(backend.data(vault) == values)
	}

	@Test("a repair reviewed for one project never repairs the project selected since")
	@MainActor
	func repairStaysWithItsProject() async throws {
		let keychain = MockKeychainService()
		keychain.storage[vault] = ("Project", "", ["TOKEN": "team"])
		keychain.storage["other"] = ("Other", "", ["TOKEN": "other"])
		let damaged = try CompanionEngine.assess(vaultId: vault, .init(marker: invalidMarker))
		keychain.companionStates[vault] = damaged
		keychain.companionStates["other"] = try CompanionEngine.assess(vaultId: "other", .init(marker: invalidMarker))
		let store = try makeReviewStore(keychain)
		await store.unlock()
		store.openProject(id: vault)
		store.openProject(id: "other")

		#expect(await store.repairCompanionData(projectId: vault, reviewed: damaged))

		#expect(keychain.companionRepairs.map(\.vaultId) == [vault])
		store.lock()
	}

	@Test("a repair that hasn't committed when the vault locks never commits")
	@MainActor
	func lockWithdrawsRepair() async throws {
		let keychain = MockKeychainService()
		keychain.storage[vault] = ("Project", "", ["TOKEN": "team"])
		let damaged = try CompanionEngine.assess(vaultId: vault, .init(marker: invalidMarker))
		keychain.companionStates[vault] = damaged
		let store = try makeReviewStore(keychain)
		await store.unlock()
		store.openProject(id: vault)
		await store.waitForLocalStateRefresh()
		let entered = DispatchSemaphore(value: 0)
		let release = DispatchSemaphore(value: 0)
		keychain.beforeKeychainTransaction = { entered.signal(); release.wait() }
		let repair = Task { await store.repairCompanionData(projectId: vault, reviewed: damaged) }
		await withCheckedContinuation { continuation in
			DispatchQueue.global().async { entered.wait(); continuation.resume() }
		}
		keychain.beforeKeychainTransaction = nil

		store.lock()
		release.signal()

		#expect(!(await repair.value))
		#expect(keychain.companionRepairs.isEmpty)
	}

	@Test("a repair that committed is reported as done even when reading the state after it fails")
	@MainActor
	func repairCommittedThenStateFails() async throws {
		let keychain = MockKeychainService()
		keychain.storage[vault] = ("Project", "", ["TOKEN": "team"])
		let damaged = try CompanionEngine.assess(vaultId: vault, .init(marker: invalidMarker))
		keychain.companionStates[vault] = damaged
		let store = try makeReviewStore(keychain)
		await store.unlock()
		store.openProject(id: vault)
		keychain.failCompanionStates = true

		#expect(await store.repairCompanionData(projectId: vault, reviewed: damaged))
		#expect(keychain.companionRepairs.count == 1)
		#expect(store.error == nil)
		store.lock()
	}

	// MARK: - Commits and the lock scope

	@Test("a transaction can't delete a marker and leave the records it lists")
	func markerDeletionOrphaningIsRefused() throws {
		let backend = CompanionTestBackend()
		let store = SharedKeychainStore(service: "companion-\(UUID().uuidString)", backend: backend)
		backend.store(vault, values)
		backend.store(try markerName(), marker(overridesV1))
		backend.store(try recordName("overrides"), overridesRecord)

		#expect(throws: KeychainStoreError.integrityValidationFailed) {
			try store.applyVaultTransaction([.delete(account: try markerName())])
		}
		#expect(backend.data(try markerName()) == marker(overridesV1))

		try store.applyVaultTransaction([.delete(account: try markerName()), .delete(account: try recordName("overrides"))])
		#expect(backend.data(try markerName()) == nil)
	}

	@Test("a transaction that changes a marker replaces what the lock scope knows about it")
	func markerChangeReplacesTheGate() throws {
		let backend = CompanionTestBackend()
		let counters = VaultKeychainPerformanceCounters()
		let store = SharedKeychainStore(service: "companion-\(UUID().uuidString)", backend: backend, performanceCounters: counters)
		backend.store(vault, values)
		try VaultKeychainTransactionLock.withLock {
			try store.authorizeCompanion(vaultId: vault, .write)
			try store.applyVaultTransaction([.write(account: try markerName(), data: marker(overridesV2))])
			#expect(throws: KeychainStoreError.companion(.unsupported(feature: "overrides", version: 2, level: .refuse))) {
				try store.authorizeCompanion(vaultId: vault, .readExcludingOverrides)
			}
		}
		#expect(counters.snapshot.markerReadCount == 1, "the scope read the marker once, and its own write told it the rest")
	}

	@Test("a project's transaction can't write another project's values past that project's gate")
	func otherOwnersValuesAreGated() throws {
		let (service, backend, _) = try makeService()
		guard case .success = service.createEnvironments(vaultId: "other", projectName: "Other", projectPath: "", environments: ["default": ["A": "1"]])
		else { Issue.record("couldn't create the second project"); return }
		backend.store(try markerName("other"), marker(overridesV2).replacing(Data("proj".utf8), with: Data("other".utf8)))
		let otherValues = backend.data("other")

		let result = service.applyVaultTransaction(
			project: .update(vaultId: vault, environments: ["default": ["TOKEN": "new"]]),
			data: [.write(account: "other", data: values)])

		guard case .failure(.accessDenied) = result else { Issue.record("another project's values were written: \(result)"); return }
		#expect(backend.data("other") == otherValues)
		#expect(backend.data(vault) == values)
	}

	@Test("damage a listing finds refuses writes, and reads still authorize against the marker")
	func listedDamageRefusesWrites() throws {
		let (service, backend, _) = try makeService()
		backend.store(try markerName(), marker(overridesV1))

		let refused = refusal(service.updateEnvironments(vaultId: vault, environments: ["default": ["TOKEN": "new"]]))
		#expect(refused == .damaged("its “overrides” record is missing"))
		#expect(backend.data(vault) == values)
		#expect(try service.getProjectResult(vaultId: vault).get() != nil)
	}

	@Test("a project whose interrupted restore can't be finished can still be deleted")
	func stuckRestoreIsDeletable() throws {
		let (service, backend, _) = try makeService()
		let restore = #"{"phase":"activating","replaces":[],"features":{\#(overridesV1)}}"#
		backend.store(try markerName(), marker("", state: "restoring", restore: restore))
		backend.store(try recordName("overrides", staged: true), Data(repeating: 0x61, count: 101 * 1024))
		guard case .unfinished? = refusal(service.getProjectResult(vaultId: vault)) else {
			Issue.record("a restore that can't be finished hides the values, saying why")
			return
		}

		guard case .success = service.applyVaultTransaction(project: .delete(vaultId: vault, deletePayload: true), data: [])
		else { Issue.record("deletion is allowed in every state"); return }
		#expect(backend.names.allSatisfy {
			!$0.hasPrefix("__vault_companion") && !$0.hasPrefix("__vault_features") && !$0.hasPrefix("__vault_staged") && $0 != vault
		})
	}

	@Test("a project whose newer data refuses changes can still be renamed, without reading its values")
	func refusedProjectRenames() async throws {
		let (service, backend, _) = try makeService()
		backend.store(try markerName(), marker(overridesV2))
		backend.resetCounts()
		let persistence = VaultPersistenceCoordinator(service: service)

		let result = await persistence.mutateProject(
			projectId: vault, expectedName: "Project", expectedPath: "",
			mutation: .renameProject(expectedName: "Project", replacement: "Renamed"))

		guard case .success(let commit) = result else { Issue.record("renaming is metadata, allowed in every state: \(result)"); return }
		#expect(commit.project.name == "Renamed")
		#expect(try service.listProjectMetadataResult().get().first?.name == "Renamed")
		#expect(backend.data(vault) == values)
		#expect(backend.reads(of: vault) == 0, "a rename never reads values")
	}

	// MARK: - The display state

	@Test("refreshing keeps a refused selected project's reason instead of an empty workspace")
	@MainActor
	func refreshKeepsRefusal() async throws {
		let keychain = MockKeychainService()
		keychain.storage[vault] = ("Project", "", ["TOKEN": "team"])
		let refused = CompanionRefusal.unsupported(feature: "overrides", version: 2, level: .refuse)
		keychain.companionRefusals[vault] = refused
		let store = try makeReviewStore(keychain)
		await store.unlock()
		store.openProject(id: vault)
		#expect(try await waitUntil { store.selectedProjectLoadFailure == .companion(refused) })

		await store.refreshLocalState()

		#expect(store.selectedProjectLoadFailure == .companion(refused))
		#expect(store.selectedProjectLoadFailure?.isCompanion == true)
		store.lock()
	}

	@Test("a selected project whose interrupted change can't be finished doesn't fail the refresh")
	func stuckSelectedProjectKeepsTheRefresh() async throws {
		let (service, backend, _) = try makeService()
		backend.store(try markerName(), marker("", state: "deleting"))
		backend.store(try recordName("future-kind"), Data("x".utf8))
		backend.failWrites(to: ["__vault_transaction_v3__"])
		let persistence = VaultPersistenceCoordinator(service: service)

		let snapshot = try await persistence.refreshSnapshot(selectedProjectID: vault).get()

		#expect(snapshot.companion[vault]?.needsResume == true)
		#expect(snapshot.companionUnfinished[vault] != nil)
		guard case .unfinished? = snapshot.selectedProjectRefusal else {
			Issue.record("the selected project's values stay hidden, saying why")
			return
		}
	}

	@Test("a finished interrupted change is reported to the person until they dismiss it")
	@MainActor
	func resumeNoticeReachesThePerson() async throws {
		let (service, backend, _) = try makeService()
		backend.store(try markerName(), marker("", state: "deleting"))
		backend.store(try recordName("future-kind"), Data("x".utf8))
		let states = try service.projectStatesResult(vaultIds: [vault]).get()
		#expect(states.resumed[vault]?.kind == "deletion")
		#expect(try service.projectStatesResult(vaultIds: [vault]).get().resumed.isEmpty, "a notice is reported once")
		#expect(CompanionNoticePresentation(try #require(states.resumed[vault])).text
			== "LPM Vault finished deleting this project’s newer data, which an earlier run left unfinished.")

		let keychain = MockKeychainService()
		keychain.storage[vault] = ("Project", "", ["TOKEN": "team"])
		keychain.pendingCompanionNotices = states.resumed
		let store = try makeReviewStore(keychain)
		await store.unlock()
		#expect(store.companionNotices[vault]?.kind == "deletion")
		await store.refreshLocalState()
		#expect(store.companionNotices[vault]?.kind == "deletion", "a notice stays until dismissed")
		store.dismissCompanionNotice(for: vault)
		#expect(store.companionNotices.isEmpty)
		store.lock()
	}

	@Test("a project this version can only read offers no edits, and one it fully supports does")
	@MainActor
	func readOnlyProjectsCantBeEdited() async throws {
		let keychain = MockKeychainService()
		keychain.storage[vault] = ("Project", "", ["TOKEN": "team"])
		keychain.storage["plain"] = ("Plain", "", ["TOKEN": "team"])
		keychain.companionStates[vault] = try CompanionEngine.assess(vaultId: vault, .init(marker: marker(futureReadOnly)))
		let store = try makeReviewStore(keychain)
		await store.unlock()

		#expect(!store.canEditValues(of: vault))
		#expect(store.canEditValues(of: "plain"))
		store.lock()
	}

	@Test("values leave the Mac only while the project's newer data allows it then")
	@MainActor
	func exportChecksTheGateFirst() async throws {
		let keychain = MockKeychainService()
		keychain.storage[vault] = ("Project", "", ["TOKEN": "team"])
		let exports = ExportCount()
		let exporter = EnvFileExportService { _, _, _ in exports.add() }
		let store = VaultStore(
			keychainService: keychain, biometricService: MockBiometricService(), apiService: MockAPIService(),
			envFileImportService: MockEnvFileImportService(), envFileExportService: exporter,
			preferences: try #require(UserDefaults(suiteName: "companion-review-\(UUID().uuidString)")),
			authTokenProvider: { _, _ in "session-token" }, authSessionClearer: { _ in })
		await store.unlock()
		store.openProject(id: vault)
		#expect(try await waitUntil { store.selectedProject?.hasLoadedEnvironments == true })
		keychain.companionRefusals[vault] = .unsupported(feature: "overrides", version: 2, level: .refuse)

		await #expect(throws: KeychainError.companion(.unsupported(feature: "overrides", version: 2, level: .refuse))) {
			try await store.exportEnvironment(projectId: vault, environment: "default", to: URL(fileURLWithPath: "/tmp/.env"))
		}
		#expect(exports.count == 0)
		#expect(keychain.valuesLeavingChecks == [vault])
		store.lock()
	}

	@Test("a project whose approval contradicts itself can have its approval chosen again")
	@MainActor
	func contradictoryApprovalCanBeChosenAgain() async throws {
		let keychain = MockKeychainService()
		keychain.storage[vault] = ("Project", "", ["TOKEN": "team"])
		keychain.unreadableCliAccess = [vault]
		keychain.failureError = .contradictoryApproval
		let store = try makeReviewStore(keychain)
		await store.unlock()
		store.openProject(id: vault)
		#expect(try await waitUntil { store.selectedProjectCliAccessContradicts })
		#expect(store.selectedProjectCliAccess == nil)
		#expect(store.error == nil, "the banner says it, not an alert")

		keychain.unreadableCliAccess = []
		await store.changeCliAccess(to: .requireApproval)

		#expect(store.selectedProjectCliAccess == .requireApproval)
		#expect(!store.selectedProjectCliAccessContradicts)
		store.lock()
	}

	// MARK: - Backups

	@Test("a backup never leaves newer data behind without saying so")
	func backupNotesMarkerlessRecords() throws {
		let (service, backend, _) = try makeService()
		backend.store(try recordName("overrides"), overridesRecord)

		let inventory = try service.backupInventoryResult().get()

		#expect(inventory.companion.withNewerData.contains(vault) || inventory.companion.excluded.contains { $0.vaultId == vault })
	}

	@Test("a backup leaves out only the project whose interrupted change can't be finished")
	func backupSurvivesStuckResume() throws {
		let (service, backend, _) = try makeService()
		guard case .success = service.createEnvironments(vaultId: "other", projectName: "Other", projectPath: "", environments: ["default": ["A": "1"]])
		else { Issue.record("couldn't create the second project"); return }
		backend.store(try markerName(), marker("", state: "deleting"))
		backend.store(try recordName("future-kind"), Data("x".utf8))
		backend.failWrites(to: ["__vault_transaction_v3__"])

		let inventory = try service.backupInventoryResult().get()

		#expect(inventory.projects.map(\.vaultId) == ["other"])
		#expect(inventory.companion.excluded.map(\.vaultId) == [vault])
		#expect(inventory.companion.excluded.first?.reason.contains("couldn’t finish an interrupted change") == true)
	}

	@Test("a backup's note for a project removed from the sidebar names it and how to repair it")
	func removedProjectsAreToldApart() throws {
		let (service, backend, _) = try makeService()
		backend.store("hidden", values)
		backend.store(try markerName("hidden"), invalidMarker)

		let excluded = try #require(try service.backupInventoryResult().get().companion.excluded.first { $0.vaultId == "hidden" })

		#expect(excluded.listing == nil)
		#expect(excluded.reason.hasSuffix("Open its folder in LPM Vault to add it back, then repair it."))
		#expect(!excluded.reason.contains("project’s page"))
		#expect(BackupExporter.removedProjectName("hidden") != BackupExporter.removedProjectName("gone"))
	}

	@Test("an engine failure says what it couldn't check, not that nothing changed")
	func engineRefusalWording() {
		#expect(CompanionRefusal.engine("its input was too large").message == "LPM Vault couldn’t check this env project’s newer data (its input was too large).")
	}

	// MARK: - Maintenance

	@Test("orphan collection deletes at most its limit a pass, and counts only deletions")
	func orphanLimit() throws {
		let backend = CompanionTestBackend()
		let store = SharedKeychainStore(service: "companion-\(UUID().uuidString)", backend: backend)
		for part in 0..<253 { backend.store(try recordName("future-log", part: part, vaultId: "gone-a"), Data("x".utf8)) }
		for kind in ["one", "two", "three", "four"] { backend.store(try recordName(kind, vaultId: "gone-b"), Data("x".utf8)) }

		let made = try store.collectCompanionOrphans(limit: 256)

		let companion = backend.deleted.filter { $0.hasPrefix("__vault_companion") || $0.hasPrefix("__vault_features") }
		#expect(companion.count <= 256)
		#expect(made == companion.count)
		#expect(try store.collectCompanionOrphans(limit: 256) > 0, "the next pass finishes what's left")
		#expect(!backend.names.contains { $0.hasPrefix("__vault_companion") || $0.hasPrefix("__vault_features") })
	}

	@Test("one contradictory item elsewhere doesn't stop switching, maintaining or deleting a project")
	func contradictoryItemElsewhere() throws {
		let (service, backend, _) = try makeService()
		backend.store(try markerName(), marker(overridesV1))
		backend.store(try recordName("overrides"), overridesRecord)
		backend.store("broken", values)
		backend.makeContradictory("broken")

		#expect(try service.setCliAccess(vaultId: vault, access: .requireApproval).get() == .requireApproval)
		_ = try service.maintainCompanionStorage().get()
		#expect(try service.storedVaultIdsResult().get().contains("broken"))
		guard case .success = service.applyVaultTransaction(project: .delete(vaultId: vault, deletePayload: true), data: [])
		else { Issue.record("one contradictory item elsewhere stopped a deletion"); return }
	}

	@Test("reconcile sets a record whose approval contradicts itself to its values item's")
	func reconcileFixesContradictoryRecords() throws {
		let (service, backend, _) = try makeService()
		backend.store(vault, values, access: .requireApproval)
		backend.store(try markerName(), marker(overridesV1))
		let record = try recordName("overrides")
		backend.store(record, overridesRecord, access: .requireApproval)
		backend.makeContradictory(record)
		#expect(try service.projectStatesResult(vaultIds: [vault]).get().companion[vault]?.damage.map(\.code) == ["access"])

		#expect(try service.maintainCompanionStorage().get().accessFixes == 1)

		#expect(backend.claim(record) == .requireApproval)
		#expect(try service.projectStatesResult(vaultIds: [vault]).get().companion[vault]?.damage == [])
	}

	// MARK: - Crashes and resumes

	/// A project with values, overrides and enough history parts that its
	/// deletion takes several transactions.
	private func projectWithHistory() throws -> (KeychainService, CompanionTestBackend) {
		let (service, backend, _) = try makeService()
		let history = #""history":{"version":1,"ifUnsupported":"ignore","kinds":["history-head","history","key"],"state":"active"}"#
		backend.store(try markerName(), marker("\(overridesV1),\(history)"))
		backend.store(try recordName("overrides"), overridesRecord)
		backend.store(try recordName("key"), Data(repeating: 7, count: 32))
		for part in 0..<40 { backend.store(try recordName("history", part: part), Data("x".utf8)) }
		return (service, backend)
	}

	private func holdsNewerData(_ backend: CompanionTestBackend) -> Bool {
		backend.names.contains {
			$0.hasPrefix("__vault_companion") || $0.hasPrefix("__vault_features") || $0.hasPrefix("__vault_staged")
		}
	}

	@Test("a deletion that dies after any durable change finishes, and never leaves values without their newer data")
	func deletionSurvivesACrashAnywhere() throws {
		let (measure, measured) = try projectWithHistory()
		let before = measured.mutations
		guard case .success = measure.applyVaultTransaction(project: .delete(vaultId: vault, deletePayload: true), data: [])
		else { Issue.record("the clean deletion failed"); return }
		let total = measured.mutations - before
		#expect(total > 10)

		let key = try recordName("key")
		let overrides = try recordName("overrides")
		for survived in 0..<total {
			let (service, backend) = try projectWithHistory()
			backend.crash(after: survived)
			_ = service.applyVaultTransaction(project: .delete(vaultId: vault, deletePayload: true), data: [])
			backend.crash(after: nil)
			try service.withKeychainTransaction {}.get()
			#expect(backend.data("__vault_transaction_v3__") == nil, "\(survived): recovery finishes a committed journal")
			if backend.data(vault) != nil {
				#expect(backend.data(key) != nil && backend.data(overrides) != nil, "\(survived): values never stay without their key and overrides")
			}

			_ = try service.maintainCompanionStorage().get()
			if backend.data(vault) != nil {
				guard case .success = service.applyVaultTransaction(project: .delete(vaultId: vault, deletePayload: true), data: [])
				else { Issue.record("\(survived): deleting again failed"); continue }
			}

			#expect(!holdsNewerData(backend), "\(survived): every record is gone")
			#expect(backend.data(vault) == nil, "\(survived)")
			#expect(backend.data("__vault_transaction_v3__") == nil, "\(survived): no journal is left")
		}
	}

	@Test("an approval switch that dies after any change never leaves a record weaker than its values, and reconcile matches them")
	func approvalSwitchSurvivesACrashAnywhere() throws {
		for target in [VaultCliAccess.requireApproval, .automatic] {
			let (measure, measured, _) = try makeService()
			let start: VaultCliAccess = target == .requireApproval ? .automatic : .requireApproval
			func prepare(_ backend: CompanionTestBackend) throws {
				backend.store(vault, values, access: start)
				backend.store(try markerName(), marker(overridesV1))
				backend.store(try recordName("overrides"), overridesRecord, access: start)
			}
			try prepare(measured)
			let before = measured.mutations
			#expect(try measure.setCliAccess(vaultId: vault, access: target).get() == target)
			let total = measured.mutations - before

			for survived in 0..<total {
				let (service, backend, _) = try makeService()
				try prepare(backend)
				backend.crash(after: survived)
				_ = service.setCliAccess(vaultId: vault, access: target)
				backend.crash(after: nil)
				let record = try recordName("overrides")
				#expect(!(backend.claim(vault) == .requireApproval && backend.claim(record) == .automatic), "\(target) after \(survived)")

				_ = try service.maintainCompanionStorage().get()

				#expect(backend.claim(record) == backend.claim(vault), "\(target) after \(survived): reconcile matches the record to its values")
			}
		}
	}

	@Test("every interrupted lifecycle step is finished or undone before the project is read")
	func everyLifecycleStepResumes() throws {
		let restoreFeatures = "{\(overridesV1)}"
		let markerAccount = try markerName()
		let overrides = try recordName("overrides")
		let stagedOverrides = try recordName("overrides", staged: true)
		struct Step {
			let name: String
			let marker: Data
			let records: [(kind: String, staged: Bool)]
			let notice: String
			let after: (CompanionTestBackend) -> Void
		}
		let steps: [Step] = [
			Step(name: "discarding", marker: marker(overridesV1, state: "discarding"), records: [("overrides", false), ("notes", false)], notice: "discard") { backend in
				#expect(backend.data(markerAccount) == nil)
				#expect(backend.names.allSatisfy { !$0.hasPrefix("__vault_companion") })
			},
			Step(name: "removing a feature",
				marker: marker(overridesV1.replacingOccurrences(of: #""state":"active""#, with: #""state":"removing""#)),
				records: [("overrides", false)], notice: "featureRemoval") { backend in
				#expect(backend.data(overrides) == nil)
			},
			Step(name: "a restore still staging",
				marker: marker("", state: "restoring", restore: #"{"phase":"staging","replaces":[],"features":\#(restoreFeatures)}"#),
				records: [("overrides", true)], notice: "restoreUndone") { backend in
				#expect(backend.data(stagedOverrides) == nil, "staged records are rolled back")
				#expect(backend.data(overrides) == nil)
			},
			Step(name: "a restore activating over a feature it replaces",
				marker: marker(overridesV1, state: "restoring", restore: #"{"phase":"activating","replaces":["overrides"],"features":\#(restoreFeatures)}"#),
				records: [("overrides", false), ("overrides", true)], notice: "restore") { backend in
				#expect(backend.data(stagedOverrides) == nil)
				#expect(backend.data(overrides) == Data("staged".utf8), "the staged record replaces the live one")
			},
		]
		for step in steps {
			let (service, backend, _) = try makeService()
			backend.store(try markerName(), step.marker)
			for record in step.records {
				backend.store(try recordName(record.kind, staged: record.staged), Data((record.staged ? "staged" : "live").utf8))
			}

			let states = try service.projectStatesResult(vaultIds: [vault]).get()

			#expect(states.unfinished.isEmpty, "\(step.name): \(states.unfinished)")
			#expect(states.resumed[vault]?.kind == step.notice, "\(step.name)")
			#expect(try service.getProjectResult(vaultId: vault).get()?.secrets(for: "default") == ["TOKEN": "team"], "\(step.name): values stay")
			step.after(backend)
		}
	}

	@Test("a project whose newer data refuses changes can still be hidden from the sidebar")
	func refusedProjectHides() throws {
		let (service, backend, _) = try makeService()
		backend.store(try markerName(), marker(overridesV2))

		#expect(service.removeFromSidebar(vaultId: vault))

		#expect(try service.listProjectMetadataResult().get().isEmpty)
		#expect(backend.data(vault) == values, "hiding keeps the values")
	}

	@Test("values that claim approval the Keychain doesn't enforce get it when their records are matched")
	func weakValuesAreStrengthened() throws {
		let (service, backend, _) = try makeService()
		backend.store(vault, values, access: .requireApproval, enforcing: .automatic)
		backend.store(try markerName(), marker(overridesV1))
		backend.store(try recordName("overrides"), overridesRecord)

		#expect(try service.maintainCompanionStorage().get().accessFixes == 1)

		#expect(backend.accessChanges.map(\.account) == [vault, try recordName("overrides")])
		#expect(backend.probe(service: "", account: vault, openAccounts: []) == .protected)
		#expect(backend.claim(try recordName("overrides")) == .requireApproval)
	}

	@Test("publishing checks the project's newer data right before its values go")
	@MainActor
	func publishChecksTheGateFirst() async throws {
		let keychain = MockKeychainService()
		keychain.storage[vault] = ("Project", "", ["TOKEN": "team"])
		let store = try makeReviewStore(keychain)
		await store.unlock()
		store.openProject(id: vault)
		#expect(try await waitUntil { store.selectedProject?.hasLoadedEnvironments == true })
		let dependencies = store.publishDependencies(for: vault)
		#expect(await dependencies.snapshot("default", .unchecked)?.values == ["TOKEN": "team"])

		keychain.companionRefusals[vault] = .unsupported(feature: "overrides", version: 2, level: .refuse)

		#expect(await dependencies.snapshot("default", .unchecked) == nil)
		#expect(keychain.valuesLeavingChecks == [vault, vault])
		store.lock()
	}

	@Test("before a backup runs, its sheet's note names what it will leave out")
	@MainActor
	func backupPreviewNamesLeftOutProjects() async throws {
		let keychain = MockKeychainService()
		keychain.storage[vault] = ("Project", "", ["TOKEN": "team"])
		keychain.backupCompanionNotes = VaultBackupCompanionNotes(
			excluded: [.init(vaultId: "hidden", listing: nil, reason: "Damaged.")], withNewerData: [vault])
		let store = try makeReviewStore(keychain)
		await store.unlock()

		let preview = try #require(await store.backupCompanionPreview())

		#expect(preview.leftOut == [.init(name: BackupExporter.removedProjectName("hidden"), reason: "Damaged.")])
		#expect(preview.withNewerData == ["Project"])
		#expect(BackupExportSheet.newerDataNote(preview.withNewerData, done: false)
			== "Backups don’t carry newer data yet, such as personal overrides, so Project will be backed up without it.")
		store.lock()
	}

	// MARK: - The shared contract

	@Test("every access fixture classifies as the CLI classifies it")
	func accessFixtures() throws {
		struct Case: Decodable {
			let name: String
			let marker: String?
			let accessControl: Bool
			let accessible: String?
			let claim: String
		}
		struct Fixture: Decodable { let cases: [Case] }
		let classes: [String: CFString] = [
			"whenUnlockedThisDeviceOnly": kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
			"whenUnlocked": kSecAttrAccessibleWhenUnlocked,
			"afterFirstUnlock": kSecAttrAccessibleAfterFirstUnlock,
		]
		let fixture = try JSONDecoder().decode(Fixture.self, from: vendoredFixture("access-claims"))
		#expect(!fixture.cases.isEmpty)
		for entry in fixture.cases {
			var attributes: [String: Any] = [:]
			if let marker = entry.marker { attributes[kSecAttrGeneric as String] = Data(marker.utf8) }
			if entry.accessControl {
				attributes[kSecAttrAccessControl as String] = try #require(SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, [], nil))
			}
			if let accessible = entry.accessible {
				guard let accessibleClass = classes[accessible] else {
					Issue.record("\(entry.name): an accessibility class this test doesn't know")
					continue
				}
				attributes[kSecAttrAccessible as String] = accessibleClass
			}
			let claim: String
			do {
				claim = try SecurityKeychainStoreBackend.cliAccess(attributes: attributes) == .requireApproval ? "requireApproval" : "automatic"
			} catch {
				#expect(error as? KeychainStoreError == .contradictoryApproval, "\(entry.name)")
				claim = "contradictory"
			}
			#expect(claim == entry.claim, "\(entry.name)")
		}
	}

	@Test("every journal fixture recovers, or is refused, as the CLI records")
	func journalFixtures() throws {
		struct Case: Decodable {
			let name: String
			let before: [String: String]
			let journal: AnyJSON
			let outcome: String
			let after: [String: String]?
		}
		struct Fixture: Decodable {
			let journalAccount: String
			let cases: [Case]
		}
		let fixture = try JSONDecoder().decode(Fixture.self, from: vendoredFixture("journals"))
		#expect(!fixture.cases.isEmpty)
		for entry in fixture.cases {
			let backend = CompanionTestBackend()
			let store = SharedKeychainStore(service: "companion-\(UUID().uuidString)", backend: backend)
			for (account, bytes) in entry.before { backend.store(account, try #require(Data(base64Encoded: bytes))) }
			backend.store(fixture.journalAccount, try JSONSerialization.data(withJSONObject: entry.journal.value))

			switch entry.outcome {
			case "recovers":
				#expect(throws: Never.self, "\(entry.name)") { try store.recoverVaultTransaction() }
				let after = try (entry.after ?? [:]).mapValues { try #require(Data(base64Encoded: $0)) }
				#expect(Dictionary(uniqueKeysWithValues: backend.names.map { ($0, backend.data($0) ?? Data()) }) == after, "\(entry.name)")
			case "refuses":
				#expect(throws: KeychainStoreError.self, "\(entry.name)") { try store.recoverVaultTransaction() }
				#expect(backend.data(fixture.journalAccount) != nil, "\(entry.name): the journal waits")
			default:
				Issue.record("\(entry.name): unknown outcome \(entry.outcome)")
			}
		}
	}

	// MARK: - Work

	@Test("a service with tens of thousands of accounts still shows its projects")
	func largeServiceStates() throws {
		let (service, backend, _) = try makeService()
		backend.store(try markerName(), marker(overridesV1))
		backend.store(try recordName("overrides"), overridesRecord)
		for name in ownMetadataNames(30_000) { backend.store(name, Data()) }

		#expect(try service.projectStatesResult(vaultIds: [vault]).get().companion[vault]?.damage == [])
	}

	@Test("a committed journal replays in a service with tens of thousands of accounts")
	func largeServiceRecovery() throws {
		let backend = CompanionTestBackend()
		let store = SharedKeychainStore(service: "companion-\(UUID().uuidString)", backend: backend)
		backend.store(vault, values)
		for name in ownMetadataNames(30_000) { backend.store(name, Data()) }
		backend.failWrites(to: [try markerName()])
		#expect(throws: KeychainStoreError.self) { try store.applyVaultTransaction([.write(account: try markerName(), data: marker(overridesV1))]) }
		backend.failWrites(to: [])

		try store.recoverVaultTransaction()

		#expect(backend.data(try markerName()) == marker(overridesV1))
	}

	@Test("a snapshot of no projects takes no listing")
	func emptySnapshotTakesNoListing() throws {
		let backend = CompanionTestBackend()
		let service = KeychainService(testingService: "companion-\(UUID().uuidString)", backend: backend)

		_ = try service.projectStatesResult(vaultIds: []).get()

		#expect(backend.listings == 0)
	}

	@Test("one lock scope lists the service once and reads each marker once, through resumes and maintenance")
	func oneListingAndOneMarkerReadAScope() throws {
		let backend = CompanionTestBackend()
		let counters = VaultKeychainPerformanceCounters()
		let service = KeychainService(testingService: "companion-\(UUID().uuidString)", backend: backend, performanceCounters: counters)
		guard case .success = service.createEnvironments(
			vaultId: vault, projectName: "Project", projectPath: "", environments: ["default": ["TOKEN": "team"]])
		else { Issue.record("couldn't create the project"); return }
		backend.store(try markerName(), marker(overridesV1))
		backend.store(try recordName("overrides"), overridesRecord)
		var resumable: [String] = []
		for index in 0..<8 {
			let id = "resumable-\(index)"
			backend.store(id, values)
			backend.store(try markerName(id), marker("", state: "deleting").replacing(Data("proj".utf8), with: Data(id.utf8)))
			backend.store(try recordName("future-kind", vaultId: id), Data("x".utf8))
			resumable.append(id)
		}
		backend.resetCounts()
		let readsBefore = counters.snapshot.markerReadCount

		_ = try service.withKeychainTransaction {
			_ = try? service.projectStatesResult(vaultIds: [vault] + resumable).get()
			_ = service.getProjectResult(vaultId: vault)
			_ = service.maintainCompanionStorage()
		}.get()

		#expect(backend.listings == 1)
		#expect(counters.snapshot.markerReadCount - readsBefore == 1 + resumable.count, "each marker once, its absence after a resume known from the scope's own change")
	}

	@Test("the engine is asked about each account once a lock scope, however many transactions use it")
	func accountsAreDescribedOnce() throws {
		let counters = VaultKeychainPerformanceCounters()
		let backend = CompanionTestBackend()
		let service = KeychainService(testingService: "companion-\(UUID().uuidString)", backend: backend, performanceCounters: counters)
		guard case .success = service.createEnvironments(vaultId: vault, projectName: "Project", projectPath: "", environments: ["default": [:]])
		else { Issue.record("couldn't create the project"); return }
		let history = #""history":{"version":1,"ifUnsupported":"ignore","kinds":["history-head","history","key"],"state":"active"}"#
		backend.store(try markerName(), marker(history))
		backend.store(try recordName("key"), Data(repeating: 1, count: 32))
		for part in 0..<32 { backend.store(try recordName("history", part: part), Data("x".utf8)) }
		for (index, name) in ownMetadataNames(64).enumerated() where index.isMultiple(of: 2) { backend.store(name, Data()) }
		let companionNames = backend.names.filter { $0.hasPrefix("__vault_companion") || $0.hasPrefix("__vault_features") }.count
		let before = counters.snapshot.companionDescriptionCount

		guard case .success = service.applyVaultTransaction(project: .delete(vaultId: vault, deletePayload: true), data: [])
		else { Issue.record("the project was kept"); return }

		#expect(!backend.names.contains { $0.hasPrefix("__vault_companion") || $0.hasPrefix("__vault_features") })
		#expect(counters.snapshot.companionDescriptionCount - before == companionNames, "each companion name once, the store's own records never")
	}
}

/// How many exports ran.
private final class ExportCount: @unchecked Sendable {
	private let lock = NSLock()
	private var value = 0

	var count: Int { lock.withLock { value } }
	func add() { lock.withLock { value += 1 } }
}

/// Any JSON value, decoded to Foundation types for re-encoding.
private struct AnyJSON: Decodable {
	let value: Any

	init(from decoder: Decoder) throws {
		if var array = try? decoder.unkeyedContainer() {
			var values: [Any] = []
			while !array.isAtEnd { values.append(try array.decode(AnyJSON.self).value) }
			value = values
		} else if let object = try? decoder.container(keyedBy: AnyKey.self) {
			value = try Dictionary(uniqueKeysWithValues: object.allKeys.map { ($0.stringValue, try object.decode(AnyJSON.self, forKey: $0).value) })
		} else {
			let single = try decoder.singleValueContainer()
			if single.decodeNil() { value = NSNull() }
			else if let bool = try? single.decode(Bool.self) { value = bool }
			else if let number = try? single.decode(Int.self) { value = number }
			else { value = try single.decode(String.self) }
		}
	}

	private struct AnyKey: CodingKey {
		let stringValue: String
		var intValue: Int? { nil }
		init(stringValue: String) { self.stringValue = stringValue }
		init?(intValue: Int) { nil }
	}
}
