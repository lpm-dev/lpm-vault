import Darwin
import Foundation
import os
import Testing

@testable import LPMVault

@Suite("Key edits")
struct VaultKeyEditTests {
	private let environments: [String: [String: String]] = [
		"default": ["STRIPE_KEY": "sk_dev", "OTHER": "other"],
		"staging": ["STRIPE_KEY": "sk_staging"],
		"production": ["DATABASE_URL": "postgres://prod"],
	]

	@Test("a rename moves the key in every environment that has it")
	func renameMovesKeyEverywhere() throws {
		let edit = VaultKeyEdit(key: "STRIPE_KEY", environments: environments, newKey: "STRIPE_SECRET_KEY")
		let result = try edit.applied(to: environments).get()
		#expect(result["default"] == ["STRIPE_SECRET_KEY": "sk_dev", "OTHER": "other"])
		#expect(result["staging"] == ["STRIPE_SECRET_KEY": "sk_staging"])
		#expect(result["production"] == environments["production"])
		#expect(VaultKeyEdit.environments(containing: "STRIPE_KEY", in: environments) == ["default", "staging"])
	}

	@Test("renaming a key that exists in one environment aligns it with the others")
	func renameFixesDrift() throws {
		let drifted: [String: [String: String]] = [
			"default": ["STRIPE_SECRET_KEY": "sk_dev"],
			"staging": ["STRIPE_SECRET": "sk_staging"],
		]
		let edit = VaultKeyEdit(key: "STRIPE_SECRET", environments: drifted, newKey: "STRIPE_SECRET_KEY")
		let result = try edit.applied(to: drifted).get()
		#expect(result == ["default": ["STRIPE_SECRET_KEY": "sk_dev"], "staging": ["STRIPE_SECRET_KEY": "sk_staging"]])
	}

	@Test("values update existing entries and add the key where it was missing")
	func valuesUpdateAndAdd() throws {
		let edit = VaultKeyEdit(
			key: "STRIPE_KEY", environments: environments, newKey: "STRIPE_SECRET_KEY",
			values: ["default": "sk_dev_2", "production": "sk_live"])
		let result = try edit.applied(to: environments).get()
		#expect(result["default"] == ["STRIPE_SECRET_KEY": "sk_dev_2", "OTHER": "other"])
		#expect(result["staging"] == ["STRIPE_SECRET_KEY": "sk_staging"])
		#expect(result["production"] == ["DATABASE_URL": "postgres://prod", "STRIPE_SECRET_KEY": "sk_live"])
	}

	@Test("a rename or addition never merges two keys", arguments: [
		("OTHER", nil as String?, "default", "OTHER"),
		("other", nil, "default", "OTHER"),
		("DATABASE_URL", "production", "production", "DATABASE_URL"),
		("database_url", "production", "production", "DATABASE_URL"),
	])
	func collisions(newKey: String, addedTo: String?, environment: String, existing: String) {
		let edit = VaultKeyEdit(
			key: "STRIPE_KEY", environments: environments, newKey: newKey,
			values: addedTo.map { [$0: "value"] } ?? [:])
		#expect(edit.applied(to: environments) == .failure(.collision(environment: environment, existingKey: existing)))
	}

	@Test("changing only the letter case of the key is a rename, not a collision")
	func caseOnlyRename() throws {
		let lower: [String: [String: String]] = ["default": ["stripe_key": "sk"]]
		let edit = VaultKeyEdit(key: "stripe_key", environments: lower, newKey: "STRIPE_KEY")
		#expect(try edit.applied(to: lower).get() == ["default": ["STRIPE_KEY": "sk"]])
	}

	@Test("a new name outside the CLI's variable rules is rejected", arguments: ["1STRIPE", "STRIPE-KEY", "", "STRIPE KEY"])
	func invalidNames(newKey: String) {
		let edit = VaultKeyEdit(key: "STRIPE_KEY", environments: environments, newKey: newKey)
		#expect(edit.applied(to: environments) == .failure(.invalidName))
	}

	@Test("a value-only edit does not re-validate an existing key name")
	func valueEditKeepsLegacyName() throws {
		let legacy: [String: [String: String]] = ["default": ["legacy-name": "old"]]
		let edit = VaultKeyEdit(key: "legacy-name", environments: legacy, values: ["default": "new"])
		#expect(try edit.applied(to: legacy).get() == ["default": ["legacy-name": "new"]])
	}

	@Test("changes made elsewhere after the edit began stop it", arguments: ["value", "added", "removed", "environment", "target"])
	func changedElsewhere(change: String) {
		let edit = VaultKeyEdit(
			key: "STRIPE_KEY", environments: environments, newKey: "STRIPE_SECRET_KEY",
			values: ["production": "sk_live"])
		var latest = environments
		switch change {
		case "value": latest["staging"]?["STRIPE_KEY"] = "rotated"
		case "added": latest["production"]?["STRIPE_KEY"] = "from-cli"
		case "removed": latest["default"]?.removeValue(forKey: "STRIPE_KEY")
		case "environment": latest.removeValue(forKey: "staging")
		default: latest.removeValue(forKey: "production")
		}
		#expect(edit.applied(to: latest) == .failure(.changed))
	}

	@Test("an edit that changes nothing leaves the environments as they are")
	func noChange() throws {
		let edit = VaultKeyEdit(key: "STRIPE_KEY", environments: environments, values: ["default": "sk_dev"])
		#expect(try edit.applied(to: environments).get() == environments)
	}
}

@Suite("Saving key edits", .serialized)
@MainActor
struct VaultKeyEditStoreTests {
	private let environments: [String: [String: String]] = [
		"default": ["STRIPE_KEY": "sk_dev"],
		"staging": ["STRIPE_KEY": "sk_staging"],
		"production": [:],
	]

	@Test("a rename with new values is written in one transaction and marked for sync")
	func savesAtomically() async throws {
		let (store, keychain) = makeStore()
		defer { store.lock() }
		let edit = VaultKeyEdit(
			key: "STRIPE_KEY", environments: environments, newKey: "STRIPE_SECRET_KEY",
			values: ["default": "sk_dev_2", "production": "sk_live"])
		try await store.saveKeyEdit(edit, in: "project")
		let expected: [String: [String: String]] = [
			"default": ["STRIPE_SECRET_KEY": "sk_dev_2"],
			"staging": ["STRIPE_SECRET_KEY": "sk_staging"],
			"production": ["STRIPE_SECRET_KEY": "sk_live"],
		]
		#expect(keychain.envStorage["project"]?.environments == expected)
		#expect(store.selectedProject?.environments == expected)
		#expect(keychain.applyVaultTransactionCallCount == 1)
		#expect(keychain.storedSyncMetadata(vaultId: "project")?.isDirty == true)
		#expect(store.error == nil)
	}

