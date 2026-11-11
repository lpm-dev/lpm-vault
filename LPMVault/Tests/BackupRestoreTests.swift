import Foundation
import Testing
import os

@testable import LPMVault

@Suite("Backup restore", .serialized)
@MainActor
struct BackupRestoreTests {
	private static let passphrase = "harbor velvet ninety cactus orbit maple"

	private struct Fixture {
		let store: VaultStore
		let keychain: MockKeychainService
		/// This Mac's sync key stores.
		let keys: InMemoryKeychainBackend
		let home: LPMHome
		let biometric: MockBiometricService
		let defaults: UserDefaults
		let folder: URL

		func tearDown() {
			try? FileManager.default.removeItem(at: folder)
			defaults.removePersistentDomain(forName: folder.lastPathComponent)
		}
	}

	/// A store on a Mac holding `local` projects, listed in its sidebar.
	private func fixture(_ local: [String: [String: [String: String]]] = [:], keyBackend: (any KeychainStoreBackend)? = nil) throws -> Fixture {
		let folder = FileManager.default.temporaryDirectory.appending(path: "lpm-backup-restore-\(UUID().uuidString)", directoryHint: .isDirectory)
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		let defaults = try #require(UserDefaults(suiteName: folder.lastPathComponent))
		let keychain = MockKeychainService()
		for (id, environments) in local { keychain.envStorage[id] = (name: id, path: "", environments: environments) }
		let biometric = MockBiometricService()
		let keys = InMemoryKeychainBackend()
		let home = try testLPMHome(in: folder)
		let keyStore = keyBackend.map {
			BackupKeyStore(roots: SharedKeychainStore(service: BackupKeyStore.testRootService, backend: $0),
				sharing: SharedKeychainStore(service: BackupKeyStore.testSharingService, backend: $0),
				wrapping: SharedKeychainStore(service: BackupKeyStore.testWrappingService, backend: $0), home: home)
		} ?? .inMemory(keys, home: home)
		let store = VaultStore(
			keychainService: keychain, biometricService: biometric, apiService: MockAPIService(), preferences: defaults,
			projectIconsDirectory: folder.appending(path: "icons", directoryHint: .isDirectory),
			backupKeys: keyStore)
		store.projects = local.keys.sorted().map { VaultProject(id: $0, name: $0, path: "", environments: local[$0] ?? [:]) }
		store.isUnlocked = true
		return Fixture(store: store, keychain: keychain, keys: keys, home: home, biometric: biometric, defaults: defaults, folder: folder)
	}

	private func project(
		_ id: String, hidden: Bool = false, folder: String? = nil, environments: [String: [String: String]],
		sync: BackupPayload.Sync? = nil
	) -> BackupPayload.Project {
		.init(vaultId: id, name: id, folder: folder, hidden: hidden, cliAccess: .automatic, environments: environments, sync: sync)
	}

	/// A backup file of `projects`, sealed by the engine.
	private func backup(
		_ projects: [BackupPayload.Project], app: BackupAppSection? = nil, keys: BackupKeys? = nil, in folder: URL
	) throws -> URL {
		let payload = BackupPayload(
			createdAt: Date(timeIntervalSince1970: 1_761_171_075), producerVersion: "1.0.2", deviceName: "Studio", projects: projects, app: app,
			keys: keys)
		let encoded = try #require(payload.encoded())
		let file = try BackupEngine.seal(payload: encoded.bytes, passphrase: Self.passphrase).get()
		let url = folder.appending(path: "backup-\(UUID().uuidString).lpmbackup")
		try file.write(to: url)
		return url
	}

