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
		("10", LPMConfigJSON.number("10")), ("-3", .number("-3")), ("0", .number("0")), ("007", .string("007")), ("1.5", .string("1.5")), ("ten", .string("ten")),
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
		#expect(secret.availability(of: .defaultValue, publicPrefix: nil) == .init(isAvailable: false, hint: "not for secret keys"))
		#expect(secret.availability(of: .bounds, publicPrefix: nil) == .init(isAvailable: false, hint: "needs integer or port format"))
		#expect(secret.availability(of: .protocols, publicPrefix: nil).isAvailable)
		#expect(Rule().availability(of: .secret, publicPrefix: "VITE_") == .init(isAvailable: false, hint: "not for public keys"))
		#expect(Rule().availability(of: .client, publicPrefix: nil) == .init(isAvailable: false, hint: "needs a public prefix"))
	}

	@Test("conflicts the LPM CLI rejects block their row and offer fixes")
	func conflicts() throws {
		let conflicted = try rule(#"{"secret":true,"default":"x","enum":["a"],"ci":"variable","min":1,"protocols":["https"],"requiredWhen":{"variable":"TOKEN","equals":"on"}}"#)
		let found = conflicted.conflicts(key: "API_KEY", publicPrefix: nil, secretKeys: ["TOKEN"])
		#expect(found[.defaultValue] == .init(kind: .blocking, message: "Secret keys can't have a default.", fixes: [.turnOffSecret, .remove(.defaultValue)]))
		#expect(found[.allowedValues]?.fixes == [.turnOffSecret, .remove(.allowedValues)])
		#expect(found[.ci]?.fixes == [.setCIStorage(.secret)])
		#expect(found[.bounds]?.fixes == [.setFormat(.integer), .remove(.bounds)])
		#expect(found[.protocols]?.fixes == [.setFormat(.url), .remove(.protocols)])
		#expect(found[.requiredWhen]?.kind == .blocking)

		var fixed = conflicted
		fixed.apply(.turnOffSecret)
		#expect(fixed.conflicts(key: "API_KEY", publicPrefix: nil, secretKeys: [])[.defaultValue] == nil)
	}

	@Test("ranges, overlapping scoped defaults, and rules Required makes pointless are named", arguments: [
		(#"{"format":"integer","min":5,"max":1}"#, Rule.Field.bounds, "Min can't be more than max."),
		(#"{"format":"port","max":"1.5"}"#, .bounds, "Use a whole number."),
		(#"{"minLength":"-1"}"#, .length, "Use a whole number of characters."),
		(#"{"minLength":9,"maxLength":3}"#, .length, "The shortest length can't be more than the longest."),
		(#"{"format":"url","protocols":[]}"#, .protocols, "Add at least one URL scheme."),
		(#"{"enum":[]}"#, .allowedValues, "Add at least one allowed value."),
		(#"{"empty":"reject","default":""}"#, .defaultValue, "An empty default can't be used while empty values are rejected."),
		(#"{"defaultsIn":[{"when":{"environment":["a"]},"value":"1"},{"when":{"stage":["build"]},"value":"2"}]}"#, .defaultsIn, "Scoped defaults overlap, so more than one could apply. Narrow them."),
		(#"{"requiredWhen":{"variable":"KEY","present":true}}"#, .requiredWhen, "A key can't depend on itself."),
	])
	func namedConflicts(json: String, field: Rule.Field, message: String) throws {
		#expect(try rule(json).conflicts(key: "KEY", publicPrefix: nil, secretKeys: [])[field]?.message == message)
	}

	@Test("Required makes scoped and conditional requirements pointless, without blocking them")
	func requiredOverlap() throws {
		let found = try rule(#"{"required":true,"requiredIn":[{"environment":["production"]}]}"#).conflicts(key: "KEY", publicPrefix: nil, secretKeys: [])
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
