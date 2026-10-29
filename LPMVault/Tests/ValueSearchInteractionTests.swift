import AppKit
import SwiftUI
import Testing

@testable import LPMVault

extension SheetInteractionTests {
	@Suite("Value search interactions", .serialized)
	@MainActor
	struct ValueSearchInteractionTests {
		static let shared = "sk_live_51HqLyjWDarjtT1zdp7dcXZ"

		@Test("Find Value… opens a masked search that lists every place by name, and a place opens its key, marked found")
		func findAndOpen() async throws {
			let fixture = try await ValueSearchWorkspace([
				(id: "alpha", name: "Alpha", environments: [
					"default": ["DATABASE_URL": Self.shared, "PORT": "3000"], "production": ["STRIPE_KEY": Self.shared],
				]),
				(id: "bravo", name: "Bravo", environments: ["default": ["PAYMENTS": Self.shared]]),
				(id: "charlie", name: "Charlie", environments: ["default": ["PAYMENTS": Self.shared]]),
			])
			defer { fixture.tearDown() }
			fixture.keychain.companionRefusals["charlie"] = .unsupported(feature: "history", version: 2, level: .refuse)
			let host = try await fixture.host()
			defer { host.window.close() }

			NotificationCenter.default.post(name: .findValue, object: nil)
			let sheet = try await fixture.sheet(of: host)
			#expect(try await host.waitForText("Nothing searched yet", in: sheet))
			#expect(try await host.waitForText(ValueSearchWording.findCoverage, in: sheet))
			#expect(try await host.waitForText("Press Return to search 3 projects in Personal vault. Nothing is searched as you type.", in: sheet))
			let field = try #require(secureField(in: sheet))
			#expect(field.accessibilityLabel() == "Value to find")

			let editor = try type(Self.shared, into: field, of: sheet)
			#expect(!editor.allowsUndo, "The term never enters undo history")
			#expect(editor.undoManager?.canUndo != true)
			submit(field, editor: editor)
			#expect(try await host.waitForText("3 places in 2 projects. 1 project couldn’t be searched.", in: sheet))
			let text = try await host.text(in: sheet)
			#expect(text.contains("Alpha, .env, DATABASE_URL, exact match"))
			#expect(text.contains("Alpha, .env.production, STRIPE_KEY, exact match"))
			#expect(text.contains("Bravo, .env, PAYMENTS, exact match"))
			#expect(text.contains("Charlie, not searched: Made with a newer LPM version. Update LPM Vault to read it."))
			#expect(text.contains("Check for Updates…, Charlie"))
			#expect(!text.contains(Self.shared), "The value is never shown or read out")

			try await host.click("Bravo, .env, PAYMENTS, exact match", in: sheet)
			#expect(try await host.waitUntil { host.window.attachedSheet == nil })
			#expect(fixture.store.selectedProjectId == "bravo")
			#expect(try await host.waitForText("Value search · 3 places in 2 projects"))
			#expect(try await host.waitForText("PAYMENTS, value hidden, found by value search"))
			#expect(try await host.waitForText("Find where the .env value is used"), "The inspector shows the key")
			#expect(fixture.store.valueSearch.term.text.isEmpty, "The term goes as the sheet closes")

			try await host.click("Show Results")
			let reopened = try await fixture.sheet(of: host)
			#expect(try await host.waitForText("3 places in 2 projects · from your last search. The value wasn’t kept.", in: reopened))
			#expect(secureField(in: reopened)?.stringValue == "")
			try await host.click("Clear Results", in: reopened)
			#expect(try await host.waitForText("Nothing searched yet", in: reopened))
			try await host.click("Cancel", in: reopened)
			#expect(try await host.waitUntil { host.window.attachedSheet == nil })
			#expect(try await host.waitForTextToDisappear("Value search ·"))
		}

