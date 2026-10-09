import AppKit
import SwiftUI
import Testing

@testable import LPMVault

@Suite("Schema page states")
struct SchemaPageStateTests {
	struct Press: Sendable, CustomTestStringConvertible {
		let modifiers: UInt
		let keyCode: UInt16
		let characters: String
		let expected: VaultSchemaShortcuts.Shortcut?

		init(_ modifiers: NSEvent.ModifierFlags, _ keyCode: UInt16, _ characters: String, _ expected: VaultSchemaShortcuts.Shortcut?) {
			self.modifiers = modifiers.rawValue
			self.keyCode = keyCode
			self.characters = characters
			self.expected = expected
		}

		var testDescription: String { "key \(keyCode) with modifiers \(modifiers)" }
	}

	static let presses: [Press] = [
		Press(.command, 6, "z", .undo),
		Press([.command, .shift], 6, "Z", .redo),
		Press(.command, 51, "\u{7f}", .remove),
		Press([], 53, "\u{1b}", .close),
		Press([.numericPad, .function], 126, "\u{f700}", .move(-1)),
		Press([.numericPad, .function], 125, "\u{f701}", .move(1)),
		Press([.numericPad, .function, .shift], 125, "\u{f701}", nil),
		Press([.numericPad, .function, .option], 126, "\u{f700}", nil),
		Press(.command, 53, "\u{1b}", nil),
		Press([], 6, "z", nil),
	]

	@Test("the page's keys: ⌘Z, ⇧⌘Z, ⌘⌫, Esc, ↑ and ↓, and nothing with other modifiers", arguments: presses)
	func shortcuts(press: Press) {
		let shortcut = VaultSchemaShortcuts.shortcut(modifiers: NSEvent.ModifierFlags(rawValue: press.modifiers), keyCode: press.keyCode,
			characters: press.characters)
		#expect(shortcut == press.expected)
	}

	@Test("failing keys list the environments they fail in, in the page's order, with names escaped")
	func failures() {
		var production = ProjectEnvValueCheck.Environment()
		production.problems = ["PORT": [.init(key: "PORT", kind: .format("port"))], "API_URL": [.init(key: "API_URL", kind: .required)]]
		var staging = ProjectEnvValueCheck.Environment()
		staging.problems = ["PORT": [.init(key: "PORT", kind: .format("port"))]]
		let check = ProjectEnvValueCheck(environments: [
			"production": production, "stag\u{202E}ing": staging, "default": ProjectEnvValueCheck.Environment(),
		])
		let failures = VaultSchemaView.failures(in: check, environments: ["default", "stag\u{202E}ing", "production"])
		#expect(failures == ["PORT": [".env.stag\\u{202e}ing", ".env.production"], "API_URL": [".env.production"]])
	}

	@Test("↑ and ↓ stop at either end, and start from the first or last row when the selection isn't one")
	func rows() {
		let rows: [VaultSchemaSelection] = [.key("A"), .key("B"), .group("g")]
		#expect(VaultSchemaView.row(1, from: nil, in: rows) == .key("A"))
		#expect(VaultSchemaView.row(-1, from: nil, in: rows) == .group("g"))
		#expect(VaultSchemaView.row(1, from: .newKey, in: rows) == .key("A"))
		#expect(VaultSchemaView.row(1, from: .key("A"), in: rows) == .key("B"))
		#expect(VaultSchemaView.row(1, from: .group("g"), in: rows) == .group("g"))
		#expect(VaultSchemaView.row(-1, from: .key("A"), in: rows) == .key("A"))
		#expect(VaultSchemaView.row(1, from: nil, in: []) == nil)
	}

	@Test("the page says why the draft can't be saved, and a check still running doesn't keep the review closed")
	@MainActor
	func pageBlocker() async throws {
		let folder = FileManager.default.temporaryDirectory.appending(path: "schema-page-state-\(UUID().uuidString)").path
		try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(atPath: folder) }
		try #"{"envSchema":{"vars":{"PORT":{"format":"port","default":"3000"},"API_TOKEN":{"secret":true}}}}"#
			.write(toFile: folder + "/lpm.json", atomically: true, encoding: .utf8)
		let store = try await Self.store(folder: folder)

		store.editSchemaDraft(in: "schema-page-state") { $0.set(.declared(.object([.init(key: "format", value: .string("port"))])), for: .key("PORT")) }
		let checking = try #require(VaultSchemaEditorFooter.blocker(store: store, projectID: "schema-page-state", item: nil))
		#expect(checking.checking && !checking.blocksReview, "The review opens and waits for the check")
		try await Self.waitForEvaluation(store)
		#expect(VaultSchemaEditorFooter.blocker(store: store, projectID: "schema-page-state", item: nil) == nil)

