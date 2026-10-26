import AppKit
import SwiftUI
import Testing

@testable import LPMVault

extension SheetInteractionTests {
	@Suite("Companion banner", .serialized) @MainActor struct CompanionBannerTests {
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

		/// An unlocked store showing `project`, whose newer data is `marker`, as
		/// a snapshot reads it.
		private func fixture(marker: String, inventory: [String]? = nil) async throws -> Fixture {
			let folder = FileManager.default.temporaryDirectory.appending(path: "lpm-companion-banner-\(UUID().uuidString)", directoryHint: .isDirectory)
			try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
			let defaults = try #require(UserDefaults(suiteName: folder.lastPathComponent))
			let keychain = MockKeychainService()
			keychain.envStorage["project"] = (name: "Project", path: "", environments: ["default": ["TOKEN": "a"]])
			keychain.companionStates["project"] = try CompanionEngine.assess(
				vaultId: "project", .init(marker: Data(marker.utf8), inventory: inventory))
			let store = VaultStore(
				keychainService: keychain, biometricService: MockBiometricService(), apiService: MockAPIService(), preferences: defaults,
				projectIconsDirectory: folder.appending(path: "icons", directoryHint: .isDirectory),
				backupKeys: .inMemory(InMemoryKeychainBackend(), home: try testLPMHome(in: folder)))
			store.isUnlocked = true
			#expect(await store.loadProjects())
			store.openProject(id: "project")
			return Fixture(store: store, keychain: keychain, defaults: defaults, folder: folder)
		}

		private func workspace(_ fixture: Fixture) -> SheetTestHost<some View> {
			SheetTestHost(ContentView(store: fixture.store).environment(UpdateChecker())
				.environment(VaultAppearanceSettings(defaults: fixture.defaults)).environment(VaultQuitSettings(defaults: fixture.defaults)),
				size: NSSize(width: 1100, height: 700), keepsRequestedSize: true)
		}

		private func element(_ label: String, in window: NSWindow) -> AccessibilityTree.Element? {
			guard let content = window.contentView else { return nil }
			content.layoutSubtreeIfNeeded()
			return AccessibilityTree.visibleElements(in: window, of: content).first { $0.isInteractive && $0.says(label, as: .leading) }
		}

		private func question<V: View>(_ host: SheetTestHost<V>) async throws -> NSWindow {
			#expect(try await host.waitUntil { host.window.sheets.first != nil }, "Repair asks first")
			return try #require(host.window.sheets.first)
		}

