import AppKit
import SwiftUI
import Testing

@testable import LPMVault

extension SheetInteractionTests {
	@Suite("Key inspector interactions", .serialized)
	@MainActor
	struct KeyInspectorInteractionTests {
		@Test("a rename and a value edit save together and the inspector follows the new name")
		func renameAndValueSaveTogether() async throws {
			let (store, keychain) = makeStore(["default": ["TOKEN": "dev", "OTHER": "other"], "staging": ["TOKEN": "stg"]])
			defer { store.lock() }
			let host = SheetTestHost(KeyInspectorFixture(store: store), size: NSSize(width: 300, height: 640))
			defer { host.window.close() }
			try await host.settle()
			try host.enterKey("API_TOKEN")
			try host.enterValue("dev-2")
			#expect(try await host.waitForText("2 unsaved changes"))
			#expect(try await host.text().contains("Renames it in all 2 environments"))
			try await host.click("Save")
			let expected: [String: [String: String]] = ["default": ["API_TOKEN": "dev-2", "OTHER": "other"], "staging": ["API_TOKEN": "stg"]]
			#expect(try await host.waitUntil { keychain.envStorage["inspector"]?.environments == expected })
			#expect(try await host.waitForText("No unsaved changes"))
			#expect(try await host.text().contains("API_TOKEN"))
			#expect(keychain.applyVaultTransactionCallCount == 1)
		}