		store.editSchemaDraft(in: "schema-page-state") {
			$0.set(.declared(.object([.init(key: "secret", value: .bool(true)), .init(key: "default", value: .string("x"))])), for: .key("API_TOKEN"))
		}
		try await Self.waitForEvaluation(store)
		let rejected = try #require(VaultSchemaEditorFooter.blocker(store: store, projectID: "schema-page-state", item: nil))
		#expect(rejected.blocksReview)
		#expect(rejected.show == .key("API_TOKEN"))
		#expect(rejected.message.hasPrefix("Can't save: API_TOKEN has a problem."))
		let panel = try #require(VaultSchemaEditorFooter.blocker(store: store, projectID: "schema-page-state", item: .key("API_TOKEN")))
		#expect(panel.message == "Fix the problem above to save.", "The panel showing the key points at it instead")
	}

	@MainActor
	static func waitForEvaluation(_ store: VaultStore) async throws {
		let clock = ContinuousClock()
		let deadline = clock.now.advanced(by: .seconds(10))
		while store.currentSchemaDraftEvaluation(for: "schema-page-state") == nil, clock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
		try #require(store.currentSchemaDraftEvaluation(for: "schema-page-state") != nil)
	}

	@MainActor
	static func store(folder: String) async throws -> VaultStore {
		let keychain = MockKeychainService()
		let project = VaultProject(id: "schema-page-state", name: "billing-app", path: folder, environments: ["default": ["PORT": "3000"]])
		keychain.envStorage[project.id] = (name: project.name, path: folder, environments: project.environments)
		let store = VaultStore(keychainService: keychain, biometricService: MockBiometricService(),
			apiService: MockAPIService(), authTokenProvider: { _, _ in nil })
		store.isUnlocked = true
		store.projects = [project]
		store.openProject(id: project.id)
		await store.refreshCliAccess()
		store.reloadKeyDescriptions()
		let clock = ContinuousClock()
		let deadline = clock.now.advanced(by: .seconds(10))
		while store.keyDescriptions[project.id]?.schema?.overview == nil, clock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
		try #require(store.keyDescriptions[project.id]?.schema?.overview != nil)
		return store
	}
}

