import Foundation
import Testing

@testable import LPMVault

@Suite("Schema drafts")
struct ProjectEnvSchemaDraftTests {
	typealias Draft = ProjectEnvSchemaDraft
	typealias Problem = ProjectEnvValueCheck.Problem

	private func json(_ text: String) throws -> LPMConfigJSON {
		try LPMConfigJSON(parsing: Data(text.utf8), rejectDuplicateKeys: true)
	}

	private func schema(_ text: String) throws -> LPMConfigJSON? {
		try json(text)
	}

	// MARK: - Changes

	@Test("changes keep the order they were made, and a value lpm.json already has drops its change")
	func changesAndNoOps() throws {
		var draft = Draft(schema: try schema(#"{"vars":{"PORT":{"format":"port","default":"3000"}}}"#))
		draft.set(.declared(try json(#"{"format":"url"}"#)), for: .key("API_URL"))
		draft.set(.declared(try json(#"{"format":"port","default":"8080"}"#)), for: .key("PORT"))
		#expect(draft.changedItems == [.key("API_URL"), .key("PORT")])

		draft.set(.declared(try json(#"{"default":"3000","format":"port"}"#)), for: .key("PORT"))
		#expect(draft.changedItems == [.key("API_URL")], "The same rule with its fields in another order is no change")
		#expect(draft.declaration(of: .key("PORT")) == .declared(try json(#"{"format":"port","default":"3000"}"#)), "lpm.json's member order stays")

		draft.discard(.key("API_URL"))
		#expect(draft.isEmpty)
		#expect(draft.declaration(of: .key("API_URL")) == .absent)
	}

	// MARK: - Applying

	@Test("members keep their place, new ones go last, and a moved key leaves its old container")
	func appliesInPlace() throws {
		let base = try schema(#"{"extends":["schemas/base.json"],"vars":{"A":{"format":"url"},"B":{"secret":true},"C":{}},"overrides":{"D":{"required":true}}}"#)
		var draft = Draft(schema: base)
		draft.set(.declared(try json(#"{"format":"url","required":true}"#)), for: .key("A"))
		draft.set(.declared(try json(#"{"format":"port"}"#)), for: .key("E"))
		draft.set(.overridden(try json(#"{"secret":true,"required":true}"#)), for: .key("C"))
		draft.set(.absent, for: .key("D"))
		let applied = try #require(try draft.applied(to: base))
		#expect(applied.rendered() == """
			{
			  "extends": [
			    "schemas/base.json"
			  ],
			  "vars": {
			    "A": {
			      "format": "url",
			      "required": true
			    },
			    "B": {
			      "secret": true
			    },
			    "E": {
			      "format": "port"
			    }
			  },
			  "overrides": {
			    "C": {
			      "secret": true,
			      "required": true
			    }
			  }
			}
			""")
	}

	@Test("a container the draft empties goes away; one that was empty stays")
	func emptiedContainers() throws {
		let base = try schema(#"{"vars":{"A":{}},"groups":{}}"#)
		var draft = Draft(schema: base)
		draft.set(.absent, for: .key("A"))
		#expect(try draft.applied(to: base) == (try json(#"{"groups":{}}"#)))

		let only = try schema(#"{"vars":{"A":{}}}"#)
		var removing = Draft(schema: only)
		removing.set(.absent, for: .key("A"))
		#expect(try removing.applied(to: only) == nil, "An envSchema left without rules goes away")
		#expect(try Draft(schema: nil).applied(to: nil) == nil, "No envSchema is added without rules")
	}

	@Test("groups, group overrides, and client prefixes apply to their own containers")
	func groupsAndPrefixes() throws {
		let base = try schema(#"{"vars":{"A":{},"B":{}},"groups":{"auth":{"mode":"exactlyOne","vars":["A","B"]}},"clientPrefixes":["ACME_"]}"#)
		var draft = Draft(schema: base)
		draft.set(.declared(try json(#"{"mode":"atLeastOne","vars":["A","B"]}"#)), for: .group("auth"))
		draft.set(.overridden(try json(#"{"mode":"allOrNone","vars":["A"]}"#)), for: .group("shared"))
		draft.set(.absent, for: .clientPrefixes)
		let applied = try #require(try draft.applied(to: base))
		#expect(applied["groups"]?["auth"]?["mode"] == .string("atLeastOne"))
		#expect(applied["groupOverrides"]?["shared"]?["mode"] == .string("allOrNone"))
		#expect(applied["clientPrefixes"] == nil)
	}

	@Test("a container that isn't an object fails instead of being replaced")
	func rejectsMalformedContainers() throws {
		let base = try schema(#"{"vars":[]}"#)
		var draft = Draft(schema: base)
		draft.set(.declared(.object([])), for: .key("A"))
		#expect(throws: ProjectEnvSchemaFile.FileError.invalidSchema) { try draft.applied(to: base) }
	}

	// MARK: - Merging

	@Test("an item changed only on disk merges, and the draft keeps its own changes")
	func mergesUnrelatedChanges() throws {
		var draft = Draft(schema: try schema(#"{"vars":{"PORT":{"format":"port"},"RETRY":{"format":"integer"}}}"#))
		draft.set(.declared(try json(#"{"format":"port","default":"8080"}"#)), for: .key("PORT"))
		let theirs = try schema(#"{"vars":{"PORT":{"format":"port"},"RETRY":{"format":"integer","max":"5"}},"groups":{"g":{"mode":"atLeastOne","vars":["PORT"]}}}"#)
		let outcome = draft.rebase(onto: theirs)
		#expect(outcome.changedItems == [.key("RETRY"), .group("g")])
		#expect(outcome.conflicts.isEmpty)
		#expect(draft.schema == theirs)
		let applied = try #require(try draft.applied(to: theirs))
		#expect(applied["vars"]?["PORT"]?["default"] == .string("8080"))
		#expect(applied["vars"]?["RETRY"]?["max"] == .string("5"))
	}

	@Test("the same item changed both ways conflicts until a version is chosen")
	func conflicts() throws {
		let base = try schema(#"{"vars":{"PORT":{"format":"port","default":"3000"}}}"#)
		var draft = Draft(schema: base)
		let mine = Draft.Declaration.declared(try json(#"{"format":"port","default":"8080"}"#))
		draft.set(mine, for: .key("PORT"))

		let theirs = try schema(#"{"vars":{"PORT":{"format":"port","default":"4000"}}}"#)
		#expect(draft.rebase(onto: theirs).conflicts == [.key("PORT")])
		#expect(draft.changes.isEmpty)
		#expect(draft.declaration(of: .key("PORT")) == mine, "The draft shows its own version while it conflicts")

		let later = try schema(#"{"vars":{"PORT":{"format":"port","default":"5000"}}}"#)
		draft.rebase(onto: later)
		#expect(draft.conflicts.first?.theirs == .declared(try json(#"{"format":"port","default":"5000"}"#)), "A conflict follows the file's latest version")

		var keeping = draft
		keeping.resolveConflict(.key("PORT"), keepingMine: true)
		#expect(keeping.conflicts.isEmpty)
		#expect(try keeping.applied(to: later)?["vars"]?["PORT"]?["default"] == .string("8080"))

		draft.resolveConflict(.key("PORT"), keepingMine: false)
		#expect(draft.isEmpty)
	}

	@Test("a change lpm.json already made, or a reordering, isn't a conflict")
	func equivalentChangesMerge() throws {
		var draft = Draft(schema: try schema(#"{"vars":{"PORT":{"format":"port","default":"3000"}}}"#))
		draft.set(.declared(try json(#"{"format":"port","default":"8080"}"#)), for: .key("PORT"))
		draft.set(.declared(try json(#"{"format":"url"}"#)), for: .key("API_URL"))
		let theirs = try schema(#"{"vars":{"PORT":{"default":"8080","format":"port"}}}"#)
		let outcome = draft.rebase(onto: theirs)
		#expect(outcome.conflicts.isEmpty)
		#expect(draft.changedItems == [.key("API_URL")])

		var reordered = Draft(schema: try schema(#"{"vars":{"A":{"format":"url","required":true}}}"#))
		reordered.set(.declared(try json(#"{"format":"port"}"#)), for: .key("A"))
		#expect(reordered.rebase(onto: try schema(#"{"vars":{"A":{"required":true,"format":"url"}}}"#)).conflicts.isEmpty)
		#expect(reordered.changedItems == [.key("A")])
	}

	@Test("a changed import list is noted as a change outside the items")
	func notesOtherFields() throws {
		var draft = Draft(schema: try schema(#"{"extends":["a.json"],"vars":{"A":{}}}"#))
		draft.set(.declared(try json(#"{"required":true}"#)), for: .key("A"))
		let outcome = draft.rebase(onto: try schema(#"{"extends":["b.json"],"vars":{"A":{}}}"#))
		#expect(outcome.changedOtherFields)
		#expect(outcome.changedItems.isEmpty)
		#expect(!outcome.isEmpty)
	}

	// MARK: - Diff

	@Test("a changed rule shows as lpm.json lines, the way the LPM CLI writes them")
	func diffOfChangedRule() throws {
		var draft = Draft(schema: try schema(#"{"vars":{"RETRY_COUNT":{"format":"integer","min":0,"max":10,"default":"3"}}}"#))
		draft.set(.declared(try json(#"{"format":"integer","min":0,"max":5,"default":"3"}"#)), for: .key("RETRY_COUNT"))
		let diff = try #require(draft.diff(for: .key("RETRY_COUNT")))
		#expect(diff.path == "envSchema.vars.RETRY_COUNT")
		#expect(diff.lines == [
			.init(kind: .unchanged, text: #""RETRY_COUNT": {"#),
			.init(kind: .unchanged, text: #"  "format": "integer","#),
			.init(kind: .unchanged, text: #"  "min": 0,"#),
			.init(kind: .removed, text: #"  "max": 10,"#),
			.init(kind: .added, text: #"  "max": 5,"#),
			.init(kind: .unchanged, text: #"  "default": "3""#),
			.init(kind: .unchanged, text: "}"),
		])
		#expect(draft.diff(for: .key("OTHER")) == nil)
	}

	@Test("an added, removed, or moved item shows whole", arguments: [
		(#"{"vars":{}}"#, Draft.Declaration.declared(.object([.init(key: "secret", value: .bool(true))])), "envSchema.vars.TOKEN", ["+", "+", "+"]),
		(#"{"vars":{"TOKEN":{"secret":true}}}"#, Draft.Declaration.absent, "envSchema.vars.TOKEN", ["-", "-", "-"]),
		(#"{"vars":{"TOKEN":{"secret":true}}}"#, Draft.Declaration.overridden(.object([.init(key: "secret", value: .bool(true))])), "envSchema.overrides.TOKEN", ["-", "-", "-", "+", "+", "+"]),
	])
	func diffOfWholeItems(base: String, value: Draft.Declaration, path: String, kinds: [String]) throws {
		var draft = Draft(schema: try schema(base))
		draft.set(value, for: .key("TOKEN"))
		let diff = try #require(draft.diff(for: .key("TOKEN")))
		#expect(diff.path == path)
		#expect(diff.lines.map { $0.kind == .added ? "+" : $0.kind == .removed ? "-" : " " } == kinds)
	}

	@Test("client prefixes show as one list")
	func diffOfPrefixes() throws {
		var draft = Draft(schema: try schema(#"{"clientPrefixes":["ACME_PUBLIC_"]}"#))
		draft.set(.declared(try json(#"["ACME_PUBLIC_","WIDGET_"]"#)), for: .clientPrefixes)
		let diff = try #require(draft.diff(for: .clientPrefixes))
		#expect(diff.path == "envSchema.clientPrefixes")
		#expect(diff.lines.filter { $0.kind != .unchanged } == [
			.init(kind: .removed, text: #"  "ACME_PUBLIC_""#),
			.init(kind: .added, text: #"  "ACME_PUBLIC_","#),
			.init(kind: .added, text: #"  "WIDGET_""#),
		])
	}

	@Test("a diff too large to align shows the middle removed, then added")
	func boundedLineDiff() {
		let old = ["{", "a", "b", "c", "}"]
		let new = ["{", "x", "b", "y", "}"]
		#expect(Draft.lineDiff(from: old, to: new).map(\.text) == ["{", "a", "x", "b", "c", "y", "}"])
		#expect(Draft.lineDiff(from: old, to: new, maximumComparisons: 4).map(\.kind) == [.unchanged, .removed, .removed, .removed, .added, .added, .added, .unchanged])
	}

	// MARK: - Rejections

	@Test("an engine diagnostic in lpm.json names its item and field", arguments: [
		("/envSchema/vars/PORT/pattern", Draft.Item?.some(.key("PORT")), String?.some("pattern")),
		("/envSchema/overrides/DATABASE_URL", .some(.key("DATABASE_URL")), nil),
		("/envSchema/groups/auth/vars", .some(.group("auth")), "vars"),
		("/envSchema/groupOverrides/a~1b", .some(.group("a/b")), nil),
		("/envSchema/clientPrefixes/0", .some(.clientPrefixes), nil),
		("/envSchema/extends/0", nil, nil),
	])
	func rejectionLocation(pointer: String, item: Draft.Item?, field: String?) {
		let rejection = Draft.Rejection(.init(code: "env.invalid_rule", source: "lpm.json", pointer: pointer, message: "invalid"))
		#expect(rejection.item == item)
		#expect(rejection.field == field)
		#expect(rejection.reason == "Invalid")
	}

	@Test("a diagnostic in an imported schema names no item of lpm.json")
	func importedRejection() {
		let rejection = Draft.Rejection(.init(code: "env.invalid_rule", source: "schemas/base.json", pointer: "/vars/PORT", message: nil))
		#expect(rejection.item == nil)
		#expect(rejection.location == "schemas/base.json › vars.PORT")
		#expect(rejection.reason == "This rule is invalid.")
	}

	// MARK: - Effects

	@Test("effects name what the draft breaks and fixes, by the item that causes it")
	func effectsByItem() throws {
		var draft = Draft(schema: nil)
		draft.set(.declared(.object([])), for: .key("RETRY_COUNT"))
		draft.set(.declared(.object([])), for: .key("PASSWORD"))
		draft.set(.declared(.object([])), for: .group("auth"))
		let before = ProjectEnvValueCheck(environments: [
			"production": .init(problems: ["PASSWORD": [Problem(key: "PASSWORD", kind: .required)], "PORT": [Problem(key: "PORT", kind: .format("port"))]]),
			"development": .init(problems: [
				"PASSWORD": [Problem(key: "PASSWORD", kind: .group(name: "auth", mode: "exactlyOne"))],
				"OAUTH_TOKEN": [Problem(key: "OAUTH_TOKEN", kind: .group(name: "auth", mode: "exactlyOne"))],
			]),
			"staging": .init(problems: [
				"PASSWORD": [Problem(key: "PASSWORD", kind: .group(name: "auth", mode: "exactlyOne"))],
				"OAUTH_TOKEN": [Problem(key: "OAUTH_TOKEN", kind: .group(name: "auth", mode: "exactlyOne"))],
			]),
		])
		let after = ProjectEnvValueCheck(environments: [
			"production": .init(problems: [
				"PORT": [Problem(key: "PORT", kind: .format("port"))],
				"RETRY_COUNT": [Problem(key: "RETRY_COUNT", kind: .constraint("max"))],
				"API_TOKEN": [Problem(key: "API_TOKEN", kind: .required)],
			]),
			"development": .init(),
			"staging": .init(problems: [
				"PASSWORD": [Problem(key: "PASSWORD", kind: .group(name: "auth", mode: "atLeastOne"))],
				"OAUTH_TOKEN": [Problem(key: "OAUTH_TOKEN", kind: .group(name: "auth", mode: "atLeastOne"))],
			]),
		])
		let effects = ProjectEnvSchemaDraftEffects(before: before, after: after, draft: draft, environmentOrder: ["development", "staging", "production"])
		#expect(effects.summary(for: .key("RETRY_COUNT")).effects == [.init(environment: "production", kind: .newlyFailing, problem: Problem(key: "RETRY_COUNT", kind: .constraint("max")))])
		#expect(effects.summary(for: .key("PASSWORD")).effects == [.init(environment: "production", kind: .nowPasses, problem: Problem(key: "PASSWORD", kind: .required))])
		let group = effects.summary(for: .group("auth"))
		#expect(group.effects == [.init(environment: "development", kind: .nowPasses, problem: Problem(key: "OAUTH_TOKEN", kind: .group(name: "auth", mode: "exactlyOne")))],
			"A group fails once per environment, not once per member")
		#expect(group.unchanged == 1, "Staging fails the group under either mode")
		#expect(effects.others.effects == [.init(environment: "production", kind: .newlyFailing, problem: Problem(key: "API_TOKEN", kind: .required))])
		#expect(effects.others.unchanged == 1, "PORT's problem is unrelated to the draft")
	}

	@Test("a group's effect goes to the changed key whichever member the engine reports it on first")
	func groupEffectThroughAnyMember() {
		var draft = Draft(schema: nil)
		draft.set(.declared(.object([])), for: .key("B"))
		let failing = ProjectEnvValueCheck(environments: ["e": .init(problems: [
			"A": [Problem(key: "A", kind: .group(name: "g", mode: "exactlyOne"))],
			"B": [Problem(key: "B", kind: .group(name: "g", mode: "exactlyOne"))],
		])])
		let passing = ProjectEnvValueCheck(environments: ["e": .init()])
		let breaking = ProjectEnvSchemaDraftEffects(before: passing, after: failing, draft: draft)
		#expect(breaking.summary(for: .key("B")).effects == [.init(environment: "e", kind: .newlyFailing, problem: Problem(key: "B", kind: .group(name: "g", mode: "exactlyOne")))])
		#expect(breaking.others.isEmpty)
		let fixing = ProjectEnvSchemaDraftEffects(before: failing, after: passing, draft: draft)
		#expect(fixing.summary(for: .key("B")).effects.map(\.kind) == [.nowPasses])
	}

	@Test("effects come in one order: environment, then failures, then key, then problem")
	func deterministicEffects() {
		let problems: [Problem] = [
			Problem(key: "A", kind: .notAllowed), Problem(key: "A", kind: .pattern), Problem(key: "A", kind: .empty),
			Problem(key: "A", kind: .format("url")), Problem(key: "A", kind: .group(name: "g", mode: "allOrNone")),
		]
		let before = ProjectEnvValueCheck(environments: ["e": .init()])
		let after = ProjectEnvValueCheck(environments: ["e": .init(problems: ["A": problems])])
		var orders = Set<[ProjectEnvValueCheck.Problem.Kind]>()
		for _ in 0..<50 {
			orders.insert(ProjectEnvSchemaDraftEffects(before: before, after: after, draft: Draft(schema: nil)).others.effects.map(\.problem.kind))
		}
		#expect(orders == [[.empty, .format("url"), .group(name: "g", mode: "allOrNone"), .notAllowed, .pattern]])
	}

	@Test("a key the draft removes from lpm.json is no longer checked, rather than passing")
	func removedKeyEffects() throws {
		var draft = Draft(schema: try schema(#"{"vars":{"PASSWORD":{"minLength":12}}}"#))
		draft.set(.absent, for: .key("PASSWORD"))
		let before = ProjectEnvValueCheck(environments: ["e": .init(problems: ["PASSWORD": [Problem(key: "PASSWORD", kind: .constraint("minLength"))]])])
		let effects = ProjectEnvSchemaDraftEffects(before: before, after: ProjectEnvValueCheck(environments: ["e": .init()]), draft: draft)
		#expect(effects.summary(for: .key("PASSWORD")).effects.map(\.kind) == [.noLongerChecked])
	}

	@Test("setting a conflicting item to the version lpm.json now has settles the conflict")
	func settlingConflictsByValue() throws {
		var draft = Draft(schema: try schema(#"{"vars":{"PORT":{"format":"port","default":"3000"}}}"#))
		draft.set(.declared(try json(#"{"format":"port","default":"8080"}"#)), for: .key("PORT"))
		let theirs = try schema(#"{"vars":{"PORT":{"format":"port","default":"4000"}}}"#)
		draft.rebase(onto: theirs)
		draft.set(.declared(try json(#"{"default":"4000","format":"port"}"#)), for: .key("PORT"))
		#expect(draft.isEmpty)

		var keeping = Draft(schema: try schema(#"{"vars":{"PORT":{"format":"port","default":"3000"}}}"#))
		keeping.set(.declared(try json(#"{"format":"port","default":"8080"}"#)), for: .key("PORT"))
		keeping.rebase(onto: theirs)
		keeping.set(.declared(try json(#"{"default":"4000","format":"port","required":true}"#)), for: .key("PORT"))
		keeping.set(.declared(try json(#"{"default":"4000","format":"port"}"#)), for: .key("PORT"))
		#expect(keeping.isEmpty, "Keeping a version equivalent to the file's changes nothing")
		#expect(try keeping.applied(to: theirs) == theirs)
	}

	@Test("keeping my version of a conflict equivalent to the file's leaves no change")
	func keepingAnEquivalentVersion() throws {
		var draft = Draft(schema: try schema(#"{"vars":{"PORT":{"format":"port"}}}"#))
		draft.set(.declared(try json(#"{"format":"port","default":"8080"}"#)), for: .key("PORT"))
		draft.rebase(onto: try schema(#"{"vars":{"PORT":{"format":"port","default":"4000"}}}"#))
		draft.set(.declared(try json(#"{"default":"4000","format":"port","x":1}"#)), for: .key("PORT"))
		let reordered = try schema(#"{"vars":{"PORT":{"x":1,"format":"port","default":"4000"}}}"#)
		draft.rebase(onto: reordered)
		#expect(draft.isEmpty, "A file that now has my version settles the conflict")
	}

	@Test("diff lines show text that could hide or reorder its surroundings as escapes")
	func diffEscapesDirectionControls() throws {
		var draft = Draft(schema: try schema(#"{"vars":{"A":{}}}"#))
		draft.set(.declared(.object([.init(key: "description", value: .string("safe \u{202E}evil\u{2028}line"))])), for: .key("A"))
		let added = try #require(draft.diff(for: .key("A"))?.lines.first { $0.kind == .added && $0.text.contains("description") })
		#expect(added.text == #"  "description": "safe \u{202e}evil\u{2028}line""#)
		#expect(!added.text.unicodeScalars.contains("\u{202E}"))
	}

	@Test("diff lines compare by bytes, so a change between Unicode spellings shows")
	func diffComparesBytes() throws {
		var draft = Draft(schema: try schema(#"{"vars":{"A":{"default":"café"}}}"#))
		draft.set(.declared(.object([.init(key: "default", value: .string("cafe\u{301}"))])), for: .key("A"))
		#expect(draft.diff(for: .key("A"))?.lines.map(\.kind).contains(.removed) == true)
	}

	@Test("a small change to a huge item shows only the changed lines with a little context")
	func boundedDiffOfLargeItem() throws {
		let values = (0..<150_000).map { LPMConfigJSON.string("v\($0)") }
		var draft = Draft(schema: .object([.init(key: "vars", value: .object([.init(key: "MODE", value: .object([.init(key: "enum", value: .array(values))]))]))]))
		draft.set(.declared(.object([.init(key: "enum", value: .array(Array(values.dropFirst().dropLast())))])), for: .key("MODE"))
		let diff = try #require(draft.diff(for: .key("MODE")))
		#expect(diff.lines.filter { $0.kind == .removed || $0.kind == .added }.count == 4)
		#expect(diff.lines.count < 30)
		#expect(diff.lines.contains { $0.kind == .omitted })
	}

	@Test("an empty draft follows the file without comparing items")
	func emptyDraftRebase() throws {
		var draft = Draft(schema: try schema(#"{"vars":{"A":{}}}"#))
		let outcome = draft.rebase(onto: try schema(#"{"vars":{"B":{}}}"#))
		#expect(outcome == Draft.Rebase())
		#expect(draft.schema == (try schema(#"{"vars":{"B":{}}}"#)))
	}

	@Test("a moved item's diff names where it was and where it goes")
	func movedItemPaths() throws {
		var draft = Draft(schema: try schema(#"{"vars":{"TOKEN":{"secret":true}}}"#))
		draft.set(.overridden(try json(#"{"secret":true}"#)), for: .key("TOKEN"))
		let diff = try #require(draft.diff(for: .key("TOKEN")))
		#expect(diff.previousPath == "envSchema.vars.TOKEN")
		#expect(diff.path == "envSchema.overrides.TOKEN")
		var edited = Draft(schema: try schema(#"{"vars":{"TOKEN":{"secret":true}}}"#))
		edited.set(.declared(try json(#"{"secret":true,"required":true}"#)), for: .key("TOKEN"))
		#expect(edited.diff(for: .key("TOKEN"))?.previousPath == nil)
	}

	@Test("the app's own description save joins the draft's version of that key instead of conflicting")
	func adoptsOwnDescription() throws {
		var draft = Draft(schema: try schema(#"{"vars":{"PORT":{"format":"port"},"TOKEN":{"secret":true}}}"#))
		draft.set(.declared(try json(#"{"format":"port","default":"8080"}"#)), for: .key("PORT"))
		let written = try schema(#"{"vars":{"PORT":{"format":"port","description":"HTTP port"},"TOKEN":{"secret":true}}}"#)
		let outcome = draft.rebase(ontoOwnWrite: written, description: (key: "PORT", text: "HTTP port"))
		#expect(outcome.conflicts.isEmpty)
		#expect(draft.schema == written)
		#expect(draft.declaration(of: .key("PORT")) == .declared(try json(#"{"format":"port","default":"8080","description":"HTTP port"}"#)))
	}

	@Test("engine rejections without a usable pointer still name the draft's item", arguments: [
		(#"{"envSchema":{}}"#, Draft.Item.clientPrefixes, Draft.Declaration.declared(.array([.string("APP")]))),
		(#"{"envSchema":{}}"#, .key("my-key"), .declared(.object([]))),
	])
	func rejectionsWithoutPointers(lpmJSON: String, item: Draft.Item, value: Draft.Declaration) throws {
		let folder = try makeFolder(lpmJSON)
		defer { try? FileManager.default.removeItem(atPath: folder) }
		var draft = Draft(schema: ProjectEnvSchemaFile.load(inFolder: folder, vaultID: "project").rootSchema)
		draft.set(value, for: item)
		let rejection = try #require(ProjectEnvSchemaFile.evaluate(draft, inFolder: folder, environments: [:]).rejection)
		#expect(rejection.item == item)
	}

	// MARK: - Files

	@Test("evaluating a draft resolves it with imported schemas and checks the stored values")
	func evaluates() throws {
		let folder = try makeFolder(#"{"envSchema":{"extends":["schemas/base.json"]}}"#, files: ["schemas/base.json": #"{"vars":{"DATABASE_URL":{"format":"url"}}}"#])
		defer { try? FileManager.default.removeItem(atPath: folder) }
		let loaded = ProjectEnvSchemaFile.load(inFolder: folder, vaultID: "project")
		var draft = Draft(schema: loaded.rootSchema)
		draft.set(.declared(try json(#"{"format":"port"}"#)), for: .key("PORT"))
		draft.set(.overridden(try json(#"{"format":"url","protocols":["postgres"]}"#)), for: .key("DATABASE_URL"))
		let evaluation = ProjectEnvSchemaFile.evaluate(draft, inFolder: folder, environments: ["default": ["PORT": "http", "DATABASE_URL": "https://db"]])
		#expect(evaluation.rejection == nil)
		#expect(evaluation.overview?.rule(for: "PORT")?.badges.map(\.text) == ["Port"])
		#expect(evaluation.overview?.rule(for: "DATABASE_URL")?.badges.map(\.text) == ["URL", "postgres only"])
		#expect(evaluation.check?.problems(of: "PORT", in: "default") == [Problem(key: "PORT", kind: .format("port"))])
		#expect(evaluation.check?.problems(of: "DATABASE_URL", in: "default") == [Problem(key: "DATABASE_URL", kind: .constraint("protocols"))])
	}

	@Test("a draft the engine rejects names the rule it rejects")
	func evaluationRejects() throws {
		let folder = try makeFolder(#"{"envSchema":{"vars":{"TOKEN":{"secret":true}}}}"#)
		defer { try? FileManager.default.removeItem(atPath: folder) }
		var draft = Draft(schema: ProjectEnvSchemaFile.load(inFolder: folder, vaultID: "project").rootSchema)
		draft.set(.declared(try json(#"{"secret":true,"default":"abc"}"#)), for: .key("TOKEN"))
		let evaluation = ProjectEnvSchemaFile.evaluate(draft, inFolder: folder, environments: [:])
		#expect(evaluation.overview == nil)
		#expect(evaluation.check == nil)
		let rejection = try #require(evaluation.rejection)
		#expect(rejection.item == .key("TOKEN"))
		#expect(rejection.reason == "Secret rules cannot contain literal defaults or enum values")
	}

	@Test("saving writes only the draft's items, rendered as the LPM CLI does, and keeps the rest of lpm.json")
	func saves() throws {
		let folder = try makeFolder(#"{"vault":"project","envSchema":{"vars":{"PORT":{"format":"port"}}},"environments":{"staging":{"file":".env.staging"}}}"#)
		defer { try? FileManager.default.removeItem(atPath: folder) }
		var draft = Draft(schema: ProjectEnvSchemaFile.load(inFolder: folder, vaultID: "project").rootSchema)
		draft.set(.declared(try json(#"{"format":"port","default":"8080"}"#)), for: .key("PORT"))
		draft.set(.declared(try json(#"{"secret":true}"#)), for: .key("TOKEN"))
		let saved = try ProjectEnvSchemaFile.apply(draft, inFolder: folder, vaultID: "project")
		#expect(saved.rules.keys == ["PORT", "TOKEN"])
		#expect(try String(contentsOfFile: folder + "/lpm.json", encoding: .utf8) == """
			{
			  "vault": "project",
			  "envSchema": {
			    "vars": {
			      "PORT": {
			        "format": "port",
			        "default": "8080"
			      },
			      "TOKEN": {
			        "secret": true
			      }
			    }
			  },
			  "environments": {
			    "staging": {
			      "file": ".env.staging"
			    }
			  }
			}

			""")
		#expect(saved.schema == ProjectEnvSchemaFile.load(inFolder: folder, vaultID: "project").rootSchema)
	}

	@Test("saving a draft whose lpm.json changed since it was read fails, leaving the file as it is")
	func saveDetectsChanges() throws {
		let folder = try makeFolder(#"{"envSchema":{"vars":{"PORT":{"format":"port"}}}}"#)
		defer { try? FileManager.default.removeItem(atPath: folder) }
		var draft = Draft(schema: ProjectEnvSchemaFile.load(inFolder: folder, vaultID: "project").rootSchema)
		draft.set(.declared(try json(#"{"format":"url"}"#)), for: .key("API_URL"))
		let outside = #"{"envSchema":{"vars":{"PORT":{"format":"port","default":"4000"}}}}"#
		try outside.write(toFile: folder + "/lpm.json", atomically: true, encoding: .utf8)
		#expect(throws: ProjectEnvSchemaFile.DraftSaveError.file(.changed)) { try ProjectEnvSchemaFile.apply(draft, inFolder: folder, vaultID: "project") }
		#expect(try String(contentsOfFile: folder + "/lpm.json", encoding: .utf8) == outside)

		draft.rebase(onto: ProjectEnvSchemaFile.load(inFolder: folder, vaultID: "project").rootSchema)
		let saved = try ProjectEnvSchemaFile.apply(draft, inFolder: folder, vaultID: "project")
		#expect(saved.schema?["vars"]?["PORT"]?["default"] == .string("4000"))
		#expect(saved.schema?["vars"]?["API_URL"] != nil)
	}

	@Test("a draft the engine rejects, with conflicts, or for another vault doesn't save")
	func refusesToSave() throws {
		let source = #"{"vault":"project","envSchema":{"vars":{"TOKEN":{"secret":true}}}}"#
		let folder = try makeFolder(source)
		defer { try? FileManager.default.removeItem(atPath: folder) }
		let read = ProjectEnvSchemaFile.load(inFolder: folder, vaultID: "project").rootSchema
		var rejected = Draft(schema: read)
		rejected.set(.declared(try json(#"{"secret":true,"enum":["a"]}"#)), for: .key("TOKEN"))
		#expect {
			try ProjectEnvSchemaFile.apply(rejected, inFolder: folder, vaultID: "project")
		} throws: { error in
			guard case .rejected(let rejection) = error as? ProjectEnvSchemaFile.DraftSaveError else { return false }
			return rejection.item == .key("TOKEN")
		}

		var conflicted = Draft(schema: try schema(#"{"vars":{"TOKEN":{}}}"#))
		conflicted.set(.declared(try json(#"{"required":true}"#)), for: .key("TOKEN"))
		conflicted.rebase(onto: read)
		#expect(throws: ProjectEnvSchemaFile.DraftSaveError.conflicts) { try ProjectEnvSchemaFile.apply(conflicted, inFolder: folder, vaultID: "project") }

		var valid = Draft(schema: read)
		valid.set(.declared(try json(#"{"format":"url"}"#)), for: .key("API_URL"))
		#expect(throws: ProjectEnvSchemaFile.DraftSaveError.file(.linkedToOtherVault)) { try ProjectEnvSchemaFile.apply(valid, inFolder: folder, vaultID: "other") }
		#expect(try String(contentsOfFile: folder + "/lpm.json", encoding: .utf8) == source)
	}

	@Test("a draft saves only into the folder it read, not another one now at the same path")
	func savesIntoTheFolderItRead() throws {
		let folder = try makeFolder(nil)
		defer { try? FileManager.default.removeItem(atPath: folder); try? FileManager.default.removeItem(atPath: folder + "-moved") }
		let loaded = ProjectEnvSchemaFile.load(inFolder: folder, vaultID: "project")
		var draft = Draft(schema: loaded.rootSchema)
		draft.set(.declared(try json(#"{"format":"port"}"#)), for: .key("PORT"))
		try FileManager.default.moveItem(atPath: folder, toPath: folder + "-moved")
		try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
		#expect(throws: ProjectEnvSchemaFile.DraftSaveError.file(.changed)) {
			try ProjectEnvSchemaFile.apply(draft, inFolder: folder, vaultID: "project", folderIdentity: loaded.folderIdentity)
		}
		#expect(!FileManager.default.fileExists(atPath: folder + "/lpm.json"))
	}

	@Test("a vault field that isn't a project ID blocks saving", arguments: [#"42"#, #"{}"#, #"["project"]"#])
	func malformedVaultLink(vault: String) throws {
		let source = #"{"vault":\#(vault),"envSchema":{"vars":{}}}"#
		let folder = try makeFolder(source)
		defer { try? FileManager.default.removeItem(atPath: folder) }
		var draft = Draft(schema: try schema(#"{"vars":{}}"#))
		draft.set(.declared(try json(#"{"format":"port"}"#)), for: .key("PORT"))
		#expect(throws: ProjectEnvSchemaFile.DraftSaveError.file(.invalidVaultLink)) { try ProjectEnvSchemaFile.apply(draft, inFolder: folder, vaultID: "project") }
		#expect(throws: ProjectEnvSchemaFile.FileError.invalidVaultLink) {
			try ProjectEnvSchemaFile.apply(.init(description: .init(key: "PORT", text: "Port")), inFolder: folder, vaultID: "project")
		}
		#expect(try String(contentsOfFile: folder + "/lpm.json", encoding: .utf8) == source)
	}

	@Test("an imported schema that changed since the draft was checked stops the save")
	func importsChangedSinceReview() throws {
		let folder = try makeFolder(#"{"envSchema":{"extends":["schemas/base.json"]}}"#, files: ["schemas/base.json": #"{"vars":{"A":{}}}"#])
		defer { try? FileManager.default.removeItem(atPath: folder) }
		var draft = Draft(schema: ProjectEnvSchemaFile.load(inFolder: folder, vaultID: "project").rootSchema)
		draft.set(.declared(try json(#"{"format":"port"}"#)), for: .key("PORT"))
		let reviewed = ProjectEnvSchemaFile.evaluate(draft, inFolder: folder, environments: [:])
		try #"{"vars":{"A":{"required":true}}}"#.write(toFile: folder + "/schemas/base.json", atomically: true, encoding: .utf8)
		#expect(throws: ProjectEnvSchemaFile.DraftSaveError.importsChanged) {
			try ProjectEnvSchemaFile.apply(draft, inFolder: folder, vaultID: "project", reviewed: reviewed.dependencies)
		}
		#expect(!(try String(contentsOfFile: folder + "/lpm.json", encoding: .utf8)).contains("PORT"))
	}

	@Test("a folder without lpm.json gets one with the draft's rules; removing the last rule removes envSchema")
	func createsAndEmpties() throws {
		let folder = try makeFolder(nil)
		defer { try? FileManager.default.removeItem(atPath: folder) }
		var draft = Draft(schema: ProjectEnvSchemaFile.load(inFolder: folder, vaultID: "project").rootSchema)
		draft.set(.declared(try json(#"{"format":"port"}"#)), for: .key("PORT"))
		let saved = try ProjectEnvSchemaFile.apply(draft, inFolder: folder, vaultID: "project")
		#expect(try String(contentsOfFile: folder + "/lpm.json", encoding: .utf8).contains(#""PORT""#))

		var removing = Draft(schema: saved.schema)
		removing.set(.absent, for: .key("PORT"))
		_ = try ProjectEnvSchemaFile.apply(removing, inFolder: folder, vaultID: "project")
		#expect(try String(contentsOfFile: folder + "/lpm.json", encoding: .utf8) == "{}\n")
	}

	private func makeFolder(_ lpmJSON: String?, files: [String: String] = [:]) throws -> String {
		let folder = FileManager.default.temporaryDirectory.appending(path: "schema-draft-\(UUID().uuidString)").path
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

@Suite("Schema drafts in the store", .serialized)
@MainActor
struct SchemaDraftStoreTests {
	private func json(_ text: String) throws -> LPMConfigJSON {
		try LPMConfigJSON(parsing: Data(text.utf8), rejectDuplicateKeys: true)
	}

	@Test("a draft starts from lpm.json's rules, is evaluated against the stored values, and saving it ends it")
	func editsEvaluatesAndSaves() async throws {
		let (store, folder) = try await makeStore(#"{"envSchema":{"vars":{"PORT":{"format":"port"}}}}"#, values: ["PORT": "3000", "RETRY": "12"])
		defer { store.lock(); try? FileManager.default.removeItem(atPath: folder) }
		#expect(store.schemaDraft(for: "project") == nil)
		#expect(store.canEditSchema(of: "project"))

		store.editSchemaDraft(in: "project") { $0.set(.declared(try! self.json(#"{"format":"integer","max":"5"}"#)), for: .key("RETRY")) }
		#expect(store.schemaDraft(for: "project")?.changedItems == [.key("RETRY")])
		try await waitUntil { store.currentSchemaDraftEvaluation(for: "project") != nil }
		let evaluation = try #require(store.currentSchemaDraftEvaluation(for: "project"))
		#expect(evaluation.overview?.rule(for: "RETRY")?.badges.map(\.text) == ["Integer", "≤ 5"])
		#expect(evaluation.check?.problems(of: "RETRY", in: "default") == [.init(key: "RETRY", kind: .constraint("max"))])

		try await store.saveSchemaDraft(in: "project")
		#expect(store.schemaDraft(for: "project") == nil)
		#expect(store.schemaDraftEvaluations["project"] == nil)
		#expect(try String(contentsOfFile: folder + "/lpm.json", encoding: .utf8).contains(#""RETRY""#))
		try await waitUntil { store.keyDescriptions["project"]?.schema?.overview?.rule(for: "RETRY") != nil }
		#expect(store.schemaDraftRebases["project"] == nil, "The app's own save isn't a change on disk")
	}

	@Test("a change on disk merges into the draft and is noted; a change to the same item conflicts")
	func mergesChangesOnDisk() async throws {
		let (store, folder) = try await makeStore(#"{"envSchema":{"vars":{"PORT":{"format":"port"},"RETRY":{"format":"integer"}}}}"#)
		defer { store.lock(); try? FileManager.default.removeItem(atPath: folder) }
		store.editSchemaDraft(in: "project") { $0.set(.declared(try! self.json(#"{"format":"port","default":"8080"}"#)), for: .key("PORT")) }

		try #"{"envSchema":{"vars":{"PORT":{"format":"port"},"RETRY":{"format":"integer","max":"3"}}}}"#.write(toFile: folder + "/lpm.json", atomically: true, encoding: .utf8)
		store.reloadKeyDescriptions()
		try await waitUntil { store.schemaDraftRebases["project"] != nil }
		#expect(store.schemaDraftRebases["project"]?.changedItems == [.key("RETRY")])
		#expect(store.schemaDraft(for: "project")?.changedItems == [.key("PORT")])
		store.dismissSchemaDraftRebase(in: "project")

		try await evaluated(store)
		try #"{"envSchema":{"vars":{"PORT":{"format":"port","default":"4000"},"RETRY":{"format":"integer","max":"3"}}}}"#.write(toFile: folder + "/lpm.json", atomically: true, encoding: .utf8)
		await #expect(throws: ProjectEnvSchemaFile.DraftSaveError.file(.changed)) { try await store.saveSchemaDraft(in: "project") }
		#expect(store.schemaDraftRebases["project"]?.conflicts == [.key("PORT")])
		await #expect(throws: ProjectEnvSchemaFile.DraftSaveError.conflicts) { try await store.saveSchemaDraft(in: "project") }

		store.editSchemaDraft(in: "project") { $0.resolveConflict(.key("PORT"), keepingMine: true) }
		try await evaluated(store)
		try await store.saveSchemaDraft(in: "project")
		let saved = try String(contentsOfFile: folder + "/lpm.json", encoding: .utf8)
		#expect(saved.contains(#""8080""#))
		#expect(saved.contains(#""max": "3""#))
	}

	@Test("the app's own description save merges into the draft without a note")
	func ownEditsAreNotNoted() async throws {
		let (store, folder) = try await makeStore(#"{"envSchema":{"vars":{"PORT":{"format":"port"},"TOKEN":{"secret":true}}}}"#, values: ["PORT": "3000", "TOKEN": "t"])
		defer { store.lock(); try? FileManager.default.removeItem(atPath: folder) }
		store.editSchemaDraft(in: "project") { $0.set(.declared(try! self.json(#"{"format":"port","default":"8080"}"#)), for: .key("PORT")) }
		let project = try #require(store.projects.first)
		store.keyDrafts.edit(project, key: "TOKEN") { $0.setKeyDescription("Bearer token", saved: "") }
		try await store.saveKeyDraft(.init(projectID: "project", key: "TOKEN"))
		try await waitUntil { store.schemaDraft(for: "project")?.schema?["vars"]?["TOKEN"]?["description"] != nil }
		#expect(store.schemaDraftRebases["project"] == nil)
		#expect(store.schemaDraft(for: "project")?.changedItems == [.key("PORT")])
	}

	@Test("an imported schema rewritten without changing its rules is evaluated again, so the draft still saves")
	func importRewrittenWithSameRules() async throws {
		let (store, folder) = try await makeStore(#"{"envSchema":{"extends":["base.json"],"vars":{"PORT":{"format":"port"}}}}"#, files: ["base.json": #"{"vars":{"A":{}}}"#])
		defer { store.lock(); try? FileManager.default.removeItem(atPath: folder) }
		store.editSchemaDraft(in: "project") { $0.set(.declared(try! self.json(#"{"format":"url"}"#)), for: .key("PORT")) }
		try await waitUntil { store.currentSchemaDraftEvaluation(for: "project") != nil }
		let before = store.currentSchemaDraftEvaluation(for: "project")?.dependencies
		try #"{ "vars": { "A": {} } }"#.write(toFile: folder + "/base.json", atomically: true, encoding: .utf8)
		store.reloadKeyDescriptions()
		try await waitUntil {
			guard let current = store.currentSchemaDraftEvaluation(for: "project") else { return false }
			return current.dependencies != before
		}
		try await store.saveSchemaDraft(in: "project")
		#expect(try String(contentsOfFile: folder + "/lpm.json", encoding: .utf8).contains(#""url""#))
	}

	@Test("an imported schema that changes after the review stops the save, which says why, until it's evaluated again")
	func importChangedAfterReview() async throws {
		let (store, folder) = try await makeStore(#"{"envSchema":{"extends":["base.json"],"vars":{"PORT":{"format":"port"}}}}"#, files: ["base.json": #"{"vars":{"A":{}}}"#])
		defer { store.lock(); try? FileManager.default.removeItem(atPath: folder) }
		let original = try String(contentsOfFile: folder + "/lpm.json", encoding: .utf8)
		store.editSchemaDraft(in: "project") { $0.set(.declared(try! self.json(#"{"format":"url"}"#)), for: .key("PORT")) }
		try await waitUntil { store.currentSchemaDraftEvaluation(for: "project") != nil }
		let reviewed = store.currentSchemaDraftEvaluation(for: "project")?.dependencies
		try #"{"vars":{"A":{"required":true}}}"#.write(toFile: folder + "/base.json", atomically: true, encoding: .utf8)
		await #expect(throws: ProjectEnvSchemaFile.DraftSaveError.importsChanged) { try await store.saveSchemaDraft(in: "project") }
		#expect(try String(contentsOfFile: folder + "/lpm.json", encoding: .utf8) == original)
		#expect(ProjectEnvSchemaFile.DraftSaveError.importsChanged.message == "An imported schema changed after you reviewed the rules. Check the changes again, then save.")
		try await waitUntil {
			guard let current = store.currentSchemaDraftEvaluation(for: "project") else { return false }
			return current.dependencies != reviewed
		}
		try await store.saveSchemaDraft(in: "project")
		#expect(try String(contentsOfFile: folder + "/lpm.json", encoding: .utf8).contains(#""url""#))
	}

	@Test("the retry after lpm.json was only reordered still checks the imports that were reviewed")
	func retryChecksReviewedImports() async throws {
		let (store, folder) = try await makeStore(#"{"envSchema":{"extends":["base.json"],"vars":{"PORT":{"format":"port"},"RETRY":{}}}}"#, files: ["base.json": #"{"vars":{"A":{}}}"#])
		defer { store.lock(); try? FileManager.default.removeItem(atPath: folder) }
		store.editSchemaDraft(in: "project") { $0.set(.declared(try! self.json(#"{"format":"url"}"#)), for: .key("PORT")) }
		try await waitUntil { store.currentSchemaDraftEvaluation(for: "project") != nil }
		try #"{"envSchema":{"extends":["base.json"],"vars":{"RETRY":{},"PORT":{"format":"port"}}}}"#.write(toFile: folder + "/lpm.json", atomically: true, encoding: .utf8)
		try #"{"vars":{"A":{"required":true}}}"#.write(toFile: folder + "/base.json", atomically: true, encoding: .utf8)
		await #expect(throws: ProjectEnvSchemaFile.DraftSaveError.importsChanged) { try await store.saveSchemaDraft(in: "project") }
		#expect(!(try String(contentsOfFile: folder + "/lpm.json", encoding: .utf8).contains(#""url""#)))
	}

	@Test("a draft isn't saved before it's evaluated, since nothing has shown what it does")
	func saveWaitsForEvaluation() async throws {
		let (store, folder) = try await makeStore(#"{"envSchema":{"vars":{"PORT":{"format":"port"}}}}"#)
		defer { store.lock(); try? FileManager.default.removeItem(atPath: folder) }
		store.editSchemaDraft(in: "project") { $0.set(.declared(try! self.json(#"{"format":"url"}"#)), for: .key("PORT")) }
		await #expect(throws: ProjectEnvSchemaFile.DraftSaveError.unavailable("The rules are still being checked. Save again in a moment.")) {
			try await store.saveSchemaDraft(in: "project")
		}
	}

	@Test("locking discards the draft")
	func lockDiscards() async throws {
		let (store, folder) = try await makeStore(#"{"envSchema":{"vars":{"PORT":{"format":"port"}}}}"#)
		defer { try? FileManager.default.removeItem(atPath: folder) }
		store.editSchemaDraft(in: "project") { $0.set(.absent, for: .key("PORT")) }
		#expect(store.schemaDraft(for: "project") != nil)
		store.lock()
		#expect(store.schemaDrafts.isEmpty)
		#expect(!store.canEditSchema(of: "project"))
	}

	@Test("a reread that lands while a save runs still merges the draft, so the next save works")
	func rereadDuringSave() async throws {
		let (store, folder) = try await makeStore(#"{"envSchema":{"vars":{"PORT":{"format":"port"},"RETRY":{"format":"integer"}}}}"#)
		defer { store.lock(); try? FileManager.default.removeItem(atPath: folder) }
		store.editSchemaDraft(in: "project") { $0.set(.declared(try! self.json(#"{"format":"port","default":"8080"}"#)), for: .key("PORT")) }
		try await evaluated(store)
		try #"{"envSchema":{"vars":{"PORT":{"format":"port"},"RETRY":{"format":"integer","max":"3"}}}}"#.write(toFile: folder + "/lpm.json", atomically: true, encoding: .utf8)

		let gate = DispatchSemaphore(value: 0)
		ProjectConfigFile.editQueue.async { gate.wait() }
		// The queue is shared by every test; a failure must not leave it blocked.
		defer { gate.signal() }
		let save = Task { @MainActor in try await store.saveSchemaDraft(in: "project") }
		try await waitUntil { store.savingSchemaDrafts.contains("project") }
		store.reloadKeyDescriptions()
		try await waitUntil { store.keyDescriptions["project"]?.rootSchema?["vars"]?["RETRY"]?["max"] != nil }
		gate.signal()
		await #expect(throws: ProjectEnvSchemaFile.DraftSaveError.file(.changed)) { try await save.value }
		#expect(store.schemaDraft(for: "project")?.schema == store.keyDescriptions["project"]?.rootSchema)
		#expect(store.schemaDraftRebases["project"]?.changedItems == [.key("RETRY")])
		try await evaluated(store)
		try await store.saveSchemaDraft(in: "project")
		#expect(try String(contentsOfFile: folder + "/lpm.json", encoding: .utf8).contains(#""8080""#))
	}

	@Test("a description saved in the inspector for a key the draft changes joins the draft, and saving keeps both")
	func ownDescriptionJoinsDraft() async throws {
		let (store, folder) = try await makeStore(#"{"envSchema":{"vars":{"PORT":{"format":"port"}}}}"#)
		defer { store.lock(); try? FileManager.default.removeItem(atPath: folder) }
		store.editSchemaDraft(in: "project") { $0.set(.declared(try! self.json(#"{"format":"port","default":"8080"}"#)), for: .key("PORT")) }
		let project = try #require(store.projects.first)
		store.keyDrafts.edit(project, key: "PORT") { $0.setKeyDescription("HTTP port", saved: "") }
		try await store.saveKeyDraft(.init(projectID: "project", key: "PORT"))
		try await waitUntil { store.keyDescriptions["project"]?.rootSchema?["vars"]?["PORT"]?["description"] != nil && !store.isReloadingKeyDescriptions }
		#expect(store.schemaDraft(for: "project")?.conflicts.isEmpty == true)
		#expect(store.schemaDraftRebases["project"] == nil)
		try await evaluated(store)
		try await store.saveSchemaDraft(in: "project")
		let saved = try String(contentsOfFile: folder + "/lpm.json", encoding: .utf8)
		#expect(saved.contains(#""HTTP port""#) && saved.contains(#""8080""#))
	}

	@Test("a description the app saves into an imported schema doesn't hide a later change to lpm.json")
	func ownImportedSaveKeepsLaterNotes() async throws {
		let (store, folder) = try await makeStore(#"{"envSchema":{"extends":["schemas/base.json"],"vars":{"PORT":{"format":"port"}}}}"#,
			files: ["schemas/base.json": #"{"vars":{"TOKEN":{"secret":true}}}"#], values: ["PORT": "3000", "TOKEN": "t"])
		defer { store.lock(); try? FileManager.default.removeItem(atPath: folder) }
		store.editSchemaDraft(in: "project") { $0.set(.declared(try! self.json(#"{"format":"port","default":"8080"}"#)), for: .key("PORT")) }
		let project = try #require(store.projects.first)
		store.keyDrafts.edit(project, key: "TOKEN") { $0.setKeyDescription("Bearer token", saved: "") }
		try await store.saveKeyDraft(.init(projectID: "project", key: "TOKEN"))
		#expect(try String(contentsOfFile: folder + "/schemas/base.json", encoding: .utf8).contains("Bearer token"))
		try await waitUntil { !store.isReloadingKeyDescriptions }
		try #"{"envSchema":{"extends":["schemas/base.json"],"vars":{"PORT":{"format":"port"},"RETRY":{"format":"integer"}}}}"#.write(toFile: folder + "/lpm.json", atomically: true, encoding: .utf8)
		store.reloadKeyDescriptions()
		try await waitUntil { store.schemaDraftRebases["project"] != nil }
		#expect(store.schemaDraftRebases["project"]?.changedItems == [.key("RETRY")])
	}

	@Test("an evaluation counts only for the draft and values it checked")
	func evaluationsMatchTheirDraft() async throws {
		let (store, folder) = try await makeStore(#"{"envSchema":{"vars":{"PORT":{"format":"port"}}}}"#)
		defer { store.lock(); try? FileManager.default.removeItem(atPath: folder) }
		store.editSchemaDraft(in: "project") { $0.set(.declared(try! self.json(#"{"secret":true,"default":"x"}"#)), for: .key("TOKEN")) }
		try await waitUntil { store.currentSchemaDraftEvaluation(for: "project") != nil }
		#expect(store.currentSchemaDraftEvaluation(for: "project")?.rejection?.item == .key("TOKEN"))
		store.editSchemaDraft(in: "project") { $0.set(.declared(try! self.json(#"{"secret":true}"#)), for: .key("TOKEN")) }
		#expect(store.currentSchemaDraftEvaluation(for: "project") == nil, "The previous draft's rejection doesn't apply")
		try await waitUntil { store.currentSchemaDraftEvaluation(for: "project") != nil }
		#expect(store.currentSchemaDraftEvaluation(for: "project")?.rejection == nil)
	}

	@Test("while lpm.json can't be read the draft can still be discarded, and saving says why it can't")
	func unreadableFile() async throws {
		let (store, folder) = try await makeStore(#"{"envSchema":{"vars":{"PORT":{"format":"port"}}}}"#)
		defer { store.lock(); try? FileManager.default.removeItem(atPath: folder) }
		store.editSchemaDraft(in: "project") { $0.set(.absent, for: .key("PORT")) }
		try "{not json".write(toFile: folder + "/lpm.json", atomically: true, encoding: .utf8)
		store.reloadKeyDescriptions()
		try await waitUntil { if case .unreadable? = store.keyDescriptions["project"]?.schema { true } else { false } }
		await #expect(throws: ProjectEnvSchemaFile.DraftSaveError.unavailable("lpm.json can't be read. Fix it, then save.")) { try await store.saveSchemaDraft(in: "project") }
		store.discardSchemaDraft(in: "project")
		#expect(store.schemaDraft(for: "project") == nil)
	}

	@Test("a second save while one runs is refused as in progress")
	func overlappingSaves() async throws {
		let (store, folder) = try await makeStore(#"{"envSchema":{"vars":{"PORT":{"format":"port"}}}}"#)
		defer { store.lock(); try? FileManager.default.removeItem(atPath: folder) }
		store.editSchemaDraft(in: "project") { $0.set(.absent, for: .key("PORT")) }
		try await evaluated(store)
		let gate = DispatchSemaphore(value: 0)
		ProjectConfigFile.editQueue.async { gate.wait() }
		// The queue is shared by every test; a failure must not leave it blocked.
		defer { gate.signal() }
		let first = Task { @MainActor in try await store.saveSchemaDraft(in: "project") }
		try await waitUntil { store.savingSchemaDrafts.contains("project") }
		await #expect(throws: ProjectEnvSchemaFile.DraftSaveError.inProgress) { try await store.saveSchemaDraft(in: "project") }
		gate.signal()
		try await first.value
	}

	@Test("a change on disk that only reorders members doesn't stop a save")
	func reorderedFileSaves() async throws {
		let (store, folder) = try await makeStore(#"{"envSchema":{"vars":{"PORT":{"format":"port","default":"3000"}}}}"#)
		defer { store.lock(); try? FileManager.default.removeItem(atPath: folder) }
		store.editSchemaDraft(in: "project") { $0.set(.declared(try! self.json(#"{"format":"url"}"#)), for: .key("API_URL")) }
		try await evaluated(store)
		try #"{"envSchema":{"vars":{"PORT":{"default":"3000","format":"port"}}}}"#.write(toFile: folder + "/lpm.json", atomically: true, encoding: .utf8)
		try await store.saveSchemaDraft(in: "project")
		#expect(try String(contentsOfFile: folder + "/lpm.json", encoding: .utf8).contains(#""API_URL""#))
		#expect(store.schemaDraftRebases["project"] == nil)
	}

	@Test("notes of changes on disk add up until dismissed, and go away with the draft")
	func notesAccumulate() async throws {
		let (store, folder) = try await makeStore(#"{"envSchema":{"vars":{"PORT":{"format":"port"}}}}"#)
		defer { store.lock(); try? FileManager.default.removeItem(atPath: folder) }
		store.editSchemaDraft(in: "project") { $0.set(.declared(try! self.json(#"{"format":"port","default":"8080"}"#)), for: .key("PORT")) }
		try #"{"envSchema":{"vars":{"PORT":{"format":"port"},"A":{}}}}"#.write(toFile: folder + "/lpm.json", atomically: true, encoding: .utf8)
		store.reloadKeyDescriptions()
		try await waitUntil { store.schemaDraftRebases["project"] != nil }
		try #"{"envSchema":{"vars":{"PORT":{"format":"port"},"A":{},"B":{}}}}"#.write(toFile: folder + "/lpm.json", atomically: true, encoding: .utf8)
		store.reloadKeyDescriptions()
		try await waitUntil { store.schemaDraftRebases["project"]?.changedItems.count == 2 }
		#expect(store.schemaDraftRebases["project"]?.changedItems == [.key("A"), .key("B")])
		store.editSchemaDraft(in: "project") { $0.discard(.key("PORT")) }
		#expect(store.schemaDraftRebases["project"] == nil)
	}

	@Test("typing runs one evaluation once it pauses, and a superseded evaluation never starts")
	func evaluationsFollowTyping() async throws {
		let (store, folder) = try await makeStore(#"{"envSchema":{"vars":{"PORT":{"format":"port"}}}}"#)
		defer { store.lock(); try? FileManager.default.removeItem(atPath: folder) }
		let calls = EvaluationCounter()
		store.schemaDraftEvaluator = ProjectEnvSchemaDraftEvaluator { schema, folder in
			calls.increment()
			return ProjectEnvSchemaDraftEvaluator.resolve(schema, inFolder: folder)
		}
		for digit in 0..<20 {
			store.editSchemaDraft(in: "project", coalescing: "default") {
				$0.set(.declared(.object([.init(key: "format", value: .string("port")), .init(key: "default", value: .string("30\(digit)"))])), for: .key("PORT"))
			}
		}
		try await waitUntil { store.currentSchemaDraftEvaluation(for: "project") != nil }
		#expect(calls.count == 1)
		for value in ["url", "port", "email", "hostname", "ip"] {
			store.editSchemaDraft(in: "project") { $0.set(.declared(.object([.init(key: "format", value: .string(value))])), for: .key("PORT")) }
		}
		try await waitUntil { store.currentSchemaDraftEvaluation(for: "project") != nil }
		#expect(calls.count <= 3, "Evaluations superseded while waiting don't run")
	}

	@Test("a project's draft ends when the project goes away")
	func removedProjectEndsDraft() async throws {
		let (store, folder) = try await makeStore(#"{"envSchema":{"vars":{"PORT":{"format":"port"}}}}"#)
		defer { store.lock(); try? FileManager.default.removeItem(atPath: folder) }
		store.editSchemaDraft(in: "project") { $0.set(.absent, for: .key("PORT")) }
		let project = try #require(store.projects.first)
		store.projects = []
		#expect(store.schemaDrafts["project"] == nil)
		store.projects = [project]
		#expect(store.schemaDraft(for: "project") == nil)
	}

	@Test("switching accounts while a save runs leaves nothing of the draft behind")
	func accountSwitchDuringSave() async throws {
		let (store, folder) = try await makeStore(#"{"envSchema":{"vars":{"PORT":{"format":"port"}}}}"#)
		defer { store.lock(); try? FileManager.default.removeItem(atPath: folder) }
		store.editSchemaDraft(in: "project") { $0.set(.absent, for: .key("PORT")) }
		try await evaluated(store)
		let gate = DispatchSemaphore(value: 0)
		ProjectConfigFile.editQueue.async { gate.wait() }
		// The queue is shared by every test; a failure must not leave it blocked.
		defer { gate.signal() }
		let save = Task { @MainActor in try await store.saveSchemaDraft(in: "project") }
		try await waitUntil { store.savingSchemaDrafts.contains("project") }
		store.selectedAccount = .org("acme")
		gate.signal()
		_ = await save.result
		#expect(store.schemaDrafts.isEmpty)
		#expect(store.keyDescriptions.isEmpty)
	}

	private func makeStore(_ lpmJSON: String, files: [String: String] = [:], values: [String: String] = ["PORT": "3000"]) async throws -> (VaultStore, String) {
		let folder = FileManager.default.temporaryDirectory.appending(path: "schema-draft-store-\(UUID().uuidString)").path
		try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
		try lpmJSON.write(toFile: folder + "/lpm.json", atomically: true, encoding: .utf8)
		for (path, contents) in files {
			let url = URL(fileURLWithPath: folder).appending(path: path)
			try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
			try contents.write(to: url, atomically: true, encoding: .utf8)
		}
		let environments = ["default": values]
		let keychain = MockKeychainService()
		keychain.envStorage["project"] = (name: "Project", path: folder, environments: environments)
		let preferences = try #require(UserDefaults(suiteName: "schema-draft-store-\(UUID().uuidString)"))
		let store = VaultStore(keychainService: keychain, biometricService: MockBiometricService(), apiService: MockAPIService(), preferences: preferences)
		store.projects = [VaultProject(id: "project", name: "Project", path: folder, environments: environments)]
		store.isUnlocked = true
		store.selectedProjectId = "project"
		store.reloadKeyDescriptions()
		try await waitUntil { store.keyDescriptions["project"]?.schema?.overview != nil }
		return (store, folder)
	}

	/// Waits for the draft as it is now to be evaluated, which saving requires.
	private func evaluated(_ store: VaultStore) async throws {
		try await waitUntil { store.currentSchemaDraftEvaluation(for: "project") != nil }
	}

	private func waitUntil(_ condition: () -> Bool) async throws {
		for _ in 0..<1000 {
			if condition() { return }
			try await Task.sleep(for: .milliseconds(5))
		}
		try #require(condition(), "Timed out")
	}
}

private final class EvaluationCounter: @unchecked Sendable {
	private let lock = NSLock()
	private var value = 0
	var count: Int { lock.withLock { value } }
	func increment() { lock.withLock { value += 1 } }
}
