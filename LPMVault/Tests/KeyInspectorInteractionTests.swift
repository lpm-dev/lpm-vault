import AppKit
import SwiftUI
import Testing

@testable import LPMVault

extension SheetInteractionTests {
	@Suite("Key inspector interactions", .serialized)
	@MainActor
	struct KeyInspectorInteractionTests {
		@Test("a rename and a value edit save together and the inspector follows the new name")
		func renameAndValueSaveTogether() async throws {
			let (store, keychain) = makeStore(["default": ["TOKEN": "dev", "OTHER": "other"], "staging": ["TOKEN": "stg"]])
			defer { store.lock() }
			let host = SheetTestHost(KeyInspectorFixture(store: store), size: NSSize(width: 300, height: 640))
			defer { host.window.close() }
			try await host.settle()
			try host.enterKey("API_TOKEN")
			try host.enterValue("dev-2")
			#expect(try await host.waitForText("2 unsaved changes"))
			#expect(try await host.text().contains("Renames it in all 2 environments"))
			try await host.click("Save")
			let expected: [String: [String: String]] = ["default": ["API_TOKEN": "dev-2", "OTHER": "other"], "staging": ["API_TOKEN": "stg"]]
			#expect(try await host.waitUntil { keychain.envStorage["inspector"]?.environments == expected })
			#expect(try await host.waitForText("No unsaved changes"))
			#expect(try await host.text().contains("API_TOKEN"))
			#expect(keychain.applyVaultTransactionCallCount == 1)
		}

		@Test("a name that collides with another key is reported and never saved")
		func nameCollision() async throws {
			let (store, keychain) = makeStore(["default": ["TOKEN": "dev", "OTHER": "other"]])
			defer { store.lock() }
			let host = SheetTestHost(KeyInspectorFixture(store: store), size: NSSize(width: 300, height: 640))
			defer { host.window.close() }
			try await host.settle()
			try host.enterKey("other")
			#expect(try await host.waitForText("OTHER already exists in .env"))
			try await host.click("Save")
			try host.returnWhileEditing("key", modifiers: [])
			try await host.settle()
			#expect(keychain.applyVaultTransactionCallCount == 0)
			#expect(keychain.envStorage["inspector"]?.environments["default"] == ["TOKEN": "dev", "OTHER": "other"])
		}

		@Test("a refresh keeps edits that changed or disappeared elsewhere until the person resolves them", arguments: ["changed", "deleted", "empty-deleted"])
		func refreshKeepsConflictingEdits(change: String) async throws {
			let original = change == "empty-deleted" ? "" : "old"
			let (store, keychain) = makeStore(["default": ["TOKEN": original], "staging": ["TOKEN": "stg"]])
			defer { store.lock() }
			let host = SheetTestHost(KeyInspectorFixture(store: store), size: NSSize(width: 300, height: 640))
			defer { host.window.close() }
			try await host.settle()
			try host.enterValue("unsaved-draft")
			try await host.settle()
			if change == "changed" {
				keychain.envStorage["inspector"]?.environments["default"]?["TOKEN"] = "cli-new"
			} else {
				keychain.envStorage["inspector"]?.environments["default"]?.removeValue(forKey: "TOKEN")
			}
			await store.refreshLocalState()
			try await host.settle()
			#expect(host.value == "unsaved-draft")
			#expect(try await host.waitForText(change == "changed" ? "Changed outside the editor" : "Deleted outside the editor"))
			try host.returnWhileEditing("value", modifiers: [])
			try await host.settle()
			#expect(keychain.applyVaultTransactionCallCount == 0)

			try await host.click(change == "changed" ? "Keep mine" : "Add again")
			try await host.click("Save")
			#expect(try await host.waitUntil { stored(keychain, "default", "TOKEN") == "unsaved-draft" })
			#expect(stored(keychain, "staging", "TOKEN") == "stg")
		}

