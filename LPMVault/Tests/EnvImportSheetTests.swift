import AppKit
import SwiftUI
import Testing

@testable import LPMVault

extension SheetInteractionTests {
	@Suite("Import sheet", .serialized) @MainActor struct EnvImportSheetTests {

		@Test("Import opens a sheet to drop, choose or paste variables, going into the environment shown")
		func opensSheet() async throws {
			let fixture = try ImportWorkspace()
			defer { fixture.tearDown() }
			let host = try await fixture.workspace()
			defer { host.window.close() }
			let sheet = try await fixture.openImport(in: host)
			for text in ["billing-app", "From file", "Paste text", "Drop an .env file here", "Choose File…", "Import into",
				"one file per import", "See new, changed and unchanged keys first", "Parsed locally. Comments and blank lines are ignored."]
			{
				#expect(try await host.waitForText(text, in: sheet), "The sheet says \(text)")
			}
			#expect(element(".env", in: sheet)?.isSelected == true, "The environment shown is chosen")
			#expect(element(".env.production", in: sheet)?.isSelected == false)
			#expect(element("New file", in: sheet)?.isSelected == false)
			#expect(element("Review before applying", in: sheet)?.isOn == true)
			#expect(element("Review", in: sheet)?.isEnabled == false, "There's nothing to review yet")
		}

		@Test("pasted text is read as it's pasted, then reviewed and imported, keeping existing values")
		func pasteReviewImport() async throws {
			let fixture = try ImportWorkspace()
			defer { fixture.tearDown() }
			let host = try await fixture.workspace()
			defer { host.window.close() }
			let sheet = try await fixture.openImport(in: host)
			try await host.click("Paste text", in: sheet)
			try paste("TOKEN=new\nexport NEW_KEY=\"hello world\"\n# a comment\n\n", into: sheet)
			#expect(try await host.waitForText("2 variables", in: sheet))
			try await clickEnabled("Review 2 variables, ⏎", in: sheet, of: host)
			#expect(try await host.waitForText("Review import", in: sheet))
			let review = try await host.text(in: sheet)
			#expect(review.contains("Pasted text") && review.contains("NEW_KEY") && review.contains("Different value"))
			try pressReturn(in: sheet)
			#expect(try await host.waitForText("Import complete", in: sheet))
			#expect(fixture.stored("default") == ["TOKEN": "a", "NEW_KEY": "hello world"], "The review keeps existing values unless Replace is chosen")
		}

		@Test("Return in the paste box starts a new line instead of pressing Review")
		func returnInPasteBox() async throws {
			let fixture = try ImportWorkspace()
			defer { fixture.tearDown() }
			let host = try await fixture.workspace()
			defer { host.window.close() }
			let sheet = try await fixture.openImport(in: host)
			try await host.click("Paste text", in: sheet)
			try paste("A=1", into: sheet)
			#expect(try await host.waitForText("1 variable", in: sheet))
			let editor = try pasteEditor(in: sheet)
			#expect(sheet.firstResponder === editor)
			let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
				windowNumber: sheet.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
			NSApplication.shared.sendEvent(event)
			try await host.settle()
			#expect(editor.string == "A=1\n")
			#expect(try await !host.text(in: sheet).contains("Review import"))
		}

