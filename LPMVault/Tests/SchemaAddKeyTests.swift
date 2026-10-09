import AppKit
import SwiftUI
import Testing

@testable import LPMVault

@Suite("Schema suggestions")
struct SchemaSuggestionTests {
	typealias Suggestion = ProjectEnvSchemaSuggestion

	private func titles(_ key: String, _ values: [String], publicPrefix: String? = nil, clientPrefixes: [String] = []) -> [String] {
		Suggestion.suggestions(for: key, values: values, publicPrefix: publicPrefix, clientPrefixes: clientPrefixes).map(\.title)
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

	@Test("keys the LPM CLI never passes to a process get no suggestions", arguments: ["NODE_OPTIONS", "PATH", "HOME", "ENV"])
	func ignoredKeys(key: String) {
		#expect(titles(key, ["3000", "4000"]).isEmpty)
		#expect(titles(key, ["production", "staging"]).isEmpty)
	}

	@Test("a public key's values are checked as public, with the project's own prefixes", arguments: [
		("NEXT_PUBLIC_API_URL", ["https://api.example.com"], "NEXT_PUBLIC_", [String](), ["URL", "https only"]),
		("VITE_PORT", ["5173"], "VITE_", [], ["Port"]),
		("APP_PUBLIC_URL", ["https://app.example.com"], "APP_PUBLIC_", ["APP_PUBLIC_"], ["URL", "https only"]),
	])
	func publicKeys(key: String, values: [String], prefix: String, clientPrefixes: [String], expected: [String]) {
		#expect(titles(key, values, publicPrefix: prefix, clientPrefixes: clientPrefixes) == expected)
	}

	@Test("a scheme written into lpm.json has to be short enough to be a real one")
	func longSchemes() {
		#expect(titles("SERVICE_URL", ["akiaiosfodnn7example://host"]) == ["URL"])
	}

	@Test("a public key whose name says it's secret is warned about, but not one named for a token or key")
	func exposure() {
		#expect(Suggestion.exposureWarning(for: "NEXT_PUBLIC_DB_PASSWORD", publicPrefix: "NEXT_PUBLIC_")?.contains("NEXT_PUBLIC_ makes it public") == true)
		#expect(Suggestion.exposureWarning(for: "NEXT_PUBLIC_MAPBOX_TOKEN", publicPrefix: "NEXT_PUBLIC_") == nil)
		#expect(Suggestion.exposureWarning(for: "DB_PASSWORD", publicPrefix: nil) == nil)
	}

	@Test("a pasted credential isn't taken for a name", arguments: [
		("ghp_16C7e42F292c6912E7710c838347Ae178B4a", true),
		("AKIA2E0A8F3B244C9986", true),
		("NEXT_PUBLIC_SUPABASE_ANON_KEY", false),
		("AWS_S3_BUCKET_2024_ARCHIVE", false),
		("DATABASE_URL", false),
	])
	func credentials(name: String, looksLikeCredential: Bool) {
		#expect(Suggestion.looksLikeCredential(name) == looksLikeCredential)
	}

	@Test("formats need evidence beyond the values passing, so near misses suggest nothing", arguments: [
		("REPORT_LIMIT", ["100"], ["Integer"]),
		("LOG_FILE", ["app.log"], [String]()),
		("APP_VERSION", ["1.4.2"], []),
		("SENTRY_TRACES_SAMPLE_RATE", ["0.1", "1.0"], []),
		("DB_HOST", ["db.internal", "db.example.com"], ["Hostname"]),
	])
	func formatEvidence(key: String, values: [String], expected: [String]) {
		#expect(titles(key, values) == expected)
	}

	@Test("Secret comes from the name whatever the format, and not for public or identifying names", arguments: [
		("ADMIN_PASSWORD", ["hunter2.example"], ["Secret"]),
		("SESSION_SECRET", ["1234567890123456"], ["Integer", "Secret"]),
		("JWT_PUBLIC_KEY", ["k3J9x2Lq8vR4mP7wZ1nB5cT6"], [String]()),
		("STRIPE_PUBLISHABLE_KEY", ["pk_live_k3J9x2Lq8vR4mP7wZ1n"], []),
		("COMMIT_SHA", ["3f786850e387550fdab836ed7e6dc881de23001b"], []),
		("GOOGLE_CLIENT_ID", ["k3J9x2Lq8vR4mP7wZ1nB5cT6.apps"], []),
		("DB_PASSWORD", ["12345678"], ["Integer", "Secret"]),
		("ADMIN_TOKEN", ["true"], ["Boolean", "Secret"]),
		("SMTP_PASSWORD", ["mail.example.com"], ["Secret"]),
		("DATABASE_URL", ["postgres://admin:S3cr3t@db/app"], ["URL", "postgres only", "Secret"]),
		("REDIS_URL", ["redis://:pw@cache:6379"], ["URL", "redis only", "Secret"]),
		("SORT_KEY", ["created_at"], []),
		("SIGNING_KEY", ["k3J9x2Lq8vR4mP7wZ1nB5cT6dF"], ["Secret"]),
	])
	func secretEvidence(key: String, values: [String], expected: [String]) {
		#expect(titles(key, values) == expected)
	}

	@Test("a cancelled task stops between the engine's checks with no suggestions")
	func cancellation() async {
		let task = Task.detached { () -> [Suggestion] in
			withUnsafeCurrentTask { $0?.cancel() }
			return Suggestion.suggestions(for: "REDIS_URL", values: ["redis://localhost:6379"], publicPrefix: nil)
		}
		#expect(await task.value.isEmpty)
	}

	@Test("evidence counts the environments that store a value, not distinct values")
	func evidenceCountsEnvironments() {
		let found = Suggestion.suggestions(for: "REDIS_URL", values: Array(repeating: "redis://localhost:6379", count: 3), publicPrefix: nil)
		#expect(found.first?.evidence == "all 3 values are URLs")
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
	@Test("only the stored keys on screen are built, so thousands of them lay out about as fast as a few")
	func rowsAreLazy() {
		let overview = ProjectEnvSchemaOverview(rules: [.init(key: "PORT", isPublic: false, source: nil, badges: [])], groups: [])
		func layout(_ count: Int) -> Duration {
			let keys = (0..<count).map { VaultStore.StoredSchemaKey(key: "KEY_\($0)", environments: 1) }
			let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 760), styleMask: [.borderless], backing: .buffered, defer: false)
			window.isReleasedWhenClosed = false
			defer { window.close() }
			return ContinuousClock().measure {
				window.contentView = NSHostingView(rootView: VaultSchemaView(state: .loaded(overview, file: nil), folder: nil, descriptions: [:],
					sortOrder: .constant(.ascending), undeclared: keys, onConnectCLI: {}, onRecheck: {}))
				window.contentView?.layoutSubtreeIfNeeded()
			}
		}
		_ = layout(10)
		let few = (0..<3).map { _ in layout(10) }.min() ?? .zero
		let many = (0..<3).map { _ in layout(4096) }.min() ?? .zero
		#expect(many < few * 10 + .milliseconds(60), "4096 rows took \(many), 10 took \(few)")
	}

