import AppKit
import SwiftUI
import Testing

@testable import LPMVault

@Suite("Schema groups")
struct SchemaGroupModelTests {
	typealias SchemaGroup = ProjectEnvSchemaGroup

	private func json(_ text: String) throws -> LPMConfigJSON {
		try LPMConfigJSON(parsing: Data(text.utf8), rejectDuplicateKeys: true)
	}

	@Test("a group reads its mode and members, and writes them back in place")
	func readsAndWrites() throws {
		let declared = try json(#"{"vars":["PASSWORD","TOKEN"],"mode":"exactlyOne"}"#)
		var group = try #require(SchemaGroup(declared))
		#expect(group == SchemaGroup(mode: .exactlyOne, members: ["PASSWORD", "TOKEN"]))
		#expect(group.summary == "Exactly one of PASSWORD, TOKEN")
		group.mode = .atLeastOne
		group.members.append("SSO")
		#expect(group.json(updating: declared) == (try json(#"{"vars":["PASSWORD","TOKEN","SSO"],"mode":"atLeastOne"}"#)), "lpm.json's member order stays")
		#expect(SchemaGroup().json() == (try json(#"{"mode":"allOrNone","vars":[]}"#)))
	}

	@Test("only a declaration the LPM CLI reads is a group", arguments: [
		#"{"mode":"someOf","vars":["A"]}"#, #"{"mode":"allOrNone"}"#, #"{"mode":"allOrNone","vars":[1]}"#,
	])
	func rejectsOtherShapes(text: String) throws {
		#expect(SchemaGroup(try json(text)) == nil)
	}

	@Test("a group of one says what its mode does with a single key", arguments: [
		(SchemaGroup.Mode.allOrNone, "With one key this always passes."),
		(.exactlyOne, "With one key this works like Required."),
		(.atLeastOne, "With one key this works like Required."),
	])
	func singleMember(mode: SchemaGroup.Mode, hint: String) {
		#expect(SchemaGroup(mode: mode, members: ["A"]).hint == hint)
		#expect(SchemaGroup(mode: mode, members: ["A", "B"]).hint == nil)
	}

	@Test("the review names the file a group override replaces, and the one a removed override brings back")
	func reviewSources() throws {
		let folder = FileManager.default.temporaryDirectory.appending(path: "group-review-\(UUID().uuidString)").path
		try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(atPath: folder) }
		try #"{"vars":{"SSO":{},"OTP":{}},"groups":{"login":{"mode":"atLeastOne","vars":["SSO","OTP"]},"mfa":{"mode":"allOrNone","vars":["OTP"]}}}"#
			.write(toFile: folder + "/base.json", atomically: true, encoding: .utf8)
		try #"{"envSchema":{"extends":["base.json"],"groupOverrides":{"mfa":{"mode":"exactlyOne","vars":["OTP"]}}}}"#
			.write(toFile: folder + "/lpm.json", atomically: true, encoding: .utf8)
		let loaded = ProjectEnvSchemaFile.load(inFolder: folder, vaultID: "project")
		var draft = ProjectEnvSchemaDraft(schema: loaded.rootSchema)
		draft.set(.overridden(try json(#"{"mode":"exactlyOne","vars":["SSO","OTP"]}"#)), for: .group("login"))
		draft.set(.absent, for: .group("mfa"))
		let evaluation = ProjectEnvSchemaFile.evaluate(draft, inFolder: folder, environments: [:])
		let project = VaultProject(id: "project", name: "Project", path: folder, environments: [:])
		let review = try #require(ProjectEnvSchemaReview(draft: draft, evaluation: evaluation, savedRules: loaded.schema.overview,
			savedCheck: nil, project: project, environments: []))
		#expect(review.items.first { $0.item == .group("login") }?.state == .override(source: "base.json"))
		#expect(review.items.first { $0.item == .group("mfa") }?.state == .resetOverride(source: "base.json"))
	}
}

extension SheetInteractionTests {
	@Suite("Editing groups from the panel", .serialized)
	@MainActor
	struct SchemaGroupInteractionTests {
		static let sample = #"""
			{"envSchema":{"extends":["schemas/base.json"],
				"vars":{
					"PASSWORD":{"secret":true},
					"TOKEN":{"secret":true},
					"PORT":{"format":"port"}
				},
				"groups":{"auth":{"mode":"exactlyOne","vars":["PASSWORD","TOKEN"]}}
			}}
			"""#

		@Test("a new group joins the draft once it has a name and a key, and its mode can change")
		func addGroup() async throws {
			let (store, host, folder) = try await workspace()
			defer { host.window.close(); store.lock(); try? FileManager.default.removeItem(atPath: folder) }
			try await host.click("Add group")
			#expect(try await host.waitForText("NEW GROUP"))
			#expect(try await host.waitUntil { host.isEditing(placeholder: "group_name") }, "Add group puts the cursor in the name")
			try await host.typeCharacters("auth", placeholder: "group_name")
			#expect(try await host.waitForText("already declared"))
			try host.enterText("smtp", placeholder: "group_name")
			#expect(try await host.waitForText("Name the group and add a key"))
			#expect(store.schemaDraft(for: "schema-groups") == nil, "A group without a key isn't added")

			try await host.click("Key")
			try await host.click("PORT", in: try await host.popoverWindow())
			#expect(try await host.waitUntil {
				store.schemaDraft(for: "schema-groups")?.declaration(of: .group("smtp")) == .declared(ProjectEnvSchemaGroup(members: ["PORT"]).json())
			})
			#expect(try await host.waitForText("always passes"))

			try await host.click("Exactly one of")
			#expect(try await host.waitUntil {
				ProjectEnvSchemaGroup(store.schemaDraft(for: "schema-groups")?.declaration(of: .group("smtp")).json)?.mode == .exactlyOne
			})
			#expect(try await host.waitForText("works like Required"))
			#expect(try await host.waitUntil { store.currentSchemaDraftEvaluation(for: "schema-groups")?.rejection == nil && store.currentSchemaDraftEvaluation(for: "schema-groups") != nil })
		}

		@Test("a group's mode changes in the draft, which the review shows and Save writes to lpm.json")
		func editAndSave() async throws {
			let (store, host, folder) = try await workspace()
			defer { host.window.close(); store.lock(); try? FileManager.default.removeItem(atPath: folder) }
			try await host.click("auth")
			#expect(try await host.waitForText("MEMBERS"))
			try await host.click("At least one of")
			#expect(try await host.waitUntil { store.schemaDraft(for: "schema-groups")?.changedItems == [.group("auth")] })
			try await host.click("Review & save")
			#expect(try await host.waitUntil { host.window.sheets.first != nil })
			let sheet = try #require(host.window.sheets.first)
			#expect(try await host.waitForText("atLeastOne", in: sheet))
			try await host.click("Save to", in: sheet)
			#expect(try await host.waitUntil { store.schemaDraft(for: "schema-groups") == nil })
			let written = try String(contentsOfFile: folder + "/lpm.json", encoding: .utf8)
			#expect(written.contains(#""mode": "atLeastOne""#) || written.contains(#""mode":"atLeastOne""#))
		}

		@Test("members can be removed, and a group renamed, in the draft")
		func membersAndRename() async throws {
			let (store, host, folder) = try await workspace()
			defer { host.window.close(); store.lock(); try? FileManager.default.removeItem(atPath: folder) }
			try await host.click("auth")
			#expect(try await host.waitForText("MEMBERS"))
			try host.enterText("login", placeholder: "group_name")
			#expect(try await host.waitForText("already declared"), "An imported group's name is taken")
			try host.enterText("signin", placeholder: "group_name")
			try await host.click("Rename")
			#expect(try await host.waitUntil {
				let draft = store.schemaDraft(for: "schema-groups")
				return draft?.declaration(of: .group("auth")) == .absent && draft?.declaration(of: .group("signin")) != .absent
			})
			#expect(try await host.waitUntil { host.fieldText(placeholder: "group_name") == "signin" }, "The panel follows the group")
			// The member's remove button is the × right after its name, in the panel.
			let panel = CGRect(x: 0.72, y: 0, width: 0.28, height: 1)
			let token = try await host.labelFrame("TOKEN", region: panel)
			try NativeTestClick.send(to: host.window, at: NSPoint(x: token.maxX + 9, y: token.midY))
			#expect(try await host.waitUntil {
				ProjectEnvSchemaGroup(store.schemaDraft(for: "schema-groups")?.declaration(of: .group("signin")).json)?.members == ["PASSWORD"]
			})
			#expect(try await host.waitForText("works like Required"))
		}

		@Test("removing a group is a draft change Keep group takes back")
		func removeAndKeep() async throws {
			let (store, host, folder) = try await workspace()
			defer { host.window.close(); store.lock(); try? FileManager.default.removeItem(atPath: folder) }
			try await host.click("auth")
			#expect(try await host.waitForText("MEMBERS"))
			try host.shortcut("\u{7f}", code: 51)
			#expect(try await host.waitUntil { store.schemaDraft(for: "schema-groups")?.declaration(of: .group("auth")) == .absent })
			#expect(try await host.waitForText("in your draft"))
			try await host.click("Keep group")
			#expect(try await host.waitUntil { store.schemaDraft(for: "schema-groups") == nil })
		}

		@Test("an imported group is read-only until it's overridden, and can't be removed here")
		func importedGroup() async throws {
			let (store, host, folder) = try await workspace()
			defer { host.window.close(); store.lock(); try? FileManager.default.removeItem(atPath: folder) }
			try await host.click("login")
			#expect(try await host.waitForText("Read-only"))
			try host.shortcut("\u{7f}", code: 51)
			#expect(try await host.waitUntil { host.window.sheets.first != nil })
			let sheet = try #require(host.window.sheets.first)
			#expect(try await host.waitForText("can't be removed here", in: sheet))
			try await host.click("Cancel", in: sheet)
			#expect(try await host.waitUntil { host.window.sheets.isEmpty })
			try await host.click("Override group")
			#expect(try await host.waitUntil {
				if case .overridden? = store.schemaDraft(for: "schema-groups")?.declaration(of: .group("login")) { true } else { false }
			})
			#expect(try await host.waitForText("editing a copy"))
		}

		private func workspace() async throws -> (VaultStore, SheetTestHost<some View>, String) {
			let folder = FileManager.default.temporaryDirectory.appending(path: "schema-groups-\(UUID().uuidString)").path
			try FileManager.default.createDirectory(atPath: folder + "/schemas", withIntermediateDirectories: true)
			try Self.sample.write(toFile: folder + "/lpm.json", atomically: true, encoding: .utf8)
			try #"{"vars":{"SSO":{},"OTP":{}},"groups":{"login":{"mode":"atLeastOne","vars":["SSO","OTP"]}}}"#
				.write(toFile: folder + "/schemas/base.json", atomically: true, encoding: .utf8)
			let keychain = MockKeychainService()
			let project = VaultProject(id: "schema-groups", name: "billing-app", path: folder, environments: [
				"default": ["PASSWORD": "long-enough-pass", "PORT": "3000", "SSO": "on"],
			])
			keychain.envStorage[project.id] = (name: project.name, path: folder, environments: project.environments)
			let store = VaultStore(keychainService: keychain, biometricService: MockBiometricService(),
				apiService: MockAPIService(), authTokenProvider: { _, _ in nil })
			store.isUnlocked = true
			store.projects = [project]
			store.openProject(id: project.id)
			await store.refreshCliAccess()
			let defaults = try #require(UserDefaults(suiteName: "schema-groups-interaction"))
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