		@Test("the inspector finds where a key's value is used without typing it, and notes a secret shared with another environment")
		func inspectorFindsStoredValue() async throws {
			let databaseURL = "postgres://app:p4ssw0rd@db.example.com/app"
			let fixture = try await ValueSearchWorkspace([
				(id: "alpha", name: "Alpha", environments: [
					"default": ["SESSION_SECRET": "s3cret-session", "PORT": "3000", "DATABASE_URL": databaseURL],
					"production": ["SESSION_SECRET": "s3cret-session", "PORT": "3000", "DATABASE_URL": databaseURL],
				]),
				(id: "bravo", name: "Bravo", environments: ["default": ["COOKIE_SECRET": "s3cret-session"]]),
			])
			defer { fixture.tearDown() }
			let host = try await fixture.host()
			defer { host.window.close() }

			try await host.click("PORT")
			#expect(try await host.waitForText("Find where the .env.production value is used"))
			// Whether a value looks secret is judged off the main actor; nothing says the judging is over.
			try await quietPeriod()
			#expect(try await !host.text().contains("Warning: same value"), "A port shared by environments is configuration")

			try await host.click("DATABASE_URL")
			#expect(try await host.waitForText("Warning: same value as .env.production."))
			#expect(try await host.waitForText("Show where the .env value is used"))
			#expect(try await !host.text().contains("Generate new value"), "A URL's password is what to change, not the whole URL")

			try await host.click("SESSION_SECRET")
			#expect(try await host.waitForText("Warning: same value as .env.production."))
			#expect(try await host.waitForText("Warning: same value as .env."))
			#expect(try await host.waitForText("Show where the .env value is used"))
			try await host.click("Generate new value for .env.production")
			let generator = try await host.generatorWindow()
			try await host.click("Password", in: generator)
			#expect(try await host.waitForText("1 unsaved change"))
			#expect(try await host.waitUntil {
				AccessibilityTree.elements(in: host.window).first { $0.says("Find where the .env.production value is used") }?.isEnabled == false
			}, "A card showing an edit doesn't search for the saved value")
			#expect(try await host.waitForTextToDisappear("Warning: same value"), "A new value isn't the same value")
			#expect(fixture.keychain.envStorage["alpha"]?.environments["production"]?["SESSION_SECRET"] == "s3cret-session", "Nothing is saved until Save")