		@Test("the paste box changes nothing it's given: no substitutions, no rich text, and its own undo history")
		func pasteBoxKeepsText() async throws {
			let fixture = try ImportWorkspace()
			defer { fixture.tearDown() }
			let host = try await fixture.workspace()
			defer { host.window.close() }
			let sheet = try await fixture.openImport(in: host)
			try await host.click("Paste text", in: sheet)
			let editor = try pasteEditor(in: sheet)
			#expect(!editor.isAutomaticQuoteSubstitutionEnabled && !editor.isAutomaticDashSubstitutionEnabled)
			#expect(!editor.isAutomaticTextReplacementEnabled && !editor.isAutomaticSpellingCorrectionEnabled)
			#expect(!editor.isContinuousSpellCheckingEnabled && !editor.isGrammarCheckingEnabled && !editor.isAutomaticLinkDetectionEnabled)
			#expect(!editor.isAutomaticTextCompletionEnabled && editor.inlinePredictionType == .no && !editor.isRichText)
			if #available(macOS 15.0, *) { #expect(editor.writingToolsBehavior == .none) }
			#expect(editor.acceptableDragTypes == [.string] && editor.readablePasteboardTypes == [.string],
				"A file dropped on the box is imported as a file, not typed in as its path")
			let value = "TOKEN=\"it's -- \"quoted\"\" (c)"
			try paste(value, into: sheet)
			#expect(editor.string == value)
			#expect(editor.undoManager != nil && editor.undoManager !== sheet.undoManager, "What's pasted stays out of the window's undo history")
			#expect(sheet.contentView.map { AccessibilityTree.visibleElements(in: sheet, of: $0) }?.contains {
				$0.role == .textArea && $0.label == "Variables to import"
			} == true, "The box says what it's for")
		}

		@Test("with Review before applying off, the import adds new keys, keeps existing values, and says which it kept")
		func importWithoutReview() async throws {
			let fixture = try ImportWorkspace()
			defer { fixture.tearDown() }
			let host = try await fixture.workspace()
			defer { host.window.close() }
			let sheet = try await fixture.openImport(in: host)
			try await host.click("Paste text", in: sheet)
			try paste("TOKEN=new\nNEW_KEY=1", into: sheet)
			#expect(try await host.waitForText("2 variables", in: sheet))
			try await host.click("Review before applying", in: sheet)
			#expect(try await host.waitForText("Adds new keys and keeps every existing value", in: sheet))
			try await clickEnabled("Import 2 variables, ⏎", in: sheet, of: host)
			#expect(try await host.waitForText("Import complete", in: sheet))
			#expect(try await host.waitForText("1 existing value differs and was kept. To replace it, import again with Review before applying on.", in: sheet))
			#expect(try await host.waitForText("1 added · 0 replaced · 1 kept · 0 unchanged", in: sheet))
			#expect(fixture.stored("default") == ["TOKEN": "a", "NEW_KEY": "1"])
			try await host.click("Done", in: sheet)
			#expect(try await host.waitUntil { host.window.attachedSheet == nil })
		}

		@Test("importing into another environment shows it in the window, and the review names it")
		func anotherEnvironment() async throws {
			let fixture = try ImportWorkspace()
			defer { fixture.tearDown() }
			let host = try await fixture.workspace()
			defer { host.window.close() }
			let sheet = try await fixture.openImport(in: host)
			try await host.click("Paste text", in: sheet)
			try paste("NEW_KEY=1", into: sheet)
			try await host.click(".env.production", in: sheet)
			#expect(try await host.waitUntil { element(".env.production", in: sheet)?.isSelected == true })
			#expect(element(".env", in: sheet)?.isSelected == false)
			try await clickEnabled("Review 1 variable, ⏎", in: sheet, of: host)
			#expect(try await host.waitForText("Review import", in: sheet))
			#expect(fixture.store.selectedEnvironment == "production")
			#expect(try await host.text(in: sheet).contains(".env.production"))
			try pressReturn(in: sheet)
			#expect(try await host.waitForText("Import complete", in: sheet))
			#expect(fixture.stored("production") == ["TOKEN": "b", "NEW_KEY": "1"])
			#expect(fixture.stored("default") == ["TOKEN": "a"])
		}

		@Test("New file creates an environment holding the variables, once it has a name no environment has")
		func newFile() async throws {
			let fixture = try ImportWorkspace()
			defer { fixture.tearDown() }
			let host = try await fixture.workspace()
			defer { host.window.close() }
			let sheet = try await fixture.openImport(in: host)
			try await host.click("Paste text", in: sheet)
			try paste("A=1\nB=2", into: sheet)
			try await host.click("New file", in: sheet)
			#expect(try await host.waitForText("A new file has nothing to compare, so it's created as it is", in: sheet))
			#expect(element("Review before applying", in: sheet)?.isEnabled == false)
			#expect(element("Create file, ⏎", in: sheet)?.isEnabled == false, "A new file needs a name")
			try host.typeText("production", placeholder: "staging", in: sheet)
			#expect(try await host.waitForText("That environment already exists.", in: sheet))
			try host.typeText("preview", placeholder: "staging", in: sheet)
			try await clickEnabled("Create .env.preview, ⏎", in: sheet, of: host)
			#expect(try await host.waitUntil { host.window.attachedSheet == nil })
			#expect(fixture.stored("preview") == ["A": "1", "B": "2"])
			#expect(fixture.store.selectedEnvironment == "preview")
		}

		@Test("a problem in pasted text names its line, and nothing imports until it's fixed")
		func pastedProblem() async throws {
			let fixture = try ImportWorkspace()
			defer { fixture.tearDown() }
			let host = try await fixture.workspace()
			defer { host.window.close() }
			let sheet = try await fixture.openImport(in: host)
			try await host.click("Paste text", in: sheet)
			try paste("GOOD=1\n1BAD=2", into: sheet)
			#expect(try await host.waitForText("Line 2 has a variable name that does not match [A-Za-z_][A-Za-z0-9_]*.", in: sheet))
			#expect(element("Review", in: sheet)?.isEnabled == false)
			let editor = try pasteEditor(in: sheet)
			editor.selectAll(nil)
			try paste("GOOD=1\nnot an assignment\n", into: sheet)
			#expect(try await host.waitForText("Line 2 isn't KEY=value, so it's left out.", in: sheet))
			#expect(try await host.waitForText("1 variable", in: sheet))
			#expect(element("Review 1 variable", in: sheet)?.isEnabled == true)
			try await host.click("Clear", in: sheet)
			#expect(try await host.waitForText("Paste KEY=value lines, as an .env file holds them", in: sheet))
			#expect(element("Review", in: sheet)?.isEnabled == false)
		}

		@Test("a dropped file opens the sheet reading it, says its size and folder, names a new file after it, and reviews like any other")
		func droppedFile() async throws {
			let fixture = try ImportWorkspace()
			defer { fixture.tearDown() }
			let file = try fixture.file(".env.local", "TOKEN=a\nNEW_KEY=1\n")
			let host = SheetTestHost(
				EnvImportSheet(store: fixture.store, projectID: ImportWorkspace.projectID, environment: "default", file: file)
					.environment(\.colorScheme, .light),
				size: NSSize(width: 640, height: 640), keepsRequestedSize: true, usesHostingView: true)
			defer { host.window.close() }
			#expect(try await host.waitForText(".env.local"))
			#expect(try await host.waitForText("2 variables · 18 bytes · "))
			#expect(try await host.waitForText("Change"))
			try await host.click("New file")
			#expect(try await host.waitUntil { host.fieldText(placeholder: "staging") == "local" })
			try await host.click(".env")
			try await clickEnabled("Review 2 variables, ⏎", in: host.window, of: host)
			#expect(try await host.waitForText("Review import"))
			let review = try await host.text()
			#expect(review.contains(".env.local") && review.contains("NEW_KEY") && review.contains("Unchanged"))
		}

		@Test("Env Project › Import Variables… opens the sheet, unless another sheet is showing")
		func menuCommand() async throws {
			let fixture = try ImportWorkspace()
			defer { fixture.tearDown() }
			let host = try await fixture.workspace()
			defer { host.window.close() }
			NotificationCenter.default.post(name: .newSecret, object: nil)
			#expect(try await host.waitUntil { host.window.attachedSheet != nil })
			let addVariable = try #require(host.window.attachedSheet)
			#expect(try await host.waitForText("Add variable", in: addVariable))
			NotificationCenter.default.post(name: .importVariables, object: nil)
			try await host.settle()
			#expect(try await !host.text(in: addVariable).contains("Import variables"))
			try await host.click("Cancel", in: addVariable)
			#expect(try await host.waitUntil { host.window.attachedSheet == nil })
			try await host.settle()
			#expect(host.window.attachedSheet == nil, "The command that came while a sheet showed doesn't open one later")

			NotificationCenter.default.post(name: .importVariables, object: nil)
			let sheet = try await fixture.sheet(of: host)
			#expect(element(".env", in: sheet)?.isSelected == true)
		}

		@Test("the sheet stays open under the curtain while the app is inactive, keeping what was pasted, and closes as the vault locks")
		func privacyAndLock() async throws {
			let fixture = try ImportWorkspace()
			defer { fixture.tearDown() }
			let host = try await fixture.workspace()
			defer { host.window.close() }
			let sheet = try await fixture.openImport(in: host)
			try await host.click("Paste text", in: sheet)
			try paste("SECRET_VALUE=hidden-while-inactive", into: sheet)
			#expect(try await host.waitForText("1 variable", in: sheet))
			fixture.presentation.isObscured = true
			try await host.settle()
			#expect(host.window.attachedSheet === sheet)
			#expect(try await !host.text(in: sheet).contains("1 variable"), "The curtain hides the sheet")
			fixture.presentation.isObscured = false
			#expect(try await host.waitForText("1 variable", in: sheet))
			#expect(try pasteEditor(in: sheet).string == "SECRET_VALUE=hidden-while-inactive")
			fixture.store.lock()
			#expect(try await host.waitUntil { host.window.attachedSheet == nil })
		}

		@Test("a new environment can start with pasted values")
		func newEnvironmentPaste() async throws {
			let fixture = try ImportWorkspace()
			defer { fixture.tearDown() }
			let project = try #require(fixture.store.selectedProject)
			let host = SheetTestHost(NewEnvironmentSheet(store: fixture.store, project: project).environment(\.colorScheme, .light),
				size: NSSize(width: 520, height: 520), keepsRequestedSize: true, usesHostingView: true)
			defer { host.window.close() }
			try host.typeText("staging", placeholder: "staging")
			try await host.click("Paste text")
			try paste("A=1\n1BAD=2", into: host.window)
			#expect(try await host.waitForText("Line 2 has a variable name"))
			#expect(element("Create environment", in: host.window)?.isEnabled == false, "Values that can't be read aren't left out quietly")
			try pasteEditor(in: host.window).selectAll(nil)
			try paste("A=1\nB=2", into: host.window)
			#expect(try await host.waitForText("2 variables"))
			try await clickEnabled("Create environment", in: host.window, of: host)
			#expect(try await host.waitUntil { fixture.stored("staging") != nil })
			#expect(fixture.stored("staging") == ["A": "1", "B": "2"])
		}
	}
}

