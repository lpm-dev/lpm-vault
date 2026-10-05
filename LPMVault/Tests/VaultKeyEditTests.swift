import Darwin
import Foundation
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

	@Test("when lpm.json cannot be written after the Keychain save, the description edit moves to the new name")
	func descriptionWriteFailsAfterRename() async throws {
		let (store, keychain, folder) = try await makeStore(#"{"vault": "project"}"#)
		defer { store.lock(); try? FileManager.default.removeItem(atPath: folder) }
		let project = try #require(store.selectedProject)
		store.keyDrafts.edit(project, key: "STRIPE_KEY") {
			$0.name = "STRIPE_SECRET_KEY"
			$0.setKeyDescription("Billing", saved: "")
		}
		try "{".write(toFile: folder + "/lpm.json", atomically: true, encoding: .utf8)
		await #expect(throws: VaultKeyEditError.description(ProjectEnvSchemaFile.FileError.invalidJSON.localizedDescription, keySaved: true)) {
			try await store.saveKeyDraft(id)
		}
		#expect(keychain.envStorage["project"]?.environments["default"]?["STRIPE_SECRET_KEY"] == "sk_dev")
		#expect(store.keyDrafts.draft(id) == nil)
		let moved = VaultKeyDraft.ID(projectID: "project", key: "STRIPE_SECRET_KEY")
		#expect(store.keyDrafts.draft(moved)?.keyDescriptionChange == "Billing")
		#expect(store.keyDrafts.draft(moved)?.isRenamed == false)
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

	@Test("retrying a partial rename moves its complete schema rule", arguments: [false, true])
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
		let moved = VaultKeyDraft.ID(projectID: "project", key: "NEW")
		#expect(keychain.envStorage["project"]?.environments["default"]?["NEW"] == "sk_dev")
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

	@Test("retrying a schema rename respects an existing descriptionless destination")
	func retrySchemaRenameWithExistingTarget() async throws {
		let original = #"{"envSchema":{"vars":{"STRIPE_KEY":{"required":true,"description":"Old"},"NEW":{"required":true}}}}"#
		let (store, _, folder) = try await makeStore(original)
		defer { store.lock(); try? FileManager.default.removeItem(atPath: folder) }
		store.keyDrafts.edit(try #require(store.selectedProject), key: id.key) {
			$0.name = "NEW"
			$0.setKeyDescription("Mine", saved: "Old")
		}
		try "{".write(toFile: folder + "/lpm.json", atomically: true, encoding: .utf8)
		do { try await store.saveKeyDraft(id) } catch {}
		let refreshed = original.replacingOccurrences(of: #""NEW":{"required":true}"#, with: #""NEW":{"required":true},"MARK":{}"#)
		try refreshed.write(toFile: folder + "/lpm.json", atomically: true, encoding: .utf8)
		store.reloadKeyDescriptions()
		try await waitUntil { store.keyDescriptions["project"]?.rules == .success(.init(keys: [id.key, "NEW", "MARK"], descriptions: [id.key: "Old"])) }
		let moved = VaultKeyDraft.ID(projectID: "project", key: "NEW")
		#expect(store.keyDrafts.draft(moved)?.hasConflict == false)
		try await store.saveKeyDraft(moved)
		#expect(try ProjectEnvSchemaFile.rules(inFolder: folder, vaultID: "project").descriptions["NEW"] == "Mine")
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
		let deadline = ContinuousClock.now.advanced(by: .seconds(5))
		while !condition() {
			try #require(ContinuousClock.now < deadline, "Timed out")
			try await Task.sleep(for: .milliseconds(5))
		}
	}
}
