import AppKit
import SwiftUI
import Testing

@testable import LPMVault

extension SheetInteractionTests {
	@Suite("New key suggestions", .serialized)
	@MainActor
	struct KeySuggestionInteractionTests {
		static let schema = #"{"envSchema":{"vars":{"API_TOKEN":{"secret":true,"requiredIn":[{"environment":["production"]}]},"DATABASE_URL":{"format":"url","required":true},"OAUTH_TOKEN":{},"PORT":{"format":"port"}}}}"#

		@Test("typing a name suggests declared keys not set in the environment; arrows and Return pick one")
		func pickDeclaredKey() async throws {
			let (store, folder) = try await makeStore()
			defer { store.lock(); try? FileManager.default.removeItem(atPath: folder) }
			let host = SheetTestHost(AddVariableSheet(store: store, projectId: "suggestions", environment: "default"), size: NSSize(width: 560, height: 560))
			defer { host.window.close() }
			try await host.settle()

			try host.typeInFirstField("A")
			#expect(try await host.waitForText("DECLARED, NOT SET IN .ENV"))
			let text = try await host.text()
			for expected in ["API_TOKEN", "DATABASE_URL", "OAUTH_TOKEN", "Create A as a new key"] {
				#expect(text.contains(expected), "Missing \(expected)")
			}
			#expect(!text.contains("PORT"), "Keys already set in .env are not suggested")

			try host.pressWhileEditing("\u{F701}", code: 125)
			try host.returnWhileEditing("key", modifiers: [])
			#expect(try await host.waitForText("declared in lpm.json"))
			#expect(try await host.waitForTextToDisappear("DECLARED, NOT SET"))
			let picked = try await host.text()
			#expect(picked.contains("DATABASE_URL"))
			#expect(picked.contains("Required"))
		}

		@Test("full names with different case or whitespace complete to the declared key", arguments: ["api_token", " API_TOKEN "])
		func completeCanonicalName(typed: String) async throws {
			let (store, folder) = try await makeStore()
			defer { store.lock(); try? FileManager.default.removeItem(atPath: folder) }
			let host = SheetTestHost(AddVariableSheet(store: store, projectId: "suggestions", environment: "default"), size: NSSize(width: 560, height: 560))
			defer { host.window.close() }
			try await host.settle()
			try host.typeInFirstField(typed)
			try #require(try await host.waitForText("DECLARED, NOT SET IN .ENV"))
			try host.returnWhileEditing("key", modifiers: [])
			try #require(try await host.waitForText("declared in lpm.json"))
			try #require(try await host.waitForTextToDisappear("DECLARED, NOT SET"))
			try host.enterValue("fixture-value")
			try await host.click("Add to .env")
			#expect(try await host.waitUntil { store.selectedProject?.value(for: "API_TOKEN", in: "default") == "fixture-value" })
			#expect(store.selectedProject?.value(for: typed, in: "default") == nil)
		}

		@Test("Esc closes the suggestions and keeps the sheet open")
		func escapeClosesSuggestions() async throws {
			let (store, folder) = try await makeStore()
			defer { store.lock(); try? FileManager.default.removeItem(atPath: folder) }
			let host = SheetTestHost(AddVariableSheet(store: store, projectId: "suggestions", environment: "default"), size: NSSize(width: 560, height: 560))
			defer { host.window.close() }
			try await host.settle()

			try host.typeInFirstField("OAUTH")
			#expect(try await host.waitForText("OAUTH_TOKEN"))
			try host.pressWhileEditing("\u{1b}", code: 53)
			#expect(try await host.waitForTextToDisappear("DECLARED, NOT SET"))
			#expect(try await host.text().contains("Add variable"))
		}

