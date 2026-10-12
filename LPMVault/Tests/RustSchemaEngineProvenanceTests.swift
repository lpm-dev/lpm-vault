import Foundation
import Testing

@testable import LPMVault

@Suite("Engine provenance")
struct RustSchemaEngineProvenanceTests {
	private typealias Engine = RustSchemaEngine

	private func json(_ text: String) throws -> LPMConfigJSON {
		try LPMConfigJSON(parsing: Data(text.utf8), rejectDuplicateKeys: true)
	}

	@Test("a resolution says where overridden groups and prefixes come from, and sums up what each override replaces")
	func provenance() throws {
		let folder = FileManager.default.temporaryDirectory.appending(path: "engine-provenance-\(UUID().uuidString)").path
		try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(atPath: folder) }
		try #"{"clientPrefixes":["SHOP_"],"vars":{"TOKEN":{"secret":true},"SHOP_ID":{"client":true},"OTHER":{}},"groups":{"pair":{"mode":"allOrNone","vars":["TOKEN","OTHER"]}}}"#
			.write(toFile: folder + "/base.json", atomically: true, encoding: .utf8)
		let resolution = try Engine.resolve(try json(#"""
			{"extends":["base.json"],"clientPrefixes":["SHOP_","OWN_"],"overrides":{"TOKEN":{"required":true}},
			 "groupOverrides":{"pair":{"mode":"exactlyOne","vars":["TOKEN","OTHER"]}}}
			"""#), inFolder: folder)
		#expect(resolution.replacedRules == ["TOKEN": .init(count: 1, source: "base.json", client: false, secret: "base.json")])
		#expect(resolution.replacedGroups == ["pair": .init(count: 1, source: "base.json")])
		#expect(resolution.groupDeclaringSources == ["pair": "base.json"])
		#expect(resolution.clientPrefixSources == ["SHOP_": "base.json", "OWN_": "lpm.json"], "A prefix lpm.json shares with an import names the import")
	}

	@Test("a schema whose output fits the engine's budget without provenance resolves with it, past that budget")
	func provenancePastTheBudget() throws {
		let folder = FileManager.default.temporaryDirectory.appending(path: "engine-provenance-\(UUID().uuidString)").path
		let directory = String(repeating: "f", count: 250)
		try FileManager.default.createDirectory(atPath: folder + "/" + directory, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(atPath: folder) }
		let path = directory + "/" + String(repeating: "i", count: 244) + ".json"
		let names = (0..<4096).map { index in "K" + String(repeating: "0", count: 255 - String(index).count) + String(index) }
		func rules(_ rule: String) -> String { names.map { "\"\($0)\":\(rule)" }.joined(separator: ",") }
		try #"{"vars":{\#(rules(#"{"secret":true}"#))}}"#.write(toFile: folder + "/" + path, atomically: true, encoding: .utf8)
		let resolution = try Engine.resolve(try json(#"{"extends":["\#(path)"],"overrides":{\#(rules("{}"))}}"#), inFolder: folder)
		#expect(resolution.replacedRules.count == 4096)
		#expect(resolution.replacedRules[names[0]] == .init(count: 1, source: path, client: false, secret: path))
	}

	@Test("a resolve output whose provenance doesn't match its schema is rejected", arguments: [
		#"{"OTHER":{"count":1,"origin":0,"client":false}}"#,
		#"{"TOKEN":{"count":0,"origin":0,"client":false}}"#,
		#"{"TOKEN":{"count":1,"client":false}}"#,
		#"{"TOKEN":{"count":1,"origin":0,"client":false,"secret":2}}"#,
		#"{"TOKEN":{"count":1,"origin":-1,"client":false}}"#,
		#"{"TOKEN":{"count":1,"origin":"0","client":false}}"#,
	])
	func rejectsMismatchedReplacements(replaced: String) throws {
		#expect(throws: ProjectEnvSchemaFile.FileError.invalidSchema) { try Engine.resolved(from: try output(replaced: replaced)) }
	}

	@Test("prefix and group provenance has to name what the schema declares")
	func rejectsMismatchedOrigins() throws {
		#expect(throws: Never.self) { try Engine.resolved(from: try output()) }
		#expect(throws: ProjectEnvSchemaFile.FileError.invalidSchema) { try Engine.resolved(from: try output(prefixOrigins: #"{"OWN_":1}"#)) }
		#expect(throws: ProjectEnvSchemaFile.FileError.invalidSchema) { try Engine.resolved(from: try output(groupDeclaring: #"{"missing":0}"#)) }
		#expect(throws: ProjectEnvSchemaFile.FileError.invalidSchema) { try Engine.resolved(from: try output(sources: #"["base.json",1]"#)) }
		#expect(throws: ProjectEnvSchemaFile.FileError.invalidSchema) { try Engine.resolved(from: try output(sources: #"["base.json"]"#)) }
	}

	/// A resolve output for `TOKEN`, which lpm.json overrides, and `OTHER`, which base.json declares.
	private func output(
		sources: String = #"["base.json","lpm.json"]"#,
		replaced: String = #"{"TOKEN":{"count":1,"origin":0,"client":false}}"#,
		prefixOrigins: String = #"{"OWN_":1,"SHOP_":0}"#,
		groupDeclaring: String = "{}"
	) throws -> LPMConfigJSON {
		try json(#"""
			{"abiVersion":1,"effective":{"vars":{"TOKEN":{},"OTHER":{}},"clientPrefixes":["OWN_","SHOP_"]},
			 "origins":{"TOKEN":{"source":"lpm.json","pointer":"/envSchema/overrides/TOKEN"},"OTHER":{"source":"base.json","pointer":"/vars/OTHER"}},
			 "groupOrigins":{},"declaringOrigins":{"TOKEN":{"source":"base.json","pointer":"/vars/TOKEN"}},
			 "sources":\#(sources),"groupDeclaringOrigins":\#(groupDeclaring),"clientPrefixOrigins":\#(prefixOrigins),"replacedVars":\#(replaced),"replacedGroups":{},
			 "dependencies":[],"fingerprint":""}
			"""#)
	}
}
