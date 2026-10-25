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
			items[account] = data
		}
	}

	func write(service: String, account: String, data: Data, access: VaultCliAccess) throws {
		try lock.withLock {
			if failingWrites.contains(account) { throw KeychainStoreError.status(operation: "write", code: errSecIO) }
			items[account] = data
			claims[account] = access
			enforced[account] = access
			accessWrites.append((account, access))
		}
	}

	func add(service: String, account: String, data: Data) throws {
		try lock.withLock {
			guard items[account] == nil else { throw KeychainStoreError.status(operation: "add", code: errSecDuplicateItem) }
			items[account] = data
		}
	}

	func delete(service: String, account: String) throws -> Bool {
		lock.withLock {
			let found = items.removeValue(forKey: account) != nil
			if found { deletions.append(account) }
			claims.removeValue(forKey: account)
			enforced.removeValue(forKey: account)
			return found
		}
	}

	func accounts(service: String) throws -> [String: VaultCliAccess] {
		lock.withLock {
			listingCount += 1
			return Dictionary(uniqueKeysWithValues: items.keys.map { ($0, claims[$0] ?? .automatic) })
		}
	}

	func cliAccess(service: String, account: String) throws -> VaultCliAccess {
		lock.withLock { claims[account] ?? .automatic }
	}

	func setCliAccess(service: String, account: String, access: VaultCliAccess) throws -> VaultCliAccess {
		try lock.withLock {
			guard items[account] != nil else { throw KeychainStoreError.status(operation: "change CLI approval", code: errSecItemNotFound) }
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
		let states = try service.projectStatesResult(vaultIds: [vault], strictAccess: true).get()
		let damage = try #require(states.companion[vault]?.damage.first)
		#expect(damage.code == "invalidMarker")
		let repair = try #require(damage.repair)
		#expect(repair.action == .discardProject)

		try service.repairCompanionData(vaultId: vault, repair: repair).get()

		#expect(backend.data(try markerName()) == nil)
		#expect(backend.data(try recordName("future-kind")) == nil)
		#expect(try service.getProjectResult(vaultId: vault).get()?.secrets(for: "default") == ["TOKEN": "team"])
		#expect(try service.projectStatesResult(vaultIds: [vault], strictAccess: true).get().companion.isEmpty)
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

		let states = try service.projectStatesResult(vaultIds: [vault, "plain"], strictAccess: true).get()

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

		let states = try service.projectStatesResult(vaultIds: [vault, "other"], strictAccess: true).get()

		#expect(states.companion[vault]?.needsResume == true)
		#expect(states.companion["other"]?.unsupported?.feature == "overrides")
		#expect(CompanionStatePresentation(try #require(states.companion[vault]))?.tone == .interrupted)

		backend.failWrites(to: [])
		let finished = try service.projectStatesResult(vaultIds: [vault], strictAccess: true).get()
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
			(service.projectStatesResult(vaultIds: [vault], strictAccess: true), service.getProjectResult(vaultId: vault))
		}.get()

		let damage = try #require(try states.get().companion[vault]?.damage.first)
		#expect(damage.code == "unlistedRecord" && damage.kind == "notes")
		#expect(damage.repair?.action == .removeUnlisted)
		#expect(try project.get()?.secrets(for: "default") == ["TOKEN": "team"], "the read in the same scope isn't refused")

		try service.repairCompanionData(vaultId: vault, repair: try #require(damage.repair)).get()
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
		#expect(inventory.withNewerData == [vault])
		#expect(inventory.excluded.map(\.vaultId) == ["newer"])
		#expect(inventory.excluded.first?.listing?.name == "Newer")
		#expect(inventory.excluded.first?.reason.contains("personal overrides v2") == true)
	}

	@Test("the banner says what newer data means, and nothing for a healthy project")
	func presentation() throws {
		let damaged = try CompanionEngine.assess(vaultId: vault, .init(marker: Data(#"{"schemaVersion":1}"#.utf8)))
		let shown = try #require(CompanionStatePresentation(damaged))
		#expect(shown.tone == .damaged)
		#expect(shown.title == "This project’s newer data is damaged")
		#expect(shown.detail == "Its feature marker is invalid. Its values stay hidden, and LPM won’t run it, until it’s repaired.")
		#expect(shown.repair?.action == .discardProject)
		let confirmation = try #require(shown.repairConfirmation(subject: .init(mark: .symbol("folder"), name: "Project")) {})
		#expect(confirmation.title == "Repair this project’s newer data?")
		#expect(confirmation.message.contains("Its values stay as they are."))

		let newer = try CompanionEngine.assess(vaultId: vault, .init(marker: marker(overridesV2)))
		let update = try #require(CompanionStatePresentation(newer))
		#expect(update.tone == .update)
		#expect(update.repair == nil)
		#expect(update.detail.contains("personal overrides v2, which this version of LPM Vault doesn’t support"))

		let missing = try CompanionEngine.assess(vaultId: vault, .init(marker: marker(overridesV1), inventory: []))
		#expect(CompanionStatePresentation(missing)?.repair == .init(action: .removeFeature, feature: "overrides"))
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
		#expect(store.selectedProjectCompanionState == damaged)
		#expect(try await waitUntil { keychain.companionMaintenanceCount == 1 }, "unlocking runs companion maintenance")

		let repair = try #require(damaged.damage.first?.repair)
		#expect(await store.repairCompanionData(repair))

		#expect(biometric.confirmationReasons == ["repair this env project’s newer data"])
		#expect(keychain.companionRepairs.map(\.vaultId) == [vault])
		#expect(store.selectedProjectCompanionState == nil)
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

		#expect(!(await store.repairCompanionData(try #require(damaged.damage.first?.repair))))
		#expect(keychain.companionRepairs.isEmpty)
		#expect(store.selectedProjectCompanionState == damaged)
	}

	@Test("a refused project's load failure says why in the app's words")
	func loadFailureMessage() {
		let failure = VaultLoadFailure(.companion(.unsupported(feature: "history", version: 3, level: .refuse)))
		#expect(failure.message == "This env project uses local history v3, which this version of LPM Vault doesn’t support. Update LPM Vault to open it.")
	}
}
