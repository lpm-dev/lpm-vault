import AppKit
import SwiftUI
import Testing

@testable import LPMVault

/// The wait before a copy is cleared: it records how long each copy asked
/// for, and ends only when the test says the time is up.
final class ClipboardClearWaits: @unchecked Sendable {
	private let lock = NSLock()
	private var requested: [Duration] = []
	private var waiting: [CheckedContinuation<Void, Never>] = []

	var durations: [Duration] { lock.withLock { requested } }

	var sleep: @Sendable (Duration) async throws -> Void {
		{ [self] duration in
			await withCheckedContinuation { continuation in
				lock.withLock {
					requested.append(duration)
					waiting.append(continuation)
				}
			}
		}
	}

	func elapse() {
		let ended = lock.withLock {
			defer { waiting.removeAll() }
			return waiting
		}
		for continuation in ended { continuation.resume() }
	}
}

extension SheetInteractionTests {
	@Suite("Raw text interaction", .serialized)
	@MainActor
	struct RawTextInteractionTests {
		private static let values = ["API_TOKEN": "tok en", "DATABASE_URL": "postgres://app:pw@db:5432/demo", "LOG_LEVEL": "info"]

		@Test("Raw text masks values, and copying takes the real lines a selection touches, without Touch ID, for 10 seconds")
		func copySelectedLines() async throws {
			let waits = ClipboardClearWaits()
			defer { waits.elapse() }
			let (store, biometric, _) = makeStore(clearWaits: waits)
			defer { store.lock() }
			let host = try await rawText(store)
			defer { host.window.close() }
			#expect(try await host.waitForText("API_TOKEN=\(VaultRawText.mask)"))
			let text = try await host.text()
			#expect(!text.contains("postgres://") && !text.contains("tok en"), "Hidden values aren't in the text at all")
			for status in ["3 lines", "values masked", "⌘A selects all"] { #expect(text.contains(status), "The status says \(status)") }
			try record(host, named: "raw-text-masked")
			let textView = try codeView(in: host)
			let lines = textView.string as NSString
			let firstLine = lines.lineRange(for: NSRange(location: 0, length: 0))
			let partial = NSRange(location: firstLine.length - 4, length: 8)
			textView.setSelectedRange(partial)
			#expect(textView.selectedRange() == lines.lineRange(for: partial), "A selection takes whole lines")
			#expect(try await host.waitForText("2 lines selected"))
			NSApp.sendAction(#selector(NSText.copy(_:)), to: textView, from: nil)
			let pasteboard = store.clipboard.pasteboard
			#expect(pasteboard.string(forType: .string) == "API_TOKEN=\"tok en\"\nDATABASE_URL=postgres://app:pw@db:5432/demo\n")
			#expect(pasteboard.types?.contains(ClipboardManager.concealedType) == true)
			#expect(pasteboard.types?.contains(ClipboardManager.transientType) == true)
			#expect(biometric.authenticateCallCount == 0 && biometric.confirmationReasons.isEmpty)
			#expect(try await host.waitForText("Copied 2 lines · clears in 10s"))
			try record(host, named: "raw-text-copied")
			#expect(try await host.waitUntil { waits.durations == [.seconds(10)] })
			waits.elapse()
			#expect(try await host.waitUntil { pasteboard.string(forType: .string) == nil })
		}

		@Test("Copy all asks for no Touch ID, and its copy clears after 10 seconds, as every copy does")
		func copyAll() async throws {
			let waits = ClipboardClearWaits()
			defer { waits.elapse() }
			let (store, biometric, _) = makeStore(clearWaits: waits)
			defer { store.lock() }
			let host = try await rawText(store)
			defer { host.window.close() }
			try await host.click("Copy all")
			#expect(try await host.waitUntil {
				store.clipboard.pasteboard.string(forType: .string) == ClipboardManager.dotenvText(for: Self.values)
			})
			#expect(try await host.waitForText("Copied"))
			#expect(biometric.authenticateCallCount == 0 && biometric.confirmationReasons.isEmpty)
			#expect(try await host.waitUntil { waits.durations == [.seconds(10)] })
		}