	@Test("a stored key that differs only in letter case from a declared one can't be declared, and a draft can't add one")
	func caseConflicts() async throws {
		let folder = FileManager.default.temporaryDirectory.appending(path: "undeclared-case-\(UUID().uuidString)").path
		try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(atPath: folder) }
		try #"{"envSchema":{"vars":{"PORT":{}}}}"#.write(toFile: folder + "/lpm.json", atomically: true, encoding: .utf8)
		let environments = ["default": ["port": "1", "PORT": "2"]]
		let keychain = MockKeychainService()
		keychain.envStorage["project"] = (name: "Project", path: folder, environments: environments)
		let preferences = try #require(UserDefaults(suiteName: "undeclared-case-\(UUID().uuidString)"))
		let store = VaultStore(keychainService: keychain, biometricService: MockBiometricService(), apiService: MockAPIService(), preferences: preferences)
		defer { store.lock() }
		store.projects = [VaultProject(id: "project", name: "Project", path: folder, environments: environments)]
		store.isUnlocked = true
		store.selectedProjectId = "project"
		store.reloadKeyDescriptions()
		for _ in 0..<1000 where store.keyDescriptions["project"]?.schema?.overview == nil || store.workspaceSnapshots["project"] == nil {
			try await Task.sleep(for: .milliseconds(5))
		}
		#expect(store.undeclaredSchemaKeys(for: "project") == [.init(key: "port", environments: 1, conflict: "PORT")])

