import AppKit
import Observation
import SwiftUI
import Testing

@testable import LPMVault

extension SheetInteractionTests {
	@Suite("Value checks in the tables", .serialized)
	@MainActor
	struct ValueCheckTableInteractionTests {
		@Observable
		final class CheckState {
			let project: VaultProject
			var check: ProjectEnvValueCheck?
			var filter = VaultWorkspaceFilter.invalid
			var addedKey: String?
			var selectedKey: String?
			var showsInspector = false

			init(project: VaultProject, check: ProjectEnvValueCheck) {
				self.project = project
				self.check = check
			}
		}

		struct CheckContent: View {
			@Bindable var state: CheckState
			var mode: VaultWorkspaceMode = .matrix

			var body: some View {
				VaultContentView(
					project: state.project,
					snapshot: VaultWorkspaceSnapshot(project: state.project),
					environments: ["default", "production"], selectedEnvironment: "production",
					mode: .constant(mode),
					filter: $state.filter, environmentViewMode: .constant(.table),
					sortOrder: .constant(.ascending), searchText: "",
					selectedKey: $state.selectedKey, revealedKeys: .constant([]),
					showsInspector: $state.showsInspector,
					columnWidths: .constant(VaultProjectTableColumnWidths()), isImporting: false,
					isCopyingAll: false,
					cliAccess: nil, isChangingCliAccess: false, onChangeCliAccess: { _ in },
					onCopyAll: {}, onImport: {}, onExport: {},
					valueChecks: VaultValueCheckPresentation(
						check: state.check, rules: nil, project: state.project),
					onAddSecret: {}, onAddKey: { state.addedKey = $0 }, onCopySecret: { _, _ in },
					onDeleteSecret: { _, _ in }, onResizeColumns: {})
			}
		}

		@Test("the Invalid filter survives pending checks")
		func invalidFilterSurvivesPendingChecks() async throws {
			let checked = ProjectEnvValueCheck(environments: [
				"default": .init(problems: [
					"BAD": [.init(key: "BAD", kind: .format("port"))]
				])
			])
			let state = CheckState(
				project: VaultProject(
					id: "p", name: "p", path: "",
					environments: ["default": ["BAD": "bad", "SAVED": "ok"]]), check: checked)
			let host = SheetTestHost(
				CheckContent(state: state), size: NSSize(width: 1100, height: 550),
				keepsRequestedSize: true)
			defer { host.window.close() }
			try await host.settle()
			state.check = nil
			try await host.settle()
			state.check = checked
			try await host.settle()
			#expect(state.filter == .invalid)
			#expect(!(try await host.text()).contains("SAVED"))
		}

		@Test("clicking a required-only matrix row adds its key")
		func requiredMatrixRowAddsItsKey() async throws {
			let state = CheckState(
				project: VaultProject(id: "p", name: "p", path: "", environments: ["default": [:]]),
				check: ProjectEnvValueCheck(environments: [
					"default": .init(problems: [
						"API_TOKEN": [.init(key: "API_TOKEN", kind: .required)]
					])
				]))
			let host = SheetTestHost(
				CheckContent(state: state), size: NSSize(width: 1100, height: 550),
				keepsRequestedSize: true, usesHostingView: true)
			defer { host.window.close() }
			try await host.settle()
			try await host.click("API_TOKEN")
			try await host.settle()
			#expect(state.addedKey == "API_TOKEN")
			#expect(state.selectedKey == nil)
			#expect(!state.showsInspector)
		}

		@Test("fallback tables show ignored keys included in the invalid count")
		func fallbackTableShowsIgnoredKeys() async throws {
			let state = CheckState(
				project: VaultProject(
					id: "p", name: "p", path: "",
					environments: ["default": ["NODE_OPTIONS": "--inspect"], "production": [:]]),
				check: ProjectEnvValueCheck(environments: [
					"production": .init(readsDefaultEnvironment: true, ignored: ["NODE_OPTIONS"])
				]))
			let host = SheetTestHost(
				CheckContent(state: state, mode: .environment("production")),
				size: NSSize(width: 1100, height: 550), keepsRequestedSize: true)
			defer { host.window.close() }
			try await host.settle()
			#expect((try await host.text()).contains("NODE_OPTIONS"))
		}

