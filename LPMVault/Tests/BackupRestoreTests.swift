import Foundation
import Testing

@testable import LPMVault

@Suite("Backup restore", .serialized)
@MainActor
struct BackupRestoreTests {
	private static let passphrase = "harbor velvet ninety cactus orbit maple"

	private struct Fixture {
		let store: VaultStore
		let keychain: MockKeychainService
		let biometric: MockBiometricService
		let defaults: UserDefaults
		let folder: URL

		func tearDown() {
			try? FileManager.default.removeItem(at: folder)
			defaults.removePersistentDomain(forName: folder.lastPathComponent)
		}
	}

	/// A store on a Mac holding `local` projects, listed in its sidebar.
	private func fixture(_ local: [String: [String: [String: String]]] = [:]) throws -> Fixture {
		let folder = FileManager.default.temporaryDirectory.appending(path: "lpm-backup-restore-\(UUID().uuidString)", directoryHint: .isDirectory)
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		let defaults = try #require(UserDefaults(suiteName: folder.lastPathComponent))
		let keychain = MockKeychainService()
		for (id, environments) in local { keychain.envStorage[id] = (name: id, path: "", environments: environments) }
		let biometric = MockBiometricService()
		let store = VaultStore(
			keychainService: keychain, biometricService: biometric, apiService: MockAPIService(), preferences: defaults,
			projectIconsDirectory: folder.appending(path: "icons", directoryHint: .isDirectory))
		store.projects = local.keys.sorted().map { VaultProject(id: $0, name: $0, path: "", environments: local[$0] ?? [:]) }
		store.isUnlocked = true
		return Fixture(store: store, keychain: keychain, biometric: biometric, defaults: defaults, folder: folder)
	}

	private func project(
		_ id: String, hidden: Bool = false, folder: String? = nil, environments: [String: [String: String]],
		sync: BackupPayload.Sync? = nil
	) -> BackupPayload.Project {
		.init(vaultId: id, name: id, folder: folder, hidden: hidden, cliAccess: .automatic, environments: environments, sync: sync)
	}

	/// A backup file of `projects`, sealed by the engine.
	private func backup(_ projects: [BackupPayload.Project], app: BackupAppSection? = nil, in folder: URL) throws -> URL {
		let payload = BackupPayload(
			createdAt: Date(timeIntervalSince1970: 1_761_171_075), producerVersion: "1.0.2", deviceName: "Studio", projects: projects, app: app)
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
		let settings = BackupAppSection.Settings(
			appearance: .dark, keySort: .descending, quitShortcut: .hold, updateChannel: .stable,
			projectOrder: ["synced"], environmentOrders: ["synced": ["staging", "default"]])
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
		#expect(fixture.store.environmentOrders["synced"] == ["staging", "default"])

		fixture.store.openProject(id: "synced")
		await fixture.store.pushToCloud()
		#expect(fixture.store.error?.hasPrefix("Sync is paused for synced") == true)
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