		@Test("the single-environment view edits its environment and shows other unsaved edits; the project view edits them all")
		func viewScope() async throws {
			let (store, _) = makeStore(["default": ["TOKEN": "dev"], "staging": ["TOKEN": "stg"], "production": [:]])
			defer { store.lock() }
			let project = SheetTestHost(KeyInspectorFixture(store: store), size: NSSize(width: 300, height: 640))
			try await project.settle()
			#expect(project.secureValues == ["dev", "stg"])
			#expect(try await project.text().contains("Add to .env.production"))
			try await project.click("Add to .env.production")
			#expect(try await project.waitUntil { project.secureValues == ["dev", "", "stg"] })
			try project.enterValue("stg-2", at: 2)
			#expect(try await project.waitForText("2 unsaved changes"))
			project.window.close()

			let single = SheetTestHost(KeyInspectorFixture(store: store, mode: .environment("default")), size: NSSize(width: 300, height: 640))
			defer { single.window.close() }
			try await single.settle()
			#expect(single.secureValues == ["dev", "", "stg-2"])
			store.keyDrafts.discardAll()
			try await single.settle()
			#expect(single.secureValues == ["dev"])
			#expect(try await single.text().contains("Add to another environment"))
		}

		@Test("inspector generation changes only the draft until saved", arguments: [ColorScheme.light, .dark])
		func generatorDraft(scheme: ColorScheme) async throws {
			let (store, keychain) = makeStore(["default": ["TOKEN": "old"], "production": ["TOKEN": "production-old"]])
			defer { store.lock() }
			let host = SheetTestHost(KeyInspectorFixture(store: store).environment(\.colorScheme, scheme), size: NSSize(width: 300, height: 640))
			defer { host.window.close() }
			try await host.settle()
			try host.click(.generate)
			let panel = try await host.generatorWindow()
			try await host.click("Password", in: panel)
			try await host.waitUntil { host.value != "old" }
			let generated = host.value
			#expect(generated.count == SecretValueGenerator.defaultLength)
			#expect(stored(keychain, "default", "TOKEN") == "old")
			// Synthetic clicks bypass the popover's outside-click monitor, so close it with its button.
			try host.click(.generate)
			#expect(try await host.waitForGeneratorDismissal(panel))
			try await host.click("Revert")
			#expect(try await host.waitUntil { host.value == "old" })
			try host.click(.generate)
			let secondPanel = try await host.generatorWindow()
			try await host.click("UUID v4", in: secondPanel, caseInsensitive: true)
			try await host.waitUntil { UUID(uuidString: host.value) != nil }
			let second = host.value
			try host.click(.generate)
			#expect(try await host.waitForGeneratorDismissal(secondPanel))
			try await host.click("Save")
			#expect(try await host.waitUntil { stored(keychain, "default", "TOKEN") == second })
			#expect(stored(keychain, "production", "TOKEN") == "production-old")
		}

		@Test("inspector generation cannot replace a pending save or a conflicting edit", arguments: ["save", "conflict"])
		func generatorUnavailable(reason: String) async throws {
			let (store, keychain) = makeStore(["default": ["TOKEN": "old"]])
			defer { store.lock() }
			let host = SheetTestHost(KeyInspectorFixture(store: store), size: NSSize(width: 300, height: 640))
			defer { host.window.close() }
			try await host.settle()
			try host.click(.generate)
			let panel = try await host.generatorWindow()
			try await host.click("Hexadecimal", in: panel)
			try await host.waitUntil { host.value != "old" }
			let generated = host.value
			let release = DispatchSemaphore(value: 0)
			defer { release.signal() }
			if reason == "save" {
				let entered = DispatchSemaphore(value: 0)
				keychain.beforeKeychainTransaction = { entered.signal(); release.wait() }
				try await host.click("Save")
				let didEnter = await withCheckedContinuation { continuation in
					DispatchQueue.global().async { continuation.resume(returning: entered.wait(timeout: .now() + 3) == .success) }
				}
				try #require(didEnter)
			} else {
				store.projects[0].environments["default"]?["TOKEN"] = "external"
				#expect(try await host.waitForText("Changed outside the editor"))
			}
			#expect(try await host.waitForGeneratorDismissal(panel))
			try host.click(.generate)
			try await host.settle()
			#expect(try await host.visibleGeneratorWindow() == nil)
			#expect(host.value == generated)
			if reason == "conflict" {
				try await host.click("Use latest")
				#expect(try await host.waitUntil { host.value == "external" })
				try host.click(.generate)
				let recoveredPanel = try await host.generatorWindow()
				try host.click(.generate)
				#expect(try await host.waitForGeneratorDismissal(recoveredPanel))
			}
		}

