import CryptoKit
import Foundation
import Security
import Testing

@testable import LPMVault

@Suite("Storing publish destinations")
struct PublishingStoreTests {
	private let keychain = MockKeychainService()
	private var store: PublishingStore { PublishingStore(service: keychain) }
	private let destinationsAccount = "destinations.\(publishTestVault)"

	@Test("saving adds a destination, saving it again replaces it, and both read back")
	func saveAndReplace() async throws {
		let store = store
		let production = vercelDestination()
		let preview = vercelDestination(source: "staging", environment: .preview)
		_ = try await store.save(production, to: publishTestVault).get()
		_ = try await store.save(preview, to: publishTestVault).get()
		var edited = production
		edited.excludedKeys = ["LOG_LEVEL"]
		let saved = try await store.save(edited, to: publishTestVault).get()
		#expect(Set(saved) == [edited, preview])
		#expect(Set(try await store.destinations(of: publishTestVault).get()) == [edited, preview])
	}

	@Test("a destination that writes where another of the vault's destinations does isn't saved")
	func sameLocation() async throws {
		let store = store
		let production = vercelDestination()
		_ = try await store.save(production, to: publishTestVault).get()
		let again = vercelDestination(source: "staging")
		#expect(await store.save(again, to: publishTestVault) == .failure(.duplicateLocation(existing: production.id)))
		#expect(try await store.destinations(of: publishTestVault).get() == [production])
	}

	@Test("an invalid destination, or one for an unsafe vault ID, isn't saved")
	func invalid() async {
		let store = store
		#expect(await store.save(vercelDestination(source: "a/b"), to: publishTestVault) == .failure(.invalidDestination(.sourceEnvironment)))
		#expect(await store.save(vercelDestination(), to: "../vault") == .failure(.invalidVault))
		#expect(await store.destinations(of: "") == .failure(.invalidVault))
		#expect(keychain.publishingStorage.isEmpty)
	}

	@Test("a vault holds at most 64 destinations")
	func limit() async throws {
		let store = store
		for index in 0..<PublishingRecords.maximumDestinations {
			_ = try await store.save(vercelDestination(project: "prj_\(index)"), to: publishTestVault).get()
		}
		#expect(await store.save(vercelDestination(project: "prj_more"), to: publishTestVault) == .failure(.limitReached))
	}

	@Test("removing a destination removes this Mac's history of it; removing the last removes the record")
	func remove() async throws {
		let store = store
		let production = vercelDestination()
		let preview = vercelDestination(source: "staging", environment: .preview)
		_ = try await store.save(production, to: publishTestVault).get()
		_ = try await store.save(preview, to: publishTestVault).get()
		for destination in [production, preview] {
			_ = try await record(["API_TOKEN"], to: destination, in: store).get()
		}
		#expect(try await store.remove(production.id, from: publishTestVault).get().map(\.id) == [preview.id])
		#expect(try await store.history(of: production.id, in: publishTestVault).get() == PublishHistory())
		#expect(try await store.history(of: preview.id, in: publishTestVault).get().keys.keys.sorted() == ["API_TOKEN"])
		#expect(try await store.remove(preview.id, from: publishTestVault).get().isEmpty)
		#expect(keychain.publishingStorage.isEmpty)
	}