			try await host.click("Find where the .env value is used")
			let sheet = try await fixture.sheet(of: host)
			#expect(try await host.waitForText("3 places in 2 projects in Personal vault.", in: sheet))
			#expect(try await host.waitForText("Bravo, .env, COOKIE_SECRET, exact match", in: sheet))
			#expect(secureField(in: sheet)?.stringValue == "s3cret-session", "The stored value was searched, masked")
		}

		@Test("Find Reused Values… lists values stored in more than one place riskiest first, with configuration left out but counted")
		func reusedValuesReport() async throws {
			let databaseURL = "postgres://app:p4ssw0rd@db.example.com/app"
			let fixture = try await ValueSearchWorkspace([
				(id: "alpha", name: "Alpha", environments: [
					"default": ["DATABASE_URL": databaseURL, "PORT": "3000", "SESSION_SECRET": "s3cret-session"],
					"production": ["SESSION_SECRET": "s3cret-session", "PORT": "3000"],
				]),
				(id: "bravo", name: "Bravo", environments: ["production": ["DB_CONNECTION": databaseURL, "PORT": "3000"]]),
			])
			defer { fixture.tearDown() }
			let host = try await fixture.host()
			defer { host.window.close() }

			NotificationCenter.default.post(name: .findReusedValues, object: nil)
			let sheet = try await fixture.sheet(of: host)
			#expect(try await host.waitForText("Nothing compared yet", in: sheet))
			try await host.click("Scan", in: sheet)
			#expect(try await host.waitForText("2 groups in 2 projects. Riskiest first.", in: sheet))
			let text = try await host.text(in: sheet)
			#expect(text.contains("Shared by 2 keys across 2 projects. Across projects."))
			#expect(text.contains("Shared by 2 keys in Alpha, .env and .env.production. Across environments."))
			#expect(text.contains(ValueSearchWording.leftOut(1)))
			#expect(!text.contains(databaseURL))
			let projects = try #require(text.lines.firstIndex { $0.contains("Across projects.") })
			let environments = try #require(text.lines.firstIndex { $0.contains("Across environments.") })
			#expect(projects < environments, "Groups spanning projects come first")

			try await host.click("Show configuration groups", in: sheet)
			try scroll(sheet, toEnd: true)
			#expect(try await host.waitForText("Configuration · 1", in: sheet))
			#expect(try await host.waitForText("Shared by 3 keys across 2 projects. Across projects.", in: sheet), "Ports repeat for good reason")
			try scroll(sheet, toEnd: false)
			try await host.click("Bravo, .env.production, DB_CONNECTION", in: sheet)
			#expect(try await host.waitUntil { host.window.attachedSheet == nil })
			#expect(fixture.store.selectedProjectId == "bravo")
			#expect(fixture.store.selectedEnvironment == "production")
			#expect(try await host.waitForText("Reused values · 2 groups in 2 projects"))
			#expect(try await host.waitForText("DB_CONNECTION, value hidden, found by value search"))
		}

		@Test("a scan for reused values lists the projects it couldn't compare, said as not compared")
		func reuseNotCompared() async throws {
			let fixture = try await ValueSearchWorkspace([
				(id: "alpha", name: "Alpha", environments: ["default": ["API_TOKEN": Self.shared], "production": ["API_TOKEN": Self.shared]]),
				(id: "charlie", name: "Charlie", environments: ["default": ["API_TOKEN": Self.shared]]),
			])
			defer { fixture.tearDown() }
			fixture.keychain.companionRefusals["charlie"] = .unsupported(feature: "history", version: 2, level: .refuse)
			let host = try await fixture.host()
			defer { host.window.close() }

			NotificationCenter.default.post(name: .findReusedValues, object: nil)
			let sheet = try await fixture.sheet(of: host)
			try await host.click("Scan", in: sheet)
			#expect(try await host.waitForText("1 group in 1 project. 1 project couldn’t be compared.", in: sheet))
			try scroll(sheet, toEnd: true)
			#expect(try await host.waitForText("Charlie, not compared: Made with a newer LPM version. Update LPM Vault to read it.", in: sheet))
		}

		@Test("a key's context menu finds where each environment's value is used")
		func rowContextMenu() async throws {
			let fixture = try await ValueSearchWorkspace([
				(id: "alpha", name: "Alpha", environments: ["default": ["TOKEN": "dev-token"], "production": ["TOKEN": "prod-token"]]),
				(id: "bravo", name: "Bravo", environments: ["default": ["TOKEN": "prod-token"]]),
			])
			defer { fixture.tearDown() }
			let host = try await fixture.host()
			defer { host.window.close() }

			let menu = try await contextMenu(ofRowSaying: "TOKEN", in: host)
			let find = try #require(menu.items.first { $0.title == "Find Where This Value Is Used" })
			let submenu = try #require(find.submenu)
			#expect(submenu.items.map(\.title) == [".env", ".env.production"])
			submenu.performActionForItem(at: 1)
			let sheet = try await fixture.sheet(of: host)
			#expect(try await host.waitForText("2 places in 2 projects in Personal vault.", in: sheet))
			#expect(try await host.waitForText("Bravo, .env, TOKEN, exact match", in: sheet))
		}

		@Test("a key stored in one environment, and a key in an environment's own table, find its value from one menu item")
		func singleEnvironmentContextMenus() async throws {
			let fixture = try await ValueSearchWorkspace([
				(id: "alpha", name: "Alpha", environments: ["default": ["TOKEN": Self.shared, "EMPTY": ""], "production": ["OTHER": "x"]]),
				(id: "bravo", name: "Bravo", environments: ["default": ["PAYMENTS": Self.shared]]),
			])
			defer { fixture.tearDown() }
			let host = try await fixture.host()
			defer { host.window.close() }

			let matrix = try await contextMenu(ofRowSaying: "TOKEN", in: host)
			let find = try #require(matrix.items.first { $0.title == "Find Where This Value Is Used" })
			#expect(find.submenu == nil, "Only one environment stores it")
			matrix.performActionForItem(at: try #require(matrix.items.firstIndex(of: find)))
			let sheet = try await fixture.sheet(of: host)
			#expect(try await host.waitForText("2 places in 2 projects in Personal vault.", in: sheet))
			try await host.click("Done", in: sheet)
			#expect(try await host.waitUntil { host.window.attachedSheet == nil })

			try await host.click(".env", region: CGRect(x: 0, y: 0, width: 0.26, height: 1))
			let row = try await contextMenu(ofRowSaying: "TOKEN, value hidden", in: host)
			#expect(row.items.map(\.title).contains("Find Where This Value Is Used"))
		}

		@Test("a pasted value keeps its line breaks, so a multiline credential is found", arguments: ["\n", "\r\n"])
		func multilineTerm(lineBreak: String) async throws {
			let key = ["-----BEGIN PRIVATE KEY-----", "MIIEvQIBADANBgkqhkiG9w0BAQEFAASC", "", "-----END PRIVATE KEY-----"].joined(separator: lineBreak)
			let fixture = try await ValueSearchWorkspace([
				(id: "alpha", name: "Alpha", environments: ["default": ["SIGNING_KEY": key]]),
			])
			defer { fixture.tearDown() }
			let host = try await fixture.host()
			defer { host.window.close() }

			NotificationCenter.default.post(name: .findValue, object: nil)
			let sheet = try await fixture.sheet(of: host)
			let field = try #require(secureField(in: sheet))
			let editor = try type(key, into: field, of: sheet)
			#expect(fixture.store.valueSearch.term == ExactText(key), "The term is the pasted bytes")
			submit(field, editor: editor)
			#expect(try await host.waitForText("1 place in 1 project in Personal vault.", in: sheet))
		}

		@Test("a running search can be stopped, shows what it didn't read, continues, and reads a project again")
		func stopContinueAndRetry() async throws {
			let fixture = try await ValueSearchWorkspace(["Alpha", "Bravo", "Charlie", "Delta"].map { name in
				(id: name.lowercased(), name: name, environments: ["default": ["API_TOKEN": Self.shared]])
			})
			defer { fixture.tearDown() }
			fixture.keychain.unpromptedReadFailures["delta"] = .unexpectedStatus(-25300)
			let gate = ValueSearchReadGate()
			fixture.keychain.beforeUnpromptedProjectRead = { gate.hold($0) }
			let host = try await fixture.host()
			defer { host.window.close() }

			NotificationCenter.default.post(name: .findValue, object: nil)
			let sheet = try await fixture.sheet(of: host)
			let field = try #require(secureField(in: sheet))
			submit(field, editor: try type(Self.shared, into: field, of: sheet))
			#expect(try await host.waitForText("Searching 2 of 4 projects…", in: sheet))
			#expect(try await host.waitForText("Found so far · 1", in: sheet))
			try await host.click("Stop", in: sheet)
			fixture.keychain.beforeUnpromptedProjectRead = nil
			gate.open()
			#expect(try await host.waitForText("Search stopped. 3 projects weren’t read.", in: sheet))
			#expect(try await host.waitForText("Found in 1 of 4 projects · 1", in: sheet))
			try await host.click("Show Projects", in: sheet)
			try scroll(sheet, toEnd: true)
			#expect(try await host.waitForText("Charlie", in: sheet))
			#expect(try await host.waitForText("Delta", in: sheet))
			try scroll(sheet, toEnd: false)

			try await host.click("Continue", in: sheet)
			#expect(try await host.waitForText("3 places in 3 projects. 1 project couldn’t be searched.", in: sheet))
			try scroll(sheet, toEnd: true)
			#expect(try await host.waitForText("Delta, not searched: The Keychain couldn’t read it.", in: sheet))
			fixture.keychain.unpromptedReadFailures = [:]
			try await host.click("Try Again, Delta", in: sheet)
			#expect(try await host.waitForText("4 places in 4 projects in Personal vault.", in: sheet))

			let again = ValueSearchReadGate()
			fixture.keychain.beforeUnpromptedProjectRead = { again.hold($0) }
			try await host.click("Search Again", in: sheet)
			#expect(try await host.waitForText("Searching 2 of 4 projects…", in: sheet))
			try await host.click("Cancel", in: sheet)
			fixture.keychain.beforeUnpromptedProjectRead = nil
			again.open()
			#expect(try await host.waitUntil { host.window.attachedSheet == nil })
			#expect(try await host.waitForText("Value search · 1 place in 1 project, stopped after 1 of 4"))
		}

		@Test("the field is focused as the sheet opens, Return searches, the field stays focused for the next search, and Escape closes")
		func keyboard() async throws {
			let fixture = try await ValueSearchWorkspace([
				(id: "alpha", name: "Alpha", environments: ["default": ["API_TOKEN": Self.shared]]),
			])
			defer { fixture.tearDown() }
			let host = try await fixture.host()
			defer { host.window.close() }

			NotificationCenter.default.post(name: .findValue, object: nil)
			let sheet = try await fixture.sheet(of: host)
			let field = try #require(secureField(in: sheet))
			#expect(try await host.waitUntil { field.currentEditor() != nil && sheet.firstResponder === field.currentEditor() })
			_ = try type(Self.shared, into: field, of: sheet)
			try host.key("\r", code: 36, in: sheet)
			#expect(try await host.waitForText("1 place in 1 project in Personal vault.", in: sheet))
			#expect(try await host.waitUntil { field.currentEditor() != nil && sheet.firstResponder === field.currentEditor() },
				"The field stays focused for the next search")
			try host.key("\u{1b}", code: 53, in: sheet)
			#expect(try await host.waitUntil { host.window.attachedSheet == nil })
		}

		@Test("a place in the project already open opens in its table, with its key selected, whatever view was showing")
		func openInSameProject() async throws {
			let fixture = try await ValueSearchWorkspace([
				(id: "alpha", name: "Alpha", environments: [
					"default": ["DATABASE_URL": Self.shared, "PORT": "3000"], "production": ["STRIPE_KEY": Self.shared, "PORT": "3000"],
				]),
			])
			defer { fixture.tearDown() }
			let host = try await fixture.host()
			defer { host.window.close() }

			try await host.click(".env", region: CGRect(x: 0, y: 0, width: 0.26, height: 1))
			try await host.click("Raw text")
			NotificationCenter.default.post(name: .findValue, object: nil)
			let sheet = try await fixture.sheet(of: host)
			let field = try #require(secureField(in: sheet))
			submit(field, editor: try type(Self.shared, into: field, of: sheet))
			try await host.click("Alpha, .env.production, STRIPE_KEY, exact match", in: sheet)
			#expect(try await host.waitUntil { host.window.attachedSheet == nil })
			#expect(fixture.store.selectedEnvironment == "production")
			let row = try await host.waitForElement(saying: "STRIPE_KEY, value hidden, found by value search")
			#expect(row.isSelected, "The table shows, with the key selected")
			#expect(try await host.waitForText("Find where the .env.production value is used"), "The inspector shows the key")
		}

		@Test("with organizations, the scope menu says what it chooses, and switching accounts closes the sheet")
		func scopeAndAccountSwitch() async throws {
			let fixture = try await ValueSearchWorkspace([
				(id: "personal", name: "Personal", environments: ["default": ["API_TOKEN": Self.shared]]),
				(id: "team", name: "Team project", environments: ["default": ["API_TOKEN": Self.shared]]),
			], orgs: ["team": "acme"])
			defer { fixture.tearDown() }
			let host = try await fixture.host()
			defer { host.window.close() }

			NotificationCenter.default.post(name: .findValue, object: nil)
			let sheet = try await fixture.sheet(of: host)
			let scope = try await host.waitForElement(saying: "Search in", in: sheet)
			#expect(scope.value == "Personal vault")
			#expect(AccessibilityTree.elements(in: sheet).filter { $0.texts.contains("Search in") }.count == 1,
				"The menu is read once, its name with its choice")
			let field = try #require(secureField(in: sheet))
			submit(field, editor: try type(Self.shared, into: field, of: sheet))
			#expect(try await host.waitForText("1 place in 1 project in Personal vault.", in: sheet))

			fixture.store.selectAccount(.org("acme"))
			#expect(try await host.waitUntil { host.window.attachedSheet == nil })
			#expect(fixture.store.valueSearch.find == nil)
			#expect(try await host.waitForTextToDisappear("Value search ·"))
		}

		@Test("opening a place in another account asks before unsaved changes are discarded")
		func crossAccountOpenAsks() async throws {
			let fixture = try await ValueSearchWorkspace([
				(id: "personal", name: "Personal", environments: ["default": ["API_TOKEN": Self.shared]]),
				(id: "team", name: "Team project", environments: ["staging": ["API_TOKEN": Self.shared]]),
			], orgs: ["team": "acme"])
			defer { fixture.tearDown() }
			let store = fixture.store
			store.keyDrafts.edit(try #require(store.selectedProject), key: "API_TOKEN") { $0.setValue("a new value", in: "default") }
			let host = try await fixture.host()
			defer { host.window.close() }

			NotificationCenter.default.post(name: .findValue, object: nil)
			let sheet = try await fixture.sheet(of: host)
			store.valueSearch.scope = .everyAccount
			let field = try #require(secureField(in: sheet))
			submit(field, editor: try type(Self.shared, into: field, of: sheet))
			#expect(try await host.waitForText("2 places in 2 projects across 2 accounts.", in: sheet))
			try await host.click("Team project, .env.staging, API_TOKEN, exact match, in Acme", in: sheet)
			let dialog = try #require(try await host.waitUntil { sheet.attachedSheet != nil } ? sheet.attachedSheet : nil)
			#expect(try await host.waitForText("Discard your unsaved changes?", in: dialog))
			#expect(try await host.waitForText("Opening API_TOKEN switches to Acme, which discards the changes you haven’t saved.", in: dialog))
			try await host.click("Keep Editing", in: dialog)
			#expect(try await host.waitUntil { sheet.attachedSheet == nil })
			#expect(store.selectedAccount == .personal)

			try await host.click("Team project, .env.staging, API_TOKEN, exact match, in Acme", in: sheet)
			let again = try #require(try await host.waitUntil { sheet.attachedSheet != nil } ? sheet.attachedSheet : nil)
			try await host.click("Discard and Open", in: again)
			#expect(try await host.waitUntil { host.window.attachedSheet == nil })
			#expect(store.selectedProjectId == "team")
			#expect(store.selectedEnvironment == "staging")
		}

		@Test("New Secret and Project Settings wait while the value search sheet is showing")
		func otherCommandsWaitForTheSheet() async throws {
			let fixture = try await ValueSearchWorkspace([
				(id: "alpha", name: "Alpha", environments: ["default": ["API_TOKEN": Self.shared]]),
			])
			defer { fixture.tearDown() }
			let host = try await fixture.host()
			defer { host.window.close() }
			let page = try await host.text().lines

			NotificationCenter.default.post(name: .findValue, object: nil)
			let sheet = try await fixture.sheet(of: host)
			#expect(try await host.waitForText("Nothing searched yet", in: sheet))
			NotificationCenter.default.post(name: .newSecret, object: nil)
			NotificationCenter.default.post(name: .showProjectSettings, object: nil)
			try await host.settle()
			#expect(host.window.attachedSheet === sheet)
			#expect(sheet.attachedSheet == nil, "No sheet opens over it")
			#expect(try await host.text(in: sheet).contains("Nothing searched yet"))

			try await host.click("Cancel", in: sheet)
			#expect(try await host.waitUntil { host.window.attachedSheet == nil })
			try await host.settle()
			#expect(host.window.attachedSheet == nil, "Nothing was waiting to open after it")
			#expect(try await host.text().lines == page, "The page behind it didn't change")
		}

		@Test("a reused value shared by thousands of keys lists them as they scroll into view")
		func largeGroupIsLazy() async throws {
			let values = Dictionary(uniqueKeysWithValues: (0..<10_000).map { ("API_SECRET_\($0)", Self.shared) })
			let fixture = try await ValueSearchWorkspace([(id: "alpha", name: "Alpha", environments: ["default": values])])
			defer { fixture.tearDown() }
			let host = try await fixture.host()
			defer { host.window.close() }

			NotificationCenter.default.post(name: .findReusedValues, object: nil)
			let sheet = try await fixture.sheet(of: host)
			fixture.store.valueSearch.startReuse()
			#expect(try await host.waitForText("Shared by 10000 keys", in: sheet))
			#expect(try await host.waitForText("Alpha, .env, API_SECRET_0", in: sheet))
		}

		@Test("text the sidebar finds no names for can be searched as a value, and moves out of the plain field")
		func sidebarOffersValueSearch() async throws {
			let fixture = try await ValueSearchWorkspace([
				(id: "alpha", name: "Alpha", environments: ["default": ["API_TOKEN": Self.shared]]),
			])
			defer { fixture.tearDown() }
			let host = try await fixture.host()
			defer { host.window.close() }

			let search = try #require(sidebarSearchField(of: host))
			host.window.makeFirstResponder(search)
			let editor = try #require(search.currentEditor() as? NSTextView)
			editor.insertText(Self.shared, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
			search.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: search))
			#expect(try await host.waitForText("No matching projects or keys"))
			let undo = try #require(editor.undoManager)
			#expect(undo.canUndo, "Typing in the plain field can be undone")
			try await host.click("Find it as a value")
			let sheet = try await fixture.sheet(of: host)
			#expect(try await host.waitForText("1 place in 1 project in Personal vault.", in: sheet))
			#expect(try await host.waitForText("Alpha, .env, API_TOKEN, exact match", in: sheet))
			#expect(try await host.waitUntil { search.stringValue.isEmpty }, "The sidebar's plain field no longer holds it")
			#expect(!undo.canUndo, "Undo can't bring it back into the plain field")
		}

		@Test("locking closes the sheet and forgets the term and the results")
		func lockForgets() async throws {
			let fixture = try await ValueSearchWorkspace([
				(id: "alpha", name: "Alpha", environments: ["default": ["API_TOKEN": Self.shared]]),
			])
			defer { fixture.tearDown() }
			let host = try await fixture.host()
			defer { host.window.close() }

			NotificationCenter.default.post(name: .findValue, object: nil)
			let sheet = try await fixture.sheet(of: host)
			let field = try #require(secureField(in: sheet))
			let editor = try type(Self.shared, into: field, of: sheet)
			submit(field, editor: editor)
			#expect(try await host.waitForText("1 place in 1 project in Personal vault.", in: sheet))
			fixture.store.lock()
			#expect(try await host.waitUntil { host.window.attachedSheet == nil })
			#expect(fixture.store.valueSearch.find == nil)
			#expect(fixture.store.valueSearch.term.text.isEmpty)
			await fixture.store.unlock()
			NotificationCenter.default.post(name: .findValue, object: nil)
			let again = try await fixture.sheet(of: host)
			#expect(try await host.waitForText("Nothing searched yet", in: again))
			#expect(secureField(in: again)?.stringValue == "")
		}
	}
}