		@Test("Esc first leaves a field and keeps its edit, then a second Esc closes the inspector", arguments: ["key", "value"])
		func escapeLeavesFieldThenCloses(field: String) async throws {
			let (store, _) = makeStore(["default": ["TOKEN": "dev"]])
			defer { store.lock() }
			let closes = CloseCounter()
			let host = SheetTestHost(KeyInspectorFixture(store: store, onClose: { closes.count += 1 }), size: NSSize(width: 300, height: 640))
			defer { host.window.close() }
			try await host.settle()
			let secure = field == "value"
			if secure { try host.enterValue("dev-2") } else { try host.enterKey("API_TOKEN") }
			try await host.settle()
			try host.escapeWhileEditing(fieldAt: 0, secure: secure)
			#expect(try await host.waitUntilRendered { try !host.isEditing(fieldAt: 0, secure: secure) })
			#expect(closes.count == 0)
			#expect(try await host.waitForText("1 unsaved change"))
			try host.sendEscape()
			#expect(try await host.waitUntilRendered { closes.count == 1 })
			let id = VaultKeyDraft.ID(projectID: "inspector", key: "TOKEN")
			#expect(secure ? store.keyDrafts.draft(id)?.value(in: "default") == "dev-2" : store.keyDrafts.draft(id)?.name == "API_TOKEN")
		}

		@Test("the pencil next to the key name starts editing it")
		func pencilEditsKeyName() async throws {
			let (store, _) = makeStore(["default": ["TOKEN": "dev"]])
			defer { store.lock() }
			let host = SheetTestHost(KeyInspectorFixture(store: store), size: NSSize(width: 300, height: 640))
			defer { host.window.close() }
			try await host.settle()
			#expect(try !host.isEditing(fieldAt: 0, secure: false))
			// The pencil sits after the name field, past the row's spacing.
			try host.click(afterPlainFieldAt: 0, offset: 12)
			#expect(try await host.waitUntil { try host.isEditing(fieldAt: 0, secure: false) })
		}

