import AppKit
import SwiftUI
import Testing

@testable import LPMVault

@Suite("Schema review")
struct SchemaReviewTests {
	typealias Draft = ProjectEnvSchemaDraft
	typealias Problem = ProjectEnvValueCheck.Problem

	private func json(_ text: String) throws -> LPMConfigJSON {
		try LPMConfigJSON(parsing: Data(text.utf8), rejectDuplicateKeys: true)
	}

	@Test("each change shows its state, its lines of lpm.json, and its effects in words")
	func reviewItems() throws {
		let schema = try json(#"{"vars":{"RETRY":{"format":"integer","max":10},"OLD":{"secret":true}},"overrides":{"DB":{"format":"url"}}}"#)
		var draft = Draft(schema: schema)
		draft.set(.declared(try json(#"{"format":"integer","max":5}"#)), for: .key("RETRY"))
		draft.set(.declared(try json(#"{"format":"port"}"#)), for: .key("PORT"))
		draft.set(.absent, for: .key("OLD"))
		draft.set(.absent, for: .key("DB"))
		draft.set(.overridden(try json(#"{"required":true}"#)), for: .key("TOKEN"))
		let saved = ProjectEnvSchemaOverview(rules: [
			.init(key: "RETRY", isPublic: false, source: nil, badges: []),
			.init(key: "OLD", isPublic: false, source: nil, badges: []),
			.init(key: "DB", isPublic: false, source: nil, badges: [], overrides: "schemas/base.json"),
			.init(key: "TOKEN", isPublic: false, source: "schemas/base.json", badges: []),
		], groups: [])
		let before = ProjectEnvValueCheck(environments: ["staging": .init(problems: ["OLD": [Problem(key: "OLD", kind: .required)]])])
		let after = ProjectEnvValueCheck(environments: ["staging": .init(problems: [
			"RETRY": [Problem(key: "RETRY", kind: .constraint("max"))],
			"API": [Problem(key: "API", kind: .required)],
		])])
		let evaluation = Draft.Evaluation(overview: saved, rejection: nil, check: after)
		let project = VaultProject(id: "p", name: "p", path: "", environments: ["staging": ["RETRY": "9"]])
		let review = try #require(ProjectEnvSchemaReview(draft: draft, evaluation: evaluation, savedRules: saved, savedCheck: before, project: project, environments: ["staging"]))
		#expect(review.items.map(\.title) == ["RETRY", "PORT", "OLD", "DB", "TOKEN"])
		#expect(review.items.map(\.state) == [.changed, .new, .removed, .resetOverride(source: "schemas/base.json"), .override(source: "schemas/base.json")])
		#expect(review.items[0].diff.path == "envSchema.vars.RETRY")
		#expect(review.items[0].effects == [.init(environment: "staging", kind: .newlyFailing, message: "Above the maximum")])
		#expect(review.items[2].effects == [.init(environment: "staging", kind: .noLongerChecked, message: "Required")])
		#expect(review.others == [.init(environment: "staging", kind: .newlyFailing, message: "API: Required")])
		#expect(review.values == .checked)
	}

	@Test("a project without rules yet compares the draft with no checks, so what it breaks shows")
	func firstRules() throws {
		var draft = Draft(schema: nil)
		draft.set(.declared(try json(#"{"format":"port","required":true}"#)), for: .key("PORT"))
		let after = ProjectEnvValueCheck(environments: [
			"default": .init(problems: ["PORT": [Problem(key: "PORT", kind: .format("port"))]]),
			"staging": .init(problems: ["PORT": [Problem(key: "PORT", kind: .required)]]),
		])
		let rules = ProjectEnvSchemaOverview(rules: [.init(key: "PORT", isPublic: false, source: nil, badges: [])], groups: [])
		let project = VaultProject(id: "p", name: "p", path: "", environments: ["default": ["PORT": "abc"], "staging": [:]])
		let review = try #require(ProjectEnvSchemaReview(draft: draft, evaluation: .init(overview: rules, rejection: nil, check: after),
			savedRules: .empty, savedCheck: nil, project: project, environments: ["default", "staging"]))
		#expect(review.values == .checked)
		#expect(review.items[0].effects.map(\.kind) == [.newlyFailing, .newlyFailing])
	}

	@Test("the review waits while the saved rules' check runs, and says when values can't be checked")
	func valuesState() throws {
		var draft = Draft(schema: try json(#"{"vars":{"PORT":{}}}"#))
		draft.set(.declared(try json(#"{"format":"port"}"#)), for: .key("PORT"))
		let saved = ProjectEnvSchemaOverview(rules: [.init(key: "PORT", isPublic: false, source: nil, badges: [])], groups: [], effectiveSchema: Data("{}".utf8))
		let evaluation = Draft.Evaluation(overview: saved, rejection: nil, check: ProjectEnvValueCheck(environments: ["default": .init()]))
		let loaded = VaultProject(id: "p", name: "p", path: "", environments: ["default": ["PORT": "1"]])
		#expect(ProjectEnvSchemaReview(draft: draft, evaluation: evaluation, savedRules: saved, savedCheck: nil, project: loaded, environments: ["default"])?.values == .checking)
		let unloaded = VaultProject(metadata: .init(id: "p", name: "p", path: "", environmentSummaries: []))
		#expect(ProjectEnvSchemaReview(draft: draft, evaluation: evaluation, savedRules: saved, savedCheck: nil, project: unloaded, environments: ["default"])?.values == .unchecked)
	}

	@Test("a removed key's problems show once per environment, naming the checks that stop")
	func removedKeyEffects() throws {
		var draft = Draft(schema: try json(#"{"vars":{"OLD":{"format":"url","maxLength":8}}}"#))
		draft.set(.absent, for: .key("OLD"))
		let before = ProjectEnvValueCheck(environments: [
			"default": .init(problems: ["OLD": [Problem(key: "OLD", kind: .format("url")), Problem(key: "OLD", kind: .constraint("maxLength"))]]),
			"staging": .init(problems: ["OLD": [Problem(key: "OLD", kind: .required)]]),
		])
		let after = ProjectEnvValueCheck(environments: ["default": .init(), "staging": .init()])
		let rules = ProjectEnvSchemaOverview(rules: [], groups: [])
		let project = VaultProject(id: "p", name: "p", path: "", environments: ["default": ["OLD": "not a url"], "staging": [:]])
		let review = try #require(ProjectEnvSchemaReview(draft: draft, evaluation: .init(overview: rules, rejection: nil, check: after),
			savedRules: rules, savedCheck: before, project: project, environments: ["default", "staging"]))
		#expect(review.items[0].effects == [
			.init(environment: "default", kind: .noLongerChecked, message: "Too long; Not a valid URL"),
			.init(environment: "staging", kind: .noLongerChecked, message: "Required"),
		])
	}

	@Test("names in effect messages show characters that hide or reorder text as escapes")
	func escapedEffectNames() throws {
		var draft = Draft(schema: nil)
		draft.set(.declared(.object([])), for: .key("A"))
		let after = ProjectEnvValueCheck(environments: ["e": .init(problems: ["B\u{202E}C": [Problem(key: "B\u{202E}C", kind: .required)]])])
		let rules = ProjectEnvSchemaOverview(rules: [], groups: [])
		let review = try #require(ProjectEnvSchemaReview(draft: draft, evaluation: .init(overview: rules, rejection: nil, check: after),
			savedRules: rules, savedCheck: ProjectEnvValueCheck(environments: ["e": .init()]), project: VaultProject(id: "p", name: "p", path: "", environments: ["e": [:]]), environments: ["e"]))
		#expect(review.others.count == 1)
		#expect(review.others.allSatisfy { !$0.message.hasHiddenCharacters })
	}

	@Test("a removed group's checks stop rather than pass, and a group problem shows for each changed member")
	func groupEffects() throws {
		let groupProblem = { (key: String) in Problem(key: key, kind: .group(name: "auth", mode: "exactlyOne")) }
		var removing = Draft(schema: try json(#"{"vars":{"A":{},"B":{}},"groups":{"auth":{"mode":"exactlyOne","vars":["A","B"]}}}"#))
		removing.set(.absent, for: .group("auth"))
		let failing = ProjectEnvValueCheck(environments: ["e": .init(problems: ["A": [groupProblem("A")], "B": [groupProblem("B")]])])
		let passing = ProjectEnvValueCheck(environments: ["e": .init()])
		let removed = ProjectEnvSchemaDraftEffects(before: failing, after: passing, draft: removing)
		#expect(removed.summary(for: .group("auth")).effects.map(\.kind) == [.noLongerChecked])

		var both = Draft(schema: try json(#"{"vars":{"A":{},"B":{}},"groups":{"auth":{"mode":"exactlyOne","vars":["A","B"]}}}"#))
		both.set(.declared(try json(#"{"required":true}"#)), for: .key("A"))
		both.set(.declared(try json(#"{"required":true}"#)), for: .key("B"))
		let breaking = ProjectEnvSchemaDraftEffects(before: passing, after: failing, draft: both)
		#expect(breaking.summary(for: .key("A")).effects.map(\.kind) == [.newlyFailing])
		#expect(breaking.summary(for: .key("B")).effects.map(\.kind) == [.newlyFailing])
	}

	@Test("a default that unset environments use is named when the draft changes or removes it")
	func defaultEffects() throws {
		var draft = Draft(schema: try json(#"{"vars":{"PORT":{"default":"3000"},"HOST":{"default":"localhost"},"MODE":{}}}"#))
		draft.set(.declared(try json(#"{"default":"4000"}"#)), for: .key("PORT"))
		draft.set(.declared(.object([])), for: .key("HOST"))
		draft.set(.declared(try json(#"{"default":"dev"}"#)), for: .key("MODE"))
		let before = ProjectEnvValueCheck(environments: ["staging": .init(defaults: ["PORT": "3000", "HOST": "localhost"])])
		let after = ProjectEnvValueCheck(environments: ["staging": .init(defaults: ["PORT": "4000", "MODE": "dev"])])
		let effects = ProjectEnvSchemaDraftEffects(before: before, after: after, draft: draft)
		#expect(effects.summary(for: .key("PORT")).defaults == [.init(environment: "staging", key: "PORT", kind: .changed)])
		#expect(effects.summary(for: .key("HOST")).defaults == [.init(environment: "staging", key: "HOST", kind: .removed)])
		#expect(effects.summary(for: .key("MODE")).defaults == [.init(environment: "staging", key: "MODE", kind: .added)])

		let rules = ProjectEnvSchemaOverview(rules: [], groups: [])
		let review = try #require(ProjectEnvSchemaReview(draft: draft, evaluation: .init(overview: rules, rejection: nil, check: after),
			savedRules: rules, savedCheck: before, project: VaultProject(id: "p", name: "p", path: "", environments: ["staging": [:]]), environments: ["staging"]))
		#expect(review.items.first { $0.title == "PORT" }?.effects == [.init(environment: "staging", kind: .defaultChanged, message: "Uses the default, which this changes")])
		#expect(review.items.first { $0.title == "HOST" }?.effects == [.init(environment: "staging", kind: .defaultChanged, message: "Used the default, which this removes")])
		#expect(review.items.first { $0.title == "MODE" }?.effects == [.init(environment: "staging", kind: .defaultChanged, message: "Now uses the default")])
	}

	@Test("a draft the engine rejects has no review")
	func noReviewWhenRejected() throws {
		var draft = Draft(schema: nil)
		draft.set(.declared(try json(#"{"secret":true,"default":"x"}"#)), for: .key("TOKEN"))
		let rejected = Draft.Evaluation(overview: nil, rejection: .init(nil), check: nil)
		#expect(ProjectEnvSchemaReview(draft: draft, evaluation: rejected, savedRules: nil, savedCheck: nil,
			project: VaultProject(id: "p", name: "p", path: "", environments: [:]), environments: []) == nil)
	}

	@Test("a conflict names only what differs on each side", arguments: [
		(#"{"format":"port","default":"8080"}"#, #"{"format":"port","default":"4000"}"#, "default 8080", "default 4000"),
		(#"{"format":"port"}"#, nil, "format port", "removed"),
		(#"{"format":"port","required":true}"#, #"{"format":"port"}"#, "required on", "no required"),
		(#"{"a":1,"b":2,"c":3,"d":4}"#, #"{}"#, "a 1, b 2, c 3, +1 more", "no a, no b, no c, +1 more"),
		(#"{}"#, nil, "no rules", "removed"),
		(#"{"enum":[]}"#, #"{"enum":["a"]}"#, "enum none", "enum a"),
	])
	func conflictSummary(mine: String, theirs: String?, mineText: String, theirsText: String) throws {
		let conflict = Draft.Conflict(item: .key("PORT"), mine: .declared(try json(mine)), theirs: try theirs.map { .declared(try json($0)) } ?? .absent)
		#expect(conflict.summary.mine == mineText)
		#expect(conflict.summary.theirs == theirsText)
	}

	@Test("a conflict between a rule and an override of the same rules says where each is")
	func conflictKinds() throws {
		let rule = try json(#"{"format":"url"}"#)
		let conflict = Draft.Conflict(item: .key("DB"), mine: .declared(rule), theirs: .overridden(rule))
		#expect(conflict.summary.mine == "in vars")
		#expect(conflict.summary.theirs == "as an override")
		let prefixes = Draft.Conflict(item: .clientPrefixes, mine: .declared(.array([])), theirs: .declared(.array([.string("APP_")])))
		#expect(prefixes.summary.mine == "none")
	}

	@Test("long values are cut before they're escaped, so an escape is never cut in half, and stay quick to describe")
	func boundedSummaries() throws {
		let long = String(repeating: "a", count: 23) + "\u{202E}" + String(repeating: "b", count: 40)
		let conflict = Draft.Conflict(item: .key("K"), mine: .declared(.object([.init(key: "default", value: .string(long))])), theirs: .declared(.object([])))
		#expect(conflict.summary.mine == "default " + String(repeating: "a", count: 23) + "\\u{202e}…")
		let huge = LPMConfigJSON.object([.init(key: "enum", value: .array((0..<150_000).map { .string("value-\($0)") }))])
		let start = ContinuousClock.now
		_ = Draft.Conflict(item: .key("K"), mine: .declared(huge), theirs: .declared(.object([]))).summary
		#expect(ContinuousClock.now - start < .milliseconds(50))
	}

	@Test("the note of changes on disk names what changed outside", arguments: [
		([Draft.Item.key("RETRY_COUNT"), .group("auth")], false, "RETRY_COUNT and the auth group changed outside"),
		([.key("A")], true, "A and its imports changed outside"),
		([.key("A"), .key("B"), .clientPrefixes], false, "A, B and the client prefixes changed outside"),
		([.key("A"), .key("B"), .key("C"), .key("D")], false, "A, B, C and 1 more changed outside"),
	])
	func describeRebase(items: [Draft.Item], otherFields: Bool, text: String) {
		#expect(Draft.Rebase(changedItems: items, changedOtherFields: otherFields).summary == text)
	}
}

@Suite("Schema save failures", .serialized)
@MainActor
struct SchemaSaveFailureTests {
	@Test("a save that can't write lpm.json is kept with its reason until the draft changes")
	func writeFailure() async throws {
		let folder = FileManager.default.temporaryDirectory.appending(path: "schema-save-failure-\(UUID().uuidString)").path
		try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
		try #"{"envSchema":{"vars":{"PORT":{"format":"port"}}}}"#.write(toFile: folder + "/lpm.json", atomically: true, encoding: .utf8)
		defer {
			chmod(folder, 0o755)
			try? FileManager.default.removeItem(atPath: folder)
		}
		let environments = ["default": ["PORT": "3000"]]
		let keychain = MockKeychainService()
		keychain.envStorage["project"] = (name: "Project", path: folder, environments: environments)
		let preferences = try #require(UserDefaults(suiteName: "schema-save-failure-\(UUID().uuidString)"))
		let store = VaultStore(keychainService: keychain, biometricService: MockBiometricService(), apiService: MockAPIService(), preferences: preferences)
		defer { store.lock() }
		store.projects = [VaultProject(id: "project", name: "Project", path: folder, environments: environments)]
		store.isUnlocked = true
		store.selectedProjectId = "project"
		store.reloadKeyDescriptions()
		try await waitUntil { store.keyDescriptions["project"]?.schema?.overview != nil }
		try FileManager.default.createDirectory(atPath: folder + "/.lpm", withIntermediateDirectories: true)

		store.editSchemaDraft(in: "project") { $0.set(.declared(.object([.init(key: "format", value: .string("url"))])), for: .key("PORT")) }
		try await waitUntil { store.currentSchemaDraftEvaluation(for: "project") != nil }
		chmod(folder, 0o555)
		await #expect { try await store.saveSchemaDraft(in: "project") } throws: { error in
			if case .file(.writeFailed) = error as? ProjectEnvSchemaFile.DraftSaveError { true } else { false }
		}
		guard case .file(.writeFailed)? = store.schemaDraftSaveFailure(for: "project") else {
			Issue.record("The failure is kept for the draft")
			return
		}
		chmod(folder, 0o755)
		store.editSchemaDraft(in: "project") { $0.set(.declared(.object([.init(key: "format", value: .string("email"))])), for: .key("PORT")) }
		#expect(store.schemaDraftSaveFailure(for: "project") == nil, "A changed draft hasn't failed yet")
	}

	@Test("a save that fails after lpm.json was only reordered keeps its failure for the draft it tried to save")
	func failureAfterReorder() async throws {
		let (store, folder) = try await makeStore(#"{"envSchema":{"vars":{"PORT":{"format":"port"},"RETRY":{}}}}"#)
		defer { chmod(folder, 0o755); store.lock(); try? FileManager.default.removeItem(atPath: folder) }
		store.editSchemaDraft(in: "project") { $0.set(.declared(.object([.init(key: "format", value: .string("url"))])), for: .key("PORT")) }
		try await waitUntil { store.currentSchemaDraftEvaluation(for: "project") != nil }
		try #"{"envSchema":{"vars":{"RETRY":{},"PORT":{"format":"port"}}}}"#.write(toFile: folder + "/lpm.json", atomically: true, encoding: .utf8)
		chmod(folder, 0o555)
		await #expect { try await store.saveSchemaDraft(in: "project") } throws: { error in
			if case .file(.writeFailed) = error as? ProjectEnvSchemaFile.DraftSaveError { true } else { false }
		}
		try await waitUntil { store.currentSchemaDraftEvaluation(for: "project") != nil }
		guard case .file(.writeFailed)? = store.schemaDraftSaveFailure(for: "project") else {
			Issue.record("The failure of the merged draft is kept")
			return
		}
	}

	@Test("a failure stops offering a retry once what the review showed changes: the imports or the stored values")
	func failureNeedsAnotherReview() async throws {
		let (store, folder) = try await makeStore(#"{"envSchema":{"extends":["base.json"],"vars":{"PORT":{"format":"port"}}}}"#, files: ["base.json": #"{"vars":{"A":{}}}"#])
		defer { chmod(folder, 0o755); store.lock(); try? FileManager.default.removeItem(atPath: folder) }
		store.editSchemaDraft(in: "project") { $0.set(.declared(.object([.init(key: "format", value: .string("url"))])), for: .key("PORT")) }
		try await waitUntil { store.currentSchemaDraftEvaluation(for: "project") != nil }
		chmod(folder, 0o555)
		_ = try? await store.saveSchemaDraft(in: "project")
		#expect(store.schemaDraftSaveFailure(for: "project") != nil)
		chmod(folder, 0o755)
		try #"{"vars":{"A":{"required":true}}}"#.write(toFile: folder + "/base.json", atomically: true, encoding: .utf8)
		store.reloadKeyDescriptions()
		try await waitUntil { store.currentSchemaDraftEvaluation(for: "project")?.overview?.rule(for: "A")?.badges.isEmpty == false }
		#expect(store.schemaDraftSaveFailure(for: "project") == nil, "The imports changed, so the draft needs another review")
	}

	@Test("a save that wrote lpm.json while the project moved to another folder counts as saved")
	func savedWhileFolderChanged() async throws {
		let (store, folder) = try await makeStore(#"{"envSchema":{"vars":{"PORT":{"format":"port"}}}}"#)
		let other = FileManager.default.temporaryDirectory.appending(path: "schema-save-other-\(UUID().uuidString)").path
		try FileManager.default.createDirectory(atPath: other, withIntermediateDirectories: true)
		defer { store.lock(); try? FileManager.default.removeItem(atPath: folder); try? FileManager.default.removeItem(atPath: other) }
		store.editSchemaDraft(in: "project") { $0.set(.declared(.object([.init(key: "format", value: .string("url"))])), for: .key("PORT")) }
		try await waitUntil { store.currentSchemaDraftEvaluation(for: "project") != nil }
		let gate = DispatchSemaphore(value: 0)
		ProjectConfigFile.editQueue.async { gate.wait() }
		defer { gate.signal() }
		let save = Task { @MainActor in try await store.saveSchemaDraft(in: "project") }
		try await waitUntil { store.savingSchemaDrafts.contains("project") }
		let project = try #require(store.projects.first)
		store.projects = [VaultProject(id: project.id, name: project.name, path: other, environments: project.environments)]
		gate.signal()
		try await save.value
		#expect(store.schemaDraft(for: "project") == nil)
		#expect(store.schemaDraftSaveFailure(for: "project") == nil)
		#expect(try String(contentsOfFile: folder + "/lpm.json", encoding: .utf8).contains(#""url""#))
	}

	@Test("a reread that lands before the app's own rename finishes isn't a change on disk")
	func reloadDuringOwnRename() async throws {
		let (store, folder, keychain) = try await makeStoreWithKeychain(#"{"envSchema":{"vars":{"PORT":{"format":"port"},"RETRY":{"format":"integer"}}}}"#,
			values: ["PORT": "3000", "RETRY": "3"])
		defer { store.lock(); try? FileManager.default.removeItem(atPath: folder) }
		store.editSchemaDraft(in: "project") { $0.set(.declared(.object([.init(key: "format", value: .string("url"))])), for: .key("PORT")) }
		let written = DispatchSemaphore(value: 0)
		let release = DispatchSemaphore(value: 0)
		keychain.afterKeychainTransaction = { written.signal(); release.wait() }
		defer { release.signal() }
		let project = try #require(store.projects.first)
		store.keyDrafts.edit(project, key: "RETRY") { $0.name = "RETRIES" }
		let rename = Task { @MainActor in try await store.saveKeyDraft(.init(projectID: "project", key: "RETRY")) }
		try await waitUntil { written.wait(timeout: .now()) == .success }
		keychain.afterKeychainTransaction = nil
		store.reloadKeyDescriptions()
		try await waitUntil { store.keyDescriptions["project"]?.rootSchema?["vars"]?["RETRIES"] != nil }
		release.signal()
		try await rename.value
		try await waitUntil { !store.isReloadingKeyDescriptions }
		#expect(store.schemaDraftRebases["project"] == nil, "The app's own rename isn't noted as a change on disk")
		#expect(store.schemaDraft(for: "project")?.changedItems == [.key("PORT")])
	}

	private func makeStore(_ lpmJSON: String, files: [String: String] = [:]) async throws -> (VaultStore, String) {
		let (store, folder, _) = try await makeStoreWithKeychain(lpmJSON, files: files)
		return (store, folder)
	}

	private func makeStoreWithKeychain(_ lpmJSON: String, files: [String: String] = [:], values: [String: String] = ["PORT": "3000"]) async throws -> (VaultStore, String, MockKeychainService) {
		let folder = FileManager.default.temporaryDirectory.appending(path: "schema-save-failure-\(UUID().uuidString)").path
		try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
		try lpmJSON.write(toFile: folder + "/lpm.json", atomically: true, encoding: .utf8)
		for (path, contents) in files { try contents.write(toFile: folder + "/" + path, atomically: true, encoding: .utf8) }
		// The LPM CLI's config lock lives here; with it in place, a read-only folder fails only the write.
		try FileManager.default.createDirectory(atPath: folder + "/.lpm", withIntermediateDirectories: true)
		let environments = ["default": values]
		let keychain = MockKeychainService()
		keychain.envStorage["project"] = (name: "Project", path: folder, environments: environments)
		let preferences = try #require(UserDefaults(suiteName: "schema-save-failure-\(UUID().uuidString)"))
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
	@Suite("Schema review and changes on disk", .serialized)
	@MainActor
	struct SchemaReviewInteractionTests {
		static let sample = #"""
			{"envSchema":{"vars":{
				"PORT":{"format":"port","default":"3000"},
				"RETRY_COUNT":{"format":"integer","min":0,"max":10}
			}}}
			"""#

		@Test("Review & save shows the change and what it breaks, and Save writes lpm.json")
		func reviewAndSave() async throws {
			let (store, host, folder) = try await workspace()
			defer { host.window.close(); store.lock(); try? FileManager.default.removeItem(atPath: folder) }
			try await host.click("RETRY_COUNT")
			#expect(try await host.waitForText("STORED VALUES"))
			try host.enterText("5", placeholder: "max")
			#expect(try await host.waitUntil { store.currentSchemaDraftEvaluation(for: "schema-review") != nil })
			try await host.click("Review & save")
			#expect(try await host.waitUntil { host.window.sheets.first != nil })
			let sheet = try #require(host.window.sheets.first)
			#expect(try await host.waitForText("Review changes to lpm.json", in: sheet))
			#expect(try await host.waitForText("Newly failing", in: sheet))
			let save = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
				windowNumber: sheet.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
			#expect(sheet.performKeyEquivalent(with: save), "Return saves")
			#expect(try await host.waitUntil { store.schemaDraft(for: "schema-review") == nil })
			#expect(try String(contentsOfFile: folder + "/lpm.json", encoding: .utf8).contains(#""max": 5"#))
		}

		@Test("a change on disk to the same key asks which version to keep")
		func conflictOnDisk() async throws {
			let (store, host, folder) = try await workspace()
			defer { host.window.close(); store.lock(); try? FileManager.default.removeItem(atPath: folder) }
			store.editSchemaDraft(in: "schema-review") {
				$0.set(.declared(.object([.init(key: "format", value: .string("port")), .init(key: "default", value: .string("8080"))])), for: .key("PORT"))
			}
			try #"{"envSchema":{"vars":{"PORT":{"format":"port","default":"4000"},"RETRY_COUNT":{"format":"integer","min":0,"max":10}}}}"#
				.write(toFile: folder + "/lpm.json", atomically: true, encoding: .utf8)
			#expect(try await host.waitForText("conflicts with your draft"))
			#expect(try await host.waitForText("Theirs: default 4000"))
			try await host.click("Keep mine")
			#expect(try await host.waitUntil { store.schemaDraft(for: "schema-review")?.conflicts.isEmpty == true })
			#expect(store.schemaDraft(for: "schema-review")?.declaration(of: .key("PORT")).json?["default"] == .string("8080"))
		}

		@Test("a change on disk to another key re-applies the draft with a note that can be dismissed")
		func noteOnDisk() async throws {
			let (store, host, folder) = try await workspace()
			defer { host.window.close(); store.lock(); try? FileManager.default.removeItem(atPath: folder) }
			store.editSchemaDraft(in: "schema-review") {
				$0.set(.declared(.object([.init(key: "format", value: .string("port")), .init(key: "default", value: .string("8080"))])), for: .key("PORT"))
			}
			try #"{"envSchema":{"vars":{"PORT":{"format":"port","default":"3000"},"RETRY_COUNT":{"format":"integer","min":0,"max":3}}}}"#
				.write(toFile: folder + "/lpm.json", atomically: true, encoding: .utf8)
			#expect(try await host.waitForText("your draft was re-applied"))
			#expect(try await host.waitForText("RETRY_COUNT changed outside"))
			store.dismissSchemaDraftRebase(in: "schema-review")
			#expect(try await host.waitForTextToDisappear("your draft was re-applied"))
		}

		@Test("a change on disk that conflicts when Save is pressed closes the review, and the banner asks which version to keep")
		func conflictAtSave() async throws {
			let (store, host, folder) = try await workspace()
			defer { host.window.close(); store.lock(); try? FileManager.default.removeItem(atPath: folder) }
			let sheet = try await openReview(store, host)
			try #"{"envSchema":{"vars":{"PORT":{"format":"port","default":"3000"},"RETRY_COUNT":{"format":"integer","min":0,"max":3}}}}"#
				.write(toFile: folder + "/lpm.json", atomically: true, encoding: .utf8)
			#expect(try pressReturn(in: sheet), "Return saves")
			#expect(try await host.waitUntil { host.window.sheets.isEmpty }, "The review closes")
			#expect(try await host.waitForText("conflicts with your draft"))
		}

		@Test("a review that changes while it's open says so, and saves only with a click")
		func changedWhileOpen() async throws {
			let (store, host, folder) = try await workspace()
			defer { host.window.close(); store.lock(); try? FileManager.default.removeItem(atPath: folder) }
			let sheet = try await openReview(store, host)
			let project = try #require(store.projects.first)
			store.projects = [VaultProject(id: project.id, name: project.name, path: project.path, environments: ["default": ["PORT": "3000", "RETRY_COUNT": "4"]])]
			#expect(try await host.waitForText("changed while it was open", in: sheet))
			#expect(try !pressReturn(in: sheet), "Return doesn't save a review the person hasn't seen")
			try await host.click("Save to", in: sheet)
			#expect(try await host.waitUntil { store.schemaDraft(for: "schema-review") == nil })
			#expect(try String(contentsOfFile: folder + "/lpm.json", encoding: .utf8).contains(#""max": 5"#))
		}

		@Test("a draft that ends while it's saving closes the review once the save returns")
		func draftEndsDuringSave() async throws {
			let (store, host, folder) = try await workspace()
			defer { host.window.close(); store.lock(); try? FileManager.default.removeItem(atPath: folder) }
			let sheet = try await openReview(store, host)
			let gate = DispatchSemaphore(value: 0)
			ProjectConfigFile.editQueue.async { gate.wait() }
			defer { gate.signal() }
			#expect(try pressReturn(in: sheet))
			#expect(try await host.waitUntil { store.savingSchemaDrafts.contains("schema-review") })
			// The folder is replaced: same path, another directory, so the draft no longer belongs to it.
			try FileManager.default.moveItem(atPath: folder, toPath: folder + "-old")
			defer { try? FileManager.default.removeItem(atPath: folder + "-old") }
			try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
			try Self.sample.write(toFile: folder + "/lpm.json", atomically: true, encoding: .utf8)
			store.reloadKeyDescriptions()
			#expect(try await host.waitUntil { store.schemaDraft(for: "schema-review") == nil })
			gate.signal()
			#expect(try await host.waitUntil { host.window.sheets.isEmpty }, "The review doesn't wait on a draft that's gone")
		}

		@Test("lpm.json edited while another page showed is read again when the Schema page returns")
		func rereadOnReturn() async throws {
			let (store, host, folder) = try await workspace()
			defer { host.window.close(); store.lock(); try? FileManager.default.removeItem(atPath: folder) }
			store.editSchemaDraft(in: "schema-review") {
				$0.set(.declared(.object([.init(key: "format", value: .string("port")), .init(key: "default", value: .string("8080"))])), for: .key("PORT"))
			}
			try await host.click("Drift between envs")
			try await host.settle()
			try #"{"envSchema":{"vars":{"PORT":{"format":"port","default":"3000"},"RETRY_COUNT":{"format":"integer","min":0,"max":3}}}}"#
				.write(toFile: folder + "/lpm.json", atomically: true, encoding: .utf8)
			try await Task.sleep(for: .milliseconds(400))
			#expect(store.schemaDraftRebases["schema-review"] == nil, "Nothing watches lpm.json while another page shows")
			try await host.click("Schema")
			#expect(try await host.waitForText("RETRY_COUNT changed outside"))
		}

		@Test("the review closes when another project is opened")
		func closesWithItsProject() async throws {
			let (store, host, folder) = try await workspace()
			defer { host.window.close(); store.lock(); try? FileManager.default.removeItem(atPath: folder) }
			_ = try await openReview(store, host)
			store.projects.append(VaultProject(id: "other", name: "other-app", path: "", environments: ["default": [:]]))
			store.openProject(id: "other")
			#expect(try await host.waitUntil { host.window.sheets.isEmpty })
		}

		@Test("a long list of effects shows the first ones, and the rest on request")
		func longEffects() async throws {
			let keys = (1...15).map { #""K\#($0)":{"requiredWhen":{"variable":"MODE","present":true}}"# }.joined(separator: ",")
			let (store, host, folder) = try await workspace(#"{"envSchema":{"vars":{"MODE":{},\#(keys)}}}"#)
			defer { host.window.close(); store.lock(); try? FileManager.default.removeItem(atPath: folder) }
			try await host.click("MODE")
			#expect(try await host.waitForText("STORED VALUES"))
			store.editSchemaDraft(in: "schema-review") { $0.set(.declared(.object([.init(key: "default", value: .string("on"))])), for: .key("MODE")) }
			#expect(try await host.waitUntil { store.schemaDraftReview(for: "schema-review", environments: ["default"])?.values == .checked })
			try await host.click("Review & save")
			#expect(try await host.waitUntil { host.window.sheets.first != nil })
			let sheet = try #require(host.window.sheets.first)
			#expect(try await host.waitForText("OTHER KEYS", in: sheet))
			try scrollToEnd(sheet)
			#expect(try await host.waitForText("Show 3 more", in: sheet))
			try await host.click("Show 3 more", in: sheet)
			#expect(try await host.waitForTextToDisappear("Show 3 more"))
		}

		private func openReview(_ store: VaultStore, _ host: SheetTestHost<some View>) async throws -> NSWindow {
			try await host.click("RETRY_COUNT")
			#expect(try await host.waitForText("STORED VALUES"))
			try host.enterText("5", placeholder: "max")
			#expect(try await host.waitUntil { store.schemaDraftReview(for: "schema-review", environments: ["default"])?.values == .checked })
			try await host.click("Review & save")
			#expect(try await host.waitUntil { host.window.sheets.first != nil })
			let sheet = try #require(host.window.sheets.first)
			#expect(try await host.waitForText("Newly failing", in: sheet))
			return sheet
		}

		private func scrollToEnd(_ sheet: NSWindow) throws {
			func scrollView(in view: NSView) -> NSScrollView? {
				if let scroll = view as? NSScrollView { return scroll }
				return view.subviews.lazy.compactMap(scrollView(in:)).first
			}
			let scroll = try #require(sheet.contentView.flatMap(scrollView(in:)))
			let document = try #require(scroll.documentView)
			document.scroll(NSPoint(x: 0, y: document.isFlipped ? document.bounds.maxY : 0))
		}

		private func pressReturn(in sheet: NSWindow) throws -> Bool {
			let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
				windowNumber: sheet.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
			return sheet.performKeyEquivalent(with: event)
		}

		private func workspace(_ sample: String = Self.sample) async throws -> (VaultStore, SheetTestHost<some View>, String) {
			let folder = FileManager.default.temporaryDirectory.appending(path: "schema-review-\(UUID().uuidString)").path
			try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
			try sample.write(toFile: folder + "/lpm.json", atomically: true, encoding: .utf8)
			let keychain = MockKeychainService()
			let project = VaultProject(id: "schema-review", name: "billing-app", path: folder, environments: [
				"default": ["PORT": "3000", "RETRY_COUNT": "7"],
			])
			keychain.envStorage[project.id] = (name: project.name, path: folder, environments: project.environments)
			let store = VaultStore(keychainService: keychain, biometricService: MockBiometricService(),
				apiService: MockAPIService(), authTokenProvider: { _, _ in nil })
			store.isUnlocked = true
			store.projects = [project]
			store.openProject(id: project.id)
			await store.refreshCliAccess()
			let defaults = try #require(UserDefaults(suiteName: "schema-review-interaction"))
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
