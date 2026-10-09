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
		#expect(review.items[2].effects == [.init(environment: "staging", kind: .noLongerChecked, message: "Stored value kept; no longer checked")])
		#expect(review.others == [.init(environment: "staging", kind: .newlyFailing, message: "API: Required")])
		#expect(review.checkedValues)
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
	])
	func conflictSummary(mine: String, theirs: String?, mineText: String, theirsText: String) throws {
		let conflict = Draft.Conflict(item: .key("PORT"), mine: .declared(try json(mine)), theirs: try theirs.map { .declared(try json($0)) } ?? .absent)
		#expect(conflict.summary.mine == mineText)
		#expect(conflict.summary.theirs == theirsText)
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

	@Test("the watcher reports lpm.json written in place or replaced, once per burst")
	func watcherReportsChanges() async throws {
		let folder = FileManager.default.temporaryDirectory.appending(path: "config-watch-\(UUID().uuidString)").path
		try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(atPath: folder) }
		try "{}".write(toFile: folder + "/lpm.json", atomically: false, encoding: .utf8)
		let changes = ChangeCounter()
		let watching = Task {
			for await _ in ProjectConfigWatcher.changes(inFolder: folder, settling: .milliseconds(100)) { changes.increment() }
		}
		defer { watching.cancel() }
		try await Task.sleep(for: .milliseconds(100))

		let handle = try #require(FileHandle(forWritingAtPath: folder + "/lpm.json"))
		handle.write(Data(#"{"a":1}"#.utf8))
		try handle.close()
		#expect(try await eventually { changes.count == 1 })

		for value in 0..<5 {
			try #"{"b":\#(value)}"#.write(toFile: folder + "/lpm.json", atomically: true, encoding: .utf8)
		}
		#expect(try await eventually { changes.count == 2 })
		try await Task.sleep(for: .milliseconds(300))
		#expect(changes.count == 2, "A burst of saves is one change")

		let replaced = try #require(FileHandle(forWritingAtPath: folder + "/lpm.json"))
		replaced.write(Data(#"{"c":1}"#.utf8))
		try replaced.close()
		#expect(try await eventually { changes.count == 3 }, "The watcher follows the replaced file")
	}

	private func eventually(_ condition: () -> Bool) async throws -> Bool {
		for _ in 0..<300 {
			if condition() { return true }
			try await Task.sleep(for: .milliseconds(10))
		}
		return condition()
	}
}

private final class ChangeCounter: @unchecked Sendable {
	private let lock = NSLock()
	private var value = 0
	var count: Int { lock.withLock { value } }
	func increment() { lock.withLock { value += 1 } }
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

		private func workspace() async throws -> (VaultStore, SheetTestHost<some View>, String) {
			let folder = FileManager.default.temporaryDirectory.appending(path: "schema-review-\(UUID().uuidString)").path
			try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
			try Self.sample.write(toFile: folder + "/lpm.json", atomically: true, encoding: .utf8)
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
			#expect(try await host.waitForText("RETRY_COUNT"))
			return (store, host, folder)
		}
	}
}