/// A workspace showing a project with two environments, whose import reads
/// real files and text.
@MainActor
private struct ImportWorkspace {
	static let projectID = "import-sheet"

	let store: VaultStore
	let keychain: MockKeychainService
	let presentation = ImportPresentation()
	let folder: URL

	init(environments: [String: [String: String]] = ["default": ["TOKEN": "a"], "production": ["TOKEN": "b"]]) throws {
		folder = FileManager.default.temporaryDirectory.appending(path: "import-sheet-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		keychain = MockKeychainService()
		let project = VaultProject(id: Self.projectID, name: "billing-app", path: folder.path, environments: environments)
		keychain.envStorage[project.id] = (name: project.name, path: project.path, environments: project.environments)
		store = VaultStore(keychainService: keychain, biometricService: MockBiometricService(),
			apiService: MockAPIService(), authTokenProvider: { _, _ in nil }, clipboard: ClipboardManager(pasteboard: .withUniqueName()))
		store.isUnlocked = true
		store.projects = [project]
		store.openProject(id: project.id)
	}

	func workspace() async throws -> SheetTestHost<ImportWorkspaceRoot> {
		await store.refreshCliAccess()
		let defaults = try #require(UserDefaults(suiteName: "import-sheet"))
		let host = SheetTestHost(ImportWorkspaceRoot(store: store, presentation: presentation, defaults: defaults),
			size: NSSize(width: 1200, height: 700), keepsRequestedSize: true, usesHostingView: true)
		#expect(try await host.waitUntil { store.workspaceSnapshots[Self.projectID] != nil })
		#expect(try await host.waitForText("TOKEN"))
		try await host.settle()
		return host
	}

	/// Clicks Import in the header and returns the sheet it opens.
	func openImport(in host: SheetTestHost<ImportWorkspaceRoot>) async throws -> NSWindow {
		try await host.click("Import variables into .env")
		return try await sheet(of: host)
	}

	func sheet(of host: SheetTestHost<ImportWorkspaceRoot>) async throws -> NSWindow {
		#expect(try await host.waitUntil { host.window.attachedSheet != nil })
		let sheet = try #require(host.window.attachedSheet)
		#expect(try await host.waitForText("Import variables", in: sheet))
		return sheet
	}

	func file(_ name: String, _ contents: String) throws -> URL {
		let url = folder.appending(path: name)
		try Data(contents.utf8).write(to: url)
		return url
	}

	func stored(_ environment: String) -> [String: String]? {
		keychain.envStorage[Self.projectID]?.environments[environment]
	}

	func tearDown() {
		store.lock()
		try? FileManager.default.removeItem(at: folder)
	}
}

@Observable @MainActor
private final class ImportPresentation {
	var isObscured = false
}

private struct ImportWorkspaceRoot: View {
	let store: VaultStore
	var presentation: ImportPresentation
	let defaults: UserDefaults
	@State private var updateChecker = UpdateChecker()
	@State private var appearance: VaultAppearanceSettings