		@Test("revealing shows the real lines, keeps the same lines selected, and the status says values are revealed")
		func revealKeepsSelection() async throws {
			let (store, _, _) = makeStore()
			defer { store.lock() }
			let host = try await rawText(store)
			defer { host.window.close() }
			let textView = try codeView(in: host)
			let masked = textView.string as NSString
			let second = masked.lineRange(for: NSRange(location: masked.lineRange(for: NSRange(location: 0, length: 0)).length, length: 0))
			textView.setSelectedRange(second)
			#expect(try await host.waitForText("1 line selected"))
			try await host.click("Reveal")
			#expect(try await host.waitForText("DATABASE_URL=postgres://app:pw@db:5432/demo"))
			let text = try await host.text()
			#expect(text.contains("API_TOKEN=\"tok en\"") && text.contains("values revealed"))
			#expect((textView.string as NSString).substring(with: textView.selectedRange()) == "DATABASE_URL=postgres://app:pw@db:5432/demo\n")
			try record(host, named: "raw-text-revealed")
		}

		@Test("a drag over parts of two lines selects both lines whole")
		func dragSelectsWholeLines() async throws {
			let (store, _, _) = makeStore()
			defer { store.lock() }
			let host = try await rawText(store)
			defer { host.window.close() }
			let textView = try codeView(in: host)
			let layoutManager = try #require(textView.layoutManager)
			let container = try #require(textView.textContainer)
			func point(at index: Int) -> NSPoint {
				let glyph = layoutManager.glyphIndexForCharacter(at: index)
				let rect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
					.offsetBy(dx: textView.textContainerOrigin.x, dy: textView.textContainerOrigin.y)
				return textView.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
			}
			func event(_ type: NSEvent.EventType, at location: NSPoint) throws -> NSEvent {
				try #require(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
					windowNumber: host.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
			}
			let lines = textView.string as NSString
			let first = lines.lineRange(for: NSRange(location: 0, length: 0))
			let second = lines.lineRange(for: NSRange(location: first.length, length: 0))
			// The text view tracks a drag in its mouse-down, reading the events after it.
			NSApp.postEvent(try event(.leftMouseDragged, at: point(at: first.length + 3)), atStart: false)
			NSApp.postEvent(try event(.leftMouseUp, at: point(at: first.length + 3)), atStart: false)
			textView.mouseDown(with: try event(.leftMouseDown, at: point(at: 4)))
			#expect(textView.selectedRange() == NSRange(location: 0, length: NSMaxRange(second)))
			#expect(try await host.waitForText("2 lines selected"))
		}

		@Test("copying lines during a refresh copies the values it publishes")
		func copyWaitsForRefresh() async throws {
			let keychain = MockKeychainService()
			let (store, _, _) = makeStore(keychain: keychain)
			defer { store.lock() }
			let host = try await rawText(store)
			defer { host.window.close() }
			let textView = try codeView(in: host)
			let lines = textView.string as NSString
			textView.setSelectedRange(lines.lineRange(for: NSRange(location: lines.lineRange(for: NSRange(location: 0, length: 0)).length, length: 0)))
			let entered = DispatchSemaphore(value: 0)
			let release = DispatchSemaphore(value: 0)
			keychain.beforeKeychainTransaction = { entered.signal(); release.wait() }
			let refresh = Task { await store.refreshLocalState() }
			await withCheckedContinuation { continuation in
				DispatchQueue.global().async { entered.wait(); continuation.resume() }
			}
			keychain.beforeKeychainTransaction = nil
			keychain.envStorage["raw"]?.environments["default"]?["DATABASE_URL"] = "postgres://refreshed"
			NSApp.sendAction(#selector(NSText.copy(_:)), to: textView, from: nil)
			#expect(store.clipboard.pasteboard.string(forType: .string) == nil, "Nothing is copied before the refresh publishes")
			release.signal()
			await refresh.value
			#expect(try await host.waitUntil { store.clipboard.pasteboard.string(forType: .string) == "DATABASE_URL=postgres://refreshed\n" })
		}

		@Test("only Copy takes the text out: its menu has Copy and Select All, and drags, Services and Writing Tools get nothing")
		func nothingElseTakesTheText() async throws {
			let (store, _, _) = makeStore()
			defer { store.lock() }
			let host = try await rawText(store)
			defer { host.window.close() }
			try await host.click("Reveal")
			let textView = try codeView(in: host)
			#expect(try await host.waitUntil { textView.string.contains("postgres://") })
			textView.selectAll(nil)
			let click = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
				windowNumber: host.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
			#expect(textView.menu(for: click)?.items.map(\.title) == ["Copy", "Select All"])
			#expect(!textView.writeSelection(to: .withUniqueName(), types: [.string]))
			#expect(textView.validRequestor(forSendType: .string, returnType: nil) == nil)
			if #available(macOS 15.0, *) { #expect(textView.writingToolsBehavior == .none) }
			#expect(!textView.isEditable)
		}

		@Test("Edit shows every key with its real value; Save writes the edit, and Undo puts it back")
		func editSaveAndUndo() async throws {
			let (store, _, keychain) = makeStore()
			defer { store.lock() }
			let undoWindow = ManualFeedbackTimer()
			let host = try await rawText(store, undoWindow: undoWindow)
			defer { host.window.close() }
			try await host.click("Edit")
			let editor = try await editorView(in: host)
			#expect(editor.string == "API_TOKEN=\"tok en\"\nDATABASE_URL=postgres://app:pw@db:5432/demo\nLOG_LEVEL=info\n")
			for text in ["Editing · real values shown", "No changes yet", "Comments, blank lines and line order aren't kept.", "4 lines"] {
				#expect(try await host.waitForText(text), "The editor says \(text)")
			}
			#expect(try await host.waitUntil { element("Save", in: host)?.isEnabled == false })
			try type("debug", over: "info", in: editor)
			try type("NEW_KEY=added\n", at: (editor.string as NSString).length, in: editor)
			#expect(try await host.waitForText("1 added · 1 changed"))
			#expect(try await host.waitUntil { element("Save", in: host)?.isEnabled == true })
			try record(host, named: "raw-text-editing")
			try await host.click("Save")
			#expect(try await host.waitUntil {
				keychain.envStorage["raw"]?.environments["default"] == Self.values.merging(["LOG_LEVEL": "debug", "NEW_KEY": "added"]) { $1 }
			})
			#expect(try await host.waitForText("Saved .env · 1 added, 1 changed"))
			#expect(try await host.waitForText("NEW_KEY=\(VaultRawText.mask)"), "Saving ends the edit, and shows the saved lines")
			try record(host, named: "raw-text-saved")
			try await host.click("Undo")
			#expect(try await host.waitUntil { keychain.envStorage["raw"]?.environments["default"] == Self.values })
			#expect(try await host.waitForText("Put .env back as it was"))
		}

