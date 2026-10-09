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

	/// A project folder with `lpmJSON` and `base` written, and lpm.json's rules as a draft.
	private func project(_ lpmJSON: String = Self.lpmJSON, base: String = Self.base) throws -> (folder: String, draft: ProjectEnvSchemaDraft) {
		let folder = FileManager.default.temporaryDirectory.appending(path: "prefixes-\(UUID().uuidString)").path
		try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
		try lpmJSON.write(toFile: folder + "/lpm.json", atomically: true, encoding: .utf8)
		try base.write(toFile: folder + "/base.json", atomically: true, encoding: .utf8)
		let loaded = ProjectEnvSchemaFile.load(inFolder: folder, vaultID: "project")
		return (folder, ProjectEnvSchemaDraft(schema: loaded.rootSchema))
	}

	/// What the popover works from: `draft` with the rules the engine resolves for it.
	private func context(_ draft: ProjectEnvSchemaDraft, in folder: String) throws -> Prefixes.Context {
		let evaluation = ProjectEnvSchemaFile.evaluate(draft, inFolder: folder, environments: [:])
		let saved = try #require(ProjectEnvSchemaFile.load(inFolder: folder, vaultID: "project").schema.overview)
		return Prefixes.Context(draft: draft, rules: try #require(evaluation.overview, "\(evaluation.rejection?.reason ?? "")"), saved: saved)
	}

	/// `draft` with `change` applied and settled as the store settles every edit.
	private func applying(_ change: Prefixes.Change, to draft: ProjectEnvSchemaDraft, in folder: String) throws -> ProjectEnvSchemaDraft {
		var updated = draft
		updated.set(change.edits.map { ($0.item, $0.declaration) })
		Prefixes.settle(&updated, since: draft, imported: ["SHOP_"], saved: try saved(in: folder))
		return updated
	}

	/// lpm.json's rules as last read from `folder`.
	private func saved(in folder: String) throws -> Prefixes.Rules {
		try #require(ProjectEnvSchemaFile.load(inFolder: folder, vaultID: "project").schema.overview)
	}

	private func expectAccepted(_ draft: ProjectEnvSchemaDraft, in folder: String, sourceLocation: SourceLocation = #_sourceLocation) {
		let evaluation = ProjectEnvSchemaFile.evaluate(draft, inFolder: folder, environments: [:])
		#expect(evaluation.rejection == nil, "\(evaluation.rejection?.reason ?? "")", sourceLocation: sourceLocation)
	}

	@Test("a prefix has to be one the LPM CLI accepts, new, not already covered, and not leave a Secret key public", arguments: [
		("1ACME_", Prefixes.Issue.invalid), (String(repeating: "A", count: 256) + "_", .tooLong), ("ACME", .missingUnderscore),
		("NEXT_PUBLIC_", .framework), ("react_app_", .framework), ("WIDGET_", .duplicate), ("SHOP_", .duplicate),
		("WIDGET_THEME_", .redundant(by: "WIDGET_")), ("SHOP_X_", .redundant(by: "SHOP_")), ("NEXT_PUBLIC_X_", .redundant(by: "NEXT_PUBLIC_")),
		("API_", .secret(key: "API_TOKEN")),
	])
	func issues(prefix: String, issue: Prefixes.Issue) throws {
		let (folder, draft) = try project()
		defer { try? FileManager.default.removeItem(atPath: folder) }
		#expect(Prefixes.issue(adding: prefix, in: try context(draft, in: folder)) == issue)
	}

	@Test("the LPM CLI accepts at most 32 prefixes, imported ones included")
	func tooMany() throws {
		let own = (0..<31).map { "\"P\($0)_\"" }.joined(separator: ",")
		let (folder, draft) = try project(#"{"envSchema":{"extends":["base.json"],"clientPrefixes":[\#(own)]}}"#)
		defer { try? FileManager.default.removeItem(atPath: folder) }
		#expect(Prefixes.issue(adding: "ACME_PUBLIC_", in: try context(draft, in: folder)) == .tooMany)
	}

	@Test("adding a prefix marks the keys it makes public, with an override for an imported one, which the LPM CLI accepts")
	func adding() throws {
		let (folder, draft) = try project()
		defer { try? FileManager.default.removeItem(atPath: folder) }
		let context = try context(draft, in: folder)
		#expect(Prefixes.issue(adding: "ACME_PUBLIC_", in: context) == nil)
		let change = Prefixes.adding("ACME_PUBLIC_", in: context)
		#expect(change.keys == ["ACME_PUBLIC_CDN", "ACME_PUBLIC_FLAGS", "ACME_PUBLIC_REGION"])
		#expect(change.overridden == ["ACME_PUBLIC_REGION"])
		let updated = try applying(change, to: draft, in: folder)
		#expect(Prefixes.own(in: updated) == ["WIDGET_", "ACME_PUBLIC_"])
		#expect(updated.declaration(of: .key("ACME_PUBLIC_CDN")).json?["client"] == .bool(true))
		#expect(updated.declaration(of: .key("ACME_PUBLIC_CDN")).json?["format"] == .string("url"), "The rest of the rule stays")
		#expect(updated.declaration(of: .key("ACME_PUBLIC_REGION")) == .overridden(.object([
			.init(key: "default", value: .string("eu")), .init(key: "client", value: .bool(true)),
		])))
		let evaluation = ProjectEnvSchemaFile.evaluate(updated, inFolder: folder, environments: [:])
		#expect(evaluation.rejection == nil, "\(evaluation.rejection?.reason ?? "")")
		#expect(evaluation.overview?.publicKeys.isSuperset(of: change.keys) == true)
	}

	@Test("removing a prefix marks private the public keys no other prefix covers, and drops an empty list, which the LPM CLI accepts")
	func removing() throws {
		let (folder, draft) = try project()
		defer { try? FileManager.default.removeItem(atPath: folder) }
		let context = try context(draft, in: folder)
		#expect(Prefixes.keys(removing: "WIDGET_", in: context) == ["WIDGET_HOST", "WIDGET_THEME"])
		let updated = try applying(Prefixes.removing("WIDGET_", in: context), to: draft, in: folder)
		#expect(updated.declaration(of: .clientPrefixes) == .absent, "Without prefixes of its own, lpm.json has no list")
		#expect(updated.declaration(of: .key("WIDGET_THEME")) == .declared(.object([])))
		#expect(updated.declaration(of: .key("WIDGET_HOST")).json?["client"] == nil)
		expectAccepted(updated, in: folder)
	}

	@Test("the engine tells an import's prefixes apart, even when the import relies on lpm.json's own to resolve")
	func importedPrefixes() throws {
		let (folder, draft) = try project(#"{"envSchema":{"extends":["base.json"],"clientPrefixes":["WIDGET_","SHOP_"]}}"#,
			base: #"{"clientPrefixes":["SHOP_"],"vars":{"SHOP_ID":{"client":true},"WIDGET_BADGE":{"client":true}}}"#)
		defer { try? FileManager.default.removeItem(atPath: folder) }
		let context = try context(draft, in: folder)
		#expect(context.imported == ["SHOP_": "base.json"])
		#expect(Prefixes.keys(removing: "SHOP_", in: context).isEmpty, "An import that lists it too keeps it in effect")
		#expect(Prefixes.keys(removing: "WIDGET_", in: context) == ["WIDGET_BADGE"])
		expectAccepted(try applying(Prefixes.removing("WIDGET_", in: context), to: draft, in: folder), in: folder)
	}

	@Test("a prefix change works from the draft's own rules: keys it removes, adds, or makes Secret count as they are in it")
	func draftsOwnRules() throws {
		let (folder, base) = try project()
		defer { try? FileManager.default.removeItem(atPath: folder) }
		var draft = base
		draft.set(.absent, for: .key("ACME_PUBLIC_CDN"))
		draft.set(.declared(.object([])), for: .key("ACME_PUBLIC_NEW"))
		var adding = Prefixes.adding("ACME_PUBLIC_", in: try context(draft, in: folder))
		#expect(adding.keys == ["ACME_PUBLIC_FLAGS", "ACME_PUBLIC_NEW", "ACME_PUBLIC_REGION"], "A removed key isn't brought back as an override")
		expectAccepted(try applying(adding, to: draft, in: folder), in: folder)

		draft.set(.declared(.object([.init(key: "secret", value: .bool(true))])), for: .key("ACME_PUBLIC_FLAGS"))
		#expect(Prefixes.issue(adding: "ACME_PUBLIC_", in: try context(draft, in: folder)) == .secret(key: "ACME_PUBLIC_FLAGS"))

		let (overrides, overridden) = try project(Self.lpmJSON.replacingOccurrences(of: #""vars":{"#,
			with: #""overrides":{"ACME_PUBLIC_REGION":{"default":"us","required":true}},"vars":{"#))
		defer { try? FileManager.default.removeItem(atPath: overrides) }
		var reset = overridden
		reset.set(.absent, for: .key("ACME_PUBLIC_REGION"))
		adding = Prefixes.adding("ACME_PUBLIC_", in: try context(reset, in: overrides))
		let updated = try applying(adding, to: reset, in: folder)
		#expect(updated.declaration(of: .key("ACME_PUBLIC_REGION")) == .overridden(.object([
			.init(key: "default", value: .string("eu")), .init(key: "client", value: .bool(true)),
		])), "A pending reset stays: the imported rule is the one marked")
		expectAccepted(updated, in: overrides)
	}

	@Test("a confirmed change is the one shown, or none when the text or the rules moved on since")
	func confirmedChanges() throws {
		let (folder, draft) = try project()
		defer { try? FileManager.default.removeItem(atPath: folder) }
		let context = try context(draft, in: folder)
		let shown = Prefixes.adding("ACME_PUBLIC_", in: context)
		#expect(Prefixes.confirmed(shown, adding: "ACME_PUBLIC_", entry: "ACME_PUBLIC_", in: context) == shown)
		#expect(Prefixes.confirmed(shown, adding: "ACME_PUBLIC_", entry: "ACME_PUBLIC_EXTRA", in: context) == nil, "Text typed since it was shown")
		var moved = draft
		moved.set(.declared(.object([])), for: .key("ACME_PUBLIC_NEW"))
		#expect(Prefixes.confirmed(shown, adding: "ACME_PUBLIC_", entry: "ACME_PUBLIC_", in: try self.context(moved, in: folder)) == nil,
			"A key added since would be left out")
		let removal = Prefixes.removing("WIDGET_", in: context)
		#expect(Prefixes.confirmed(removal, removing: "WIDGET_", in: context) == removal)
		var removed = draft
		removed.set(.absent, for: .key("WIDGET_HOST"))
		#expect(Prefixes.confirmed(removal, removing: "WIDGET_", in: try self.context(removed, in: folder)) == nil)
	}

	@Test("the review warns when lpm.json's override drops Secret from the imported rule it replaces")
	func reviewWarnsOfDroppedSecret() throws {
		let (folder, base) = try project(#"{"envSchema":{"extends":["base.json"]}}"#, base: #"{"vars":{"TOKEN":{"secret":true},"REGION":{}}}"#)
		defer { try? FileManager.default.removeItem(atPath: folder) }
		var draft = base
		draft.set(.overridden(.object([.init(key: "required", value: .bool(true))])), for: .key("TOKEN"))
		draft.set(.overridden(.object([.init(key: "secret", value: .bool(true)), .init(key: "required", value: .bool(true))])), for: .key("REGION"))
		let evaluation = ProjectEnvSchemaFile.evaluate(draft, inFolder: folder, environments: [:])
		let project = VaultProject(id: "p", name: "p", path: folder, environments: [:])
		let review = try #require(ProjectEnvSchemaReview(draft: draft, evaluation: evaluation,
			savedRules: ProjectEnvSchemaFile.load(inFolder: folder, vaultID: "project").schema.overview, savedCheck: nil, project: project, environments: []))
		let warnings = Dictionary(uniqueKeysWithValues: review.items.map { ($0.title, $0.warning) })
		#expect(warnings["TOKEN"] == "base.json marks TOKEN Secret, and this override doesn't, so its value is no longer treated as secret.")
		#expect(warnings["REGION"] == .some(nil), "An override that keeps or adds Secret drops nothing")
		#expect(review.warningSummary == "TOKEN loses the Secret an import gives it. Check its change below before saving.")
	}

	@Test("removing nested prefixes one after another leaves every key they made public private")
	func nestedPrefixes() throws {
		let (folder, draft) = try project(
			#"{"envSchema":{"clientPrefixes":["APP_","APP_PUBLIC_"],"vars":{"APP_Y":{"client":true},"APP_PUBLIC_X":{"client":true}}}}"#)
		defer { try? FileManager.default.removeItem(atPath: folder) }
		let inner = try applying(Prefixes.removing("APP_PUBLIC_", in: try context(draft, in: folder)), to: draft, in: folder)
		#expect(inner.declaration(of: .key("APP_PUBLIC_X")).json?["client"] == .bool(true), "APP_ still covers it")
		let outer = try applying(Prefixes.removing("APP_", in: try context(inner, in: folder)), to: inner, in: folder)
		#expect(outer.declaration(of: .key("APP_Y")).json?["client"] == nil)
		#expect(outer.declaration(of: .key("APP_PUBLIC_X")).json?["client"] == nil)
		expectAccepted(outer, in: folder)
	}

	@Test("discarding or keeping a key after a prefix change leaves it public exactly when a prefix makes it so")
	func settlesOtherEdits() throws {
		let (folder, draft) = try project()
		defer { try? FileManager.default.removeItem(atPath: folder) }
		let added = try applying(Prefixes.adding("ACME_PUBLIC_", in: try context(draft, in: folder)), to: draft, in: folder)
		var discarded = added
		discarded.discard(.key("ACME_PUBLIC_CDN"))
		Prefixes.settle(&discarded, since: added, imported: ["SHOP_"], saved: try saved(in: folder))
		#expect(discarded.declaration(of: .key("ACME_PUBLIC_CDN")).json?["client"] == .bool(true))
		expectAccepted(discarded, in: folder)

		var removed = draft
		removed.remove("ACME_PUBLIC_CDN", settling: [])
		let addedAfter = try applying(Prefixes.adding("ACME_PUBLIC_", in: try context(removed, in: folder)), to: removed, in: folder)
		var kept = addedAfter
		kept.keep("ACME_PUBLIC_CDN")
		Prefixes.settle(&kept, since: addedAfter, imported: ["SHOP_"], saved: try saved(in: folder))
		expectAccepted(kept, in: folder)

		var removedTheme = draft
		removedTheme.remove("WIDGET_THEME", settling: [])
		let dropped = try applying(Prefixes.removing("WIDGET_", in: try context(removedTheme, in: folder)), to: removedTheme, in: folder)
		var keptTheme = dropped
		keptTheme.keep("WIDGET_THEME")
		Prefixes.settle(&keptTheme, since: dropped, imported: ["SHOP_"], saved: try saved(in: folder))
		#expect(keptTheme.declaration(of: .key("WIDGET_THEME")).json?["client"] == nil)
		expectAccepted(keptTheme, in: folder)
	}

	@Test("adding a prefix and removing it again leaves nothing behind, an override or an empty list")
	func addThenRemove() throws {
		for lpmJSON in [Self.lpmJSON, Self.lpmJSON.replacingOccurrences(of: #""clientPrefixes":["WIDGET_"]"#, with: #""clientPrefixes":[]"#)
			.replacingOccurrences(of: #""WIDGET_THEME":{"client":true},"#, with: "").replacingOccurrences(of: #""WIDGET_HOST":{"client":true,"format":"hostname"},"#, with: "")] {
			let (folder, draft) = try project(lpmJSON)
			defer { try? FileManager.default.removeItem(atPath: folder) }
			let added = try applying(Prefixes.adding("ACME_PUBLIC_", in: try context(draft, in: folder)), to: draft, in: folder)
			let removal = Prefixes.removing("ACME_PUBLIC_", in: try context(added, in: folder))
			#expect(removal.restored == ["ACME_PUBLIC_REGION"], "The override only marked it, so it goes")
			#expect(try applying(removal, to: added, in: folder).isEmpty)
		}
	}

	@Test("the store settles a key's public mark whatever edit unsettles it")
	@MainActor
	func storeSettles() async throws {
		let (folder, _) = try project()
		defer { try? FileManager.default.removeItem(atPath: folder) }
		let store = try await Self.store(folder: folder)
		store.editSchemaDraft(in: "schema-prefixes") { $0.set(.declared(.array([.string("WIDGET_"), .string("ACME_PUBLIC_")])), for: .clientPrefixes) }
		let draft = try #require(store.schemaDraft(for: "schema-prefixes"))
		#expect(draft.declaration(of: .key("ACME_PUBLIC_CDN")).json?["client"] == .bool(true), "A key lpm.json declares follows its prefix")
		#expect(draft.declaration(of: .key("ACME_PUBLIC_REGION")) == .absent, "An imported key is changed only by an override the user adds")
		store.editSchemaDraft(in: "schema-prefixes") { $0.set(.declared(.object([])), for: .key("ACME_PUBLIC_NEW")) }
		#expect(store.schemaDraft(for: "schema-prefixes")?.declaration(of: .key("ACME_PUBLIC_NEW")).json?["client"] == .bool(true))
	}

	@Test("prefixes can change only from the draft's own rules: not while it's checked, nor while the LPM CLI rejects it")
	@MainActor
	func availability() async throws {
		let (folder, _) = try project()
		defer { try? FileManager.default.removeItem(atPath: folder) }
		let store = try await Self.store(folder: folder)
		#expect(store.schemaPrefixAvailability(for: "schema-prefixes").context?.draft.isEmpty == true, "Without a draft, lpm.json's rules")
		store.editSchemaDraft(in: "schema-prefixes") { $0.set(.declared(.object([.init(key: "pattern", value: .string("("))])), for: .key("API_TOKEN")) }
		#expect(store.schemaPrefixAvailability(for: "schema-prefixes") == .checking)
		let clock = ContinuousClock()
		let deadline = clock.now.advanced(by: .seconds(10))
		while store.currentSchemaDraftEvaluation(for: "schema-prefixes") == nil, clock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
		#expect(store.schemaPrefixAvailability(for: "schema-prefixes") == .rejected)
		#expect(store.schemaPrefixAvailability(for: "schema-prefixes").reason != nil)
	}

	@Test("a Secret key is never marked public: the LPM CLI rejects the draft until someone decides")
	func secretStaysUnmarked() throws {
		let (folder, draft) = try project()
		defer { try? FileManager.default.removeItem(atPath: folder) }
		var updated = draft
		updated.set(.declared(.array([.string("WIDGET_"), .string("API_")])), for: .clientPrefixes)
		Prefixes.settle(&updated, since: draft, imported: ["SHOP_"], saved: try saved(in: folder))
		#expect(updated.declaration(of: .key("API_TOKEN")) == draft.declaration(of: .key("API_TOKEN")))
	}

	@Test("a prefix that makes public a key an import marks Secret says so, and the review leads with it")
	func exposesImportedSecret() throws {
		let (folder, draft) = try project(#"{"envSchema":{"extends":["base.json"],"overrides":{"ACME_TOKEN":{"description":"Token"}}}}"#,
			base: #"{"vars":{"ACME_TOKEN":{"secret":true},"ACME_REGION":{}}}"#)
		defer { try? FileManager.default.removeItem(atPath: folder) }
		let context = try context(draft, in: folder)
		#expect(Prefixes.issue(adding: "ACME_", in: context) == nil)
		let change = Prefixes.adding("ACME_", in: context)
		#expect(change.exposed == [Prefixes.Exposure(key: "ACME_TOKEN", source: "base.json")])
		let added = try applying(change, to: draft, in: folder)
		let evaluation = ProjectEnvSchemaFile.evaluate(added, inFolder: folder, environments: [:])
		let project = VaultProject(id: "p", name: "p", path: folder, environments: [:])
		let review = try #require(ProjectEnvSchemaReview(draft: added, evaluation: evaluation, savedRules: try saved(in: folder), savedCheck: nil,
			project: project, environments: []))
		#expect(review.warningSummary == "ACME_TOKEN loses the Secret an import gives it. Check its change below before saving.")
	}

	@Test("choosing the file's prefixes over the draft's takes back an override that only marked a key")
	@MainActor
	func takeTheirsRestores() async throws {
		let (folder, _) = try project()
		defer { try? FileManager.default.removeItem(atPath: folder) }
		let store = try await Self.store(folder: folder)
		try Self.add("ACME_PUBLIC_", in: store)
		#expect(store.schemaDraft(for: Self.id)?.declaration(of: .key("ACME_PUBLIC_REGION")) != .absent)
		try Self.lpmJSON.replacingOccurrences(of: #""clientPrefixes":["WIDGET_"]"#, with: #""clientPrefixes":["WIDGET_","OTHER_"]"#)
			.write(toFile: folder + "/lpm.json", atomically: true, encoding: .utf8)
		store.reloadKeyDescriptions()
		#expect(try await Self.waitUntil { store.schemaDraft(for: Self.id)?.conflicts.contains { $0.item == .clientPrefixes } == true })
		store.editSchemaDraft(in: Self.id) { $0.resolveConflict(.clientPrefixes, keepingMine: false) }
		#expect(store.schemaDraft(for: Self.id) == nil, "The override only marked the key, so nothing is left")
	}

	@Test("after a change on disk, every key is marked as the draft's prefixes require, and the draft is accepted")
	@MainActor
	func mergeSettlesEveryKey() async throws {
		let (added, _) = try project()
		defer { try? FileManager.default.removeItem(atPath: added) }
		let store = try await Self.store(folder: added)
		try Self.add("ACME_PUBLIC_", in: store)
		try Self.lpmJSON.replacingOccurrences(of: #""ACME_PUBLIC_FLAGS":{},"#, with: #""ACME_PUBLIC_FLAGS":{},"ACME_PUBLIC_NEW":{},"#)
			.write(toFile: added + "/lpm.json", atomically: true, encoding: .utf8)
		store.reloadKeyDescriptions()
		#expect(try await Self.waitUntil { store.schemaDraft(for: Self.id)?.declaration(of: .key("ACME_PUBLIC_NEW")).json?["client"] == .bool(true) },
			"A key lpm.json gains under the draft's prefix")
		#expect(try await Self.accepted(store))

		let (kept, _) = try project()
		defer { try? FileManager.default.removeItem(atPath: kept) }
		let other = try await Self.store(folder: kept)
		try Self.add("MINE_", in: other)
		try Self.lpmJSON.replacingOccurrences(of: #""clientPrefixes":["WIDGET_"]"#, with: #""clientPrefixes":["WIDGET_","THEIRS_"]"#)
			.replacingOccurrences(of: #""API_TOKEN":{"secret":true},"#, with: #""API_TOKEN":{"secret":true},"THEIRS_X":{"client":true},"#)
			.write(toFile: kept + "/lpm.json", atomically: true, encoding: .utf8)
		other.reloadKeyDescriptions()
		#expect(try await Self.waitUntil { other.schemaDraft(for: Self.id)?.conflicts.contains { $0.item == .clientPrefixes } == true })
		other.editSchemaDraft(in: Self.id) { $0.resolveConflict(.clientPrefixes, keepingMine: true) }
		#expect(other.schemaDraft(for: Self.id)?.declaration(of: .key("THEIRS_X")).json?["client"] == nil, "Keeping mine drops THEIRS_")
		#expect(try await Self.accepted(other))
	}

	@Test("discarding everything restores lpm.json's rules exactly, even while its imports can't be read")
	@MainActor
	func discardAllWhileUnreadable() async throws {
		let (folder, _) = try project(Self.lpmJSON.replacingOccurrences(of: #""API_TOKEN":{"secret":true},"#, with: #""API_TOKEN":{"secret":true},"SHOP_LOCAL":{"client":true},"#))
		defer { try? FileManager.default.removeItem(atPath: folder) }
		let store = try await Self.store(folder: folder)
		store.editSchemaDraft(in: Self.id) { $0.set(.declared(.object([.init(key: "pattern", value: .string("("))])), for: .key("API_TOKEN")) }
		#expect(try await Self.waitUntil { store.currentSchemaDraftEvaluation(for: Self.id)?.rejection != nil })
		try "{".write(toFile: folder + "/base.json", atomically: true, encoding: .utf8)
		store.reloadKeyDescriptions()
		#expect(try await Self.waitUntil { if case .unreadable? = store.keyDescriptions[Self.id]?.schema { true } else { false } })
		store.discardSchemaDraft(in: Self.id)
		#expect(store.schemaDraft(for: Self.id) == nil)
	}

	@Test("prefixes wait for the draft to be checked against imports that changed, not use the old check")
	@MainActor
	func changedImportsWait() async throws {
		let (folder, _) = try project()
		defer { try? FileManager.default.removeItem(atPath: folder) }
		let store = try await Self.store(folder: folder)
		store.editSchemaDraft(in: Self.id) { $0.set(.declared(.object([.init(key: "client", value: .bool(true)), .init(key: "description", value: .string("Theme"))])), for: .key("WIDGET_THEME")) }
		#expect(try await Self.waitUntil { store.currentSchemaDraftEvaluation(for: Self.id) != nil })
		let before = store.keyDescriptions[Self.id]?.dependencies
		store.schemaDraftEvaluator = ProjectEnvSchemaDraftEvaluator { schema, folder in
			Thread.sleep(forTimeInterval: 1)
			return ProjectEnvSchemaDraftEvaluator.resolve(schema, inFolder: folder)
		}
		try Self.base.replacingOccurrences(of: #""ACME_PUBLIC_REGION":{"default":"eu"}"#, with: #""ACME_PUBLIC_REGION":{"secret":true}"#)
			.write(toFile: folder + "/base.json", atomically: true, encoding: .utf8)
		store.reloadKeyDescriptions()
		#expect(try await Self.waitUntil { store.keyDescriptions[Self.id]?.dependencies != before })
		#expect(store.currentSchemaDraftEvaluation(for: Self.id) == nil)
		#expect(store.schemaPrefixAvailability(for: Self.id) == .checking)
		#expect(try await Self.waitUntil { store.schemaPrefixAvailability(for: Self.id).context != nil })
		let context = try #require(store.schemaPrefixAvailability(for: Self.id).context)
		#expect(Prefixes.issue(adding: "ACME_PUBLIC_", in: context) == .secret(key: "ACME_PUBLIC_REGION"))
	}

	@Test("after the app's own edit of lpm.json, prefixes wait for the file to be read back, and the imports stay known")
	@MainActor
	func ownWriteWaits() async throws {
		let (folder, _) = try project()
		defer { try? FileManager.default.removeItem(atPath: folder) }
		let store = try await Self.store(folder: folder)
		let project = try #require(store.projects.first)
		store.keyDrafts.edit(project, key: "WIDGET_THEME") { $0.setKeyDescription("Theme", saved: "") }
		try await store.saveKeyDraft(.init(projectID: Self.id, key: "WIDGET_THEME"))
		#expect(store.schemaPrefixAvailability(for: Self.id) == .checking)
		#expect(store.keyDescriptions[Self.id]?.dependencies?.isEmpty == false)
		#expect(try await Self.waitUntil { store.schemaPrefixAvailability(for: Self.id).context != nil })
	}

	@Test("an import that can't be read stays watched, so fixing it is noticed")
	@MainActor
	func brokenImportStaysWatched() async throws {
		let (folder, _) = try project()
		defer { try? FileManager.default.removeItem(atPath: folder) }
		let store = try await Self.store(folder: folder)
		#expect(store.keyDescriptions[Self.id]?.importPaths == ["base.json"])
		try "{".write(toFile: folder + "/base.json", atomically: true, encoding: .utf8)
		store.reloadKeyDescriptions()
		#expect(try await Self.waitUntil { if case .unreadable? = store.keyDescriptions[Self.id]?.schema { true } else { false } })
		#expect(store.keyDescriptions[Self.id]?.importPaths == ["base.json"])
	}

	static let id = "schema-prefixes"

	@MainActor
	private static func add(_ prefix: String, in store: VaultStore) throws {
		let context = try #require(store.schemaPrefixAvailability(for: id).context)
		let change = Prefixes.adding(prefix, in: context)
		store.editSchemaDraft(in: id) { $0.set(change.edits.map { ($0.item, $0.declaration) }) }
	}

	/// Whether the draft's check, once it's current, is accepted.
	@MainActor
	private static func accepted(_ store: VaultStore) async throws -> Bool {
		guard try await waitUntil({ store.currentSchemaDraftEvaluation(for: id) != nil }) else { return false }
		let rejection = store.currentSchemaDraftEvaluation(for: id)?.rejection
		if let rejection { Issue.record("Rejected: \(rejection.reason)") }
		return rejection == nil
	}

	@MainActor
	private static func waitUntil(_ condition: () -> Bool) async throws -> Bool {
		let clock = ContinuousClock()
		let deadline = clock.now.advanced(by: .seconds(10))
		while !condition() {
			guard clock.now < deadline else { return false }
			try await Task.sleep(for: .milliseconds(10))
		}
		return true
	}

	@MainActor
	static func store(folder: String) async throws -> VaultStore {
		let keychain = MockKeychainService()
		let project = VaultProject(id: "schema-prefixes", name: "billing-app", path: folder, environments: ["default": ["WIDGET_THEME": "dark"]])
		keychain.envStorage[project.id] = (name: project.name, path: folder, environments: project.environments)
		let store = VaultStore(keychainService: keychain, biometricService: MockBiometricService(),
			apiService: MockAPIService(), authTokenProvider: { _, _ in nil })
		store.isUnlocked = true
		store.projects = [project]
		store.openProject(id: project.id)
		await store.refreshCliAccess()
		store.reloadKeyDescriptions()
		let clock = ContinuousClock()
		let deadline = clock.now.advanced(by: .seconds(10))
		while store.keyDescriptions[project.id]?.schema?.overview == nil, clock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
		try #require(store.keyDescriptions[project.id]?.schema?.overview != nil)
		return store
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
			#expect(try await host.waitForText("become public with", in: popover))
			try await host.click("Add", in: popover)
			#expect(try await host.waitUntil {
				let draft = store.schemaDraft(for: "schema-prefixes")
				return draft.map(ProjectEnvSchemaClientPrefixes.own(in:)) == ["WIDGET_", "ACME_PUBLIC_"]
					&& draft?.declaration(of: .key("ACME_PUBLIC_CDN")).json?["client"] == .bool(true)
			})
			#expect(try await host.waitUntil { store.currentSchemaDraftEvaluation(for: "schema-prefixes")?.rejection == nil && store.currentSchemaDraftEvaluation(for: "schema-prefixes") != nil })
		}

		@Test("Return adds only the prefix whose change was shown, not text typed since")
		func staleReturn() async throws {
			let (store, host, folder) = try await workspace()
			defer { host.window.close(); store.lock(); try? FileManager.default.removeItem(atPath: folder) }
			try await host.click("Client prefixes")
			let popover = try await host.popoverWindow()
			try host.typeText("ACME_PUBLIC_", placeholder: "NEW_PREFIX_", in: popover)
			#expect(try await host.waitForText("become public with", in: popover))
			// No render between the new text and Return: the change shown is still ACME_PUBLIC_'s.
			try host.typeText("ACME_PUBLIC_EXTRA", placeholder: "NEW_PREFIX_", in: popover)
			try host.pressWhileEditing("\r", code: 36, in: popover)
			try await host.settle()
			#expect(store.schemaDraft(for: "schema-prefixes") == nil, "A prefix without its underscore isn't added")
			try host.typeText("ACME_PUBLIC_", placeholder: "NEW_PREFIX_", in: popover)
			#expect(try await host.waitForText("become public with", in: popover))
			try host.pressWhileEditing("\r", code: 36, in: popover)
			#expect(try await host.waitUntil { store.schemaDraft(for: "schema-prefixes").map(ProjectEnvSchemaClientPrefixes.own(in:)) == ["WIDGET_", "ACME_PUBLIC_"] })
		}

		@Test("an override lpm.json has that a prefix needs to mark the key can't be reset, which the panel explains")
		func resetKeepsTheMark() async throws {
			let lpmJSON = SchemaClientPrefixTests.lpmJSON
				.replacingOccurrences(of: #""clientPrefixes":["WIDGET_"]"#, with: #""clientPrefixes":["WIDGET_","ACME_PUBLIC_"]"#)
				.replacingOccurrences(of: #""ACME_PUBLIC_CDN":{"format":"url"},"#, with: #""ACME_PUBLIC_CDN":{"format":"url","client":true},"#)
				.replacingOccurrences(of: #""ACME_PUBLIC_FLAGS":{},"#, with: #""ACME_PUBLIC_FLAGS":{"client":true},"#)
				.replacingOccurrences(of: #""vars":{"#, with: #""overrides":{"ACME_PUBLIC_REGION":{"default":"us","client":true}},"vars":{"#)
			let (store, host, folder) = try await workspace(lpmJSON)
			defer { host.window.close(); store.lock(); try? FileManager.default.removeItem(atPath: folder) }
			try await host.click("ACME_PUBLIC_REGION")
			#expect(try await host.waitForText("Resetting would leave it unmarked"))
			#expect(try await !host.text().contains("Reset to original"))
		}

		@Test("an override a prefix adds only to mark an imported key public can't be discarded apart from the prefix")
		func markingOverrideStaysWithThePrefix() async throws {
			let (store, host, folder) = try await workspace()
			defer { host.window.close(); store.lock(); try? FileManager.default.removeItem(atPath: folder) }
			let context = try #require(store.schemaPrefixAvailability(for: "schema-prefixes").context)
			let change = ProjectEnvSchemaClientPrefixes.adding("ACME_PUBLIC_", in: context)
			store.editSchemaDraft(in: "schema-prefixes") { $0.set(change.edits.map { ($0.item, $0.declaration) }) }
			try await host.settle()
			// The row's badges leave room for only the ends of its name.
			try await host.click("REGION")
			#expect(try await host.waitForText("only to mark it Public"))
			#expect(try await !host.text().contains("Discard"), "Only removing the prefix takes the override away")
		}

		@Test("⌘⌫ on an override that marks a key as its prefixes require explains, and offers no reset that would break the mark")
		func removeKeepsTheMark() async throws {
			let lpmJSON = SchemaClientPrefixTests.lpmJSON
				.replacingOccurrences(of: #""clientPrefixes":["WIDGET_"]"#, with: #""clientPrefixes":["WIDGET_","ACME_PUBLIC_"]"#)
				.replacingOccurrences(of: #""ACME_PUBLIC_CDN":{"format":"url"},"#, with: #""ACME_PUBLIC_CDN":{"format":"url","client":true},"#)
				.replacingOccurrences(of: #""ACME_PUBLIC_FLAGS":{},"#, with: #""ACME_PUBLIC_FLAGS":{"client":true},"#)
				.replacingOccurrences(of: #""vars":{"#, with: #""overrides":{"ACME_PUBLIC_REGION":{"default":"us","client":true}},"vars":{"#)
			let (store, host, folder) = try await workspace(lpmJSON)
			defer { host.window.close(); store.lock(); try? FileManager.default.removeItem(atPath: folder) }
			try await host.click("ACME_PUBLIC_REGION")
			#expect(try await host.waitForText("Resetting would leave it unmarked"))
			try host.shortcut("\u{7f}", code: 51)
			#expect(try await host.waitUntil { host.window.sheets.first != nil })
			let sheet = try #require(host.window.sheets.first)
			#expect(try await host.waitForText("only an override can mark it", in: sheet))
			#expect(try await !host.text(in: sheet).contains("Reset to original"))
		}

		@Test("⌘⌫ on an override a prefix added only to mark the key offers no reset either")
		func removeKeepsTheAddedMark() async throws {
			let (store, host, folder) = try await workspace()
			defer { host.window.close(); store.lock(); try? FileManager.default.removeItem(atPath: folder) }
			let context = try #require(store.schemaPrefixAvailability(for: "schema-prefixes").context)
			let change = ProjectEnvSchemaClientPrefixes.adding("ACME_PUBLIC_", in: context)
			store.editSchemaDraft(in: "schema-prefixes") { $0.set(change.edits.map { ($0.item, $0.declaration) }) }
			let draft = store.schemaDraft(for: "schema-prefixes")
			try await host.settle()
			try await host.click("REGION")
			#expect(try await host.waitForText("only to mark it public"))
			try host.shortcut("\u{7f}", code: 51)
			#expect(try await host.waitUntil { host.window.sheets.first != nil })
			let sheet = try #require(host.window.sheets.first)
			#expect(try await host.waitForText("only an override can mark it", in: sheet))
			#expect(try await !host.text(in: sheet).contains("Reset to original"))
			#expect(store.schemaDraft(for: "schema-prefixes") == draft)
		}

		@Test("an override that settles a conflict between imports says so, not that it carries a mark")
		func conflictOverrideNote() async throws {
			let (store, host, folder) = try await workspace(#"{"envSchema":{"extends":["a.json","b.json"],"overrides":{"REGION":{"default":"us"}}}}"#,
				files: ["a.json": #"{"vars":{"REGION":{"default":"eu"}}}"#, "b.json": #"{"vars":{"REGION":{"default":"ap"}}}"#])
			defer { host.window.close(); store.lock(); try? FileManager.default.removeItem(atPath: folder) }
			try await host.click("REGION")
			#expect(try await host.waitForText("settles a conflict between imported schemas"))
			#expect(try await !host.text().contains("marked public"))
		}

		@Test("after Add, the field keeps focus for the next prefix, and imported prefixes stay listed while the draft is checked")
		func addKeepsFocus() async throws {
			let (store, host, folder) = try await workspace()
			defer { host.window.close(); store.lock(); try? FileManager.default.removeItem(atPath: folder) }
			try await host.click("Client prefixes")
			let popover = try await host.popoverWindow()
			#expect(try await host.waitForText("SHOP_", in: popover))
			store.schemaDraftEvaluator = ProjectEnvSchemaDraftEvaluator { schema, folder in
				Thread.sleep(forTimeInterval: 3)
				return ProjectEnvSchemaDraftEvaluator.resolve(schema, inFolder: folder)
			}
			try host.typeText("ACME_PUBLIC_", placeholder: "NEW_PREFIX_", in: popover)
			#expect(try await host.waitForText("become public with", in: popover))
			try host.pressWhileEditing("\r", code: 36, in: popover)
			#expect(try await host.waitUntil { store.schemaPrefixAvailability(for: "schema-prefixes") == .checking })
			try await host.settle()
			#expect(try await host.text(in: popover).contains("SHOP_"), "The imported prefix stays while the draft is checked")
			#expect(store.schemaPrefixAvailability(for: "schema-prefixes") == .checking)
			#expect(host.isEditing(placeholder: "NEW_PREFIX_", in: popover), "The field keeps focus")
		}

		@Test("a key lpm.json declares that a prefix marks has nothing to discard, and says why it changed")
		func markedKeyHasNothingToDiscard() async throws {
			let (store, host, folder) = try await workspace()
			defer { host.window.close(); store.lock(); try? FileManager.default.removeItem(atPath: folder) }
			let context = try #require(store.schemaPrefixAvailability(for: "schema-prefixes").context)
			let change = ProjectEnvSchemaClientPrefixes.adding("ACME_PUBLIC_", in: context)
			store.editSchemaDraft(in: "schema-prefixes") { $0.set(change.edits.map { ($0.item, $0.declaration) }) }
			try await host.settle()
			// The row's badges leave room for only the ends of its name.
			try await host.click("CDN")
			#expect(try await host.waitForText("Marked public"))
			#expect(try await !host.text().contains("Discard"))
		}

		@Test("a review that gives up an import's Secret leads with it, and Return doesn't save")
		func reviewWarningNeedsAClick() async throws {
			let (store, host, folder) = try await workspace(#"{"envSchema":{"extends":["base.json"]}}"#, base: #"{"vars":{"TOKEN":{"secret":true}}}"#)
			defer { host.window.close(); store.lock(); try? FileManager.default.removeItem(atPath: folder) }
			store.editSchemaDraft(in: "schema-prefixes") { $0.set(.overridden(.object([.init(key: "required", value: .bool(true))])), for: .key("TOKEN")) }
			#expect(try await host.waitUntil { store.currentSchemaDraftEvaluation(for: "schema-prefixes") != nil })
			try await host.click("TOKEN")
			try await host.click("Review & save")
			#expect(try await host.waitUntil { host.window.sheets.first != nil })
			let sheet = try #require(host.window.sheets.first)
			#expect(try await host.waitForText("loses the Secret an import gives it", in: sheet))
			let enter = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
				windowNumber: sheet.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
			#expect(!sheet.performKeyEquivalent(with: enter), "Return doesn't save")
			try await host.settle()
			#expect(store.schemaDraft(for: "schema-prefixes") != nil)
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

		private func workspace(_ lpmJSON: String = SchemaClientPrefixTests.lpmJSON, base: String = SchemaClientPrefixTests.base,
			files: [String: String] = [:]) async throws -> (VaultStore, SheetTestHost<some View>, String)
		{
			let folder = FileManager.default.temporaryDirectory.appending(path: "schema-prefixes-\(UUID().uuidString)").path
			try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
			try lpmJSON.write(toFile: folder + "/lpm.json", atomically: true, encoding: .utf8)
			try base.write(toFile: folder + "/base.json", atomically: true, encoding: .utf8)
			for (path, contents) in files { try contents.write(toFile: folder + "/" + path, atomically: true, encoding: .utf8) }
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