		@Test("a description typed in the inspector is saved to lpm.json with the rest of the key")
		func descriptionSave() async throws {
			let folder = FileManager.default.temporaryDirectory.appending(path: "inspector-description-\(UUID().uuidString)").path
			try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
			defer { try? FileManager.default.removeItem(atPath: folder) }
			try #"{"vault": "inspector"}"#.write(toFile: folder + "/lpm.json", atomically: true, encoding: .utf8)
			let (store, keychain) = makeStore(["default": ["TOKEN": "dev"]], path: folder)
			defer { store.lock() }
			store.reloadKeyDescriptions()
			let host = SheetTestHost(KeyInspectorFixture(store: store), size: NSSize(width: 300, height: 640))
			defer { host.window.close() }
			#expect(try await host.waitUntil { store.keyDescriptions["inspector"] != nil })
			#expect(try await host.waitForText("DESCRIPTION"))
			#expect(try await host.text().contains("Stored in lpm.json, not encrypted"))
			try host.enterText("Rotated monthly by the billing team", at: 1)
			#expect(try await host.waitForText("1 unsaved change"))
			try await host.click("Save")
			#expect(try await host.waitUntil {
				(try? ProjectEnvSchemaFile.rules(inFolder: folder, vaultID: "inspector").descriptions) == ["TOKEN": "Rotated monthly by the billing team"]
			})
			#expect(try await host.waitForText("No unsaved changes"))
			#expect(keychain.applyVaultTransactionCallCount == 0)
		}

		@Test("a partial schema rename keeps its error visible under the saved name")
		func partialRenameErrorStaysVisible() async throws {
			let folder = FileManager.default.temporaryDirectory.appending(path: "inspector-partial-rename-\(UUID().uuidString)").path
			try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
			defer { try? FileManager.default.removeItem(atPath: folder) }
			try #"{"envSchema":{"vars":{"TOKEN":{"required":true}}}}"#.write(toFile: folder + "/lpm.json", atomically: true, encoding: .utf8)
			let (store, _) = makeStore(["default": ["TOKEN": "dev"]], path: folder)
			defer { store.lock() }
			store.reloadKeyDescriptions()
			let host = SheetTestHost(KeyInspectorFixture(store: store), size: NSSize(width: 300, height: 640))
			defer { host.window.close() }
			#expect(try await host.waitUntil { store.keyDescriptions["inspector"] != nil })
			try await host.settle()
			try host.enterKey("NEW")
			try "{".write(toFile: folder + "/lpm.json", atomically: true, encoding: .utf8)
			try await host.click("Save")
			#expect(try await host.waitForText("The key was saved"))
			#expect(try await host.text().contains("lpm.json was not updated"))
			#expect(try await host.text().contains("1 unsaved change"))
		}

		@Test("a deferred Save action cannot save a later account's draft")
		func deferredSaveSessionLifetime() async throws {
			let (store, keychain) = makeStore(["default": ["TOKEN": "dev"]])
			defer { store.lock() }
			let host = SheetTestHost(KeyInspectorFixture(store: store), size: NSSize(width: 300, height: 640))
			defer { host.window.close() }
			try await host.settle()
			try host.enterValue("Old session")
			try await host.settle()
			try host.returnWhileEditing("value", modifiers: [])
			store.selectedAccount = .org("other")
			store.selectedAccount = .personal
			let id = VaultKeyDraft.ID(projectID: "inspector", key: "TOKEN")
			store.keyDrafts.edit(try #require(store.selectedProject), key: "TOKEN") { $0.setValue("Fresh session", in: "default") }
			let fresh = store.keyDrafts.draft(id)
			try await host.settle()
			#expect(store.keyDrafts.draft(id) == fresh)
			#expect(keychain.applyVaultTransactionCallCount == 0)
		}

		private func makeStore(_ environments: [String: [String: String]], path: String = "") -> (VaultStore, MockKeychainService) {
			let keychain = MockKeychainService()
			keychain.envStorage["inspector"] = (name: "Inspector", path: path, environments: environments)
			let preferences = UserDefaults(suiteName: "key-inspector-\(UUID().uuidString)")!
			let store = VaultStore(keychainService: keychain, biometricService: MockBiometricService(), apiService: MockAPIService(), preferences: preferences)
			store.selectedProjectId = "inspector"
			store.projects = [VaultProject(id: "inspector", name: "Inspector", path: path, environments: environments)]
			store.isUnlocked = true
			return (store, keychain)
		}

		private func stored(_ keychain: MockKeychainService, _ environment: String, _ key: String) -> String? {
			keychain.envStorage["inspector"]?.environments[environment]?[key]
		}
	}
}

@MainActor
private final class CloseCounter {
	var count = 0
}

private struct KeyInspectorFixture: View {
	@Bindable var store: VaultStore
	var mode: VaultWorkspaceMode = .matrix
	var onClose: () -> Void = {}
	@State private var selectedKey: String? = "TOKEN"
	@State private var revealedKeys: Set<String> = []

	var body: some View {
		if let project = store.selectedProject {
			VaultInspectorView(
				store: store,
				project: project,
				environments: store.orderedEnvironmentNames(for: project),
				mode: mode,
				selectedKey: selectedKey,
				revealedKeys: $revealedKeys,
				onClose: onClose,
				onCopy: { _ in },
				onDelete: { _, _ in },
				onAddElsewhere: { _, _ in },
				onRenamed: { key, newKey in
					if selectedKey == key { selectedKey = newKey }
				}
			)
			.frame(width: 300, height: 640)
		}
	}
}
