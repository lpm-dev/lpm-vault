import Darwin
import Foundation
import Testing
import os
@testable import LPMVault

@Suite("Composed env schema", .serialized)
struct EnvSchemaCompositionTests {
    @Test("installed package fragments refuse edits and explain root overrides", arguments: ["node_modules", "NODE_MODULES", "node_moduleſ"])
    func installedFragmentsAreReadOnly(component: String) throws {
        let root = try folder("{\"extends\":[\"\(component)/acme/base.json\"]}", fragment:"{}")
        defer { try? FileManager.default.removeItem(at:root) }
        let source = root.appendingPathComponent("\(component)/acme/base.json")
        try FileManager.default.createDirectory(at:source.deletingLastPathComponent(),withIntermediateDirectories:true)
        let bytes = Data(#"{"vars":{"A":{"description":"Old"}}}"#.utf8)
        try bytes.write(to:source)
        do {
            _ = try ProjectEnvSchemaFile.apply(.init(description:.init(key:"A",text:"New")),inFolder:root.path,vaultID:"project")
            Issue.record("Installed fragment must reject edits")
        } catch { #expect(error.localizedDescription.contains("overrides")) }
        #expect(try Data(contentsOf:source) == bytes)
        #expect(!FileManager.default.fileExists(atPath:source.deletingLastPathComponent().appendingPathComponent(".lpm").path))
    }

    @Test("fragment description edits preserve BOM indentation and escaped slash bytes")
    func fragmentDescriptionPreservesAuthoredBytes() throws {
        let text = "\u{FEFF}{\n    \"vars\": {\n        \"A\": {\n            \"description\": \"Old\",\n            \"default\": \"https:\\/\\/host\"\n        }\n    }\n}\n"
        let root = try folder(#"{"extends":["base.json"]}"#,fragment:text)
        defer { try? FileManager.default.removeItem(at:root) }
        _ = try ProjectEnvSchemaFile.apply(.init(description:.init(key:"A",text:"New")),inFolder:root.path,vaultID:"project")
        #expect(try Data(contentsOf:root.appendingPathComponent("base.json")) == Data(text.replacingOccurrences(of:"Old",with:"New").utf8))
    }

    @Test("fragment description insertion and removal preserve authored bytes", arguments: [#"{"default":"https:\/\/host"}"#, #"{}"#, #"{"description":"Old","default":"https:\/\/host"}"#, #"{"default":"https:\/\/host","description":"Old"}"#])
    func descriptionInsertionAndRemovalPreserveOtherTokens(rule: String) throws {
        let text = "\u{FEFF}{\n    \"vars\": {\n        \"A\": " + rule + "\n    }\n}\n"
        let root = try folder(#"{"extends":["base.json"]}"#, fragment: text)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("base.json")
        for description in ["New \"quoted\" é", ""] {
            _ = try ProjectEnvSchemaFile.apply(.init(description: .init(key: "A", text: description)), inFolder: root.path, vaultID: "project")
            let bytes = try Data(contentsOf: source)
            #expect(bytes.starts(with: [0xEF, 0xBB, 0xBF]))
            let value = try LPMConfigJSON(parsing: bytes)
            #expect(value["vars"]?["A"]?["description"] == (description.isEmpty ? nil : .string(description)))
            let authored = try String(contentsOf: source, encoding: .utf8)
            #expect(authored.contains("\n    \"vars\": {\n        \"A\":"))
            if rule.contains("default") { #expect(authored.contains(#"https:\/\/host"#)) }
        }
    }

    @Test("authored fragment directories do not receive project locks")
    func fragmentDirectoriesStayFreeOfProjectLocks() throws {
        let root = try folder(#"{"extends":["schemas/base.json"]}"#,fragment:"{}")
        defer { try? FileManager.default.removeItem(at:root) }
        let directory = root.appendingPathComponent("schemas")
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        try #"{"vars":{"A":{}}}"#.write(to:directory.appendingPathComponent("base.json"),atomically:true,encoding:.utf8)
        _ = try ProjectEnvSchemaFile.apply(.init(description:.init(key:"A",text:"New")),inFolder:root.path,vaultID:"project")
        #expect(!FileManager.default.fileExists(atPath:directory.appendingPathComponent(".lpm").path))
    }

    @Test("slash metadata size matches unescaped cloud JSON")
    func slashMetadataFitsCloudLimit() throws {
        let base = LPMJSONValue.object(["value":.string("")])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.withoutEscapingSlashes]
        let count = ProjectEnvSchemaFile.maximumMetadataBytes - (try encoder.encode(base).count)
        try ProjectEnvSchemaFile.validateMetadataSize(.object(["value":.string(String(repeating:"/",count:count))]))
        #expect(throws:ProjectEnvSchemaFile.FileError.metadataTooLarge) {
            try ProjectEnvSchemaFile.validateMetadataSize(.object(["value":.string(String(repeating:"/",count:count+1))]))
        }
    }

    @Test("inherited rename errors identify the declaring file")
    func inheritedRenameNamesDeclaringFile() throws {
        let root = try folder(#"{"extends":["base.json"]}"#,fragment:#"{"vars":{"A":{}}}"#)
        defer { try? FileManager.default.removeItem(at:root) }
        do {
            _ = try ProjectEnvSchemaFile.apply(.init(rename:.init(from:"A",to:"B")),inFolder:root.path,vaultID:"project")
            Issue.record("Inherited rename must fail")
        } catch { #expect(error.localizedDescription.contains("base.json")) }
    }

    @Test("fragment references prevent root renames with the declaring source", arguments: [false, true])
    func fragmentReferenceNamesDeclaringFile(group: Bool) throws {
        let fragment = group ? #"{"groups":{"pair":{"mode":"allOrNone","vars":["A","B"]}}}"# : #"{"vars":{"B":{"requiredWhen":{"variable":"A","equals":"yes"}}}}"#
        let schema = group ? #"{"extends":["base.json"],"vars":{"A":{},"B":{}}}"# : #"{"extends":["base.json"],"vars":{"A":{}}}"#
        let root = try folder(schema, fragment: fragment)
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = try Data(contentsOf: root.appendingPathComponent("lpm.json"))
        do {
            _ = try ProjectEnvSchemaFile.apply(.init(rename: .init(from: "A", to: "NEW")), inFolder: root.path, vaultID: "project")
            Issue.record("Referenced root key must reject renames")
        } catch { #expect(error.localizedDescription.contains("base.json")) }
        #expect(try Data(contentsOf: root.appendingPathComponent("lpm.json")) == bytes)
    }

	private func folder(_ schema: String, fragment: String) throws -> URL {
		let root = FileManager.default.temporaryDirectory.appending(path: "env-composition-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
		try ("{\"unrelated\":1e400,\"envSchema\":" + schema + "}").write(to: root.appendingPathComponent("lpm.json"), atomically: true, encoding: .utf8)
		try fragment.write(to: root.appendingPathComponent("base.json"), atomically: true, encoding: .utf8)
		return root
	}

    @Test("inherited and overridden descriptions compare authored Unicode bytes", arguments: [false, true])
    func descriptionFreshnessUsesExactBytes(overridden: Bool) throws {
        let schema = overridden ? #"{"extends":["base.json"],"overrides":{"A":{"description":"e\u0301"}}}"# : #"{"extends":["base.json"]}"#
        let root = try folder(schema, fragment:#"{"vars":{"A":{"description":"e\u0301"}}}"#)
        defer { try? FileManager.default.removeItem(at:root) }
        #expect(throws: ProjectEnvSchemaFile.FileError.changed) { try ProjectEnvSchemaFile.apply(.init(description:.init(key:"A",text:"new",expectedText:"é")),inFolder:root.path,vaultID:"project") }
        _ = try ProjectEnvSchemaFile.apply(.init(description:.init(key:"A",text:"e\u{0301}",expectedText:"stale")),inFolder:root.path,vaultID:"project")
    }

    @Test("renames classify against imported custom public prefixes")
    func renameUsesImportedPrefixes() throws {
        let root = try folder(#"{"extends":["base.json"],"vars":{"OLD":{}}}"#,fragment:#"{"clientPrefixes":["APP_"]}"#)
        defer { try? FileManager.default.removeItem(at:root) }
        for (from,to) in [("OLD","APP_URL"),("APP_URL","APP_OTHER"),("APP_OTHER","PRIVATE")] {
            _ = try ProjectEnvSchemaFile.apply(.init(rename:.init(from:from,to:to)),inFolder:root.path,vaultID:"project")
            let d = try LPMConfigJSON(parsing:Data(contentsOf:root.appendingPathComponent("lpm.json")))
            #expect(d["envSchema"]?["vars"]?[to]?["client"] == (to.hasPrefix("APP_") ? .bool(true) : nil))
        }
    }

    @Test("flat and composed metadata omit the same serde defaults")
    func flatAndComposedMetadataHaveParity() throws {
        let rule = #"{"ci":null,"min":null,"requiredWhen":null,"requiredIn":[],"defaultsIn":[],"secret":false}"#
        let flat = try folder("{\"vars\":{\"A\":" + rule + "}}",fragment:"{}")
        let composed = try folder(#"{"extends":["base.json"]}"#,fragment:"{\"vars\":{\"A\":" + rule + "}}")
        defer { try? FileManager.default.removeItem(at:flat); try? FileManager.default.removeItem(at:composed) }
        let a = try ProjectEnvSchemaFile.validatedSyncConfig(inFolder:flat.path,vaultID:"project")
        let b = try ProjectEnvSchemaFile.validatedSyncConfig(inFolder:composed.path,vaultID:"project")
        #expect(a == b)
    }

    @Test("sync refuses metadata over the cloud byte limit before capture")
    func syncRejectsOversizedMetadata() throws {
        let root = try folder("{\"vars\":{\"A\":{\"description\":\"" + String(repeating:"x",count:300*1024) + "\"}}}",fragment:"{}")
        defer { try? FileManager.default.removeItem(at:root) }
        #expect(throws:(any Error).self) { try ProjectEnvSchemaFile.validatedSyncConfig(inFolder:root.path,vaultID:"project") }
    }

    @Test("fragment freshness failures compensate persisted changes", arguments: [false, true])
    func fragmentFreshnessCompensates(noOp: Bool) throws {
        for changed in ["lpm.json","base.json","other.json","parent","parent-replacement"] {
            let root = try folder(#"{"extends":["schemas/base.json","other.json"]}"#,fragment:"{}")
            defer { try? FileManager.default.removeItem(at:root) }
            let parent = root.appendingPathComponent("schemas")
            try FileManager.default.createDirectory(at:parent,withIntermediateDirectories:true)
            let source = parent.appendingPathComponent("base.json")
            try #"{"vars":{"A":{"description":"Old"}}}"#.write(to:source,atomically:true,encoding:.utf8)
            try #"{"vars":{"B":{}}}"#.write(to:root.appendingPathComponent("other.json"),atomically:true,encoding:.utf8)
            let original = try Data(contentsOf:source)
            var persisted = 0; var restored = 0
            #expect(throws:(any Error).self) {
                _ = try ProjectEnvSchemaFile.edit(.init(description:.init(key:"A",text:noOp ? "Old" : "New")),at:root.appendingPathComponent("lpm.json"),vaultID:"project",beforeWrite:{
                    persisted += 1
                    if changed.hasPrefix("parent") {
                        let old = root.appendingPathComponent("retained")
                        try FileManager.default.moveItem(at:parent,to:old)
                        if changed == "parent" { try FileManager.default.createSymbolicLink(at:parent,withDestinationURL:old) }
                        else { try FileManager.default.createDirectory(at:parent,withIntermediateDirectories:true); try original.write(to:source) }
                    } else {
                        let target = changed == "base.json" ? source : root.appendingPathComponent(changed)
                        let current = try String(contentsOf:target,encoding:.utf8)
                        try (current + " ").write(to:target,atomically:true,encoding:.utf8)
                    }
                },onWriteFailure:{ restored += 1 })
            }
            #expect(persisted == 1); #expect(restored == 1)
            let after = try Data(contentsOf:source)
            #expect(after == (changed == "base.json" ? original + Data(" ".utf8) : original))
        }
    }

    @Test("nested fragment edits wait on the nearest project lock while holding the root lock", arguments: [false, true])
    func nestedFragmentLockOrdering(deeper: Bool) async throws {
        let root = try folder(deeper ? #"{"extends":["schemas/deeper/base.json"]}"# : #"{"extends":["schemas/base.json"]}"#,fragment:"{}")
        defer { try? FileManager.default.removeItem(at:root) }
        let parent = root.appendingPathComponent("schemas")
        try FileManager.default.createDirectory(at:parent.appendingPathComponent(".lpm"),withIntermediateDirectories:true)
        let target = deeper ? parent.appendingPathComponent("deeper") : parent
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try #"{"vars":{"A":{}}}"#.write(to:target.appendingPathComponent("base.json"),atomically:true,encoding:.utf8)
        try "{}".write(to:parent.appendingPathComponent("lpm.json"),atomically:true,encoding:.utf8)
        let lock = open(parent.appendingPathComponent(".lpm/.config.lock").path,O_RDWR|O_CREAT,0o644)
        defer { flock(lock,LOCK_UN); close(lock) }
        #expect(flock(lock,LOCK_EX) == 0)
        let completion = OSAllocatedUnfairLock(initialState:(finished:false,succeeded:false))
        Thread {
            do { _ = try ProjectEnvSchemaFile.apply(.init(description:.init(key:"A",text:"New")),inFolder:root.path,vaultID:"project"); completion.withLock { $0.succeeded = true } } catch {}
            completion.withLock { $0.finished = true }
        }.start()
        let deadline = ContinuousClock.now + .seconds(10)
        var rootIsLocked = false
        while ContinuousClock.now < deadline {
            let rootLock = open(root.appendingPathComponent(".lpm/.config.lock").path,O_RDWR)
            if rootLock >= 0 {
                if flock(rootLock,LOCK_EX|LOCK_NB) == 0 { flock(rootLock,LOCK_UN) }
                else { rootIsLocked = errno == EWOULDBLOCK }
                close(rootLock)
            }
            if rootIsLocked { break }
            try await Task.sleep(for:.milliseconds(10))
        }
        #expect(rootIsLocked)
        #expect(!completion.withLock { $0.finished })
        flock(lock,LOCK_UN)
        let completionDeadline = ContinuousClock.now + .seconds(10)
        var completed = false
        while ContinuousClock.now < completionDeadline {
            if completion.withLock({ $0.finished }) { completed = true; break }
            try await Task.sleep(for:.milliseconds(10))
        }
        #expect(completed)
        #expect(completion.withLock { $0.succeeded })
        if deeper { #expect(!FileManager.default.fileExists(atPath: target.appendingPathComponent(".lpm").path)) }
    }

    @Test("fragment output size is bounded before persistence")
    func fragmentRenderedOutputHasItsOwnLimit() throws {
        let root = try folder(#"{"extends":["base.json"]}"#,fragment:#"{"vars":{"A":{}}}"#)
        defer { try? FileManager.default.removeItem(at:root) }
        var persisted = false
        #expect(throws:ProjectEnvSchemaFile.FileError.tooLarge) {
            _ = try ProjectEnvSchemaFile.edit(.init(description:.init(key:"A",text:String(repeating:"x",count:2*1024*1024))),at:root.appendingPathComponent("lpm.json"),vaultID:"project",beforeWrite:{ persisted = true })
        }
        #expect(!persisted)
    }

    @Test("metadata limits count complete encoded bytes at the boundary")
    func metadataLimitCountsEncodedBytes() throws {
        for text in ["x", "é", "\\", "\n"] {
            let base = LPMJSONValue.object(["envConfig":.object(["alias":.string("custom")]),"value":.string("")])
            let overhead = try JSONEncoder().encode(base).count
            let width = try JSONEncoder().encode(LPMJSONValue.string(text)).count - 2
            let count = (ProjectEnvSchemaFile.maximumMetadataBytes - overhead) / width
            let valid = LPMJSONValue.object(["envConfig":.object(["alias":.string("custom")]),"value":.string(String(repeating:text,count:count))])
            try ProjectEnvSchemaFile.validateMetadataSize(valid)
            let invalid = LPMJSONValue.object(["envConfig":.object(["alias":.string("custom")]),"value":.string(String(repeating:text,count:count+1))])
            #expect(throws:ProjectEnvSchemaFile.FileError.metadataTooLarge) { try ProjectEnvSchemaFile.validateMetadataSize(invalid) }
        }
    }

    @Test("oversized metadata starts no personal or organization request")
    func oversizedMetadataStartsNoRequest() async {
        MetadataBudgetURLProtocol.requests.withLock { $0 = 0 }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MetadataBudgetURLProtocol.self]
        let session = URLSession(configuration:configuration,delegate:BoundedHTTPResponseDelegate(),delegateQueue:nil)
        defer { session.invalidateAndCancel() }
        let service = SyncService(session:session)
        let schema = LPMJSONValue.object(["description":.string(String(repeating:"x",count:300*1024))])
        let personal = await service.preparePushAuthenticated(authToken:"token",expectedPrincipalId:"account",vaultId:"project",encryptedBlob:"blob",wrappedKey:"key",schema:schema)
        _ = await personal.start().value()
        let organization = await service.preparePushOrgAuthenticated(authToken:"token",orgSlug:"team",expectedOrganizationID:"team-id",expectedCallerUserID:"account",vaultId:"project",encryptedBlob:"blob",wrappedKeys:nil,expectedVersion:nil,schema:schema)
        _ = await organization.start().value()
        #expect(MetadataBudgetURLProtocol.requests.withLock { $0 } == 0)
    }

    @Test("nested override descriptions edit the authored fragment only")
    func nestedOverrideDescriptionKeepsAuthoredOrigin() throws {
        let root = try folder(#"{"extends":["schemas/override.json"]}"#,fragment:#"{"vars":{"A":{}}}"#)
        defer { try? FileManager.default.removeItem(at:root) }
        try FileManager.default.createDirectory(at:root.appendingPathComponent("schemas"),withIntermediateDirectories:true)
        let fragment = root.appendingPathComponent("schemas/override.json")
        try #"{"extends":["../base.json"],"overrides":{"A":{"client":false,"default":null}}}"#.write(to:fragment,atomically:true,encoding:.utf8)
        let rootBytes = try Data(contentsOf:root.appendingPathComponent("lpm.json"))
        _ = try ProjectEnvSchemaFile.apply(.init(description:.init(key:"A",text:"New")),inFolder:root.path,vaultID:"project")
        let updated = try LPMConfigJSON(parsing:Data(contentsOf:fragment))
        #expect(updated["overrides"]?["A"]?["client"] == .bool(false))
        #expect(updated["overrides"]?["A"]?["default"] == .null)
        #expect(updated["overrides"]?["A"]?["description"] == .string("New"))
        #expect(try Data(contentsOf:root.appendingPathComponent("lpm.json")) == rootBytes)
    }

    @Test("multi-file rename and description edits reject before persistence")
    func multiFileEditsRejectBeforePersistence() throws {
        let root = try folder(#"{"extends":["base.json"],"vars":{"OLD":{}}}"#,fragment:#"{"vars":{"A":{}}}"#)
        defer { try? FileManager.default.removeItem(at:root) }
        var persisted = false
        #expect(throws:ProjectEnvSchemaFile.FileError.multipleSourceEdit) {
            _ = try ProjectEnvSchemaFile.edit(.init(rename:.init(from:"OLD",to:"NEW"),description:.init(key:"A",text:"New")),at:root.appendingPathComponent("lpm.json"),vaultID:"project",beforeWrite:{ persisted = true })
        }
        #expect(!persisted)
    }

    @Test("root transactions classify deeply nested JSON as an input error")
    func deepRootJSONHasTypedInputError() throws {
        let root = try folder(#"{}"#,fragment:"{}")
        defer { try? FileManager.default.removeItem(at:root) }
        let invalid = "{\"other\":" + String(repeating:"[",count:1024) + "0" + String(repeating:"]",count:1024) + "}"
        try invalid.write(to:root.appendingPathComponent("lpm.json"),atomically:true,encoding:.utf8)
        #expect(throws:ProjectEnvSchemaFile.FileError.invalidJSON) { try ProjectEnvSchemaFile.apply(.init(description:.init(key:"A",text:"New")),inFolder:root.path,vaultID:"project") }
    }

	@Test("inherited descriptions edit their authored rule and retain inheritance")
	func inheritedDescriptionRetainsAuthoredOrigin() throws {
		let fragment = #"{"vars":{"TOKEN":{"description":null},"MODE":{}},"groups":{"pair":{"mode":"allOrNone","vars":["TOKEN","MODE"]}}}"#
		let root = try folder(#"{"extends":["base.json"]}"#, fragment: fragment)
		defer { try? FileManager.default.removeItem(at: root) }
		let original = try Data(contentsOf: root.appendingPathComponent("lpm.json"))
		_ = try ProjectEnvSchemaFile.apply(.init(description: .init(key: "TOKEN", text: "Access token")), inFolder: root.path, vaultID: "project")
		#expect(try Data(contentsOf: root.appendingPathComponent("lpm.json")) == original)
		var document = try LPMConfigJSON(parsing: Data(contentsOf: root.appendingPathComponent("base.json")))
		#expect(document["vars"]?["TOKEN"]?["description"] == .string("Access token"))
		var vars = try #require(document["vars"])
		var token = try #require(vars["TOKEN"])
		token.set(.bool(true), forKey: "secret")
		token.set(.bool(true), forKey: "required")
		vars.set(token, forKey: "TOKEN"); document.set(vars, forKey: "vars")
		try (document.rendered() + "\n").write(to: root.appendingPathComponent("base.json"), atomically: true, encoding: .utf8)
		_ = try ProjectEnvSchemaFile.apply(.init(description: .init(key: "TOKEN", text: "")), inFolder: root.path, vaultID: "project")
		let metadata = try #require(try ProjectEnvSchemaFile.validatedSyncConfig(inFolder: root.path, vaultID: "project"))
		let wire = try LPMConfigJSON(parsing: JSONEncoder().encode(metadata))
		#expect(wire["envSchema"]?["vars"]?["TOKEN"]?["secret"] == .bool(true))
		#expect(wire["envSchema"]?["vars"]?["TOKEN"]?["required"] == .bool(true))
		#expect(wire["envSchema"]?["vars"]?["TOKEN"]?["description"] == nil)
		#expect(try Data(contentsOf: root.appendingPathComponent("lpm.json")) == original)
	}

	@Test("description edits preserve authored override tokens")
	func descriptionsPreserveAuthoredOverrideTokens() throws {
		let root = try folder(#"{"extends":["base.json"],"overrides":{"N":{"format":"integer","min":-1,"max":"9223372036854775807","required":false,"default":null}}}"#, fragment: #"{"vars":{"N":{}}}"#)
		defer { try? FileManager.default.removeItem(at: root) }
		_ = try ProjectEnvSchemaFile.apply(.init(description: .init(key: "N", text: "Count")), inFolder: root.path, vaultID: "project")
		let document = try LPMConfigJSON(parsing: Data(contentsOf: root.appendingPathComponent("lpm.json")))
		let rule = try #require(document["envSchema"]?["overrides"]?["N"])
		#expect(rule["min"] == .number("-1"))
		#expect(rule["required"] == .bool(false))
		#expect(rule["default"] == .null)
		#expect(rule["secret"] == nil)
	}

	@Test("preset declarations refuse description edits without creating overrides")
	func presetsRefuseDescriptionEdits() throws {
		let root = try folder(#"{"extends":["preset:node"]}"#, fragment: #"{}"#)
		defer { try? FileManager.default.removeItem(at: root) }
		let original = try Data(contentsOf: root.appendingPathComponent("lpm.json"))
		#expect(throws: (any Error).self) { try ProjectEnvSchemaFile.apply(.init(description: .init(key: "NODE_ENV", text: "Mode")), inFolder: root.path, vaultID: "project") }
		#expect(try Data(contentsOf: root.appendingPathComponent("lpm.json")) == original)
	}

	@Test("preset renames identify the read-only declaration and a usable recovery")
	func presetRenamesExplainReadOnlyDeclaration() throws {
		let root = try folder(#"{"extends":["preset:node"]}"#, fragment: #"{}"#)
		defer { try? FileManager.default.removeItem(at: root) }
		let original = try Data(contentsOf: root.appendingPathComponent("lpm.json"))
		do {
			_ = try ProjectEnvSchemaFile.apply(.init(rename: .init(from: "NODE_ENV", to: "MODE")), inFolder: root.path, vaultID: "project")
			Issue.record("Preset rename must reject")
		} catch {
			#expect(error.localizedDescription.contains("preset:node"))
			#expect(error.localizedDescription.contains("separate local key"))
			#expect(!error.localizedDescription.contains("declaring file"))
		}
		#expect(try Data(contentsOf: root.appendingPathComponent("lpm.json")) == original)
	}

	@Test("renames rewrite conditions and members in authored overrides")
	func renamesRewriteOverrideReferences() throws {
		let root = try folder(#"{"extends":["base.json"],"vars":{"OLD":{}},"overrides":{"TARGET":{"requiredWhen":{"variable":"OLD","present":true}}},"groupOverrides":{"pair":{"mode":"allOrNone","vars":["OLD","TARGET"]}}}"#, fragment: #"{"vars":{"TARGET":{}},"groups":{"pair":{"mode":"allOrNone","vars":["TARGET"]}}}"#)
		defer { try? FileManager.default.removeItem(at: root) }
		_ = try ProjectEnvSchemaFile.apply(.init(rename: .init(from: "OLD", to: "NEW")), inFolder: root.path, vaultID: "project")
		let document = try LPMConfigJSON(parsing: Data(contentsOf: root.appendingPathComponent("lpm.json")))
		#expect(document["envSchema"]?["overrides"]?["TARGET"]?["requiredWhen"]?["variable"] == .string("NEW"))
		#expect(document["envSchema"]?["groupOverrides"]?["pair"]?["vars"] == .array([.string("NEW"),.string("TARGET")]))
	}

	@Test("composed empty rules fit the cloud metadata byte limit")
	func composedEmptyRulesFitCloudMetadataLimit() throws {
		let vars = (0..<4096).map { "\"K\($0)\":{}" }.joined(separator: ",")
		let root = try folder(#"{"extends":["base.json"]}"#, fragment: "{\"vars\":{" + vars + "}}")
		defer { try? FileManager.default.removeItem(at: root) }
		let config = try #require(try ProjectEnvSchemaFile.validatedSyncConfig(inFolder: root.path, vaultID: "project"))
		guard case .object(let fields) = config else { Issue.record("Expected metadata"); return }
		let wire = ProjectEnvSchemaFile.pushMetadata(from: fields)
		#expect(try JSONEncoder().encode(wire).count < 256 * 1024)
		let document = try LPMConfigJSON(parsing: JSONEncoder().encode(wire))
		#expect(document["envSchema"]?["K0"] == .object([]))
		#expect(document["envSchemaConfig"] == nil)
	}

	@Test("inherited renames and collisions with imported targets reject before writes", arguments: [
		(#"{"extends":["base.json"]}"#, "INHERITED", "NEW"),
		(#"{"extends":["base.json"],"vars":{"LOCAL":{}}}"#, "LOCAL", "INHERITED"),
		(#"{"extends":["base.json"],"overrides":{"INHERITED":{}}}"#, "INHERITED", "NEW"),
	])
	func inheritedRenameRejects(schema: String, from: String, to: String) throws {
		let root = try folder(schema, fragment: #"{"vars":{"INHERITED":{}}}"#)
		defer { try? FileManager.default.removeItem(at: root) }
		let original = try Data(contentsOf: root.appendingPathComponent("lpm.json"))
		do {
			_ = try ProjectEnvSchemaFile.apply(.init(rename: .init(from: from, to: to)), inFolder: root.path, vaultID: "project")
			Issue.record("Inherited declarations and target collisions must reject")
		} catch {
			let message = error.localizedDescription
			if schema.contains("overrides") {
				#expect(message.contains("imported schema"))
				#expect(message.contains("root override"))
			} else if from == "LOCAL" {
				#expect(message.contains("target key INHERITED"))
				#expect(message.contains("base.json"))
			} else { #expect(message.contains("base.json")) }
		}
		#expect(try Data(contentsOf: root.appendingPathComponent("lpm.json")) == original)
	}

	@Test("no-op changes retain one lightweight snapshot that still detects source changes")
	func noOpUsesOneFreshnessHandle() throws {
		let root = try folder(#"{"extends":["base.json"]}"#, fragment: #"{"vars":{"A":{}}}"#)
		defer { try? FileManager.default.removeItem(at: root) }
		let document = try LPMConfigJSON(parsing: Data(contentsOf: root.appendingPathComponent("lpm.json")))
		let (updated, rules, snapshots) = try ProjectEnvSchemaFile.validatedChange(.init(), in: document, vaultID: "project", folder: root.path)
		#expect(updated == document)
		#expect(rules.keys == ["A"])
		#expect(snapshots.count == 1)
		try snapshots[0].verify()
		try #"{"vars":{"A":{"required":true}}}"#.write(to: root.appendingPathComponent("base.json"), atomically: true, encoding: .utf8)
		#expect(throws: ProjectEnvSchemaFile.FileError.changed) { try snapshots[0].verify() }
	}

	@Test("a changed fragment compensates persistence before replacement or no-op completion", arguments: [false, true])
	func changedSourceCompensatesPersistence(noOp: Bool) throws {
		let root = try folder(#"{"extends":["base.json"],"vars":{"LOCAL":{}}}"#, fragment: #"{"vars":{"A":{}}}"#)
		defer { try? FileManager.default.removeItem(at: root) }
		let url = root.appendingPathComponent("lpm.json")
		let original = try Data(contentsOf: url)
		var snapshots: [RustSchemaEngine.Snapshot] = []
		var persists = 0
		var compensations = 0
		#expect(throws: ProjectEnvSchemaFile.FileError.changed) {
			try ProjectConfigFile.update(at: url, rejectDuplicateKeys: true, validateSources: {
				for snapshot in snapshots { try snapshot.verify() }
			}, beforeWrite: {
				persists += 1
				try #"{"vars":{"A":{"required":true}}}"#.write(to: root.appendingPathComponent("base.json"), atomically: true, encoding: .utf8)
			}, onWriteFailure: { compensations += 1 }) { document in
				let change = noOp ? ProjectEnvSchemaFile.Change() : .init(description: .init(key: "LOCAL", text: "Changed"))
				let (updated, _, sources) = try ProjectEnvSchemaFile.validatedChange(change, in: document, vaultID: "project", folder: root.path)
				snapshots = sources
				document = updated
			}
		}
		#expect(persists == 1)
		#expect(compensations == 1)
		#expect(try Data(contentsOf: url) == original)
	}

	@Test("retargeting a selected project link invalidates the native snapshot")
	func selectedFolderAliasRetargetRejects() throws {
		let first = try folder(#"{"extends":["base.json"]}"#, fragment: #"{"vars":{"A":{}}}"#)
		let second = try folder(#"{"extends":["base.json"]}"#, fragment: #"{"vars":{"A":{}}}"#)
		let link = first.deletingLastPathComponent().appending(path: "selected-\(UUID().uuidString)")
		defer { try? FileManager.default.removeItem(at: link); try? FileManager.default.removeItem(at: first); try? FileManager.default.removeItem(at: second) }
		try FileManager.default.createSymbolicLink(at: link, withDestinationURL: first)
		let schema = try LPMConfigJSON(parsing: Data(#"{"extends":["base.json"]}"#.utf8))
		let resolved = try RustSchemaEngine.resolve(schema, inFolder: link.path)
		try resolved.verify()
		try FileManager.default.removeItem(at: link)
		try FileManager.default.createSymbolicLink(at: link, withDestinationURL: second)
		#expect(throws: ProjectEnvSchemaFile.FileError.changed) { try resolved.verify() }
	}

	@Test("compact rendering preserves escaped Unicode and exact numbers within its byte limit")
	func compactRenderingIsLosslessAndBounded() throws {
		let document = try LPMConfigJSON(parsing: Data(#"{"n":9223372036854775807,"huge":1e400,"text":"é🎉\n\u001f","array":[true,null,{}]}"#.utf8))
		let output = try document.compactData(maximumBytes: 4096)
		#expect(!String(decoding: output, as: UTF8.self).contains("\n"))
		#expect(try LPMConfigJSON(parsing: output) == document)
		#expect(try document.compactData(maximumBytes: output.count) == output)
		#expect(throws: LPMConfigJSON.RenderError.tooLarge) { try document.compactData(maximumBytes: output.count - 1) }
	}
	@Test("sync rejects a replaced manifest even when imported files stay unchanged")
	func syncDetectsRootReplacement() throws {
		let root = try folder(#"{"extends":["base.json"]}"#, fragment: #"{"vars":{"A":{}}}"#)
		defer { try? FileManager.default.removeItem(at: root) }
		#expect(throws: ProjectEnvSchemaFile.FileError.changed) {
			try ProjectEnvSchemaFile.validatedSyncConfig(inFolder: root.path, vaultID: "project", beforeVerification: {
				try! #"{"vault":"other","envSchema":{"vars":{"B":{}}}}"#.write(to: root.appendingPathComponent("lpm.json"), atomically: true, encoding: .utf8)
			})
		}
	}

	@Test("a retargeted folder cannot edit a second project while holding the first project's lock")
	func transactionRejectsRetargetBeforeResolution() throws {
		let first = try folder(#"{"extends":["base.json"],"vars":{"LOCAL":{}}}"#, fragment: #"{"vars":{"A":{}}}"#)
		let second = try folder(#"{"extends":["base.json"],"vars":{"LOCAL":{}}}"#, fragment: #"{"vars":{"A":{}}}"#)
		let link = first.deletingLastPathComponent().appending(path: "selected-\(UUID().uuidString)")
		defer { try? FileManager.default.removeItem(at: link); try? FileManager.default.removeItem(at: first); try? FileManager.default.removeItem(at: second) }
		try FileManager.default.createSymbolicLink(at: link, withDestinationURL: first)
		let original = try Data(contentsOf: first.appendingPathComponent("lpm.json"))
		var snapshots: [RustSchemaEngine.Snapshot] = []
		var persisted = false
		#expect(throws: ProjectConfigFile.FileError.changed) {
			try ProjectConfigFile.update(at: link.appendingPathComponent("lpm.json"), rejectDuplicateKeys: true, validateSources: {
				for snapshot in snapshots { try snapshot.verify() }
			}, beforeWrite: { persisted = true }) { document in
				try FileManager.default.removeItem(at: link)
				try FileManager.default.createSymbolicLink(at: link, withDestinationURL: second)
				let (updated, _, sources) = try ProjectEnvSchemaFile.validatedChange(.init(description: .init(key: "LOCAL", text: "Changed")), in: document, vaultID: "project", folder: link.path)
				snapshots = sources
				document = updated
			}
		}
		#expect(!persisted)
		#expect(try Data(contentsOf: first.appendingPathComponent("lpm.json")) == original)
		#expect(try Data(contentsOf: second.appendingPathComponent("lpm.json")) == original)
	}

	@Test("anchored replacement writes to the retained directory after a late alias retarget")
	func anchoredWriterKeepsItsOriginalDirectory() throws {
		let first = try folder(#"{"vars":{}}"#, fragment: #"{"vars":{}}"#)
		let second = try folder(#"{"vars":{}}"#, fragment: #"{"vars":{}}"#)
		let link = first.deletingLastPathComponent().appending(path: "selected-\(UUID().uuidString)")
		defer { try? FileManager.default.removeItem(at: link); try? FileManager.default.removeItem(at: first); try? FileManager.default.removeItem(at: second) }
		try FileManager.default.createSymbolicLink(at: link, withDestinationURL: first)
		let descriptor = open(link.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
		#expect(descriptor >= 0)
		defer { _ = close(descriptor) }
		let original = try Data(contentsOf: second.appendingPathComponent("lpm.json"))
		let updated = Data(#"{"changed":true}"#.utf8)
		try SecureFileWriter.write(updated, to: link.appendingPathComponent("lpm.json"), beforeReplacement: {
			try FileManager.default.removeItem(at: link)
			try FileManager.default.createSymbolicLink(at: link, withDestinationURL: second)
		}, directoryDescriptor: descriptor)
		#expect(try Data(contentsOf: first.appendingPathComponent("lpm.json")) == updated)
		#expect(try Data(contentsOf: second.appendingPathComponent("lpm.json")) == original)
	}

}

@MainActor
@Suite("Optional linked sync metadata")
struct LinkedSyncMetadataTests {
	@Test("a missing linked folder omits sync metadata")
	func missingLinkedFolderOmitsSyncMetadata() async throws {
		let store = VaultStore(keychainService: MockKeychainService(), biometricService: MockBiometricService(), apiService: MockAPIService())
		let project = VaultProject(id: "project", name: "Project", path: FileManager.default.temporaryDirectory.appending(path: "missing-\(UUID().uuidString)").path, environments: [:])
		#expect(try await store.syncSchema(for: project) == nil)
	}
}

private final class MetadataBudgetURLProtocol: URLProtocol {
    static let requests = OSAllocatedUnfairLock(initialState:0)
    override class func canInit(with request:URLRequest) -> Bool { true }
    override class func canonicalRequest(for request:URLRequest) -> URLRequest { request }
    override func startLoading() { Self.requests.withLock { $0 += 1 }; client?.urlProtocol(self,didFailWithError:URLError(.cancelled)) }
    override func stopLoading() {}
}