		@Test("a long list stays inside the sheet, above the footer, and scrolls to the highlighted key")
		func longListStaysInsideTheSheet() async throws {
			let vars = ["SMTP_FROM", "SMTP_HOST", "SMTP_PASSWORD", "SMTP_PORT", "SMTP_SECURE", "SMTP_USER"]
				.map { #""\#($0)":{"required":true}"# }.joined(separator: ",")
			let (store, folder) = try await makeStore(lpmJSON: #"{"envSchema":{"vars":{\#(vars)}}}"#)
			defer { store.lock(); try? FileManager.default.removeItem(atPath: folder) }
			let host = SheetTestHost(AddVariableSheet(store: store, projectId: "suggestions", environment: "default"), size: NSSize(width: 560, height: 560))
			defer { host.window.close() }
			try await host.settle()

			try host.typeInFirstField("SMTP")
			#expect(try await host.waitForText("SMTP_FROM"))
			#expect(try await host.text().contains("Create SMTP as a new key"), "The footer must not cover the list")

			try host.pressWhileEditing("\u{F700}", code: 126)
			#expect(try await host.waitForText("SMTP_USER"), "The last key scrolls into view when highlighted")
			try host.returnWhileEditing("key", modifiers: [])
			#expect(try await host.waitForText("declared in lpm.json"))
			#expect(try await host.text().contains("SMTP_USER"))
		}

		@Test("a declared key's value is checked as it is typed, a failing value can still be added, and only a length rule shows a counter")
		func liveValueCheck() async throws {
			let (store, folder) = try await makeStore(lpmJSON: #"{"envSchema":{"vars":{"DATABASE_URL":{"format":"url"},"API_TOKEN":{"secret":true,"minLength":12}}}}"#)
			defer { store.lock(); try? FileManager.default.removeItem(atPath: folder) }
			for _ in 0..<200 where store.valueChecks["suggestions"] == nil { try await Task.sleep(for: .milliseconds(10)) }
			try #require(store.valueChecks["suggestions"] != nil)

			let host = SheetTestHost(AddVariableSheet(store: store, projectId: "suggestions", environment: "default", initialKey: "DATABASE_URL"), size: NSSize(width: 560, height: 560))
			defer { host.window.close() }
			try await host.settle()
			try host.enterValue("not a url")
			#expect(try await host.waitForText("Not a valid URL"))
			var text = try await host.text()
			#expect(text.contains("Add anyway"))
			#expect(!text.contains("chars"), "A key without a length rule shows no counter")

			try host.enterValue("https://db.example.com")
			#expect(try await host.waitForTextToDisappear("Not a valid URL"))
			text = try await host.text()
			#expect(text.contains("Add to .env"))
			#expect(!text.contains("Add anyway"))

			let token = SheetTestHost(AddVariableSheet(store: store, projectId: "suggestions", environment: "default", initialKey: "API_TOKEN"), size: NSSize(width: 560, height: 560))
			defer { token.window.close() }
			try await token.settle()
			try token.enterValue("short")
			#expect(try await token.waitForText("Too short"))
			#expect(try await token.text().contains("5 chars"))
		}

		private func makeStore(lpmJSON: String = Self.schema) async throws -> (VaultStore, String) {
			let folder = FileManager.default.temporaryDirectory.appending(path: "key-suggestions-\(UUID().uuidString)").path
			try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
			try lpmJSON.write(toFile: folder + "/lpm.json", atomically: true, encoding: .utf8)
			let keychain = MockKeychainService()
			let project = VaultProject(id: "suggestions", name: "api", path: folder, environments: ["default": ["PORT": "3000"]])
			keychain.envStorage[project.id] = (name: project.name, path: folder, environments: project.environments)
			let store = VaultStore(keychainService: keychain, biometricService: MockBiometricService(),
				apiService: MockAPIService(), authTokenProvider: { _, _ in nil })
			store.isUnlocked = true
			store.projects = [project]
			store.openProject(id: project.id)
			store.reloadKeyDescriptions()
			for _ in 0..<200 where store.keyDescriptions[project.id]?.schema?.overview == nil {
				try await Task.sleep(for: .milliseconds(10))
			}
			try #require(store.keyDescriptions[project.id]?.schema?.overview != nil)
			return (store, folder)
		}
	}
}