		@Test("a stored value's hidden characters are said in words, and each fix is an edit saved like any other")
		func storedValueHiddenCharacters() async throws {
			let (store, keychain) = makeStore(["default": ["TOKEN": "dev\u{200B}"], "staging": ["TOKEN": " stg"]])
			defer { store.lock() }
			let host = SheetTestHost(KeyInspectorFixture(store: store), size: NSSize(width: 300, height: 640))
			defer { host.window.close() }
			try await host.settle()
			#expect(try await host.waitForText("Warning: the value in .env has hidden characters: zero width space at character 4."))
			#expect(try await host.waitForText("Warning: the value in .env.staging has hidden characters: space at the start."))
			#expect(try await host.waitForText("No unsaved changes"), "A warning is no edit")
			try await host.click("Remove hidden characters")
			#expect(try await host.waitForText("1 unsaved change"))
			try await host.click("Trim the ends")
			#expect(try await host.waitForText("2 unsaved changes"))
			try await host.click("Save")
			#expect(try await host.waitUntil {
				keychain.envStorage["inspector"]?.environments == ["default": ["TOKEN": "dev"], "staging": ["TOKEN": "stg"]]
			})
			#expect(try await host.waitForTextToDisappear("hidden characters"))
		}

		@Test("an edit to characters Swift calls equal to the stored ones is an edit, named and saved as typed")
		func canonicallyEqualEdit() async throws {
			let (store, keychain) = makeStore(["default": ["TOKEN": "a\u{2000}b"]])
			defer { store.lock() }
			let host = SheetTestHost(KeyInspectorFixture(store: store), size: NSSize(width: 300, height: 640))
			defer { host.window.close() }
			try await host.settle()
			#expect(try await host.waitForText("Warning: the value in .env has hidden characters: en quad at character 2."))
			try host.enterValue("a\u{2002}b")
			#expect(try await host.waitForText("1 unsaved change"))
			#expect(try await host.waitForText("Warning: the value in .env has hidden characters: en space at character 2."))
			try await host.click("Save")
			#expect(try await host.waitUntil { stored(keychain, "default", "TOKEN").map(ExactText.init) == ExactText("a\u{2002}b") })
			#expect(try await host.waitForText("No unsaved changes"))
		}

		@Test("a value pasted into the masked field keeps its line breaks")
		func maskedMultilineEdit() async throws {
			let (store, keychain) = makeStore(["default": ["TOKEN": "dev"]])
			defer { store.lock() }
			let host = SheetTestHost(KeyInspectorFixture(store: store), size: NSSize(width: 300, height: 640))
			defer { host.window.close() }
			try await host.settle()
			let value = "line one\r\nline two\n"
			try host.enterValue(value)
			#expect(try await host.waitForText("1 unsaved change"))
			try await host.click("Save")
			#expect(try await host.waitUntil { stored(keychain, "default", "TOKEN").map(ExactText.init) == ExactText(value) })
		}

		@Test("an edited value is checked as it's typed, and a revealed one shows where its hidden characters are")
		func editedValueHiddenCharacters() async throws {
			let (store, keychain) = makeStore(["default": ["TOKEN": "dev"]])
			defer { store.lock() }
			let host = SheetTestHost(KeyInspectorFixture(store: store), size: NSSize(width: 300, height: 640))
			defer { host.window.close() }
			try await host.settle()
			try host.enterValue("new\u{FEFF}")
			#expect(try await host.waitForText("Warning: the value in .env has hidden characters: zero width no-break space at character 4."))
			try host.click(.reveal)
			#expect(try await host.waitForText("The value in .env with its hidden characters shown, revealed visually"))
			#expect(keychain.envStorage["inspector"]?.environments["default"] == ["TOKEN": "dev"], "Nothing is saved until Save")
			#expect(keychain.applyVaultTransactionCallCount == 0)
		}

		@Test("value fields mark their content so macOS doesn't offer saved passwords")
		func valueFieldsOfferNoPasswords() async throws {
			let (store, _) = makeStore(["default": ["TOKEN": "dev"], "staging": ["TOKEN": "stg"]])
			defer { store.lock() }
			let host = SheetTestHost(KeyInspectorFixture(store: store), size: NSSize(width: 300, height: 640))
			defer { host.window.close() }
			try await host.settle()
			#expect(host.secureFieldContentTypes == [.oneTimeCode, .oneTimeCode])
		}

		@Test("a name that collides with another key is reported and never saved")
		func nameCollision() async throws {
			let (store, keychain) = makeStore(["default": ["TOKEN": "dev", "OTHER": "other"]])
			defer { store.lock() }
			let host = SheetTestHost(KeyInspectorFixture(store: store), size: NSSize(width: 300, height: 640))
			defer { host.window.close() }
			try await host.settle()
			try host.enterKey("other")
			#expect(try await host.waitForText("OTHER already exists in .env"))
			try await host.click("Save")
			try host.returnWhileEditing("key", modifiers: [])
			try await host.settle()
			#expect(keychain.applyVaultTransactionCallCount == 0)
			#expect(keychain.envStorage["inspector"]?.environments["default"] == ["TOKEN": "dev", "OTHER": "other"])
		}

		@Test("a refresh keeps edits that changed or disappeared elsewhere until the person resolves them", arguments: ["changed", "deleted", "empty-deleted"])
		func refreshKeepsConflictingEdits(change: String) async throws {
			let original = change == "empty-deleted" ? "" : "old"
			let (store, keychain) = makeStore(["default": ["TOKEN": original], "staging": ["TOKEN": "stg"]])
			defer { store.lock() }
			let host = SheetTestHost(KeyInspectorFixture(store: store), size: NSSize(width: 300, height: 640))
			defer { host.window.close() }
			try await host.settle()
			try host.enterValue("unsaved-draft")
			try await host.settle()
			if change == "changed" {
				keychain.envStorage["inspector"]?.environments["default"]?["TOKEN"] = "cli-new"
			} else {
				keychain.envStorage["inspector"]?.environments["default"]?.removeValue(forKey: "TOKEN")
			}
			await store.refreshLocalState()
			try await host.settle()
			#expect(host.value == "unsaved-draft")
			#expect(try await host.waitForText(change == "changed" ? "Changed outside the editor" : "Deleted outside the editor"))
			try host.returnWhileEditing("value", modifiers: [])
			try await host.settle()
			#expect(keychain.applyVaultTransactionCallCount == 0)

			try await host.click(change == "changed" ? "Keep mine" : "Add again")
			try await host.click("Save")
			#expect(try await host.waitUntil { stored(keychain, "default", "TOKEN") == "unsaved-draft" })
			#expect(stored(keychain, "staging", "TOKEN") == "stg")
		}

		@Test("the single-environment view edits its environment and shows other unsaved edits; the project view edits them all")
		func viewScope() async throws {
			let (store, _) = makeStore(["default": ["TOKEN": "dev"], "staging": ["TOKEN": "stg"], "production": [:]])
			defer { store.lock() }
			let project = SheetTestHost(KeyInspectorFixture(store: store), size: NSSize(width: 300, height: 640))
			try await project.settle()
			#expect(project.secureValues == ["dev", "stg"])
			#expect(try await project.text().contains("Add to .env.production"))
			try await project.click("Add to .env.production")
			#expect(try await project.waitUntil { project.secureValues == ["dev", "", "stg"] })
			try project.enterValue("stg-2", at: 2)
			#expect(try await project.waitForText("2 unsaved changes"))
			project.window.close()

			let single = SheetTestHost(KeyInspectorFixture(store: store, mode: .environment("default")), size: NSSize(width: 300, height: 640))
			defer { single.window.close() }
			try await single.settle()
			#expect(single.secureValues == ["dev", "", "stg-2"])
			store.keyDrafts.discardAll()
			try await single.settle()
			#expect(single.secureValues == ["dev"])
			#expect(try await single.text().contains("Add to another environment"))
		}

		@Test("a value's controls show at rest, so the field's end never looks empty")
		func controlsAtRest() async throws {
			let (store, _) = makeStore(["default": ["TOKEN": "old"]])
			defer { store.lock() }
			let host = SheetTestHost(KeyInspectorFixture(store: store), size: NSSize(width: 300, height: 640))
			defer { host.window.close() }
			try await host.settle()
			for control in ["Copy .env value", Self.more] {
				let drawn = try await host.drawnFrame(saying: control)
				#expect(drawn.width > 4 && drawn.height > 1, "\(control) is drawn without the pointer over the field: \(drawn)")
			}
		}

		@Test("with values in several environments, a labeled Reveal shows them all, and then says Hide")
		func revealAllIsLabeled() async throws {
			let (store, _) = makeStore(["default": ["TOKEN": "one"], "production": ["TOKEN": "two"]])
			defer { store.lock() }
			let host = SheetTestHost(KeyInspectorFixture(store: store), size: NSSize(width: 300, height: 700))
			defer { host.window.close() }
			let reveal = try await host.waitForElement(saying: "Reveal this key in all environments")
			#expect(reveal.role == .button)
			let drawn = try await host.drawnFrame(saying: "Reveal this key in all environments")
			#expect(drawn.width > 30, "It shows its name beside the eye, not the eye alone: \(drawn)")
			let label = try await host.drawnFrame(saying: "VALUES")
			#expect(label.height < 16 && label.width > 30, "The section's label stays on one line beside them: \(label)")
			try await host.click("Reveal this key in all environments")
			#expect(try await host.waitForText("Hide this key in all environments"))
		}

		@Test("copying or cutting a revealed value's text goes through the guarded copy, never straight to the clipboard, and it can't be dragged out")
		func revealedFieldCopy() async throws {
			let clipboard = GeneralPasteboardBackup()
			defer { clipboard.restore() }
			let (store, _) = makeStore(["default": ["TOKEN": "s3cret-token"], "staging": ["TOKEN": "stg"]])
			defer { store.lock() }
			let copies = CopiedRequests()
			let host = SheetTestHost(KeyInspectorFixture(store: store, onCopy: { request in
				copies.requests.append(request)
				if copies.succeeds { request.onCopied?() }
			}), size: NSSize(width: 300, height: 700))
			defer { host.window.close() }
			try await host.click("Reveal this key in all environments")
			var found: NSTextField?
			#expect(try await host.waitUntil {
				found = Self.field(in: host.view) { !($0 is NSSecureTextField) && $0.stringValue == "s3cret-token" }
				return found != nil
			})
			let field = try #require(found)
			#expect(host.window.makeFirstResponder(field))
			let editor = try #require(field.currentEditor() as? NSTextView)

			editor.setSelectedRange(NSRange(location: 0, length: 6))
			#expect(NSApp.sendAction(#selector(NSText.copy(_:)), to: editor, from: nil))
			#expect(try await host.waitUntil { copies.requests.map(\.selection) == ["s3cret"] })
			#expect(copies.requests.first?.environment == "default" && copies.requests.first?.key == "TOKEN")

			copies.succeeds = false
			editor.setSelectedRange(NSRange(location: 6, length: 6))
			#expect(NSApp.sendAction(#selector(NSText.cut(_:)), to: editor, from: nil))
			#expect(try await host.waitUntil { copies.requests.map(\.selection) == ["s3cret", "-token"] })
			#expect(editor.string == "s3cret-token", "A cut whose copy wasn't made, as when approval is declined, takes nothing out")

			copies.succeeds = true
			editor.setSelectedRange(NSRange(location: 6, length: 6))
			#expect(NSApp.sendAction(#selector(NSText.cut(_:)), to: editor, from: nil))
			#expect(try await host.waitUntil { copies.requests.count == 3 })
			#expect(try await host.waitUntil { editor.string == "s3cret" }, "Once copied, Cut takes the text out of the field")

			let click = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
				windowNumber: host.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
			let actions = Set((editor.menu(for: click)?.items ?? []).compactMap(\.action))
			#expect(actions == [#selector(NSText.cut(_:)), #selector(NSText.copy(_:)), #selector(NSText.paste(_:)), #selector(NSText.selectAll(_:))],
				"No Share, Look Up, Translate or Services")

			editor.selectAll(nil)
			#expect(!editor.writeSelection(to: NSPasteboard(name: .drag), types: [.string]), "Nothing drags out or goes to a Service")
			#expect(!clipboard.changed, "The clipboard itself was never written")
		}

		private static func field(in view: NSView, where matches: (NSTextField) -> Bool) -> NSTextField? {
			if let field = view as? NSTextField, matches(field) { return field }
			for subview in view.subviews {
				if let found = field(in: subview, where: matches) { return found }
			}
			return nil
		}

		@Test("a value's More menu opens in the app's popover: a format copies, and Generate opens the generator in its place")
		func moreMenu() async throws {
			let (store, _) = makeStore(["default": ["TOKEN": "old"]])
			defer { store.lock() }
			let copies = CopiedFormats()
			let host = SheetTestHost(KeyInspectorFixture(store: store, onCopy: { copies.formats.append($0.format) }), size: NSSize(width: 300, height: 640))
			defer { host.window.close() }
			try await host.settle()
			try await host.click(Self.more)
			let menu = try await host.popoverWindow()
			#expect(try await host.waitForText("COPY AS", in: menu))
			try await host.click("KEY=value", in: menu)
			#expect(try await host.waitUntil { copies.formats == [.dotenv] })
			#expect(try await host.waitUntil { !menu.isVisible }, "Choosing closes the menu")
			try await host.click(Self.more)
			let again = try await host.popoverWindow()
			try await host.click("Generate Value…", in: again)
			let panel = try await host.generatorWindow()
			#expect(try await host.waitUntil { !again.isVisible })
			#expect(try await host.perform(Self.closeGenerator, on: Self.more))
			#expect(try await host.waitForGeneratorDismissal(panel))
		}

		@Test("inspector generation changes only the draft until saved", arguments: [ColorScheme.light, .dark])
		func generatorDraft(scheme: ColorScheme) async throws {
			let (store, keychain) = makeStore(["default": ["TOKEN": "old"], "production": ["TOKEN": "production-old"]])
			defer { store.lock() }
			let host = SheetTestHost(KeyInspectorFixture(store: store).environment(\.colorScheme, scheme), size: NSSize(width: 300, height: 640))
			defer { host.window.close() }
			try await host.settle()
			#expect(try await host.perform(Self.generate, on: Self.more))
			let panel = try await host.generatorWindow()
			try await host.click("Password", in: panel)
			try await host.waitUntil { host.value != "old" }
			let generated = host.value
			#expect(generated.count == SecretValueGenerator.defaultLength)
			#expect(stored(keychain, "default", "TOKEN") == "old")
			// Synthetic clicks bypass the popover's outside-click monitor, so close it as VoiceOver does.
			#expect(try await host.perform(Self.closeGenerator, on: Self.more))
			#expect(try await host.waitForGeneratorDismissal(panel))
			try await host.click("Revert")
			#expect(try await host.waitUntil { host.value == "old" })
			#expect(try await host.perform(Self.generate, on: Self.more))
			let secondPanel = try await host.generatorWindow()
			try await host.click("UUID v4", in: secondPanel, caseInsensitive: true)
			try await host.waitUntil { UUID(uuidString: host.value) != nil }
			let second = host.value
			#expect(try await host.perform(Self.closeGenerator, on: Self.more))
			#expect(try await host.waitForGeneratorDismissal(secondPanel))
			try await host.click("Save")
			#expect(try await host.waitUntil { stored(keychain, "default", "TOKEN") == second })
			#expect(stored(keychain, "production", "TOKEN") == "production-old")
		}

		@Test("inspector generation cannot replace a pending save or a conflicting edit", arguments: ["save", "conflict"])
		func generatorUnavailable(reason: String) async throws {
			let (store, keychain) = makeStore(["default": ["TOKEN": "old"]])
			defer { store.lock() }
			let host = SheetTestHost(KeyInspectorFixture(store: store), size: NSSize(width: 300, height: 640))
			defer { host.window.close() }
			try await host.settle()
			#expect(try await host.perform(Self.generate, on: Self.more))
			let panel = try await host.generatorWindow()
			try await host.click("Hexadecimal", in: panel)
			try await host.waitUntil { host.value != "old" }
			let generated = host.value
			let release = DispatchSemaphore(value: 0)
			defer { release.signal() }
			if reason == "save" {
				let entered = DispatchSemaphore(value: 0)
				keychain.beforeKeychainTransaction = { entered.signal(); release.wait() }
				try await host.click("Save")
				let didEnter = await withCheckedContinuation { continuation in
					DispatchQueue.global().async { continuation.resume(returning: entered.wait(timeout: .now() + testWaitSeconds) == .success) }
				}
				try #require(didEnter)
			} else {
				store.projects[0].environments["default"]?["TOKEN"] = "external"
				#expect(try await host.waitForText("Changed outside the editor"))
			}
			#expect(try await host.waitForGeneratorDismissal(panel))
			#expect(try await !host.perform(Self.generate, on: Self.more), "Generate Value… is unavailable")
			try await host.settle()
			#expect(try await host.visibleGeneratorWindow() == nil)
			#expect(host.value == generated)
			if reason == "conflict" {
				try await host.click("Use latest")
				#expect(try await host.waitUntil { host.value == "external" })
				#expect(try await host.perform(Self.generate, on: Self.more))
				let recoveredPanel = try await host.generatorWindow()
				#expect(try await host.perform(Self.closeGenerator, on: Self.more))
				#expect(try await host.waitForGeneratorDismissal(recoveredPanel))
			}
		}

		@Test("Esc first leaves a field and keeps its edit, then a second Esc closes the inspector", arguments: ["key", "value"])
		func escapeLeavesFieldThenCloses(field: String) async throws {
			let (store, _) = makeStore(["default": ["TOKEN": "dev"]])
			defer { store.lock() }
			let closes = CloseCounter()
			let host = SheetTestHost(KeyInspectorFixture(store: store, onClose: { closes.count += 1 }), size: NSSize(width: 300, height: 640))
			defer { host.window.close() }
			try await host.settle()
			let secure = field == "value"
			if secure { try host.enterValue("dev-2") } else { try host.enterKey("API_TOKEN") }
			try await host.settle()
			try host.escapeWhileEditing(fieldAt: 0, secure: secure)
			#expect(try await host.waitUntilRendered { try !host.isEditing(fieldAt: 0, secure: secure) })
			#expect(closes.count == 0)
			#expect(try await host.waitForText("1 unsaved change"))
			try host.sendEscape()
			#expect(try await host.waitUntilRendered { closes.count == 1 })
			let id = VaultKeyDraft.ID(projectID: "inspector", key: "TOKEN")
			#expect(secure ? store.keyDrafts.draft(id)?.value(in: "default") == "dev-2" : store.keyDrafts.draft(id)?.name == "API_TOKEN")
		}

		@Test("the pencil next to the key name starts editing it")
		func pencilEditsKeyName() async throws {
			let (store, _) = makeStore(["default": ["TOKEN": "dev"]])
			defer { store.lock() }
			let host = SheetTestHost(KeyInspectorFixture(store: store), size: NSSize(width: 300, height: 640))
			defer { host.window.close() }
			try await host.settle()
			#expect(try !host.isEditing(fieldAt: 0, secure: false))
			// The pencil sits after the name field, past the row's spacing.
			try host.click(afterPlainFieldAt: 0, offset: 12)
			#expect(try await host.waitUntil { try host.isEditing(fieldAt: 0, secure: false) })
		}

		@Test("a description typed in the inspector is saved to lpm.json with the rest of the key")
		func descriptionSave() async throws {
			let folder = FileManager.default.temporaryDirectory.appending(path: "inspector-description-\(UUID().uuidString)").path
			try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
			defer { try? FileManager.default.removeItem(atPath: folder) }
			try #"{"vault": "inspector"}"#.write(toFile: folder + "/lpm.json", atomically: true, encoding: .utf8)
			let (store, keychain) = makeStore(["default": ["TOKEN": "dev"]], path: folder)
			defer { store.lock() }
			store.reloadKeyDescriptions()
			let host = SheetTestHost(KeyInspectorFixture(store: store), size: NSSize(width: 300, height: 640))
			defer { host.window.close() }
			#expect(try await host.waitUntil { store.keyDescriptions["inspector"] != nil })
			#expect(try await host.waitForText("DESCRIPTION", exactly: true))
			#expect(try await host.text().contains("Stored in lpm.json, not encrypted"))
			try host.enterText("Rotated monthly by the billing team", at: 1)
			#expect(try await host.waitForText("1 unsaved change"))
			try await host.click("Save")
			#expect(try await host.waitUntil {
				(try? ProjectEnvSchemaFile.rules(inFolder: folder, vaultID: "inspector").descriptions) == ["TOKEN": "Rotated monthly by the billing team"]
			})
			#expect(try await host.waitForText("No unsaved changes"))
			#expect(keychain.applyVaultTransactionCallCount == 0)
		}

		@Test("an edit to characters Swift calls equal to the last edit is checked against the rules again")
		func canonicallyEqualEditIsRechecked() async throws {
			let folder = FileManager.default.temporaryDirectory.appending(path: "inspector-recheck-\(UUID().uuidString)").path
			try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
			defer { try? FileManager.default.removeItem(atPath: folder) }
			try #"{"envSchema":{"vars":{"TOKEN":{"minLength":2}}}}"#.write(toFile: folder + "/lpm.json", atomically: true, encoding: .utf8)
			let (store, _) = makeStore(["default": ["TOKEN": "ok"]], path: folder)
			defer { store.lock() }
			store.reloadKeyDescriptions()
			let host = SheetTestHost(KeyInspectorFixture(store: store), size: NSSize(width: 300, height: 640))
			defer { host.window.close() }
			#expect(try await host.waitUntil { store.valueChecks["inspector"] != nil })
			try host.enterValue("\u{E9}")
			#expect(try await host.waitForText("Too short"))
			try host.enterValue("e\u{301}")
			#expect(try await host.waitForTextToDisappear("Too short"), "two scalars meet the rule")
			#expect(store.isUnlocked && store.selectedProject != nil, "the inspector is still shown, so the rule is what passed")
		}

		@Test("a rejected schema rename keeps its error and draft visible")
		func rejectedRenameErrorStaysVisible() async throws {
			let folder = FileManager.default.temporaryDirectory.appending(path: "inspector-partial-rename-\(UUID().uuidString)").path
			try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
			defer { try? FileManager.default.removeItem(atPath: folder) }
			try #"{"envSchema":{"vars":{"TOKEN":{"required":true}}}}"#.write(toFile: folder + "/lpm.json", atomically: true, encoding: .utf8)
			let (store, _) = makeStore(["default": ["TOKEN": "dev"]], path: folder)
			defer { store.lock() }
			store.reloadKeyDescriptions()
			let host = SheetTestHost(KeyInspectorFixture(store: store), size: NSSize(width: 300, height: 640))
			defer { host.window.close() }
			#expect(try await host.waitUntil { store.keyDescriptions["inspector"] != nil })
			try await host.settle()
			try host.enterKey("NEW")
			try "{".write(toFile: folder + "/lpm.json", atomically: true, encoding: .utf8)
			try await host.click("Save")
			#expect(try await host.waitForText("Could not update lpm.json"))
			#expect(try await host.text().contains("lpm.json is not valid JSON"))
			#expect(try await host.text().contains("1 unsaved change"))
		}

		@Test("a deferred Save action cannot save a later account's draft")
		func deferredSaveSessionLifetime() async throws {
			let (store, keychain) = makeStore(["default": ["TOKEN": "dev"]])
			defer { store.lock() }
			let host = SheetTestHost(KeyInspectorFixture(store: store), size: NSSize(width: 300, height: 640))
			defer { host.window.close() }
			try await host.settle()
			try host.enterValue("Old session")
			try await host.settle()
			try host.returnWhileEditing("value", modifiers: [])
			store.selectedAccount = .org("other")
			store.selectedAccount = .personal
			let id = VaultKeyDraft.ID(projectID: "inspector", key: "TOKEN")
			store.keyDrafts.edit(try #require(store.selectedProject), key: "TOKEN") { $0.setValue("Fresh session", in: "default") }
			let fresh = store.keyDrafts.draft(id)
			try await host.settle()
			#expect(store.keyDrafts.draft(id) == fresh)
			#expect(keychain.applyVaultTransactionCallCount == 0)
		}

		private static let generate = "Generate a value for .env"
		private static let more = "More for the .env value"
		private static let closeGenerator = "Close the value generator for .env"

		private func makeStore(_ environments: [String: [String: String]], path: String = "") -> (VaultStore, MockKeychainService) {
			let keychain = MockKeychainService()
			keychain.envStorage["inspector"] = (name: "Inspector", path: path, environments: environments)
			let preferences = UserDefaults(suiteName: "key-inspector-\(UUID().uuidString)")!
			let store = VaultStore(keychainService: keychain, biometricService: MockBiometricService(), apiService: MockAPIService(), preferences: preferences)
			store.selectedProjectId = "inspector"
			store.projects = [VaultProject(id: "inspector", name: "Inspector", path: path, environments: environments)]
			store.isUnlocked = true
			return (store, keychain)
		}

		private func stored(_ keychain: MockKeychainService, _ environment: String, _ key: String) -> String? {
			keychain.envStorage["inspector"]?.environments[environment]?[key]
		}
	}
}

