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
		#expect(references.map(\.fixes) == [[.dropFromGroup, .removeGroup], [.dropFromGroup], [.removeCondition], [.removeCondition]])
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

	private func makeFolder(_ lpmJSON: String, base: String) throws -> String {
		let folder = FileManager.default.temporaryDirectory.appending(path: "references-\(UUID().uuidString)").path
		try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
		try lpmJSON.write(toFile: folder + "/lpm.json", atomically: true, encoding: .utf8)
		try base.write(toFile: folder + "/base.json", atomically: true, encoding: .utf8)
		return folder
	}
}

@Suite("Removing schema keys", .serialized)
@MainActor
struct SchemaRemoveKeyStoreTests {
	@Test("removing a key with its fixes is one change, and Keep in schema takes back the fixes that weren't edited since")
	func removeAndKeep() async throws {
		let (store, folder) = try await makeStore(#"{"envSchema":{"vars":{"PASSWORD":{"secret":true,"minLength":12},"OAUTH_TOKEN":{"secret":true,"requiredWhen":{"variable":"PASSWORD","present":false}},"API":{"requiredWhen":{"variable":"PASSWORD","present":true}}}}}"#)
		defer { store.lock(); try? FileManager.default.removeItem(atPath: folder) }
		store.editSchemaDraft(in: "project") { $0.set(.declared(.object([.init(key: "secret", value: .bool(true))])), for: .key("PASSWORD")) }
		let draft = store.schemaDraftOrBase(for: "project")
		let references = ProjectEnvSchemaReference.references(to: "PASSWORD", in: draft, rules: store.keyDescriptions["project"]?.schema?.overview)
		store.removeSchemaKey("PASSWORD", fixes: references.map { ($0.item, $0.fixed(by: .removeCondition)) }, in: "project")
		#expect(store.schemaDraft(for: "project")?.declaration(of: .key("PASSWORD")) == .absent)
		#expect(store.schemaDraft(for: "project")?.changedItems.count == 3)

		store.editSchemaDraft(in: "project") { $0.set(.declared(.object([.init(key: "format", value: .string("url"))])), for: .key("API")) }
		store.keepSchemaKey("PASSWORD", in: "project")
		let kept = try #require(store.schemaDraft(for: "project"))
		#expect(kept.declaration(of: .key("PASSWORD")) == .declared(.object([.init(key: "secret", value: .bool(true))])), "The key comes back as the draft had it")
		#expect(!kept.hasChange(to: .key("OAUTH_TOKEN")), "Its fix goes with it")
		#expect(kept.declaration(of: .key("API")) == .declared(.object([.init(key: "format", value: .string("url"))])), "A fix edited since stays")

		store.undoSchemaDraft(in: "project")
		#expect(store.schemaDraft(for: "project")?.declaration(of: .key("PASSWORD")) == .absent, "Keeping can be undone")
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
			#expect(store.schemaDraft(for: "schema-remove") == nil, "Nothing joins the draft before Add to draft")
			try await host.click("Add to draft", in: sheet)
			#expect(try await host.waitUntil { host.window.sheets.isEmpty })
			let draft = try #require(store.schemaDraft(for: "schema-remove"))
			#expect(draft.declaration(of: .key("PASSWORD")) == .absent)
			#expect(draft.changedItems.count == 3)
			#expect(try await host.waitForText("in your draft"))
			#expect(try await host.waitUntil { store.currentSchemaDraftEvaluation(for: "schema-remove")?.rejection == nil && store.currentSchemaDraftEvaluation(for: "schema-remove") != nil },
				"The LPM CLI accepts the rules")

			try await host.click("Keep in schema")
			#expect(try await host.waitUntil { store.schemaDraft(for: "schema-remove") == nil }, "The removal and its fixes go")
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
			#expect(try await host.waitForText("Open base.json", in: sheet))
			try await host.click("Override rules", in: sheet)
			#expect(try await host.waitUntil { if case .overridden? = store.schemaDraft(for: "schema-remove")?.declaration(of: .key("DATABASE_URL")) { true } else { false } })
		}

		private func workspace() async throws -> (VaultStore, SheetTestHost<some View>, String) {
			let folder = FileManager.default.temporaryDirectory.appending(path: "schema-remove-\(UUID().uuidString)").path
			try FileManager.default.createDirectory(atPath: folder + "/schemas", withIntermediateDirectories: true)
			try Self.sample.write(toFile: folder + "/lpm.json", atomically: true, encoding: .utf8)
			try #"{"vars":{"DATABASE_URL":{"format":"url"}}}"#.write(toFile: folder + "/schemas/base.json", atomically: true, encoding: .utf8)
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