		@Test(arguments: [false, true]) func inspector_checks_pending_key_rename(editValue: Bool) async throws {
			let folder = FileManager.default.temporaryDirectory.appending(
				path: "review-rename-\(UUID().uuidString)")
			try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
			defer { try? FileManager.default.removeItem(at: folder) }
			try #"{"envSchema":{"vars":{"PORT":{"format":"port"}}}}"#.write(
				to: folder.appending(path: "lpm.json"), atomically: true, encoding: .utf8)
			let keychain = MockKeychainService()
			let project = VaultProject(
				id: "p", name: "p", path: folder.path, environments: ["default": ["OLD": "abc"]])
			keychain.envStorage[project.id] = (
				name: project.name, path: folder.path, environments: project.environments
			)
			let store = VaultStore(
				keychainService: keychain, biometricService: MockBiometricService(),
				apiService: MockAPIService(), authTokenProvider: { _, _ in nil })
			store.isUnlocked = true
			store.projects = [project]
			store.openProject(id: project.id)
			defer { store.lock() }
			store.reloadKeyDescriptions()
			for _ in 0..<500 {
				if store.valueChecks[project.id] != nil { break }
				try await Task.sleep(for: .milliseconds(10))
			}
			_ = try #require(store.valueChecks[project.id])
			let host = SheetTestHost(
				VaultInspectorView(
					store: store, project: project, environments: ["default"],
					mode: .environment("default"), selectedKey: "OLD", revealedKeys: .constant([]),
					onClose: {}, onCopy: { _ in }, onDelete: { _, _ in },
					onAddElsewhere: { _, _ in }, onRenamed: { _, _ in }),
				size: NSSize(width: 440, height: 900), keepsRequestedSize: true)
			defer { host.window.close() }
			try await host.settle()
			store.keyDrafts.edit(project, key: "OLD") {
				$0.name = "PORT"
				if editValue { $0.setValue("still-bad", in: "default") }
			}
			try await Task.sleep(for: .milliseconds(500))
			try await host.settle()
			var draft = try #require(store.keyDrafts.draft(.init(projectID: project.id, key: "OLD")))
			let pendingEdit = draft.beginSave()
			let edit = try #require(pendingEdit)
			let renamed = try edit.applied(to: project.environments).get()
			let rules = try #require(store.keyDescriptions[project.id]?.schema?.overview)
			#expect(try #require(rules.check(renamed)).problems(of: "PORT", in: "default").count == 1)
			let text = try await host.text()
			#expect(text.contains("Not a valid port"))
		}

		@Test func tables_show_defaults_that_replace_empty_stored_values() async throws {
			let project = VaultProject(
				id: "p", name: "p", path: "", environments: ["default": ["EMPTY": ""]])
			let check = ProjectEnvValueCheck(environments: ["default": .init(defaults: ["EMPTY": "filled"])]
			)
			let presentation = VaultValueCheckPresentation(check: check, rules: nil, project: project)
			let host = SheetTestHost(
				VaultContentView(
					project: project, snapshot: VaultWorkspaceSnapshot(project: project),
					environments: ["default"], selectedEnvironment: "default",
					mode: .constant(.environment("default")), filter: .constant(.all),
					environmentViewMode: .constant(.table), sortOrder: .constant(.ascending),
					searchText: "",
					selectedKey: .constant(nil), revealedKeys: .constant(["EMPTY"]),
					showsInspector: .constant(false),
					columnWidths: .constant(VaultProjectTableColumnWidths()),
					isImporting: false, isCopyingAll: false, cliAccess: nil,
					isChangingCliAccess: false, onChangeCliAccess: { _ in }, onCopyAll: {},
					onImport: {}, onExport: {},
					valueChecks: presentation, onAddSecret: {}, onCopySecret: { _, _ in },
					onDeleteSecret: { _, _ in }, onResizeColumns: {}
				), size: NSSize(width: 950, height: 550), keepsRequestedSize: true)
			defer { host.window.close() }
			try await host.settle()
			let text = try await host.text()
			#expect(text.contains("filled"))
			#expect(text.contains("(default)"))
		}
		@Test func raw_text_omits_keys_without_stored_values() async throws {
			let project = VaultProject(
				id: "p", name: "p", path: "", environments: ["default": ["SAVED": "x"]])
			let check = ProjectEnvValueCheck(environments: [
				"default": .init(
					problems: ["API_TOKEN": [.init(key: "API_TOKEN", kind: .required)]],
					defaults: ["PORT": "3000"])
			])
			let presentation = VaultValueCheckPresentation(check: check, rules: nil, project: project)
			let host = SheetTestHost(
				VaultContentView(
					project: project, snapshot: VaultWorkspaceSnapshot(project: project),
					environments: ["default"], selectedEnvironment: "default",
					mode: .constant(.environment("default")), filter: .constant(.all),
					environmentViewMode: .constant(.raw), sortOrder: .constant(.ascending),
					searchText: "",
					selectedKey: .constant(nil),
					revealedKeys: .constant(["SAVED", "API_TOKEN", "PORT"]),
					showsInspector: .constant(false),
					columnWidths: .constant(VaultProjectTableColumnWidths()),
					isImporting: false, isCopyingAll: false, cliAccess: nil,
					isChangingCliAccess: false, onChangeCliAccess: { _ in }, onCopyAll: {},
					onImport: {}, onExport: {},
					valueChecks: presentation, onAddSecret: {}, onCopySecret: { _, _ in },
					onDeleteSecret: { _, _ in }, onResizeColumns: {}
				), size: NSSize(width: 950, height: 550), keepsRequestedSize: true)
			defer { host.window.close() }
			try await host.settle()
			let text = try await host.text()
			#expect(text.contains("SAVED"))
			#expect(!text.contains("API_TOKEN"))
			let containsUnstoredPort = text.contains("PORT=")
			#expect(!containsUnstoredPort)
		}

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

