import Darwin
import Foundation
import Testing

@testable import LPMVault

@Suite("lpm.json documents")
struct LPMConfigJSONTests {
	private func fixture(_ name: String) throws -> Data {
		try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/\(name)"))
	}

	/// The expected file was rendered by serde_json with the CLI's features after
	/// the same edit, so the app writes `lpm.json` exactly as the CLI would.
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

	private func makeFolder(_ lpmJSON: String?) throws -> String {
		let folder = FileManager.default.temporaryDirectory.appending(path: "lpm-schema-\(UUID().uuidString)").path
		try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
		if let lpmJSON { try lpmJSON.write(toFile: folder + "/lpm.json", atomically: true, encoding: .utf8) }
		return folder
	}

	private func contents(_ folder: String) throws -> String {
		try String(contentsOfFile: folder + "/lpm.json", encoding: .utf8)
	}
}