@MainActor
private final class CloseCounter {
	var count = 0
}

@MainActor
private final class CopiedFormats {
	var formats: [VaultCopyFormat] = []
}

private struct KeyInspectorFixture: View {
	@Bindable var store: VaultStore
	var mode: VaultWorkspaceMode = .matrix
	var onClose: () -> Void = {}
	var onCopy: (VaultValueCopy) -> Void = { _ in }
	@State private var selectedKey: String? = "TOKEN"
	@State private var revealedKeys: Set<String> = []

	var body: some View {
		if let project = store.selectedProject {
			VaultInspectorView(
				store: store,
				project: project,
				environments: store.orderedEnvironmentNames(for: project),
				mode: mode,
				selectedKey: selectedKey,
				revealedKeys: $revealedKeys,
				onClose: onClose,
				onCopy: onCopy,
				onDelete: { _, _ in },
				onAddElsewhere: { _, _ in },
				onRenamed: { key, newKey in
					if selectedKey == key { selectedKey = newKey }
				}
			)
			.frame(width: 300, height: 640)
		}
	}
}

@MainActor
private final class CopiedRequests {
	var requests: [VaultValueCopy] = []
	/// Whether the copy is made, as an approval allows.
	var succeeds = true
}

/// The person's clipboard as a test found it, put back afterwards should the
/// test write it, so a failing run doesn't leave a value there.
@MainActor
final class GeneralPasteboardBackup {
	private let changeCount = NSPasteboard.general.changeCount
	private let items: [[NSPasteboard.PasteboardType: Data]] = (NSPasteboard.general.pasteboardItems ?? []).map { item in
		Dictionary(uniqueKeysWithValues: item.types.compactMap { type in item.data(forType: type).map { (type, $0) } })
	}

	var changed: Bool { NSPasteboard.general.changeCount != changeCount }

	func restore() {
		guard changed else { return }
		NSPasteboard.general.clearContents()
		NSPasteboard.general.writeObjects(items.map { entries in
			let item = NSPasteboardItem()
			for (type, data) in entries { item.setData(data, forType: type) }
			return item
		})
	}
}