/// A workspace whose projects a value search reads, unlocked as a person unlocks.
@MainActor
private struct ValueSearchWorkspace {
	let store: VaultStore
	let keychain: MockKeychainService
	let defaults: UserDefaults
	let domain: String

	/// `orgs` assigns projects to organizations the person belongs to.
	init(_ projects: [(id: String, name: String, environments: [String: [String: String]])], orgs: [String: String] = [:]) async throws {
		keychain = MockKeychainService()
		for project in projects { keychain.envStorage[project.id] = (name: project.name, path: "", environments: project.environments) }
		domain = "value-search-ui-\(UUID().uuidString)"
		defaults = try #require(UserDefaults(suiteName: domain))
		store = VaultStore(keychainService: keychain, biometricService: MockBiometricService(), apiService: MockAPIService(), preferences: defaults)
		await store.unlock()
		if !orgs.isEmpty {
			store.currentUser = LPMUser(id: "user", username: "user", name: nil, email: nil, avatarUrl: nil, plan: nil, createdAt: nil,
				orgs: Set(orgs.values).sorted().map { LPMOrg(id: "\($0)-id", slug: $0, name: $0.capitalized, avatarUrl: nil, role: "owner") })
			for (project, slug) in orgs { store.vaultOrgAssociations[project] = slug }
		}
		let first = try #require(projects.first?.id)
		store.openProject(id: first)
		let store = store
		try #require(try await waitUntil { store.selectedProject?.hasLoadedEnvironments == true })
	}