	@Test("on a Mac with no projects, a backup restores as new projects requiring approval, synced ones paused, and its settings, icons and destinations")
	func freshMac() async throws {
		let fixture = try fixture()
		defer { fixture.tearDown() }
		let destination = vercelDestination(source: "default")
		let preferences = BackupAppSection.Preferences(
			app: VaultSettings.Snapshot(
				security: .init(lockAfter: .fifteenMinutes, valueApproval: .afterFiveMinutes, clipboardClear: .thirtySeconds,
					rehide: .oneMinute, hidesFromCapture: false),
				newProjectsKeepHistory: false, newProjectsAskBeforeCLIReads: true, remindsToBackUp: false),
			updates: .init(checks: false, downloads: false))
		let settings = BackupAppSection.Settings(
			appearance: .dark, keySort: .descending, quitShortcut: .hold, updateChannel: .stable,
			projectOrder: ["synced"], environmentOrders: ["synced": ["staging", "default"]], preferences: preferences)
		let url = try backup([
			project("synced", environments: ["default": ["TOKEN": "a"], "staging": [:]],
				sync: .init(registry: "https://lpm.dev", principalId: "usr_1", scope: .personal)),
			project("removed", hidden: true, environments: ["default": ["OLD": "x"]]),
		], app: BackupAppSection(settings: settings, icons: ["synced": .choice(.emoji("🚀"))], destinations: ["synced": [destination]]), in: fixture.folder)

		let review = try await fixture.store.openBackup(at: url, passphrase: Self.passphrase)
		#expect(review.plan.projects.map(\.status) == [.new, .new])
		#expect(review.plan.contents.deviceName == "Studio")
		let choices = BackupRestoreChoices.defaults(for: review.plan, hasLocalProjects: false)
		#expect(choices.included == ["synced"], "A project the backup's Mac removed from its sidebar is left out unless chosen")
		#expect(choices.applySettings)

		var told: [String] = []
		let result = try await fixture.store.restoreBackup(review, choices: choices) { told.append($0.vaultId) }
		#expect(fixture.biometric.confirmationReasons == ["restore a backup into your env projects"])
		#expect(told == ["synced", "removed"])
		#expect(result.items.map(\.outcome) == [.restored(keys: 1, environments: 2, needsFolder: true), .notChosen])
		#expect(fixture.keychain.envStorage["synced"]?.environments == ["default": ["TOKEN": "a"], "staging": [:]])
		#expect(fixture.keychain.cliAccessPolicies["synced"] == .requireApproval)
		#expect(fixture.keychain.hiddenPayloads["removed"] == nil)

		#expect(fixture.store.syncPauses["synced"]?.principalId == "usr_1")
		#expect(VaultSyncPause.load(from: fixture.defaults)["synced"] != nil)
		#expect(result.destinations == 1)
		#expect(try await fixture.store.publishing.destinations(of: "synced").get() == [destination])
		#expect(fixture.store.projectIcons.savedChoices(for: ["synced"]) == ["synced": .emoji("🚀")])
		#expect(result.settings == settings)
		#expect(fixture.defaults.string(forKey: VaultKeySortOrder.defaultsKey) == "descending")
		#expect(fixture.store.settings.snapshot == preferences.app, "Security, new projects' defaults and the reminder come back")
		#expect(VaultSettings(defaults: fixture.defaults).snapshot == preferences.app)
		#expect(fixture.store.environmentOrders["synced"] == ["staging", "default"])

		fixture.store.openProject(id: "synced")
		await fixture.store.pushToCloud()
		#expect(fixture.store.error?.hasPrefix("Sync is paused for synced") == true)
	}

	@Test("a synced project's pause is saved before the project, hidden ones too, and dropped when the project isn't written")
	func pausesComeFirst() async throws {
		let fixture = try fixture()
		defer { fixture.tearDown() }
		let sync = BackupPayload.Sync(registry: "https://lpm.dev", principalId: "usr_1", scope: .personal)
		let url = try backup([
			project("listed", environments: ["default": ["A": "1"]], sync: sync),
			project("hidden", hidden: true, environments: ["default": ["B": "2"]], sync: sync),
			project("refused", environments: ["default": ["C": "3"]], sync: sync),
		], in: fixture.folder)
		let review = try await fixture.store.openBackup(at: url, passphrase: Self.passphrase)
		var choices = BackupRestoreChoices.defaults(for: review.plan, hasLocalProjects: false)
		choices.included.insert("hidden")

		let pausedWhenWritten = OSAllocatedUnfairLock(initialState: [String: Bool]())
		let defaults = ThreadSafeDefaults(defaults: fixture.defaults)
		let keychain = fixture.keychain
		keychain.beforeRestoredProjectWrite = { project in
			pausedWhenWritten.withLock { $0[project.id] = VaultSyncPause.load(from: defaults.defaults)[project.id] != nil }
			keychain.failRestoreWrites = project.id == "refused"
		}
		let result = try await fixture.store.restoreBackup(review, choices: choices)

		#expect(pausedWhenWritten.withLock { $0 } == ["listed": true, "hidden": true, "refused": true])
		#expect(result.items.map(\.outcome).last == .failed(KeychainError.accessDenied.description))
		#expect(Set(fixture.store.syncPauses.keys) == ["listed", "hidden"])
		#expect(Set(VaultSyncPause.load(from: fixture.defaults).keys) == ["listed", "hidden"])
	}

	@Test("a pause outlives loading projects while its project's data does, hidden or not, and goes with it")
	func pausesFollowStoredProjects() async throws {
		let fixture = try fixture()
		defer { fixture.tearDown() }
		let sync = BackupPayload.Sync(registry: "https://lpm.dev", principalId: "usr_1", scope: .personal)
		let url = try backup([
			project("listed", environments: ["default": ["A": "1"]], sync: sync),
			project("hidden", hidden: true, environments: ["default": ["B": "2"]], sync: sync),
		], in: fixture.folder)
		let review = try await fixture.store.openBackup(at: url, passphrase: Self.passphrase)
		var choices = BackupRestoreChoices.defaults(for: review.plan, hasLocalProjects: false)
		choices.included.insert("hidden")
		_ = try await fixture.store.restoreBackup(review, choices: choices)

		await fixture.store.loadProjects()
		#expect(Set(fixture.store.syncPauses.keys) == ["listed", "hidden"])
		#expect(Set(VaultSyncPause.load(from: fixture.defaults).keys) == ["listed", "hidden"])

		fixture.keychain.hiddenPayloads["hidden"] = nil
		fixture.keychain.envStorage["listed"] = nil
		await fixture.store.loadProjects()
		#expect(fixture.store.syncPauses.isEmpty)
		#expect(VaultSyncPause.load(from: fixture.defaults).isEmpty)
	}

	private func secret(_ text: String) -> SecretBytes {
		SecretBytes(count: text.utf8.count) { $0.copyBytes(from: Array(text.utf8)) }
	}