			// Recognition on CI runners misreads the matrix's 11-point Required;
			// the environment table below checks it at its larger size.
			#expect(try await host.waitForText("Invalid values"))
			var text = try await host.text()
			for expected in ["API_TOKEN", "(default)"] {
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

		@Test("the inspector checks an unsaved edit against the current rules before it is saved")
		func inspectorChecksEdits() async throws {
			let folder = FileManager.default.temporaryDirectory.appending(path: "value-check-inspector-\(UUID().uuidString)").path
			try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
			defer { try? FileManager.default.removeItem(atPath: folder) }
			try #"{"envSchema":{"vars":{"DATABASE_URL":{"format":"url"}}}}"#.write(toFile: folder + "/lpm.json", atomically: true, encoding: .utf8)
			let keychain = MockKeychainService()
			let project = VaultProject(id: "checked-inspector", name: "billing-api", path: folder, environments: [
				"default": ["DATABASE_URL": "https://db.example.com"],
				"production": ["DATABASE_URL": "not a url"],
			])
			keychain.envStorage[project.id] = (name: project.name, path: folder, environments: project.environments)
			let store = VaultStore(keychainService: keychain, biometricService: MockBiometricService(),
				apiService: MockAPIService(), authTokenProvider: { _, _ in nil })
			store.isUnlocked = true
			store.projects = [project]
			store.openProject(id: project.id)
			defer { store.lock() }
			await store.refreshCliAccess()
			let defaults = try #require(UserDefaults(suiteName: "value-check-inspector"))
			let host = SheetTestHost(VaultWorkspaceView(store: store).environment(UpdateChecker())
				.environment(VaultAppearanceSettings(defaults: defaults)).defaultAppStorage(defaults),
				size: NSSize(width: 1400, height: 760), keepsRequestedSize: true, usesHostingView: true)
			defer { host.window.close() }
			#expect(try await host.waitUntil { store.valueChecks[project.id] != nil })

			try await host.click("DATABASE_URL")
			#expect(try await host.waitForText("RULES"))
			let inspector = CGRect(x: 0.78, y: 0, width: 0.22, height: 1)
			func inspectorText() async throws -> OCRText {
				let lines = try await RenderedText.lines(in: host.snapshot(host.view), level: .accurate, region: inspector)
				return OCRText(lines.map(\.text).joined(separator: "\n"))
			}
			#expect(try await inspectorText().contains("Not a valid URL"))
			#expect(try await inspectorText().contains("production"))

			try host.enterValue("https://db.example.com", at: 1)
			var cleared = false
			for _ in 0..<100 where !cleared {
				cleared = try await !inspectorText().contains("Not a valid URL")
				if !cleared { try await Task.sleep(for: .milliseconds(20)) }
			}
			#expect(cleared, "The fixed value passes before it is saved")
			#expect(store.valueChecks[project.id]?.problems(of: "DATABASE_URL", in: "production").isEmpty == false, "The saved value still fails until it is saved")

			try #"{"envSchema":{"vars":{"DATABASE_URL":{"format":"email"}}}}"#.write(toFile: folder + "/lpm.json", atomically: true, encoding: .utf8)
			store.reloadKeyDescriptions()
			var rechecked = false
			for _ in 0..<100 where !rechecked {
				rechecked = try await inspectorText().contains("Not a valid email address")
				if !rechecked { try await Task.sleep(for: .milliseconds(20)) }
			}
			#expect(rechecked, "Changing lpm.json rechecks the unchanged unsaved value")
		}
	}
}
