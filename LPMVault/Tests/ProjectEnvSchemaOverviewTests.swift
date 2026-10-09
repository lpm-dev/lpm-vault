import Foundation
import Testing

@testable import LPMVault

@Suite("Env schema overview")
struct ProjectEnvSchemaOverviewTests {
	private typealias Badge = ProjectEnvSchemaOverview.Badge

	@Test("the engine's resolved rules become plain-word badges with their sources, groups, and public keys")
	func resolvedRules() throws {
		let folder = try makeFolder(#"""
			{"envSchema":{
				"extends":["preset:node","schemas/base.json"],
				"vars":{
					"API_TOKEN":{"secret":true,"requiredIn":[{"environment":["production"]}],"description":"Bearer token for the admin API."},
					"AUTH_MODE":{"enum":["password","oauth"],"default":"password"},
					"NEXT_PUBLIC_API_URL":{"client":true,"format":"url","protocols":["https"]},
					"PORT":{"format":"port","default":"3000"},
					"PASSWORD":{"secret":true,"minLength":12,"requiredWhen":{"variable":"AUTH_MODE","equals":"password"}},
					"OAUTH_TOKEN":{"secret":true},
					"RETRY_COUNT":{"format":"integer","min":"0","max":"10","default":"3","ci":"variable"},
					"TOKEN_PATTERN":{"pattern":"^tok_[a-z]+$","empty":"allow"},
					"BUILD_FLAG":{"defaultsIn":[{"when":{"stage":["test"]},"value":"4000"}],"requiredIn":[{"environment":["production","staging"],"stage":["build"],"service":["api"]}]}
				},
				"groups":{"credentials":{"mode":"exactlyOne","vars":["PASSWORD","OAUTH_TOKEN"]}}
			}}
			"""#, files: ["schemas/base.json": #"{"vars":{"DATABASE_URL":{"format":"url","required":true,"secret":true}}}"#])
		defer { try? FileManager.default.removeItem(atPath: folder) }

		let loaded = ProjectEnvSchemaFile.load(inFolder: folder, vaultID: "project")
		guard case .loaded(let overview, let file) = loaded.schema else {
			Issue.record("Expected loaded rules, got \(loaded.schema)")
			return
		}
		#expect(file?.path == folder + "/lpm.json")
		#expect(overview.rules.map(\.key) == [
			"API_TOKEN", "AUTH_MODE", "BUILD_FLAG", "DATABASE_URL", "NEXT_PUBLIC_API_URL",
			"NODE_ENV", "OAUTH_TOKEN", "PASSWORD", "PORT", "RETRY_COUNT", "TOKEN_PATTERN",
		])
		let badges = Dictionary(uniqueKeysWithValues: overview.rules.map { ($0.key, $0.badges.map(\.text)) })
		#expect(badges["API_TOKEN"] == ["Required in production", "Secret"])
		#expect(badges["AUTH_MODE"] == ["One of: password, oauth", "Default: password"])
		#expect(badges["BUILD_FLAG"] == ["Required in production, staging · build stage · api service", "Default in test stage: 4000"])
		#expect(badges["DATABASE_URL"] == ["Required", "URL", "Secret"])
		#expect(badges["NEXT_PUBLIC_API_URL"] == ["URL", "https only"])
		#expect(badges["OAUTH_TOKEN"] == ["Secret"])
		#expect(badges["PASSWORD"] == ["Required when AUTH_MODE = password", "12+ chars", "Secret"])
		#expect(badges["PORT"] == ["Port", "Default: 3000"])
		#expect(badges["RETRY_COUNT"] == ["Integer", "0–10", "Default: 3", "CI variable"])
		#expect(overview.rule(for: "TOKEN_PATTERN")?.badges == [Badge(text: "Pattern", help: "^tok_[a-z]+$"), Badge(text: "Empty allowed")])
		#expect(overview.rule(for: "DATABASE_URL")?.source == "schemas/base.json")
		#expect(overview.rule(for: "NODE_ENV")?.source == "preset:node")
		#expect(overview.rule(for: "PORT")?.source == nil)
		#expect(overview.inheritedCount == 2)
		#expect(overview.publicKeys == ["NEXT_PUBLIC_API_URL"])
		#expect(overview.rule(for: "NEXT_PUBLIC_API_URL")?.isPublic == true)
		#expect(overview.groups == [.init(name: "credentials", summary: "Exactly one of PASSWORD, OAUTH_TOKEN", members: ["PASSWORD", "OAUTH_TOKEN"], mode: "exactlyOne")])
		#expect(try loaded.rules.get().descriptions == ["API_TOKEN": "Bearer token for the admin API."])
	}

	@Test("badges cover one-sided bounds, conditions, scopes, and long literals without losing them")
	func badgeVocabulary() throws {
		func badges(_ rule: String) throws -> [Badge] {
			ProjectEnvSchemaOverview.badges(for: try LPMConfigJSON(parsing: Data(rule.utf8)))
		}
		#expect(try badges(#"{"format":"integer","min":"1"}"#).map(\.text) == ["Integer", "≥ 1"])
		#expect(try badges(#"{"format":"port","max":"8080"}"#).map(\.text) == ["Port", "≤ 8080"])
		#expect(try badges(#"{"format":"integer","min":"5","max":"5"}"#).map(\.text) == ["Integer", "Exactly 5"])
		#expect(try badges(#"{"maxLength":"64"}"#).map(\.text) == ["≤ 64 chars"])
		#expect(try badges(#"{"minLength":"8","maxLength":"8"}"#).map(\.text) == ["8 chars"])
		#expect(try badges(#"{"minLength":"1"}"#).map(\.text) == ["1+ chars"])
		#expect(try badges(#"{"requiredWhen":{"variable":"MODE","present":false}}"#).map(\.text) == ["Required when MODE is not set"])
		#expect(try badges(#"{"requiredWhen":{"variable":"MODE","present":true}}"#).map(\.text) == ["Required when MODE is set"])
		#expect(try badges(#"{"requiredWhen":{"variable":"MODE","equals":""}}"#).map(\.text) == [#"Required when MODE = """#])
		#expect(try badges(#"{"empty":"reject","format":"email"}"#).map(\.text) == ["Email", "Empty rejected"])
		#expect(try badges(#"{"protocols":["http","https"],"format":"url"}"#).map(\.text) == ["URL", "http, https only"])
		#expect(try badges(#"{"required":false,"secret":false,"client":true,"empty":"missing","ci":"secret"}"#).isEmpty)

		let choices = try badges(#"{"enum":["alpha","bravo","charlie","delta","echo","foxtrot","golf"]}"#)
		#expect(choices == [Badge(text: "One of: alpha, bravo, charlie, delta +3", help: "alpha\nbravo\ncharlie\ndelta\necho\nfoxtrot\ngolf")])
		let long = String(repeating: "x", count: 40)
		#expect(try badges(#"{"default":"\#(long)"}"#) == [Badge(text: "Default: " + String(repeating: "x", count: 32) + "…", help: long)])
		#expect(try badges(#"{"default":"line one\nline two"}"#) == [Badge(text: "Default: line one line two", help: "line one\nline two")])
	}

	@Test("enum badges preserve shortened and multiline allowed values", arguments: [
		[String(repeating: "x", count: 40)],
		["line one\nline two"],
		["line one\nline two", "short"],
	])
	func enumLiteralTooltips(options: [String]) throws {
		let rule = try LPMConfigJSON(parsing: JSONSerialization.data(withJSONObject: ["enum": options]))
		let badge = try #require(ProjectEnvSchemaOverview.badges(for: rule).first)
		#expect(badge.help == options.joined(separator: "\n"))
	}

	@Test("suggestions list declared keys not set in every selected environment, names that start with the text first")
	func suggestions() {
		let rules = ["API_TOKEN", "DATABASE_URL", "OAUTH_TOKEN", "PORT", "APP_NAME"].map {
			ProjectEnvSchemaOverview.Rule(key: $0, isPublic: false, source: nil, badges: [])
		}
		let overview = ProjectEnvSchemaOverview(rules: rules, groups: [])
		let project = VaultProject(id: "p", name: "p", path: "", environments: [
			"default": ["PORT": "1", "APP_NAME": "x"], "production": ["APP_NAME": "x"],
		])
		#expect(overview.suggestions(matching: "a", unsetIn: ["default"], of: project).map(\.key) == ["API_TOKEN", "DATABASE_URL", "OAUTH_TOKEN"])
		#expect(overview.suggestions(matching: "p", unsetIn: ["default", "production"], of: project).map(\.key) == ["PORT", "API_TOKEN"])
		#expect(overview.suggestions(matching: "API_TOKEN", unsetIn: ["default"], of: project).isEmpty, "An exact name needs no suggestion")
		#expect(overview.suggestions(matching: "api_token", unsetIn: ["default"], of: project).map(\.key) == ["API_TOKEN"])
		#expect(overview.suggestions(matching: " API_TOKEN ", unsetIn: ["default"], of: project).map(\.key) == ["API_TOKEN"])
		#expect(overview.suggestions(matching: "  ", unsetIn: ["default"], of: project).isEmpty)
		#expect(overview.suggestions(matching: "a", unsetIn: [], of: project).isEmpty)
		#expect(overview.suggestions(matching: "t", unsetIn: ["default"], of: project, limit: 2).count == 2)
	}

	@Test("folders without rules read as empty, and a missing folder asks to connect one")
	func emptyStates() throws {
		#expect(ProjectEnvSchemaFile.load(inFolder: "/nonexistent-\(UUID().uuidString)", vaultID: "project").schema == .noFolder)

		let bare = try makeFolder(nil)
		defer { try? FileManager.default.removeItem(atPath: bare) }
		#expect(ProjectEnvSchemaFile.load(inFolder: bare, vaultID: "project").schema == .loaded(.empty, file: nil))

		let unruled = try makeFolder(#"{"name":"app"}"#)
		defer { try? FileManager.default.removeItem(atPath: unruled) }
		let loaded = ProjectEnvSchemaFile.load(inFolder: unruled, vaultID: "project")
		guard case .loaded(let overview, let file) = loaded.schema else {
			Issue.record("Expected loaded rules, got \(loaded.schema)")
			return
		}
		#expect(overview.isEmpty)
		#expect(file == URL(fileURLWithPath: unruled + "/lpm.json"))
		#expect(try loaded.rules.get() == .init())
	}

	@Test("unreadable rules name the file and location the engine reports", arguments: [
		(#"{"envSchema":{"vars":{"PORT":{"rnage":"1"}}}}"#, [String: String](), "lpm.json › envSchema.vars.PORT.rnage", "Invalid schema definition. Check the field name and value type at this location."),
		(#"{"envSchema":{"extends":["a.json","b.json"]}}"#, ["a.json": #"{"vars":{"X":{}}}"#, "b.json": #"{"vars":{"X":{}}}"#], "b.json › vars.X", "More than one schema declares this key. Add an override in lpm.json to choose one."),
		(#"{"envSchema":{"extends":["a.json"]}}"#, ["a.json": #"{"extends":["lpm.json"]}"#], "lpm.json › envSchema.extends", "The imports form a cycle."),
		(#"{"envSchema":{"extends":["preset:nope"]}}"#, [:], "preset:nope", "This preset doesn't exist."),
		("{not json", [:], "lpm.json", "lpm.json is not valid JSON."),
		(#"{"vault":"another-project"}"#, [:], "lpm.json", "lpm.json in the project folder links another env project."),
	])
	func unreadableStates(json: String, files: [String: String], location: String, reason: String?) throws {
		let folder = try makeFolder(json, files: files)
		defer { try? FileManager.default.removeItem(atPath: folder) }
		let loaded = ProjectEnvSchemaFile.load(inFolder: folder, vaultID: "project")
		guard case .unreadable(let problem) = loaded.schema else {
			Issue.record("Expected an unreadable schema, got \(loaded.schema)")
			return
		}
		#expect(problem.location == location)
		if let reason { #expect(problem.reason == reason) } else { #expect(!problem.reason.isEmpty) }
		#expect(!problem.reason.contains("env."), "Known codes read as plain words: \(problem.reason)")
		#expect((try? loaded.rules.get()) == nil)
	}

	@Test("the store keeps rules and the schema display together and drops the display with the folder")
	func storeKeepsSchemaWithRules() {
		let rules = ProjectEnvSchemaFile.Rules(keys: ["A"], descriptions: ["A": "Alpha"])
		let schema = ProjectEnvSchemaState.loaded(ProjectEnvSchemaOverview(rules: [.init(key: "A", isPublic: false, source: nil, badges: [])], groups: []), file: nil)
		let loaded = ProjectKeyDescriptions(folder: "/tmp/app", loaded: .init(rules: .success(rules), schema: schema))
		#expect(loaded.schema == schema)
		#expect(loaded.description(of: "A") == "Alpha")
		#expect(ProjectKeyDescriptions(folder: "/tmp/app", rules: .success(rules)).schema == nil)
	}

	private func makeFolder(_ lpmJSON: String?, files: [String: String] = [:]) throws -> String {
		let folder = FileManager.default.temporaryDirectory.appending(path: "lpm-schema-overview-\(UUID().uuidString)").path
		try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
		if let lpmJSON { try lpmJSON.write(toFile: folder + "/lpm.json", atomically: true, encoding: .utf8) }
		for (path, contents) in files {
			let url = URL(fileURLWithPath: folder).appending(path: path)
			try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
			try contents.write(to: url, atomically: true, encoding: .utf8)
		}
		return folder
	}
}

@Suite("Schema display text")
struct SchemaDisplayTextTests {
	@Test("Unicode line and paragraph separators show as escapes")
	func escapesUnicodeSeparators() {
		#expect("before\u{2028}after".escapingDirectionControls == "before\\u{2028}after")
		#expect("before\u{2029}after".escapingDirectionControls == "before\\u{2029}after")
	}

	@Test("authored text that could hide or reorder what surrounds it shows escaped")
	func escapesDirectionControls() throws {
		let folder = FileManager.default.temporaryDirectory.appending(path: "display-text-\(UUID().uuidString)").path
		try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(atPath: folder) }
		let file = "base\u{202E}nosj.json"
		try #"{"vars":{"PORT":{"default":"30‮00"}}}"#.write(toFile: folder + "/" + file, atomically: true, encoding: .utf8)
		try #"{"envSchema":{"extends":["\#(file)"]}}"#.write(toFile: folder + "/lpm.json", atomically: true, encoding: .utf8)
		let rule = try #require(ProjectEnvSchemaFile.load(inFolder: folder, vaultID: "project").schema.overview?.rule(for: "PORT"))
		#expect(rule.source == "base\\u{202e}nosj.json")
		#expect(rule.badges.map(\.text) == ["Default: 30\\u{202e}00"])

		try #"{"vars":{"PORT":{"rnage":"1"}}}"#.write(toFile: folder + "/" + file, atomically: true, encoding: .utf8)
		guard case .unreadable(let problem) = ProjectEnvSchemaFile.load(inFolder: folder, vaultID: "project").schema else {
			Issue.record("Expected an unreadable schema")
			return
		}
		#expect(!problem.location.unicodeScalars.contains("\u{202E}"))
		#expect(problem.location == "base\\u{202e}nosj.json › vars.PORT.rnage")
	}
}
