import Foundation
import Testing

@testable import LPMVault

@Suite("Schema rules")
struct ProjectEnvSchemaRuleTests {
	typealias Rule = ProjectEnvSchemaRule

	private func rule(_ text: String) throws -> Rule {
		Rule(try LPMConfigJSON(parsing: Data(text.utf8), rejectDuplicateKeys: true))
	}

	@Test("fields read and write in place, new ones go last, and fields the editor doesn't know stay")
	func editsInPlace() throws {
		var rule = try rule(#"{"format":"port","x-team":"api","default":"3000"}"#)
		rule.defaultValue = "8080"
		rule.required = true
		rule.format = .integer
		#expect(rule.json.rendered() == """
			{
			  "format": "integer",
			  "x-team": "api",
			  "default": "8080",
			  "required": true
			}
			""")
		rule.required = false
		rule.defaultValue = ""
		#expect(rule.json == (try LPMConfigJSON(parsing: Data(#"{"format":"integer","x-team":"api"}"#.utf8))), "A false flag and a cleared field leave the rule")
	}

	@Test("bounds are numbers when they're whole numbers and text otherwise, so the LPM CLI names the mistake", arguments: [
		("10", LPMConfigJSON.number("10")), ("-3", .number("-3")), ("0", .number("0")), ("-0", .string("-0")), ("007", .string("007")), ("1.5", .string("1.5")), ("ten", .string("ten")),
	])
	func bounds(text: String, written: LPMConfigJSON) {
		var rule = Rule()
		rule.max = text
		#expect(rule.json["max"] == written)
		#expect(rule.max == text)
	}

	@Test("scopes, scoped defaults, and conditions round-trip through lpm.json's shapes")
	func structuredFields() throws {
		var rule = Rule()
		rule.requiredIn = [.init(environments: ["production"], stages: [.runtime]), .init(services: ["api"])]
		rule.defaultsIn = [.init(scope: .init(environments: ["development"]), value: "http://localhost")]
		rule.requiredWhen = .init(variable: "AUTH_MODE", condition: .equals("password"))
		#expect(rule.json.rendered() == """
			{
			  "requiredIn": [
			    {
			      "environment": [
			        "production"
			      ],
			      "stage": [
			        "runtime"
			      ]
			    },
			    {
			      "service": [
			        "api"
			      ]
			    }
			  ],
			  "defaultsIn": [
			    {
			      "when": {
			        "environment": [
			          "development"
			        ]
			      },
			      "value": "http://localhost"
			    }
			  ],
			  "requiredWhen": {
			    "variable": "AUTH_MODE",
			    "equals": "password"
			  }
			}
			""")
		#expect(rule.requiredIn.first?.summary == "production · runtime")
		rule.requiredWhen = .init(variable: "TOKEN", condition: .present(false))
		#expect(rule.json["requiredWhen"] == (try LPMConfigJSON(parsing: Data(#"{"variable":"TOKEN","present":false}"#.utf8))))
		rule.requiredIn = []
		#expect(rule.json["requiredIn"] == nil)
	}

	@Test("a resolved rule drops the fields the engine fills in with defaults")
	func resolvedRule() throws {
		let resolved = try LPMConfigJSON(parsing: Data(#"{"required":true,"format":"url","pattern":null,"enum":null,"default":null,"secret":false,"client":false,"empty":"missing","requiredIn":[],"min":"1","description":null}"#.utf8))
		#expect(Rule(resolved: resolved).json == (try LPMConfigJSON(parsing: Data(#"{"required":true,"format":"url","min":1}"#.utf8))))
	}

	@Test("public prefixes follow the LPM CLI: frameworks, React's in any case, then the project's")
	func publicPrefixes() {
		#expect(Rule.publicPrefix(of: "NEXT_PUBLIC_API_URL", clientPrefixes: []) == "NEXT_PUBLIC_")
		#expect(Rule.publicPrefix(of: "react_app_token", clientPrefixes: []) == "REACT_APP_")
		#expect(Rule.publicPrefix(of: "ACME_PUBLIC_CDN", clientPrefixes: ["ACME_PUBLIC_"]) == "ACME_PUBLIC_")
		#expect(Rule.publicPrefix(of: "API_TOKEN", clientPrefixes: ["ACME_"]) == nil)
	}

	@Test("the add menu says why a rule can't be added")
	func availability() throws {
		let secret = try rule(#"{"secret":true,"format":"url"}"#)
		let key = Rule.Context(key: "KEY")
		#expect(secret.availability(of: .defaultValue, in: key) == .init(isAvailable: false, hint: "not for secret keys"))
		#expect(secret.availability(of: .bounds, in: key) == .init(isAvailable: false, hint: "needs integer or port format"))
		#expect(secret.availability(of: .protocols, in: key).isAvailable)
		#expect(Rule().availability(of: .secret, in: .init(key: "VITE_KEY", publicPrefix: "VITE_")) == .init(isAvailable: false, hint: "not for public keys"))
		#expect(Rule().availability(of: .secret, in: .init(key: "MODE", comparedBy: ["X"])) == .init(isAvailable: false, hint: "X compares its value"))
		#expect(Rule().availability(of: .client, in: key) == .init(isAvailable: false, hint: "needs a public prefix"))
		#expect(Rule().availability(of: .requiredWhen, in: .init(key: "KEY", declaredKeys: ["KEY"])) == .init(isAvailable: false, hint: "no other keys"))
	}

	@Test("conflicts the LPM CLI rejects block their row and offer fixes")
	func conflicts() throws {
		let conflicted = try rule(#"{"secret":true,"default":"x","enum":["a"],"ci":"variable","min":1,"protocols":["https"],"requiredWhen":{"variable":"TOKEN","equals":"on"}}"#)
		let found = conflicted.conflicts(in: .init(key: "API_KEY", secretKeys: ["TOKEN"]))
		#expect(found[.defaultValue] == .init(kind: .blocking, message: "Secret keys can't have a default.", fixes: [.turnOffSecret, .remove(.defaultValue)]))
		#expect(found[.allowedValues]?.fixes == [.turnOffSecret, .remove(.allowedValues)])
		#expect(found[.ci]?.fixes == [.setCIStorage(.secret)])
		#expect(found[.bounds]?.fixes == [.setFormat(.integer), .remove(.bounds)])
		#expect(found[.protocols]?.fixes == [.setFormat(.url), .remove(.protocols)])
		#expect(found[.requiredWhen] == .init(kind: .blocking, message: "TOKEN is secret, so its value can't be compared.", fixes: [.usePresence, .remove(.requiredWhen)]))

		var fixed = conflicted
		fixed.apply(.turnOffSecret)
		#expect(fixed.conflicts(in: .init(key: "API_KEY"))[.defaultValue] == nil)
		fixed.apply(.usePresence)
		#expect(fixed.requiredWhen == .init(variable: "TOKEN", condition: .present(true)))
	}

	@Test("a key can't be secret while another key compares its value")
	func secretComparedByAnotherKey() throws {
		let found = try rule(#"{"secret":true}"#).conflicts(in: .init(key: "MODE", comparedBy: ["X"]))
		#expect(found[.secret] == .init(kind: .blocking, message: "X compares this key's value in Required when, so it can't be secret.", fixes: [.turnOffSecret]))
	}

	@Test("ranges, overlapping scoped defaults, and rules Required makes pointless are named", arguments: [
		(#"{"format":"integer","min":5,"max":1}"#, Rule.Field.bounds, "Min can't be more than max."),
		(#"{"format":"port","max":"1.5"}"#, .bounds, "Use a whole number."),
		(#"{"minLength":"-1"}"#, .length, "Use a whole number of characters."),
		(#"{"minLength":9,"maxLength":3}"#, .length, "The shortest length can't be more than the longest."),
		(#"{"format":"url","protocols":[]}"#, .protocols, "Add at least one URL scheme."),
		(#"{"enum":[]}"#, .allowedValues, "Add at least one allowed value."),
		(#"{"empty":"reject","default":""}"#, .defaultValue, "An empty default can't be used while empty values are rejected."),
		(#"{"empty":"reject","defaultsIn":[{"when":{"stage":["build"]},"value":""}]}"#, .defaultsIn, "An empty scoped default can't be used while empty values are rejected."),
		(#"{"required":true,"default":""}"#, .defaultValue, "An empty default can't satisfy Required."),
		(#"{"format":"port","max":"99999999999999999999"}"#, .bounds, "Use a whole number from -9223372036854775808 to 9223372036854775807."),
		(#"{"format":"port","min":70000}"#, .bounds, "These bounds leave no valid port, which runs from 1 to 65535."),
		(#"{"maxLength":"+5"}"#, .length, "Use a whole number of characters."),
		(#"{"format":"url","protocols":["https:"]}"#, .protocols, "“https:” isn't a URL scheme. Use lowercase letters, digits, “+”, “.” and “-”, starting with a letter, without a colon."),
		(#"{"format":"url","protocols":["https","https"]}"#, .protocols, "A URL scheme is listed twice."),
		(#"{"requiredIn":[{"service":["api gateway"]}]}"#, .requiredIn, "“api gateway” isn't a valid name. Use letters, digits, “.”, “_” and “-”, up to 64 characters."),
		(#"{"requiredIn":[{"environment":["a","b"]},{"environment":["b","a"],"stage":["development","build","runtime","ci","test"]}]}"#, .requiredIn, "Two scopes are the same."),
		(#"{"requiredWhen":{"variable":"GONE","present":true}}"#, .requiredWhen, "GONE isn't declared."),
		(#"{"defaultsIn":[{"when":{"environment":["a"]},"value":"1"},{"when":{"stage":["build"]},"value":"2"}]}"#, .defaultsIn, "Scoped defaults overlap, so more than one could apply. Narrow them."),
		(#"{"requiredWhen":{"variable":"KEY","present":true}}"#, .requiredWhen, "No effect: it depends on the key itself."),
	])
	func namedConflicts(json: String, field: Rule.Field, message: String) throws {
		#expect(try rule(json).conflicts(in: .init(key: "KEY", declaredKeys: ["KEY", "OTHER"]))[field]?.message == message)
	}

	@Test("a row blocks exactly the rules the LPM CLI rejects", arguments: [
		#"{"format":"integer","min":"007","max":"+5"}"#,
		#"{"format":"integer","min":"-0"}"#,
		#"{"format":"integer","min":-0}"#,
		#"{"format":"integer","min":"99999999999999999999"}"#,
		#"{"format":"integer","min":9223372036854775808}"#,
		#"{"format":"integer","min":1.5}"#,
		#"{"format":"port","max":0}"#,
		#"{"min":null}"#,
		#"{"minLength":"007","maxLength":"+5"}"#,
		#"{"maxLength":4294967296}"#,
		#"{"secret":true,"default":null,"enum":null}"#,
		#"{"requiredWhen":{"variable":"KEY","present":true}}"#,
		#"{"requiredWhen":{"variable":"OTHER","equals":"on"}}"#,
		#"{"format":"url","protocols":["https:"]}"#,
		#"{"format":"url","protocols":["git+ssh","s3"]}"#,
		#"{"requiredIn":[{"service":["api..v2"]}]}"#,
		#"{"requiredIn":[{"environment":["__index__"]}]}"#,
		#"{"requiredIn":[{"environment":["a"]},{"environment":["a"],"stage":["development","build","runtime","ci","test"]}]}"#,
		#"{"empty":"reject","defaultsIn":[{"when":{"stage":["build"]},"value":""}]}"#,
		#"{"required":true,"defaultsIn":[{"when":{"stage":["build"]},"value":""}]}"#,
	])
	func matchesEngine(json: String) throws {
		let folder = FileManager.default.temporaryDirectory.appending(path: "rule-parity-\(UUID().uuidString)").path
		try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(atPath: folder) }
		let schema = try LPMConfigJSON(parsing: Data(#"{"vars":{"KEY":\#(json),"OTHER":{}}}"#.utf8))
		let rejected = if case .failure = try RustSchemaEngine.resolveOrDiagnose(schema, inFolder: folder) { true } else { false }
		let blocking = try rule(json).conflicts(in: .init(key: "KEY", declaredKeys: ["KEY", "OTHER"])).values.contains { $0.kind == .blocking }
		#expect(blocking == rejected, "The panel and the LPM CLI disagree about \(json)")
	}

	@Test("entries nobody changed keep their form when a list is rewritten")
	func untouchedEntriesKeepTheirForm() throws {
		var rule = try rule(#"{"requiredIn":[{"stage":["test","build"],"environment":["production"]},{"service":["api"]}]}"#)
		rule.requiredIn = rule.requiredIn + [.init(environments: ["staging"])]
		guard case .array(let entries)? = rule.json["requiredIn"] else { Issue.record("requiredIn isn't a list"); return }
		#expect(entries.count == 3)
		#expect(entries.first == (try LPMConfigJSON(parsing: Data(#"{"stage":["test","build"],"environment":["production"]}"#.utf8))))
		#expect(entries.last == (try LPMConfigJSON(parsing: Data(#"{"environment":["staging"]}"#.utf8))))
	}

	@Test("Required makes scoped and conditional requirements pointless, without blocking them")
	func requiredOverlap() throws {
		let found = try rule(#"{"required":true,"requiredIn":[{"environment":["production"]}]}"#).conflicts(in: .init(key: "KEY"))
		#expect(found[.requiredIn] == .init(kind: .noEffect, message: "No effect while Required is on.", fixes: [.remove(.requiredIn)]))
	}

	@Test("scopes overlap only when every dimension both name can match")
	func scopeOverlap() {
		typealias Scope = Rule.Scope
		#expect(Scope(environments: ["production"]).overlaps(Scope(stages: [.build])))
		#expect(!Scope(environments: ["production"]).overlaps(Scope(environments: ["staging"])))
		#expect(!Scope(environments: ["production"], stages: [.build]).overlaps(Scope(environments: ["production"], stages: [.runtime])))
	}
}
