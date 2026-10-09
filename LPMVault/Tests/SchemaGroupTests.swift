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
		group.mode = .atLeastOne
		group.members.append("SSO")
		#expect(group.json(updating: declared) == (try json(#"{"vars":["PASSWORD","TOKEN","SSO"],"mode":"atLeastOne"}"#)), "lpm.json's member order stays")
		#expect(SchemaGroup().json() == (try json(#"{"mode":"allOrNone","vars":[]}"#)))
	}

	@Test("a group's line names its first members and counts the rest, however many it has")
	func memberPreview() {
		typealias Group = ProjectEnvSchemaOverview.Group
		#expect(Group(name: "auth", members: ["PASSWORD", "TOKEN"], mode: "exactlyOne").summary == "Exactly one of PASSWORD, TOKEN")
		let short = Group(name: "big", members: (0..<4096).map { "KEY_\($0)" }, mode: "allOrNone").memberPreview
		#expect(short.hasPrefix("KEY_0, KEY_1, KEY_2, "))
		#expect(short.utf8.count <= 200)
		let shownCount = short.components(separatedBy: ", ").count
		#expect(short.hasSuffix(" +\((4096 - shownCount).formatted()) more"), "Every member the line leaves out is counted")
		let long = Group(name: "long", members: (0..<4096).map { String(repeating: "N", count: 240) + "_\($0)" }, mode: "allOrNone").memberPreview
		#expect(long.utf8.count <= 200)
		#expect(long.hasSuffix("… +\(4095.formatted()) more"), "A first member too long for the line is cut, not left out")
		#expect(Group(name: "odd", members: ["A\u{202E}B", "C"], mode: "allOrNone").memberPreview == "A\\u{202e}B, C")
	}

	@Test("the key picker lists declared keys from A to Z, with the draft's additions and without the group's members")
	func pickableKeys() throws {
		let base = try json(#"{"vars":{"A_KEY":{},"PASSWORD":{},"PORT":{},"TOKEN":{},"Z_KEY":{}}}"#)
		let rules = ProjectEnvSchemaOverview(rules: ["Z_KEY", "TOKEN", "PORT", "PASSWORD", "A_KEY"].map {
			.init(key: $0, isPublic: false, source: nil, badges: [])
		}, groups: []).rules
		var draft = ProjectEnvSchemaDraft(schema: base)
		draft.set(.declared(.object([])), for: .key("B_NEW"))
		draft.set(.declared(.object([])), for: .key("TOKEN_2"))
		draft.set(.absent, for: .key("PORT"))
		#expect(VaultSchemaGroupEditor.pickableKeys(evaluated: rules, draft: draft, excluding: ["PASSWORD", "TOKEN_2"]) == ["A_KEY", "B_NEW", "TOKEN", "Z_KEY"])
	}

	@Test("the panel's footer names an item with hidden characters escaped")
	func footerEscapesNames() {
		#expect(VaultSchemaEditorFooter.name(of: .group("g\u{202E}x")) == "the group g\\u{202e}x")
		#expect(VaultSchemaEditorFooter.name(of: .key("K\u{202E}")) == "K\\u{202e}")
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

	@Test("a renamed group keeps its place in lpm.json, renaming it back ends the rename, and discarding restores it")
	func renames() throws {
		var draft = ProjectEnvSchemaDraft(schema: try json(#"{"vars":{"A":{},"B":{}},"groups":{"auth":{"mode":"exactlyOne","vars":["A","B"]},"zeta":{"mode":"allOrNone","vars":["A"]}}}"#))
		draft.renameGroup("auth", to: "signin")
		#expect(draft.originalName(ofGroup: "signin") == "auth")
		#expect(draft.newName(ofGroup: "auth") == "signin")
		guard case .object(let groups)? = try draft.applied(to: draft.schema)?["groups"] else { Issue.record("No groups"); return }
		#expect(groups.map(\.key) == ["signin", "zeta"], "The renamed group keeps its place")
		draft.renameGroup("signin", to: "login")
		#expect(draft.originalName(ofGroup: "login") == "auth")
		#expect(!draft.hasChange(to: .group("signin")))
		draft.renameGroup("login", to: "auth")
		#expect(draft.isEmpty, "Renaming back to lpm.json's name ends the rename")
		draft.renameGroup("auth", to: "signin")
		draft.discardGroup("signin")
		#expect(draft.isEmpty)
		#expect(draft.originalName(ofGroup: "signin") == nil)
	}

	@Test("a key the draft no longer adds leaves the draft's groups and conditions, and a group of only it goes")
	func dropsReferences() throws {
		var draft = ProjectEnvSchemaDraft(schema: try json(#"{"vars":{"A":{}},"groups":{"pair":{"mode":"allOrNone","vars":["A"]}}}"#))
		draft.set(.declared(.object([])), for: .key("NEW"))
		draft.set(.declared(try json(#"{"requiredWhen":{"variable":"NEW","present":true}}"#)), for: .key("A"))
		draft.set(.declared(try json(#"{"mode":"allOrNone","vars":["A","NEW"]}"#)), for: .group("pair"))
		draft.set(.declared(try json(#"{"mode":"exactlyOne","vars":["NEW"]}"#)), for: .group("solo"))
		draft.discard(.key("NEW"))
		draft.dropReferences(to: "NEW")
		#expect(draft.isEmpty, "Everything the key brought along goes with it")
	}

	@Test("lpm.json's override of an imported group is marked, though the engine can't name the original")
	func overriddenGroupsMarked() throws {
		let folder = FileManager.default.temporaryDirectory.appending(path: "group-overrides-\(UUID().uuidString)").path
		try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(atPath: folder) }
		try #"{"vars":{"SSO":{},"OTP":{}},"groups":{"login":{"mode":"atLeastOne","vars":["SSO","OTP"]}}}"#
			.write(toFile: folder + "/base.json", atomically: true, encoding: .utf8)
		try #"{"envSchema":{"extends":["base.json"],"groupOverrides":{"login":{"mode":"exactlyOne","vars":["SSO","OTP"]}}}}"#
			.write(toFile: folder + "/lpm.json", atomically: true, encoding: .utf8)
		let overview = try #require(ProjectEnvSchemaFile.load(inFolder: folder, vaultID: "project").schema.overview)
		#expect(overview.groups.first { $0.name == "login" }?.overrides == "an imported schema")
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
		private typealias SchemaGroup = ProjectEnvSchemaGroup
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
			#expect(try await host.waitForText("Add a key to add the group"))
			#expect(store.schemaDraft(for: "schema-groups") == nil, "A group without a key isn't added")

			try await host.click("Add member")
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
			try await host.settle()
			let renamed = try await host.text()
			#expect(!renamed.contains("already added"), "A renamed group's own name isn't taken")
			#expect(!renamed.contains("NEW GROUP"), "A renamed group isn't a new one")
			try host.enterText("signin2", placeholder: "group_name")
			try await host.click("Rename")
			#expect(try await host.waitUntil { store.schemaDraft(for: "schema-groups")?.originalName(ofGroup: "signin2") == "auth" })
			#expect(store.schemaDraft(for: "schema-groups")?.hasChange(to: .group("signin")) == false)
			host.window.makeFirstResponder(nil)
			try host.shortcut("z", code: 6)
			#expect(try await host.waitUntil { host.fieldText(placeholder: "group_name") == "signin" }, "Undo moves the panel back with the rename")
			try await host.click("Discard")
			#expect(try await host.waitUntil { store.schemaDraft(for: "schema-groups") == nil }, "Discarding a rename keeps the group as lpm.json has it")
			#expect(try await host.waitUntil { host.fieldText(placeholder: "group_name") == "auth" })
			try host.enterText("signin", placeholder: "group_name")
			try await host.click("Rename")
			#expect(try await host.waitUntil { store.schemaDraft(for: "schema-groups")?.originalName(ofGroup: "signin") == "auth" })
			// The member's remove button is the × right after its name, in the panel.
			let panel = CGRect(x: 0.72, y: 0, width: 0.28, height: 1)
			let token = try await host.labelFrame("TOKEN", region: panel)
			try NativeTestClick.send(to: host.window, at: NSPoint(x: token.maxX + 9, y: token.midY))
			#expect(try await host.waitUntil {
				ProjectEnvSchemaGroup(store.schemaDraft(for: "schema-groups")?.declaration(of: .group("signin")).json)?.members == ["PASSWORD"]
			})
			#expect(try await host.waitForText("works like Required"))
		}

		@Test("removing the last member of a group being added takes it out of the draft, without the member")
		func removeLastMember() async throws {
			let (store, host, folder) = try await workspace()
			defer { host.window.close(); store.lock(); try? FileManager.default.removeItem(atPath: folder) }
			try await host.click("Add group")
			#expect(try await host.waitUntil { host.hasField(placeholder: "group_name") })
			try host.enterText("smtp", placeholder: "group_name")
			try await host.click("Add member")
			try await host.click("PORT", in: try await host.popoverWindow())
			#expect(try await host.waitUntil { store.schemaDraft(for: "schema-groups")?.declaration(of: .group("smtp")) != .absent })
			let panel = CGRect(x: 0.72, y: 0, width: 0.28, height: 1)
			let port = try await host.labelFrame("PORT", region: panel)
			try NativeTestClick.send(to: host.window, at: NSPoint(x: port.maxX + 9, y: port.midY))
			#expect(try await host.waitUntil { store.schemaDraft(for: "schema-groups") == nil })
			try await host.click("Add member")
			try await host.click("TOKEN", in: try await host.popoverWindow())
			#expect(try await host.waitUntil {
				ProjectEnvSchemaGroup(store.schemaDraft(for: "schema-groups")?.declaration(of: .group("smtp")).json)?.members == ["TOKEN"]
			}, "The removed member doesn't come back")
		}

		@Test("discarding a group change a key's removal made keeps the removed key out of it")
		func discardAfterRemoval() async throws {
			let (store, host, folder) = try await workspace()
			defer { host.window.close(); store.lock(); try? FileManager.default.removeItem(atPath: folder) }
			let references = ProjectEnvSchemaReference.references(to: "TOKEN", in: store.schemaDraftOrBase(for: "schema-groups"),
				rules: store.keyDescriptions["schema-groups"]?.schema?.overview)
			store.removeSchemaKey("TOKEN", settling: references.map { ($0, .dropFromGroup) }, in: "schema-groups")
			try await host.click("auth")
			#expect(try await host.waitForText("MEMBERS"))
			try await host.settle()
			#expect(try await !host.text().contains("Discard"), "Dropping a removed key is all the group's change, and it has to stay")
			try await host.click("At least one of")
			#expect(try await host.waitUntil {
				ProjectEnvSchemaGroup(store.schemaDraftOrBase(for: "schema-groups").declaration(of: .group("auth")).json)?.mode == .atLeastOne
			})
			try await host.click("Discard")
			#expect(try await host.waitUntil {
				ProjectEnvSchemaGroup(store.schemaDraftOrBase(for: "schema-groups").declaration(of: .group("auth")).json)
					== ProjectEnvSchemaGroup(mode: .exactlyOne, members: ["PASSWORD"])
			}, "The mode goes back, and the removed key stays out")
			#expect(try await host.waitUntil {
				store.currentSchemaDraftEvaluation(for: "schema-groups").map { $0.rejection == nil } == true
			}, "The LPM CLI still accepts the rules")
		}

		@Test("a group too large to show whole is filtered to find a member, which removes from it")
		func largeGroupFiltered() async throws {
			let (store, host, folder) = try await groupPanel(sample: Self.largeGroup(count: 100), group: "many")
			defer { host.window.close(); store.lock(); try? FileManager.default.removeItem(atPath: folder) }
			#expect(try await host.waitForText("Showing the first 40"))
			#expect(try await !host.text().contains("ZEBRA"), "Members past the first ones aren't drawn")
			try host.enterText("zebra", placeholder: "Filter 100 members")
			#expect(try await host.waitForText("ZEBRA_TOKEN"))
			#expect(try await !host.text().contains("Showing"))
			let zebra = try await host.labelFrame("ZEBRA_TOKEN")
			try NativeTestClick.send(to: host.window, at: NSPoint(x: zebra.maxX + 9, y: zebra.midY))
			#expect(try await host.waitUntil {
				ProjectEnvSchemaGroup(store.schemaDraft(for: "schema-groups")?.declaration(of: .group("many")).json)?.members
					== (0..<99).map { String(format: "KEY_%04d", $0) }
			}, "Only the member found is removed, from the group shown")
			#expect(try await host.waitForText("No members match"))
		}

		@Test("a group of 4096 members opens and redraws within a frame or so",
			.enabled(if: ProcessInfo.processInfo.environment["SCHEMA_DRAFT_BENCHMARKS"] == "1"))
		func largeGroupBenchmark() async throws {
			let (store, project) = try await store(sample: Self.largeGroup(count: SchemaGroup.maximumMembers))
			defer { store.lock(); try? FileManager.default.removeItem(atPath: project.path) }
			store.reloadKeyDescriptions()
			let clock = ContinuousClock()
			let deadline = clock.now.advanced(by: .seconds(30))
			while store.keyDescriptions[project.id]?.schema?.overview == nil, clock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
			try #require(store.keyDescriptions[project.id]?.schema?.overview?.groups.first?.members.count == SchemaGroup.maximumMembers)
			let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 760), styleMask: [.titled], backing: .buffered, defer: false)
			defer { window.close() }
			let started = clock.now
			let view = NSHostingView(rootView: VaultSchemaPanel(store: store, project: project, environments: ["default"], selection: .group("many"),
				session: UUID(), onSelect: { _ in }, onFollow: { _ in }, onReview: {}))
			window.contentView = view
			view.layoutSubtreeIfNeeded()
			view.displayIfNeeded()
			let open = started.duration(to: clock.now)
			var redraws: [Duration] = []
			for index in 0..<12 {
				let mode: SchemaGroup.Mode = index.isMultiple(of: 2) ? .atLeastOne : .allOrNone
				let members = (0..<SchemaGroup.maximumMembers - 1).map { String(format: "KEY_%04d", $0) } + ["ZEBRA_TOKEN"]
				store.editSchemaDraft(in: project.id) { $0.set(.declared(SchemaGroup(mode: mode, members: members).json()), for: .group("many")) }
				let begin = clock.now
				view.layoutSubtreeIfNeeded()
				view.displayIfNeeded()
				redraws.append(begin.duration(to: clock.now))
			}
			let median = redraws.sorted()[redraws.count / 2]
			print("group panel, 4096 members: open \(open), redraw median \(median), max \(redraws.max() ?? .zero)")
			#expect(open < .milliseconds(400))
			#expect(median < .milliseconds(30))
		}

		@Test("a key whose override the draft resets is still one a group can list")
		func resetOverrideKeyListed() async throws {
			let (store, host, folder) = try await workspace(overridesOTP: true)
			defer { host.window.close(); store.lock(); try? FileManager.default.removeItem(atPath: folder) }
			store.editSchemaDraft(in: "schema-groups") { $0.set(.absent, for: .key("OTP")) }
			try await host.click("auth")
			#expect(try await host.waitForText("MEMBERS"))
			try await host.click("Add member")
			#expect(try await host.waitForText("OTP", in: try await host.popoverWindow()))
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

		/// A store with the project open on `sample` as its lpm.json, and the project's folder.
		private func store(sample: String) async throws -> (VaultStore, VaultProject) {
			let folder = FileManager.default.temporaryDirectory.appending(path: "schema-groups-\(UUID().uuidString)").path
			try FileManager.default.createDirectory(atPath: folder + "/schemas", withIntermediateDirectories: true)
			try sample.write(toFile: folder + "/lpm.json", atomically: true, encoding: .utf8)
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
			return (store, project)
		}

		private func workspace(overridesOTP: Bool = false) async throws -> (VaultStore, SheetTestHost<some View>, String) {
			let sample = overridesOTP ? Self.sample.replacingOccurrences(of: #""vars":{"#, with: #""overrides":{"OTP":{"format":"url"}},"vars":{"#) : Self.sample
			let (store, project) = try await store(sample: sample)
			let defaults = try #require(UserDefaults(suiteName: "schema-groups-interaction"))
			defaults.set(VaultKeySortOrder.ascending.rawValue, forKey: VaultKeySortOrder.defaultsKey)
			let host = SheetTestHost(VaultWorkspaceView(store: store).environment(UpdateChecker())
				.environment(VaultAppearanceSettings(defaults: defaults)).defaultAppStorage(defaults),
				size: NSSize(width: 1400, height: 760), keepsRequestedSize: true, usesHostingView: true)
			#expect(try await host.waitUntil { store.keyDescriptions[project.id]?.schema?.overview != nil })
			try await host.click("Schema")
			#expect(try await host.waitForText("enforced by LPM CLI"))
			return (store, host, project.path)
		}

		/// lpm.json with `count` declared keys, all members of the group `many`, the last of them ZEBRA_TOKEN.
		static func largeGroup(count: Int) -> String {
			let keys = (0..<count - 1).map { String(format: "KEY_%04d", $0) } + ["ZEBRA_TOKEN"]
			let vars = keys.map { #""\#($0)":{}"# }.joined(separator: ",")
			let members = keys.map { #""\#($0)""# }.joined(separator: ",")
			return #"{"envSchema":{"vars":{\#(vars)},"groups":{"many":{"mode":"allOrNone","vars":[\#(members)]}}}}"#
		}

		/// The group's panel on its own, as the Schema page shows it beside the table.
		private func groupPanel(sample: String, group: String) async throws -> (VaultStore, SheetTestHost<some View>, String) {
			let (store, project) = try await store(sample: sample)
			// The workspace reads lpm.json as it appears; the panel alone doesn't.
			store.reloadKeyDescriptions()
			let host = SheetTestHost(VaultSchemaPanel(store: store, project: project, environments: ["default"], selection: .group(group), session: UUID(),
				onSelect: { _ in }, onFollow: { _ in }, onReview: {}), size: NSSize(width: 320, height: 760), keepsRequestedSize: true, usesHostingView: true)
			#expect(try await host.waitUntil { store.keyDescriptions[project.id]?.schema?.overview != nil })
			return (store, host, project.path)
		}
	}
}
