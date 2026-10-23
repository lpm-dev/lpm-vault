import AppKit
import SwiftUI
import Testing

@testable import LPMVault

extension SheetInteractionTests {
	@Suite("Backup restore sheet", .serialized) @MainActor struct BackupRestoreSheetTests {
		private static let passphrase = "harbor velvet ninety cactus orbit maple"

		private struct Fixture {
			let store: VaultStore
			let keychain: MockKeychainService
			let defaults: UserDefaults
			let folder: URL

			func tearDown() {
				try? FileManager.default.removeItem(at: folder)
				defaults.removePersistentDomain(forName: folder.lastPathComponent)
			}
		}

		private func fixture(_ local: [String: [String: [String: String]]] = [:], pauses: [String: VaultSyncPause] = [:]) throws -> Fixture {
			let folder = FileManager.default.temporaryDirectory.appending(path: "lpm-restore-sheet-\(UUID().uuidString)", directoryHint: .isDirectory)
			try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
			let defaults = try #require(UserDefaults(suiteName: folder.lastPathComponent))
			VaultSyncPause.save(pauses, to: defaults)
			let keychain = MockKeychainService()
			for (id, environments) in local { keychain.envStorage[id] = (name: id, path: "", environments: environments) }
			let store = VaultStore(
				keychainService: keychain, biometricService: MockBiometricService(), apiService: MockAPIService(), preferences: defaults,
				projectIconsDirectory: folder.appending(path: "icons", directoryHint: .isDirectory),
				backupKeys: .inMemory(InMemoryKeychainBackend(), home: try testLPMHome(in: folder)))
			store.projects = local.keys.sorted().map { VaultProject(id: $0, name: $0, path: "", environments: local[$0] ?? [:]) }
			store.isUnlocked = true
			return Fixture(store: store, keychain: keychain, defaults: defaults, folder: folder)
		}

