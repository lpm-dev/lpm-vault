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
