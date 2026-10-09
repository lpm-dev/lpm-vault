import AppKit
import SwiftUI
import Testing

@testable import LPMVault

@Suite("Schema draft history and renames", .serialized)
@MainActor
struct SchemaDraftHistoryTests {
	private func json(_ text: String) throws -> LPMConfigJSON {
		try LPMConfigJSON(parsing: Data(text.utf8), rejectDuplicateKeys: true)
	}

	@Test("undo steps back through edits, typing in one field undoes at once, and redo steps forward")
	func undoAndRedo() async throws {
		let (store, folder) = try await makeStore(#"{"envSchema":{"vars":{"PORT":{"format":"port"}}}}"#)
		defer { store.lock(); try? FileManager.default.removeItem(atPath: folder) }
		store.editSchemaDraft(in: "project") { $0.set(.declared(try! self.json(#"{"format":"port","required":true}"#)), for: .key("PORT")) }
		for value in ["8", "80", "808", "8080"] {
			store.editSchemaDraft(in: "project", coalescing: "PORT/default") {
				$0.set(.declared(try! self.json(#"{"format":"port","required":true,"default":"\#(value)"}"#)), for: .key("PORT"))
			}
		}
		#expect(store.schemaDraft(for: "project")?.declaration(of: .key("PORT")).json?["default"] == .string("8080"))
		store.undoSchemaDraft(in: "project")
		#expect(store.schemaDraft(for: "project")?.declaration(of: .key("PORT")) == .declared(try json(#"{"format":"port","required":true}"#)))
		store.undoSchemaDraft(in: "project")
		#expect(store.schemaDraft(for: "project") == nil)
		#expect(!store.canUndoSchemaDraft(in: "project"))
		store.redoSchemaDraft(in: "project")
		store.redoSchemaDraft(in: "project")
		#expect(store.schemaDraft(for: "project")?.declaration(of: .key("PORT")).json?["default"] == .string("8080"))
		#expect(!store.canRedoSchemaDraft(in: "project"))
	}

	@Test("discarding can be undone, and a merge with lpm.json ends the history")
	func discardAndMergeHistory() async throws {
		let (store, folder) = try await makeStore(#"{"envSchema":{"vars":{"PORT":{"format":"port"}}}}"#)
		defer { store.lock(); try? FileManager.default.removeItem(atPath: folder) }
		store.editSchemaDraft(in: "project") { $0.set(.absent, for: .key("PORT")) }
		store.discardSchemaDraft(in: "project")
		#expect(store.schemaDraft(for: "project") == nil)
		store.undoSchemaDraft(in: "project")
		#expect(store.schemaDraft(for: "project")?.declaration(of: .key("PORT")) == .absent)

		try #"{"envSchema":{"vars":{"PORT":{"format":"port"},"A":{}}}}"#.write(toFile: folder + "/lpm.json", atomically: true, encoding: .utf8)
		store.reloadKeyDescriptions()
		try await waitUntil { store.schemaDraft(for: "project")?.schema?["vars"]?["A"] != nil }
		#expect(!store.canUndoSchemaDraft(in: "project"), "Earlier versions were made against the old file")
	}

	@Test("a key only lpm.json declares renames in lpm.json; a stored key renames with its values")
	func renames() async throws {
		let (store, folder) = try await makeStore(#"{"envSchema":{"vars":{"PORT":{"format":"port"},"UNUSED":{"required":true}}}}"#)
		defer { store.lock(); try? FileManager.default.removeItem(atPath: folder) }
		try await store.renameDeclaredKey("UNUSED", to: "SPARE", in: "project")
		let renamed = try String(contentsOfFile: folder + "/lpm.json", encoding: .utf8)
		#expect(renamed.contains(#""SPARE""#) && !renamed.contains(#""UNUSED""#))

		try await waitUntil { store.keyDescriptions["project"]?.schema?.overview?.rule(for: "SPARE") != nil && !store.isReloadingKeyDescriptions }
		try await store.renameDeclaredKey("PORT", to: "HTTP_PORT", in: "project")
		#expect(store.projects.first?.environments["default"]?["HTTP_PORT"] == "3000")
		#expect(try String(contentsOfFile: folder + "/lpm.json", encoding: .utf8).contains(#""HTTP_PORT""#))
	}

	@Test("a rename waits until no rule edits are unsaved")
	func renameNeedsEmptyDraft() async throws {
		let (store, folder) = try await makeStore(#"{"envSchema":{"vars":{"PORT":{"format":"port"}}}}"#)
		defer { store.lock(); try? FileManager.default.removeItem(atPath: folder) }
		store.editSchemaDraft(in: "project") { $0.set(.declared(try! self.json(#"{"format":"url"}"#)), for: .key("API_URL")) }
		await #expect(throws: VaultKeyEditError.description("Save or discard your rule changes before renaming a key.", keySaved: false)) {
			try await store.renameDeclaredKey("PORT", to: "HTTP_PORT", in: "project")
		}
	}

	private func makeStore(_ lpmJSON: String) async throws -> (VaultStore, String) {
		let folder = FileManager.default.temporaryDirectory.appending(path: "schema-history-\(UUID().uuidString)").path
		try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
		try lpmJSON.write(toFile: folder + "/lpm.json", atomically: true, encoding: .utf8)
		let environments = ["default": ["PORT": "3000"]]
		let keychain = MockKeychainService()
		keychain.envStorage["project"] = (name: "Project", path: folder, environments: environments)
		let preferences = try #require(UserDefaults(suiteName: "schema-history-\(UUID().uuidString)"))
		let store = VaultStore(keychainService: keychain, biometricService: MockBiometricService(), apiService: MockAPIService(), preferences: preferences)
		store.projects = [VaultProject(id: "project", name: "Project", path: folder, environments: environments)]
		store.isUnlocked = true
		store.selectedProjectId = "project"
		store.reloadKeyDescriptions()
		try await waitUntil { store.keyDescriptions["project"]?.schema?.overview != nil }
		return (store, folder)
	}

	private func waitUntil(_ condition: () -> Bool) async throws {
		for _ in 0..<1000 {
			if condition() { return }
			try await Task.sleep(for: .milliseconds(5))
		}
		try #require(condition(), "Timed out")
	}
}

extension SheetInteractionTests {
	@Suite("Schema key panel", .serialized)
	@MainActor
	struct SchemaKeyPanelTests {
		static let sample = #"""
			{"envSchema":{
				"extends":["schemas/base.json"],
				"vars":{
					"API_TOKEN":{"secret":true,"description":"Bearer token for the admin API."},
					"PORT":{"format":"port","default":"3000","description":"HTTP port the server listens on."},
					"RETRY_COUNT":{"format":"integer","min":0,"max":10}
				}
			}}
			"""#

		@Test("selecting a key opens its rules for editing; an edit marks the row and saving writes lpm.json")
		func editAndSave() async throws {
			let (store, host, folder) = try await workspace()
			defer { host.window.close(); store.lock(); try? FileManager.default.removeItem(atPath: folder) }
			try await host.click("PORT")
			#expect(try await host.waitForText("STORED VALUES"))
			#expect(try await host.waitForText("Passes"))
			try host.enterText("8080", placeholder: "value")
			#expect(try await host.waitUntil { store.schemaDraft(for: "schema-panel")?.declaration(of: .key("PORT")).json?["default"] == .string("8080") })
			#expect(try await host.waitForText("1 unsaved change"))
			#expect(try await host.waitForText("Draft"))
			#expect(try await host.waitUntil { store.currentSchemaDraftEvaluation(for: "schema-panel") != nil })
			try await host.click("Save")
			#expect(try await host.waitUntil { store.schemaDraft(for: "schema-panel") == nil })
			#expect(try String(contentsOfFile: folder + "/lpm.json", encoding: .utf8).contains(#""8080""#))
		}

		@Test("a key from an imported schema is read-only until it's overridden, which edits a copy")
		func overrideInheritedKey() async throws {
			let (store, host, folder) = try await workspace()
			defer { host.window.close(); store.lock(); try? FileManager.default.removeItem(atPath: folder) }
			try await host.click("DATABASE_URL")
			#expect(try await host.waitForText("Read-only"))
			#expect(try await host.waitForText("Override rules"))
			try await host.click("Override rules")
			#expect(try await host.waitUntil { if case .overridden? = store.schemaDraft(for: "schema-panel")?.declaration(of: .key("DATABASE_URL")) { true } else { false } })
			#expect(try await host.waitForText("editing a copy of the rule"))
			let copy = try #require(store.schemaDraft(for: "schema-panel")?.declaration(of: .key("DATABASE_URL")).json)
			#expect(copy.isEquivalent(to: try LPMConfigJSON(parsing: Data(#"{"required":true,"format":"url","protocols":["postgres"],"secret":true}"#.utf8))),
				"The copy has only the fields the original sets")
		}

		@Test("a rule the LPM CLI would reject says why next to the row, with a fix")
		func conflictWithFix() async throws {
			let (store, host, folder) = try await workspace()
			defer { host.window.close(); store.lock(); try? FileManager.default.removeItem(atPath: folder) }
			try await host.click("PORT")
			#expect(try await host.waitForText("STORED VALUES"))
			store.editSchemaDraft(in: "schema-panel") {
				$0.set(.declared(try! LPMConfigJSON(parsing: Data(#"{"format":"port","default":"3000","description":"HTTP port the server listens on.","secret":true}"#.utf8))), for: .key("PORT"))
			}
			#expect(try await host.waitForText("Secret keys can't have a default."))
			try await host.click("Turn off Secret")
			#expect(try await host.waitUntil { store.schemaDraft(for: "schema-panel") == nil }, "Turning Secret off restores the saved rule")
			#expect(try await host.waitForTextToDisappear("Secret keys can't have a default."))
		}

		@Test("⌘Z undoes the last rule change while the panel is open")
		func undoShortcut() async throws {
			let (store, host, folder) = try await workspace()
			defer { host.window.close(); store.lock(); try? FileManager.default.removeItem(atPath: folder) }
			try await host.click("RETRY_COUNT")
			#expect(try await host.waitForText("STORED VALUES"))
			store.editSchemaDraft(in: "schema-panel") {
				$0.set(.declared(try! LPMConfigJSON(parsing: Data(#"{"format":"integer","min":0,"max":5}"#.utf8))), for: .key("RETRY_COUNT"))
			}
			try await host.settle()
			#expect(try host.command("z", code: 6))
			#expect(try await host.waitUntil { store.schemaDraft(for: "schema-panel") == nil })
			#expect(try host.command("z", code: 6, shift: true))
			#expect(try await host.waitUntil { store.schemaDraft(for: "schema-panel") != nil })
		}

		private func workspace() async throws -> (VaultStore, SheetTestHost<some View>, String) {
			let folder = FileManager.default.temporaryDirectory.appending(path: "schema-panel-\(UUID().uuidString)").path
			try FileManager.default.createDirectory(atPath: folder + "/schemas", withIntermediateDirectories: true)
			try Self.sample.write(toFile: folder + "/lpm.json", atomically: true, encoding: .utf8)
			try #"{"vars":{"DATABASE_URL":{"format":"url","required":true,"protocols":["postgres"],"secret":true}}}"#
				.write(toFile: folder + "/schemas/base.json", atomically: true, encoding: .utf8)
			let keychain = MockKeychainService()
			let project = VaultProject(id: "schema-panel", name: "billing-app", path: folder, environments: [
				"default": ["PORT": "3000", "RETRY_COUNT": "7", "DATABASE_URL": "postgres://db"],
			])
			keychain.envStorage[project.id] = (name: project.name, path: folder, environments: project.environments)
			let store = VaultStore(keychainService: keychain, biometricService: MockBiometricService(),
				apiService: MockAPIService(), authTokenProvider: { _, _ in nil })
			store.isUnlocked = true
			store.projects = [project]
			store.openProject(id: project.id)
			await store.refreshCliAccess()
			let defaults = try #require(UserDefaults(suiteName: "schema-panel-interaction"))
			let host = SheetTestHost(VaultWorkspaceView(store: store).environment(UpdateChecker())
				.environment(VaultAppearanceSettings(defaults: defaults)).defaultAppStorage(defaults),
				size: NSSize(width: 1400, height: 760), keepsRequestedSize: true, usesHostingView: true)
			#expect(try await host.waitUntil { store.keyDescriptions[project.id]?.schema?.overview != nil })
			try await host.click("Schema")
			#expect(try await host.waitForText("RETRY_COUNT"))
			return (store, host, folder)
		}
	}
}
