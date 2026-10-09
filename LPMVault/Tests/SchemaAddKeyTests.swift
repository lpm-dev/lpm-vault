import AppKit
import SwiftUI
import Testing

@testable import LPMVault

@Suite("Schema suggestions")
struct SchemaSuggestionTests {
	typealias Suggestion = ProjectEnvSchemaSuggestion

	private func titles(_ key: String, _ values: [String], publicPrefix: String? = nil) -> [String] {
		Suggestion.suggestions(for: key, values: values, publicPrefix: publicPrefix).map(\.title)
	}

	@Test("values the engine accepts as one format suggest it, naming the evidence and never a value", arguments: [
		("SENTRY_DSN", ["https://a@o1.ingest.sentry.io/1", "https://b@o1.ingest.sentry.io/2"], ["URL", "https only"], "both values are URLs"),
		("REDIS_URL", ["redis://localhost:6379", "redis://cache:6379", "redis://cache.internal:6379"], ["URL", "redis only"], "all 3 values are URLs"),
		("CACHE_PORT", ["6379", "6380", "6381"], ["Port"], "all 3 values are whole numbers from 1 to 65535"),
		("WORKERS", ["4", "8"], ["Integer"], "both values are whole numbers"),
		("FEATURE_ENABLED", ["true", "false"], ["Boolean"], "both values are booleans"),
		("SUPPORT_EMAIL", ["help@example.com"], ["Email"], "the value is an email address"),
		("DB_HOST", ["db.internal", "db.example.com"], ["Hostname"], "both values are hostnames"),
	])
	func formats(key: String, values: [String], expected: [String], evidence: String) {
		let found = Suggestion.suggestions(for: key, values: values, publicPrefix: nil)
		#expect(found.map(\.title) == expected)
		#expect(found.first?.evidence == evidence)
		#expect(!found.contains { suggestion in values.contains { suggestion.evidence.contains($0) } })
	}

	@Test("a number isn't a port unless the name says so, and 1 and 0 are numbers first")
	func numbers() {
		#expect(titles("RETRIES", ["3"]) == ["Integer"])
		#expect(titles("DEBUG", ["1", "0"]) == ["Integer"])
	}

	@Test("secrets are suggested from the name or random values, never for URLs or public keys")
	func secrets() {
		#expect(titles("STRIPE_WEBHOOK_SECRET", ["whsec_short"]) == ["Secret"])
		#expect(titles("SESSION_SALT", ["k3J9x2Lq8vR4mP7wZ1nB5cT6"]) == ["Secret"])
		#expect(Suggestion.suggestions(for: "SESSION_SALT", values: ["k3J9x2Lq8vR4mP7wZ1nB5cT6"], publicPrefix: nil).first?.evidence == "the value looks random")
		#expect(titles("SENTRY_DSN", ["https://k3J9x2Lq8vR4mP7wZ1nB5cT6@sentry.io/1"]) == ["URL", "https only"])
		#expect(titles("NEXT_PUBLIC_TOKEN", ["k3J9x2Lq8vR4mP7wZ1nB5cT6"], publicPrefix: "NEXT_PUBLIC_").isEmpty)
		#expect(titles("GREETING", ["hello world"]).isEmpty)
	}

	@Test("accepting a suggestion applies its rule, and undo takes it back")
	func applyAndUndo() {
		var rule = ProjectEnvSchemaRule()
		let protocols = Suggestion(change: .protocols(["redis"]), evidence: "")
		protocols.apply(to: &rule)
		#expect(rule.format == .url)
		#expect(rule.protocols == ["redis"])
		#expect(protocols.isApplied(in: rule))
		protocols.undo(in: &rule)
		#expect(rule.protocols == nil)
		#expect(rule.format == .url)
	}
}

