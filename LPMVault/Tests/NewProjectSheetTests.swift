import AppKit
import SwiftUI
import Testing

@testable import LPMVault

extension SheetInteractionTests {
	@Suite("New project sheet", .serialized)
	@MainActor
	struct NewProjectSheetTests {
		private struct Fixture {
			let store: VaultStore
			let keychain: MockKeychainService
			let preferences: UserDefaults
			let domain: String
			let images: URL
			let root: URL

			@MainActor func tearDown() {
				store.lock()
				preferences.removePersistentDomain(forName: domain)
				try? FileManager.default.removeItem(at: images)
				try? FileManager.default.removeItem(at: root)
			}
		}

		private func makeFixture() throws -> Fixture {
			let domain = "new-project-sheet-\(UUID().uuidString)"
			let preferences = try #require(UserDefaults(suiteName: domain))
			let images = FileManager.default.temporaryDirectory.appending(path: "new-project-sheet-images-\(UUID().uuidString)", directoryHint: .isDirectory)
			let root = FileManager.default.temporaryDirectory.appending(path: "new-project-sheet-\(UUID().uuidString)", directoryHint: .isDirectory)
			try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
			let keychain = MockKeychainService()
			let store = VaultStore(keychainService: keychain, biometricService: MockBiometricService(), apiService: MockAPIService(),
				preferences: preferences, authTokenProvider: { _, _ in nil }, projectIconsDirectory: images)
			store.isUnlocked = true
			return Fixture(store: store, keychain: keychain, preferences: preferences, domain: domain, images: images, root: root)
		}

		private func host(_ fixture: Fixture, folder: URL? = nil) async throws -> SheetTestHost<some View> {
			let host = SheetTestHost(
				NewVaultSheet(store: fixture.store, folderPicker: { folder }, imagePicker: { _, _ in nil }).environment(\.colorScheme, .light),
				size: NSSize(width: 460, height: 640))
			try await host.settle()
			return host
		}

		@Test("the sheet offers an icon, a folder, CLI approval and local history, the switches on as Settings starts them")
		func showsChoices() async throws {
			let fixture = try makeFixture()
			defer { fixture.tearDown() }
			let host = try await host(fixture)
			defer { host.window.close() }
			#expect(try await host.waitForText("New env project"))
			for text in ["PROJECT NAME", "FOLDER", "Optional", "None", "CLI approval", "Local history",
				"The LPM CLI uses this project in the folder you choose. You can link one later from Connect CLI."] {
				#expect(try await host.waitForText(text), "\(text)")
			}
			#expect(try await host.waitForElement(saying: "Choose icon").isInteractive)
			#expect(try await host.waitForElement(saying: "Choose Folder…").isInteractive)
			#expect(try await host.waitForElement(saying: "CLI approval").isOn == true)
			#expect(try await host.waitForElement(saying: "Local history").isOn == true)
			#expect(try await !host.waitForElement(saying: "Create Project").isEnabledNow, "Nothing to create until it has a name")

			try await host.click("Choose icon")
			let menu = try await host.popoverWindow()
			for row in ["Symbol, Emoji or Monogram…", "Image File…", "Use Automatic"] {
				#expect(try await host.waitForText(row, in: menu), "\(row)")
			}
			#expect(try await !host.waitForElement(saying: "Use Automatic", in: menu).isEnabledNow, "Already automatic")
		}

		@Test("switches start as Settings says new projects start, when that's been turned off")
		func switchesFollowSettings() async throws {
			let fixture = try makeFixture()
			defer { fixture.tearDown() }
			fixture.store.settings.newProjectsAskBeforeCLIReads = false
			fixture.store.settings.newProjectsKeepHistory = false
			let host = try await host(fixture)
			defer { host.window.close() }
			#expect(try await host.waitForElement(saying: "CLI approval").isOn == false)
			#expect(try await host.waitForElement(saying: "Local history").isOn == false)
		}

		@Test("Create Project makes the project in the chosen folder, with its lpm.json linked and the switches as left")
		func createsWithChoices() async throws {
			let fixture = try makeFixture()
			defer { fixture.tearDown() }
			let project = fixture.root.appending(path: "billing", directoryHint: .isDirectory)
			try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
			try Data("{}".utf8).write(to: project.appending(path: "package.json"))
			let host = try await host(fixture, folder: project)
			defer { host.window.close() }
			try host.enterText("billing-api", placeholder: "my-api-server")
			try await host.click("Choose Folder…")
			#expect(try await host.waitForText("Adds \"vault\" to its lpm.json, keeping its other settings"))
			#expect(try await host.waitForText(project.lastPathComponent))
			#expect(try await host.waitForText("Change Folder…"))
			try await host.click("Local history")
			#expect(try await waitUntil { try await host.waitForElement(saying: "Local history").isOn == false })
			try await host.click("Create Project")

			#expect(try await host.waitUntil { fixture.keychain.storage.values.contains { $0.name == "billing-api" } })
			let (id, created) = try #require(fixture.keychain.storage.first { $0.value.name == "billing-api" })
			let folder = try #require(realpath(project.path, nil).map { pointer in
				defer { free(pointer) }
				return String(cString: pointer)
			})
			#expect(created.path == folder)
			#expect(ProjectCLILink.status(vaultId: id, folder: folder) == .linked)
			#expect(fixture.keychain.cliAccessPolicies[id] == .requireApproval)
			#expect(try fixture.keychain.historyStateResult(vaultId: id).get().history == "off")
		}

		@Test("a folder whose lpm.json links a project on this Mac says so, offers to open it, and holds Create back")
		func takenFolder() async throws {
			let fixture = try makeFixture()
			defer { fixture.tearDown() }
			fixture.store.projects = [VaultProject(id: "billing-vault", name: "Billing API", path: "", environments: ["default": [:]])]
			let taken = fixture.root.appending(path: "taken", directoryHint: .isDirectory)
			try FileManager.default.createDirectory(at: taken, withIntermediateDirectories: true)
			let original = Data(#"{"vault":"billing-vault"}"#.utf8)
			try original.write(to: taken.appending(path: "lpm.json"))
			let host = try await host(fixture, folder: taken)
			defer { host.window.close() }
			try host.enterText("another", placeholder: "my-api-server")
			try await host.click("Choose Folder…")
			#expect(try await host.waitForText("Its lpm.json links Billing API. Choose another folder, or open Billing API."))
			#expect(try await !host.waitForElement(saying: "Create Project").isEnabledNow)
			try await host.click("Remove Folder")
			#expect(try await host.waitForText("None", exactly: true))
			#expect(try await waitUntil { try await host.waitForElement(saying: "Create Project").isEnabledNow })
			#expect(try Data(contentsOf: taken.appending(path: "lpm.json")) == original)
		}
	}
}