		private func backup(_ projects: [BackupPayload.Project], in folder: URL) throws -> URL {
			let payload = BackupPayload(
				createdAt: Date(timeIntervalSince1970: 1_761_171_075), producerVersion: "1.0.2", deviceName: "Studio", projects: projects, app: nil)
			let file = try BackupEngine.seal(payload: try #require(payload.encoded()).bytes, passphrase: Self.passphrase).get()
			let url = folder.appending(path: "LPM Vault 2026-10-21.lpmbackup")
			try file.write(to: url)
			return url
		}

		private func project(_ id: String, folder: String? = nil, environments: [String: [String: String]], sync: BackupPayload.Sync? = nil) -> BackupPayload.Project {
			.init(vaultId: id, name: id, folder: folder, hidden: false, cliAccess: .automatic, environments: environments, sync: sync)
		}

		private func element(_ label: String, in window: NSWindow) -> AccessibilityTree.Element? {
			guard let content = window.contentView else { return nil }
			content.layoutSubtreeIfNeeded()
			return AccessibilityTree.visibleElements(in: window, of: content).first { $0.isInteractive && $0.says(label, as: .leading) }
		}

		private func host(_ fixture: Fixture, file: URL) -> SheetTestHost<BackupRestoreSheet> {
			SheetTestHost(BackupRestoreSheet(store: fixture.store, chooseFile: { file }), size: NSSize(width: 600, height: 760))
		}

		@Test("the passphrase field waits for a file, and a wrong passphrase says there's no limit on attempts")
		func wrongPassphrase() async throws {
			let fixture = try fixture()
			defer { fixture.tearDown() }
			let url = try backup([project("fresh", environments: ["default": ["TOKEN": "a"]])], in: fixture.folder)
			let host = host(fixture, file: url)
			defer { host.window.close() }
			try await host.settle()
			for text in ["Restore from backup", "Nothing is written until you review what comes in.", "Choose a .lpmbackup file or drop it here",
				"The file is decrypted on this Mac only"]
			{
				#expect(try await host.waitForText(text), "The sheet says \(text)")
			}
			#expect(element("Continue", in: host.window)?.isEnabled == false)
			try await host.click("Choose…")
			#expect(try await host.waitForText("LPM Vault 2026-10-21.lpmbackup"))
			try host.enterValue("not the passphrase", at: 0)
			#expect(try await host.waitUntil { element("Continue", in: host.window)?.isEnabled == true })
			try await host.click("Continue")
			#expect(try await host.waitForText("That passphrase doesn’t open this file. Check it and try again — there’s no limit on attempts."))
		}

		@Test("the review lists new and already-here projects with per-key choices, and the summary says what each became")
		func reviewAndRestore() async throws {
			let fixture = try fixture(["shared": ["default": ["A": "1", "B": "2"]]])
			defer { fixture.tearDown() }
			let url = try backup([
				project("fresh", environments: ["default": ["TOKEN": "a"]], sync: .init(registry: "https://lpm.dev", principalId: "usr_1", scope: .personal)),
				project("shared", environments: ["default": ["A": "1", "B": "9"]]),
			], in: fixture.folder)
			let host = host(fixture, file: url)
			defer { host.window.close() }
			try await host.settle()
			try await host.click("Choose…")
			try host.enterValue(Self.passphrase, at: 0)
			#expect(try await host.waitUntil { element("Continue", in: host.window)?.isEnabled == true })
			try await host.click("Continue")
			#expect(try await host.waitForText("Review what comes in"))
			for text in ["1 new", "1 already here", "Values hidden", "Made on Studio", "fresh", "syncs with lpm.dev — paused: this Mac doesn’t have its key",
				"shared", "1 key differs — choose per key", "Platform logins aren’t in backups.", "Touch ID or your Mac password, just before writing"]
			{
				#expect(try await host.waitForText(text), "The review says \(text)")
			}
			try await host.click("Show keys")
			#expect(try await host.waitForText("B"))
			try await host.click("Replace")
			try await host.click("Restore 2 items")
			#expect(try await host.waitForText("Restore finished"))
			for text in ["1 restored", "1 merged", "Restored · 1 key · 1 env · needs a folder", "Merged · 0 keys added, 1 replaced",
				"1 synced project keeps sync paused: this Mac doesn’t have its keys."]
			{
				#expect(try await host.waitForText(text), "The summary says \(text)")
			}
			#expect(fixture.keychain.envStorage["fresh"]?.environments == ["default": ["TOKEN": "a"]])
			#expect(fixture.keychain.envStorage["shared"]?.environments["default"]?["B"] == "9")
		}

		@Test("Use this folder appears when the backup's folder links the project, and the restored project keeps it")
		func useThisFolder() async throws {
			let fixture = try fixture()
			defer { fixture.tearDown() }
			let projectFolder = fixture.folder.appending(path: "fresh", directoryHint: .isDirectory)
			try FileManager.default.createDirectory(at: projectFolder, withIntermediateDirectories: true)
			try Data(#"{"vault":"fresh"}"#.utf8).write(to: projectFolder.appending(path: "lpm.json"))
			let url = try backup([project("fresh", folder: projectFolder.path, environments: ["default": ["TOKEN": "a"]])], in: fixture.folder)
			let host = host(fixture, file: url)
			defer { host.window.close() }
			try await host.settle()
			try await host.click("Choose…")
			try host.enterValue(Self.passphrase, at: 0)
			#expect(try await host.waitUntil { element("Continue", in: host.window)?.isEnabled == true })
			try await host.click("Continue")
			#expect(try await host.waitForElement(saying: "Use this folder").isEnabled)
			try await host.click("Use this folder")
			#expect(try await host.waitForElement(saying: "Change…").isEnabled)
			try await host.click("Restore 1 item")
			#expect(try await host.waitForText("Restore finished"))
			#expect(fixture.keychain.envStorage["fresh"]?.path == projectFolder.path)
		}

		@Test("a Mac with no projects welcomes with a link to restore a backup")
		func welcome() async throws {
			var restored = false
			let host = SheetTestHost(
				VaultWorkspaceEmptyView(isSearching: false, hasProjects: false, onCreate: {}, onImport: {}, onRestore: { restored = true }),
				size: NSSize(width: 700, height: 460))
			defer { host.window.close() }
			try await host.settle()
			for text in ["Welcome to LPM Vault", "Create project", "Restore from a backup", "Moving from another Mac?"] {
				#expect(try await host.waitForText(text), "The welcome says \(text)")
			}
			try await host.click("Restore from a backup")
			#expect(try await host.waitUntil { restored })
		}

		@Test("a project whose sync a restore paused says so above its values")
		func pausedBanner() async throws {
			let pause = VaultSyncPause(.init(registry: "https://lpm.dev", principalId: "usr_1", scope: .personal), restoredAt: Date())
			let fixture = try fixture(["paused": ["default": ["TOKEN": "a"]]], pauses: ["paused": pause])
			defer { fixture.tearDown() }
			fixture.store.openProject(id: "paused")
			let host = SheetTestHost(ContentView(store: fixture.store).environment(UpdateChecker())
				.environment(VaultAppearanceSettings(defaults: fixture.defaults)).environment(VaultQuitSettings(defaults: fixture.defaults)),
				size: NSSize(width: 1100, height: 700), keepsRequestedSize: true)
			defer { host.window.close() }
			try await host.settle()
			#expect(try await host.waitForText("Sync paused: keys not recovered · values work locally"))
		}
	}
}