		@Test("a line that can't be saved is marked with why, by its number, and keeps Save off until it's fixed")
		func problemLines() async throws {
			let (store, _, _) = makeStore()
			defer { store.lock() }
			let host = try await rawText(store)
			defer { host.window.close() }
			try await host.click("Edit")
			let editor = try await editorView(in: host)
			try type("bad key=1\nLOG_LEVEL=warn\n", at: (editor.string as NSString).length, in: editor)
			#expect(try await host.waitForText("2 problems · Save is available once every line is valid"))
			let footer = try await host.waitForElement(saying: "2 problems · Save is available once every line is valid")
			#expect(footer.value?.contains("Line 4: invalid key name — use letters, digits and _, not starting with a digit") == true)
			#expect(footer.value?.contains("Line 5: duplicate of line 3") == true)
			#expect(try await host.waitUntil { element("Save", in: host)?.isEnabled == false })
			try record(host, named: "raw-text-problems")
			try type("BAD_KEY", over: "bad key", in: editor)
			try type("", over: "LOG_LEVEL=warn\n", in: editor)
			#expect(try await host.waitForText("1 added"))
			#expect(try await host.waitUntil { element("Save", in: host)?.isEnabled == true })
		}

		@Test("text copied or cut in the editor goes to the clipboard as every copy of values does")
		func editorCopiesLikeEveryCopy() async throws {
			let waits = ClipboardClearWaits()
			defer { waits.elapse() }
			let (store, _, _) = makeStore(clearWaits: waits)
			defer { store.lock() }
			let host = try await rawText(store)
			defer { host.window.close() }
			try await host.click("Edit")
			let editor = try await editorView(in: host)
			let lines = editor.string as NSString
			editor.setSelectedRange(lines.range(of: "LOG_LEVEL=info"))
			NSApp.sendAction(#selector(NSText.copy(_:)), to: editor, from: nil)
			let pasteboard = store.clipboard.pasteboard
			#expect(pasteboard.string(forType: .string) == "LOG_LEVEL=info")
			#expect(pasteboard.types?.contains(ClipboardManager.concealedType) == true)
			#expect(try await host.waitUntil { waits.durations == [.seconds(10)] })
			editor.setSelectedRange((editor.string as NSString).range(of: "API_TOKEN=\"tok en\"\n"))
			NSApp.sendAction(#selector(NSText.cut(_:)), to: editor, from: nil)
			#expect(pasteboard.string(forType: .string) == "API_TOKEN=\"tok en\"\n")
			#expect(!editor.string.contains("API_TOKEN"))
			#expect(try await host.waitForText("1 removed"))
		}

		@Test("a save that finds the environment changed meanwhile writes nothing, says so, and saves once compared")
		func changedMeanwhile() async throws {
			let (store, _, keychain) = makeStore()
			defer { store.lock() }
			let host = try await rawText(store)
			defer { host.window.close() }
			try await host.click("Edit")
			let editor = try await editorView(in: host)
			try type("debug", over: "info", in: editor)
			keychain.simulateCLISet(vaultId: "raw", environment: "default", key: "API_TOKEN", value: "from-cli")
			try await host.click("Save")
			#expect(try await host.waitForText(".env changed meanwhile, as by the LPM CLI, so nothing was saved."))
			#expect(keychain.envStorage["raw"]?.environments["default"]?["LOG_LEVEL"] == "info")
			try await host.click("Compare with current values")
			#expect(try await host.waitForText("2 changed"), "The edit puts back the token the CLI changed, and says so")
			try await host.click("Save")
			#expect(try await host.waitUntil {
				keychain.envStorage["raw"]?.environments["default"] == Self.values.merging(["LOG_LEVEL": "debug"]) { $1 }
			})
		}

