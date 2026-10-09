import Foundation
import os
import Testing

@testable import LPMVault

@Suite("Value checks")
struct ProjectEnvValueCheckTests {
	@Test("fallback tables include ignored inherited keys")
	func fallbackTablesIncludeIgnoredInheritedKeys() throws {
		let rules = try overview(#"{"vars":{"PORT":{}}}"#)
		let project = VaultProject(id: "p", name: "p", path: "",
			environments: ["default": ["NODE_OPTIONS": "--inspect"], "production": [:]])
		let check = try #require(rules.check(project.environments))
		let presentation = VaultValueCheckPresentation(check: check, rules: rules, project: project)
		#expect(presentation.invalidKeys(in: "production") == ["NODE_OPTIONS"])
		#expect(presentation.unstoredKeys(in: "production") == ["NODE_OPTIONS"])
		#expect(presentation.reason(for: "NODE_OPTIONS", in: "production")
			== "The LPM CLI never passes NODE_OPTIONS to commands.")
	}

	@Test("a declared-key rename preview matches the saved rules and values")
	func renamePreviewMatchesSavedState() async throws {
		let folder = FileManager.default.temporaryDirectory.appending(path: "rename-preview-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: folder) }
		try #"{"envSchema":{"vars":{"OLD":{"format":"port"},"TOKEN":{"requiredWhen":{"variable":"OLD","equals":"3000"}},"ALT":{}},"groups":{"choice":{"mode":"exactlyOne","vars":["OLD","ALT"]}}}}"#
			.write(to: folder.appending(path: "lpm.json"), atomically: true, encoding: .utf8)
		let rules = try #require(ProjectEnvSchemaFile.load(inFolder: folder.path, vaultID: "p").schema.overview)
		let project = VaultProject(id: "p", name: "p", path: folder.path,
			environments: ["default": ["OLD": "bad", "ALT": "set"], "production": ["OLD": "3000"]])
		let edit = VaultKeyEdit(key: "OLD", environments: project.environments, newKey: "NEW")
		let worker = ProjectEnvValueCheckWorker()
		let preview = try #require(await worker.preview(edit: edit, project: project, rules: rules))
		_ = try ProjectEnvSchemaFile.apply(.init(rename: .init(from: "OLD", to: "NEW")),
			inFolder: folder.path, vaultID: "p")
		let savedRules = try #require(ProjectEnvSchemaFile.load(inFolder: folder.path, vaultID: "p").schema.overview)
		let savedValues = try edit.applied(to: project.environments).get()
		#expect(preview.project.environments == savedValues)
		#expect(preview.rules.effectiveSchema == savedRules.effectiveSchema)
		#expect(preview.check == savedRules.check(savedValues))
		#expect(preview.check?.problems(of: "NEW", in: "default").contains(.init(key: "NEW", kind: .format("port"))) == true)
		#expect(preview.rules.groups.first?.members == ["NEW", "ALT"])
	}

	@Test("group explanations exclude values the CLI ignores")
	func groupMessagesExcludeIgnoredValues() throws {
		let rules = try overview(#"{"vars":{"NODE_OPTIONS":{},"TOKEN":{}},"groups":{"auth":{"mode":"exactlyOne","vars":["NODE_OPTIONS","TOKEN"]}}}"#)
		let project = VaultProject(id: "p", name: "p", path: "",
			environments: ["default": ["NODE_OPTIONS": "ignored"], "production": [:]])
		let check = try #require(rules.check(project.environments))
		let presentation = VaultValueCheckPresentation(check: check, rules: rules, project: project)
		for environment in ["default", "production"] {
			#expect(presentation.groupFailures(in: environment).first?.message
				== "Exactly one of NODE_OPTIONS, TOKEN — none set")
		}
	}

	@Test func fallback_preserves_environment_scoped_missing_requirements() throws {
		let rules = try overview(
			#"{"vars":{"API_TOKEN":{"requiredIn":[{"environment":["production"]}]},"PORT":{}}}"#)
		let project = VaultProject(
			id: "p", name: "p", path: "", environments: ["default": ["PORT": "3000"], "production": [:]])
		let check = try #require(rules.check(project.environments))
		#expect(check.problems(of: "API_TOKEN", in: "default").isEmpty)
		#expect(check.problems(of: "API_TOKEN", in: "production").count == 1)
		let presentation = VaultValueCheckPresentation(check: check, rules: rules, project: project)
		#expect(presentation.invalidKeys(in: "production").contains("API_TOKEN"))
		#expect(presentation.isRequiredAndUnset("API_TOKEN", in: "production"))
	}
	@Test func group_message_counts_defaults_replacing_empty_values() throws {
		let rules = try overview(
			#"{"vars":{"A":{"default":"x"},"B":{}},"groups":{"pair":{"mode":"exactlyOne","vars":["A","B"]}}}"#
		)
		let project = VaultProject(
			id: "p", name: "p", path: "", environments: ["default": ["A": "", "B": "y"]])
		let check = try #require(rules.check(project.environments))
		#expect(check.defaultValue(of: "A", in: "default") == "x")
		let presentation = VaultValueCheckPresentation(check: check, rules: rules, project: project)
		#expect(presentation.groupFailures(in: "default").first?.message == "Exactly one of A, B — both set")
	}

	@Test("a cancelled queued value check never enters the engine")
	func cancelledQueuedCheckSkipsEngine() async {
		let calls = OSAllocatedUnfairLock(initialState: 0)
		let entered = DispatchSemaphore(value: 0)
		let release = DispatchSemaphore(value: 0)
		defer { release.signal() }
		let worker = ProjectEnvValueCheckWorker { _, _ in
			let call = calls.withLock { count in count += 1; return count }
			if call == 1 {
				entered.signal()
				_ = release.wait(timeout: .now() + 5)
			}
			return nil
		}
		let first = Task { await worker.check(rules: .empty, environments: [:]) }
		let started = await withCheckedContinuation { continuation in
			Thread.detachNewThread { continuation.resume(returning: entered.wait(timeout: .now() + 5) == .success) }
		}
		#expect(started)
		let cancelled = Task { await worker.check(rules: .empty, environments: [:]) }
		cancelled.cancel()
		release.signal()
		_ = await first.value
		_ = await cancelled.value

		#expect(calls.withLock { $0 } == 1)
	}

	private typealias Problem = ProjectEnvValueCheck.Problem

	private func overview(_ schema: String) throws -> ProjectEnvSchemaOverview {
		let folder = FileManager.default.temporaryDirectory.appending(path: "value-check-\(UUID().uuidString)").path
		try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(atPath: folder) }
		try #"{"envSchema":\#(schema)}"#.write(toFile: folder + "/lpm.json", atomically: true, encoding: .utf8)
		return try #require(ProjectEnvSchemaFile.load(inFolder: folder, vaultID: "project").schema.overview)
	}

	@Test("the engine reports each environment's problems, defaults, and ignored keys")
	func checksEachEnvironment() throws {
		let rules = try overview(#"""
			{"vars":{
				"API_TOKEN":{"secret":true,"requiredIn":[{"environment":["production"]}]},
				"DATABASE_URL":{"format":"url"},
				"PORT":{"format":"port","default":"3000"},
				"WORKERS":{"format":"integer","min":"1"},
				"LEVEL":{"enum":["debug","info"],"defaultsIn":[{"when":{"environment":["production"]},"value":"info"}]},
				"PASSWORD":{"secret":true},
				"OAUTH_TOKEN":{"secret":true}
			},"groups":{"credentials":{"mode":"exactlyOne","vars":["PASSWORD","OAUTH_TOKEN"]}}}
			"""#)
		let check = try #require(rules.check([
			"default": ["DATABASE_URL": "not a url", "WORKERS": "0", "PASSWORD": "a", "OAUTH_TOKEN": "b", "LEVEL": "trace"],
			"production": ["DATABASE_URL": "https://db.example.com", "PASSWORD": "a", "NODE_OPTIONS": "--inspect"],
			"staging": [:],
		]))

		let defaults = try #require(check.environments["default"])
		#expect(!defaults.readsDefaultEnvironment)
		#expect(check.problems(of: "DATABASE_URL", in: "default") == [Problem(key: "DATABASE_URL", kind: .format("url"))])
		#expect(check.problems(of: "WORKERS", in: "default") == [Problem(key: "WORKERS", kind: .constraint("min"))])
		#expect(check.problems(of: "LEVEL", in: "default") == [Problem(key: "LEVEL", kind: .notAllowed)])
		#expect(check.problems(of: "PASSWORD", in: "default") == [Problem(key: "PASSWORD", kind: .group(name: "credentials", mode: "exactlyOne"))])
		#expect(check.problems(of: "API_TOKEN", in: "default").isEmpty, "Required only in production")
		#expect(defaults.defaults == ["PORT": "3000"])

		let production = try #require(check.environments["production"])
		#expect(check.problems(of: "API_TOKEN", in: "production") == [Problem(key: "API_TOKEN", kind: .required)])
		#expect(production.problems.keys.sorted() == ["API_TOKEN"])
		#expect(production.defaults == ["PORT": "3000", "LEVEL": "info"])
		#expect(production.ignored == ["NODE_OPTIONS"])

		let staging = try #require(check.environments["staging"])
		#expect(staging.readsDefaultEnvironment, "An environment without values reads the default environment's")
		#expect(staging.problems == defaults.problems)
	}

	@Test("rules without a resolved schema, and unexpected engine output, check nothing")
	func failsClosed() {
		let unresolved = ProjectEnvSchemaOverview(rules: [.init(key: "PORT", isPublic: false, source: nil, badges: [])], groups: [])
		#expect(unresolved.check(["default": ["PORT": "x"]]) == nil)
		#expect(ProjectEnvValueCheck(output: .object([])) == nil)
		let malformed = LPMConfigJSON.object([.init(key: "environments", value: .object([
			.init(key: "default", value: .object([.init(key: "problems", value: .array([]))])),
		]))])
		#expect(ProjectEnvValueCheck(output: malformed) == nil)
	}

	@Test("default-environment fallback values count against the engine work budget")
	func fallbackValuesRespectWorkBudget() throws {
		let rules = try overview(#"{"vars":{"A":{}}}"#)
		let defaults = Dictionary(uniqueKeysWithValues: (0..<1_024).map { ("V\($0)", "x") })
		var environments = Dictionary(uniqueKeysWithValues: (0..<255).map { ("env\($0)", [String: String]()) })
		environments["default"] = defaults

		#expect(rules.check(environments) == nil)
	}

	@Test("every group member counts against the engine work budget")
	func groupMembersRespectWorkBudget() throws {
		let variables = (0..<32).map { #""V\#($0)":{}"# }.joined(separator: ",")
		let members = (0..<32).map { #""V\#($0)""# }.joined(separator: ",")
		let groups = (0..<128).map { #""G\#($0)":{"mode":"allOrNone","vars":[\#(members)]}"# }.joined(separator: ",")
		let rules = try overview(#"{"vars":{\#(variables)},"groups":{\#(groups)}}"#)
		let environments = Dictionary(uniqueKeysWithValues: (0..<64).map { ("env\($0)", [String: String]()) })

		#expect(rules.check(environments) == nil)
	}


}

@Suite("Value checks in the store", .serialized)
@MainActor
struct ValueCheckStoreTests {
    @Test func published_checks_are_invalidated_when_stored_values_change() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path:"review-stale-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:folder) }
        try #"{"envSchema":{"vars":{"PORT":{"format":"port"}}}}"#.write(to:folder.appending(path:"lpm.json"),atomically:true,encoding:.utf8)
        let keychain = MockKeychainService()
        let project = VaultProject(id:"p",name:"p",path:folder.path,environments:["default":["PORT":"3000"]])
        keychain.envStorage[project.id] = (name:project.name,path:folder.path,environments:project.environments)
        let store = VaultStore(keychainService:keychain,biometricService:MockBiometricService(),apiService:MockAPIService(),authTokenProvider:{_,_ in nil})
        store.isUnlocked = true
        store.projects = [project]
        store.openProject(id:project.id)
        defer { store.lock() }
        store.reloadKeyDescriptions()
        for _ in 0..<500 {
            if store.valueChecks[project.id] != nil { break }
            try await Task.sleep(for:.milliseconds(10))
        }
        let previous = try #require(store.valueChecks[project.id])
        #expect(previous.problems(of:"PORT",in:"default").isEmpty)
        store.projects[0].environments["default"]?["PORT"] = "bad"
        #expect(store.valueChecks[project.id] == nil)
    }

	@Test("the store checks the selected project's values, rechecks after an edit, and drops the check when lpm.json breaks or the vault locks")
	func storeKeepsChecksCurrent() async throws {
		let folder = FileManager.default.temporaryDirectory.appending(path: "value-check-store-\(UUID().uuidString)").path
		try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(atPath: folder) }
		try #"{"envSchema":{"vars":{"PORT":{"format":"port"},"WORKERS":{"format":"integer"}}}}"#
			.write(toFile: folder + "/lpm.json", atomically: true, encoding: .utf8)
		let keychain = MockKeychainService()
		let project = VaultProject(id: "checked", name: "api", path: folder, environments: ["default": ["PORT": "not-a-port"]])
		keychain.envStorage[project.id] = (name: project.name, path: folder, environments: project.environments)
		let store = VaultStore(keychainService: keychain, biometricService: MockBiometricService(),
			apiService: MockAPIService(), authTokenProvider: { _, _ in nil })
		store.isUnlocked = true
		store.projects = [project]
		store.openProject(id: project.id)
		defer { store.lock() }
		store.reloadKeyDescriptions()

		func eventually(_ condition: () -> Bool) async throws -> Bool {
			for _ in 0..<500 {
				if condition() { return true }
				try await Task.sleep(for: .milliseconds(10))
			}
			return condition()
		}
		typealias Problem = ProjectEnvValueCheck.Problem
		#expect(try await eventually { store.valueChecks[project.id]?.problems(of: "PORT", in: "default") == [Problem(key: "PORT", kind: .format("port"))] })

		#expect(await store.addSecret(to: project.id, environment: "default", key: "WORKERS", value: "many") == .success)
		#expect(try await eventually { store.valueChecks[project.id]?.problems(of: "WORKERS", in: "default") == [Problem(key: "WORKERS", kind: .format("integer"))] })

		try "{not json".write(toFile: folder + "/lpm.json", atomically: true, encoding: .utf8)
		store.reloadKeyDescriptions()
		#expect(try await eventually { store.valueChecks[project.id] == nil }, "Nothing is checked while lpm.json can't be read")

		try #"{"envSchema":{"vars":{"PORT":{"format":"port"}}}}"#.write(toFile: folder + "/lpm.json", atomically: true, encoding: .utf8)
		store.reloadKeyDescriptions()
		#expect(try await eventually { store.valueChecks[project.id] != nil })
		store.lock()
		#expect(store.valueChecks.isEmpty)
	}
}

@Suite("Value check presentation")
struct VaultValueCheckPresentationTests {
	private typealias Problem = ProjectEnvValueCheck.Problem
	private typealias Environment = ProjectEnvValueCheck.Environment

	private let project = VaultProject(id: "p", name: "p", path: "", environments: [
		"default": ["DATABASE_URL": "x", "PASSWORD": "a", "OAUTH_TOKEN": "b", "NODE_OPTIONS": "--inspect"],
		"production": ["DATABASE_URL": "https://db"],
		"staging": [:],
	])
	private let rules = ProjectEnvSchemaOverview(rules: [
		.init(key: "API_TOKEN", isPublic: false, source: nil, badges: [.init(text: "Required in production"), .init(text: "Secret")]),
		.init(key: "DATABASE_URL", isPublic: false, source: nil, badges: [.init(text: "URL")]),
	], groups: [.init(name: "credentials", members: ["PASSWORD", "OAUTH_TOKEN"], mode: "exactlyOne")])

	private var presentation: VaultValueCheckPresentation {
		let group = Problem.Kind.group(name: "credentials", mode: "exactlyOne")
		let check = ProjectEnvValueCheck(environments: [
			"default": Environment(problems: [
				"DATABASE_URL": [Problem(key: "DATABASE_URL", kind: .format("url"))],
				"PASSWORD": [Problem(key: "PASSWORD", kind: group)],
				"OAUTH_TOKEN": [Problem(key: "OAUTH_TOKEN", kind: group)],
			], defaults: ["PORT": "3000"], ignored: ["NODE_OPTIONS"]),
			"production": Environment(problems: ["API_TOKEN": [Problem(key: "API_TOKEN", kind: .required)]], defaults: ["PORT": "3000"]),
			"staging": Environment(readsDefaultEnvironment: true, problems: ["DATABASE_URL": [Problem(key: "DATABASE_URL", kind: .format("url"))]], defaults: ["PORT": "3000"]),
		])
		return VaultValueCheckPresentation(check: check, rules: rules, project: project)
	}

	@Test("problems read as plain reasons, with the rule's scope and the group's state")
	func reasons() {
		let shown = presentation
		#expect(shown.reason(for: "DATABASE_URL", in: "default") == "Not a valid URL")
		#expect(shown.reason(for: "API_TOKEN", in: "production") == "Required in production")
		#expect(shown.reason(for: "PASSWORD", in: "default") == "Exactly one of PASSWORD, OAUTH_TOKEN — both set")
		#expect(shown.reason(for: "NODE_OPTIONS", in: "default") == "The LPM CLI never passes NODE_OPTIONS to commands.")
		#expect(shown.reason(for: "DATABASE_URL", in: "production") == nil)
		#expect(shown.groupFailures(in: "default").map(\.message) == ["Exactly one of PASSWORD, OAUTH_TOKEN — both set"])
		#expect(shown.isRequiredAndUnset("API_TOKEN", in: "production"))
	}

	@Test("fallback environments retain their scoped problems and defaults")
	func defaultEnvironmentReaders() {
		let shown = presentation
		#expect(shown.readsDefaultEnvironment("staging"))
		#expect(shown.problems(of: "DATABASE_URL", in: "staging") == [.init(key: "DATABASE_URL", kind: .format("url"))])
		#expect(shown.defaultValue(of: "PORT", in: "staging") == "3000")
		#expect(shown.invalidKeys(in: "staging") == ["DATABASE_URL"])
		#expect(shown.invalidKeys == ["DATABASE_URL", "PASSWORD", "OAUTH_TOKEN", "NODE_OPTIONS", "API_TOKEN"])
	}

	@Test("schema defaults escape controls before display")
	func defaultsEscapeControls() {
		let check = ProjectEnvValueCheck(environments: [
			"production": Environment(defaults: ["MESSAGE": "before\u{2028}middle\u{202E}after"]),
		])
		let shown = VaultValueCheckPresentation(check: check, rules: nil, project: project)

		#expect(shown.defaultValue(of: "MESSAGE", in: "production") == "before\\u{2028}middle\\u{202e}after")
	}

	@Test("declared keys without a stored value show where a rule or a default needs them")
	func unstoredKeys() {
		let shown = presentation
		#expect(shown.unstoredKeys(in: "production") == ["API_TOKEN", "PORT"])
		#expect(shown.unstoredKeys(in: "staging") == ["DATABASE_URL", "PORT"])
		#expect(shown.unstoredInvalidKeys() == ["API_TOKEN"])
		#expect(VaultValueCheckPresentation.none.invalidKeys.isEmpty)
		#expect(!VaultValueCheckPresentation.none.hasCheck)
	}

	@Test("tables list declared keys among stored ones in Finder order, and the Invalid filter keeps failing keys")
	func derivation() {
		let snapshot = VaultWorkspaceSnapshot(project: project)
		func derive(_ mode: VaultWorkspaceMode, filter: VaultWorkspaceFilter = .all, search: String = "", order: VaultKeySortOrder = .ascending, unstored: Set<String>) -> VaultContentDerivation {
			VaultContentDerivation(project: project, snapshot: snapshot, selectedEnvironment: "production", mode: mode,
				filter: filter, searchText: search, sortOrder: order, revealedKeys: [],
				invalidKeys: ["API_TOKEN", "DATABASE_URL"], unstoredKeys: unstored)
		}
		#expect(derive(.matrix, unstored: ["API_TOKEN"]).filteredKeys == ["API_TOKEN", "DATABASE_URL", "NODE_OPTIONS", "OAUTH_TOKEN", "PASSWORD"])
		#expect(derive(.matrix, order: .descending, unstored: ["API_TOKEN"]).filteredKeys.first == "PASSWORD")
		#expect(derive(.matrix, filter: .invalid, unstored: ["API_TOKEN"]).filteredKeys == ["API_TOKEN", "DATABASE_URL"])
		#expect(derive(.matrix, search: "api", unstored: ["API_TOKEN"]).filteredKeys == ["API_TOKEN"])
		#expect(derive(.environment("production"), unstored: ["API_TOKEN", "PORT"]).environmentKeys == ["API_TOKEN", "DATABASE_URL", "PORT"])
		#expect(derive(.environment("production"), order: .descending, unstored: ["API_TOKEN", "PORT"]).environmentKeys == ["PORT", "DATABASE_URL", "API_TOKEN"])
		#expect(derive(.environment("production"), search: "port", unstored: ["API_TOKEN", "PORT"]).environmentKeys == ["PORT"])
	}
}
