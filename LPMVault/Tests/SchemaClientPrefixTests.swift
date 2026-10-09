import AppKit
import SwiftUI
import Testing

@testable import LPMVault

@Suite("Schema client prefixes")
struct SchemaClientPrefixTests {
	typealias Prefixes = ProjectEnvSchemaClientPrefixes

	static let lpmJSON = #"""
		{"envSchema":{"extends":["base.json"],"clientPrefixes":["WIDGET_"],"vars":{
			"WIDGET_THEME":{"client":true},
			"WIDGET_HOST":{"client":true,"format":"hostname"},
			"ACME_PUBLIC_CDN":{"format":"url"},
			"ACME_PUBLIC_FLAGS":{},
			"API_TOKEN":{"secret":true},
			"NEXT_PUBLIC_API_URL":{"client":true}
		}}}
		"""#
	static let base = #"{"clientPrefixes":["SHOP_"],"vars":{"SHOP_ID":{"client":true},"ACME_PUBLIC_REGION":{"default":"eu"}}}"#

	private func loaded(_ lpmJSON: String = Self.lpmJSON) throws -> (
		folder: String, draft: ProjectEnvSchemaDraft, rules: ProjectEnvSchemaOverview?, imported: Set<String>
	) {
		let folder = FileManager.default.temporaryDirectory.appending(path: "prefixes-\(UUID().uuidString)").path
		try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
		try lpmJSON.write(toFile: folder + "/lpm.json", atomically: true, encoding: .utf8)
		try Self.base.write(toFile: folder + "/base.json", atomically: true, encoding: .utf8)
		let loaded = ProjectEnvSchemaFile.load(inFolder: folder, vaultID: "project")
		let draft = ProjectEnvSchemaDraft(schema: loaded.rootSchema)
		return (folder, draft, loaded.schema.overview, Prefixes.imported(loaded.importedClientPrefixes, draft: draft, rules: loaded.schema.overview))
	}

	@Test("a prefix has to be one the LPM CLI accepts, new, and not leave a Secret key public", arguments: [
		("1ACME_", Prefixes.Issue.invalid), ("ACME", .missingUnderscore), ("NEXT_PUBLIC_", .framework), ("react_app_", .framework),
		("WIDGET_", .duplicate), ("SHOP_", .duplicate), ("API_", .secret(key: "API_TOKEN")),
	])
	func issues(prefix: String, issue: Prefixes.Issue) throws {
		let (folder, draft, rules, _) = try loaded()
		defer { try? FileManager.default.removeItem(atPath: folder) }
		#expect(Prefixes.issue(adding: prefix, draft: draft, rules: rules) == issue)
	}

	@Test("the LPM CLI accepts at most 32 prefixes, imported ones included")
	func tooMany() throws {
		let own = (0..<31).map { "\"P\($0)_\"" }.joined(separator: ",")
		let (folder, draft, rules, _) = try loaded(#"{"envSchema":{"extends":["base.json"],"clientPrefixes":[\#(own)]}}"#)
		defer { try? FileManager.default.removeItem(atPath: folder) }
		#expect(Prefixes.issue(adding: "ACME_PUBLIC_", draft: draft, rules: rules) == .tooMany)
	}

	@Test("adding a prefix marks the keys it makes public, with an override for an imported one, which the LPM CLI accepts")
	func adding() throws {
		let (folder, draft, rules, _) = try loaded()
		defer { try? FileManager.default.removeItem(atPath: folder) }
		#expect(Prefixes.issue(adding: "ACME_PUBLIC_", draft: draft, rules: rules) == nil)
		let change = Prefixes.adding("ACME_PUBLIC_", draft: draft, rules: rules)
		#expect(change.keys == ["ACME_PUBLIC_CDN", "ACME_PUBLIC_FLAGS", "ACME_PUBLIC_REGION"])
		#expect(change.overridden == ["ACME_PUBLIC_REGION"])
		var updated = draft
		updated.set(change.edits.map { ($0.item, $0.declaration) })
		#expect(Prefixes.own(in: updated) == ["WIDGET_", "ACME_PUBLIC_"])
		#expect(updated.declaration(of: .key("ACME_PUBLIC_CDN")).json?["client"] == .bool(true))
		#expect(updated.declaration(of: .key("ACME_PUBLIC_CDN")).json?["format"] == .string("url"), "The rest of the rule stays")
		#expect(updated.declaration(of: .key("ACME_PUBLIC_REGION")).json?["client"] == .bool(true))
		if case .overridden = updated.declaration(of: .key("ACME_PUBLIC_REGION")) {} else { Issue.record("An imported key is overridden") }
		let evaluation = ProjectEnvSchemaFile.evaluate(updated, inFolder: folder, environments: [:])
		#expect(evaluation.rejection == nil, "\(evaluation.rejection?.reason ?? "")")
		#expect(evaluation.overview?.publicKeys.isSuperset(of: change.keys) == true)
	}

	@Test("removing a prefix marks private the public keys no other prefix covers, and drops an empty list, which the LPM CLI accepts")
	func removing() throws {
		let (folder, draft, rules, imported) = try loaded()
		defer { try? FileManager.default.removeItem(atPath: folder) }
		#expect(imported == ["SHOP_"])
		#expect(Prefixes.keys(removing: "WIDGET_", imported: imported, draft: draft, rules: rules) == ["WIDGET_HOST", "WIDGET_THEME"])
		let change = Prefixes.removing("WIDGET_", imported: imported, draft: draft, rules: rules)
		var updated = draft
		updated.set(change.edits.map { ($0.item, $0.declaration) })
		#expect(updated.declaration(of: .clientPrefixes) == .absent, "Without prefixes of its own, lpm.json has no list")
		#expect(updated.declaration(of: .key("WIDGET_THEME")) == .declared(.object([])))
		#expect(updated.declaration(of: .key("WIDGET_HOST")).json?["client"] == nil)
		let evaluation = ProjectEnvSchemaFile.evaluate(updated, inFolder: folder, environments: [:])
		#expect(evaluation.rejection == nil, "\(evaluation.rejection?.reason ?? "")")
	}

	@Test("removing a prefix an import also lists leaves its keys public")
	func importedDuplicate() throws {
		let (folder, draft, rules, imported) = try loaded(#"{"envSchema":{"extends":["base.json"],"clientPrefixes":["SHOP_"]}}"#)
		defer { try? FileManager.default.removeItem(atPath: folder) }
		#expect(imported == ["SHOP_"], "The imports' prefixes are told apart from lpm.json's own")
		#expect(Prefixes.keys(removing: "SHOP_", imported: imported, draft: draft, rules: rules).isEmpty)
	}
}

extension SheetInteractionTests {
	@Suite("Editing client prefixes", .serialized)
	@MainActor
	struct SchemaClientPrefixInteractionTests {
		@Test("adding a prefix lists the keys it makes public and joins the draft with them; a Secret key blocks it")
		func addPrefix() async throws {
			let (store, host, folder) = try await workspace()
			defer { host.window.close(); store.lock(); try? FileManager.default.removeItem(atPath: folder) }
			try await host.click("Client prefixes")
			let popover = try await host.popoverWindow()
			#expect(try await host.waitForText("WIDGET_", in: popover))
			try host.typeText("API_", placeholder: "NEW_PREFIX_", in: popover)
			#expect(try await host.waitForText("is Secret", in: popover))
			try host.typeText("ACME_PUBLIC_", placeholder: "NEW_PREFIX_", in: popover)
			#expect(try await host.waitForText("marked Public", in: popover))
			try await host.click("Add", in: popover)
			#expect(try await host.waitUntil {
				let draft = store.schemaDraft(for: "schema-prefixes")
				return draft.map(ProjectEnvSchemaClientPrefixes.own(in:)) == ["WIDGET_", "ACME_PUBLIC_"]
					&& draft?.declaration(of: .key("ACME_PUBLIC_CDN")).json?["client"] == .bool(true)
			})
			#expect(try await host.waitUntil { store.currentSchemaDraftEvaluation(for: "schema-prefixes")?.rejection == nil && store.currentSchemaDraftEvaluation(for: "schema-prefixes") != nil })
		}

		@Test("removing a prefix public keys rely on asks first, then marks them private in the same change")
		func removePrefix() async throws {
			let (store, host, folder) = try await workspace()
			defer { host.window.close(); store.lock(); try? FileManager.default.removeItem(atPath: folder) }
			try await host.click("Client prefixes")
			let popover = try await host.popoverWindow()
			#expect(try await host.waitForText("WIDGET_", in: popover))
			// The prefix's remove button is the × right after its key count.
			let count = try await host.labelFrame("2 keys", in: popover)
			try NativeTestClick.send(to: popover, at: NSPoint(x: count.maxX + 11, y: count.midY))
			#expect(try await host.waitForText("become private", in: popover))
			#expect(store.schemaDraft(for: "schema-prefixes") == nil, "Nothing changes before Remove")
			try await host.click("Remove", in: popover)
			#expect(try await host.waitUntil {
				let draft = store.schemaDraft(for: "schema-prefixes")
				return draft?.declaration(of: .clientPrefixes) == .absent && draft?.declaration(of: .key("WIDGET_THEME")).json?["client"] == nil
			})
		}

		private func workspace() async throws -> (VaultStore, SheetTestHost<some View>, String) {
			let folder = FileManager.default.temporaryDirectory.appending(path: "schema-prefixes-\(UUID().uuidString)").path
			try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
			try SchemaClientPrefixTests.lpmJSON.write(toFile: folder + "/lpm.json", atomically: true, encoding: .utf8)
			try SchemaClientPrefixTests.base.write(toFile: folder + "/base.json", atomically: true, encoding: .utf8)
			let keychain = MockKeychainService()
			let project = VaultProject(id: "schema-prefixes", name: "billing-app", path: folder, environments: ["default": ["WIDGET_THEME": "dark"]])
			keychain.envStorage[project.id] = (name: project.name, path: folder, environments: project.environments)
			let store = VaultStore(keychainService: keychain, biometricService: MockBiometricService(),
				apiService: MockAPIService(), authTokenProvider: { _, _ in nil })
			store.isUnlocked = true
			store.projects = [project]
			store.openProject(id: project.id)
			await store.refreshCliAccess()
			let defaults = try #require(UserDefaults(suiteName: "schema-prefixes-interaction"))
			defaults.set(VaultKeySortOrder.ascending.rawValue, forKey: VaultKeySortOrder.defaultsKey)
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