		@Test("an edit stays while the table is shown, and Cancel discards it")
		func editStaysUntilCancelled() async throws {
			let (store, _, keychain) = makeStore()
			defer { store.lock() }
			let host = try await rawText(store)
			defer { host.window.close() }
			try await host.click("Edit")
			let editor = try await editorView(in: host)
			try type("debug", over: "info", in: editor)
			#expect(try await host.waitForText("1 changed"))
			try await host.click("Table")
			#expect(try await host.waitForText("KEY", exactly: true))
			#expect(try await host.waitForText("Raw text edit not saved"))
			try await host.click("Raw text")
			#expect(try await editorView(in: host).string.contains("LOG_LEVEL=debug"))
			try await host.click("Cancel")
			#expect(try await host.waitForText("API_TOKEN=\(VaultRawText.mask)"))
			#expect(store.rawTextDraft(for: VaultEnvironmentTarget(projectId: "raw", environment: "default")) == nil)
			#expect(keychain.envStorage["raw"]?.environments["default"] == Self.values)
		}

		@Test("Edit waits while keys have unsaved edits, and says so")
		func editWaitsForKeyEdits() async throws {
			let (store, _, _) = makeStore()
			defer { store.lock() }
			let host = try await rawText(store)
			defer { host.window.close() }
			let project = try #require(store.selectedProject)
			store.keyDrafts.edit(project, key: "LOG_LEVEL") { $0.setValue("debug", in: "default") }
			#expect(try await host.waitUntil { element("Edit .env as text", in: host)?.isEnabled == false })
			#expect(element("Edit .env as text", in: host)?.help == "Save or discard the unsaved edits of 1 key first")
		}

		@Test("Fix in table, on a failed group's banner, shows the table")
		func fixInTable() async throws {
			let project = VaultProject(id: "p", name: "p", path: "", environments: ["default": ["SAVED": "x"]])
			let check = ProjectEnvValueCheck(environments: [
				"default": .init(problems: ["SAVED": [.init(key: "SAVED", kind: .group(name: "credentials", mode: "exactlyOne"))]])
			])
			let host = SheetTestHost(FixInTableView(project: project, check: check), size: NSSize(width: 950, height: 550),
				keepsRequestedSize: true)
			defer { host.window.close() }
			#expect(try await host.waitForText("Group credentials fails"))
			try await host.click("Fix in table")
			#expect(try await host.waitForText("KEY", exactly: true))
			#expect(try await host.waitForTextToDisappear("Fix in table"))
		}

		/// `clearWaits` holds each copy until it's told the time is up.
		private func makeStore(keychain: MockKeychainService = MockKeychainService(), clearWaits: ClipboardClearWaits? = nil)
			-> (VaultStore, MockBiometricService, MockKeychainService)
		{
			let biometric = MockBiometricService()
			let project = VaultProject(id: "raw", name: "Raw", path: "", environments: ["default": Self.values])
			keychain.envStorage[project.id] = (name: project.name, path: "", environments: project.environments)
			let clipboard = clearWaits.map { ClipboardManager(pasteboard: .withUniqueName(), sleep: $0.sleep) }
				?? ClipboardManager(pasteboard: .withUniqueName())
			let store = VaultStore(keychainService: keychain, biometricService: biometric, apiService: MockAPIService(),
				authTokenProvider: { _, _ in nil }, clipboard: clipboard)
			store.isUnlocked = true
			store.projects = [project]
			store.openProject(id: project.id)
			return (store, biometric, keychain)
		}

