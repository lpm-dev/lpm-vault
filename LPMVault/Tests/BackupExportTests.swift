import AppKit
import Foundation
import Testing

@testable import LPMVault

@Suite("Backup export", .serialized)
@MainActor
struct BackupExportTests {
	private static let passphrase = "harbor velvet ninety cactus orbit maple"

	private struct Fixture {
		let store: VaultStore
		let keychain: MockKeychainService
		let biometric: MockBiometricService
		let defaults: UserDefaults
		let folder: URL

		var destination: URL { folder.appending(path: "LPM Vault.lpmbackup") }

		func tearDown() {
			try? FileManager.default.removeItem(at: folder)
			defaults.removePersistentDomain(forName: folder.lastPathComponent)
		}
	}

	private func fixture() throws -> Fixture {
		let folder = FileManager.default.temporaryDirectory.appending(path: "lpm-backup-export-\(UUID().uuidString)", directoryHint: .isDirectory)
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		let defaults = try #require(UserDefaults(suiteName: folder.lastPathComponent))
		let keychain = MockKeychainService()
		let environments: [String: [String: String]] = ["default": ["TOKEN": "a"], "staging": ["TOKEN": "b", "URL": "https://x"]]
		keychain.envStorage["vault-a"] = (name: "api", path: "/tmp/api", environments: environments)
		keychain.cliAccessPolicies["vault-a"] = .requireApproval
		keychain.hiddenPayloads["vault-hidden"] = ["default": ["OLD": "x"]]
		let biometric = MockBiometricService()
		let store = VaultStore(
			keychainService: keychain,
			biometricService: biometric,
			apiService: MockAPIService(),
			preferences: defaults,
			projectIconsDirectory: folder.appending(path: "icons", directoryHint: .isDirectory))
		store.projects = [VaultProject(id: "vault-a", name: "api", path: "/tmp/api", environments: environments)]
		store.isUnlocked = true
		return Fixture(store: store, keychain: keychain, biometric: biometric, defaults: defaults, folder: folder)
	}

	/// The payload a saved backup holds.
	private func opened(_ file: URL) throws -> LPMConfigJSON {
		let payload = try BackupEngine.open(try Data(contentsOf: file), passphrase: Self.passphrase).get()
		return try payload.withUnsafeBytes { try LPMConfigJSON(parsing: Data($0), rejectDuplicateKeys: true) }
	}

	private func projects(_ payload: LPMConfigJSON) -> [String: LPMConfigJSON] {
		guard case .array(let projects)? = payload["projects"] else { return [:] }
		return Dictionary(uniqueKeysWithValues: projects.compactMap { project in
			guard case .string(let id)? = project["vaultId"] else { return nil }
			return (id, project)
		})
	}

	@Test("a backup carries every project, removed ones too, with values, CLI approval, and the app's settings, icons and destinations")
	func everything() async throws {
		let fixture = try fixture()
		defer { fixture.tearDown() }
		let store = fixture.store
		fixture.defaults.set(VaultAppearance.dark.rawValue, forKey: VaultAppearanceSettings.defaultsKey)
		fixture.defaults.set(VaultKeySortOrder.descending.rawValue, forKey: VaultKeySortOrder.defaultsKey)
		fixture.defaults.set(VaultQuitShortcut.hold.rawValue, forKey: VaultQuitShortcut.defaultsKey)
		fixture.defaults.set(VaultReleaseChannel.nightly.rawValue, forKey: UpdateChecker.channelDefaultsKey)
		store.saveEnvironmentOrder(for: "vault-a", order: ["staging", "default"])
		#expect(store.projectIcons.save(.emoji("🚀"), for: "vault-a"))
		let destination = vercelDestination(source: "default")
		_ = try await store.publishing.save(destination, to: "vault-a").get()

		let authorization = try #require(await store.authorizeBackupExport())
		let result = try await store.exportBackup(.init(), passphrase: Self.passphrase, to: fixture.destination, authorization: authorization)

		#expect(fixture.biometric.confirmationReasons == ["export a backup of your env projects"])
		let attributes = try FileManager.default.attributesOfItem(atPath: fixture.destination.path)
		#expect((attributes[.posixPermissions] as? Int) == 0o600)
		#expect(result.bytes == (attributes[.size] as? Int))
		#expect(result.summary == .init(projects: 1, removedProjects: 1, keys: 4, destinations: 1, settings: true, unusableItems: 0))

		let payload = try opened(fixture.destination)
		let projects = projects(payload)
		#expect(projects["vault-a"]?["name"] == .string("api"))
		#expect(projects["vault-a"]?["folder"] == .string("/tmp/api"))
		#expect(projects["vault-a"]?["hidden"] == .bool(false))
		#expect(projects["vault-a"]?["cliAccess"] == .string("requireApproval"))
		#expect(projects["vault-a"]?["environments"]?["staging"]?["URL"] == .string("https://x"))
		#expect(projects["vault-hidden"]?["name"] == .string("vault-hidden"))
		#expect(projects["vault-hidden"]?["folder"] == nil)
		#expect(projects["vault-hidden"]?["hidden"] == .bool(true))
		#expect(projects["vault-hidden"]?["environments"]?["default"]?["OLD"] == .string("x"))

		let app = try BackupAppSection(json: try #require(payload["app"]))
		#expect(app.settings == .init(
			appearance: .dark, keySort: .descending, quitShortcut: .hold, updateChannel: .nightly,
			projectOrder: ["vault-a"], environmentOrders: ["vault-a": ["staging", "default"]]))
		#expect(app.icons == ["vault-a": .choice(.emoji("🚀"))])
		#expect(app.destinations == ["vault-a": [destination]])

