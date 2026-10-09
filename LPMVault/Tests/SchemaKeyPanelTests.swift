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
		await #expect(throws: VaultKeyEditError.refused("Save or discard your rule changes before renaming a key.")) {
			try await store.renameDeclaredKey("PORT", to: "HTTP_PORT", in: "project")
		}
	}

	@Test("a rename that fails leaves nothing unsaved behind, so another name can be tried")
	func failedRenameLeavesNoDraft() async throws {
		let (store, folder) = try await makeStore(#"{"envSchema":{"vars":{"PORT":{"format":"port"}}}}"#, environments: ["default": ["PORT": "3000", "HTTP_PORT": "80"]])
		defer { store.lock(); try? FileManager.default.removeItem(atPath: folder) }
		await #expect(throws: VaultKeyEditError.collision(environment: "default", existingKey: "HTTP_PORT", newKey: "HTTP_PORT")) {
			try await store.renameDeclaredKey("PORT", to: "HTTP_PORT", in: "project")
		}
		#expect(store.keyDrafts.draft(.init(projectID: "project", key: "PORT")) == nil)
		#expect(store.keyDrafts.editedKeys(in: "project").isEmpty)
		try await store.renameDeclaredKey("PORT", to: "WEB_PORT", in: "project")
		#expect(store.projects.first?.environments["default"]?["WEB_PORT"] == "3000")
	}

	@Test("a key isn't renamed while the project's values are loading, which would leave them under the old name")
	func renameWaitsForValues() async throws {
		let (store, folder) = try await makeStore(#"{"envSchema":{"vars":{"API_TOKEN":{"secret":true,"required":true}}}}"#, environments: ["default": ["API_TOKEN": "t"]])
		defer { store.lock(); try? FileManager.default.removeItem(atPath: folder) }
		store.projects = [VaultProject(metadata: .init(id: "project", name: "Project", path: folder, environmentSummaries: []))]
		await #expect(throws: VaultKeyEditError.refused("Project's values are still loading. Rename the key once they've loaded.")) {
			try await store.renameDeclaredKey("API_TOKEN", to: "ADMIN_TOKEN", in: "project")
		}
		#expect(try String(contentsOfFile: folder + "/lpm.json", encoding: .utf8).contains(#""API_TOKEN""#))
	}

	@Test("a key stored since its values were read isn't renamed in lpm.json alone")
	func renameChecksTheKeychain() async throws {
		let (store, folder, keychain) = try await makeStoreWithKeychain(#"{"envSchema":{"vars":{"API_TOKEN":{"secret":true}}}}"#, environments: ["default": [:]])
		defer { store.lock(); try? FileManager.default.removeItem(atPath: folder) }
		keychain.envStorage["project"] = (name: "Project", path: folder, environments: ["default": ["API_TOKEN": "t"]])
		await #expect(throws: VaultKeyEditError.changed) {
			try await store.renameDeclaredKey("API_TOKEN", to: "ADMIN_TOKEN", in: "project")
		}
		#expect(try String(contentsOfFile: folder + "/lpm.json", encoding: .utf8).contains(#""API_TOKEN""#))
		#expect(keychain.envStorage["project"]?.environments["default"]?["API_TOKEN"] == "t")
	}

	@Test("renaming a key nothing stores writes lpm.json and leaves the Keychain alone")
	func ruleOnlyRename() async throws {
		let (store, folder, keychain) = try await makeStoreWithKeychain(#"{"envSchema":{"vars":{"PORT":{"format":"port"},"UNUSED":{}}}}"#, environments: ["default": ["PORT": "3000"]])
		defer { store.lock(); try? FileManager.default.removeItem(atPath: folder) }
		let writes = keychain.applyVaultTransactionCallCount
		try await store.renameDeclaredKey("UNUSED", to: "SPARE", in: "project")
		#expect(keychain.applyVaultTransactionCallCount == writes)
		#expect(try String(contentsOfFile: folder + "/lpm.json", encoding: .utf8).contains(#""SPARE""#))
	}

	@Test("lpm.json's rules are parsed once while they stay the same, however often they're read")
	func baseIsParsedOnce() async throws {
		let vars = (0..<4096).map { #""KEY_\#($0)":{"format":"port","default":"\#($0 % 65535 + 1)","description":"Port \#($0)"}"# }.joined(separator: ",")
		let (store, folder) = try await makeStore(#"{"envSchema":{"vars":{\#(vars)}}}"#)
		defer { store.lock(); try? FileManager.default.removeItem(atPath: folder) }
		#expect(store.schemaDraftOrBase(for: "project").declaration(of: .key("KEY_7")).json?["default"] == .string("8"))
		let start = ContinuousClock.now
		for index in 0..<500 { _ = store.schemaDraftOrBase(for: "project").declaration(of: .key("KEY_\(index)")) }
		#expect(ContinuousClock.now - start < .seconds(1), "Reading the rules parses lpm.json again")

		try #"{"envSchema":{"vars":{"OTHER":{}}}}"#.write(toFile: folder + "/lpm.json", atomically: true, encoding: .utf8)
		store.reloadKeyDescriptions()
		try await waitUntil { store.keyDescriptions["project"]?.schema?.overview?.rule(for: "OTHER") != nil }
		#expect(store.schemaDraftOrBase(for: "project").declaration(of: .key("OTHER")) == .declared(.object([])), "New rules replace the parsed ones")
	}

	@Test("errors that name an imported schema escape characters that hide or reorder text")
	func escapedErrorSources() {
		let message = ProjectEnvSchemaFile.FileError.fragmentReference("schemas/safe\u{202E}nosj.lave.json").localizedDescription
		#expect(!message.hasHiddenCharacters)
		#expect(message.contains("\\u{202e}"))
	}

	@Test("row descriptions escape hidden characters, with or without a draft")
	func escapedRowDescriptions() throws {
		let saved = ["A": "Safe\u{202E}txt"]
		#expect(VaultSchemaView.rowDescription(of: "A", saved: saved, draft: nil, draftOverview: nil)?.hasHiddenCharacters == false)
		var draft = ProjectEnvSchemaDraft(schema: try json(#"{"vars":{"A":{"description":"x"}}}"#))
		draft.set(.declared(try json(#"{"description":"New\u202Etxt"}"#)), for: .key("A"))
		#expect(VaultSchemaView.rowDescription(of: "A", saved: saved, draft: draft, draftOverview: nil)?.hasHiddenCharacters == false)
	}

	private func makeStore(_ lpmJSON: String, environments: [String: [String: String]] = ["default": ["PORT": "3000"]]) async throws -> (VaultStore, String) {
		let (store, folder, _) = try await makeStoreWithKeychain(lpmJSON, environments: environments)
		return (store, folder)
	}

	private func makeStoreWithKeychain(_ lpmJSON: String, environments: [String: [String: String]]) async throws -> (VaultStore, String, MockKeychainService) {
		let folder = FileManager.default.temporaryDirectory.appending(path: "schema-history-\(UUID().uuidString)").path
		try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
		try lpmJSON.write(toFile: folder + "/lpm.json", atomically: true, encoding: .utf8)
		let keychain = MockKeychainService()
		keychain.envStorage["project"] = (name: "Project", path: folder, environments: environments)
		let preferences = try #require(UserDefaults(suiteName: "schema-history-\(UUID().uuidString)"))
		let store = VaultStore(keychainService: keychain, biometricService: MockBiometricService(), apiService: MockAPIService(), preferences: preferences)
		store.projects = [VaultProject(id: "project", name: "Project", path: folder, environments: environments)]
		store.isUnlocked = true
		store.selectedProjectId = "project"
		store.reloadKeyDescriptions()
		try await waitUntil { store.keyDescriptions["project"]?.schema?.overview != nil }
		return (store, folder, keychain)
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
			try await host.click("Review & save")
			#expect(try await host.waitUntil { host.window.sheets.first != nil })
			let sheet = try #require(host.window.sheets.first)
			#expect(try await host.waitForText("Review changes to lpm.json", in: sheet))
			let save = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
				windowNumber: sheet.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
			#expect(sheet.performKeyEquivalent(with: save))
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
			try host.shortcut("z", code: 6)
			#expect(try await host.waitUntil { store.schemaDraft(for: "schema-panel") == nil })
			try host.shortcut("z", code: 6, shift: true)
			#expect(try await host.waitUntil { store.schemaDraft(for: "schema-panel") != nil })
		}

		@Test("⌘Z in a field being edited undoes typing, not a rule change")
		func undoLeavesTypingAlone() async throws {
			let (store, host, folder) = try await workspace()
			defer { host.window.close(); store.lock(); try? FileManager.default.removeItem(atPath: folder) }
			try await host.click("PORT")
			#expect(try await host.waitForText("STORED VALUES"))
			try host.typeText("80", placeholder: "value")
			#expect(try await host.waitUntil { store.schemaDraft(for: "schema-panel")?.declaration(of: .key("PORT")).json?["default"] == .string("80") })
			try host.shortcut("z", code: 6)
			try await host.settle()
			#expect(store.schemaDraft(for: "schema-panel")?.declaration(of: .key("PORT")).json?["default"] == .string("80"))
			host.window.makeFirstResponder(nil)
			try host.shortcut("z", code: 6)
			#expect(try await host.waitUntil { store.schemaDraft(for: "schema-panel") == nil })
		}

		@Test("clearing a field keeps its row, so a new value can be typed")
		func clearedRowStays() async throws {
			let (store, host, folder) = try await workspace()
			defer { host.window.close(); store.lock(); try? FileManager.default.removeItem(atPath: folder) }
			try await host.click("PORT")
			#expect(try await host.waitForText("STORED VALUES"))
			try host.enterText("", placeholder: "value")
			#expect(try await host.waitUntil { store.schemaDraft(for: "schema-panel")?.declaration(of: .key("PORT")).json?["default"] == nil })
			try await host.settle()
			#expect(host.hasField(placeholder: "value"))
			try host.enterText("8080", placeholder: "value")
			#expect(try await host.waitUntil { store.schemaDraft(for: "schema-panel")?.declaration(of: .key("PORT")).json?["default"] == .string("8080") })
		}

		@Test("a default the rule rejects says why in words, on its row")
		func invalidDefault() async throws {
			let (store, host, folder) = try await workspace()
			defer { host.window.close(); store.lock(); try? FileManager.default.removeItem(atPath: folder) }
			try await host.click("PORT")
			#expect(try await host.waitForText("STORED VALUES"))
			try host.enterText("abc", placeholder: "value")
			#expect(try await host.waitForText("The default doesn't match the format."))
			#expect(try await !host.text().contains("env.invalid_format"))
			#expect(try await host.waitForText("Fix the problem above to save."))
		}

		@Test("an empty scoped default that the rule rejects is named on its row")
		func emptyScopedDefault() async throws {
			let (store, host, folder) = try await workspace()
			defer { host.window.close(); store.lock(); try? FileManager.default.removeItem(atPath: folder) }
			try await host.click("PORT")
			#expect(try await host.waitForText("STORED VALUES"))
			store.editSchemaDraft(in: "schema-panel") {
				$0.set(.declared(try! LPMConfigJSON(parsing: Data(#"{"format":"port","empty":"reject","defaultsIn":[{"when":{"stage":["build"]},"value":""}]}"#.utf8))), for: .key("PORT"))
			}
			#expect(try await host.waitForText("An empty scoped default can't be used"))
		}

		@Test("adding the CI storage row writes nothing until a storage is chosen")
		func addingCIStorageWritesNothing() async throws {
			let (store, host, folder) = try await workspace()
			defer { host.window.close(); store.lock(); try? FileManager.default.removeItem(atPath: folder) }
			try await host.click("RETRY_COUNT")
			#expect(try await host.waitForText("STORED VALUES"))
			try await host.click("Add rule")
			try await host.click("CI storage", in: try await host.popoverWindow())
			#expect(try await host.waitForText("variable"))
			#expect(store.schemaDraft(for: "schema-panel") == nil)
		}

		@Test("renaming says when the new name makes a key public, and a secret key can't take a public prefix")
		func renameExposure() async throws {
			let (store, host, folder) = try await workspace()
			defer { host.window.close(); store.lock(); try? FileManager.default.removeItem(atPath: folder) }
			try await host.click("PORT")
			#expect(try await host.waitForText("STORED VALUES"))
			try host.enterText("NEXT_PUBLIC_PORT", placeholder: "KEY_NAME")
			#expect(try await host.waitForText("Becomes public"))
			try await host.click("API_TOKEN")
			#expect(try await host.waitForText("Bearer token"))
			try host.enterText("NEXT_PUBLIC_TOKEN", placeholder: "KEY_NAME")
			#expect(try await host.waitForText("Secret keys can't start with NEXT_PUBLIC_"))
		}

		@Test("a rename from the panel follows the key to its new name")
		func renameFromPanel() async throws {
			let (store, host, folder) = try await workspace()
			defer { host.window.close(); store.lock(); try? FileManager.default.removeItem(atPath: folder) }
			try await host.click("RETRY_COUNT")
			#expect(try await host.waitForText("STORED VALUES"))
			try host.typeText("RETRIES", placeholder: "KEY_NAME")
			#expect(try await host.waitForText("values in 1 environment"))
			try host.pressWhileEditing("\r", code: 36)
			#expect(try await host.waitUntil { store.projects.first?.environments["default"]?["RETRIES"] == "7" })
			#expect(try String(contentsOfFile: folder + "/lpm.json", encoding: .utf8).contains(#""RETRIES""#))
			#expect(try await host.waitForText("checked against these rules"))
			#expect(try await host.waitUntil { host.hasField(placeholder: "KEY_NAME") })
		}

		@Test("resetting an override shows the imported rule it brings back, until it's kept or saved")
		func resetOverride() async throws {
			let (store, host, folder) = try await workspace(Self.overridden)
			defer { host.window.close(); store.lock(); try? FileManager.default.removeItem(atPath: folder) }
			try await host.click("DATABASE_URL")
			#expect(try await host.waitForText("Overridden"))
			try await host.click("Reset to original")
			#expect(try await host.waitForText("Keep override"))
			#expect(try await host.waitForText("postgres only"))
			#expect(try await !host.text().contains("isn't declared"))
			try await host.click("Keep override")
			#expect(try await host.waitUntil { store.schemaDraft(for: "schema-panel") == nil })
			#expect(try await host.waitForText("Reset to original"))
		}

		@Test("discarding an edited override goes back to reading it")
		func discardOverrideEdit() async throws {
			let (store, host, folder) = try await workspace(Self.overridden)
			defer { host.window.close(); store.lock(); try? FileManager.default.removeItem(atPath: folder) }
			try await host.click("DATABASE_URL")
			try await host.click("Edit override")
			#expect(try await host.waitForText("editing a copy"))
			store.editSchemaDraft(in: "schema-panel") {
				$0.set(.overridden(try! LPMConfigJSON(parsing: Data(#"{"format":"url","required":true,"secret":true,"description":"Primary"}"#.utf8))), for: .key("DATABASE_URL"))
			}
			try await host.click("Discard")
			#expect(try await host.waitUntil { store.schemaDraft(for: "schema-panel") == nil })
			#expect(try await host.waitForText("Edit override"))
		}

		@Test("a key can't be made secret while another key compares its value, and Save says which key blocks it")
		func secretComparedElsewhere() async throws {
			let (store, host, folder) = try await workspace(#"{"envSchema":{"vars":{"MODE":{},"X":{"requiredWhen":{"variable":"MODE","equals":"on"}}}}}"#)
			defer { host.window.close(); store.lock(); try? FileManager.default.removeItem(atPath: folder) }
			try await host.click("MODE")
			#expect(try await host.waitForText("STORED VALUES"))
			store.editSchemaDraft(in: "schema-panel") { $0.set(.declared(.object([.init(key: "secret", value: .bool(true))])), for: .key("MODE")) }
			#expect(try await host.waitForText("X compares this key's value"))
			#expect(try await host.waitForText("X has a problem"))
		}

		@Test("text with characters that hide or reorder it is shown escaped next to its field")
		func hiddenCharacters() async throws {
			let (store, host, folder) = try await workspace(#"{"envSchema":{"vars":{"PORT":{"description":"Port ‮ txt"}}}}"#)
			defer { host.window.close(); store.lock(); try? FileManager.default.removeItem(atPath: folder) }
			try await host.click("PORT")
			#expect(try await host.waitForText("Has hidden or reordering characters"))
		}

		static let overridden = #"""
			{"envSchema":{
				"extends":["schemas/base.json"],
				"overrides":{"DATABASE_URL":{"format":"url","required":true,"secret":true}},
				"vars":{"PORT":{"format":"port","default":"3000"}}
			}}
			"""#

		private func workspace(_ sample: String = Self.sample) async throws -> (VaultStore, SheetTestHost<some View>, String) {
			let folder = FileManager.default.temporaryDirectory.appending(path: "schema-panel-\(UUID().uuidString)").path
			try FileManager.default.createDirectory(atPath: folder + "/schemas", withIntermediateDirectories: true)
			try sample.write(toFile: folder + "/lpm.json", atomically: true, encoding: .utf8)
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
			#expect(try await host.waitForText("enforced by LPM CLI"))
			return (store, host, folder)
		}
	}
}

@Suite("Schema panel inputs")
struct SchemaPanelInputTests {
	@Test("URL schemes are taken as typed, without case or a colon", arguments: [
		("HTTPS://", String?.some("https")), (" git+ssh: ", "git+ssh"), ("s3", "s3"), ("  ", nil),
	])
	func schemes(entry: String, expected: String?) {
		#expect(VaultChipField.scheme(entry) == expected)
	}

	@Test("allowed values keep quoted spaces, and \"\" is the empty value")
	func literals() {
		#expect(VaultChipField.literal(#""""#) == "")
		#expect(VaultChipField.literal(#"" padded ""#) == " padded ")
		#expect(VaultChipField.literal("  plain  ") == "plain")
		#expect(VaultChipField.literal("   ") == nil)
		#expect(VaultChipField.display("") == #""""#)
		#expect(VaultChipField.display(" padded") == #"" padded""#)
		#expect(VaultChipField.display("rtl\u{202E}") == #"rtl\u{202e}"#)
	}

	@Test("a scope edited while lpm.json changed is replaced where it is, or added when it's gone")
	func replacingScopes() {
		typealias Scope = ProjectEnvSchemaRule.Scope
		let production = Scope(environments: ["production"]), staging = Scope(environments: ["staging"]), build = Scope(stages: [.build])
		#expect([production, staging].replacingEntry(staging, with: build) == [production, build])
		#expect([production].replacingEntry(staging, with: build) == [production, build])
		#expect([production].replacingEntry(nil, with: build) == [production, build])
	}

	@Test("the key picker lists names that start with the search before names that contain it")
	func keyPickerMatches() {
		let keys = ["API_URL", "DATABASE_URL", "URL_SIGNING_KEY"]
		#expect(VaultKeyPicker.matches("url", in: keys) == ["URL_SIGNING_KEY", "API_URL", "DATABASE_URL"])
		#expect(VaultKeyPicker.matches(" ", in: keys) == keys)
	}
}