		/// The workspace showing the project's .env as Raw text. Copy
		/// confirmations, and a save's chance to undo, stay until the test ends them.
		private func rawText(_ store: VaultStore, undoWindow: ManualFeedbackTimer = ManualFeedbackTimer()) async throws
			-> SheetTestHost<some View>
		{
			await store.refreshCliAccess()
			let defaults = try #require(UserDefaults(suiteName: "raw-text-interaction"))
			let host = SheetTestHost(VaultWorkspaceView(store: store).environment(UpdateChecker())
				.environment(VaultAppearanceSettings(defaults: defaults)).environment(VaultQuitSettings(defaults: defaults))
				.environment(\.vaultCopyFeedbackTimer, ManualFeedbackTimer().timer)
				.environment(\.vaultImportUndoTimer, undoWindow.timer)
				.defaultAppStorage(defaults),
				size: NSSize(width: 1300, height: 700), keepsRequestedSize: true, usesHostingView: true)
			#expect(try await host.waitUntil { store.workspaceSnapshots["raw"] != nil })
			try await host.clickSidebarEnvironment(".env")
			try await host.click("Raw text")
			#expect(try await host.waitForText("API_TOKEN="))
			try await host.settle()
			return host
		}

		private func editorView<V: View>(in host: SheetTestHost<V>) async throws -> VaultRawTextEditor.EditorTextView {
			func find(_ view: NSView) -> VaultRawTextEditor.EditorTextView? {
				if let editor = view as? VaultRawTextEditor.EditorTextView { return editor }
				return view.subviews.lazy.compactMap(find).first
			}
			var editor: VaultRawTextEditor.EditorTextView?
			#expect(try await host.waitUntil {
				editor = find(host.view)
				return editor != nil
			}, "Raw text shows its editor")
			return try #require(editor)
		}

		/// Types `text` over the first `old` in the editor, as a person selecting it and typing would.
		private func type(_ text: String, over old: String, in editor: NSTextView) throws {
			let range = (editor.string as NSString).range(of: old)
			try #require(range.location != NSNotFound, "The editor holds \(old)")
			editor.setSelectedRange(range)
			editor.insertText(text, replacementRange: range)
		}

		private func type(_ text: String, at location: Int, in editor: NSTextView) throws {
			editor.setSelectedRange(NSRange(location: location, length: 0))
			editor.insertText(text, replacementRange: NSRange(location: location, length: 0))
		}

		private func element<V: View>(_ label: String, in host: SheetTestHost<V>) -> AccessibilityTree.Element? {
			AccessibilityTree.visibleElements(in: host.window, of: host.view).first { $0.isInteractive && $0.says(label, as: .leading) }
		}

		private func codeView<V: View>(in host: SheetTestHost<V>) throws -> VaultRawTextView.CodeTextView {
			func find(_ view: NSView) -> VaultRawTextView.CodeTextView? {
				if let textView = view as? VaultRawTextView.CodeTextView { return textView }
				return view.subviews.lazy.compactMap(find).first
			}
			return try #require(find(host.view), "Raw text shows a code view")
		}

		private func record<V: View>(_ host: SheetTestHost<V>, named name: String) throws {
			let view = host.view
			let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
			view.cacheDisplay(in: view.bounds, to: bitmap)
			Attachment.record(try #require(bitmap.representation(using: .png, properties: [:])), named: name + ".png")
		}
	}
}

/// A content view showing Raw text, whose Fix in table can switch it to the table.
private struct FixInTableView: View {
	let project: VaultProject
	let check: ProjectEnvValueCheck
	@State private var viewMode = VaultEnvironmentViewMode.raw

	var body: some View {
		VaultContentView(
			project: project, snapshot: VaultWorkspaceSnapshot(project: project),
			environments: ["default"], selectedEnvironment: "default",
			mode: .constant(.environment("default")), filter: .constant(.all),
			environmentViewMode: $viewMode, sortOrder: .constant(.ascending),
			searchText: "", selectedKey: .constant(nil), revealedKeys: .constant([]),
			showsInspector: .constant(false), columnWidths: .constant(VaultProjectTableColumnWidths()),
			isCopyingAll: false, cliAccess: nil,
			isChangingCliAccess: false, onChangeCliAccess: { _ in }, onCopyAll: {},
			onImport: {}, onExport: {},
			valueChecks: VaultValueCheckPresentation(check: check, rules: nil, project: project),
			onAddSecret: {}, onCopySecret: { _, _ in },
			onDeleteSecret: { _, _ in }, onResizeColumns: {}
		)
	}
}