		#expect(store.lastBackup?.bytes == result.bytes)
		#expect(VaultBackupRecord(defaults: fixture.defaults) == store.lastBackup)
	}

	@Test("without destinations, settings and icons, a backup carries only the projects")
	func projectsOnly() async throws {
		let fixture = try fixture()
		defer { fixture.tearDown() }
		_ = try await fixture.store.publishing.save(vercelDestination(source: "default"), to: "vault-a").get()
		let authorization = try #require(await fixture.store.authorizeBackupExport())
		let result = try await fixture.store.exportBackup(
			.init(destinations: false, settingsAndIcons: false), passphrase: Self.passphrase,
			to: fixture.destination, authorization: authorization)
		#expect(try opened(fixture.destination)["app"] == nil)
		#expect(result.summary.destinations == 0)
		#expect(!result.summary.settings)
	}

	@Test("a backup needs authenticating, and nothing is saved once the vault locks after")
	func authorization() async throws {
		let fixture = try fixture()
		defer { fixture.tearDown() }
		fixture.biometric.shouldSucceed = false
		#expect(await fixture.store.authorizeBackupExport() == nil)
		fixture.biometric.shouldSucceed = true
		let authorization = try #require(await fixture.store.authorizeBackupExport())
		fixture.store.lock()
		await #expect(throws: CancellationError.self) {
			try await fixture.store.exportBackup(.init(), passphrase: Self.passphrase, to: fixture.destination, authorization: authorization)
		}
		#expect(!FileManager.default.fileExists(atPath: fixture.destination.path))
		#expect(fixture.store.lastBackup == nil)
	}

	@Test("a backup that can't read every project saves nothing")
	func unreadable() async throws {
		let fixture = try fixture()
		defer { fixture.tearDown() }
		fixture.keychain.failBackupInventory = true
		let authorization = try #require(await fixture.store.authorizeBackupExport())
		await #expect(throws: BackupExporter.Failure.unreadableProjects) {
			try await fixture.store.exportBackup(.init(), passphrase: Self.passphrase, to: fixture.destination, authorization: authorization)
		}
		#expect(!FileManager.default.fileExists(atPath: fixture.destination.path))
	}

	@Test("a project the CLI couldn't store is named when the engine refuses it")
	func tooLarge() async throws {
		let fixture = try fixture()
		defer { fixture.tearDown() }
		fixture.keychain.envStorage["vault-a"]?.environments = ["default": ["BIG": String(repeating: "x", count: 110 * 1024)]]
		let authorization = try #require(await fixture.store.authorizeBackupExport())
		let error = await #expect(throws: BackupExporter.Failure.self) {
			try await fixture.store.exportBackup(.init(), passphrase: Self.passphrase, to: fixture.destination, authorization: authorization)
		}
		#expect(error == .invalidProject(name: "api", reason: "project_too_large"))
		#expect(error?.message.hasPrefix("api is larger than the LPM CLI can store") == true)
	}

	@Test("a project syncs in a backup when its binding names a principal, and an organization's needs its slug")
	func sync() {
		let personal = SyncPrincipalBinding(registryURL: "https://lpm.dev", principalID: "usr_1", scope: "personal")
		let organization = SyncPrincipalBinding(registryURL: "https://lpm.dev", principalID: "org_1", scope: "organization")
		func metadata(_ binding: SyncPrincipalBinding) -> SyncMetadata {
			SyncMetadata(lastSyncedAt: Date(timeIntervalSince1970: 1_760_000_000), lastAction: "push", lastVersion: 3, binding: binding)
		}
		#expect(BackupExporter.sync(metadata(personal), orgSlug: nil) == .init(registry: "https://lpm.dev", principalId: "usr_1", scope: .personal))
		#expect(BackupExporter.sync(metadata(organization), orgSlug: "acme")
			== .init(registry: "https://lpm.dev", principalId: "org_1", scope: .organization(slug: "acme")))
		#expect(BackupExporter.sync(metadata(organization), orgSlug: nil) == nil)
		#expect(BackupExporter.sync(metadata(organization), orgSlug: "-bad") == nil)
		#expect(BackupExporter.sync(nil, orgSlug: nil) == nil)
		let unbound = SyncPrincipalBinding(registryURL: "https://lpm.dev/", principalID: "usr_1", scope: "personal")
		#expect(BackupExporter.sync(metadata(unbound), orgSlug: nil) == nil)
	}

	@Test("a copied icon is carried as the PNG LPM Vault keeps; one that can't be read stays out")
	func icons() throws {
		let folder = FileManager.default.temporaryDirectory.appending(path: "lpm-backup-icons-\(UUID().uuidString)", directoryHint: .isDirectory)
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: folder) }
		let image = NSImage(size: NSSize(width: 300, height: 300), flipped: false) { rect in
			NSColor.systemRed.setFill()
			rect.fill()
			return true
		}
		let tiff = try #require(image.tiffRepresentation)
		let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
		let file = UUID().uuidString + ".png"
		try png.write(to: folder.appending(path: file))

		let icons = BackupExporter.icons([
			"copied": .storedImage(file: file, name: "logo.png"),
			"missing": .storedImage(file: UUID().uuidString + ".png", name: "gone.png"),
			"symbol": .symbol("bolt.fill", .blue),
			"automatic": .automatic,
		], imagesDirectory: folder)

		#expect(icons.keys.sorted() == ["copied", "symbol"])
		#expect(icons["symbol"] == .choice(.symbol("bolt.fill", .blue)))
		guard case .image(let name, let kept)? = icons["copied"] else {
			Issue.record("the copied image isn't carried")
			return
		}
		#expect(name == "logo.png")
		#expect(NSBitmapImageRep(data: kept)?.pixelsWide == ProjectIconRenderer.storedPixels)
	}
}