extension SheetInteractionTests {
	@Suite("Schema page keys and states", .serialized)
	@MainActor
	struct SchemaPageKeyboardTests {
		static let sample = #"""
			{"envSchema":{
				"extends":["schemas/base.json"],
				"vars":{
					"API_URL":{"format":"url"},
					"PORT":{"format":"port","default":"3000"},
					"RETRY_COUNT":{"format":"integer","min":0,"max":10}
				},
				"groups":{"limits":{"mode":"allOrNone","vars":["PORT","RETRY_COUNT"]}}
			}}
			"""#

		/// The side panel, by the share of the window it takes on the right.
		private static let panel = CGRect(x: 0.79, y: 0, width: 0.21, height: 1)

		@Test("↑ and ↓ move through keys and groups in the table's order, and Esc closes a panel just opened")
		func arrowsAndEscape() async throws {
			let (store, host, folder) = try await workspace()
			defer { host.window.close(); store.lock(); try? FileManager.default.removeItem(atPath: folder) }
			try host.press(.down)
			#expect(try await host.waitUntil { host.fieldText(placeholder: "KEY_NAME") == "API_URL" }, "↓ with nothing selected selects the first key")
			try host.press(.down)
			#expect(try await panelShows("DATABASE_URL", in: host), "Imported keys are rows too")
			try host.press(.down)
			#expect(try await host.waitUntil { host.fieldText(placeholder: "KEY_NAME") == "PORT" })
			try host.press(.down)
			try host.press(.down)
			#expect(try await host.waitUntil { host.fieldText(placeholder: "group_name") == "limits" }, "Groups follow the keys")
			try host.press(.down)
			try await host.settle()
			#expect(host.fieldText(placeholder: "group_name") == "limits", "The last row stays selected")
			try host.press(.up)
			#expect(try await host.waitUntil { host.fieldText(placeholder: "KEY_NAME") == "RETRY_COUNT" })

			try host.press(.escape)
			#expect(try await host.waitUntil { !host.hasField(placeholder: "KEY_NAME") }, "Esc closes the panel")
			try await host.click("API_URL")
			#expect(try await host.waitUntil { host.fieldText(placeholder: "KEY_NAME") == "API_URL" })
			try host.press(.escape)
			#expect(try await host.waitUntil { !host.hasField(placeholder: "KEY_NAME") }, "Esc closes a panel opened by a click")
			try host.press(.up)
			#expect(try await host.waitUntil { host.fieldText(placeholder: "group_name") == "limits" }, "↑ with nothing selected selects the last row")
		}

		@Test("the arrows stay with a field being edited, and follow the table's sort order")
		func arrowsInFieldsAndReversed() async throws {
			let (store, host, folder) = try await workspace(sortOrder: .descending)
			defer { host.window.close(); store.lock(); try? FileManager.default.removeItem(atPath: folder) }
			try host.press(.down)
			#expect(try await host.waitUntil { host.fieldText(placeholder: "KEY_NAME") == "RETRY_COUNT" }, "Z to A starts from the last key")
			try host.press(.down)
			#expect(try await host.waitUntil { host.fieldText(placeholder: "KEY_NAME") == "PORT" })
			try host.typeText("PORT", placeholder: "KEY_NAME")
			try host.press(.down)
			try host.press(.escape)
			try await host.settle()
			#expect(host.fieldText(placeholder: "KEY_NAME") == "PORT", "The arrow and the first Esc go to the field")
			#expect(!host.isEditing(placeholder: "KEY_NAME"), "Esc leaves the field")
			try host.press(.escape)
			#expect(try await host.waitUntil { !host.hasField(placeholder: "KEY_NAME") }, "The next Esc closes the panel")
		}

		@Test("selecting a row out of sight scrolls the table to it")
		func selectionScrolls() async throws {
			let vars = (0..<60).map { String(format: #""KEY_%02d":{"format":"integer"}"#, $0) }.joined(separator: ",")
			let (store, host, folder) = try await workspace(#"{"envSchema":{"vars":{\#(vars)}}}"#)
			defer { host.window.close(); store.lock(); try? FileManager.default.removeItem(atPath: folder) }
			#expect(try await !tableText(in: host).contains("KEY_59"))
			try host.press(.up)
			#expect(try await host.waitUntil { host.fieldText(placeholder: "KEY_NAME") == "KEY_59" })
			#expect(try await waitForTable(in: host) { $0.contains("KEY_59") }, "The last row scrolls into view")
			for _ in 0..<59 { try host.press(.up) }
			#expect(try await host.waitUntil { host.fieldText(placeholder: "KEY_NAME") == "KEY_00" })
			#expect(try await waitForTable(in: host) { $0.contains("KEY_00") }, "The first row scrolls back into view, below the header")
		}

		@Test("with the panel closed, the status bar offers Review & save and Discard; ⌘Z brings a discarded draft back")
		func statusBarActions() async throws {
			let (store, host, folder) = try await workspace()
			defer { host.window.close(); store.lock(); try? FileManager.default.removeItem(atPath: folder) }
			#expect(try await !host.text().contains("Review & save"), "Nothing to review without a draft")
			store.editSchemaDraft(in: "schema-keys") { $0.set(.declared(.object([.init(key: "format", value: .string("port"))])), for: .key("PORT")) }
			#expect(try await host.waitForText("1 unsaved change", footer: 30))
			#expect(try await host.waitUntil { store.currentSchemaDraftEvaluation(for: "schema-keys") != nil })
			try await host.click("Review & save")
			#expect(try await host.waitUntil { host.window.sheets.first != nil })
			let sheet = try #require(host.window.sheets.first)
			#expect(try await host.waitForText("Review changes to lpm.json", in: sheet))
			try closeSheet(sheet)
			#expect(try await host.waitUntil { host.window.sheets.isEmpty })

			try await host.click("Discard")
			#expect(try await host.waitUntil { store.schemaDraft(for: "schema-keys") == nil })
			try host.shortcut("z", code: 6)
			#expect(try await host.waitUntil { store.schemaDraft(for: "schema-keys") != nil }, "⌘Z works with the panel closed")

			try await host.click("API_URL")
			#expect(try await host.waitUntil { host.fieldText(placeholder: "KEY_NAME") == "API_URL" })
			try await host.settle()
			#expect(try await !statusBarText(in: host).contains("Discard"), "The panel's footer offers them instead")
		}

		@Test("⌘S opens the review from the page and from the panel; a problem keeps it closed and Show opens the key")
		func commandS() async throws {
			let (store, host, folder) = try await workspace()
			defer { host.window.close(); store.lock(); try? FileManager.default.removeItem(atPath: folder) }
			store.editSchemaDraft(in: "schema-keys") {
				$0.set(.declared(.object([.init(key: "format", value: .string("integer")), .init(key: "min", value: .number("0")),
					.init(key: "max", value: .number("100"))])), for: .key("RETRY_COUNT"))
			}
			#expect(try await host.waitForText("1 unsaved change", footer: 30))
			#expect(try await host.waitUntil { store.currentSchemaDraftEvaluation(for: "schema-keys") != nil })
			#expect(try host.keyEquivalent("s", code: 1))
			#expect(try await host.waitUntil { host.window.sheets.first != nil }, "⌘S on the page")
			try closeSheet(try #require(host.window.sheets.first))
			#expect(try await host.waitUntil { host.window.sheets.isEmpty })

			for _ in 0..<3 { try host.press(.down) }
			#expect(try await host.waitUntil { host.fieldText(placeholder: "KEY_NAME") == "PORT" })
			try host.typeText("8080", placeholder: "value")
			host.view.layoutSubtreeIfNeeded()
			#expect(store.currentSchemaDraftEvaluation(for: "schema-keys") == nil, "The check of the typing is still running")
			#expect(try host.keyEquivalent("s", code: 1), "⌘S while typing, before the check finishes")
			#expect(try await host.waitUntil { host.window.sheets.first != nil }, "⌘S in the panel")
			try closeSheet(try #require(host.window.sheets.first))
			#expect(try await host.waitUntil { host.window.sheets.isEmpty })
			host.window.makeFirstResponder(nil)
			try host.press(.escape)
			#expect(try await host.waitUntil { !host.hasField(placeholder: "KEY_NAME") })

			store.editSchemaDraft(in: "schema-keys") {
				$0.set(.declared(.object([.init(key: "format", value: .string("port")), .init(key: "default", value: .string("3000")),
					.init(key: "secret", value: .bool(true))])), for: .key("PORT"))
			}
			#expect(try await host.waitForText("PORT has a problem", footer: 30))
			_ = try host.keyEquivalent("s", code: 1)
			try await host.settle()
			#expect(host.window.sheets.isEmpty, "Saving is blocked")
			try await host.click("Show")
			#expect(try await host.waitUntil { host.fieldText(placeholder: "KEY_NAME") == "PORT" })
		}

		@Test("a failing stored value shows a dot on its row and a count in the status bar")
		func failures() async throws {
			let (store, host, folder) = try await workspace()
			defer { host.window.close(); store.lock(); try? FileManager.default.removeItem(atPath: folder) }
			#expect(try await host.waitForText("1 key fails in .env", footer: 30))
		}

		@Test("with no rules, one button declares every stored key in one change")
		func declareAll() async throws {
			let (store, host, folder) = try await workspace(#"{"name":"app"}"#)
			defer { host.window.close(); store.lock(); try? FileManager.default.removeItem(atPath: folder) }
			#expect(try await host.waitForText("No rules yet"))
			try await host.click("Declare 4 stored keys")
			#expect(try await host.waitUntil {
				store.schemaDraft(for: "schema-keys")?.changedItems == [.key("DATABASE_URL"), .key("EXTRA"), .key("PORT"), .key("RETRY_COUNT")]
			})
			try host.shortcut("z", code: 6)
			#expect(try await host.waitUntil { store.schemaDraft(for: "schema-keys") == nil }, "One undo takes them all back")
		}

		@Test("an unreadable lpm.json keeps the draft's count, and Discard still ends it")
		func unreadableWithDraft() async throws {
			let (store, host, folder) = try await workspace()
			defer { host.window.close(); store.lock(); try? FileManager.default.removeItem(atPath: folder) }
			store.editSchemaDraft(in: "schema-keys") { $0.set(.declared(.object([.init(key: "format", value: .string("port"))])), for: .key("PORT")) }
			try #"{"envSchema":{"vars":{"PORT":{"rnage":"1"}}}}"#.write(toFile: folder + "/lpm.json", atomically: true, encoding: .utf8)
			#expect(try await host.waitForText("Schema can't be read"))
			#expect(try await host.waitForText("1 unsaved change", footer: 30))
			try await host.click("Discard")
			#expect(try await host.waitUntil { store.schemaDraft(for: "schema-keys") == nil })
		}

		@Test("the inspector opens a declared key on the Schema page, and declares one lpm.json doesn't")
		func inspectorLinks() async throws {
			let (store, host, folder) = try await workspace(schemaPage: false)
			defer { host.window.close(); store.lock(); try? FileManager.default.removeItem(atPath: folder) }
			try await host.click("PORT")
			try await host.click("Edit in Schema")
			#expect(try await host.waitUntil { host.fieldText(placeholder: "KEY_NAME") == "PORT" })
			#expect(try await host.waitForText("enforced by LPM CLI", footer: 30))

			let (other, matrix, otherFolder) = try await workspace(schemaPage: false)
			defer { matrix.window.close(); other.lock(); try? FileManager.default.removeItem(atPath: otherFolder) }
			try await matrix.click("EXTRA")
			try await matrix.click("Declare in Schema")
			#expect(try await matrix.waitUntil { other.schemaDraft(for: "schema-keys")?.changedItems == [.key("EXTRA")] })
			#expect(try await panelShows("NEW KEY", in: matrix))
			#expect(try await panelShows("EXTRA", in: matrix))
		}

		private func panelShows(_ text: String, in host: SheetTestHost<some View>) async throws -> Bool {
			let deadline = ContinuousClock.now.advanced(by: .seconds(10))
			while ContinuousClock.now < deadline {
				let lines = try await RenderedText.lines(in: host.snapshot(host.view), level: .accurate, region: Self.panel)
				if OCRText(lines.map(\.text).joined(separator: "\n")).contains(text) { return true }
				try await Task.sleep(for: .milliseconds(20))
			}
			return false
		}

		/// Closes a sheet with Esc, as its close button's shortcut.
		private func closeSheet(_ sheet: NSWindow) throws {
			let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
				windowNumber: sheet.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
			#expect(sheet.performKeyEquivalent(with: event))
		}

		/// What the page's status bar reads, left of the panel.
		private func statusBarText(in host: SheetTestHost<some View>) async throws -> OCRText {
			let bar = CGRect(x: 0.2, y: 0, width: 0.58, height: 30 / host.view.bounds.height)
			let lines = try await RenderedText.lines(in: host.snapshot(host.view), level: .accurate, region: bar)
			return OCRText(lines.map(\.text).joined(separator: "\n"))
		}

		/// What the table's key column reads, left of the panel.
		private func tableText(in host: SheetTestHost<some View>) async throws -> OCRText {
			let column = CGRect(x: 0.2, y: 0, width: 0.2, height: 1)
			let lines = try await RenderedText.lines(in: host.snapshot(host.view), level: .accurate, region: column)
			return OCRText(lines.map(\.text).joined(separator: "\n"))
		}

		private func waitForTable(in host: SheetTestHost<some View>, _ condition: (OCRText) -> Bool) async throws -> Bool {
			let deadline = ContinuousClock.now.advanced(by: .seconds(10))
			while ContinuousClock.now < deadline {
				if try await condition(tableText(in: host)) { return true }
				try await Task.sleep(for: .milliseconds(20))
			}
			return false
		}

		private func workspace(_ lpmJSON: String = Self.sample, sortOrder: VaultKeySortOrder = .ascending, schemaPage: Bool = true) async throws
			-> (VaultStore, SheetTestHost<some View>, String)
		{
			let folder = FileManager.default.temporaryDirectory.appending(path: "schema-keys-\(UUID().uuidString)").path
			try FileManager.default.createDirectory(atPath: folder + "/schemas", withIntermediateDirectories: true)
			try lpmJSON.write(toFile: folder + "/lpm.json", atomically: true, encoding: .utf8)
			try #"{"vars":{"DATABASE_URL":{"format":"url","required":true}}}"#.write(toFile: folder + "/schemas/base.json", atomically: true, encoding: .utf8)
			let keychain = MockKeychainService()
			let project = VaultProject(id: "schema-keys", name: "billing-app", path: folder, environments: [
				"default": ["PORT": "3000", "RETRY_COUNT": "70", "DATABASE_URL": "postgres://db", "EXTRA": "x"],
			])
			keychain.envStorage[project.id] = (name: project.name, path: folder, environments: project.environments)
			let store = VaultStore(keychainService: keychain, biometricService: MockBiometricService(),
				apiService: MockAPIService(), authTokenProvider: { _, _ in nil })
			store.isUnlocked = true
			store.projects = [project]
			store.openProject(id: project.id)
			await store.refreshCliAccess()
			let defaults = try #require(UserDefaults(suiteName: "schema-page-keys"))
			defaults.set(sortOrder.rawValue, forKey: VaultKeySortOrder.defaultsKey)
			let host = SheetTestHost(VaultWorkspaceView(store: store).environment(UpdateChecker())
				.environment(VaultAppearanceSettings(defaults: defaults)).defaultAppStorage(defaults),
				size: NSSize(width: 1400, height: 760), keepsRequestedSize: true, usesHostingView: true)
			#expect(try await host.waitUntil { store.keyDescriptions[project.id]?.schema != nil && store.workspaceSnapshots[project.id] != nil })
			if schemaPage {
				try await host.click("Schema")
				#expect(try await host.waitForText(lpmJSON.contains("envSchema") ? "enforced by LPM CLI" : "No rules yet"))
			}
			return (store, host, folder)
		}
	}
}