	@Test("a CLI change after the edit began is reported to the editor, not raised as an alert")
	func cliChangeIsAConflict() async throws {
		let (store, keychain) = makeStore()
		defer { store.lock() }
		let edit = VaultKeyEdit(key: "STRIPE_KEY", environments: environments, newKey: "STRIPE_SECRET_KEY")
		keychain.simulateCLISet(vaultId: "project", environment: "staging", key: "STRIPE_KEY", value: "rotated")
		await #expect(throws: VaultKeyEditError.changed) {
			try await store.saveKeyEdit(edit, in: "project")
		}
		#expect(store.error == nil)
		#expect(store.selectedProject?.environments["staging"] == ["STRIPE_KEY": "rotated"])
		#expect(keychain.envStorage["project"]?.environments["default"] == ["STRIPE_KEY": "sk_dev"])
	}

	@Test("a key the CLI added under the new name is reported as a collision")
	func cliCollisionIsReported() async throws {
		let (store, keychain) = makeStore()
		defer { store.lock() }
		let edit = VaultKeyEdit(key: "STRIPE_KEY", environments: environments, newKey: "STRIPE_SECRET_KEY")
		keychain.simulateCLISet(vaultId: "project", environment: "staging", key: "STRIPE_SECRET_KEY", value: "cli")
		await #expect(throws: VaultKeyEditError.collision(environment: "staging", existingKey: "STRIPE_SECRET_KEY", newKey: "STRIPE_SECRET_KEY")) {
			try await store.saveKeyEdit(edit, in: "project")
		}
		#expect(keychain.envStorage["project"]?.environments["default"] == ["STRIPE_KEY": "sk_dev"])
	}

	@Test("a locked vault or an unselected project saves nothing", arguments: [true, false])
	func unavailableTargets(locked: Bool) async {
		let (store, keychain) = makeStore()
		defer { store.lock() }
		if locked { store.lock() } else { store.selectedProjectId = nil }
		let edit = VaultKeyEdit(key: "STRIPE_KEY", environments: environments, newKey: "STRIPE_SECRET_KEY")
		await #expect(throws: locked ? VaultKeyEditError.vaultLocked : .targetUnavailable) {
			try await store.saveKeyEdit(edit, in: "project")
		}
		#expect(keychain.envStorage["project"]?.environments == environments)
	}

	@Test("a Keychain failure leaves every environment unchanged")
	func persistenceFailure() async {
		let (store, keychain) = makeStore()
		defer { store.lock() }
		keychain.failProjectReads = true
		let edit = VaultKeyEdit(key: "STRIPE_KEY", environments: environments, newKey: "STRIPE_SECRET_KEY")
		do {
			try await store.saveKeyEdit(edit, in: "project")
			Issue.record("The save should fail")
		} catch {
			if case .persistence = error {} else { Issue.record("Unexpected error \(error)") }
		}
		keychain.failProjectReads = false
		#expect(keychain.envStorage["project"]?.environments == environments)
		#expect(store.selectedProject?.environments == environments)
		#expect(store.error == nil)
	}

	@Test("a key draft saves once, even when saving is requested twice, and then ends")
	func draftSavesOnce() async throws {
		let (store, keychain) = makeStore()
		defer { store.lock() }
		let project = try #require(store.selectedProject)
		let id = VaultKeyDraft.ID(projectID: "project", key: "STRIPE_KEY")
		store.keyDrafts.edit(project, key: "STRIPE_KEY") {
			$0.name = "STRIPE_SECRET_KEY"
			$0.setValue("sk_live", in: "production")
		}
		async let first: Void = store.saveKeyDraft(id)
		async let second: Void = store.saveKeyDraft(id)
		_ = try await (first, second)
		#expect(keychain.applyVaultTransactionCallCount == 1)
		#expect(keychain.envStorage["project"]?.environments["production"] == ["STRIPE_SECRET_KEY": "sk_live"])
		#expect(keychain.envStorage["project"]?.environments["staging"] == ["STRIPE_SECRET_KEY": "sk_staging"])
		#expect(store.keyDrafts.draft(id) == nil)
		#expect(store.keyDrafts.editedKeys(in: "project").isEmpty)
	}

	@Test("a value saved elsewhere before the draft's save runs keeps the edit as a conflict")
	func draftSaveConflict() async throws {
		let (store, keychain) = makeStore()
		defer { store.lock() }
		let project = try #require(store.selectedProject)
		let id = VaultKeyDraft.ID(projectID: "project", key: "STRIPE_KEY")
		store.keyDrafts.edit(project, key: "STRIPE_KEY") { $0.setValue("sk_dev_2", in: "default") }
		keychain.simulateCLISet(vaultId: "project", environment: "default", key: "STRIPE_KEY", value: "sk_cli")
		await #expect(throws: VaultKeyEditError.changed) {
			try await store.saveKeyDraft(id)
		}
		let draft = try #require(store.keyDrafts.draft(id))
		#expect(draft.value(in: "default") == "sk_dev_2")
		#expect(draft.values["default"]?.hasExternalConflict == true)
		#expect(!draft.isSaveInFlight)
		#expect(keychain.envStorage["project"]?.environments["default"] == ["STRIPE_KEY": "sk_cli"])
		#expect(store.error == nil)
	}

	@Test("drafts follow a refresh and end when the vault locks or the account changes", arguments: ["lock", "account"])
	func draftLifecycle(ending: String) async throws {
		let (store, keychain) = makeStore()
		defer { store.lock() }
		let project = try #require(store.selectedProject)
		let id = VaultKeyDraft.ID(projectID: "project", key: "STRIPE_KEY")
		store.keyDrafts.edit(project, key: "STRIPE_KEY") { $0.setValue("sk_dev_2", in: "default") }
		keychain.simulateCLISet(vaultId: "project", environment: "staging", key: "STRIPE_KEY", value: "sk_staging_cli")
		await store.refreshLocalState()
		#expect(store.keyDrafts.draft(id)?.value(in: "staging") == "sk_staging_cli")
		#expect(store.keyDrafts.draft(id)?.value(in: "default") == "sk_dev_2")
		if ending == "lock" { store.lock() } else { store.selectedAccount = .org("other") }
		#expect(store.keyDrafts.drafts.isEmpty)
	}

	private func makeStore() -> (VaultStore, MockKeychainService) {
		let keychain = MockKeychainService()
		keychain.envStorage["project"] = (name: "Project", path: "", environments: environments)
		let store = VaultStore(keychainService: keychain, biometricService: MockBiometricService(), apiService: MockAPIService())
		store.projects = [VaultProject(id: "project", name: "Project", path: "", environments: environments)]
		store.isUnlocked = true
		store.selectedProjectId = "project"
		return (store, keychain)
	}
}