	func host() async throws -> SheetTestHost<some View> {
		let host = SheetTestHost(VaultWorkspaceView(store: store).environment(UpdateChecker())
			.environment(VaultAppearanceSettings(defaults: defaults)).defaultAppStorage(defaults),
			size: NSSize(width: 1200, height: 760), keepsRequestedSize: true, usesHostingView: true)
		let store = store
		#expect(try await host.waitUntil { store.selectedProject.map { store.workspaceSnapshots[$0.id] != nil } ?? false })
		try await host.settle()
		return host
	}

	func sheet<V: View>(of host: SheetTestHost<V>) async throws -> NSWindow {
		try #require(try await host.waitUntil { host.window.attachedSheet != nil })
		return try #require(host.window.attachedSheet)
	}

	func tearDown() {
		store.lock()
		UserDefaults().removePersistentDomain(forName: domain)
	}
}

/// The sidebar's search field: the one editable field over the sidebar.
@MainActor
private func sidebarSearchField<V: View>(of host: SheetTestHost<V>) -> NSTextField? {
	func fields(in view: NSView) -> [NSTextField] {
		if let field = view as? NSTextField { return field.isEditable ? [field] : [] }
		return view.subviews.flatMap(fields)
	}
	host.view.layoutSubtreeIfNeeded()
	return fields(in: host.view).first { $0.convert($0.bounds, to: nil).maxX < VaultMetrics.sidebar }
}