@Suite("Stored keys lpm.json doesn't declare", .serialized)
@MainActor
struct UndeclaredSchemaKeyTests {
	@Test("stored keys are listed unless lpm.json, an import, or the draft declares them, from A to Z with how many environments store them")
	func undeclaredKeys() async throws {
		let folder = FileManager.default.temporaryDirectory.appending(path: "undeclared-\(UUID().uuidString)").path
		try FileManager.default.createDirectory(atPath: folder + "/schemas", withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(atPath: folder) }
		try #"{"envSchema":{"extends":["schemas/base.json"],"vars":{"PORT":{},"OLD":{}}}}"#.write(toFile: folder + "/lpm.json", atomically: true, encoding: .utf8)
		try #"{"vars":{"DATABASE_URL":{}}}"#.write(toFile: folder + "/schemas/base.json", atomically: true, encoding: .utf8)
		let environments = [
			"default": ["PORT": "1", "OLD": "x", "DATABASE_URL": "d", "KEY_10": "a", "KEY_2": "b", "SMTP_HOST": "h"],
			"staging": ["KEY_2": "c"],
		]
		let keychain = MockKeychainService()
		keychain.envStorage["project"] = (name: "Project", path: folder, environments: environments)
		let preferences = try #require(UserDefaults(suiteName: "undeclared-\(UUID().uuidString)"))
		let store = VaultStore(keychainService: keychain, biometricService: MockBiometricService(), apiService: MockAPIService(), preferences: preferences)
		defer { store.lock() }
		store.projects = [VaultProject(id: "project", name: "Project", path: folder, environments: environments)]
		store.isUnlocked = true
		store.selectedProjectId = "project"
		store.reloadKeyDescriptions()
		for _ in 0..<1000 where store.keyDescriptions["project"]?.schema?.overview == nil { try await Task.sleep(for: .milliseconds(5)) }
		#expect(store.undeclaredSchemaKeys(for: "project") == [.init(key: "KEY_2", environments: 2), .init(key: "KEY_10", environments: 1), .init(key: "SMTP_HOST", environments: 1)])

		store.editSchemaDraft(in: "project") {
			$0.set(.declared(.object([])), for: .key("SMTP_HOST"))
			$0.set(.absent, for: .key("OLD"))
		}
		#expect(store.undeclaredSchemaKeys(for: "project").map(\.key) == ["KEY_2", "KEY_10"], "Keys the draft declares or removes aren't listed")
	}
}

