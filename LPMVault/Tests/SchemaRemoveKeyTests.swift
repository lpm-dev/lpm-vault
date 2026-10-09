import AppKit
import SwiftUI
import Testing

@testable import LPMVault

@Suite("Schema key references")
struct SchemaKeyReferenceTests {
	typealias Draft = ProjectEnvSchemaDraft
	typealias Reference = ProjectEnvSchemaReference

	private func json(_ text: String) throws -> LPMConfigJSON {
		try LPMConfigJSON(parsing: Data(text.utf8), rejectDuplicateKeys: true)
	}

	@Test("a key's references are the groups that list it and the keys whose Required when names it, in lpm.json and in imports")
	func findsReferences() throws {
		let folder = try makeFolder(
			#"{"envSchema":{"extends":["base.json"],"vars":{"PASSWORD":{"secret":true},"OAUTH_TOKEN":{"secret":true,"requiredWhen":{"variable":"PASSWORD","present":false}},"MODE":{}},"groups":{"auth":{"mode":"exactlyOne","vars":["PASSWORD","OAUTH_TOKEN"]}}}}"#,
			base: #"{"vars":{"LEGACY":{"requiredWhen":{"variable":"PASSWORD","present":true},"format":"url"},"SSO":{}},"groups":{"login":{"mode":"atLeastOne","vars":["PASSWORD","SSO"]}}}"#)
		defer { try? FileManager.default.removeItem(atPath: folder) }
		let loaded = ProjectEnvSchemaFile.load(inFolder: folder, vaultID: "project")
		let draft = Draft(schema: loaded.rootSchema)
		let references = Reference.references(to: "PASSWORD", in: draft, rules: loaded.schema.overview)
		#expect(references.map(\.title) == [
			"Group auth: Exactly one of PASSWORD, OAUTH_TOKEN",
			"Group login: At least one of PASSWORD, SSO",
			"LEGACY · Required when PASSWORD is set",
			"OAUTH_TOKEN · Required when PASSWORD is not set",
		])
		#expect(references.map(\.location) == ["envSchema.groups.auth", "base.json", "base.json", "envSchema.vars.OAUTH_TOKEN.requiredWhen"])
		#expect(references.map(\.fixes) == [[.removeGroup, .dropFromGroup], [.dropFromGroup], [.removeCondition], [.removeCondition]],
			"Removing a group of two comes first, since dropping one member leaves the other required")
		#expect(references[0].note(for: .dropFromGroup) == "Leaves OAUTH_TOKEN as the group's only member, which makes it required.")
		#expect(Set(references.map(\.id)).count == references.count)
		#expect(Reference.references(to: "MODE", in: draft, rules: loaded.schema.overview).isEmpty)
	}

	@Test("fixes keep the rest of each declaration, and override what an import declares")
	func fixes() throws {
		let folder = try makeFolder(
			#"{"envSchema":{"extends":["base.json"],"vars":{"PASSWORD":{"secret":true},"OAUTH_TOKEN":{"secret":true,"requiredWhen":{"variable":"PASSWORD","present":false},"description":"Token"}},"groups":{"auth":{"vars":["PASSWORD","OAUTH_TOKEN"],"mode":"exactlyOne"}}}}"#,
			base: #"{"vars":{"LEGACY":{"requiredWhen":{"variable":"PASSWORD","present":true},"format":"url"},"SSO":{}},"groups":{"login":{"mode":"atLeastOne","vars":["PASSWORD","SSO"]}}}"#)
		defer { try? FileManager.default.removeItem(atPath: folder) }
		let loaded = ProjectEnvSchemaFile.load(inFolder: folder, vaultID: "project")
		var draft = Draft(schema: loaded.rootSchema)
		let references = Reference.references(to: "PASSWORD", in: draft, rules: loaded.schema.overview)
		let byTitle = Dictionary(uniqueKeysWithValues: references.map { ($0.item, $0) })
		#expect(byTitle[.group("auth")]?.fixed(by: .dropFromGroup) == .declared(try json(#"{"vars":["OAUTH_TOKEN"],"mode":"exactlyOne"}"#)))
		#expect(byTitle[.group("auth")]?.fixed(by: .removeGroup) == .absent)
		#expect(byTitle[.group("login")]?.fixed(by: .dropFromGroup) == .overridden(try json(#"{"mode":"atLeastOne","vars":["SSO"]}"#)))
		#expect(byTitle[.key("OAUTH_TOKEN")]?.fixed(by: .removeCondition) == .declared(try json(#"{"secret":true,"description":"Token"}"#)))
		#expect(byTitle[.key("LEGACY")]?.fixed(by: .removeCondition) == .overridden(try json(#"{"format":"url"}"#)))
		let legacy = try #require(byTitle[.key("LEGACY")])
		#expect(legacy.title(of: .removeCondition) == "Override without the rule", "A fix that writes an override says so")
		#expect(legacy.done(by: .removeCondition) == "Overridden in lpm.json")
		#expect(legacy.note(for: .removeCondition) == "Writes envSchema.overrides.LEGACY to lpm.json, which replaces base.json's version in full: later changes there won't apply.")

		for reference in references {
			draft.set(reference.fixed(by: reference.fixes[0]), for: reference.item)
		}
		draft.set(.absent, for: .key("PASSWORD"))
		let evaluation = ProjectEnvSchemaFile.evaluate(draft, inFolder: folder, environments: [:])
		#expect(evaluation.rejection == nil, "The LPM CLI accepts the rules once every reference is fixed: \(evaluation.rejection?.reason ?? "")")
	}

	@Test("an imported group the key alone is in can't be fixed in lpm.json, and says where to fix it")
	func unfixableReference() throws {
		let folder = try makeFolder(#"{"envSchema":{"extends":["base.json"]}}"#, base: #"{"vars":{"PASSWORD":{}},"groups":{"solo":{"mode":"allOrNone","vars":["PASSWORD"]}}}"#)
		defer { try? FileManager.default.removeItem(atPath: folder) }
		let loaded = ProjectEnvSchemaFile.load(inFolder: folder, vaultID: "project")
		let references = Reference.references(to: "PASSWORD", in: Draft(schema: loaded.rootSchema), rules: loaded.schema.overview)
		#expect(references.count == 1)
		#expect(references.first?.fixes.isEmpty == true)
		#expect(references.first?.unfixable == "The group has no other member and is declared in base.json. Remove it there.")
	}

	@Test("a group lpm.json overrides can go back to the import's version, which settles a reference only the override has")
	func groupOverrideReference() throws {
		let folder = try makeFolder(
			#"{"envSchema":{"extends":["base.json"],"vars":{"PASSWORD":{}},"groupOverrides":{"login":{"mode":"atLeastOne","vars":["PASSWORD"]}}}}"#,
			base: #"{"vars":{"SSO":{},"OTP":{}},"groups":{"login":{"mode":"atLeastOne","vars":["SSO","OTP"]}}}"#)
		defer { try? FileManager.default.removeItem(atPath: folder) }
		let loaded = ProjectEnvSchemaFile.load(inFolder: folder, vaultID: "project")
		var draft = Draft(schema: loaded.rootSchema)
		let references = Reference.references(to: "PASSWORD", in: draft, rules: loaded.schema.overview)
		#expect(references.map(\.fixes) == [[.removeGroupOverride]])
		#expect(references.first?.location == "envSchema.groupOverrides.login")
		draft.remove("PASSWORD", settling: references.map { ($0, .removeGroupOverride) })
		let evaluation = ProjectEnvSchemaFile.evaluate(draft, inFolder: folder, environments: [:])
		#expect(evaluation.rejection == nil, "\(evaluation.rejection?.reason ?? "")")
	}

	@Test("a key declared in both vars and overrides, which the CLI rejects, is still one reference per item")
	func duplicateDeclarations() throws {
		let schema = try json(#"{"vars":{"PASSWORD":{},"TOKEN":{"requiredWhen":{"variable":"PASSWORD","present":true}}},"overrides":{"TOKEN":{"requiredWhen":{"variable":"PASSWORD","present":false}}}}"#)
		let references = Reference.references(to: "PASSWORD", in: Draft(schema: schema), rules: nil)
		#expect(references.map(\.id) == [.key("TOKEN")])
	}

	@Test("removing says what happens to the stored values, counted in environments")
	func consequence() {
		#expect(VaultSchemaRemoveSheet.consequence(stored: 2) == "Adds the removal to your draft. Its values stay in the Keychain in 2 environments, and the LPM CLI stops checking them.")
		#expect(VaultSchemaRemoveSheet.consequence(stored: 0) == "Adds the removal to your draft. No environment stores a value for it.")
	}

	@Test("a key only an import can remove names the file that declares it, and offers only what can be done here", arguments: [
		(VaultSchemaElsewhere(source: "base.json", path: "base.json", isOverridden: true), true,
			"It's declared in base.json, which lpm.json imports, and lpm.json overrides its rules. To remove it, delete it in base.json and reset the override here: lpm.json can't override a key its imports don't declare."),
		(VaultSchemaElsewhere(source: "preset:node", path: nil, isOverridden: true), false,
			"It's declared in preset:node, which can't be edited here, and lpm.json overrides its rules. Reset the override to bring back the original rules."),
		(VaultSchemaElsewhere(source: "b.json", path: "b.json", isOverridden: false, overriddenBy: "a.json"), true,
			"It's declared in b.json, and a.json overrides its rules. Remove it from both, or override its rules in lpm.json."),
	])
	func elsewhere(elsewhere: VaultSchemaElsewhere, editable: Bool, explanation: String) {
		#expect(VaultSchemaElsewhereSheet.explanation(for: elsewhere, editable: editable) == explanation)
	}

	@Test("presets and installed packages, however the folder name is spelled, can't be edited from the project", arguments: [
		("schemas/base.json", true), ("preset:node", false), ("node_modules/pkg/schema.json", false),
		("NODE_MODULES/pkg/schema.json", false), ("node_module\u{17F}/pkg/schema.json", false),
	])
	func editableImports(path: String, editable: Bool) {
		#expect((VaultSchemaElsewhere.editable(path) != nil) == editable)
	}

	@Test("a rule one import overrides in another names the file that declares it")
	func declaringFile() throws {
		let folder = try makeFolder(#"{"envSchema":{"extends":["a.json"]}}"#, base: #"{"vars":{"KEY":{}}}"#, named: "b.json")
		defer { try? FileManager.default.removeItem(atPath: folder) }
		try #"{"extends":["b.json"],"overrides":{"KEY":{"format":"url"}}}"#.write(toFile: folder + "/a.json", atomically: true, encoding: .utf8)
		let loaded = ProjectEnvSchemaFile.load(inFolder: folder, vaultID: "project")
		let rule = try #require(loaded.schema.overview?.rule(for: "KEY"))
		#expect(rule.sourcePath == "a.json")
		#expect(rule.declaringPath == "b.json")
	}

	private func makeFolder(_ lpmJSON: String, base: String, named baseName: String = "base.json") throws -> String {
		let folder = FileManager.default.temporaryDirectory.appending(path: "references-\(UUID().uuidString)").path
		try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
		try lpmJSON.write(toFile: folder + "/lpm.json", atomically: true, encoding: .utf8)
		try base.write(toFile: folder + "/" + baseName, atomically: true, encoding: .utf8)
		return folder
	}
}

@Suite("Removing schema keys", .serialized)
@MainActor
struct SchemaRemoveKeyStoreTests {
	@Test("removing a key with its fixes is one change, and Keep in schema takes the fixes back, keeping later edits")
	func removeAndKeep() async throws {
		let (store, folder) = try await makeStore(#"{"envSchema":{"vars":{"PASSWORD":{"secret":true,"minLength":12},"OAUTH_TOKEN":{"secret":true,"requiredWhen":{"variable":"PASSWORD","present":false}},"API":{"requiredWhen":{"variable":"PASSWORD","present":true}}}}}"#)
		defer { store.lock(); try? FileManager.default.removeItem(atPath: folder) }
		store.editSchemaDraft(in: "project") { $0.set(.declared(.object([.init(key: "secret", value: .bool(true))])), for: .key("PASSWORD")) }
		let draft = store.schemaDraftOrBase(for: "project")
		let references = ProjectEnvSchemaReference.references(to: "PASSWORD", in: draft, rules: store.keyDescriptions["project"]?.schema?.overview)
		store.removeSchemaKey("PASSWORD", settling: references.map { ($0, .removeCondition) }, in: "project")
		#expect(store.schemaDraft(for: "project")?.declaration(of: .key("PASSWORD")) == .absent)
		#expect(store.schemaDraft(for: "project")?.changedItems.count == 3)

		store.editSchemaDraft(in: "project") { $0.set(.declared(.object([.init(key: "format", value: .string("url"))])), for: .key("API")) }
		store.keepSchemaKey("PASSWORD", in: "project")
		let kept = try #require(store.schemaDraft(for: "project"))
		#expect(kept.declaration(of: .key("PASSWORD")) == .declared(.object([.init(key: "secret", value: .bool(true))])), "The key comes back as the draft had it")
		#expect(!kept.hasChange(to: .key("OAUTH_TOKEN")), "Its fix goes with it")
		#expect(kept.declaration(of: .key("API")).isEquivalent(to: .declared(try LPMConfigJSON(parsing: Data(#"{"format":"url","requiredWhen":{"variable":"PASSWORD","present":true}}"#.utf8)))),
			"A rule edited since keeps the edit and gets its condition back")

		store.undoSchemaDraft(in: "project")
		#expect(store.schemaDraft(for: "project")?.declaration(of: .key("PASSWORD")) == .absent, "Keeping can be undone")
	}

	static let referenced = #"{"envSchema":{"vars":{"PASSWORD":{"secret":true},"OAUTH_TOKEN":{"secret":true,"requiredWhen":{"variable":"PASSWORD","present":false}},"OTHER":{}},"groups":{"auth":{"mode":"allOrNone","vars":["PASSWORD","OAUTH_TOKEN","OTHER"]}}}}"#

	/// Removes `key` with each reference's first fix, as Settle all does.
	private func remove(_ key: String, from store: VaultStore) {
		let references = ProjectEnvSchemaReference.references(to: key, in: store.schemaDraftOrBase(for: "project"), rules: store.keyDescriptions["project"]?.schema?.overview)
		store.removeSchemaKey(key, settling: references.map { ($0, $0.fixes[0]) }, in: "project")
	}

	@Test("Keep takes the fixes back after undo and redo, and after keeping is undone")
	func keepAfterUndo() async throws {
		let (store, folder) = try await makeStore(Self.referenced)
		defer { store.lock(); try? FileManager.default.removeItem(atPath: folder) }
		remove("PASSWORD", from: store)
		#expect(store.schemaDraft(for: "project")?.changedItems.count == 3)
		store.undoSchemaDraft(in: "project")
		#expect(store.schemaDraft(for: "project") == nil)
		store.redoSchemaDraft(in: "project")
		store.keepSchemaKey("PASSWORD", in: "project")
		#expect(store.schemaDraft(for: "project") == nil, "The removal and both fixes go")

		remove("PASSWORD", from: store)
		store.keepSchemaKey("PASSWORD", in: "project")
		store.undoSchemaDraft(in: "project")
		#expect(store.schemaDraft(for: "project")?.declaration(of: .key("PASSWORD")) == .absent)
		store.keepSchemaKey("PASSWORD", in: "project")
		#expect(store.schemaDraft(for: "project") == nil)
	}

	@Test("keys removed from one group come back to their places, kept in either order", arguments: [["A", "B"], ["B", "A"]])
	func keepSharedGroup(order: [String]) async throws {
		let (store, folder) = try await makeStore(#"{"envSchema":{"vars":{"A":{},"B":{},"C":{}},"groups":{"g":{"mode":"allOrNone","vars":["A","B","C"]}}}}"#)
		defer { store.lock(); try? FileManager.default.removeItem(atPath: folder) }
		remove("A", from: store)
		remove("B", from: store)
		#expect(store.schemaDraft(for: "project")?.declaration(of: .group("g")).json?["vars"] == .array([.string("C")]))
		for key in order { store.keepSchemaKey(key, in: "project") }
		#expect(store.schemaDraft(for: "project") == nil)
	}

	@Test("Keep leaves what lpm.json changed on disk since the removal, and brings the key back as the file has it")
	func keepAfterDiskChange() async throws {
		let (store, folder) = try await makeStore(Self.referenced)
		defer { store.lock(); try? FileManager.default.removeItem(atPath: folder) }
		remove("PASSWORD", from: store)
		// A teammate drops the same condition and gives PASSWORD a minimum length.
		try #"{"envSchema":{"vars":{"PASSWORD":{"secret":true,"minLength":20},"OAUTH_TOKEN":{"secret":true},"OTHER":{}},"groups":{"auth":{"mode":"allOrNone","vars":["PASSWORD","OAUTH_TOKEN","OTHER"]}}}}"#
			.write(toFile: folder + "/lpm.json", atomically: true, encoding: .utf8)
		store.reloadKeyDescriptions()
		for _ in 0..<1000 where store.keyDescriptions["project"]?.schema?.overview?.rule(for: "PASSWORD")?.hasLengthRule != true {
			try await Task.sleep(for: .milliseconds(5))
		}
		#expect(store.schemaDraft(for: "project")?.conflicts.map(\.item) == [.key("PASSWORD")])
		store.keepSchemaKey("PASSWORD", in: "project")
		let draft = store.schemaDraft(for: "project")
		#expect(draft?.conflicts.isEmpty != false)
		#expect(!(draft?.hasChange(to: .key("OAUTH_TOKEN")) ?? false), "The teammate's version of OAUTH_TOKEN stands")
		#expect(store.schemaDraftOrBase(for: "project").declaration(of: .key("PASSWORD")).json?["minLength"] != nil)
	}

	@Test("a removed key shows the rules keeping it brings back, with the draft's earlier edits")
	func removalKeepsEdits() async throws {
		let (store, folder) = try await makeStore(Self.referenced)
		defer { store.lock(); try? FileManager.default.removeItem(atPath: folder) }
		let edited = LPMConfigJSON.object([.init(key: "secret", value: .bool(true)), .init(key: "minLength", value: .number("20"))])
		store.editSchemaDraft(in: "project") { $0.set(.declared(edited), for: .key("PASSWORD")) }
		remove("PASSWORD", from: store)
		#expect(store.schemaDraft(for: "project")?.removal(of: "PASSWORD")?.edited == .declared(edited))
		store.keepSchemaKey("PASSWORD", in: "project")
		#expect(store.schemaDraft(for: "project")?.declaration(of: .key("PASSWORD")) == .declared(edited))
	}

	private func makeStore(_ lpmJSON: String) async throws -> (VaultStore, String) {
		let folder = FileManager.default.temporaryDirectory.appending(path: "remove-key-\(UUID().uuidString)").path
		try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
		try lpmJSON.write(toFile: folder + "/lpm.json", atomically: true, encoding: .utf8)
		let environments = ["default": ["PASSWORD": "long-enough-pass"]]
		let keychain = MockKeychainService()
		keychain.envStorage["project"] = (name: "Project", path: folder, environments: environments)
		let preferences = try #require(UserDefaults(suiteName: "remove-key-\(UUID().uuidString)"))
		let store = VaultStore(keychainService: keychain, biometricService: MockBiometricService(), apiService: MockAPIService(), preferences: preferences)
		store.projects = [VaultProject(id: "project", name: "Project", path: folder, environments: environments)]
		store.isUnlocked = true
		store.selectedProjectId = "project"
		store.reloadKeyDescriptions()
		for _ in 0..<1000 where store.keyDescriptions["project"]?.schema?.overview == nil { try await Task.sleep(for: .milliseconds(5)) }
		return (store, folder)
	}
}

extension SheetInteractionTests {
	@Suite("Removing keys from the panel", .serialized)
	@MainActor
	struct SchemaRemoveKeyInteractionTests {
		static let sample = #"""
			{"envSchema":{"extends":["schemas/base.json"],
				"vars":{
					"PASSWORD":{"secret":true,"minLength":12},
					"TOKEN":{"secret":true,"requiredWhen":{"variable":"PASSWORD","present":false}},
					"PORT":{"format":"port"}
				},
				"groups":{"auth":{"mode":"exactlyOne","vars":["PASSWORD","TOKEN"]}}
			}}
			"""#

		@Test("removing a key settles each reference first, then joins the draft as one change that Keep in schema takes back")
		func removeWithReferences() async throws {
			let (store, host, folder) = try await workspace()
			defer { host.window.close(); store.lock(); try? FileManager.default.removeItem(atPath: folder) }
			store.editSchemaDraft(in: "schema-remove") {
				$0.set(.declared(.object([.init(key: "secret", value: .bool(true)), .init(key: "minLength", value: .number("20"))])), for: .key("PASSWORD"))
			}
			try await host.click("PASSWORD")
			#expect(try await host.waitForText("STORED VALUES"))
			try host.shortcut("\u{7f}", code: 51)
			#expect(try await host.waitUntil { host.window.sheets.first != nil })
			let sheet = try #require(host.window.sheets.first)
			#expect(try await host.waitForText("REFERENCED BY", in: sheet))
			#expect(try await host.waitForText("2 references left", in: sheet))
			try await host.click("Drop from group", in: sheet)
			#expect(try await host.waitForText("Dropped from group", in: sheet))
			try await host.click("Remove rule", in: sheet)
			#expect(try await host.waitForText("Every reference is settled", in: sheet))
			#expect(store.schemaDraft(for: "schema-remove")?.changedItems == [.key("PASSWORD")], "Nothing joins the draft before Add to draft")
			try await host.click("Add to draft", in: sheet)
			#expect(try await host.waitUntil { host.window.sheets.isEmpty })
			let draft = try #require(store.schemaDraft(for: "schema-remove"))
			#expect(draft.declaration(of: .key("PASSWORD")) == .absent)
			#expect(draft.changedItems.count == 3)
			#expect(try await host.waitForText("in your draft"))
			#expect(try await host.waitForText("20+ chars"), "The rules shown are the ones keeping it brings back")
			#expect(try await host.waitUntil { store.currentSchemaDraftEvaluation(for: "schema-remove")?.rejection == nil && store.currentSchemaDraftEvaluation(for: "schema-remove") != nil },
				"The LPM CLI accepts the rules")

			try await host.click("Keep in schema")
			#expect(try await host.waitUntil {
				store.schemaDraft(for: "schema-remove")?.changedItems == [.key("PASSWORD")]
			}, "The removal and its fixes go, and the key keeps its earlier edit")

			host.window.makeFirstResponder(nil)
			try host.shortcut("z", code: 6)
			#expect(try await host.waitUntil { store.schemaDraft(for: "schema-remove")?.changedItems.count == 3 })
			#expect(try await host.waitForText("in your draft"))
			try await host.click("Discard")
			#expect(try await host.waitUntil {
				store.schemaDraft(for: "schema-remove")?.changedItems == [.key("PASSWORD")]
			}, "Discarding a removal keeps the key, with its fixes")
		}

		@Test("a fix that no longer fits the reference, after the rules change, isn't applied")
		func staleFix() async throws {
			let (store, host, folder) = try await workspace()
			defer { host.window.close(); store.lock(); try? FileManager.default.removeItem(atPath: folder) }
			try await host.click("PASSWORD")
			#expect(try await host.waitForText("STORED VALUES"))
			try host.shortcut("\u{7f}", code: 51)
			#expect(try await host.waitUntil { host.window.sheets.first != nil })
			let sheet = try #require(host.window.sheets.first)
			try await host.click("Drop from group", in: sheet)
			#expect(try await host.waitForText("1 reference left", in: sheet))
			store.editSchemaDraft(in: "schema-remove") { draft in
				draft.set(.declared(try! LPMConfigJSON(parsing: Data(#"{"mode":"exactlyOne","vars":["PASSWORD"]}"#.utf8))), for: .group("auth"))
				draft.set(.declared(.object([.init(key: "secret", value: .bool(true))])), for: .key("TOKEN"))
			}
			#expect(try await host.waitForText("1 reference left", in: sheet), "A group of one can't drop its member")
		}

		@Test("the dialog explains when the draft's problem hides what imported schemas refer to")
		func rejectedDraft() async throws {
			let (store, host, folder) = try await workspace()
			defer { host.window.close(); store.lock(); try? FileManager.default.removeItem(atPath: folder) }
			store.editSchemaDraft(in: "schema-remove") { $0.set(.declared(.object([.init(key: "format", value: .string("nope"))])), for: .key("PORT")) }
			#expect(try await host.waitUntil { store.currentSchemaDraftEvaluation(for: "schema-remove")?.rejection != nil })
			try await host.click("PASSWORD")
			#expect(try await host.waitForText("STORED VALUES"))
			try host.shortcut("\u{7f}", code: 51)
			#expect(try await host.waitUntil { host.window.sheets.first != nil })
			let sheet = try #require(host.window.sheets.first)
			#expect(try await host.waitForText("Fix the problem first", in: sheet))
		}

		@Test("many references scroll inside the dialog, which Settle all can settle at once")
		func manyReferences() async throws {
			let conditions = (0..<40).map { #""KEY_\#($0)":{"requiredWhen":{"variable":"ADMIN","present":true}}"# }.joined(separator: ",")
			let (store, host, folder) = try await workspace(#"{"envSchema":{"vars":{"ADMIN":{"format":"email"},\#(conditions)}}}"#)
			defer { host.window.close(); store.lock(); try? FileManager.default.removeItem(atPath: folder) }
			// The other rows name ADMIN in their badges; its own row, first from A to Z, is the one with Email.
			try await host.click("Email")
			#expect(try await host.waitForText("STORED VALUES"))
			try host.shortcut("\u{7f}", code: 51)
			#expect(try await host.waitUntil { host.window.sheets.first != nil })
			let sheet = try #require(host.window.sheets.first)
			#expect(try await host.waitForText("40 references left", in: sheet))
			#expect(sheet.frame.height < 700, "The list scrolls, so the dialog fits on screen")
			try await host.click("Settle all", in: sheet)
			#expect(try await host.waitForText("Every reference is settled", in: sheet))
			try await host.click("Add to draft", in: sheet)
			#expect(try await host.waitUntil { store.schemaDraft(for: "schema-remove")?.changedItems.count == 41 })
		}

		@Test("a long file name doesn't push the dialog's buttons out of view")
		func longFileName() async throws {
			let (store, host, folder) = try await workspace(basePath: "schemas/production-environment-shared-schema-for-all-services.json")
			defer { host.window.close(); store.lock(); try? FileManager.default.removeItem(atPath: folder) }
			try await host.click("DATABASE_URL")
			#expect(try await host.waitForText("Read-only"))
			try host.shortcut("\u{7f}", code: 51)
			#expect(try await host.waitUntil { host.window.sheets.first != nil })
			let sheet = try #require(host.window.sheets.first)
			#expect(try await host.waitForText("Override rules", in: sheet))
			#expect(try await host.waitForText("Cancel", in: sheet))
			#expect(try await host.waitForText("Open file", in: sheet))
		}

		@Test("a key from an imported schema can't be removed here, which the dialog explains")
		func removeImported() async throws {
			let (store, host, folder) = try await workspace()
			defer { host.window.close(); store.lock(); try? FileManager.default.removeItem(atPath: folder) }
			try await host.click("DATABASE_URL")
			#expect(try await host.waitForText("Read-only"))
			try host.shortcut("\u{7f}", code: 51)
			#expect(try await host.waitUntil { host.window.sheets.first != nil })
			let sheet = try #require(host.window.sheets.first)
			#expect(try await host.waitForText("can't be removed here", in: sheet))
			#expect(try await host.waitForText("Open file", in: sheet))
			try await host.click("Override rules", in: sheet)
			#expect(try await host.waitUntil { if case .overridden? = store.schemaDraft(for: "schema-remove")?.declaration(of: .key("DATABASE_URL")) { true } else { false } })
		}

		private func workspace(_ sample: String = Self.sample, basePath: String = "schemas/base.json") async throws -> (VaultStore, SheetTestHost<some View>, String) {
			let folder = FileManager.default.temporaryDirectory.appending(path: "schema-remove-\(UUID().uuidString)").path
			try FileManager.default.createDirectory(atPath: folder + "/schemas", withIntermediateDirectories: true)
			try sample.replacingOccurrences(of: "schemas/base.json", with: basePath).write(toFile: folder + "/lpm.json", atomically: true, encoding: .utf8)
			try #"{"vars":{"DATABASE_URL":{"format":"url"}}}"#.write(toFile: folder + "/" + basePath, atomically: true, encoding: .utf8)
			let keychain = MockKeychainService()
			let project = VaultProject(id: "schema-remove", name: "billing-app", path: folder, environments: [
				"default": ["PASSWORD": "long-enough-password", "PORT": "3000"],
				"staging": ["PASSWORD": "another-long-password", "TOKEN": "t"],
			])
			keychain.envStorage[project.id] = (name: project.name, path: folder, environments: project.environments)
			let store = VaultStore(keychainService: keychain, biometricService: MockBiometricService(),
				apiService: MockAPIService(), authTokenProvider: { _, _ in nil })
			store.isUnlocked = true
			store.projects = [project]
			store.openProject(id: project.id)
			await store.refreshCliAccess()
			let defaults = try #require(UserDefaults(suiteName: "schema-remove-interaction"))
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