/// Scrolls the window's first scroll view to its end or back to its top:
/// only what's on screen is read, as VoiceOver reads it.
@MainActor
private func scroll(_ window: NSWindow, toEnd: Bool) throws {
	func first(in view: NSView) -> NSScrollView? {
		if let scrollView = view as? NSScrollView { return scrollView }
		for subview in view.subviews { if let found = first(in: subview) { return found } }
		return nil
	}
	let content = try #require(window.contentView)
	content.layoutSubtreeIfNeeded()
	let scrollView = try #require(first(in: content), "The window has a scroll view")
	let clip = scrollView.contentView
	let height = scrollView.documentView?.frame.height ?? 0
	let end = clip.isFlipped ? max(0, height - clip.bounds.height) : 0
	let top = clip.isFlipped ? 0 : max(0, height - clip.bounds.height)
	clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: toEnd ? end : top))
	scrollView.reflectScrolledClipView(clip)
	content.layoutSubtreeIfNeeded()
}

@MainActor
private func secureField(in window: NSWindow) -> NSSecureTextField? {
	func find(in view: NSView) -> NSSecureTextField? {
		if let field = view as? NSSecureTextField { return field }
		for subview in view.subviews { if let field = find(in: subview) { return field } }
		return nil
	}
	return window.contentView.flatMap(find)
}

/// Types `text` into `field` as a person pasting it does, leaving it focused.
@MainActor
private func type(_ text: String, into field: NSSecureTextField, of window: NSWindow) throws -> NSTextView {
	window.makeFirstResponder(field)
	let editor = try #require(field.currentEditor() as? NSTextView)
	editor.insertText(text, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
	field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
	return editor
}

/// Presses Return in the field being edited.
@MainActor
private func submit(_ field: NSSecureTextField, editor: NSTextView) {
	_ = field.delegate?.control?(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:)))
}

/// The context menu of the table row saying `label`.
@MainActor
private func contextMenu<V: View>(ofRowSaying label: String, in host: SheetTestHost<V>) async throws -> NSMenu {
	let row = try await host.waitForElement(saying: label)
	let point = AccessibilityTree.center(of: row, in: host.window)
	let event = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [],
		timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: host.window.windowNumber, context: nil,
		eventNumber: 0, clickCount: 1, pressure: 1))
	let target = try #require(host.view.hitTest(host.view.superview?.convert(point, from: nil) ?? point))
	return try #require(target.menu(for: event) ?? host.view.menu(for: event), "\(label) has a context menu")
}