		@Test("a damaged project says what's wrong, and Repair asks first, then repairs and the banner goes")
		func damagedBanner() async throws {
			let fixture = try await fixture(marker: #"{"schemaVersion":1}"#)
			defer { fixture.tearDown() }
			let host = workspace(fixture)
			defer { host.window.close() }
			try await host.settle()
			for text in ["This project’s newer data is damaged", "Its feature marker is invalid.", "Its values stay hidden"] {
				#expect(try await host.waitForText(text), "The banner says \(text)")
			}

			try await host.click("Repair…")
			let cancelled = try await question(host)
			#expect(try await host.waitForText("Repair this project’s newer data?", exactly: true, in: cancelled))
			try await host.click("Cancel", in: cancelled)
			#expect(try await host.waitUntil { host.window.sheets.isEmpty })
			#expect(fixture.keychain.companionRepairs.isEmpty, "Cancel changes nothing")

			try await host.click("Repair…")
			let repair = try await question(host)
			for text in ["discards all of this project’s newer data on this Mac", "Its values stay as they are.", "Project"] {
				#expect(try await host.waitForText(text, in: repair), "The question says \(text)")
			}
			try await host.click("Repair", in: repair)
			#expect(try await host.waitForTextToDisappear("This project’s newer data is damaged"))
			#expect(fixture.keychain.companionRepairs.map(\.reviewed.repairs) == [[.init(action: .discardProject, feature: nil)]])
		}

		@Test("a missing record's repair removes only its feature")
		func featureRepair() async throws {
			let marker = #"{"schemaVersion":1,"vaultId":"project","state":"active","features":{"overrides":{"version":1,"ifUnsupported":"refuse","kinds":["overrides"],"state":"active"}}}"#
			let fixture = try await fixture(marker: marker, inventory: [])
			defer { fixture.tearDown() }
			let host = workspace(fixture)
			defer { host.window.close() }
			try await host.settle()
			#expect(try await host.waitForText("Its “overrides” record is missing."))

			try await host.click("Repair…")
			let repair = try await question(host)
			#expect(try await host.waitForText("Repairing removes personal overrides from this project on this Mac.", in: repair))
			try await host.click("Repair", in: repair)
			#expect(try await host.waitForTextToDisappear("This project’s newer data is damaged"))
			#expect(fixture.keychain.companionRepairs.first?.reviewed.repairs == [.init(action: .removeFeature, feature: "overrides")])
		}

		@Test("a feature this version can only read says changes need an update")
		func readOnlyBanner() async throws {
			let marker = #"{"schemaVersion":1,"vaultId":"project","state":"active","features":{"future":{"version":1,"ifUnsupported":"readOnly","kinds":["future-log"],"state":"active"}}}"#
			let fixture = try await fixture(marker: marker)
			defer { fixture.tearDown() }
			let host = workspace(fixture)
			defer { host.window.close() }
			try await host.settle()
			for text in ["This project uses data from a newer LPM", "the feature “future” v1, which this version of LPM Vault can only read",
				"Update LPM Vault to change it.", "Check for Updates…"]
			{
				#expect(try await host.waitForText(text), "The banner says \(text)")
			}
		}

		@Test("an interrupted change says values stay hidden until it's finished, and Try Again tries")
		func interruptedBanner() async throws {
			let deleting = #"{"schemaVersion":1,"vaultId":"project","state":"deleting","features":{}}"#
			let fixture = try await fixture(marker: deleting)
			defer { fixture.tearDown() }
			let host = workspace(fixture)
			defer { host.window.close() }
			try await host.settle()
			for text in ["This project’s newer data has an unfinished change", "its values stay hidden until then"] {
				#expect(try await host.waitForText(text), "The banner says \(text)")
			}
			fixture.keychain.companionStates["project"] = nil
			try await host.click("Try Again")
			#expect(try await host.waitForTextToDisappear("This project’s newer data has an unfinished change"))
		}

		@Test("a project using a newer feature's data asks to update, with nothing to repair")
		func newerFeatureBanner() async throws {
			let marker = #"{"schemaVersion":1,"vaultId":"project","state":"active","features":{"overrides":{"version":2,"ifUnsupported":"refuse","kinds":["overrides"],"state":"active"}}}"#
			let fixture = try await fixture(marker: marker)
			defer { fixture.tearDown() }
			let host = workspace(fixture)
			defer { host.window.close() }
			try await host.settle()
			for text in ["This project uses data from a newer LPM", "personal overrides v2, which this version of LPM Vault doesn’t support"] {
				#expect(try await host.waitForText(text), "The banner says \(text)")
			}
			#expect(try await host.waitForText("Check for Updates…"))
			#expect(element("Repair…", in: host.window) == nil)
		}
		/// An unlocked store showing `project`, with `other` in the sidebar, each
		/// with newer data as `states` says, as a snapshot reads it.
		private func twoProjects(_ states: [String: String], refusals: [String: CompanionRefusal] = [:]) async throws -> Fixture {
			let folder = FileManager.default.temporaryDirectory.appending(path: "lpm-companion-banner-\(UUID().uuidString)", directoryHint: .isDirectory)
			try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
			let defaults = try #require(UserDefaults(suiteName: folder.lastPathComponent))
			let keychain = MockKeychainService()
			keychain.envStorage["project"] = (name: "Project", path: "", environments: ["default": ["TOKEN": "a"]])
			keychain.envStorage["other"] = (name: "Other", path: "", environments: ["default": ["TOKEN": "b"]])
			for (vaultId, marker) in states {
				keychain.companionStates[vaultId] = try CompanionEngine.assess(
					vaultId: vaultId, .init(marker: Data(marker.replacingOccurrences(of: "VAULT", with: vaultId).utf8)))
			}
			keychain.companionRefusals = refusals
			let store = VaultStore(
				keychainService: keychain, biometricService: MockBiometricService(), apiService: MockAPIService(), preferences: defaults,
				projectIconsDirectory: folder.appending(path: "icons", directoryHint: .isDirectory),
				backupKeys: .inMemory(InMemoryKeychainBackend(), home: try testLPMHome(in: folder)))
			store.isUnlocked = true
			#expect(await store.loadProjects())
			store.openProject(id: "project")
			return Fixture(store: store, keychain: keychain, defaults: defaults, folder: folder)
		}

		@Test("a repair question for one project goes when another project opens, and never repairs it")
		func repairQuestionStaysWithItsProject() async throws {
			let invalid = #"{"schemaVersion":1}"#
			let fixture = try await twoProjects(["project": invalid, "other": invalid])
			defer { fixture.tearDown() }
			let host = workspace(fixture)
			defer { host.window.close() }
			try await host.settle()
			#expect(try await host.waitForText("This project’s newer data is damaged"))
			try await host.click("Repair…")
			_ = try await question(host)

			fixture.store.openProject(id: "other")

			#expect(try await host.waitUntil { host.window.sheets.isEmpty }, "the question about Project goes")
			#expect(fixture.keychain.companionRepairs.isEmpty)
		}

		@Test("a project this version can only read offers no edits")
		func readOnlyProjectOffersNoEdits() async throws {
			let readOnly = #"{"schemaVersion":1,"vaultId":"VAULT","state":"active","features":{"future":{"version":1,"ifUnsupported":"readOnly","kinds":["future-log"],"state":"active"}}}"#
			let fixture = try await twoProjects(["project": readOnly])
			defer { fixture.tearDown() }
			let host = workspace(fixture)
			defer { host.window.close() }
			try await host.settle()
			#expect(try await host.waitForText("This project uses data from a newer LPM"))
			let newKey = try #require(element("New key", in: host.window))
			#expect(!newKey.isEnabledNow, "New key is disabled")
			let importer = try #require(element("Import variables into", in: host.window))
			#expect(!importer.isEnabledNow, "Import is disabled")
		}

		@Test("a project whose newer data hides its values offers no Retry that can't help")
		func refusedProjectOffersNoRetry() async throws {
			let newer = #"{"schemaVersion":1,"vaultId":"VAULT","state":"active","features":{"overrides":{"version":2,"ifUnsupported":"refuse","kinds":["overrides"],"state":"active"}}}"#
			let fixture = try await twoProjects(["project": newer], refusals: ["project": .unsupported(feature: "overrides", version: 2, level: .refuse)])
			defer { fixture.tearDown() }
			let host = workspace(fixture)
			defer { host.window.close() }
			try await host.settle()
			#expect(try await host.waitForText("This project uses data from a newer LPM"))
			#expect(try await host.waitUntil { fixture.store.selectedProjectLoadFailure != nil })
			try await host.settle()
			#expect(element("Retry", in: host.window) == nil)
		}

		@Test("a finished interrupted change says what it did until it's dismissed")
		func noticeBanner() async throws {
			let fixture = try await twoProjects([:])
			defer { fixture.tearDown() }
			fixture.keychain.pendingCompanionNotices = ["project": .init(kind: "restoreUndone", features: [])]
			await fixture.store.refreshLocalState()
			let host = workspace(fixture)
			defer { host.window.close() }
			try await host.settle()
			let text = "LPM Vault undid a restore of this project’s newer data that an earlier run left unfinished. Run the restore again."
			#expect(try await host.waitForText(text, exactly: true))

			try await host.click("Dismiss")

			#expect(try await host.waitForTextToDisappear(text))
			#expect(fixture.store.companionNotices.isEmpty)
		}

		@Test("a project with more than one damage names each, and Repair says what each repair does")
		func everyDamageIsShown() async throws {
			let marker = #"{"schemaVersion":1,"vaultId":"project","state":"active","features":{"overrides":{"version":1,"ifUnsupported":"refuse","kinds":["overrides"],"state":"active"}}}"#
			let notes = try CompanionEngine.accountNames([.init(role: .record, vaultId: "project", kind: "notes", part: nil)])[0]
			let fixture = try await fixture(marker: marker, inventory: [notes])
			defer { fixture.tearDown() }
			let host = workspace(fixture)
			defer { host.window.close() }
			try await host.settle()
			#expect(try await host.waitForText("Its “overrides” record is missing"))
			#expect(try await host.waitForText("“notes” records no feature lists"))

			try await host.click("Repair…")
			let repair = try await question(host)
			for text in ["removes personal overrides from this project", "deletes the newer data no feature of this project uses"] {
				#expect(try await host.waitForText(text, in: repair), "The question says \(text)")
			}
			try await host.click("Repair", in: repair)
			#expect(try await host.waitForTextToDisappear("This project’s newer data is damaged"))
			#expect(fixture.keychain.companionRepairs.first?.reviewed.repairs.count == 2)
		}
	}
}
