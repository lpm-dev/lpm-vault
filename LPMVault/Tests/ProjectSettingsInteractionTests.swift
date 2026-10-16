import AppKit
import SwiftUI
import Testing

@testable import LPMVault

extension SheetInteractionTests {
	@Suite("Project settings rendering", .serialized)
	@MainActor
	struct ProjectSettingsRenderingTests {
		private struct Fixture {
			let store: VaultStore
			let keychain: MockKeychainService
			let preferences: UserDefaults
			let domain: String
			let images: URL

			@MainActor func tearDown() {
				store.lock()
				preferences.removePersistentDomain(forName: domain)
				try? FileManager.default.removeItem(at: images)
			}
		}

		private func makeFixture(path: String) throws -> Fixture {
			let domain = "project-settings-ui-\(UUID().uuidString)"
			let preferences = try #require(UserDefaults(suiteName: domain))
			let images = FileManager.default.temporaryDirectory.appending(path: "project-settings-ui-images-\(UUID().uuidString)", directoryHint: .isDirectory)
			let keychain = MockKeychainService()
			keychain.envStorage["demo"] = (name: "demo-api", path: path, environments: ["default": ["TOKEN": "x"]])
			let store = VaultStore(keychainService: keychain, biometricService: MockBiometricService(), apiService: MockAPIService(),
				preferences: preferences, authTokenProvider: { _, _ in nil }, projectIconsDirectory: images)
			store.projects = [VaultProject(id: "demo", name: "demo-api", path: path, environments: ["default": ["TOKEN": "x"]])]
			store.isUnlocked = true
			store.selectedProjectId = "demo"
			return Fixture(store: store, keychain: keychain, preferences: preferences, domain: domain, images: images)
		}

		@Test("⌘I opens Project Settings with the detected icon, folder, CLI approval and Delete Locally, and Save renames the project")
		func pageOpensAndSaves() async throws {
			let folder = try ProjectIconFixture.folder()
			defer { try? FileManager.default.removeItem(at: folder) }
			try ProjectIconFixture.write(ProjectIconFixture.svg("#ff0000"), to: "public/favicon.svg", in: folder)
			let fixture = try makeFixture(path: folder.path)
			defer { fixture.tearDown() }
			let host = SheetTestHost(ContentView(store: fixture.store).environment(UpdateChecker())
				.environment(VaultAppearanceSettings(defaults: fixture.preferences)),
				size: NSSize(width: 1100, height: 720), keepsRequestedSize: true)
			defer { host.window.close() }
			try await host.settle()
			NotificationCenter.default.post(name: .showProjectSettings, object: nil)
			#expect(try await host.waitForText("Project Settings"))
			#expect(try await host.waitForText("public/favicon.svg"))
			#expect(try await host.waitForText("CLI approval"))
			#expect(try await host.waitForText("Delete Locally"))
			#expect(try await !host.text().contains("Unsaved changes"))
			try host.enterText("renamed-project", placeholder: "Project name")
			#expect(try await host.waitForText("Unsaved changes"))
			try await host.click("Save")
			#expect(try await host.waitUntil { fixture.keychain.envStorage["demo"]?.name == "renamed-project" })
			#expect(try await host.waitUntil { fixture.store.projectSettingsDrafts.isEmpty })
			#expect(try await host.waitForTextToDisappear("Unsaved changes"))
			try await host.click("All variables")
			#expect(try await host.waitForText("New key"))
		}

		@Test("Rename opens Project Settings with the name being edited")
		func renameFocusesName() async throws {
			let fixture = try makeFixture(path: "")
			defer { fixture.tearDown() }
			let project = try #require(fixture.store.projects.first)
			let host = SheetTestHost(VaultProjectSettingsView(store: fixture.store, project: project, nameFocusRequest: UUID(), onBack: {}, onDelete: {}),
				size: NSSize(width: 820, height: 640), keepsRequestedSize: true)
			defer { host.window.close() }
			#expect(try await host.waitUntilRendered {
				((host.window.firstResponder as? NSText)?.delegate as? NSTextField)?.placeholderString == "Project name"
			})
			#expect(try await host.waitForText("This project isn't linked to a folder."))
		}

		@Test("the icon picker chooses an emoji by its search, and a monogram from its letters and color")
		func iconPicker() async throws {
			var chosen: [ProjectIconChoice] = []
			let host = SheetTestHost(VaultProjectIconPicker(projectName: "demo-api", initial: .automatic) { chosen.append($0) },
				size: NSSize(width: 560, height: 560))
			defer { host.window.close() }
			#expect(try await host.waitForText("Choose project icon"))
			#expect(try await host.waitForText("Search symbols"))
			try await host.click("Emoji")
			#expect(try await host.waitForText("Search emoji"))
			try host.typeText("rocket", placeholder: "Search emoji")
			try host.pressWhileEditing("\r", code: 36)
			try await host.click("Use Icon")
			#expect(chosen == [.emoji("🚀")])

			let monogram = SheetTestHost(VaultProjectIconPicker(projectName: "demo-api", initial: .monogram("DA", .teal)) { chosen.append($0) },
				size: NSSize(width: 560, height: 560))
			defer { monogram.window.close() }
			#expect(try await monogram.waitForText("letters or digits"))
			try monogram.enterText("xy", at: 0)
			try await monogram.click("Use Icon")
			#expect(chosen.last == .monogram("XY", .teal))
		}
	}
}
