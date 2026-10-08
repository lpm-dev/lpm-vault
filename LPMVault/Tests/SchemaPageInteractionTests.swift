import AppKit
import SwiftUI
import Testing

@testable import LPMVault

extension SheetInteractionTests {
	@Suite("Schema page", .serialized)
	@MainActor
	struct SchemaPageInteractionTests {
		private final class BadgeWidths {
			var rule: CGFloat = 0
			var source: CGFloat = 0
		}

		static let sample = #"""
			{"envSchema":{
				"extends":["schemas/base.json"],
				"vars":{
					"API_TOKEN":{"secret":true,"requiredIn":[{"environment":["production"]}],"description":"Bearer token for the admin API."},
					"NEXT_PUBLIC_API_URL":{"client":true,"format":"url","protocols":["https"]},
					"PORT":{"format":"port","default":"3000"},
					"PASSWORD":{"secret":true,"minLength":12},
					"OAUTH_TOKEN":{"secret":true}
				},
				"groups":{"credentials":{"mode":"exactlyOne","vars":["PASSWORD","OAUTH_TOKEN"]}}
			}}
			"""#

		@Test("the Schema row opens the project's rules read-only, with badges, sources, and groups")
		func schemaPageShowsRules() async throws {
			let folder = try makeFolder(Self.sample, files: ["schemas/base.json": #"{"vars":{"DATABASE_URL":{"format":"url","required":true}}}"#])
			defer { try? FileManager.default.removeItem(atPath: folder) }
			let store = makeStore(path: folder)
			defer { store.lock() }
			let host = try await workspace(store)
			defer { host.window.close() }
			#expect(try await host.waitUntil { store.keyDescriptions["schema-page"]?.schema?.overview != nil })
			try await host.click("Schema")
			#expect(try await host.waitForText("6 declared keys"))
			let text = try await host.text()
			for expected in ["Required in production", "Default: 3000", "https only", "12+ chars", "Public",
				"Exactly one of PASSWORD, OAUTH_TOKEN", "Bearer token for the admin API.", "1 inherited"] {
				#expect(text.contains(expected), "Missing \(expected)")
			}
			// Recognition misreads the small dashed source badge; the page renders the model's source.
			#expect(store.keyDescriptions["schema-page"]?.schema?.overview?.rule(for: "DATABASE_URL")?.source == "schemas/base.json")
			#expect(!text.contains("VALUES"), "The inspector stays closed on the Schema page")
		}

		@Test("without a folder, the page explains where rules live and offers Connect CLI")
		func noFolderState() async throws {
			let store = makeStore(path: "/nonexistent-\(UUID().uuidString)")
			defer { store.lock() }
			let host = try await workspace(store)
			defer { host.window.close() }
			#expect(try await host.waitUntil { store.keyDescriptions["schema-page"]?.schema == .noFolder })
			try await host.click("Schema")
			#expect(try await host.waitForText("Rules live in your project's lpm.json"))
			#expect(try await host.text().contains("Learn about envSchema"))
		}

		@Test("lpm.json without rules shows a valid example the LPM CLI accepts")
		func noRulesState() async throws {
			let folder = try makeFolder(#"{"name":"app"}"#)
			defer { try? FileManager.default.removeItem(atPath: folder) }
			let store = makeStore(path: folder)
			defer { store.lock() }
			let host = try await workspace(store)
			defer { host.window.close() }
			#expect(try await host.waitUntil { store.keyDescriptions["schema-page"]?.schema != nil })
			try await host.click("Schema")
			#expect(try await host.waitForText("No rules yet"))
			#expect(try await host.text().contains("format"))

			let example = try LPMConfigJSON(parsing: Data(VaultSchemaView.example.utf8))
			let resolved = try RustSchemaEngine.resolve(try #require(example["envSchema"]), inFolder: folder)
			#expect(ProjectEnvSchemaOverview(resolution: resolved).rule(for: "PORT")?.badges.map(\.text) == ["Port", "Default: 3000"])
		}

		@Test("an unreadable lpm.json pauses checks with its location, and Recheck reads the fixed file")
		func unreadableStateRecovers() async throws {
			let folder = try makeFolder(#"{"envSchema":{"vars":{"PORT":{"rnage":"1"}}}}"#)
			defer { try? FileManager.default.removeItem(atPath: folder) }
			let store = makeStore(path: folder)
			defer { store.lock() }
			let host = try await workspace(store)
			defer { host.window.close() }
			#expect(try await host.waitUntil {
				if case .unreadable? = store.keyDescriptions["schema-page"]?.schema { true } else { false }
			})
			try await host.click("Schema")
			#expect(try await host.waitForText("Schema can't be read"))
			let text = try await host.text()
			#expect(text.contains("unknown field"))
			#expect(text.contains("Checks paused"))

			try Self.sample.write(toFile: folder + "/lpm.json", atomically: true, encoding: .utf8)
			try FileManager.default.createDirectory(atPath: folder + "/schemas", withIntermediateDirectories: true)
			try #"{"vars":{}}"#.write(toFile: folder + "/schemas/base.json", atomically: true, encoding: .utf8)
			try await host.click("Recheck")
			#expect(try await host.waitForText("5 declared keys"))
			#expect(try await !host.text().contains("Schema can't be read"))
		}

		@Test("long rule and source badges fit the available width", arguments: [CGFloat(140), 264, 400])
		func longBadgesFit(width: CGFloat) async throws {
			let measured = BadgeWidths()
			let badge = ProjectEnvSchemaOverview.Badge(text: "Required when AUTHENTICATION_MODE = production")
			let source = "schemas/shared/environment/production/long-schema-name.json"
			let host = SheetTestHost(VaultFlowLayout {
				VaultRuleBadge(badge: badge)
					.background(GeometryReader { geometry in
						Color.clear.onAppear { measured.rule = geometry.size.width }
					})
				VaultSourceBadge(source: source)
					.background(GeometryReader { geometry in
						Color.clear.onAppear { measured.source = geometry.size.width }
					})
			}.frame(width: width, alignment: .leading), size: NSSize(width: width + 200, height: 160),
				keepsRequestedSize: true, usesHostingView: true)
			defer { host.window.close() }
			#expect(try await host.waitUntil { measured.rule > 0 && measured.source > 0 })
			#expect(measured.rule <= width)
			#expect(measured.source <= width)
		}

		@Test("the inspector shows a key's rules read-only, with its group, and says when a key has none")
		func inspectorShowsRules() async throws {
			let folder = try makeFolder(Self.sample, files: ["schemas/base.json": #"{"vars":{}}"#])
			defer { try? FileManager.default.removeItem(atPath: folder) }
			let store = makeStore(path: folder)
			defer { store.lock() }
			let host = try await workspace(store)
			defer { host.window.close() }
			#expect(try await host.waitUntil { store.keyDescriptions["schema-page"]?.schema?.overview != nil })
			let inspector = CGRect(x: 0.78, y: 0, width: 0.22, height: 1)

			try await host.click("PASSWORD")
			#expect(try await host.waitForText("RULES"))
			let rules = try await RenderedText.lines(in: host.snapshot(host.view), level: .accurate, region: inspector)
			let text = OCRText(rules.map(\.text).joined(separator: "\n"))
			for expected in ["12+ chars", "Secret", "Exactly one of PASSWORD, OAUTH_TOKEN", "Edit them there"] {
				#expect(text.contains(expected), "Missing \(expected) in the inspector")
			}

			try await host.click("UNDECLARED")
			#expect(try await host.waitForText("No rules for this key."))
		}

		private func makeStore(path: String) -> VaultStore {
			let keychain = MockKeychainService()
			let project = VaultProject(id: "schema-page", name: "billing-app", path: path, environments: ["default": ["PORT": "3000", "PASSWORD": "long-enough-password", "UNDECLARED": "x"]])
			keychain.envStorage[project.id] = (name: project.name, path: path, environments: project.environments)
			let store = VaultStore(keychainService: keychain, biometricService: MockBiometricService(),
				apiService: MockAPIService(), authTokenProvider: { _, _ in nil })
			store.isUnlocked = true
			store.projects = [project]
			store.openProject(id: project.id)
			return store
		}

		private func workspace(_ store: VaultStore) async throws -> SheetTestHost<some View> {
			await store.refreshCliAccess()
			let defaults = try #require(UserDefaults(suiteName: "schema-page-interaction"))
			let host = SheetTestHost(VaultWorkspaceView(store: store).environment(UpdateChecker())
				.environment(VaultAppearanceSettings(defaults: defaults)).defaultAppStorage(defaults),
				size: NSSize(width: 1400, height: 760), keepsRequestedSize: true, usesHostingView: true)
			#expect(try await host.waitUntil { store.workspaceSnapshots[store.selectedProjectId ?? ""] != nil })
			try await host.settle()
			return host
		}

		private func makeFolder(_ lpmJSON: String, files: [String: String] = [:]) throws -> String {
			let folder = FileManager.default.temporaryDirectory.appending(path: "schema-page-\(UUID().uuidString)").path
			try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
			try lpmJSON.write(toFile: folder + "/lpm.json", atomically: true, encoding: .utf8)
			for (path, contents) in files {
				let url = URL(fileURLWithPath: folder).appending(path: path)
				try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
				try contents.write(to: url, atomically: true, encoding: .utf8)
			}
			return folder
		}
	}
}
