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
		let token = Engine.Origin(source: "base.json", pointer: "/vars/TOKEN")
		#expect(resolution.replacedRules == ["TOKEN": .init(count: 1, origin: token, client: false, secret: token)])
		#expect(resolution.replacedGroups == ["pair": .init(count: 1, origin: .init(source: "base.json", pointer: "/groups/pair"))])
		#expect(resolution.groupDeclaringOrigins == ["pair": .init(source: "base.json", pointer: "/groups/pair")])
		#expect(resolution.clientPrefixOrigins["SHOP_"]?.source == "base.json", "A prefix lpm.json shares with an import names the import")
		#expect(resolution.clientPrefixOrigins["OWN_"]?.source == "lpm.json")
	}

	@Test("a resolve output whose provenance doesn't match its schema is rejected", arguments: [
		#"{"OTHER":{"count":1,"origin":{"source":"base.json","pointer":"/vars/OTHER"},"client":false}}"#,
		#"{"TOKEN":{"count":0,"origin":{"source":"base.json","pointer":"/vars/TOKEN"},"client":false}}"#,
		#"{"TOKEN":{"count":1,"client":false}}"#,
		#"{"TOKEN":{"count":1,"origin":{"source":"base.json","pointer":"/vars/TOKEN"},"client":false,"secret":{"source":"base.json"}}}"#,
	])
	func rejectsMismatchedReplacements(replaced: String) throws {
		#expect(throws: ProjectEnvSchemaFile.FileError.invalidSchema) { try Engine.resolved(from: try output(replaced: replaced)) }
	}

	@Test("prefix and group provenance has to name what the schema declares")
	func rejectsMismatchedOrigins() throws {
		#expect(throws: Never.self) { try Engine.resolved(from: try output()) }
		#expect(throws: ProjectEnvSchemaFile.FileError.invalidSchema) {
			try Engine.resolved(from: try output(prefixOrigins: #"{"OWN_":{"source":"lpm.json","pointer":"/envSchema/clientPrefixes/0"}}"#))
		}
		#expect(throws: ProjectEnvSchemaFile.FileError.invalidSchema) {
			try Engine.resolved(from: try output(groupDeclaring: #"{"missing":{"source":"base.json","pointer":"/groups/missing"}}"#))
		}
	}

	/// A resolve output for `TOKEN`, which lpm.json overrides, and `OTHER`, which base.json declares.
	private func output(
		replaced: String = #"{"TOKEN":{"count":1,"origin":{"source":"base.json","pointer":"/vars/TOKEN"},"client":false}}"#,
		prefixOrigins: String = #"{"OWN_":{"source":"lpm.json","pointer":"/envSchema/clientPrefixes/0"},"SHOP_":{"source":"base.json","pointer":"/clientPrefixes/0"}}"#,
		groupDeclaring: String = "{}"
	) throws -> LPMConfigJSON {
		try json(#"""
			{"abiVersion":1,"effective":{"vars":{"TOKEN":{},"OTHER":{}},"clientPrefixes":["OWN_","SHOP_"]},
			 "origins":{"TOKEN":{"source":"lpm.json","pointer":"/envSchema/overrides/TOKEN"},"OTHER":{"source":"base.json","pointer":"/vars/OTHER"}},
			 "groupOrigins":{},"declaringOrigins":{"TOKEN":{"source":"base.json","pointer":"/vars/TOKEN"}},
			 "groupDeclaringOrigins":\#(groupDeclaring),"clientPrefixOrigins":\#(prefixOrigins),"replacedVars":\#(replaced),"replacedGroups":{},
			 "dependencies":[],"fingerprint":""}
			"""#)
	}
}