extension SheetInteractionTests {
	@Suite("Adding and declaring keys", .serialized)
	@MainActor
	struct SchemaAddKeyInteractionTests {
		static let sample = #"""
			{"envSchema":{"extends":["schemas/base.json"],"vars":{
				"PORT":{"format":"port","default":"3000"}
			}}}
			"""#

		@Test("Add key checks the name as it's typed and adds the key once it's valid")
		func addKey() async throws {
			let (store, host, folder) = try await workspace()
			defer { host.window.close(); store.lock(); try? FileManager.default.removeItem(atPath: folder) }
			try await host.click("Add key")
			#expect(try await host.waitForText("NEW KEY"))

			try host.enterText("api-token", placeholder: "KEY_NAME")
			#expect(try await host.waitForText("Use API_TOKEN"))
			#expect(store.schemaDraft(for: "schema-add") == nil, "A name that isn't valid isn't added")

			try host.enterText("DATABASE_URL", placeholder: "KEY_NAME")
			#expect(try await host.waitForText("Already declared"))
			try host.enterText("port", placeholder: "KEY_NAME")
			#expect(try await host.waitForText("Conflicts with PORT"))

			try host.enterText("SMTP_HOST", placeholder: "KEY_NAME")
			#expect(try await host.waitUntil { store.schemaDraft(for: "schema-add")?.declaration(of: .key("SMTP_HOST")) == .declared(.object([])) })
			#expect(try await host.waitForText("New"))
			try await host.settle()
			#expect(try await host.text().contains("SHAPE"), "The rows a new key starts with stay once its name is valid")
			#expect(try await host.text().contains("NEW KEY"))

			try host.enterText("MAIL_HOST", placeholder: "KEY_NAME")
			#expect(try await host.waitUntil { store.schemaDraft(for: "schema-add")?.changedItems == [.key("MAIL_HOST")] }, "Renaming a new key moves it in the draft")

			try await host.click("Add key")
			#expect(try await host.waitUntil { host.hasField(placeholder: "KEY_NAME") })
			try host.enterText("MAIL_HOST", placeholder: "KEY_NAME")
			#expect(try await host.waitForText("Already declared"), "A key the draft adds is taken")
			#expect(store.schemaDraft(for: "schema-add")?.changedItems == [.key("MAIL_HOST")])
		}

		@Test("a public prefix makes the new key public")
		func publicNewKey() async throws {
			let (store, host, folder) = try await workspace()
			defer { host.window.close(); store.lock(); try? FileManager.default.removeItem(atPath: folder) }
			try await host.click("Add key")
			#expect(try await host.waitForText("NEW KEY"))
			try host.enterText("NEXT_PUBLIC_ANALYTICS", placeholder: "KEY_NAME")
			#expect(try await host.waitUntil {
				store.schemaDraft(for: "schema-add")?.declaration(of: .key("NEXT_PUBLIC_ANALYTICS")) == .declared(.object([.init(key: "client", value: .bool(true))]))
			})
			#expect(try await host.waitForText("this key will be public"))
		}

		@Test("a stored key lpm.json doesn't declare can be declared, with rules suggested from its values")
		func declareStoredKey() async throws {
			let (store, host, folder) = try await workspace()
			defer { host.window.close(); store.lock(); try? FileManager.default.removeItem(atPath: folder) }
			#expect(try await host.waitForText("STORED, NOT DECLARED"))
			#expect(try await host.waitForText("REDIS_URL"))
			try await host.click("Declare")
			#expect(try await host.waitUntil { store.schemaDraft(for: "schema-add")?.declaration(of: .key("REDIS_URL")) == .declared(.object([])) })
			#expect(try await host.waitForText("SUGGESTED FROM STORED VALUES"))
			#expect(try await host.waitForText("both values are URLs"))
			try await host.click("Accept")
			#expect(try await host.waitUntil { store.schemaDraft(for: "schema-add")?.declaration(of: .key("REDIS_URL")).json?["format"] == .string("url") })
			#expect(try await host.waitForText("Accepted"))
		}

		private func workspace() async throws -> (VaultStore, SheetTestHost<some View>, String) {
			let folder = FileManager.default.temporaryDirectory.appending(path: "schema-add-\(UUID().uuidString)").path
			try FileManager.default.createDirectory(atPath: folder + "/schemas", withIntermediateDirectories: true)
			try Self.sample.write(toFile: folder + "/lpm.json", atomically: true, encoding: .utf8)
			try #"{"vars":{"DATABASE_URL":{"format":"url"}}}"#.write(toFile: folder + "/schemas/base.json", atomically: true, encoding: .utf8)
			let keychain = MockKeychainService()
			let project = VaultProject(id: "schema-add", name: "billing-app", path: folder, environments: [
				"default": ["PORT": "3000", "REDIS_URL": "redis://localhost:6379"],
				"staging": ["PORT": "3001", "REDIS_URL": "redis://cache.internal:6379"],
			])
			keychain.envStorage[project.id] = (name: project.name, path: folder, environments: project.environments)
			let store = VaultStore(keychainService: keychain, biometricService: MockBiometricService(),
				apiService: MockAPIService(), authTokenProvider: { _, _ in nil })
			store.isUnlocked = true
			store.projects = [project]
			store.openProject(id: project.id)
			await store.refreshCliAccess()
			let defaults = try #require(UserDefaults(suiteName: "schema-add-interaction"))
			let host = SheetTestHost(VaultWorkspaceView(store: store).environment(UpdateChecker())
				.environment(VaultAppearanceSettings(defaults: defaults)).defaultAppStorage(defaults),
				size: NSSize(width: 1400, height: 760), keepsRequestedSize: true, usesHostingView: true)
			#expect(try await host.waitUntil { store.keyDescriptions[project.id]?.schema?.overview != nil })
			try await host.click("Schema")
			#expect(try await host.waitForText("PORT"))
			return (store, host, folder)
		}
	}
}