	private static let personalSync = BackupPayload.Sync(registry: "https://lpm.dev", principalId: "usr_1", scope: .personal)
	private static let organizationSync = BackupPayload.Sync(registry: "https://lpm.dev", principalId: "org_1", scope: .organization(slug: "acme"))

	/// The root key account of `personalSync`.
	private func personalRootAccount() throws -> String {
		try PersonalProjectCrypto.rootAccount(origin: "https://lpm.dev", principalID: "usr_1")
	}

	private func stored(_ fixture: Fixture, _ service: String, _ account: String) throws -> String? {
		try fixture.keys.read(service: service, account: account).map { String(decoding: $0, as: UTF8.self) }
	}

	@Test("a backup's sync keys are added where this Mac has none, so its synced projects sync, an organization's associated")
	func syncKeysRestore() async throws {
		let fixture = try fixture()
		defer { fixture.tearDown() }
		let account = try personalRootAccount()
		var keys = BackupKeys()
		keys.personalRoots = [.init(account: account, key: secret(BackupKeysTests.rootKey))]
		keys.sharingKeys = [.init(account: BackupKeysTests.sharingAccount, live: secret(BackupKeysTests.liveKey), pending: nil)]
		keys.floors = [.init(digest: BackupKeysTests.floor, version: 4)]
		let url = try backup([
			project("personal", environments: ["default": ["A": "1"]], sync: Self.personalSync),
			project("team", environments: ["default": ["B": "2"]], sync: Self.organizationSync),
		], keys: keys, in: fixture.folder)

		let review = try await fixture.store.openBackup(at: url, passphrase: Self.passphrase)
		#expect(
			review.keys
				== BackupKeyStore.Review(added: 2, floorsRaised: 1, addedRoots: [account], addedLiveSharingKeys: [BackupKeysTests.sharingAccount]))
		#expect(review.hasKey(for: Self.personalSync, restoringKeys: true))
		#expect(!review.hasKey(for: Self.personalSync, restoringKeys: false), "Without the backup's keys, this Mac has none")
		let choices = BackupRestoreChoices.defaults(for: review.plan, hasLocalProjects: false)
		#expect(choices.restoreKeys)

