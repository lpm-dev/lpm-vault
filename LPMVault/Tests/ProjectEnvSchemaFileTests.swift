import Darwin
import Foundation
import Testing

@testable import LPMVault

@Suite("lpm.json documents")
struct LPMConfigJSONTests {
    @Test("description edits preserve explicit private classification")
    func descriptionPreservesPrivateClassification() throws {
        let document = try LPMConfigJSON(parsing: Data(#"{"envSchema":{"vars":{"A":{"client":false,"description":"Old"}}}}"#.utf8))
        let edited = try ProjectEnvSchemaFile.applying(.init(description:.init(key:"A",text:"New")), to:document)
        #expect(edited["envSchema"]?["vars"]?["A"]?["client"] == .bool(false))
    }

	private func fixture(_ name: String) throws -> Data {
		try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/\(name)"))
	}

	/// The expected file was rendered by serde_json with the CLI's features after
	/// the same edit, so the app writes `lpm.json` exactly as the CLI would.
	@Test("direct sync projection canonicalizes exact integer bounds")
	func directSyncProjectionUsesDecimalBounds() {
		let root: [String: LPMJSONValue] = ["envSchema": .object(["vars": .object(["COUNT": .object(["format": .string("integer"), "min": .integer(1), "max": .integer(Int64.max), "minLength": .integer(1), "maxLength": .integer(4294967295)])])])]
		guard case .object(let wire) = ProjectEnvSchemaFile.pushMetadata(from: root), case .object(let vars)? = wire["envSchema"], case .object(let rule)? = vars["COUNT"] else { Issue.record("wire missing"); return }
		#expect(rule["min"] == .string("1"))
		#expect(rule["minLength"] == .string("1"))
		#expect(rule["maxLength"] == .string("4294967295"))
		#expect(rule["max"] == .string("9223372036854775807"))
	}

	@Test("an edit renders the file as the CLI's serde_json does")
	func matchesSerdeJSON() throws {
		let document = try LPMConfigJSON(parsing: fixture("lpm-json-edit-input.json"))
		let change = ProjectEnvSchemaFile.Change(
			rename: .init(from: "OLD_NAME", to: "NEW_NAME"),
			description: .init(key: "API_KEY", text: "Stripe key \"live\"\\n\té 🎉 </x>")
		)
		let updated = try ProjectEnvSchemaFile.applying(change, to: document)
		let expected = try #require(String(data: fixture("lpm-json-edit-expected.json"), encoding: .utf8))
		#expect(updated.rendered() + "\n" == expected)
		#expect(try LPMConfigJSON(parsing: Data(expected.utf8)).rendered() + "\n" == expected)
	}

	@Test("a repeated key keeps its first position and its last value")
	func duplicateKeys() throws {
		let document = try LPMConfigJSON(parsing: Data(#"{"a": 1, "b": 2, "a": 3}"#.utf8))
		#expect(document == .object([.init(key: "a", value: .number("3")), .init(key: "b", value: .number("2"))]))
	}

	@Test("distinct Unicode spellings survive unrelated JSON edits")
	func distinctUnicodeKeys() throws {
		var document = try LPMConfigJSON(parsing: Data(#"{"é":"first","e\u0301":"second","vault":"old"}"#.utf8))
		document.set(.string("new"), forKey: "vault")
		guard case .object(let members) = document else { Issue.record("Expected an object"); return }
		#expect(members.count == 3)
		#expect(document["é"] == .string("first"))
		#expect(document["e\u{0301}"] == .string("second"))
		document.set(.string("changed"), forKey: "e\u{0301}")
		#expect(document["é"] == .string("first"))
		document.renameKey("e\u{0301}", to: "decomposed")
		#expect(document["é"] == .string("first"))
		#expect(document.removeValue(forKey: "decomposed") == .string("changed"))
		#expect(document["é"] == .string("first"))
		#expect(LPMConfigJSON.string("é") != .string("e\u{0301}"))
		#expect(LPMConfigJSON.object([.init(key: "é", value: .null)]) != .object([.init(key: "e\u{0301}", value: .null)]))
	}

	@Test("strict JSON only, like the CLI", arguments: [
		#"{"a": 1,}"#, #"{"a": 1} // note"#, "{'a': 1}", #"{"a": 01}"#, #"{"a": "\ud800"}"#,
		"{\"a\": \"line\nbreak\"}", #"{"a": "open"#, #"{"a": 1} {}"#, #"{"a": NaN}"#, #"{"a": 1.}"#, "",
	])
	func rejectsInvalidJSON(text: String) {
		#expect(throws: LPMConfigJSON.ParseError.self) { try LPMConfigJSON(parsing: Data(text.utf8)) }
	}

	@Test("nesting stops at serde_json's recursion limit")
	func recursionLimit() throws {
		let accepted = String(repeating: "[", count: 128) + String(repeating: "]", count: 128)
		_ = try LPMConfigJSON(parsing: Data(accepted.utf8))
		let rejected = String(repeating: "[", count: 129) + String(repeating: "]", count: 129)
		#expect(throws: LPMConfigJSON.ParseError.tooDeep) { try LPMConfigJSON(parsing: Data(rejected.utf8)) }
	}

	@Test("rendering bounds escaped UTF-8 output and its trailing newline")
	func boundedRendering() throws {
		let document = LPMConfigJSON.object([.init(key: "unicode", value: .string("é🎉\n\u{1F}"))])
		let expected = Data((document.rendered() + "\n").utf8)
		#expect(try document.renderedData(maximumBytes: expected.count) == expected)
		#expect(throws: LPMConfigJSON.RenderError.tooLarge) { try document.renderedData(maximumBytes: expected.count - 1) }
		#expect(throws: LPMConfigJSON.RenderError.tooLarge) { try document.renderedData(maximumBytes: -1) }
	}
}

@Suite("lpm.json key descriptions", .serialized)
struct ProjectEnvSchemaFileTests {
	private let vaultID = "3f2b8c1e-4d5a-4f6b-9c7d-8e9f0a1b2c3d"

	@Test("sync omits metadata when the connected folder is missing")
	func syncOmitsMissingFolderMetadata() throws {
		let folder = try makeFolder(nil)
		defer { try? FileManager.default.removeItem(atPath: folder) }
		#expect(try ProjectEnvSchemaFile.validatedSyncConfig(inFolder: folder + "/missing", vaultID: vaultID) == nil)
	}

	@Test("a null env schema has no rules and accepts description edits")
	func nullSchemaHasNoRules() throws {
		let folder = try makeFolder(#"{"envSchema":null}"#)
		defer { try? FileManager.default.removeItem(atPath: folder) }
		#expect(try ProjectEnvSchemaFile.rules(inFolder: folder, vaultID: vaultID) == .init())
		let rules = try ProjectEnvSchemaFile.apply(.init(description: .init(key: "TOKEN", text: "token")), inFolder: folder, vaultID: vaultID)
		#expect(rules.descriptions["TOKEN"] == "token")
	}

	@Test("duplicate JSON keys have a specific diagnostic")
	func duplicateKeysHaveSpecificDiagnostic() throws {
		let folder = try makeFolder(#"{"unrelated":1,"unrelated":2}"#)
		defer { try? FileManager.default.removeItem(atPath: folder) }
		do {
			_ = try ProjectEnvSchemaFile.rules(inFolder: folder, vaultID: vaultID)
			Issue.record("Expected duplicate-key rejection")
		} catch {
			#expect(error.localizedDescription.contains("duplicate"))
		}
	}

	@Test("native edits and sync reject Rust-invalid pattern and default semantics", arguments: [
		#"{"pattern":"["}"#,
		#"{"pattern":"^live$","default":"dev"}"#,
		#"{"format":"port","default":"0"}"#,
	])
	func semanticInvalidSchemaPreservesFile(rule: String) throws {
		let original = #"{"envSchema":{"vars":{"VALUE":\#(rule)}}}"#
		let folder = try makeFolder(original)
		defer { try? FileManager.default.removeItem(atPath: folder) }
		#expect(throws: ProjectEnvSchemaFile.FileError.invalidSchema) {
			try ProjectEnvSchemaFile.apply(.init(description: .init(key: "VALUE", text: "Changed")), inFolder: folder, vaultID: vaultID)
		}
		#expect(try contents(folder) == original)
		#expect(throws: ProjectEnvSchemaFile.FileError.invalidSchema) {
			try ProjectEnvSchemaFile.validatedSyncConfig(inFolder: folder, vaultID: vaultID)
		}
	}

	@Test("scope metadata survives description edits and sync")
	func scopeMetadataSurvivesEditsAndSync() throws {
		let original =
			#"{"envSchema":{"vars":{"COUNT":{"format":"integer","requiredIn":[{"environment":["production"],"stage":["build"],"service":["api"]}],"defaultsIn":[{"when":{"stage":["test"]},"value":"2"}]}}}}"#
		let folder = try makeFolder(original)
		defer { try? FileManager.default.removeItem(atPath: folder) }
		_ = try ProjectEnvSchemaFile.apply(
			.init(description: .init(key: "COUNT", text: "Count")), inFolder: folder, vaultID: vaultID)
		let config = try #require(
			try ProjectEnvSchemaFile.validatedSyncConfig(inFolder: folder, vaultID: vaultID))
		guard case .object(let root) = config,
			case .object(let wire) = ProjectEnvSchemaFile.pushMetadata(from: root),
			case .object(let rules)? = wire["envSchema"], case .object(let rule)? = rules["COUNT"]
		else { Issue.record("scope metadata missing"); return }
		#expect(rule["requiredIn"] != nil)
		#expect(rule["defaultsIn"] != nil)
		#expect(rule["description"] == .string("Count"))
		let document = try LPMConfigJSON(parsing: Data(original.utf8))
		let edited = try LPMConfigJSON(parsing: Data(contents(folder).utf8))
		#expect(
			edited["envSchema"]?["vars"]?["COUNT"]?["requiredIn"]
				== document["envSchema"]?["vars"]?["COUNT"]?["requiredIn"])
		#expect(
			edited["envSchema"]?["vars"]?["COUNT"]?["defaultsIn"]
				== document["envSchema"]?["vars"]?["COUNT"]?["defaultsIn"])
	}

	@Test(
		"malformed or ambiguous scopes reject edits without writing",
		arguments: [
			#"{"requiredIn":null}"#, #"{"requiredIn":[{}]}"#, #"{"requiredIn":[{"stage":[]}]}"#,
			#"{"requiredIn":[{"stage":["unknown"]}]}"#, #"{"requiredIn":[{"environment":["../outside"]}]}"#,
			#"{"requiredIn":[{"service":["api\u001f"]}]}"#,
			#"{"defaultsIn":[{"when":{"stage":["build"]},"value":"1"},{"when":{"environment":["production"]},"value":"2"}]}"#,
			#"{"secret":true,"defaultsIn":[{"when":{"stage":["build"]},"value":"private-fixture"}]}"#,
		])
	func malformedScopesPreserveFile(rule: String) throws {
		let original = #"{"envSchema":{"vars":{"VALUE":\#(rule)}}}"#
		let folder = try makeFolder(original)
		defer { try? FileManager.default.removeItem(atPath: folder) }
		#expect(throws: ProjectEnvSchemaFile.FileError.invalidSchema) {
			try ProjectEnvSchemaFile.apply(
				.init(description: .init(key: "VALUE", text: "Changed")), inFolder: folder,
				vaultID: vaultID)
		}
		#expect(try contents(folder) == original)
	}

	@Test("global scope budgets reject valid individual rules", arguments: [false, true])
	func aggregateScopeLimitsRejectBeforeSync(atoms: Bool) throws {
		let count = atoms ? 257 : 129
		let names = (0..<32).map { "\"name\($0)\"" }.joined(separator: ",")
		let selectors =
			atoms
			? #"{"environment":[\#(names)],"service":[\#(names)],"stage":["development","build","runtime","ci","test"]}"#
			: (0..<32).map { #"{"environment":["name\#($0)"]}"# }.joined(separator: ",")
		let rules = (0..<count).map { #""VALUE_\#($0)":{"requiredIn":[\#(selectors)]}"# }.joined(separator: ",")
		let original = #"{"envSchema":{"vars":{\#(rules)}}}"#
		let folder = try makeFolder(original)
		defer { try? FileManager.default.removeItem(atPath: folder) }
		#expect(throws: ProjectEnvSchemaFile.FileError.invalidSchema) {
			try ProjectEnvSchemaFile.validatedSyncConfig(inFolder: folder, vaultID: vaultID)
		}
	}

	@Test("scope identity treats omitted stage as all stages")
	func omittedStageMatchesAllStages() throws {
		let original =
			#"{"envSchema":{"vars":{"VALUE":{"requiredIn":[{"environment":["production"]},{"environment":["production"],"stage":["development","build","runtime","ci","test"]}]}}}}"#
		let folder = try makeFolder(original)
		defer { try? FileManager.default.removeItem(atPath: folder) }
		#expect(throws: ProjectEnvSchemaFile.FileError.invalidSchema) {
			try ProjectEnvSchemaFile.validatedSyncConfig(inFolder: folder, vaultID: vaultID)
		}
	}

	@Test("description edits reject duplicate declarations without changing the file")
	func duplicateDeclarationsAreNotNormalized() throws {
		let original = #"{"envSchema":{"vars":{"A":{"required":true},"A":{"description":"old"}}}}"#
		let folder = try makeFolder(original)
		defer { try? FileManager.default.removeItem(atPath: folder) }
		#expect(throws: (any Error).self) {
			try ProjectEnvSchemaFile.apply(.init(description: .init(key: "A", text: "new")), inFolder: folder, vaultID: vaultID)
		}
		#expect(try contents(folder) == original)
	}

	@Test("forbidden secret literals cannot pass through description edits", arguments: ["default", "enum"])
	func secretLiteralsRejectEdits(field: String) throws {
		let value = field == "enum" ? #"["private-fixture-value"]"# : #""private-fixture-value""#
		let original = #"{"envSchema":{"vars":{"A":{"secret":true,"\#(field)":\#(value)}}}}"#
		let folder = try makeFolder(original)
		defer { try? FileManager.default.removeItem(atPath: folder) }
		#expect(throws: ProjectEnvSchemaFile.FileError.invalidSchema) {
			try ProjectEnvSchemaFile.apply(.init(description: .init(key: "A", text: "new")), inFolder: folder, vaultID: vaultID)
		}
		#expect(try contents(folder) == original)
	}

