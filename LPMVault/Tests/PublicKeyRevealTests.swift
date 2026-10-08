import AppKit
import SwiftUI
import Testing

@testable import LPMVault

@Suite("Public key reveal")
struct PublicKeyRevealTests {
	private let project = VaultProject(id: "public", name: "Public", path: "", environments: [
		"default": ["NEXT_PUBLIC_URL": "https://example.com", "TOKEN": "secret"],
	])

	@Test("public values never need revealing, and Reveal all counts only maskable values", arguments: [
		VaultWorkspaceMode.matrix, .environment("default"),
	])
	func revealCountsMaskableValues(mode: VaultWorkspaceMode) {
		let snapshot = VaultWorkspaceSnapshot(project: project)
		func derived(revealed: Set<String>, publicKeys: Set<String>) -> VaultContentDerivation {
			VaultContentDerivation(project: project, snapshot: snapshot, selectedEnvironment: "default", mode: mode,
				filter: .all, searchText: "", sortOrder: .ascending, revealedKeys: revealed, publicKeys: publicKeys)
		}
		let none = derived(revealed: [], publicKeys: ["NEXT_PUBLIC_URL"])
		#expect(none.hasMaskableValues)
		#expect(!none.allVisibleRevealed)
		#expect(derived(revealed: ["TOKEN"], publicKeys: ["NEXT_PUBLIC_URL"]).allVisibleRevealed)

		let onlyPublic = VaultContentDerivation(project: project, snapshot: snapshot, selectedEnvironment: "default", mode: mode,
			filter: .all, searchText: "next", sortOrder: .ascending, revealedKeys: [], publicKeys: ["NEXT_PUBLIC_URL"])
		#expect(!onlyPublic.hasMaskableValues)
		#expect(!onlyPublic.allVisibleRevealed, "Nothing is left to reveal or hide")
	}
}

extension SheetInteractionTests {
	@Suite("Public key reveal in the workspace", .serialized)
	@MainActor
	struct PublicKeyWorkspaceTests {
		@Test("rereading unchanged rules masks public values until the read finishes")
		func publicSchemaReread() async throws {
			let (store, _, folder) = try await publicStore()
			defer { cleanUp(store, folder: folder) }
			let previous = store.keyDescriptions["public-review"]?.schema
			store.reloadKeyDescriptions()
			#expect(store.publicKeys(in: "public-review").isEmpty)
			#expect(store.keyDescriptions["public-review"]?.schema == previous)
			try await waitForPublicRules(store)
			#expect(store.publicKeys(in: "public-review") == ["APP_ENDPOINT"])
		}

		@Test("a changed CLI folder cannot reuse public rules", arguments: ["secret", "broken", "missing"])
		func changedPublicSchemaFolder(state: String) async throws {
			let (store, _, folder) = try await publicStore()
			defer { cleanUp(store, folder: folder) }
			let other = folder.appendingPathComponent("other")
			if state != "missing" {
				try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
				let json = state == "secret" ? #"{"envSchema":{"vars":{"APP_ENDPOINT":{"secret":true}}}}"# : "{invalid"
				try json.write(to: other.appendingPathComponent("lpm.json"), atomically: true, encoding: .utf8)
			}
			ProjectCLILink.rememberFolder(other.path, vaultId: "public-review", defaults: store.preferences)
			#expect(store.publicKeys(in: "public-review").isEmpty)
			store.reloadKeyDescriptions()
			#expect(store.publicKeys(in: "public-review").isEmpty)
			for _ in 0..<200 where store.keyDescriptions["public-review"]?.folder != other.path {
				try await Task.sleep(for: .milliseconds(10))
			}
			#expect(store.keyDescriptions["public-review"]?.folder == other.path)
			#expect(store.publicKeys(in: "public-review").isEmpty)
		}

		@Test("refresh never shows a newly private value using previous public rules")
		func refreshedPrivateValueStaysMasked() async throws {
			let (store, keychain, folder) = try await publicStore()
			defer { cleanUp(store, folder: folder) }
			var vars: [String: Any] = ["APP_ENDPOINT": ["secret": true]]
			for index in 0..<500 { vars["KEY_\(index)"] = ["required": true] }
			try JSONSerialization.data(withJSONObject: ["envSchema": ["vars": vars]])
				.write(to: folder.appendingPathComponent("lpm.json"))
			keychain.envStorage["public-review"]?.environments["default"]?["APP_ENDPOINT"] = "PRIVATE_FRESH_VALUE"
			await store.refreshLocalState()
			#expect(store.selectedProject?.value(for: "APP_ENDPOINT", in: "default") == "PRIVATE_FRESH_VALUE")
			#expect(store.publicKeys(in: "public-review").isEmpty)
			let host = SheetTestHost(VaultWorkspaceView(store: store).environment(UpdateChecker())
				.environment(VaultAppearanceSettings(defaults: store.preferences)).defaultAppStorage(store.preferences),
				size: NSSize(width: 1400, height: 700), keepsRequestedSize: true, usesHostingView: true)
			defer { host.window.close() }
			let text = try await RenderedText.strings(in: host.snapshot(host.view)).joined(separator: "\n")
			#expect(!text.contains("PRIVATE_FRESH_VALUE"))
			#expect(try await host.waitUntil { store.keyDescriptions["public-review"]?.schema?.overview?.rules.count == 501 })
			#expect(store.publicKeys(in: "public-review").isEmpty)
		}