	init(store: VaultStore, presentation: ImportPresentation, defaults: UserDefaults) {
		self.store = store
		self.presentation = presentation
		self.defaults = defaults
		_appearance = State(initialValue: VaultAppearanceSettings(defaults: defaults))
	}

	var body: some View {
		VaultWorkspaceView(store: store)
			.environment(updateChecker)
			.environment(appearance)
			.defaultAppStorage(defaults)
			.environment(\.vaultContentObscured, presentation.isObscured)
	}
}

/// The first control saying exactly `label`, or `label` and the ⏎ it's
/// pressed with, as VoiceOver finds it.
@MainActor
private func element(_ label: String, in window: NSWindow) -> AccessibilityTree.Element? {
	guard let content = window.contentView else { return nil }
	content.layoutSubtreeIfNeeded()
	return AccessibilityTree.visibleElements(in: window, of: content).first {
		$0.isInteractive && ($0.says(label) || $0.says(label + ", ⏎"))
	}
}

/// Clicks the control saying `label` once it's enabled: a button can say
/// what it does a render before it enables.
@MainActor
private func clickEnabled<V: View>(_ label: String, in window: NSWindow, of host: SheetTestHost<V>) async throws {
	#expect(try await host.waitUntil { element(label, in: window)?.isEnabled == true }, "\(label) enables")
	try await host.click(label, in: window)
}

/// Presses Return in `window`, as a person does with nothing being edited.
@MainActor
private func pressReturn(in window: NSWindow) throws {
	window.makeFirstResponder(nil)
	let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
		windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
	#expect(window.performKeyEquivalent(with: event))
}

@MainActor
private func pasteEditor(in window: NSWindow) throws -> EnvImportPasteEditor.PasteTextView {
	func find(in view: NSView) -> EnvImportPasteEditor.PasteTextView? {
		if let editor = view as? EnvImportPasteEditor.PasteTextView { return editor }
		for subview in view.subviews { if let found = find(in: subview) { return found } }
		return nil
	}
	return try #require(window.contentView.flatMap(find), "The sheet shows the paste box")
}

/// Pastes `text` into the paste box as ⌘V does, from a pasteboard of the test's own.
@MainActor
private func paste(_ text: String, into window: NSWindow) throws {
	let editor = try pasteEditor(in: window)
	let pasteboard = NSPasteboard.withUniqueName()
	defer { pasteboard.releaseGlobally() }
	pasteboard.clearContents()
	pasteboard.setString(text, forType: .string)
	window.makeFirstResponder(editor)
	#expect(editor.readSelection(from: pasteboard, type: .string))
}