	@Test("description edits reject unsafe controls without changing the file", arguments: ["\u{0}", "\u{1F}", "\u{7F}", "\u{85}"])
	func unsafeDescriptionControlsRejectEdits(control: String) throws {
		let original = #"{"envSchema":{"vars":{"A":{}}}}"#
		let folder = try makeFolder(original)
		defer { try? FileManager.default.removeItem(atPath: folder) }
		#expect(throws: ProjectEnvSchemaFile.FileError.invalidSchema) {
			try ProjectEnvSchemaFile.apply(.init(description: .init(key: "A", text: "before" + control + "after")), inFolder: folder, vaultID: vaultID)
		}
		#expect(try contents(folder) == original)
	}

	@Test("sync rejects forbidden secret literals before constructing plaintext metadata")
	func syncConfigRejectsSecretLiterals() throws {
		let folder = try makeFolder(#"{"envSchema":{"vars":{"TOKEN":{"secret":true,"default":"private-fixture-value"}}}}"#)
		defer { try? FileManager.default.removeItem(atPath: folder) }
		#expect(throws: ProjectEnvSchemaFile.FileError.invalidSchema) {
			try ProjectEnvSchemaFile.validatedSyncConfig(inFolder: folder, vaultID: vaultID)
		}
	}

	@Test("description edits preserve independent exposure and CI storage policy")
	func editsPreserveExposurePolicy() throws {
		let folder = try makeFolder(#"{"envSchema":{"clientPrefixes":["APP_"],"vars":{"APP_API":{"client":true,"ci":"secret"},"BUILD_MODE":{"ci":"variable"}}}}"#)
		defer { try? FileManager.default.removeItem(atPath: folder) }
		_ = try ProjectEnvSchemaFile.apply(.init(description: .init(key: "APP_API", text: "Public endpoint")), inFolder: folder, vaultID: vaultID)
		let config = try ProjectEnvSchemaFile.validatedSyncConfig(inFolder: folder, vaultID: vaultID)
		guard case .object(let root)? = config else { Issue.record("metadata missing"); return }
		guard case .object(let wire) = ProjectEnvSchemaFile.pushMetadata(from: root) else { Issue.record("wire missing"); return }
		#expect(wire["envSchemaConfig"] == .object(["clientPrefixes": .array([.string("APP_")])]))
		guard case .object(let vars)? = wire["envSchema"], case .object(let rule)? = vars["APP_API"] else { Issue.record("rule missing"); return }
		#expect(rule["ci"] == .string("secret"))
		#expect(rule["description"] == .string("Public endpoint"))
	}

	@Test("native exposure rules reject browser secrets and readable secret storage", arguments: [
		#"{"vars":{"PUBLIC_TOKEN":{"secret":true,"client":true}}}"#,
		#"{"vars":{"react_app_token":{"secret":true}}}"#,
		#"{"vars":{"TOKEN":{"secret":true,"ci":"variable"}}}"#,
		#"{"clientPrefixes":["APP_","APP_"],"vars":{}}"#,
		#"{"vars":{"VITE_TOKEN":{}}}"#
	])
	func exposureRejectsUnsafePolicy(_ schema: String) throws {
		let document = try LPMConfigJSON(parsing: Data("{\"envSchema\":\(schema)}".utf8))
		#expect(throws: ProjectEnvSchemaFile.FileError.invalidSchema) { try ProjectEnvSchemaFile.rules(of: document) }
	}

	@Test("sync projects metadata without decoding unrelated manifest numbers")
	func syncConfigProjectsMetadata() throws {
		let original = #"{"unrelated":{"number":1e400},"envSchema":{"vars":{"MESSAGE":{"description":"public"}}}}"#
		let folder = try makeFolder(original)
		defer { try? FileManager.default.removeItem(atPath: folder) }
		let config = try ProjectEnvSchemaFile.validatedSyncConfig(inFolder: folder, vaultID: vaultID)
		#expect(config == .object(["envSchema": .object(["vars": .object(["MESSAGE": .object(["description": .string("public")])])])]))
		#expect(try String(contentsOfFile: folder + "/lpm.json", encoding: .utf8) == original)
	}

	@Test("sync retains supported public metadata and rejects a changed project binding")
	func syncConfigChecksBindingAndRetainsPublicFields() throws {
		let folder = try makeFolder(#"{"vault":"\#(vaultID)","envSchema":{"vars":{"MESSAGE":{"default":"first\nsecond","description":"a\tb"}}}}"#)
		defer { try? FileManager.default.removeItem(atPath: folder) }
		let config = try ProjectEnvSchemaFile.validatedSyncConfig(inFolder: folder, vaultID: vaultID)
		#expect(config != nil)
		#expect(throws: ProjectEnvSchemaFile.FileError.linkedToOtherVault) {
			try ProjectEnvSchemaFile.validatedSyncConfig(inFolder: folder, vaultID: "another-project")
		}
	}

	@Test("reads each key's rule and description")
	func readsRules() throws {
		let folder = try makeFolder(#"{"vault": "\#(vaultID)", "envSchema": {"vars": {"A": {"required": true}, "B": {"description": "Bee"}}}}"#)
		defer { try? FileManager.default.removeItem(atPath: folder) }
		let rules = try ProjectEnvSchemaFile.rules(inFolder: folder, vaultID: vaultID)
		#expect(rules == .init(keys: ["A", "B"], descriptions: ["B": "Bee"]))
	}

	@Test("a folder without lpm.json has no rules, and a missing folder has none to offer")
	func missingFiles() throws {
		let folder = try makeFolder(nil)
		defer { try? FileManager.default.removeItem(atPath: folder) }
		#expect(try ProjectEnvSchemaFile.rules(inFolder: folder, vaultID: vaultID) == .init())
		#expect(throws: ProjectEnvSchemaFile.FileError.noFolder) {
			try ProjectEnvSchemaFile.rules(inFolder: folder + "/missing", vaultID: vaultID)
		}
	}

	@Test("refuses files the CLI would not use for this vault", arguments: [
		(#"{"vault": "another-vault"}"#, ProjectEnvSchemaFile.FileError.linkedToOtherVault),
		(#"{"envSchema": []}"#, .invalidSchema),
		(#"{"envSchema": {"vars": {"A": {"description": 1}}}}"#, .invalidSchema),
		("{", .invalidJSON),
		("[]", .invalidJSON),
	])
	func refusesUnusableFiles(contents: String, error: ProjectEnvSchemaFile.FileError) throws {
		let folder = try makeFolder(contents)
		defer { try? FileManager.default.removeItem(atPath: folder) }
		#expect(throws: error) { try ProjectEnvSchemaFile.rules(inFolder: folder, vaultID: vaultID) }
		#expect(throws: error) {
			try ProjectEnvSchemaFile.apply(.init(description: .init(key: "A", text: "x")), inFolder: folder, vaultID: vaultID)
		}
		#expect(try String(contentsOfFile: folder + "/lpm.json", encoding: .utf8) == contents)
	}

	@Test("never follows a symbolic link to lpm.json")
	func rejectsSymlink() throws {
		let folder = try makeFolder(nil)
		defer { try? FileManager.default.removeItem(atPath: folder) }
		try #"{"vault": "\#(vaultID)"}"#.write(toFile: folder + "/elsewhere.json", atomically: true, encoding: .utf8)
		try FileManager.default.createSymbolicLink(atPath: folder + "/lpm.json", withDestinationPath: folder + "/elsewhere.json")
		#expect(throws: ProjectEnvSchemaFile.FileError.unsafeFile) {
			try ProjectEnvSchemaFile.apply(.init(description: .init(key: "A", text: "x")), inFolder: folder, vaultID: vaultID)
		}
		#expect(try String(contentsOfFile: folder + "/elsewhere.json", encoding: .utf8) == #"{"vault": "\#(vaultID)"}"#)
	}

	@Test("adding and then clearing a description leaves no empty rule behind")
	func addAndClear() throws {
		let folder = try makeFolder(#"{"vault": "\#(vaultID)", "tasks": {}}"#)
		defer { try? FileManager.default.removeItem(atPath: folder) }
		let added = try ProjectEnvSchemaFile.apply(.init(description: .init(key: "API_KEY", text: "Billing")), inFolder: folder, vaultID: vaultID)
		#expect(added.descriptions == ["API_KEY": "Billing"])
		#expect(try contents(folder) == """
			{
			  "vault": "\(vaultID)",
			  "tasks": {},
			  "envSchema": {
			    "vars": {
			      "API_KEY": {
			        "description": "Billing"
			      }
			    }
			  }
			}

			""")
		_ = try ProjectEnvSchemaFile.apply(.init(description: .init(key: "API_KEY", text: "")), inFolder: folder, vaultID: vaultID)
		#expect(try contents(folder) == "{\n  \"vault\": \"\(vaultID)\",\n  \"tasks\": {}\n}\n")
	}

	@Test("clearing a description keeps the key's other rules")
	func clearKeepsRules() throws {
		let folder = try makeFolder(#"{"envSchema": {"vars": {"A": {"required": true, "description": "Old"}}}}"#)
		defer { try? FileManager.default.removeItem(atPath: folder) }
		let rules = try ProjectEnvSchemaFile.apply(.init(description: .init(key: "A", text: "")), inFolder: folder, vaultID: vaultID)
		#expect(rules == .init(keys: ["A"], descriptions: [:]))
	}

	@Test("a rename moves the rule in place unless the new name already has one", arguments: [false, true])
	func renameRule(targetExists: Bool) throws {
		let target = targetExists ? #", "NEW": {"required": true}"# : ""
		let folder = try makeFolder(#"{"envSchema": {"vars": {"FIRST": {}, "OLD": {"description": "Old"}, "LAST": {}\#(target)}}}"#)
		defer { try? FileManager.default.removeItem(atPath: folder) }
		let rules = try ProjectEnvSchemaFile.apply(.init(rename: .init(from: "OLD", to: "NEW")), inFolder: folder, vaultID: vaultID)
		let document = try LPMConfigJSON(parsing: Data(contents(folder).utf8))
		guard case .object(let vars)? = document["envSchema"]?["vars"] else {
			Issue.record("Missing vars")
			return
		}
		if targetExists {
			#expect(vars.map(\.key) == ["FIRST", "OLD", "LAST", "NEW"])
			#expect(rules.descriptions == ["OLD": "Old"])
		} else {
			#expect(vars.map(\.key) == ["FIRST", "NEW", "LAST"])
			#expect(rules.descriptions == ["NEW": "Old"])
		}
	}

	@Test("a change with no effect leaves the file untouched, and a write keeps its permissions")
	func writesOnlyChanges() throws {
		let original = #"{"envSchema":{"vars":{"A":{"description":"Same"}}}}"#
		let folder = try makeFolder(original)
		defer { try? FileManager.default.removeItem(atPath: folder) }
		chmod(folder + "/lpm.json", 0o600)
		_ = try ProjectEnvSchemaFile.apply(.init(description: .init(key: "A", text: "Same")), inFolder: folder, vaultID: vaultID)
		#expect(try contents(folder) == original)
		_ = try ProjectEnvSchemaFile.apply(.init(description: .init(key: "A", text: "New")), inFolder: folder, vaultID: vaultID)
		var metadata = stat()
		#expect(stat(folder + "/lpm.json", &metadata) == 0)
		#expect(metadata.st_mode & 0o777 == 0o600)
	}

	@Test("an edit waits for the CLI's config lock")
	func waitsForCLILock() async throws {
		let folder = try makeFolder(#"{"vault": "\#(vaultID)"}"#)
		defer { try? FileManager.default.removeItem(atPath: folder) }
		mkdir(folder + "/.lpm", 0o755)
		let lock = open(folder + "/.lpm/.config.lock", O_RDWR | O_CREAT, 0o644)
		try #require(lock >= 0)
		#expect(flock(lock, LOCK_EX) == 0)
		let vaultID = vaultID
		let edit = Task {
			await ProjectEnvSchemaFile.save(.init(description: .init(key: "A", text: "Locked")), inFolder: folder, vaultID: vaultID)
		}
		try await Task.sleep(for: .milliseconds(200))
		#expect(try contents(folder) == #"{"vault": "\#(vaultID)"}"#)
		flock(lock, LOCK_UN)
		close(lock)
		#expect(try await edit.value.get().descriptions == ["A": "Locked"])
	}

	@Test("expanded JSON is rejected without changing the original file")
	func rejectsOversizedRendering() throws {
		let original = "{\"extra\":" + String(repeating: "[", count: 126) + Array(repeating: "0", count: 100_000).joined(separator: ",") + String(repeating: "]", count: 126) + "}"
		let folder = try makeFolder(original)
		defer { try? FileManager.default.removeItem(atPath: folder) }
		#expect(throws: ProjectEnvSchemaFile.FileError.tooLarge) {
			try ProjectEnvSchemaFile.apply(.init(description: .init(key: "A", text: "New")), inFolder: folder, vaultID: vaultID)
		}
		#expect(try contents(folder) == original)
	}

	@Test("descriptions classify public names", arguments: ["NEXT_PUBLIC_API", "EXPO_PUBLIC_API", "GATSBY_API", "NUXT_PUBLIC_API", "APP_API"])
	func descriptionsClassifyPublicNames(key: String) throws {
		let folder = try makeFolder(#"{"envSchema":{"clientPrefixes":["APP_"]}}"#)
		defer { try? FileManager.default.removeItem(atPath: folder) }
		_ = try ProjectEnvSchemaFile.apply(.init(description: .init(key: key, text: "Endpoint")), inFolder: folder, vaultID: vaultID)
		let document = try LPMConfigJSON(parsing: Data(contents(folder).utf8))
		#expect(document["envSchema"]?["vars"]?[key]?["client"] == .bool(true))
	}

	@Test("secret rename errors identify the public prefix", arguments: ["VITE_TOKEN", "APP_TOKEN", "react_app_token"])
	func secretRenameIdentifiesPublicPrefix(target: String) throws {
		let document = try LPMConfigJSON(parsing: Data(#"{"envSchema":{"clientPrefixes":["APP_"],"vars":{"TOKEN":{"secret":true}}}}"#.utf8))
		do {
			_ = try ProjectEnvSchemaFile.applying(.init(rename: .init(from: "TOKEN", to: target)), to: document)
			Issue.record("Expected secret rename rejection")
		} catch {
			#expect(error.localizedDescription.contains("Secret"))
			#expect(error.localizedDescription.contains(target == "APP_TOKEN" ? "APP_" : target == "VITE_TOKEN" ? "VITE_" : "REACT_APP_"))
		}
	}

	@Test("renames reclassify public rules", arguments: [false, true])
	func renamesReclassifyPublicRules(fromPublic: Bool) throws {
		let old = fromPublic ? "APP_API" : "API"
		let new = fromPublic ? "API" : "APP_API"
		let client = fromPublic ? #", "client":true"# : ""
		let folder = try makeFolder(#"{"envSchema":{"clientPrefixes":["APP_"],"vars":{"\#(old)":{"required":true\#(client)}}}}"#)
		defer { try? FileManager.default.removeItem(atPath: folder) }
		_ = try ProjectEnvSchemaFile.apply(.init(rename: .init(from: old, to: new)), inFolder: folder, vaultID: vaultID)
		let document = try LPMConfigJSON(parsing: Data(contents(folder).utf8))
		#expect(document["envSchema"]?["vars"]?[new]?["client"] == (fromPublic ? nil : .bool(true)))
		#expect(document["envSchema"]?["vars"]?[new]?["required"] == .bool(true))
	}

	@Test("integer bounds distinguish numeric negative zero from an exact string")
	func integerBoundsRejectNumericNegativeZero() throws {
		let folder = try makeFolder(#"{"envSchema":{"vars":{"COUNT":{"format":"integer","min":-0}}}}"#)
		defer { try? FileManager.default.removeItem(atPath: folder) }
		#expect(throws: ProjectEnvSchemaFile.FileError.invalidSchema) { try ProjectEnvSchemaFile.rules(inFolder: folder, vaultID: vaultID) }
		try #"{"envSchema":{"vars":{"COUNT":{"format":"integer","min":"-0"}}}}"#.write(toFile: folder + "/lpm.json", atomically: true, encoding: .utf8)
		#expect(try ProjectEnvSchemaFile.rules(inFolder: folder, vaultID: vaultID).keys == ["COUNT"])
	}

	private func makeFolder(_ lpmJSON: String?) throws -> String {
		let folder = FileManager.default.temporaryDirectory.appending(path: "lpm-schema-\(UUID().uuidString)").path
		try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
		if let lpmJSON { try lpmJSON.write(toFile: folder + "/lpm.json", atomically: true, encoding: .utf8) }
		return folder
	}

	private func contents(_ folder: String) throws -> String {
		try String(contentsOfFile: folder + "/lpm.json", encoding: .utf8)
	}
	@Test("constraint edits and sync preserve exact integer bounds and root groups")
	func constraintsPreserveExactMetadata() throws {
		let folder = FileManager.default.temporaryDirectory.appending(path: "env-constraints-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: folder) }
		let input = #"{"envSchema":{"vars":{"COUNT":{"format":"integer","min":9007199254740993,"max":"9223372036854775807","minLength":1,"maxLength":20,"requiredWhen":{"variable":"MODE","present":false}},"URL":{"format":"url","protocols":["https"]},"MODE":{}},"groups":{"auth":{"mode":"atLeastOne","vars":["COUNT","URL"]}}}}"#
		try input.write(to: folder.appendingPathComponent("lpm.json"), atomically: true, encoding: .utf8)
		_ = try ProjectEnvSchemaFile.apply(.init(description: .init(key: "COUNT", text: "Count")), inFolder: folder.path, vaultID: "project")
		guard case .object(let config)? = try ProjectEnvSchemaFile.validatedSyncConfig(inFolder: folder.path, vaultID: "project") else { Issue.record("Metadata must be retained"); return }
		let metadata = try LPMConfigJSON(parsing: JSONEncoder().encode(ProjectEnvSchemaFile.pushMetadata(from: config)))
		#expect(metadata["envSchema"]?["COUNT"]?["min"] == .string("9007199254740993"))
		#expect(metadata["envSchema"]?["COUNT"]?["max"] == .string("9223372036854775807"))
		#expect(metadata["envSchema"]?["COUNT"]?["minLength"] == .string("1"))
		#expect(metadata["envSchema"]?["COUNT"]?["maxLength"] == .string("20"))
		#expect(metadata["envSchema"]?["COUNT"]?["requiredWhen"]?["present"] == .bool(false))
		#expect(metadata["envSchemaConfig"]?["groups"]?["auth"]?["mode"] == .string("atLeastOne"))
	}

	@Test("renames update conditions and group members and clearing descriptions retains referenced declarations")
	func constraintReferencesFollowRenamesAndDescriptionEdits() throws {
		let folder = FileManager.default.temporaryDirectory.appending(path: "env-references-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: folder) }
		try #"{"envSchema":{"vars":{"SOURCE":{"description":"Source"},"TARGET":{"requiredWhen":{"variable":"SOURCE","present":true}}},"groups":{"g":{"mode":"allOrNone","vars":["SOURCE","TARGET"]}}}}"#.write(to: folder.appendingPathComponent("lpm.json"), atomically: true, encoding: .utf8)
		_ = try ProjectEnvSchemaFile.apply(.init(rename: .init(from: "SOURCE", to: "NEW"), description: .init(key: "NEW", text: "")), inFolder: folder.path, vaultID: "project")
		let data = try Data(contentsOf: folder.appendingPathComponent("lpm.json"))
		let document = try LPMConfigJSON(parsing: data)
		#expect(document["envSchema"]?["vars"]?["NEW"] == .object([]))
		#expect(document["envSchema"]?["vars"]?["TARGET"]?["requiredWhen"]?["variable"] == .string("NEW"))
		#expect(document["envSchema"]?["groups"]?["g"]?["vars"] == .array([.string("NEW"), .string("TARGET")]))
	}

	@Test("native metadata rejects unsafe or contradictory constraints", arguments: [
		#"{"vars":{"N":{"format":"integer","min":"9223372036854775808"}}}"#,
		#"{"vars":{"N":{"format":"integer","min":1.5}}}"#,
		#"{"vars":{"N":{"format":"integer","min":2,"max":1}}}"#,
		#"{"vars":{"N":{"minLength":2,"maxLength":1}}}"#,
		#"{"vars":{"N":{"maxLength":1.5}}}"#,
		#"{"vars":{"N":{"format":"url","protocols":["HTTPS"]}}}"#,
		#"{"vars":{"N":{"requiredWhen":{"variable":"UNKNOWN","present":true}}}}"#,
		#"{"vars":{"TOKEN":{"secret":true},"TARGET":{"requiredWhen":{"variable":"TOKEN","equals":"private-condition"}}}}"#,
		#"{"vars":{"N":{}},"groups":{"g":{"mode":"exactlyOne","vars":["N","N"]}}}"#,
	])
	func invalidConstraintMetadataFails(schema: String) throws {
		let document = try LPMConfigJSON(parsing: Data(("{\"envSchema\":" + schema + "}").utf8))
		#expect(throws: ProjectEnvSchemaFile.FileError.invalidSchema) { _ = try ProjectEnvSchemaFile.rules(of: document) }
	}

	@Test("native metadata accepts exact endpoints and multiline nonsecret equality")
	func exactConstraintEndpointsAndMultilineEqualityAreSupported() throws {
		let document = try LPMConfigJSON(parsing: Data(#"{"envSchema":{"vars":{"N":{"format":"integer","min":-9223372036854775808,"max":9223372036854775807},"SOURCE":{"default":"first\nsecond"},"TARGET":{"requiredWhen":{"variable":"SOURCE","equals":"first\nsecond"}}}}}"#.utf8))
		#expect(try ProjectEnvSchemaFile.rules(of: document).keys == ["N", "SOURCE", "TARGET"])
	}

	@Test("sync omits invalid alias and canonical environment names")
	func syncSkipsInvalidEnvironmentAliases() throws {
		let root: [String: LPMJSONValue] = ["env": .object([
			"test:unit": .string("config/unit.env"), "": .string(".env."),
			"bad": .string(".env.test:unit"), "unit": .string("config/unit.env")
		])]
		let metadata = try LPMConfigJSON(parsing: JSONEncoder().encode(ProjectEnvSchemaFile.pushMetadata(from: root)))
		#expect(metadata["envConfig"]?["test:unit"] == nil)
		#expect(metadata["envConfig"]?[""] == nil)
		#expect(metadata["envConfig"]?["bad"] == nil)
		#expect(metadata["envConfig"]?["unit"]?["canonical"] == .string("unit"))
	}

	@Test("sync aliases retain nested paths and declared environment precedence")
	func syncAliasesRetainNestedPathsAndPrecedence() throws {
		let folder = try makeFolder(
			#"{"env":{"show":"config/show.env","staging":".env.production"},"environments":{"staging":{"file":"config/staging.env"}}}"#
		)
		defer { try? FileManager.default.removeItem(atPath: folder) }
		guard
			case .object(let root)? = try ProjectEnvSchemaFile.validatedSyncConfig(
				inFolder: folder, vaultID: vaultID)
		else { Issue.record("Missing metadata"); return }
		let wire = try LPMConfigJSON(
			parsing: JSONEncoder().encode(ProjectEnvSchemaFile.pushMetadata(from: root)))
		#expect(wire["envConfig"]?["show"]?["canonical"] == .string("show"))
		#expect(wire["envConfig"]?["show"]?["file"] == .string("config/show.env"))
		#expect(wire["envConfig"]?["staging"]?["canonical"] == .string("staging"))
	}

    @Test("sync omits nonobject definitions and control characters in environment file paths")
    func syncOmitsMalformedEnvironmentDefinitionsAndPaths() throws {
        let root: [String: LPMJSONValue] = [
            "environments": .object([
                "null": .null, "number": .integer(1), "flag": .bool(true), "array": .array([]),
                "bad": .string("config/bad\n.env"),
                "structured": .object(["file": .string("config/bad\u{85}.env")]),
                "good": .string("config/good.env")
            ]),
            "env": .object(["bad": .string("config/bad\u{7f}.env"), "good": .string("config/good.env")])
        ]
        guard case .object(let wire) = ProjectEnvSchemaFile.pushMetadata(from: root),
              case .object(let environments)? = wire["environments"],
              case .object(let aliases)? = wire["envConfig"] else { Issue.record("Missing metadata"); return }
        #expect(Set(environments.keys) == ["good"])
        #expect(Set(aliases.keys) == ["good"])
    }

    @Test("sync omits invalid environment definitions and parents while retaining file shorthand")
    func syncOmitsInvalidEnvironmentDefinitions() throws {
        let root: [String: LPMJSONValue] = ["environments": .object([
            "test:unit": .string(".env.test"),
            "unit": .object(["file": .string("config/unit.env")]),
            "bad": .object(["extends": .string("test:unit")]),
            "base": .string(".env")
        ])]
        guard case .object(let metadata) = ProjectEnvSchemaFile.pushMetadata(from: root),
              case .object(let environments)? = metadata["environments"] else { Issue.record("Expected environments"); return }
        #expect(environments["test:unit"] == nil)
        #expect(environments["bad"] == nil)
        #expect(environments["unit"] == .object(["file": .string("config/unit.env")]))
        #expect(environments["base"] == .string(".env"))
    }

}