		let result = try await fixture.store.restoreBackup(review, choices: choices)
		#expect(result.keys?.added == 2)
		#expect(result.keyFailure == nil)
		#expect(try stored(fixture, BackupKeyStore.testRootService, account) == BackupKeysTests.rootKey)
		#expect(
			try stored(fixture, BackupKeyStore.testSharingService, VaultCrypto.scopedX25519AccountPrefix + BackupKeysTests.sharingAccount)
				== BackupKeysTests.liveKey)
		#expect(try PersonalProjectCrypto.floor(digest: BackupKeysTests.floor, home: fixture.home) == 4)
		#expect(fixture.store.syncPauses.isEmpty, "Both projects have their keys, so neither waits")
		let associations = try #require(fixture.keychain.dataStorage["__org_associations__"])
		#expect(try JSONDecoder().decode([String: String].self, from: associations) == ["team": "acme"])
	}

	@Test("a key this Mac holds differently is kept and the project it opens stays paused; left out, no key is added")
	func differingKeys() async throws {
		let fixture = try fixture()
		defer { fixture.tearDown() }
		let account = try personalRootAccount()
		let local = String(repeating: "c3", count: 32)
		try fixture.keys.add(service: BackupKeyStore.testRootService, account: account, data: Data(local.utf8))
		var keys = BackupKeys()
		keys.personalRoots = [.init(account: account, key: secret(BackupKeysTests.rootKey))]
		keys.wrappingKey = secret(BackupKeysTests.wrappingKey)
		let url = try backup([project("personal", environments: ["default": ["A": "1"]], sync: Self.personalSync)], keys: keys, in: fixture.folder)

		let review = try await fixture.store.openBackup(at: url, passphrase: Self.passphrase)
		#expect(review.keys.added == 1)
		#expect(review.keys.differing == 1)
		#expect(review.keys.differingRoots == [account])
		#expect(!review.hasKey(for: Self.personalSync, restoringKeys: true), "This Mac's own key can't open the backup's copy")

		var choices = BackupRestoreChoices.defaults(for: review.plan, hasLocalProjects: false)
		choices.restoreKeys = false
		_ = try await fixture.store.restoreBackup(review, choices: choices)
		#expect(try stored(fixture, BackupKeyStore.testWrappingService, VaultCrypto.wrappingKeyAccount) == nil, "Left out, no key is added")
		#expect(fixture.store.syncPauses["personal"] != nil)

		let again = try await fixture.store.openBackup(at: url, passphrase: Self.passphrase)
		let result = try await fixture.store.restoreBackup(again, choices: BackupRestoreChoices.defaults(for: again.plan, hasLocalProjects: true))
		#expect(result.keys?.added == 1)
		#expect(result.keys?.differing == 1)
		#expect(try stored(fixture, BackupKeyStore.testRootService, account) == local, "A key this Mac has is never replaced")
		#expect(try stored(fixture, BackupKeyStore.testWrappingService, VaultCrypto.wrappingKeyAccount) == BackupKeysTests.wrappingKey)
		#expect(fixture.store.syncPauses["personal"] != nil)
	}

	@Test("an organization's project has its key when every live sharing key the backup carries is here as it has it, or, carrying none, this Mac has one")
	func organizationCoverage() {
		typealias Coverage = BackupKeyStore.Coverage
		let carried = BackupKeysTests.sharingAccount
		let other = String(repeating: "0f", count: 32)
		var backup = BackupKeys()
		backup.sharingKeys = [.init(account: carried, live: secret(BackupKeysTests.liveKey), pending: nil)]
		let sync = Self.organizationSync

		#expect(!Coverage(present: .init(liveSharingKeys: [other]), review: .init(), backup: backup).hasKey(for: sync), "Another account's key isn't the backup's")
		#expect(Coverage(present: .init(liveSharingKeys: [carried, other]), review: .init(), backup: backup).hasKey(for: sync))
		#expect(
			!Coverage(present: .init(liveSharingKeys: [carried]), review: .init(differingLiveSharingKeys: [carried]), backup: backup).hasKey(for: sync),
			"This Mac's own key for the account can't open what the backup's opened")
		#expect(Coverage(present: BackupKeyStore.Present().adding(backup), review: .init(), backup: backup).hasKey(for: sync))
		#expect(Coverage(present: .init(liveSharingKeys: [other]), review: .init(), backup: BackupKeys()).hasKey(for: sync))
		#expect(!Coverage(present: .init(), review: .init(), backup: BackupKeys()).hasKey(for: sync))
		#expect(!Coverage().hasKey(for: Self.personalSync), "A Mac whose keys couldn't be read has none")
	}

	@Test("a restore that adds a paused project's missing key ends its pause; a key this Mac already had doesn't")
	func addedKeyEndsEarlierPause() async throws {
		let fixture = try fixture()
		defer { fixture.tearDown() }
		let account = try personalRootAccount()
		var keys = BackupKeys()
		keys.personalRoots = [.init(account: account, key: secret(BackupKeysTests.rootKey))]
		let url = try backup([project("personal", environments: ["default": ["A": "1"]], sync: Self.personalSync)], keys: keys, in: fixture.folder)

		let first = try await fixture.store.openBackup(at: url, passphrase: Self.passphrase)
		var choices = BackupRestoreChoices.defaults(for: first.plan, hasLocalProjects: false)
		choices.restoreKeys = false
		_ = try await fixture.store.restoreBackup(first, choices: choices)
		#expect(fixture.store.syncPauses["personal"] != nil)

		let again = try await fixture.store.openBackup(at: url, passphrase: Self.passphrase)
		let result = try await fixture.store.restoreBackup(again, choices: .defaults(for: again.plan, hasLocalProjects: true))
		#expect(result.keys?.addedRoots == [account])
		#expect(fixture.store.syncPauses.isEmpty, "The key the project lacked arrived")
		#expect(VaultSyncPause.load(from: fixture.defaults).isEmpty)
	}

	@Test("a pause from a differing root stays when a later backup carries the root this Mac already has")
	func heldKeyKeepsEarlierPause() async throws {
		let fixture = try fixture()
		defer { fixture.tearDown() }
		let account = try personalRootAccount()
		let local = String(repeating: "c3", count: 32)
		try fixture.keys.add(service: BackupKeyStore.testRootService, account: account, data: Data(local.utf8))
		var theirs = BackupKeys()
		theirs.personalRoots = [.init(account: account, key: secret(BackupKeysTests.rootKey))]
		let url = try backup([project("personal", environments: ["default": ["A": "1"]], sync: Self.personalSync)], keys: theirs, in: fixture.folder)
		let first = try await fixture.store.openBackup(at: url, passphrase: Self.passphrase)
		_ = try await fixture.store.restoreBackup(first, choices: .defaults(for: first.plan, hasLocalProjects: false))
		#expect(fixture.store.syncPauses["personal"] != nil)

		var ours = BackupKeys()
		ours.personalRoots = [.init(account: account, key: secret(local))]
		let own = try backup([], keys: ours, in: fixture.folder)
		let second = try await fixture.store.openBackup(at: own, passphrase: Self.passphrase)
		_ = try await fixture.store.restoreBackup(second, choices: .defaults(for: second.plan, hasLocalProjects: true))
		#expect(fixture.store.syncPauses["personal"] != nil, "This Mac's own root still can't open what the first backup's did")
	}

	@Test("Keep on this Mac only ends a pause; an organization's project leaves the organization here")
	func keepOnThisMacOnly() async throws {
		let fixture = try fixture()
		defer { fixture.tearDown() }
		let url = try backup([
			project("personal", environments: ["default": ["A": "1"]], sync: Self.personalSync),
			project("team", environments: ["default": ["B": "2"]], sync: Self.organizationSync),
		], in: fixture.folder)
		let review = try await fixture.store.openBackup(at: url, passphrase: Self.passphrase)
		_ = try await fixture.store.restoreBackup(review, choices: .defaults(for: review.plan, hasLocalProjects: false))
		#expect(Set(fixture.store.syncPauses.keys) == ["personal", "team"])
		#expect(fixture.store.vaultOrgAssociations["team"] == "acme")

		#expect(await fixture.store.keepOnThisMacOnly(projectId: "personal"))
		#expect(fixture.store.syncPauses["personal"] == nil)
		#expect(await fixture.store.keepOnThisMacOnly(projectId: "team"))
		#expect(fixture.store.syncPauses.isEmpty)
		#expect(VaultSyncPause.load(from: fixture.defaults).isEmpty)
		#expect(fixture.store.vaultOrgAssociations["team"] == nil)
		let associations = try #require(fixture.keychain.dataStorage["__org_associations__"])
		#expect(try JSONDecoder().decode([String: String].self, from: associations).isEmpty)
		#expect(fixture.keychain.envStorage["team"]?.environments == ["default": ["B": "2"]], "Its values stay")
		#expect(!(await fixture.store.keepOnThisMacOnly(projectId: "team")), "A project that isn't paused has nothing to end")
	}

	@Test("Check again ends an organization project's pause once this Mac holds the signed-in account's sharing key")
	func resumeOrganizationProject() async throws {
		let fixture = try fixture()
		defer { fixture.tearDown() }
		fixture.store.appEnvironment = .production
		let registry = AppEnvironment.production.registryURL
		let sync = BackupPayload.Sync(registry: registry, principalId: "org_1", scope: .organization(slug: "acme"))
		let url = try backup([project("team", environments: ["default": ["B": "2"]], sync: sync)], in: fixture.folder)
		let review = try await fixture.store.openBackup(at: url, passphrase: Self.passphrase)
		_ = try await fixture.store.restoreBackup(review, choices: .defaults(for: review.plan, hasLocalProjects: false))
		#expect(fixture.store.syncPauses["team"] != nil)

		#expect(!(await fixture.store.resumePausedOrganizationProject(projectId: "team")))
		#expect(fixture.store.error == "Sign in to lpm.dev to check for your sharing key.")
		fixture.store.currentUser = LPMUser(
			id: "usr_1", username: "dummy", name: nil, email: nil, avatarUrl: nil, plan: nil, createdAt: nil, orgs: nil)
		#expect(!(await fixture.store.resumePausedOrganizationProject(projectId: "team")))
		#expect(fixture.store.error == VaultStore.missingSharingKeyGuidance)
		#expect(fixture.store.syncPauses["team"] != nil)

		try fixture.keys.add(
			service: BackupKeyStore.testSharingService,
			account: VaultCrypto.x25519KeychainAccount(registryURL: registry, callerUserID: "usr_1"),
			data: Data(BackupKeysTests.liveKey.utf8))
		#expect(await fixture.store.resumePausedOrganizationProject(projectId: "team"))
		#expect(fixture.store.syncPauses.isEmpty)
	}

	@Test("a project already here is merged: this Mac's values kept unless replaced, the backup's other keys added")
	func merge() async throws {
		let fixture = try fixture(["shared": ["default": ["A": "1", "B": "2"]], "same": ["default": ["X": "1"]]])
		defer { fixture.tearDown() }
		let url = try backup([
			project("shared", environments: ["default": ["A": "1", "B": "9", "C": "3"], "staging": ["D": "4"]]),
			project("same", environments: ["default": ["X": "1"]]),
		], in: fixture.folder)

		let review = try await fixture.store.openBackup(at: url, passphrase: Self.passphrase)
		let differing = BackupRestorePlan.KeyDifference(environment: "default", key: "B")
		#expect(review.plan.projects.map(\.status) == [.merge(added: 2, differing: [differing]), .identical])
		var choices = BackupRestoreChoices.defaults(for: review.plan, hasLocalProjects: true)
		#expect(!choices.applySettings, "Settings would replace this Mac's, so they're off by default")
		_ = try await fixture.store.restoreBackup(review, choices: choices)
		#expect(fixture.keychain.envStorage["shared"]?.environments == ["default": ["A": "1", "B": "2", "C": "3"], "staging": ["D": "4"]])
		#expect(fixture.keychain.cliAccessPolicies["shared"] == nil, "A merge keeps this Mac's CLI approval")

		let again = try await fixture.store.openBackup(at: url, passphrase: Self.passphrase)
		#expect(again.plan.projects.map(\.status) == [.merge(added: 0, differing: [differing]), .identical])
		choices = BackupRestoreChoices.defaults(for: again.plan, hasLocalProjects: true)
		choices.replacing["shared"] = [differing]
		let result = try await fixture.store.restoreBackup(again, choices: choices)
		#expect(result.items.map(\.outcome) == [.merged(added: 0, replaced: 1), .identical])
		#expect(fixture.keychain.envStorage["shared"]?.environments["default"]?["B"] == "9")
	}

	@Test("restoring the same file again changes nothing already restored")
	func idempotent() async throws {
		let fixture = try fixture()
		defer { fixture.tearDown() }
		let url = try backup([project("vault-a", environments: ["default": ["TOKEN": "a"]])], in: fixture.folder)
		let first = try await fixture.store.openBackup(at: url, passphrase: Self.passphrase)
		_ = try await fixture.store.restoreBackup(first, choices: .defaults(for: first.plan, hasLocalProjects: false))
		let second = try await fixture.store.openBackup(at: url, passphrase: Self.passphrase)
		#expect(second.plan.projects.map(\.status) == [.identical])
		let result = try await fixture.store.restoreBackup(second, choices: .defaults(for: second.plan, hasLocalProjects: true))
		#expect(result.items.map(\.outcome) == [.identical])
	}

	@Test("a project that changes here after the review is left as it is")
	func changedSinceReview() async throws {
		let fixture = try fixture(["shared": ["default": ["A": "1"]]])
		defer { fixture.tearDown() }
		let url = try backup([project("shared", environments: ["default": ["A": "1", "B": "2"]])], in: fixture.folder)
		let review = try await fixture.store.openBackup(at: url, passphrase: Self.passphrase)
		fixture.keychain.envStorage["shared"]?.environments = ["default": ["A": "changed by the CLI"]]
		let result = try await fixture.store.restoreBackup(review, choices: .defaults(for: review.plan, hasLocalProjects: true))
		#expect(result.items.map(\.outcome) == [.changedSinceReview])
		#expect(fixture.keychain.envStorage["shared"]?.environments == ["default": ["A": "changed by the CLI"]])
	}

	@Test("restoring needs authenticating, and a locked vault ends the review")
	func authentication() async throws {
		let fixture = try fixture()
		defer { fixture.tearDown() }
		let url = try backup([project("vault-a", environments: ["default": ["TOKEN": "a"]])], in: fixture.folder)
		let review = try await fixture.store.openBackup(at: url, passphrase: Self.passphrase)
		fixture.biometric.shouldSucceed = false
		await #expect(throws: CancellationError.self) {
			try await fixture.store.restoreBackup(review, choices: .defaults(for: review.plan, hasLocalProjects: false))
		}
		#expect(fixture.keychain.envStorage.isEmpty)
		fixture.biometric.shouldSucceed = true
		fixture.store.lock()
		#expect(!fixture.store.isCurrentBackupRestoreReview(review))
		fixture.store.isUnlocked = true
		#expect(!fixture.store.isCurrentBackupRestoreReview(review))
		await #expect(throws: CancellationError.self) {
			try await fixture.store.restoreBackup(review, choices: .defaults(for: review.plan, hasLocalProjects: false))
		}
		#expect(fixture.keychain.envStorage.isEmpty)
	}

	@Test("a wrong passphrase, a file that isn't a backup, and a link each say what's wrong")
	func openingFailures() async throws {
		let fixture = try fixture()
		defer { fixture.tearDown() }
		let url = try backup([project("vault-a", environments: ["default": ["TOKEN": "a"]])], in: fixture.folder)
		await #expect(throws: BackupRestoreFailure.engine(.wrongPassphrase)) {
			try await fixture.store.openBackup(at: url, passphrase: Self.passphrase + " typo")
		}
		let text = fixture.folder.appending(path: "notes.lpmbackup")
		try Data("just some notes".utf8).write(to: text)
		await #expect(throws: BackupRestoreFailure.engine(.notABackup)) {
			try await fixture.store.openBackup(at: text, passphrase: Self.passphrase)
		}
		let link = fixture.folder.appending(path: "link.lpmbackup")
		try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
		await #expect(throws: BackupRestoreFailure.file(.notAFile)) {
			try await fixture.store.openBackup(at: link, passphrase: Self.passphrase)
		}
	}



	@Test("withdrawn restore keeps completed projects and cleanup but does not apply global settings",
		arguments: ["lock", "cancel", "none"])
	func settingsRespectRevocation(transition: String) async throws {
		let fixture = try fixture()
		defer {
			fixture.store.lock()
			fixture.tearDown()
		}
		fixture.store.settings.lockAfter = .thirtyMinutes
		fixture.store.settings.valueApproval = .afterFiveMinutes
		fixture.store.settings.rehide = .thirtySeconds
		fixture.store.settings.hidesFromCapture = true
		var weaker = fixture.store.settings.snapshot
		weaker.security.valueApproval = .never
		weaker.security.rehide = .never
		weaker.security.hidesFromCapture = false
		let settings = BackupAppSection.Settings(
			appearance: .dark, keySort: .descending, quitShortcut: .hold, updateChannel: .stable,
			projectOrder: ["revocation-a", "revocation-b"], environmentOrders: [:],
			preferences: .init(app: weaker, updates: .standard))
		let sync = BackupPayload.Sync(registry: "https://lpm.dev", principalId: "org_demo", scope: .organization(slug: "demo"))
		let url = try backup([
			project("revocation-a", environments: ["default": ["TOKEN": "DEMO-A"]]),
			project("revocation-b", environments: ["default": ["TOKEN": "DEMO-B"]], sync: sync),
		], app: .init(settings: settings), in: fixture.folder)
		let review = try await fixture.store.openBackup(at: url, passphrase: Self.passphrase)
		let choices = BackupRestoreChoices(included: ["revocation-a", "revocation-b"], applySettings: true)
		var completed: [String] = []
		let task = Task { @MainActor in
			try await fixture.store.restoreBackup(review, choices: choices) { item in
				completed.append(item.vaultId)
				guard item.vaultId == "revocation-a" else { return }
				if transition == "lock" { fixture.store.lock() }
				if transition == "cancel" { withUnsafeCurrentTask { $0?.cancel() } }
			}
		}
		let result = try await task.value
		let persisted = VaultSettings(defaults: fixture.defaults)
		#expect(fixture.keychain.envStorage["revocation-a"] != nil)
		if transition == "none" {
			#expect(fixture.keychain.envStorage["revocation-b"] != nil)
			#expect(persisted.valueApproval == .never)
			#expect(!persisted.hidesFromCapture)
			#expect(result.settings != nil)
		} else {
			#expect(completed == ["revocation-a"])
			#expect(fixture.keychain.envStorage["revocation-b"] == nil)
			#expect(persisted.valueApproval == .afterFiveMinutes)
			#expect(persisted.rehide == .thirtySeconds)
			#expect(persisted.hidesFromCapture)
			#expect(result.settings == nil)
			#expect(fixture.store.syncPauses["revocation-b"] == nil)
			let associations = try JSONDecoder().decode([String: String].self,
				from: fixture.keychain.dataStorage["__org_associations__"] ?? Data("{}".utf8))
			#expect(associations["revocation-b"] == nil)
		}
	}


	@Test("key restoration stops before the next item after revocation",
		arguments: ["lock", "cancel", "none"])
	func keyInstallationRespectsRevocation(transition: String) async throws {
		let backend = GatedBackupKeyBackend()
		let fixture = try fixture(keyBackend: backend)
		defer {
			fixture.store.lock()
			fixture.tearDown()
		}
		let first = String(repeating: "a", count: 64)
		let second = String(repeating: "b", count: 64)
		var keys = BackupKeys()
		keys.personalRoots = [
			.init(account: first, key: secret(String(repeating: "1", count: 64))),
			.init(account: second, key: secret(String(repeating: "2", count: 64))),
		]
		let url = try backup([project("after-keys", environments: ["default": ["TOKEN": "DEMO"]])], keys: keys, in: fixture.folder)
		let review = try await fixture.store.openBackup(at: url, passphrase: Self.passphrase)
		let choices = BackupRestoreChoices(included: ["after-keys"], applySettings: false, restoreKeys: true)
		backend.arm()
		let task = Task { @MainActor in try await fixture.store.restoreBackup(review, choices: choices) }
		do {
			try #require(try await waitUntil { backend.gate.isWaiting })
			if transition == "lock" { fixture.store.lock() }
			if transition == "cancel" { task.cancel() }
			backend.gate.release()
			let result = try await task.value
			#expect(try backend.base.read(service: BackupKeyStore.testRootService, account: first) != nil)
			if transition == "none" {
				#expect(try backend.base.read(service: BackupKeyStore.testRootService, account: second) != nil)
				#expect(fixture.keychain.envStorage["after-keys"] != nil)
				#expect(result.keys?.added == 2)
			} else {
				#expect(try backend.base.read(service: BackupKeyStore.testRootService, account: second) == nil)
				#expect(fixture.keychain.envStorage["after-keys"] == nil)
				#expect(result.keys?.added == 1)
				#expect(result.settings == nil)
			}
		} catch {
			backend.gate.release()
			_ = await task.result
			throw error
		}
	}


	@Test("queued destination writes recheck revoked backup authority", arguments: [false, true])
	func destinationAuthorityIsRechecked(revoked: Bool) async throws {
		let fixture = try fixture()
		defer {
			fixture.store.lock()
			fixture.tearDown()
		}
		let authorization = FileWriteAuthorization()
		let gate = BackupTestGate()
		fixture.keychain.beforeAppItemRead = { store, account in
			if store == .publishing, account == "destinations.backup-destination" { gate.pause() }
		}
		let destination = vercelDestination(source: "default")
		let task = Task { await fixture.store.publishing.save(destination, to: "backup-destination", authorization: authorization) }
		do {
			try #require(try await waitUntil { gate.isWaiting })
			if revoked { authorization.invalidate() }
			gate.release()
			let result = await task.value
			fixture.keychain.beforeAppItemRead = nil
			let saved = try await fixture.store.publishing.destinations(of: "backup-destination").get()
			if revoked {
				#expect(result == .failure(.cancelled))
				#expect(saved.isEmpty)
			} else {
				#expect(saved == [destination])
			}
		} catch {
			gate.release()
			_ = await task.value
			throw error
		}
	}

	@Test("restored icons require current backup authority", arguments: [false, true])
	func iconAuthorityIsChecked(revoked: Bool) async throws {
		let fixture = try fixture()
		defer {
			fixture.store.lock()
			fixture.tearDown()
		}
		let authorization = FileWriteAuthorization()
		if revoked { authorization.invalidate() }
		let restored = await fixture.store.projectIcons.restore(.choice(.emoji("🚀")), for: "backup-icon", authorization: authorization)
		#expect(restored == !revoked)
		#expect(fixture.store.projectIcons.savedChoices(for: ["backup-icon"]).isEmpty == revoked)
	}

	@Test("revoked image restore removes its prepared PNG and never publishes its choice", arguments: [false, true])
	func restoredImageRespectsRevocation(revoked: Bool) async throws {
		let fixture = try fixture()
		defer { fixture.tearDown() }
		let gate = BackupTestGate()
		let directory = fixture.folder.appending(path: "restored-icons", directoryHint: .isDirectory)
		let icons = ProjectIconStore(preferences: fixture.defaults, imagesDirectory: directory,
			prepareRestoredImage: { name, png, directory, authorization in
				let choice = ProjectIconStore.prepareRestoredImage(name, png, directory, authorization)
				gate.pause()
				return choice
			})
		let authorization = FileWriteAuthorization()
		let png = try ProjectIconFixture.png(red: 255, green: 0, blue: 0)
		let task = Task { await icons.restore(.image(name: "demo.png", png: png), for: "image-project", authorization: authorization) }
		do {
			try #require(try await waitUntil { gate.isWaiting })
			#expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == 1)
			if revoked { authorization.invalidate() }
			gate.release()
			#expect(await task.value == !revoked)
			await icons.waitForFileWork()
			#expect(icons.savedChoices(for: ["image-project"]).isEmpty == revoked)
			#expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == (revoked ? 0 : 1))
		} catch {
			gate.release()
			_ = await task.value
			await icons.waitForFileWork()
			throw error
		}
	}

	@Test("organization preparation queued before revocation writes nothing", arguments: ["lock", "cancel", "none"])
	func organizationPreparationRespectsRevocation(transition: String) async throws {
		let fixture = try fixture()
		defer {
			fixture.store.lock()
			fixture.tearDown()
		}
		let sync = BackupPayload.Sync(registry: "https://lpm.dev", principalId: "org_demo", scope: .organization(slug: "demo"))
		let url = try backup([project("queued-org", environments: ["default": ["TOKEN": "DEMO"]], sync: sync)], in: fixture.folder)
		let review = try await fixture.store.openBackup(at: url, passphrase: Self.passphrase)
		let gate = BackupTestGate()
		fixture.keychain.beforeKeychainTransaction = { gate.pause() }
		let task = Task { @MainActor in
			try await fixture.store.restoreBackup(review, choices: .init(included: ["queued-org"], applySettings: false))
		}
		do {
			try #require(try await waitUntil { gate.isWaiting })
			if transition == "lock" { fixture.store.lock() }
			if transition == "cancel" { task.cancel() }
			gate.release()
			_ = try await task.value
			#expect(fixture.keychain.dataWriteCounts["__org_associations__", default: 0] == (transition == "none" ? 1 : 0))
			#expect((fixture.keychain.envStorage["queued-org"] != nil) == (transition == "none"))
		} catch {
			gate.release()
			_ = await task.result
			throw error
		}
	}

	@Test("an admitted project may finish after revocation but later projects and settings stop",
		arguments: ["lock", "cancel"])
	func admittedProjectFinishes(transition: String) async throws {
		let fixture = try fixture()
		defer {
			fixture.store.lock()
			fixture.tearDown()
		}
		fixture.store.settings.hidesFromCapture = true
		var weaker = VaultSettings.standard
		weaker.security.hidesFromCapture = false
		let settings = BackupAppSection.Settings(appearance: .dark, keySort: .descending, quitShortcut: .hold,
			updateChannel: .stable, projectOrder: [], environmentOrders: [:], preferences: .init(app: weaker, updates: .standard))
		let sync = BackupPayload.Sync(registry: "https://lpm.dev", principalId: "org_demo", scope: .organization(slug: "demo"))
		let url = try backup([
			project("admitted-a", environments: ["default": ["TOKEN": "DEMO-A"]], sync: sync),
			project("admitted-b", environments: ["default": ["TOKEN": "DEMO-B"]], sync: sync),
		], app: .init(settings: settings), in: fixture.folder)
		let review = try await fixture.store.openBackup(at: url, passphrase: Self.passphrase)
		let gate = BackupTestGate()
		fixture.keychain.beforeRestoredProjectWrite = { project in if project.id == "admitted-a" { gate.pause() } }
		let task = Task { @MainActor in
			try await fixture.store.restoreBackup(review, choices: .init(included: ["admitted-a", "admitted-b"], applySettings: true))
		}
		do {
			try #require(try await waitUntil { gate.isWaiting })
			if transition == "lock" { fixture.store.lock() } else { task.cancel() }
			gate.release()
			let result = try await task.value
			#expect(fixture.keychain.envStorage["admitted-a"] != nil)
			#expect(fixture.keychain.envStorage["admitted-b"] == nil)
			#expect(Set(VaultSyncPause.load(from: fixture.defaults).keys) == ["admitted-a"])
			let associations = try JSONDecoder().decode([String: String].self,
				from: fixture.keychain.dataStorage["__org_associations__"] ?? Data("{}".utf8))
			#expect(associations == ["admitted-a": "demo"])
			#expect(VaultSettings(defaults: fixture.defaults).hidesFromCapture)
			#expect(result.settings == nil)
			#expect(!fixture.store.isWriting)
		} catch {
			gate.release()
			_ = await task.result
			throw error
		}
	}

	@Test("a merge keeps this Mac's keys, adds the backup's, and replaces only the chosen ones")
	func mergedValues() {
		let backup = ["default": ["A": "b", "B": "b"], "new": ["C": "c"]]
		let local = ["default": ["A": "l", "L": "l"]]
		let replaceA = BackupRestorePlan.KeyDifference(environment: "default", key: "A")
		#expect(BackupRestorePlan.merged(backup, into: local, replacing: []) == ["default": ["A": "l", "B": "b", "L": "l"], "new": ["C": "c"]])
		#expect(BackupRestorePlan.merged(backup, into: local, replacing: [replaceA])["default"]?["A"] == "b")
		#expect(BackupRestorePlan.status(["default": [:], "extra": [:]], against: ["default": [:]]) == .merge(added: 0, differing: []))
		#expect(BackupRestorePlan.status(["default": ["A": "1"]], against: ["default": ["A": "1"], "mine": [:]]) == .identical)
	}
}
