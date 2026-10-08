import AppKit
import SwiftUI
import Testing

@testable import LPMVault

extension SheetInteractionTests {
	@Suite("Value checks in the tables", .serialized)
	@MainActor
	struct ValueCheckTableInteractionTests {
		@Test("the tables mark failing values, show required and default values, and the Invalid view lists only failing keys")
		func tablesShowChecks() async throws {
			let folder = FileManager.default.temporaryDirectory.appending(path: "value-check-tables-\(UUID().uuidString)").path
			try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
			defer { try? FileManager.default.removeItem(atPath: folder) }
			try #"""
			{"envSchema":{"vars":{
				"API_TOKEN":{"secret":true,"requiredIn":[{"environment":["production"]}]},
				"DATABASE_URL":{"format":"url"},
				"NODE_ENV":{"enum":["development","production"]},
				"PORT":{"format":"port","default":"3000"},
				"PASSWORD":{"secret":true},
				"OAUTH_TOKEN":{"secret":true}
			},"groups":{"credentials":{"mode":"exactlyOne","vars":["PASSWORD","OAUTH_TOKEN"]}}}}
			"""#.write(toFile: folder + "/lpm.json", atomically: true, encoding: .utf8)
			let keychain = MockKeychainService()
			let project = VaultProject(id: "checked-tables", name: "billing-api", path: folder, environments: [
				"default": ["DATABASE_URL": "https://db.example.com", "NODE_ENV": "development", "PASSWORD": "a", "PORT": "4000"],
				"production": ["DATABASE_URL": "not a url", "NODE_ENV": "production", "PASSWORD": "a", "OAUTH_TOKEN": "b"],
			])
			keychain.envStorage[project.id] = (name: project.name, path: folder, environments: project.environments)
			let store = VaultStore(keychainService: keychain, biometricService: MockBiometricService(),
				apiService: MockAPIService(), authTokenProvider: { _, _ in nil })
			store.isUnlocked = true
			store.projects = [project]
			store.openProject(id: project.id)
			defer { store.lock() }
			await store.refreshCliAccess()
			let defaults = try #require(UserDefaults(suiteName: "value-check-tables"))
			let host = SheetTestHost(VaultWorkspaceView(store: store).environment(UpdateChecker())
				.environment(VaultAppearanceSettings(defaults: defaults)).defaultAppStorage(defaults),
				size: NSSize(width: 1400, height: 760), keepsRequestedSize: true, usesHostingView: true)
			defer { host.window.close() }
			#expect(try await host.waitUntil { store.valueChecks[project.id] != nil })

			#expect(try await host.waitForText("Required"))
			var text = try await host.text()
			for expected in ["API_TOKEN", "(default)", "Invalid values"] {
				#expect(text.contains(expected), "Missing \(expected)")
			}

			try await host.click("Invalid values")
			#expect(try await host.waitForTextToDisappear("NODE_ENV"))
			text = try await host.text()
			for expected in ["API_TOKEN", "DATABASE_URL", "PASSWORD", "OAUTH_TOKEN"] {
				#expect(text.contains(expected), "The Invalid view lists \(expected)")
			}

			try await host.clickSidebarEnvironment(".env.production")
			#expect(try await host.waitForText("Exactly one of PASSWORD, OAUTH_TOKEN"))
			text = try await host.text()
			#expect(text.contains("both set"))
			#expect(text.contains("Required"), "A key required in production shows in its table without a stored value")
			#expect(text.contains("(default)"), "A default fills PORT in production")
		}
	}
}