		store.editSchemaDraft(in: "project") { $0.set(.declared(.object([])), for: .key("port")) }
		for _ in 0..<1000 where store.currentSchemaDraftEvaluation(for: "project") == nil { try await Task.sleep(for: .milliseconds(5)) }
		await #expect(throws: ProjectEnvSchemaFile.DraftSaveError.unavailable("PORT and port differ only in letter case, which Windows reads as one name. Rename one of them.")) {
			try await store.saveSchemaDraft(in: "project")
		}
		#expect(try String(contentsOfFile: folder + "/lpm.json", encoding: .utf8) == #"{"envSchema":{"vars":{"PORT":{}}}}"#)
	}

	@Test("stored keys are listed unless lpm.json, an import, or the draft declares them, from A to Z with how many environments store them")
	func undeclaredKeys() async throws {
		let folder = FileManager.default.temporaryDirectory.appending(path: "undeclared-\(UUID().uuidString)").path
		try FileManager.default.createDirectory(atPath: folder + "/schemas", withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(atPath: folder) }
		try #"{"envSchema":{"extends":["schemas/base.json"],"vars":{"PORT":{},"OLD":{}}}}"#.write(toFile: folder + "/lpm.json", atomically: true, encoding: .utf8)
		try #"{"vars":{"DATABASE_URL":{}}}"#.write(toFile: folder + "/schemas/base.json", atomically: true, encoding: .utf8)
		let environments = [
			"default": ["PORT": "1", "OLD": "x", "DATABASE_URL": "d", "KEY_10": "a", "KEY_2": "b", "SMTP_HOST": "h", "NODE_OPTIONS": "--inspect"],
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
		for _ in 0..<1000 where store.keyDescriptions["project"]?.schema?.overview == nil || store.workspaceSnapshots["project"] == nil
			|| store.valueChecks["project"] == nil
		{
			try await Task.sleep(for: .milliseconds(5))
		}
		#expect(store.undeclaredSchemaKeys(for: "project") == [
			.init(key: "KEY_2", environments: 2), .init(key: "KEY_10", environments: 1),
			.init(key: "NODE_OPTIONS", environments: 1, isIgnored: true), .init(key: "SMTP_HOST", environments: 1),
		])

		store.editSchemaDraft(in: "project") {
			$0.set(.declared(.object([])), for: .key("SMTP_HOST"))
			$0.set(.absent, for: .key("OLD"))
		}
		#expect(store.undeclaredSchemaKeys(for: "project").map(\.key) == ["KEY_2", "KEY_10", "NODE_OPTIONS"], "Keys the draft declares or removes aren't listed")
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
			#expect(try await host.waitForText("Already added in your draft"), "A key the draft adds is taken")
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
			try host.enterText("NEXT_PUBLIC_DB_PASSWORD", placeholder: "KEY_NAME")
			#expect(try await host.waitForText("says it's secret"))

			try host.enterText("PORT", placeholder: "KEY_NAME")
			#expect(try await host.waitForText("Already declared"))
			try await host.settle()
			#expect(try await !host.text().contains("need a public prefix"), "A key waiting for a name is public only if that name says so")
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
			#expect(!host.hasField(placeholder: "KEY_NAME"), "A declared key keeps the name its values are stored under")
			#expect(try await host.waitForText("both values are URLs"))
			try await host.click("Accept")
			#expect(try await host.waitUntil { store.schemaDraft(for: "schema-add")?.declaration(of: .key("REDIS_URL")).json?["format"] == .string("url") })
			#expect(try await host.waitForText("Accepted"))
		}

		@Test("typing a name one character at a time adds the key only while the name is free, and leaves nothing behind")
		func typingLeavesNoStrayKeys() async throws {
			let (store, host, folder) = try await workspace()
			defer { host.window.close(); store.lock(); try? FileManager.default.removeItem(atPath: folder) }
			try await host.click("Add key")
			#expect(try await host.waitUntil { host.isEditing(placeholder: "KEY_NAME") }, "Add key puts the cursor in the name")
			try await host.typeCharacters("DATABASE_URL", placeholder: "KEY_NAME")
			#expect(try await host.waitForText("Already declared"))
			#expect(store.schemaDraft(for: "schema-add") == nil, "No shorter name the field passed through is left in the draft")
			try await host.click("Open that key")
			#expect(try await host.waitForText("Read-only"))
			#expect(store.schemaDraft(for: "schema-add") == nil)

			try await host.click("Add key")
			#expect(try await host.waitUntil { host.hasField(placeholder: "KEY_NAME") })
			try await host.typeCharacters("api-token", placeholder: "KEY_NAME")
			#expect(try await host.waitForText("Use API_TOKEN"))
			#expect(store.schemaDraft(for: "schema-add") == nil)

			try host.enterText("ghp_16C7e42F292c6912E7710c838347Ae178B4a", placeholder: "KEY_NAME")
			#expect(try await host.waitForText("looks like a token"))
			#expect(store.schemaDraft(for: "schema-add") == nil, "A pasted credential isn't written to lpm.json")
			try await host.click("Use it as a name")
			#expect(try await host.waitUntil { store.schemaDraft(for: "schema-add")?.changedItems == [.key("ghp_16C7e42F292c6912E7710c838347Ae178B4a")] })

			try host.enterText(String(repeating: "A", count: 257), placeholder: "KEY_NAME")
			#expect(try await host.waitForText("at most 256"))
			#expect(try await host.waitUntil { store.schemaDraft(for: "schema-add") == nil })
		}

		@Test("a name the draft removes is taken, so typing past it leaves the removal as it is")
		func typingOverRemovedKey() async throws {
			let (store, host, folder) = try await workspace()
			defer { host.window.close(); store.lock(); try? FileManager.default.removeItem(atPath: folder) }
			store.editSchemaDraft(in: "schema-add") { $0.set(.absent, for: .key("PORT")) }
			try await host.click("Add key")
			#expect(try await host.waitUntil { host.hasField(placeholder: "KEY_NAME") })
			try await host.typeCharacters("PORT", placeholder: "KEY_NAME")
			#expect(try await host.waitForText("Your draft removes this key"))
			#expect(try await host.waitForText("Name the key to add it"), "Saving now would leave the key out")
			try await host.typeCharacters("PORTAL", placeholder: "KEY_NAME")
			#expect(try await host.waitUntil { store.schemaDraft(for: "schema-add")?.declaration(of: .key("PORTAL")) == .declared(.object([])) })
			#expect(store.schemaDraft(for: "schema-add")?.declaration(of: .key("PORT")) == .absent)
			#expect(host.fieldText(placeholder: "KEY_NAME") == "PORTAL")
		}

		@Test("undo takes a new key back to its earlier name, and the panel follows it")
		func undoFollowsNewKey() async throws {
			let (store, host, folder) = try await workspace()
			defer { host.window.close(); store.lock(); try? FileManager.default.removeItem(atPath: folder) }
			try await host.click("Add key")
			#expect(try await host.waitUntil { host.hasField(placeholder: "KEY_NAME") })
			try await host.typeCharacters("SMTP_HOST", placeholder: "KEY_NAME")
			#expect(try await host.waitUntil { store.schemaDraft(for: "schema-add")?.changedItems == [.key("SMTP_HOST")] })
			try await Task.sleep(for: .milliseconds(1200))
			try await host.typeCharacters("MAIL_HOST", placeholder: "KEY_NAME")
			#expect(try await host.waitUntil { store.schemaDraft(for: "schema-add")?.changedItems == [.key("MAIL_HOST")] })
			host.window.makeFirstResponder(nil)
			try host.shortcut("z", code: 6)
			#expect(try await host.waitUntil { store.schemaDraft(for: "schema-add")?.changedItems == [.key("SMTP_HOST")] })
			#expect(try await host.waitUntil { host.fieldText(placeholder: "KEY_NAME") == "SMTP_HOST" }, "The panel follows the key")
			try host.shortcut("z", code: 6)
			#expect(try await host.waitUntil { store.schemaDraft(for: "schema-add") == nil })
			#expect(try await host.waitUntil { host.fieldText(placeholder: "KEY_NAME") == "" })
		}

		@Test("renaming a key being added takes the draft's references to it along")
		func referencesFollowNewName() async throws {
			let (store, host, folder) = try await workspace()
			defer { host.window.close(); store.lock(); try? FileManager.default.removeItem(atPath: folder) }
			try await host.click("Add key")
			#expect(try await host.waitUntil { host.hasField(placeholder: "KEY_NAME") })
			try host.typeText("FOO", placeholder: "KEY_NAME")
			#expect(try await host.waitUntil { store.schemaDraft(for: "schema-add")?.changedItems == [.key("FOO")] })
			store.editSchemaDraft(in: "schema-add") { draft in
				draft.set(draft.declaration(of: .key("PORT")).replacingJSON {
					$0.set(.object([.init(key: "variable", value: .string("FOO")), .init(key: "present", value: .bool(true))]), forKey: "requiredWhen")
				}, for: .key("PORT"))
			}
			try await host.typeCharacters("FOO_X", placeholder: "KEY_NAME")
			#expect(try await host.waitUntil {
				store.schemaDraft(for: "schema-add")?.declaration(of: .key("PORT")).json?["requiredWhen"]?["variable"] == .string("FOO_X")
			})
			#expect(store.schemaDraft(for: "schema-add")?.declaration(of: .key("FOO_X")) == .declared(.object([])))
		}

		@Test("Secret isn't suggested for a key whose value another key compares")
		func secretSuggestionFollowsAvailability() async throws {
			let (store, host, folder) = try await workspace(values: [
				"default": ["PORT": "3000", "SESSION_TOKEN": "k3J9x2Lq8vR4mP7wZ1nB5cT6"],
			])
			defer { host.window.close(); store.lock(); try? FileManager.default.removeItem(atPath: folder) }
			try await host.click("Declare")
			#expect(try await host.waitForText("says it's secret"))
			store.editSchemaDraft(in: "schema-add") { draft in
				draft.set(draft.declaration(of: .key("PORT")).replacingJSON {
					$0.set(.object([.init(key: "variable", value: .string("SESSION_TOKEN")), .init(key: "equals", value: .string("on"))]), forKey: "requiredWhen")
				}, for: .key("PORT"))
			}
			#expect(try await host.waitForTextToDisappear("says it's secret"))
		}

		@Test("stored keys lpm.json doesn't declare follow the table's order")
		func undeclaredFollowSortOrder() async throws {
			let (store, host, folder) = try await workspace(values: [
				"default": ["PORT": "3000", "API_TOKEN": "a", "REDIS_URL": "redis://localhost"],
			], order: .descending)
			defer { host.window.close(); store.lock(); try? FileManager.default.removeItem(atPath: folder) }
			#expect(try await host.waitForText("REDIS_URL"))
			let lines = try await RenderedText.lines(in: host.snapshot(host.view), level: .accurate)
			let redis = try #require(lines.first { $0.text.contains("REDIS_URL") })
			let api = try #require(lines.first { $0.text.contains("API_TOKEN") })
			#expect(redis.bounds.midY > api.bounds.midY, "Z to A puts REDIS_URL above API_TOKEN")
		}

		@Test("stored keys can be declared even before lpm.json has rules")
		func declareFromEmptyState() async throws {
			let (store, host, folder) = try await workspace(#"{"envSchema":{}}"#, shows: "No rules yet")
			defer { host.window.close(); store.lock(); try? FileManager.default.removeItem(atPath: folder) }
			#expect(try await host.waitForText("No rules yet"))
			#expect(try await host.waitForText("STORED, NOT DECLARED"))
			try await host.click("Declare")
			#expect(try await host.waitUntil { store.schemaDraft(for: "schema-add")?.changedItems.isEmpty == false })
		}

		private func workspace(
			_ sample: String = Self.sample, values: [String: [String: String]]? = nil, order: VaultKeySortOrder = .ascending,
			shows: String = "by LPM CLI"
		) async throws -> (VaultStore, SheetTestHost<some View>, String) {
			let folder = FileManager.default.temporaryDirectory.appending(path: "schema-add-\(UUID().uuidString)").path
			try FileManager.default.createDirectory(atPath: folder + "/schemas", withIntermediateDirectories: true)
			try sample.write(toFile: folder + "/lpm.json", atomically: true, encoding: .utf8)
			try #"{"vars":{"DATABASE_URL":{"format":"url"}}}"#.write(toFile: folder + "/schemas/base.json", atomically: true, encoding: .utf8)
			let keychain = MockKeychainService()
			let project = VaultProject(id: "schema-add", name: "billing-app", path: folder, environments: values ?? [
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
			defaults.set(order.rawValue, forKey: VaultKeySortOrder.defaultsKey)
			let host = SheetTestHost(VaultWorkspaceView(store: store).environment(UpdateChecker())
				.environment(VaultAppearanceSettings(defaults: defaults)).defaultAppStorage(defaults),
				size: NSSize(width: 1400, height: 760), keepsRequestedSize: true, usesHostingView: true)
			#expect(try await host.waitUntil { store.keyDescriptions[project.id]?.schema?.overview != nil })
			try await host.click("Schema")
			#expect(try await host.waitForText(shows))
			return (store, host, folder)
		}
	}
}
