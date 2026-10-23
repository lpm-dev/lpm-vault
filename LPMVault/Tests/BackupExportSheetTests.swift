import AppKit
import SwiftUI
import Testing

@testable import LPMVault

extension SheetInteractionTests {
	@Suite("Backup export sheet", .serialized) @MainActor struct BackupExportSheetTests {
		private static let strong = "harbor velvet ninety cactus orbit maple"

		private struct Fixture {
			let store: VaultStore
			let biometric: MockBiometricService
			let folder: URL

			var destination: URL { folder.appending(path: "LPM Vault.lpmbackup") }

			func tearDown() {
				try? FileManager.default.removeItem(at: folder)
				UserDefaults().removePersistentDomain(forName: folder.lastPathComponent)
			}
		}

		private func fixture() async throws -> Fixture {
			let folder = FileManager.default.temporaryDirectory.appending(path: "lpm-backup-sheet-\(UUID().uuidString)", directoryHint: .isDirectory)
			try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
			let defaults = try #require(UserDefaults(suiteName: folder.lastPathComponent))
			let keychain = MockKeychainService()
			let environments = ["default": ["TOKEN": "a", "URL": "https://x"]]
			keychain.envStorage["vault-a"] = (name: "api", path: "/tmp/api", environments: environments)
			let biometric = MockBiometricService()
			let store = VaultStore(
				keychainService: keychain, biometricService: biometric, apiService: MockAPIService(), preferences: defaults,
				projectIconsDirectory: folder.appending(path: "icons", directoryHint: .isDirectory))
			store.projects = [VaultProject(id: "vault-a", name: "api", path: "/tmp/api", environments: environments)]
			store.isUnlocked = true
			_ = try await store.publishing.save(vercelDestination(source: "default"), to: "vault-a").get()
			return Fixture(store: store, biometric: biometric, folder: folder)
		}

		private func host(_ fixture: Fixture, chosen: @escaping @MainActor (String) -> URL? = { _ in nil }) -> SheetTestHost<BackupExportSheet> {
			SheetTestHost(BackupExportSheet(store: fixture.store, chooseDestination: chosen), size: NSSize(width: 560, height: 760))
		}

		private func element(_ label: String, in window: NSWindow) -> AccessibilityTree.Element? {
			guard let content = window.contentView else { return nil }
			content.layoutSubtreeIfNeeded()
			return AccessibilityTree.visibleElements(in: window, of: content).first { $0.isInteractive && $0.says(label, as: .leading) }
		}

		@Test("the sheet lists what a backup holds, and Export waits for a strong passphrase typed twice")
		func strengthAndConfirmation() async throws {
			let fixture = try await fixture()
			defer { fixture.tearDown() }
			let host = host(fixture)
			defer { host.window.close() }
			try await host.settle()
			for text in ["Export backup", "What’s included", "Projects & values", "Always included", "1 project · 2 keys",
				"Publish destinations", "1 destination", "Settings & icons", "platform logins aren’t included",
				"A lost passphrase can’t be recovered.", "Touch ID confirms, then you choose where to save"]
			{
				#expect(try await host.waitForText(text), "The sheet says \(text)")
			}
			#expect(element("Export…", in: host.window)?.isEnabled == false)
			#expect(element("Publish destinations", in: host.window)?.isOn == true)
			try await host.click("Publish destinations")
			#expect(try await host.waitUntil { element("Publish destinations", in: host.window)?.isOn == false }, "Each optional item can be left out")

			try host.enterValue("password123", at: 0)
			try host.enterValue("password123", at: 1)
			_ = try await host.waitForElement(saying: "Passphrase strength: Weak")
			#expect(element("Export…", in: host.window)?.isEnabled == false, "A weak passphrase can't seal a backup")

			try host.enterValue(Self.strong, at: 0)
			#expect(try await host.waitForText("The passphrases don’t match."))
			try host.enterValue(Self.strong, at: 1)
			_ = try await host.waitForElement(saying: "Passphrase strength: Strong")
			#expect(try await host.waitUntil { element("Export…", in: host.window)?.isEnabled == true })
			#expect(try await host.waitForTextToDisappear("The passphrases don’t match."))
		}

		@Test("Generate fills both fields with six words, shown with Copy, and the backup it seals is saved where chosen")
		func generateAndExport() async throws {
			let fixture = try await fixture()
			defer { fixture.tearDown() }
			var offered: String?
			let host = host(fixture) { name in
				offered = name
				return fixture.destination
			}
			defer { host.window.close() }
			try await host.settle()
			try await host.click("Generate")
			_ = try await host.waitForElement(saying: "Copy passphrase")
			#expect(element("Passphrase strength", in: host.window) == nil, "Generated passphrases show their words, not a meter")
			#expect(try await host.waitUntil { element("Export…", in: host.window)?.isEnabled == true })

			try await host.click("Export…")
			#expect(try await host.waitForText("Backup exported"))
			#expect(fixture.biometric.confirmationReasons == ["export a backup of your env projects"])
			#expect(offered?.hasPrefix("LPM Vault ") == true && offered?.hasSuffix(".lpmbackup") == true)
			for text in ["LPM Vault.lpmbackup", "1 project, 1 destination, settings", "Show in Finder",
				"Encrypted with your passphrase.", "Last backup is now shown in Settings."]
			{
				#expect(try await host.waitForText(text), "The done state says \(text)")
			}
			#expect(FileManager.default.fileExists(atPath: fixture.destination.path))
			#expect(fixture.store.lastBackup != nil)
		}

		@Test("a cancelled Touch ID prompt leaves the sheet as it was and asks for no file")
		func cancelledAuthentication() async throws {
			let fixture = try await fixture()
			defer { fixture.tearDown() }
			fixture.biometric.shouldSucceed = false
			var asked = false
			let host = host(fixture) { _ in
				asked = true
				return fixture.destination
			}
			defer { host.window.close() }
			try await host.settle()
			try host.enterValue(Self.strong, at: 0)
			try host.enterValue(Self.strong, at: 1)
			#expect(try await host.waitUntil { element("Export…", in: host.window)?.isEnabled == true })
			try await host.click("Export…")
			#expect(try await host.waitUntil { fixture.biometric.confirmationReasons.count == 1 })
			#expect(try await host.waitUntil { element("Export…", in: host.window)?.isEnabled == true }, "The sheet can export again")
			#expect(!asked)
			#expect(!FileManager.default.fileExists(atPath: fixture.destination.path))
		}

		@Test("Settings says when the last backup was made")
		func settingsSection() async throws {
			let fixture = try await fixture()
			defer { fixture.tearDown() }
			let section = SheetTestHost(VaultBackupSettingsSection(store: fixture.store) {}, size: NSSize(width: 640, height: 200))
			defer { section.window.close() }
			try await section.settle()
			for text in ["Your Keychain data stays on this Mac", "Export backup…", "No backup yet"] {
				#expect(try await section.waitForText(text), "The section says \(text)")
			}
			let authorization = try #require(await fixture.store.authorizeBackupExport())
			let result = try await fixture.store.exportBackup(.init(), passphrase: Self.strong, to: fixture.destination, authorization: authorization)
			let size = ByteCountFormatter.string(fromByteCount: Int64(result.bytes), countStyle: .file)
			#expect(try await section.waitForText("Last backup"))
			#expect(try await section.waitForText(size))
		}
	}
}