	@Test("a record written by a newer LPM Vault is reported and left exactly as it was")
	func newerRecord() async throws {
		let store = store
		let newer = Data(#"{"version":2,"vault":"\#(publishTestVault)","destinations":[]}"#.utf8)
		keychain.publishingStorage[destinationsAccount] = newer
		#expect(await store.destinations(of: publishTestVault) == .failure(.newerVersion))
		#expect(await store.save(vercelDestination(), to: publishTestVault) == .failure(.newerVersion))
		let rename = await store.renameEnvironment("production", to: "live", in: publishTestVault)
		#expect(throws: PublishingStoreError.newerVersion) { try rename.get() }
		#expect(keychain.publishingStorage[destinationsAccount] == newer)
	}

	@Test("a newer history isn't overwritten; a damaged one is replaced, since it only records past publishes")
	func historyRecords() async throws {
		let store = store
		let production = vercelDestination()
		_ = try await store.save(production, to: publishTestVault).get()
		let account = "history.\(publishTestVault).\(production.id.uuidString.lowercased())"
		let newer = Data(#"{"version":2}"#.utf8)
		keychain.publishingStorage[account] = newer
		#expect(await record(["A"], to: production, in: store) == .failure(.newerVersion))
		#expect(keychain.publishingStorage[account] == newer)
		keychain.publishingStorage[account] = Data("{".utf8)
		#expect(try await store.history(of: production.id, in: publishTestVault).get() == PublishHistory())
		_ = try await record(["A"], to: production, in: store).get()
		#expect(try await store.history(of: production.id, in: publishTestVault).get().keys.keys.sorted() == ["A"])
	}

	@Test("a damaged destinations record is reported and not overwritten")
	func damagedRecord() async throws {
		let store = store
		let damaged = Data("{".utf8)
		keychain.publishingStorage[destinationsAccount] = damaged
		#expect(await store.save(vercelDestination(), to: publishTestVault) == .failure(.unreadable))
		#expect(keychain.publishingStorage[destinationsAccount] == damaged)
	}

	@Test("a Keychain failure is reported")
	func keychainFailure() async {
		keychain.failPublishingAccounts = [destinationsAccount]
		#expect(await store.destinations(of: publishTestVault) == .failure(.keychain(.accessDenied)))
	}

	@Test("the fingerprint key is made once and kept; a damaged one is replaced; a failed read doesn't replace it")
	func fingerprintKey() async throws {
		let store = store
		let first = try await store.fingerprintKey().get()
		let again = try await store.fingerprintKey().get()
		#expect(first == again)
		#expect(keychain.publishingStorage["fingerprint-key.v1"]?.count == 32)
		keychain.failPublishingAccounts = ["fingerprint-key.v1"]
		#expect(await store.fingerprintKey() == .failure(.keychain(.accessDenied)))
		keychain.failPublishingAccounts = []
		#expect(try await store.fingerprintKey().get() == first)
		keychain.publishingStorage["fingerprint-key.v1"] = Data(count: 7)
		let replaced = try await store.fingerprintKey().get()
		#expect(replaced != first)
		#expect(try await store.fingerprintKey().get() == replaced)
	}

	@Test("recording a publish saves the person's choices on the stored destination and the history")
	func recordPublish() async throws {
		let store = store
		let production = vercelDestination(excluded: ["GONE"])
		_ = try await store.save(production, to: publishTestVault).get()
		let at = Date(timeIntervalSince1970: 1_760_000_600)
		let choices = PublishPlan.Choices(
			leftOut: ["LOG_LEVEL"], chosen: ["API_TOKEN"], sourceKeys: ["API_TOKEN", "LOG_LEVEL"], forgotten: ["GONE"])
		let updated = try await store.recordPublish(
			[published("API_TOKEN", to: production)], to: production.id, at: production.target.location,
			choices: choices, of: publishTestVault, at: at).get()
		#expect(updated.excludedKeys == ["LOG_LEVEL"] && updated.updatedAt == at)
		#expect(try await store.destinations(of: publishTestVault).get() == [updated])
		let history = try await store.history(of: production.id, in: publishTestVault).get()
		#expect(history.publishedAt == at && history.keys.keys.sorted() == ["API_TOKEN"])
	}

	@Test("renaming an environment moves its destinations; renaming a key carries its exclusion where the key was")
	func renames() async throws {
		let store = store
		let staging = vercelDestination(source: "staging", environment: .preview, excluded: ["OLD"])
		let production = vercelDestination(excluded: ["NEW"])
		_ = try await store.save(staging, to: publishTestVault).get()
		_ = try await store.save(production, to: publishTestVault).get()
		_ = try await store.renameEnvironment("staging", to: "qa", in: publishTestVault).get()
		_ = try await store.renameKey("OLD", to: "NEW", sourcedFrom: ["qa", "production"], in: publishTestVault).get()
		let destinations = try await store.destinations(of: publishTestVault).get()
		let movedStaging = try #require(destinations.first { $0.id == staging.id })
		let movedProduction = try #require(destinations.first { $0.id == production.id })
		#expect(movedStaging.sourceEnvironment == "qa" && movedStaging.excludedKeys == ["NEW"])
		#expect(movedStaging.updatedAt >= staging.updatedAt)
		// The renamed key wasn't left out of Production, so a stale exclusion of its new name goes.
		#expect(movedProduction.sourceEnvironment == "production" && movedProduction.excludedKeys.isEmpty)
	}

	@Test("deleting a vault's records removes its destinations and histories, even unreadable ones, and nothing else")
	func deleteRecords() async throws {
		let store = store
		let production = vercelDestination()
		_ = try await store.save(production, to: publishTestVault).get()
		_ = try await record(["A"], to: production, in: store).get()
		_ = try await store.fingerprintKey().get()
		let otherVault = "\(publishTestVault).other"
		_ = try await store.save(vercelDestination(), to: otherVault).get()
		keychain.publishingStorage["history.\(publishTestVault).\(UUID().uuidString.lowercased())"] = Data("{".utf8)
		keychain.publishingStorage[destinationsAccount] = Data(#"{"version":9}"#.utf8)
		_ = try await store.deleteRecords(of: publishTestVault).get()
		#expect(Set(keychain.publishingStorage.keys) == ["fingerprint-key.v1", "destinations.\(otherVault)"])
	}

	@Test("publishing items live in the app's own access group, on this Mac only")
	func appOnlyItems() {
		let query = AppKeychainBackend(service: VaultConstants.publishingKeychainService).query(account: "fingerprint-key.v1")
		#expect(query[kSecAttrAccessGroup as String] as? String == "823S8YKMRW.dev.lpm.vault")
		#expect(query[kSecAttrAccessGroup as String] as? String != VaultConstants.keychainAccessGroup)
		#expect(query[kSecAttrService as String] as? String == "dev.lpm.vault.publishing")
		#expect(query[kSecAttrSynchronizable as String] as? Bool == false)
		#expect(query[kSecUseDataProtectionKeychain as String] as? Bool == true)
	}

	@Test("a Keychain service built for tests has no publishing storage unless one is given")
	func testingService() {
		let service = KeychainService(testingService: "dev.lpm.vault.tests.\(UUID().uuidString)")
		#expect(service.readPublishingData(account: "fingerprint-key.v1") == .failure(.unexpectedStatus(errSecUnimplemented)))
		#expect(service.publishingAccounts() == .failure(.unexpectedStatus(errSecUnimplemented)))
	}

	private func record(_ keys: [String], to destination: PublishDestination, in store: PublishingStore) async -> Result<PublishDestination, PublishingStoreError> {
		await store.recordPublish(
			keys.map { published($0, to: destination) }, to: destination.id, at: destination.target.location,
			choices: .init(leftOut: [], chosen: Set(keys), sourceKeys: Set(keys)), of: publishTestVault, at: Date())
	}

	private func published(_ key: String, to destination: PublishDestination) -> PublishHistory.Published {
		.init(
			key: key,
			fingerprint: PublishFingerprint.of(value: "value", key: key, destination: destination.id, using: SymmetricKey(size: .bits256)),
			remoteID: "env_\(key)",
			remoteUpdatedAt: nil, publishedAsSecret: true
		)
	}
}

@Suite("Publish destinations follow their vault", .serialized)
@MainActor
struct PublishDestinationFollowTests {
	private let environments: [String: [String: String]] = [
		"default": ["STRIPE_KEY": "sk_dev"],
		"staging": ["STRIPE_KEY": "sk_staging"],
	]

	@Test("renaming an environment points its destinations at the new name")
	func environmentRename() async throws {
		let (store, _) = makeStore()
		defer { store.lock() }
		let destination = vercelDestination(source: "staging", environment: .preview)
		_ = try await store.publishing.save(destination, to: "project").get()
		store.renameEnvironment(in: "project", from: "staging", to: "qa")
		try await waitForSource("qa", of: destination.id, in: store)
	}

	@Test("an environment rename saved as the vault locks still moves its destinations")
	func renameDuringLock() async throws {
		let (store, keychain) = makeStore()
		let destination = vercelDestination(source: "staging", environment: .preview)
		_ = try await store.publishing.save(destination, to: "project").get()
		store.renameEnvironment(in: "project", from: "staging", to: "qa")
		store.lock()
		try await waitForSource("qa", of: destination.id, in: store)
		#expect(keychain.envStorage["project"]?.environments["qa"] == ["STRIPE_KEY": "sk_staging"])
	}

	@Test("renaming a key in the inspector carries its exclusion to the new name")
	func keyRename() async throws {
		let (store, _) = makeStore()
		defer { store.lock() }
		let destination = vercelDestination(source: "staging", environment: .preview, excluded: ["STRIPE_KEY"])
		_ = try await store.publishing.save(destination, to: "project").get()
		try await store.saveKeyEdit(VaultKeyEdit(key: "STRIPE_KEY", environments: environments, newKey: "STRIPE_SECRET_KEY"), in: "project")
		#expect(try await store.publishing.destinations(of: "project").get().first?.excludedKeys == ["STRIPE_SECRET_KEY"])
	}

	@Test("renaming a key that has a rule in lpm.json carries its exclusion to the new name")
	func schemaKeyRename() async throws {
		let folder = FileManager.default.temporaryDirectory.appending(path: "publish-follow-\(UUID().uuidString)").path
		try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(atPath: folder) }
		try #"{"envSchema": {"vars": {"STRIPE_KEY": {"required": true}}}}"#.write(toFile: folder + "/lpm.json", atomically: true, encoding: .utf8)
		let (store, keychain) = makeStore(path: folder)
		defer { store.lock() }
		store.reloadKeyDescriptions()
		for _ in 0..<1000 where store.keyDescriptions["project"] == nil { try await Task.sleep(for: .milliseconds(5)) }
		let destination = vercelDestination(source: "default", excluded: ["STRIPE_KEY"])
		_ = try await store.publishing.save(destination, to: "project").get()
		let project = try #require(store.selectedProject)
		store.keyDrafts.edit(project, key: "STRIPE_KEY") { $0.name = "STRIPE_SECRET_KEY" }
		try await store.saveKeyDraft(VaultKeyDraft.ID(projectID: "project", key: "STRIPE_KEY"))
		#expect(keychain.envStorage["project"]?.environments["default"] == ["STRIPE_SECRET_KEY": "sk_dev"])
		#expect(try ProjectEnvSchemaFile.rules(inFolder: folder, vaultID: "project").keys.contains("STRIPE_SECRET_KEY"))
		#expect(try await store.publishing.destinations(of: "project").get().first?.excludedKeys == ["STRIPE_SECRET_KEY"])
	}

	@Test("deleting a vault's local copy deletes its destinations and history")
	func localDeletion() async throws {
		let (store, keychain) = makeStore()
		defer { store.lock() }
		let destination = vercelDestination()
		_ = try await store.publishing.save(destination, to: "project").get()
		_ = try await store.publishing.recordPublish(
			[], to: destination.id, at: destination.target.location, choices: .init(leftOut: [], chosen: [], sourceKeys: []),
			of: "project", at: Date()).get()
		let project = try #require(store.selectedProject)
		#expect(await store.deleteLocalVault(project))
		#expect(keychain.publishingStorage.isEmpty)
	}

	@Test("removing a project from the sidebar keeps its destinations")
	func sidebarRemoval() async throws {
		let (store, keychain) = makeStore()
		defer { store.lock() }
		_ = try await store.publishing.save(vercelDestination(), to: "project").get()
		let project = try #require(store.selectedProject)
		store.removeFromSidebar(project)
		for _ in 0..<1000 where store.projects.contains(where: { $0.id == "project" }) { try await Task.sleep(for: .milliseconds(5)) }
		#expect(keychain.publishingStorage["destinations.project"] != nil)
	}

	private func makeStore(path: String = "") -> (VaultStore, MockKeychainService) {
		let keychain = MockKeychainService()
		keychain.envStorage["project"] = (name: "Project", path: path, environments: environments)
		let store = VaultStore(keychainService: keychain, biometricService: MockBiometricService(), apiService: MockAPIService())
		store.projects = [VaultProject(id: "project", name: "Project", path: path, environments: environments)]
		store.isUnlocked = true
		store.selectedProjectId = "project"
		return (store, keychain)
	}

	private func waitForSource(_ source: String, of id: UUID, in store: VaultStore) async throws {
		for _ in 0..<1000 {
			if try await store.publishing.destinations(of: "project").get().first(where: { $0.id == id })?.sourceEnvironment == source {
				return
			}
			try await Task.sleep(for: .milliseconds(5))
		}
		Issue.record("The destination didn't follow the rename")
	}
}

@Suite("Publishing records under review", .serialized)
@MainActor
struct PublishingRecordFindingTests {
	private let keychain = MockKeychainService()
	private var store: PublishingStore { PublishingStore(service: keychain) }

	@Test("renaming a key leaves the exclusions of destinations whose source never had it")
	func renameOnlyWhereTheKeyWas() async throws {
		let vault = makeVault(["production": ["OLD": "a"], "staging": ["NEW": "b"]])
		defer { vault.lock() }
		let staging = vercelDestination(source: "staging", environment: .preview, excluded: ["NEW"])
		_ = try await vault.publishing.save(staging, to: "project").get()
		let environments = try #require(vault.selectedProject?.environments)
		try await vault.saveKeyEdit(VaultKeyEdit(key: "OLD", environments: environments, newKey: "NEW"), in: "project")
		#expect(try await vault.publishing.destinations(of: "project").get().first?.excludedKeys == ["NEW"])
	}

	@Test("histories of many destinations stay readable, each in its own record")
	func historyStaysReadable() async throws {
		let store = store
		var destinations: [PublishDestination] = []
		for index in 0..<PublishingRecords.maximumDestinations {
			let destination = vercelDestination(project: "prj_\(index)")
			_ = try await store.save(destination, to: publishTestVault).get()
			_ = try await record(["A"], to: destination, in: store).get()
			destinations.append(destination)
		}
		let extra = vercelDestination(project: "prj_extra")
		#expect(await record(["A"], to: extra, in: store) == .failure(.destinationRemoved))
		for destination in destinations {
			#expect(try await store.history(of: destination.id, in: publishTestVault).get().keys.keys.sorted() == ["A"])
		}
	}

	@Test("a history too large for one record still keeps the newest publish")
	func historyBudget() async throws {
		let store = store
		var destinations: [PublishDestination] = []
		for index in 0..<10 {
			let destination = vercelDestination(project: "prj_\(index)")
			_ = try await store.save(destination, to: publishTestVault).get()
			destinations.append(destination)
		}
		let keys = (0..<600).map { String(format: "KEY_NUMBER_%08d", $0) }
		for destination in destinations {
			_ = try await record(keys, to: destination, in: store).get()
		}
		for destination in destinations {
			#expect(try await store.history(of: destination.id, in: publishTestVault).get().keys.count == keys.count)
		}
	}

	@Test("recording a publish keeps a rename that happened during the publish")
	func recordKeepsRename() async throws {
		let store = store
		let staging = vercelDestination(source: "staging", environment: .preview)
		_ = try await store.save(staging, to: publishTestVault).get()
		_ = try await store.renameEnvironment("staging", to: "qa", in: publishTestVault).get()
		_ = try await record(["A"], to: staging, in: store).get()
		#expect(try await store.destinations(of: publishTestVault).get().first?.sourceEnvironment == "qa")
	}

	@Test("recording a publish doesn't bring back a destination removed during the publish")
	func recordDoesntRecreate() async throws {
		let store = store
		let production = vercelDestination()
		_ = try await store.save(production, to: publishTestVault).get()
		_ = try await store.remove(production.id, from: publishTestVault).get()
		#expect(await record(["A"], to: production, in: store) == .failure(.destinationRemoved))
		#expect(try await store.destinations(of: publishTestVault).get().isEmpty)
		#expect(keychain.publishingStorage.isEmpty)
	}

	@Test("moving a destination to another place drops its history, and a publish planned for the old place isn't recorded")
	func retargetDropsHistory() async throws {
		let store = store
		let original = vercelDestination()
		var destination = original
		_ = try await store.save(destination, to: publishTestVault).get()
		_ = try await record(["A"], to: destination, in: store).get()
		destination.target = vercelDestination(project: "prj_other", environment: .preview).target
		_ = try await store.save(destination, to: publishTestVault).get()
		#expect(try await store.history(of: destination.id, in: publishTestVault).get() == PublishHistory())
		#expect(await record(["A"], to: original, in: store) == .failure(.destinationMoved))
	}

	@Test("an environment rename whose commit outcome was lost still moves its destinations")
	func renameAfterLostOutcome() async throws {
		let vault = makeVault(["default": ["A": "1"], "staging": ["A": "2"]])
		defer { vault.lock() }
		let destination = vercelDestination(source: "staging", environment: .preview)
		_ = try await vault.publishing.save(destination, to: "project").get()
		keychain.nextVaultTransactionErrorAfterCommit = .transactionOutcomeIndeterminate
		vault.renameEnvironment(in: "project", from: "staging", to: "qa")
		await vault.refreshLocalState()
		#expect(keychain.envStorage["project"]?.environments["qa"] != nil)
		#expect(try await vault.publishing.destinations(of: "project").get().first?.sourceEnvironment == "qa")
	}

	@Test("an environment rename that wasn't saved leaves its destinations")
	func failedRename() async throws {
		let vault = makeVault(["default": ["A": "1"], "staging": ["A": "2"]])
		defer { vault.lock() }
		let destination = vercelDestination(source: "staging", environment: .preview)
		_ = try await vault.publishing.save(destination, to: "project").get()
		keychain.nextVaultTransactionError = .transactionOutcomeIndeterminate
		vault.renameEnvironment(in: "project", from: "staging", to: "qa")
		await vault.refreshLocalState()
		#expect(keychain.envStorage["project"]?.environments["qa"] == nil)
		#expect(try await vault.publishing.destinations(of: "project").get().first?.sourceEnvironment == "staging")
	}

	@Test("a rename whose destinations can't follow says so")
	func followFailureSurfaces() async throws {
		let vault = makeVault(["default": ["A": "1"], "staging": ["A": "2"]])
		defer { vault.lock() }
		_ = try await vault.publishing.save(vercelDestination(source: "staging", environment: .preview), to: "project").get()
		keychain.failPublishingAccounts = ["destinations.project"]
		vault.renameEnvironment(in: "project", from: "staging", to: "qa")
		await vault.refreshLocalState()
		#expect(keychain.envStorage["project"]?.environments["qa"] != nil)
		#expect(vault.error?.contains("publish destinations couldn't be updated") == true)
	}

	@Test("deleting an environment removes the destinations it published from, with their history")
	func environmentDeletion() async throws {
		let vault = makeVault(["default": ["A": "1"], "staging": ["A": "2"]])
		defer { vault.lock() }
		let staging = vercelDestination(source: "staging", environment: .preview)
		let production = vercelDestination(source: "default")
		_ = try await vault.publishing.save(staging, to: "project").get()
		_ = try await vault.publishing.save(production, to: "project").get()
		_ = try await vault.publishing.recordPublish(
			[], to: staging.id, at: staging.target.location, choices: .init(leftOut: [], chosen: [], sourceKeys: []),
			of: "project", at: Date()).get()
		vault.deleteEnvironment(from: "project", name: "staging")
		await vault.refreshLocalState()
		#expect(keychain.envStorage["project"]?.environments["staging"] == nil)
		#expect(try await vault.publishing.destinations(of: "project").get().map(\.id) == [production.id])
		#expect(keychain.publishingStorage["history.project.\(staging.id.uuidString.lowercased())"] == nil)
	}

	@Test("an exclusion a rename carried to a new name survives recording a publish planned before the rename")
	func exclusionSurvivesConcurrentRename() async throws {
		let store = store
		let secret = SymmetricKey(size: .bits256)
		let destination = vercelDestination(source: "staging", environment: .preview, excluded: ["OLD"])
		_ = try await store.save(destination, to: publishTestVault).get()
		let plan = PublishPlan(
			destination: destination, values: ["OLD": "1", "KEEP": "2"], rules: .empty, check: nil, remote: [:],
			reservedKeys: [], history: nil, fingerprintKey: secret)
		let selection = PublishPlan.Selection(defaultsOf: plan)
		_ = try await store.renameKey("OLD", to: "NEW", sourcedFrom: ["staging"], in: publishTestVault).get()
		let changes = try plan.changes(for: selection, values: ["OLD": "1", "KEEP": "2"], fingerprintKey: secret).get()
		_ = try await store.recordPublish(
			changes.map { $0.published(remoteID: "env_\($0.key)", remoteUpdatedAt: nil) }, to: destination.id,
			at: plan.location, choices: plan.choices(for: selection), of: publishTestVault, at: Date()).get()
		#expect(try await store.destinations(of: publishTestVault).get().first?.excludedKeys == ["NEW"])
	}

	@Test("retargeting whose history can't be removed isn't saved, so a retry still clears the old history")
	func retargetHistoryFailure() async throws {
		let store = store
		var destination = vercelDestination()
		_ = try await store.save(destination, to: publishTestVault).get()
		_ = try await record(["A"], to: destination, in: store).get()
		let historyAccount = "history.\(publishTestVault).\(destination.id.uuidString.lowercased())"
		destination.target = vercelDestination(project: "prj_other", environment: .preview).target
		keychain.failPublishingAccounts = [historyAccount]
		_ = await store.save(destination, to: publishTestVault)
		keychain.failPublishingAccounts = []
		_ = try await store.save(destination, to: publishTestVault).get()
		#expect(try await store.history(of: destination.id, in: publishTestVault).get() == PublishHistory())
	}

	@Test("a local deletion whose outcome was lost removes the vault's publishing records once it's seen deleted")
	func deletionAfterLostOutcome() async throws {
		let vault = makeVault(["default": ["A": "1"]])
		defer { vault.lock() }
		let destination = vercelDestination(source: "default")
		_ = try await vault.publishing.save(destination, to: "project").get()
		keychain.nextVaultTransactionErrorAfterCommit = .transactionOutcomeIndeterminate
		let project = try #require(vault.selectedProject)
		_ = await vault.deleteLocalVault(project)
		#expect(keychain.envStorage["project"] == nil)
		#expect(keychain.publishingStorage.isEmpty)
	}

	@Test("unlocking clears publishing records of vaults deleted from this Mac, and keeps those only removed from the sidebar")
	func reconcileOnUnlock() async throws {
		let vault = makeVault(["default": ["A": "1"]])
		defer { vault.lock() }
		_ = try await vault.publishing.save(vercelDestination(source: "default"), to: "project").get()
		_ = try await vault.publishing.save(vercelDestination(source: "default"), to: "deleted-vault").get()
		keychain.envStorage["sidebar-vault"] = (name: "Hidden", path: "", environments: ["default": [:]])
		_ = try await vault.publishing.save(vercelDestination(source: "default"), to: "sidebar-vault").get()
		await vault.reconcilePublishingRecords()
		#expect(Set(keychain.publishingStorage.keys) == ["destinations.project", "destinations.sidebar-vault"])
	}

	private func makeVault(_ environments: [String: [String: String]]) -> VaultStore {
		keychain.envStorage["project"] = (name: "Project", path: "", environments: environments)
		let vault = VaultStore(keychainService: keychain, biometricService: MockBiometricService(), apiService: MockAPIService())
		vault.projects = [VaultProject(id: "project", name: "Project", path: "", environments: environments)]
		vault.isUnlocked = true
		vault.selectedProjectId = "project"
		return vault
	}

	private func record(_ keys: [String], to destination: PublishDestination, in store: PublishingStore) async -> Result<PublishDestination, PublishingStoreError> {
		await store.recordPublish(
			keys.map { key in
				.init(key: key, fingerprint: PublishFingerprint.of(value: "v", key: key, destination: destination.id, using: SymmetricKey(size: .bits256)),
					remoteID: "env_\(key)", remoteUpdatedAt: nil, publishedAsSecret: true)
			},
			to: destination.id, at: destination.target.location,
			choices: .init(leftOut: [], chosen: Set(keys), sourceKeys: Set(keys)), of: publishTestVault, at: Date())
	}
}