		@Test("returning to a project waits for current public rules")
		func reselectedPublicProject() async throws {
			let (store, keychain, folder) = try await publicStore()
			defer { cleanUp(store, folder: folder) }
			let other = VaultProject(id: "other", name: "Other", path: "", environments: ["default": [:]])
			store.projects.append(other)
			keychain.envStorage[other.id] = (name: other.name, path: other.path, environments: other.environments)
			store.openProject(id: other.id)
			store.openProject(id: "public-review")
			#expect(store.publicKeys(in: "public-review").isEmpty)
			store.reloadKeyDescriptions()
			try await waitForPublicRules(store)
			#expect(store.publicKeys(in: "public-review") == ["APP_ENDPOINT"])
		}

		private func publicStore() async throws -> (VaultStore, MockKeychainService, URL) {
			let folder = FileManager.default.temporaryDirectory.appendingPathComponent("public-review-\(UUID().uuidString)")
			try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
			try #"{"envSchema":{"clientPrefixes":["APP_"],"vars":{"APP_ENDPOINT":{"client":true}}}}"#
				.write(to: folder.appendingPathComponent("lpm.json"), atomically: true, encoding: .utf8)
			let defaults = try #require(UserDefaults(suiteName: folder.lastPathComponent))
			let keychain = MockKeychainService()
			let project = VaultProject(id: "public-review", name: "Review", path: folder.path,
				environments: ["default": ["APP_ENDPOINT": "old-public-value"]])
			keychain.envStorage[project.id] = (name: project.name, path: project.path, environments: project.environments)
			let store = VaultStore(keychainService: keychain, biometricService: MockBiometricService(),
				apiService: MockAPIService(), preferences: defaults)
			store.isUnlocked = true
			store.projects = [project]
			store.selectedProjectId = project.id
			store.reloadKeyDescriptions()
			try await waitForPublicRules(store)
			return (store, keychain, folder)
		}

		private func waitForPublicRules(_ store: VaultStore) async throws {
			for _ in 0..<200 where store.publicKeys(in: "public-review") != ["APP_ENDPOINT"] {
				try await Task.sleep(for: .milliseconds(10))
			}
			try #require(store.publicKeys(in: "public-review") == ["APP_ENDPOINT"])
		}

		private func cleanUp(_ store: VaultStore, folder: URL) {
			store.lock()
			store.preferences.removePersistentDomain(forName: folder.lastPathComponent)
			try? FileManager.default.removeItem(at: folder)
		}

		@Test("public values show in the tables and inspector, and every value masks when lpm.json can't be read")
		func publicValuesShowAndFailClosed() async throws {
			let folder = FileManager.default.temporaryDirectory.appending(path: "public-keys-\(UUID().uuidString)").path
			try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
			defer { try? FileManager.default.removeItem(atPath: folder) }
			try #"{"envSchema":{"vars":{"NEXT_PUBLIC_API_URL":{"client":true,"format":"url"},"API_TOKEN":{"secret":true}}}}"#
				.write(toFile: folder + "/lpm.json", atomically: true, encoding: .utf8)
			let keychain = MockKeychainService()
			let project = VaultProject(id: "public-keys", name: "web-app", path: folder, environments: [
				"default": ["NEXT_PUBLIC_API_URL": "https://api.example.com", "API_TOKEN": "tok-hidden-value"],
			])
			keychain.envStorage[project.id] = (name: project.name, path: folder, environments: project.environments)
			let store = VaultStore(keychainService: keychain, biometricService: MockBiometricService(),
				apiService: MockAPIService(), authTokenProvider: { _, _ in nil })
			store.isUnlocked = true
			store.projects = [project]
			store.openProject(id: project.id)
			defer { store.lock() }
			await store.refreshCliAccess()
			let defaults = try #require(UserDefaults(suiteName: "public-key-interaction"))
			let host = SheetTestHost(VaultWorkspaceView(store: store).environment(UpdateChecker())
				.environment(VaultAppearanceSettings(defaults: defaults)).defaultAppStorage(defaults),
				size: NSSize(width: 1400, height: 700), keepsRequestedSize: true, usesHostingView: true)
			defer { host.window.close() }
			#expect(try await host.waitUntil { store.publicKeys(in: project.id) == ["NEXT_PUBLIC_API_URL"] })

			#expect(try await host.waitForText("api.example.com"))
			#expect(try await !host.text().contains("tok-hidden-value"))

			try await host.click("NEXT_PUBLIC_API_URL")
			#expect(try await host.waitForText("VALUES"))
			let inspector = CGRect(x: 0.78, y: 0, width: 0.22, height: 1)
			#expect(try await host.labelFrame("api.example.com", region: inspector).width > 0, "The inspector shows the public value")

			try await host.clickSidebarEnvironment(".env")
			#expect(try await host.waitForText("ACTIONS"))
			#expect(try await host.waitForText("api.example.com"))
			#expect(try await !host.text().contains("tok-hidden-value"))

			try "{not json".write(toFile: folder + "/lpm.json", atomically: true, encoding: .utf8)
			store.reloadKeyDescriptions()
			#expect(try await host.waitUntil { store.publicKeys(in: project.id).isEmpty })
			#expect(try await host.waitForTextToDisappear("api.example.com"))
		}
	}
}
