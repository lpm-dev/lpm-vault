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
	private let historyAccount = "history.\(publishTestVault)"

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

	@Test("removing a destination removes this Mac's history of it; removing the last removes the records")
	func remove() async throws {
		let store = store
		let production = vercelDestination()
		let preview = vercelDestination(source: "staging", environment: .preview)
		_ = try await store.save(production, to: publishTestVault).get()
		_ = try await store.save(preview, to: publishTestVault).get()
		for destination in [production, preview] {
			_ = try await store.recordPublish([published("API_TOKEN", to: destination)], to: destination, of: publishTestVault, at: Date()).get()
		}
		#expect(try await store.remove(production.id, from: publishTestVault).get() == [preview])
		#expect(try await store.history(of: publishTestVault).get().entries.keys.sorted { $0.uuidString < $1.uuidString } == [preview.id])
		#expect(try await store.remove(preview.id, from: publishTestVault).get().isEmpty)
		#expect(keychain.publishingStorage[destinationsAccount] == nil)
		#expect(keychain.publishingStorage[historyAccount] == nil)
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

	@Test("a damaged record is reported and not overwritten")
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

	@Test("the fingerprint key is made once and kept; a damaged one is replaced")
	func fingerprintKey() async throws {
		let store = store
		let first = try await store.fingerprintKey().get()
		let again = try await store.fingerprintKey().get()
		#expect(first == again)
		#expect(keychain.publishingStorage["fingerprint-key"]?.count == 32)
		keychain.publishingStorage["fingerprint-key"] = Data(count: 7)
		let replaced = try await store.fingerprintKey().get()
		#expect(replaced != first)
		#expect(try await store.fingerprintKey().get() == replaced)
	}

	@Test("recording a publish saves the history and the destination, and prunes history of removed destinations")
	func recordPublish() async throws {
		let store = store
		var production = vercelDestination()
		_ = try await store.save(production, to: publishTestVault).get()
		let removed = vercelDestination(source: "staging", environment: .preview)
		_ = try await store.save(removed, to: publishTestVault).get()
		_ = try await store.recordPublish([published("A", to: removed)], to: removed, of: publishTestVault, at: Date()).get()
		_ = try await store.remove(removed.id, from: publishTestVault).get()
		keychain.publishingStorage[historyAccount] = PublishingRecords.encode(
			PublishHistory().recording([published("A", to: removed)], to: removed.id, at: Date()), vaultID: publishTestVault)

		production.excludedKeys = ["LOG_LEVEL"]
		production.updatedAt = Date(timeIntervalSince1970: 1_760_000_500)
		let at = Date(timeIntervalSince1970: 1_760_000_600)
		_ = try await store.recordPublish([published("API_TOKEN", to: production)], to: production, of: publishTestVault, at: at).get()
		#expect(try await store.destinations(of: publishTestVault).get() == [production])
		let history = try await store.history(of: publishTestVault).get()
		#expect(Array(history.entries.keys) == [production.id])
		#expect(history.entries[production.id]?.publishedAt == at)
		#expect(history.entries[production.id]?.keys.keys.sorted() == ["API_TOKEN"])
	}

	@Test("a publish to a destination that can't be saved still records its history, and keeps the rest")
	func recordWithoutDestination() async throws {
		let store = store
		let production = vercelDestination()
		let other = UUID()
		keychain.publishingStorage[historyAccount] = PublishingRecords.encode(
			PublishHistory().recording([published("A", to: production)], to: other, at: Date()), vaultID: publishTestVault)
		let newer = Data(#"{"version":2,"vault":"\#(publishTestVault)","destinations":[]}"#.utf8)
		keychain.publishingStorage[destinationsAccount] = newer
		let recorded = await store.recordPublish([published("B", to: production)], to: production, of: publishTestVault, at: Date())
		#expect(throws: PublishingStoreError.newerVersion) { try recorded.get() }
		#expect(Set(try await store.history(of: publishTestVault).get().entries.keys) == [other, production.id])
		#expect(keychain.publishingStorage[destinationsAccount] == newer)
	}

	@Test("renaming an environment moves its destinations; renaming a key carries its exclusion")
	func renames() async throws {
		let store = store
		let staging = vercelDestination(source: "staging", environment: .preview, excluded: ["OLD"])
		let production = vercelDestination(excluded: ["NEW"])
		_ = try await store.save(staging, to: publishTestVault).get()
		_ = try await store.save(production, to: publishTestVault).get()
		_ = try await store.renameEnvironment("staging", to: "qa", in: publishTestVault).get()
		_ = try await store.renameKey("OLD", to: "NEW", in: publishTestVault).get()
		let destinations = try await store.destinations(of: publishTestVault).get()
		let movedStaging = try #require(destinations.first { $0.id == staging.id })
		let movedProduction = try #require(destinations.first { $0.id == production.id })
		#expect(movedStaging.sourceEnvironment == "qa" && movedStaging.excludedKeys == ["NEW"])
		#expect(movedStaging.updatedAt >= staging.updatedAt)
		// The renamed key wasn't left out of Production, so a stale exclusion of its new name goes.
		#expect(movedProduction.sourceEnvironment == "production" && movedProduction.excludedKeys.isEmpty)
	}

	@Test("deleting a vault's records removes its destinations and history, and keeps the fingerprint key")
	func deleteRecords() async throws {
		let store = store
		let production = vercelDestination()
		_ = try await store.save(production, to: publishTestVault).get()
		_ = try await store.recordPublish([published("A", to: production)], to: production, of: publishTestVault, at: Date()).get()
		_ = try await store.fingerprintKey().get()
		_ = try await store.deleteRecords(of: publishTestVault).get()
		#expect(Array(keychain.publishingStorage.keys) == ["fingerprint-key"])
	}

	@Test("publishing items live in the app's own access group, on this Mac only")
	func appOnlyItems() {
		let query = AppKeychainBackend.query(service: VaultConstants.publishingKeychainService, account: "fingerprint-key")
		#expect(query[kSecAttrAccessGroup as String] as? String == "823S8YKMRW.dev.lpm.vault")
		#expect(query[kSecAttrAccessGroup as String] as? String != VaultConstants.keychainAccessGroup)
		#expect(query[kSecAttrSynchronizable as String] as? Bool == false)
		#expect(query[kSecUseDataProtectionKeychain as String] as? Bool == true)
	}

	private func published(_ key: String, to destination: PublishDestination) -> PublishHistory.Published {
		.init(
			key: key,
			fingerprint: PublishFingerprint.of(value: "value", key: key, destination: destination.id, using: SymmetricKey(size: .bits256)),
			remoteID: "env_\(key)",
			remoteUpdatedAt: nil
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
		let destination = vercelDestination(excluded: ["STRIPE_KEY"])
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
		_ = try await store.publishing.recordPublish([], to: destination, of: "project", at: Date()).get()
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