@Suite("Saving key descriptions", .serialized)
@MainActor
struct VaultKeyDescriptionStoreTests {
	private let environments: [String: [String: String]] = ["default": ["STRIPE_KEY": "sk_dev", "OTHER": "other"]]
	private let id = VaultKeyDraft.ID(projectID: "project", key: "STRIPE_KEY")

	@Test("a description edit is written to lpm.json without touching the Keychain")
	func descriptionOnly() async throws {
		let (store, keychain, folder) = try await makeStore(#"{"vault": "project"}"#)
		defer { store.lock(); try? FileManager.default.removeItem(atPath: folder) }
		let project = try #require(store.selectedProject)
		store.keyDrafts.edit(project, key: "STRIPE_KEY") { $0.setKeyDescription("Billing", saved: "") }
		#expect(store.keyDrafts.editedKeys(in: "project") == ["STRIPE_KEY"])
		try await store.saveKeyDraft(id)
		#expect(keychain.applyVaultTransactionCallCount == 0)
		#expect(try ProjectEnvSchemaFile.rules(inFolder: folder, vaultID: "project").descriptions == ["STRIPE_KEY": "Billing"])
		#expect(store.keyDescriptions["project"]?.description(of: "STRIPE_KEY") == "Billing")
		#expect(store.keyDrafts.draft(id) == nil)
	}

	@Test("a secret rename into a browser prefix fails before changing stored values", arguments: [false, true])
	func secretCannotBeRenamedIntoBrowserPrefix(targetDeclared: Bool) async throws {
		let target = targetDeclared ? #","NEXT_PUBLIC_TOKEN":{"client":true}"# : ""
		let original = #"{"envSchema":{"vars":{"STRIPE_KEY":{"secret":true}\#(target)}}}"#
		let (store, keychain, folder) = try await makeStore(original)
		defer { store.lock(); try? FileManager.default.removeItem(atPath: folder) }
		store.keyDrafts.edit(try #require(store.selectedProject), key: id.key) { $0.name = "NEXT_PUBLIC_TOKEN" }
		await #expect(throws: VaultKeyEditError.description(ProjectEnvSchemaFile.FileError.invalidSchema.localizedDescription, keySaved: false)) { try await store.saveKeyDraft(id) }
		#expect(keychain.applyVaultTransactionCallCount == 0)
		#expect(keychain.envStorage["project"]?.environments == environments)
		#expect(try String(contentsOfFile: folder + "/lpm.json", encoding: .utf8) == original)
	}

	@Test("a rename moves the key's rule and saves its new description in the same save")
	func renameWithDescription() async throws {
		let (store, keychain, folder) = try await makeStore(#"{"envSchema": {"vars": {"STRIPE_KEY": {"required": true, "description": "Old"}}}}"#)
		defer { store.lock(); try? FileManager.default.removeItem(atPath: folder) }
		let project = try #require(store.selectedProject)
		store.keyDrafts.edit(project, key: "STRIPE_KEY") {
			$0.name = "STRIPE_SECRET_KEY"
			$0.setKeyDescription("Live billing key", saved: "Old")
		}
		try await store.saveKeyDraft(id)
		#expect(keychain.envStorage["project"]?.environments["default"] == ["STRIPE_SECRET_KEY": "sk_dev", "OTHER": "other"])
		let rules = try ProjectEnvSchemaFile.rules(inFolder: folder, vaultID: "project")
		#expect(rules == .init(keys: ["STRIPE_SECRET_KEY"], descriptions: ["STRIPE_SECRET_KEY": "Live billing key"]))
	}

	@Test("a description that cannot be read stops the save before anything is written")
	func unreadableDescriptions() async throws {
		let (store, keychain, folder) = try await makeStore(#"{"vault": "another-vault"}"#)
		defer { store.lock(); try? FileManager.default.removeItem(atPath: folder) }
		let project = try #require(store.selectedProject)
		store.keyDrafts.edit(project, key: "STRIPE_KEY") {
			$0.name = "STRIPE_SECRET_KEY"
			$0.setKeyDescription("Billing", saved: "")
		}
		await #expect(throws: VaultKeyEditError.description(ProjectEnvSchemaFile.FileError.linkedToOtherVault.localizedDescription, keySaved: false)) {
			try await store.saveKeyDraft(id)
		}
		#expect(keychain.applyVaultTransactionCallCount == 0)
		#expect(store.keyDrafts.draft(id)?.keyDescriptionChange == "Billing")
		#expect(store.keyDrafts.draft(id)?.isSaveInFlight == false)
	}

	@Test("an invalid manifest stops a rename and retains the original draft")
	func invalidManifestStopsRename() async throws {
		let (store, keychain, folder) = try await makeStore(#"{"vault": "project"}"#)
		defer { store.lock(); try? FileManager.default.removeItem(atPath: folder) }
		let project = try #require(store.selectedProject)
		store.keyDrafts.edit(project, key: "STRIPE_KEY") {
			$0.name = "STRIPE_SECRET_KEY"
			$0.setKeyDescription("Billing", saved: "")
		}
		try "{".write(toFile: folder + "/lpm.json", atomically: true, encoding: .utf8)
		await #expect(throws: VaultKeyEditError.description(ProjectEnvSchemaFile.FileError.invalidJSON.localizedDescription, keySaved: false)) {
			try await store.saveKeyDraft(id)
		}
		#expect(keychain.envStorage["project"]?.environments["default"]?["STRIPE_KEY"] == "sk_dev")
		#expect(store.keyDrafts.draft(id)?.keyDescriptionChange == "Billing")
		#expect(store.keyDrafts.draft(id)?.isRenamed == true)
		#expect(keychain.applyVaultTransactionCallCount == 0)
	}

	@Test("a description changed in lpm.json while it is edited becomes a conflict")
	func externalDescriptionChange() async throws {
		let (store, _, folder) = try await makeStore(#"{"envSchema": {"vars": {"STRIPE_KEY": {"description": "Old"}}}}"#)
		defer { store.lock(); try? FileManager.default.removeItem(atPath: folder) }
		let project = try #require(store.selectedProject)
		store.keyDrafts.edit(project, key: "STRIPE_KEY") { $0.setKeyDescription("Mine", saved: "Old") }
		try #"{"envSchema": {"vars": {"STRIPE_KEY": {"description": "Theirs"}}}}"#.write(toFile: folder + "/lpm.json", atomically: true, encoding: .utf8)
		store.reloadKeyDescriptions()
		try await waitUntil { store.keyDescriptions["project"]?.description(of: "STRIPE_KEY") == "Theirs" }
		let draft = try #require(store.keyDrafts.draft(id))
		#expect(draft.keyDescription?.hasExternalConflict == true)
		#expect(draft.keyDescriptionChange == "Mine")
		#expect(!draft.canSave)
	}

	@Test("saving detects an external description edit without a refresh")
	func saveDetectsUnseenDescriptionChange() async throws {
		let (store, _, folder) = try await makeStore(#"{"envSchema":{"vars":{"STRIPE_KEY":{"description":"Old"}}}}"#)
		defer { store.lock(); try? FileManager.default.removeItem(atPath: folder) }
		let project = try #require(store.selectedProject)
		store.keyDrafts.edit(project, key: id.key) { $0.setKeyDescription("Mine", saved: "Old") }
		try #"{"envSchema":{"vars":{"STRIPE_KEY":{"description":"Theirs"}}}}"#.write(toFile: folder + "/lpm.json", atomically: true, encoding: .utf8)
		do { try await store.saveKeyDraft(id); Issue.record("An unseen edit must conflict") } catch {}
		#expect(try ProjectEnvSchemaFile.rules(inFolder: folder, vaultID: "project").descriptions[id.key] == "Theirs")
		#expect(store.keyDrafts.draft(id)?.keyDescription?.hasExternalConflict == true)
		#expect(store.keyDrafts.draft(id)?.keyDescriptionChange == "Mine")
		store.keyDrafts.edit(project, key: id.key) { $0.keepKeyDescription() }
		try await store.saveKeyDraft(id)
		#expect(try ProjectEnvSchemaFile.rules(inFolder: folder, vaultID: "project").descriptions[id.key] == "Mine")
	}

	@Test("retrying a rejected rename moves its complete schema rule", arguments: [false, true])
	func retrySchemaRename(withDescription: Bool) async throws {
		let original = #"{"envSchema":{"vars":{"STRIPE_KEY":{"required":true,"description":"Old","format":"url"}}}}"#
		let (store, keychain, folder) = try await makeStore(original)
		defer { store.lock(); try? FileManager.default.removeItem(atPath: folder) }
		let project = try #require(store.selectedProject)
		store.keyDrafts.edit(project, key: id.key) {
			$0.name = "NEW"
			if withDescription { $0.setKeyDescription("Mine", saved: "Old") }
		}
		try "{".write(toFile: folder + "/lpm.json", atomically: true, encoding: .utf8)
		do { try await store.saveKeyDraft(id); Issue.record("Schema update must fail") } catch {}
		let moved = id
		#expect(keychain.envStorage["project"]?.environments["default"]?[id.key] == "sk_dev")
		#expect(store.keyDrafts.draft(moved)?.canSave == true)
		try original.write(toFile: folder + "/lpm.json", atomically: true, encoding: .utf8)
		try await store.saveKeyDraft(moved)
		let document = try LPMConfigJSON(parsing: Data(contentsOf: URL(fileURLWithPath: folder + "/lpm.json")))
		#expect(document["envSchema"]?["vars"]?["STRIPE_KEY"] == nil)
		#expect(document["envSchema"]?["vars"]?["NEW"]?["required"] == .bool(true))
		#expect(document["envSchema"]?["vars"]?["NEW"]?["format"] == .string("url"))
		#expect(document["envSchema"]?["vars"]?["NEW"]?["description"] == .string(withDescription ? "Mine" : "Old"))
		#expect(store.keyDrafts.draft(moved) == nil)
	}

	@Test("a rename checks current rules even when the cached file had none", arguments: [false, true])
	func renameChecksCurrentSchema(beforeFirstLoad: Bool) async throws {
		let (store, _, folder) = try await makeStore(#"{"vault":"project"}"#)
		defer { store.lock(); try? FileManager.default.removeItem(atPath: folder) }
		if beforeFirstLoad { store.selectedAccount = .org("other"); store.selectedAccount = .personal }
		try #"{"vault":"project","envSchema":{"vars":{"STRIPE_KEY":{"required":true}}}}"#.write(toFile: folder + "/lpm.json", atomically: true, encoding: .utf8)
		store.keyDrafts.edit(try #require(store.selectedProject), key: id.key) { $0.name = "NEW" }
		try await store.saveKeyDraft(id)
		let rules = try ProjectEnvSchemaFile.rules(inFolder: folder, vaultID: "project")
		#expect(rules.keys == ["NEW"])
	}

	@Test("old schema save completions preserve later session drafts and caches", arguments: ["account", "lock"], [false, true])
	func schemaSaveSessionLifetime(transition: String, fails: Bool) async throws {
		let (store, keychain, folder) = try await makeStore(#"{"vault":"project"}"#)
		defer { store.lock(); try? FileManager.default.removeItem(atPath: folder) }
		try FileManager.default.createDirectory(atPath: folder + "/.lpm", withIntermediateDirectories: true)
		let descriptor = open(folder + "/.lpm/.config.lock", O_RDWR | O_CREAT, 0o644)
		try #require(descriptor >= 0)
		defer { flock(descriptor, LOCK_UN); close(descriptor) }
		#expect(flock(descriptor, LOCK_EX) == 0)
		store.keyDrafts.edit(try #require(store.selectedProject), key: id.key) {
			$0.setValue("committed", in: "default")
			$0.setKeyDescription("Old session", saved: "")
		}
		let save = Task { try? await store.saveKeyDraft(id) }
		try await waitUntil { keychain.envStorage["project"]?.environments["default"]?[id.key] == "committed" }
		if transition == "lock" { store.lock(); store.isUnlocked = true } else {
			store.selectedAccount = .org("other"); store.selectedAccount = .personal
		}
		let current = VaultProject(id: "project", name: "Project", path: folder, environments: environments)
		store.projects = [current]
		store.selectedProjectId = "project"
		store.keyDrafts.edit(current, key: id.key) { $0.setValue("Fresh session", in: "default") }
		let fresh = store.keyDrafts.draft(id)
		if fails { try "{".write(toFile: folder + "/lpm.json", atomically: true, encoding: .utf8) }
		flock(descriptor, LOCK_UN)
		await save.value
		#expect(store.keyDrafts.draft(id) == fresh)
		#expect(store.keyDescriptions.isEmpty)
	}

	@Test("a key rename rejects an existing destination declaration")
	func schemaRenameRejectsExistingTarget() async throws {
		let original = #"{"envSchema":{"vars":{"STRIPE_KEY":{"required":true,"description":"Old"},"NEW":{"required":true}}}}"#
		let (store, keychain, folder) = try await makeStore(original)
		defer { store.lock(); try? FileManager.default.removeItem(atPath: folder) }
		store.keyDrafts.edit(try #require(store.selectedProject), key: id.key) { $0.name = "NEW" }
		await #expect(throws: VaultKeyEditError.description(ProjectEnvSchemaFile.FileError.invalidSchema.localizedDescription, keySaved: false)) { try await store.saveKeyDraft(id) }
		#expect(keychain.applyVaultTransactionCallCount == 0)
		#expect(keychain.envStorage["project"]?.environments == environments)
		#expect(try String(contentsOfFile: folder + "/lpm.json", encoding: .utf8) == original)
	}

	@Test("schema replacement failures restore keys and sync metadata under the transaction lock", arguments: [false, true])
	func schemaWriteFailureRestoresKeyAndMetadata(editorRace: Bool) async throws {
		let original = #"{"envSchema":{"vars":{"STRIPE_KEY":{"secret":true}}}}"#
		let (store, keychain, folder) = try await makeStore(original)
		defer { store.lock(); try? FileManager.default.removeItem(atPath: folder) }
		let project = try #require(store.selectedProject)
		let metadata = keychain.dataStorage
		let coordinator = VaultPersistenceCoordinator(service: keychain)
		let result = coordinator.coordinatedKeyRename(project: project, edit: .init(key: id.key, environments: environments, newKey: "NEW"), change: .init(rename: .init(from: id.key, to: "NEW")), folder: folder, fileWriter: { _, url, _, _, check in
			if editorRace { try #"{"edited":true}"#.write(to: url, atomically: true, encoding: .utf8); try check() }
			throw ProjectConfigFile.FileError.writeFailed("fixture replacement failure")
		})
		switch result {
		case .failure, .schemaChanged: break
		default: Issue.record("Failed replacement must be reported"); return
		}
		#expect(keychain.envStorage["project"]?.environments == environments)
		#expect(keychain.dataStorage == metadata)
		#expect(keychain.applyVaultTransactionCallCount == 2)
		#expect(try String(contentsOfFile: folder + "/lpm.json", encoding: .utf8) == (editorRace ? #"{"edited":true}"# : original))
	}

	@Test("a committed rename remains aligned when directory durability fails")
	func schemaRenameDirectorySyncFailureKeepsAlignment() async throws {
		let (store, keychain, folder) = try await makeStore(#"{"envSchema":{"vars":{"STRIPE_KEY":{"secret":true}}}}"#)
		defer { store.lock(); try? FileManager.default.removeItem(atPath: folder) }
		let result = VaultPersistenceCoordinator(service: keychain).coordinatedKeyRename(project: try #require(store.selectedProject), edit: .init(key: id.key, environments: environments, newKey: "NEW"), change: .init(rename: .init(from: id.key, to: "NEW")), folder: folder, fileWriter: { data, url, permissions, replace, check in
			try SecureFileWriter.write(data, to: url, permissions: permissions, replaceExisting: replace, beforeReplacement: check, directorySynchronizer: { _ in EIO })
		})
		guard case .success(let commit, let rules) = result else { Issue.record("Replacement committed; report the durability warning without reverting keys"); return }
		#expect(commit.warning != nil)
		#expect(rules?.keys.contains("NEW") == true)
		#expect(keychain.envStorage["project"]?.environments["default"]?["NEW"] == "sk_dev")
		#expect(keychain.envStorage["project"]?.environments["default"]?[id.key] == nil)
		#expect(try ProjectEnvSchemaFile.rules(inFolder: folder, vaultID: "project").keys.contains("NEW"))
		#expect(keychain.applyVaultTransactionCallCount == 1)
	}

	@Test("initial rename persistence failures preserve their indeterminate classification", arguments: [false, true])
	func initialSchemaRenameFailureIsIndeterminate(transactionEntry: Bool) async throws {
		let (store, keychain, folder) = try await makeStore(#"{"envSchema":{"vars":{"STRIPE_KEY":{"secret":true}}}}"#)
		defer { store.lock(); try? FileManager.default.removeItem(atPath: folder) }
		if transactionEntry { keychain.nextKeychainTransactionError = .transactionOutcomeIndeterminate }
		else { keychain.nextVaultTransactionError = .transactionOutcomeIndeterminate }
		let result = VaultPersistenceCoordinator(service: keychain).coordinatedKeyRename(project: try #require(store.selectedProject), edit: .init(key: id.key, environments: environments, newKey: "NEW"), change: .init(rename: .init(from: id.key, to: "NEW")), folder: folder)
		guard case .indeterminate = result else { Issue.record("An indeterminate Keychain outcome requires a durable reload"); return }
	}

	@Test("schema renames share the project mutation queue before waiting for the config lock")
	func schemaRenameSerializesLaterMutations() async throws {
		let (store, keychain, folder) = try await makeStore(#"{"envSchema":{"vars":{"STRIPE_KEY":{"secret":true}}}}"#)
		defer { store.lock(); try? FileManager.default.removeItem(atPath: folder) }
		try FileManager.default.createDirectory(atPath: folder + "/.lpm", withIntermediateDirectories: true)
		let descriptor = open(folder + "/.lpm/.config.lock", O_RDWR | O_CREAT, 0o644)
		try #require(descriptor >= 0)
		defer { flock(descriptor, LOCK_UN); close(descriptor) }
		#expect(flock(descriptor, LOCK_EX) == 0)
		let observed = OSAllocatedUnfairLock(initialState: (calls: 0, overtaken: false, released: false))
		let entered = DispatchSemaphore(value: 0)
		keychain.beforeKeychainTransaction = {
			observed.withLock { state in
				state.calls += 1
				if state.calls > 1 && !state.released { state.overtaken = true }
			}
			entered.signal()
		}
		store.keyDrafts.edit(try #require(store.selectedProject), key: id.key) { $0.name = "NEW" }
		let rename = Task { try await store.saveKeyDraft(id) }
		await withCheckedContinuation { continuation in Thread.detachNewThread { entered.wait(); continuation.resume() } }
		let edit = VaultKeyEdit(key: id.key, environments: environments, values: ["default": "later"])
		let later = Task { try? await store.saveKeyEdit(edit, in: "project") }
		DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(100)) {
			observed.withLock { $0.released = true }
			flock(descriptor, LOCK_UN)
		}
		try await rename.value
		await later.value
		#expect(!observed.withLock { $0.overtaken })
		#expect(store.selectedProject?.environments == keychain.envStorage["project"]?.environments)
		#expect(store.selectedProject?.environments["default"]?["NEW"] == "sk_dev")
	}

	@Test("a rename conflict publishes current values and marks the draft's conflict")
	func schemaRenamePublishesLatestConflict() async throws {
		let (store, keychain, folder) = try await makeStore(#"{"envSchema":{"vars":{"STRIPE_KEY":{"secret":true}}}}"#)
		defer { store.lock(); try? FileManager.default.removeItem(atPath: folder) }
		store.keyDrafts.edit(try #require(store.selectedProject), key: id.key) { $0.name = "NEW"; $0.setValue("mine", in: "default") }
		keychain.simulateCLISet(vaultId: "project", environment: "default", key: id.key, value: "external")
		await #expect(throws: VaultKeyEditError.changed) { try await store.saveKeyDraft(id) }
		#expect(store.selectedProject?.environments["default"]?[id.key] == "external")
		#expect(store.keyDrafts.draft(id)?.values["default"]?.hasExternalConflict == true)
		#expect(store.keyDrafts.draft(id)?.isSaveInFlight == false)
	}

	@Test("a queued rename ends its failed save when the selection or connected folder changes", arguments: [false, true])
	func queuedSchemaRenameRejectsChangedTarget(folderChanged: Bool) async throws {
		let original = #"{"envSchema":{"vars":{"STRIPE_KEY":{"secret":true}}}}"#
		let (store, keychain, folder) = try await makeStore(original)
		defer { store.lock(); try? FileManager.default.removeItem(atPath: folder) }
		let project = try #require(store.selectedProject)
		let otherFolder: String?
		if folderChanged {
			let other = folder + "/other"
			try FileManager.default.createDirectory(atPath: other, withIntermediateDirectories: true)
			try original.write(toFile: other + "/lpm.json", atomically: true, encoding: .utf8)
			otherFolder = other
		} else { otherFolder = nil }
		let entered = DispatchSemaphore(value: 0)
		let release = DispatchSemaphore(value: 0)
		keychain.blockNextSaveEnvironments = { entered.signal(); #expect(release.wait(timeout: .now() + 5) == .success) }
		defer { release.signal() }
		let earlier = Task { try await store.saveKeyEdit(.init(key: "OTHER", environments: environments, values: ["default": "later"]), in: "project") }
		let rename: Task<Void, Error>? = await withCheckedContinuation { continuation in
			Thread.detachNewThread {
				let didEnter = entered.wait(timeout: .now() + 5) == .success
				DispatchQueue.main.async {
					guard didEnter else {
						Issue.record("Earlier mutation did not enter its save")
						release.signal()
						continuation.resume(returning: nil)
						return
					}
					store.keyDrafts.edit(project, key: id.key) { $0.name = "NEW" }
					let rename = Task { try await store.saveKeyDraft(id) }
					observeOnMainQueue(until: { store.keyDrafts.draft(id)?.isSaveInFlight == true }) {
						if let otherFolder {
							ProjectCLILink.rememberFolder(otherFolder, vaultId: "project", defaults: store.preferences)
						} else { store.selectedProjectId = nil }
						release.signal()
						continuation.resume(returning: rename)
					}
				}
			}
		}
		try await earlier.value
		guard let rename else { return }
		let expected: VaultKeyEditError = folderChanged
			? .description("The project folder changed. Review its descriptions, then save again.", keySaved: false)
			: .targetUnavailable
		await #expect(throws: expected) { try await rename.value }
		#expect(keychain.envStorage["project"]?.environments["default"]?["OTHER"] == "later")
		#expect(store.keyDrafts.draft(id)?.isSaveInFlight == false)
		#expect(keychain.envStorage["project"]?.environments["default"]?[id.key] == "sk_dev")
		#expect(keychain.envStorage["project"]?.environments["default"]?["NEW"] == nil)
		#expect(try String(contentsOfFile: folder + "/lpm.json", encoding: .utf8) == original)
	}

	@Test("old rename indeterminate completions cannot reload a locked session")
	func staleSchemaRenameDoesNotReloadLockedSession() async throws {
		let (store, keychain, folder) = try await makeStore(#"{"envSchema":{"vars":{"STRIPE_KEY":{"secret":true}}}}"#)
		defer { store.lock(); try? FileManager.default.removeItem(atPath: folder) }
		try FileManager.default.createDirectory(atPath: folder + "/.lpm", withIntermediateDirectories: true)
		let descriptor = open(folder + "/.lpm/.config.lock", O_RDWR | O_CREAT, 0o644)
		try #require(descriptor >= 0)
		defer { flock(descriptor, LOCK_UN); close(descriptor) }
		#expect(flock(descriptor, LOCK_EX) == 0)
		let entered = DispatchSemaphore(value: 0)
		keychain.beforeKeychainTransaction = { entered.signal() }
		keychain.nextVaultTransactionError = .transactionOutcomeIndeterminate
		store.keyDrafts.edit(try #require(store.selectedProject), key: id.key) { $0.name = "NEW" }
		let rename = Task { try? await store.saveKeyDraft(id) }
		await withCheckedContinuation { continuation in Thread.detachNewThread { entered.wait(); continuation.resume() } }
		store.lock()
		let reads = keychain.projectMetadataReadCount
		flock(descriptor, LOCK_UN)
		await rename.value
		#expect(keychain.projectMetadataReadCount == reads)
		#expect(store.keyDescriptions.isEmpty)
		#expect(store.keyDrafts.draft(id) == nil)
	}

	@Test("old rename completions preserve later account drafts and caches", arguments: ["saved", "changed", "indeterminate"])
	func staleSchemaRenamePreservesAccountSession(outcome: String) async throws {
		let original = #"{"envSchema":{"vars":{"STRIPE_KEY":{"secret":true,"description":"Old"}}}}"#
		let (store, keychain, folder) = try await makeStore(original)
		defer { store.lock(); try? FileManager.default.removeItem(atPath: folder) }
		try FileManager.default.createDirectory(atPath: folder + "/.lpm", withIntermediateDirectories: true)
		let descriptor = open(folder + "/.lpm/.config.lock", O_RDWR | O_CREAT, 0o644)
		try #require(descriptor >= 0)
		defer { flock(descriptor, LOCK_UN); close(descriptor) }
		#expect(flock(descriptor, LOCK_EX) == 0)
		let entered = DispatchSemaphore(value: 0)
		keychain.beforeKeychainTransaction = { entered.signal() }
		if outcome == "indeterminate" { keychain.nextVaultTransactionError = .transactionOutcomeIndeterminate }
		store.keyDrafts.edit(try #require(store.selectedProject), key: id.key) { $0.name = "NEW"; $0.setKeyDescription("Mine", saved: "Old") }
		let rename = Task { try? await store.saveKeyDraft(id) }
		await withCheckedContinuation { continuation in Thread.detachNewThread { entered.wait(); continuation.resume() } }
		store.selectedAccount = .org("other")
		store.selectedAccount = .personal
		let current = VaultProject(id: "project", name: "Project", path: folder, environments: environments)
		store.projects = [current]
		store.selectedProjectId = "project"
		store.keyDrafts.edit(current, key: id.key) { $0.setValue("Fresh session", in: "default") }
		let fresh = store.keyDrafts.draft(id)
		let reads = keychain.projectMetadataReadCount
		if outcome == "changed" { try #"{"envSchema":{"vars":{"STRIPE_KEY":{"secret":true,"description":"External"}}}}"#.write(toFile: folder + "/lpm.json", atomically: true, encoding: .utf8) }
		flock(descriptor, LOCK_UN)
		await rename.value
		#expect(store.keyDrafts.draft(id) == fresh)
		#expect(store.keyDescriptions.isEmpty)
		#expect(store.projects == [current])
		#expect(keychain.projectMetadataReadCount == reads)
	}

	@Test("a rename schema conflict reaches the draft after its save ends")
	func schemaRenameDescriptionConflictRemainsRecoverable() async throws {
		let (store, keychain, folder) = try await makeStore(#"{"envSchema":{"vars":{"STRIPE_KEY":{"secret":true,"description":"Old"}}}}"#)
		defer { store.lock(); try? FileManager.default.removeItem(atPath: folder) }
		store.keyDrafts.edit(try #require(store.selectedProject), key: id.key) { $0.name = "NEW"; $0.setKeyDescription("Mine", saved: "Old") }
		try #"{"envSchema":{"vars":{"STRIPE_KEY":{"secret":true,"description":"Theirs"}}}}"#.write(toFile: folder + "/lpm.json", atomically: true, encoding: .utf8)
		await #expect(throws: VaultKeyEditError.description(ProjectEnvSchemaFile.FileError.changed.localizedDescription, keySaved: false)) { try await store.saveKeyDraft(id) }
		let draft = try #require(store.keyDrafts.draft(id))
		#expect(draft.keyDescription?.hasExternalConflict == true)
		#expect(!draft.canSave)
		#expect(!draft.isSaveInFlight)
		#expect(keychain.envStorage["project"]?.environments["default"]?[id.key] == "sk_dev")
		store.keyDrafts.edit(try #require(store.selectedProject), key: id.key) { $0.keepKeyDescription() }
		try await store.saveKeyDraft(id)
		#expect(try ProjectEnvSchemaFile.rules(inFolder: folder, vaultID: "project").descriptions["NEW"] == "Mine")
	}

	@Test("an indeterminate rename recovery load belongs to its original account session")
	func schemaRenameRecoveryLoadPreservesLaterAccount() async throws {
		let (store, keychain, folder) = try await makeStore(#"{"envSchema":{"vars":{"STRIPE_KEY":{"secret":true}}}}"#)
		defer { store.lock(); try? FileManager.default.removeItem(atPath: folder) }
		let entered = DispatchSemaphore(value: 0)
		let release = DispatchSemaphore(value: 0)
		defer { release.signal() }
		keychain.blockNextListProjectMetadata = { entered.signal(); _ = release.wait(timeout: .now() + 10) }
		keychain.nextVaultTransactionError = .transactionOutcomeIndeterminate
		store.keyDrafts.edit(try #require(store.selectedProject), key: id.key) { $0.name = "NEW" }
		let rename = Task { try? await store.saveKeyDraft(id) }
		await withCheckedContinuation { continuation in Thread.detachNewThread { entered.wait(); continuation.resume() } }
		store.selectedAccount = .org("other"); store.selectedAccount = .personal
		let current = VaultProject(id: "project", name: "Project", path: folder, environments: environments)
		store.projects = [current]
		store.keyDrafts.edit(current, key: id.key) { $0.setValue("Fresh session", in: "default") }
		let fresh = store.keyDrafts.draft(id)
		release.signal()
		await rename.value
		#expect(store.projects == [current])
		#expect(store.keyDrafts.draft(id) == fresh)
		#expect(store.keyDescriptions.isEmpty)
	}

	@Test("schema renames enter the Keychain transaction before taking the config lock")
	func schemaRenameMatchesCliLockOrder() async throws {
		let (store, keychain, folder) = try await makeStore(#"{"envSchema":{"vars":{"STRIPE_KEY":{"secret":true}}}}"#)
		defer { store.lock(); try? FileManager.default.removeItem(atPath: folder) }
		try FileManager.default.createDirectory(atPath: folder + "/.lpm", withIntermediateDirectories: true)
		let observed = OSAllocatedUnfairLock(initialState: false)
		keychain.beforeKeychainTransaction = {
			let descriptor = open(folder + "/.lpm/.config.lock", O_RDWR | O_CREAT, 0o644)
			if descriptor >= 0 {
				observed.withLock { $0 = flock(descriptor, LOCK_EX | LOCK_NB) == 0 }
				flock(descriptor, LOCK_UN)
				close(descriptor)
			}
		}
		let result = VaultPersistenceCoordinator(service: keychain).coordinatedKeyRename(project: try #require(store.selectedProject), edit: .init(key: id.key, environments: environments, newKey: "NEW"), change: .init(rename: .init(from: id.key, to: "NEW")), folder: folder)
		guard case .success = result else { Issue.record("Rename must succeed"); return }
		#expect(observed.withLock { $0 })
	}

	@Test("failed rename compensation reports an indeterminate outcome")
	func failedRenameCompensationIsIndeterminate() async throws {
		let (store, keychain, folder) = try await makeStore(#"{"envSchema":{"vars":{"STRIPE_KEY":{"secret":true}}}}"#)
		defer { store.lock(); try? FileManager.default.removeItem(atPath: folder) }
		let result = VaultPersistenceCoordinator(service: keychain).coordinatedKeyRename(project: try #require(store.selectedProject), edit: .init(key: id.key, environments: environments, newKey: "NEW"), change: .init(rename: .init(from: id.key, to: "NEW")), folder: folder, fileWriter: { _, _, _, _, _ in
			keychain.failNextSaveEnvironments = true
			throw ProjectConfigFile.FileError.writeFailed("fixture replacement failure")
		})
		guard case .indeterminate = result else { Issue.record("Failed compensation must not claim restored values"); return }
	}

	@Test("a folder change prevents saves and completions from using the old cache", arguments: [false, true])
	func schemaFolderChange(inFlight: Bool) async throws {
		let (store, keychain, folder) = try await makeStore(#"{"envSchema":{"vars":{"STRIPE_KEY":{"description":"Old"}}}}"#)
		defer { store.lock(); try? FileManager.default.removeItem(atPath: folder) }
		let other = folder + "/other"
		try FileManager.default.createDirectory(atPath: other, withIntermediateDirectories: true)
		let otherContents = #"{"envSchema":{"vars":{"STRIPE_KEY":{"description":"Other"}}}}"#
		try otherContents.write(toFile: other + "/lpm.json", atomically: true, encoding: .utf8)
		store.keyDrafts.edit(try #require(store.selectedProject), key: id.key) {
			$0.setKeyDescription("Mine", saved: "Old")
			if inFlight { $0.setValue("committed", in: "default") }
		}
		try FileManager.default.createDirectory(atPath: folder + "/.lpm", withIntermediateDirectories: true)
		let descriptor = open(folder + "/.lpm/.config.lock", O_RDWR | O_CREAT, 0o644)
		try #require(descriptor >= 0)
		defer { flock(descriptor, LOCK_UN); close(descriptor) }
		var save: Task<Void, Never>?
		if inFlight {
			#expect(flock(descriptor, LOCK_EX) == 0)
			try #"{"envSchema":{"vars":{"STRIPE_KEY":{"description":"Theirs"}}}}"#.write(toFile: folder + "/lpm.json", atomically: true, encoding: .utf8)
			save = Task { try? await store.saveKeyDraft(id) }
			try await waitUntil { keychain.envStorage["project"]?.environments["default"]?[id.key] == "committed" }
		}
		ProjectCLILink.rememberFolder(other, vaultId: "project", defaults: store.preferences)
		if inFlight {
			store.reloadKeyDescriptions()
			try await waitUntil { store.keyDescriptions["project"]?.folder == other }
			flock(descriptor, LOCK_UN)
			await save?.value
			#expect(store.keyDescriptions["project"]?.folder == other)
		} else {
			do { try await store.saveKeyDraft(id); Issue.record("Stale folder metadata must not save") } catch {}
			#expect(try ProjectEnvSchemaFile.rules(inFolder: folder, vaultID: "project").descriptions[id.key] == "Old")
		}
		#expect(try String(contentsOfFile: other + "/lpm.json", encoding: .utf8) == otherContents)
	}

	@Test("unrelated key renames do not require valid schema metadata", arguments: ["missing-folder", "missing-manifest", "unrelated-invalid"])
	func unrelatedRenamesDoNotRequireSchema(state: String) async throws {
		let original = #"{"envSchema":{"vars":{"VITE_X":{}}}}"#
		let (store, keychain, folder) = try await makeStore(original)
		defer { store.lock(); try? FileManager.default.removeItem(atPath: folder) }
		if state == "missing-folder" { try FileManager.default.removeItem(atPath: folder) }
		if state == "missing-manifest" { try FileManager.default.removeItem(atPath: folder + "/lpm.json") }
		store.keyDrafts.edit(try #require(store.selectedProject), key: id.key) { $0.name = "NEW" }
		try await store.saveKeyDraft(id)
		#expect(keychain.envStorage["project"]?.environments["default"]?["NEW"] == "sk_dev")
		#expect(keychain.envStorage["project"]?.environments["default"]?[id.key] == nil)
		if state == "unrelated-invalid" { #expect(try String(contentsOfFile: folder + "/lpm.json", encoding: .utf8) == original) }
	}

    @Test("irrelevant rename rolls back if a declaration is added during persistence")
    func irrelevantRenameChecksManifestFreshness() async throws {
        let (store, keychain, folder) = try await makeStore(#"{"envSchema":{"vars":{}}}"#)
        defer { store.lock(); try? FileManager.default.removeItem(atPath: folder) }
        keychain.blockNextSaveEnvironments = {
            try! #"{"envSchema":{"vars":{"STRIPE_KEY":{"required":true}}}}"#.write(toFile: folder + "/lpm.json", atomically: true, encoding: .utf8)
        }
        store.keyDrafts.edit(try #require(store.selectedProject), key: id.key) { $0.name = "NEW" }
        do { try await store.saveKeyDraft(id); Issue.record("Stale admission must fail") } catch {}
        #expect(keychain.envStorage["project"]?.environments["default"]?[id.key] == "sk_dev")
        #expect(keychain.envStorage["project"]?.environments["default"]?["NEW"] == nil)
    }

    @Test("a vanished folder refuses a combined rename and description without losing the draft")
    func missingFolderDoesNotDiscardRequestedDescription() async throws {
        let (store, keychain, folder) = try await makeStore(#"{"envSchema":{"vars":{"STRIPE_KEY":{"description":"Old"}}}}"#)
        defer { store.lock(); try? FileManager.default.removeItem(atPath: folder) }
        store.keyDrafts.edit(try #require(store.selectedProject), key: id.key) {
            $0.name = "NEW"
            $0.setKeyDescription("Requested", saved: "Old")
        }
        try FileManager.default.removeItem(atPath: folder)
        do { try await store.saveKeyDraft(id); Issue.record("A description cannot be saved without its folder") } catch {}
        #expect(keychain.envStorage["project"]?.environments["default"]?[id.key] == "sk_dev")
        #expect(keychain.envStorage["project"]?.environments["default"]?["NEW"] == nil)
        #expect(store.keyDrafts.draft(id)?.keyDescriptionChange == "Requested")
        #expect(keychain.applyVaultTransactionCallCount == 0)
    }

	private func makeStore(_ lpmJSON: String) async throws -> (VaultStore, MockKeychainService, String) {
		let folder = FileManager.default.temporaryDirectory.appending(path: "lpm-descriptions-\(UUID().uuidString)").path
		try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
		try lpmJSON.write(toFile: folder + "/lpm.json", atomically: true, encoding: .utf8)
		let keychain = MockKeychainService()
		keychain.envStorage["project"] = (name: "Project", path: folder, environments: environments)
		let preferences = try #require(UserDefaults(suiteName: "key-descriptions-\(UUID().uuidString)"))
		let store = VaultStore(keychainService: keychain, biometricService: MockBiometricService(), apiService: MockAPIService(), preferences: preferences)
		store.projects = [VaultProject(id: "project", name: "Project", path: folder, environments: environments)]
		store.isUnlocked = true
		store.selectedProjectId = "project"
		store.reloadKeyDescriptions()
		try await waitUntil { store.keyDescriptions["project"] != nil }
		return (store, keychain, folder)
	}

	private func waitUntil(_ condition: () -> Bool) async throws {
		for _ in 0..<1000 {
			if condition() { return }
			try await Task.sleep(for: .milliseconds(5))
		}
		try #require(condition(), "Timed out")
	}
}

@MainActor
private func observeOnMainQueue(
	until condition: @escaping @MainActor @Sendable () -> Bool,
	deadline: ContinuousClock.Instant = .now + .seconds(5),
	completion: @escaping @MainActor @Sendable () -> Void
) {
	if condition() { completion(); return }
	guard ContinuousClock.now < deadline else {
		Issue.record("Queued rename did not enter its save")
		completion()
		return
	}
	DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(5)) {
		observeOnMainQueue(until: condition, deadline: deadline, completion: completion)
	}
}
