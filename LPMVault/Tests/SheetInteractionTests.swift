import AppKit
import SwiftUI
import Testing
import Vision

@testable import LPMVault

@MainActor
final class SheetTestHost<V: View> {
	let view: NSView
	let window: NSWindow

	init(_ root: V, size: NSSize) {
		let controller = NSHostingController(rootView: root)
		view = controller.view
		window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
		window.isReleasedWhenClosed = false
		window.contentViewController = controller
		view.frame = NSRect(origin: .zero, size: size)
		window.orderBack(nil)
		view.layoutSubtreeIfNeeded()
	}

	func settle() async throws {
		for _ in 0..<8 {
			view.layoutSubtreeIfNeeded()
			try await Task.sleep(for: .milliseconds(10))
		}
	}

	func text(in targetWindow: NSWindow? = nil) throws -> OCRText { OCRText(try observations(in: targetWindow?.contentView).map { $0.topCandidates(1).first?.string ?? "" }.joined(separator: "\n")) }

	func waitForText(_ expected: String, in targetWindow: NSWindow? = nil) async throws -> OCRText {
		let deadline = Date().addingTimeInterval(3)
		var rendered = try text(in: targetWindow)
		while !rendered.contains(expected), Date() < deadline {
			try await settle()
			rendered = try text(in: targetWindow)
		}
		return rendered
	}

	func click(_ label: String, in targetWindow: NSWindow? = nil) throws {
		let window = targetWindow ?? self.window
		let view = try #require(window.contentView)
		let observations = try observations(in: view)
		let observation = try #require(observations.first { $0.topCandidates(1).first?.string.contains(label) == true }, "Missing button \(label)")
		let candidate = try #require(observation.topCandidates(1).first)
		let range = try #require(candidate.string.range(of: label))
		let bounds = try #require(try candidate.boundingBox(for: range)?.boundingBox)
		let point = view.convert(NSPoint(x: bounds.midX * view.bounds.width, y: (view.isFlipped ? 1 - bounds.midY : bounds.midY) * view.bounds.height), to: nil)
		for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
			let event = try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
			window.sendEvent(event)
		}
	}

	func enterKey(_ key: String) throws {
		try enter(key, secure: false)
	}

	func enterValue(_ value: String) throws {
		try enter(value, secure: true)
	}

	private func enter(_ text: String, secure: Bool) throws {
		let field = try #require(textFields(in: view).first { ($0 is NSSecureTextField) == secure })
		window.makeFirstResponder(field)
		let editor = try #require(field.currentEditor() as? NSTextView)
		editor.insertText(text, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
		field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
		window.makeFirstResponder(nil)
	}

	func returnWhileEditing(_ target: String, modifiers: NSEvent.ModifierFlags = .shift) throws {
		let fields = textFields(in: view)
		let field = try #require(target == "key" ? fields.first { !($0 is NSSecureTextField) } : fields.last)
		window.makeFirstResponder(field)
		let editor = try #require(field.currentEditor())
		try #require(window.firstResponder === editor)
		let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
		window.sendEvent(event)
	}

	func key(_ character: String, code: UInt16, modifiers: NSEvent.ModifierFlags = [], in targetWindow: NSWindow) throws {
		let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: targetWindow.windowNumber, context: nil, characters: character, charactersIgnoringModifiers: character, isARepeat: false, keyCode: code))
		targetWindow.sendEvent(event)
	}

	func escape() throws -> Bool {
		let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
		return window.performKeyEquivalent(with: event)
	}

	var value: String { textFields(in: view).first { $0 is NSSecureTextField }?.stringValue ?? "" }

	var isKeyFieldEnabled: Bool { textFields(in: view).first { !($0 is NSSecureTextField) }?.isEnabled ?? false }

	func bounds(of label: String) throws -> CGRect {
		let observation = try #require(try observations().first { OCRText($0.topCandidates(1).first?.string ?? "").contains(label) })
		return observation.boundingBox
	}

	func line(containing label: String) throws -> String {
		try #require(try observations().compactMap { $0.topCandidates(1).first?.string }.first { $0.contains(label) })
	}

	func generatorWindow() async throws -> NSWindow {
		let deadline = Date().addingTimeInterval(3)
		repeat {
			if let panel = try visibleGeneratorWindow() { return panel }
			try await settle()
		} while Date() < deadline
		throw CocoaError(.coderValueNotFound)
	}

	func visibleGeneratorWindow() throws -> NSWindow? {
		for candidate in NSApp.windows where candidate !== window && candidate.isVisible {
			guard let content = candidate.contentView, !content.bounds.isEmpty else { continue }
			let text = OCRText(try observations(in: content).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " "))
			if text.contains("GENERATE VALUE") { return candidate }
		}
		return nil
	}

	private func textFields(in view: NSView) -> [NSTextField] {
		if let field = view as? NSTextField { return [field] }
		return view.subviews.flatMap { textFields(in: $0) }
	}

	private func observations(in target: NSView? = nil) throws -> [VNRecognizedTextObservation] {
		let view = target ?? self.view
		view.layoutSubtreeIfNeeded()
		let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
		view.cacheDisplay(in: view.bounds, to: bitmap)
		let image = try #require(bitmap.cgImage)
		let request = VNRecognizeTextRequest()
		request.recognitionLevel = .accurate
		request.usesLanguageCorrection = false
		try VNImageRequestHandler(cgImage: image).perform([request])
		return request.results ?? []
	}
}

@Suite("Sheet interaction regressions", .serialized)
@MainActor
struct SheetInteractionTests {
	private func makeStore(path: String = "", environments: [String: [String: String]] = ["default": [:]]) -> (VaultStore, MockKeychainService) {
		let keychain = MockKeychainService()
		keychain.envStorage["sheet-regression"] = (name: "Sheet regression", path: path, environments: environments)
		let store = VaultStore(keychainService: keychain, biometricService: MockBiometricService(), apiService: MockAPIService())
		store.selectedProjectId = "sheet-regression"
		store.projects = [VaultProject(id: "sheet-regression", name: "Sheet regression", path: path, environments: environments)]
		store.isUnlocked = true
		return (store, keychain)
	}

	@Test("lock-screen encryption note stays centered above the bottom", arguments: [NSSize(width: 1040, height: 640), NSSize(width: 1400, height: 900)], [ColorScheme.light, .dark])
	func lockScreenFooter(size: NSSize, scheme: ColorScheme) async throws {
		let (store, _) = makeStore()
		store.lock()
		let host = SheetTestHost(ContentView(store: store).environment(\.colorScheme, scheme), size: size)
		defer { host.window.close() }
		try await host.settle()
		let bounds = try host.bounds(of: "Values stay encrypted")
		#expect(abs(bounds.midX - 0.5) * host.view.bounds.width < 3)
		#expect((15...28).contains(bounds.minY * host.view.bounds.height))
		#expect(try host.line(containing: "Unlock").range(of: #"Unlock\s+\S*L"#, options: .regularExpression) != nil)
	}

	@Test("inspector generation changes only the draft until saved", arguments: [ColorScheme.light, .dark])
	func inspectorGeneratorDraft(scheme: ColorScheme) async throws {
		let (store, keychain) = makeStore(environments: ["default": ["TOKEN": "old"], "production": ["TOKEN": "production-old"]])
		store.selectedEnvironment = "default"
		let host = SheetTestHost(InspectorInteractionFixture(store: store).environment(\.colorScheme, scheme), size: NSSize(width: 300, height: 640))
		defer { host.window.close() }
		try await host.settle()
		try host.click("Generate")
		let panel = try await host.generatorWindow()
		try host.click("Password", in: panel)
		try await host.settle()
		let generated = host.value
		#expect(generated.count == SecretValueGenerator.defaultLength)
		#expect(generated != "old")
		#expect(keychain.envStorage["sheet-regression"]?.environments["default"]?["TOKEN"] == "old")
		try host.click("Revert")
		try await host.settle()
		#expect(host.value == "old")
		try host.click("Generate")
		let secondPanel = try await host.generatorWindow()
		try host.click("UUID v4", in: secondPanel)
		try await host.settle()
		let second = host.value
		#expect(UUID(uuidString: second) != nil)
		try host.click("Save")
		try await host.settle()
		#expect(keychain.envStorage["sheet-regression"]?.environments["default"]?["TOKEN"] == second)
		#expect(keychain.envStorage["sheet-regression"]?.environments["production"]?["TOKEN"] == "production-old")
	}

	@Test("inspector generation cannot replace a pending save or conflicting draft", arguments: ["save", "conflict"])
	func inspectorGeneratorUnavailable(reason: String) async throws {
		let (store, keychain) = makeStore(environments: ["default": ["TOKEN": "old"]])
		let host = SheetTestHost(InspectorInteractionFixture(store: store), size: NSSize(width: 300, height: 640))
		defer { host.window.close() }
		try await host.settle()
		try host.click("Generate")
		let panel = try await host.generatorWindow()
		try host.click("Hexadecimal", in: panel)
		try await host.settle()
		let generated = host.value
		let release = DispatchSemaphore(value: 0)
		defer { release.signal() }
		if reason == "save" {
			let entered = DispatchSemaphore(value: 0)
			keychain.beforeKeychainTransaction = { entered.signal(); release.wait() }
			try host.click("Save")
			let didEnter = await withCheckedContinuation { continuation in
				DispatchQueue.global().async { continuation.resume(returning: entered.wait(timeout: .now() + 3) == .success) }
			}
			try #require(didEnter)
		} else {
			store.projects[0].environments["default"]?["TOKEN"] = "external"
		}
		try await host.settle()
		#expect(try host.visibleGeneratorWindow() == nil)
		try host.click("Generate")
		try await host.settle()
		#expect(try host.visibleGeneratorWindow() == nil)
		#expect(host.value == generated)
		if reason == "conflict" {
			try host.click("Revert")
			try await host.settle()
			#expect(host.value == "external")
			try host.click("Generate")
			_ = try await host.generatorWindow()
		}
	}

	@Test("cancel is unavailable while an add transaction is committing")
	func cancelUnavailableDuringCommit() async throws {
		let (store, keychain) = makeStore()
		let host = SheetTestHost(AddVariableSheet(store: store, projectId: "sheet-regression", environment: "default", initialKey: "COMMITTING"), size: NSSize(width: 560, height: 520))
		defer { host.window.close() }
		try await host.settle()
		let entered = DispatchSemaphore(value: 0)
		let release = DispatchSemaphore(value: 0)
		keychain.beforeKeychainTransaction = { entered.signal(); release.wait() }
		defer { release.signal() }
		try host.click("Add to")
		let didEnter = await withCheckedContinuation { continuation in
			DispatchQueue.global().async { continuation.resume(returning: entered.wait(timeout: .now() + 3) == .success) }
		}
		try #require(didEnter)
		try await host.settle()
		try host.click("Cancel")
		try await host.settle()
		#expect(try host.escape() == false)
		#expect(host.isKeyFieldEnabled == false)
		release.signal()
		try await host.settle()
		#expect(keychain.envStorage["sheet-regression"]?.environments["default"]?["COMMITTING"] == "")
	}

	@Test("privacy changes clear a draft even while a transaction is committing", arguments: [false, true])
	func privacyClearsCommittingDraft(changeProject: Bool) async throws {
		let (store, keychain) = makeStore()
		let host = SheetTestHost(AddVariableSheet(store: store, projectId: "sheet-regression", environment: "default", initialKey: "PRIVATE"), size: NSSize(width: 560, height: 520))
		defer { host.window.close() }
		try await host.settle()
		try host.enterValue("synthetic-value")
		try await host.settle()
		try #require(host.value == "synthetic-value")
		let entered = DispatchSemaphore(value: 0)
		let release = DispatchSemaphore(value: 0)
		keychain.beforeKeychainTransaction = { entered.signal(); release.wait() }
		defer { release.signal() }
		try host.click("Add to")
		let didEnter = await withCheckedContinuation { continuation in
			DispatchQueue.global().async { continuation.resume(returning: entered.wait(timeout: .now() + 3) == .success) }
		}
		try #require(didEnter)
		if changeProject { store.selectedProjectId = nil } else { store.lock() }
		try await host.settle()
		#expect(host.value.isEmpty)
		release.signal()
		try await host.settle()
		#expect(host.value.isEmpty)
	}

	@Test("choosing a folder preserves its existing vault link until replacement is requested")
	func chosenFolderRequiresReplacement() async throws {
		let domain = "lpm-sheet-test-" + UUID().uuidString
		let defaults = try #require(UserDefaults(suiteName: domain))
		defer { defaults.removePersistentDomain(forName: domain) }
		let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: folder) }
		let config = folder.appendingPathComponent("lpm.json")
		let original = Data(#"{"vault":"other-vault","custom":true}"#.utf8)
		try original.write(to: config)
		let (store, _) = makeStore()
		let host = SheetTestHost(ConnectCLISheet(store: store, projectId: "sheet-regression", folderPicker: { folder }, localFolderDefaults: defaults), size: NSSize(width: 600, height: 560))
		defer { host.window.close() }
		try await host.settle()
		try host.click("write file")
		try await host.settle()
		try host.click("Choose folder")
		try await host.settle()
		#expect(try Data(contentsOf: config) == original)
		#expect(try host.text().contains("Replace vault ID"))
	}

	@Test("the connect sheet names LPM CLI after checking its link status")
	func connectProductNames() async throws {
		let (store, _) = makeStore()
		let host = SheetTestHost(ConnectCLISheet(store: store, projectId: "sheet-regression"), size: NSSize(width: 600, height: 560))
		defer { host.window.close() }
		let text = try await host.waitForText("Install LPM CLI")
		#expect(text.contains("Connect to the LPM CLI"))
		#expect(text.contains("Install LPM CLI"))
	}

	@Test("a chosen local folder remains associated when the connect sheet is reopened")
	func chosenFolderSurvivesReopening() async throws {
		let domain = "lpm-sheet-test-" + UUID().uuidString
		let defaults = try #require(UserDefaults(suiteName: domain))
		defer { defaults.removePersistentDomain(forName: domain) }
		let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: folder) }
		let (store, _) = makeStore()
		let first = SheetTestHost(ConnectCLISheet(store: store, projectId: "sheet-regression", folderPicker: { folder }, localFolderDefaults: defaults), size: NSSize(width: 600, height: 560))
		try await first.settle()
		try first.click("write file")
		try await first.settle()
		try first.click("Choose folder")
		try await first.settle()
		if try first.text().contains("Write lpm.json") {
			try first.click("Write")
			try await first.settle()
		}
		first.window.close()
		let second = SheetTestHost(ConnectCLISheet(store: store, projectId: "sheet-regression", localFolderDefaults: defaults), size: NSSize(width: 600, height: 560))
		defer { second.window.close() }
		try await second.settle()
		#expect(try second.text().contains("Linked in lpm.json"))
	}

	@Test("adding and keeping open preserves the success confirmation through UI updates")
	func keepOpenConfirmation() async throws {
		let (store, keychain) = makeStore()
		let host = SheetTestHost(AddVariableSheet(store: store, projectId: "sheet-regression", environment: "default", initialKey: "TOKEN"), size: NSSize(width: 560, height: 520))
		defer { host.window.close() }
		try await host.settle()
		try host.returnWhileEditing("key")
		try await host.settle()
		#expect(keychain.envStorage["sheet-regression"]?.environments["default"]?["TOKEN"] == "")
		let confirmationText = try await host.waitForText("Added TOKEN")
		#expect(confirmationText.contains("Added TOKEN"))
		try host.enterKey("NEXT")
		try await host.settle()
		#expect(try !host.text().contains("Added TOKEN"))
	}

	@Test("Shift Return keeps the sheet open from every focused field", arguments: ["key", "secure value", "revealed value"], [false, true])
	func focusedKeepOpen(target: String, capsLock: Bool) async throws {
		let (store, keychain) = makeStore()
		let host = SheetTestHost(AddVariableSheet(store: store, projectId: "sheet-regression", environment: "default", initialKey: "FOCUSED", initialValueRevealed: target == "revealed value"), size: NSSize(width: 560, height: 520))
		defer { host.window.close() }
		try await host.settle()
		try host.returnWhileEditing(target, modifiers: capsLock ? [.shift, .capsLock] : .shift)
		let rendered = try await host.waitForText("Added FOCUSED")
		#expect(keychain.envStorage["sheet-regression"]?.environments["default"]?["FOCUSED"] != nil)
		#expect(rendered.contains("Added FOCUSED"))
	}

	@Test("ordinary Return advances from the key and submits from the value")
	func ordinaryReturnPreservesFieldActions() async throws {
		let (store, keychain) = makeStore()
		let host = SheetTestHost(AddVariableSheet(store: store, projectId: "sheet-regression", environment: "default", initialKey: "ORDINARY"), size: NSSize(width: 560, height: 520))
		defer { host.window.close() }
		try await host.settle()
		try host.returnWhileEditing("key", modifiers: [])
		try await host.settle()
		#expect(keychain.envStorage["sheet-regression"]?.environments["default"]?["ORDINARY"] == nil)
		try host.returnWhileEditing("secure value", modifiers: [])
		try await host.settle()
		#expect(keychain.envStorage["sheet-regression"]?.environments["default"]?["ORDINARY"] == "")
		#expect(try !host.text().contains("Added ORDINARY"))
	}

	@Test("Shift Return keeps a presented sheet open after focus leaves a text field", arguments: ["generator", "tab"], [false, true])
	func keepOpenAfterControlFocus(transition: String, capsLock: Bool) async throws {
		let (store, keychain) = makeStore()
		let host = SheetTestHost(AddVariablePresentedFixture(store: store), size: NSSize(width: 800, height: 650))
		defer {
			for sheet in host.window.sheets { host.window.endSheet(sheet); sheet.orderOut(nil) }
			host.window.close()
		}
		try await host.settle()
		let sheet = try #require(host.window.sheets.first)
		if transition == "generator" {
			try host.click("Generate", in: sheet)
			_ = try await host.generatorWindow()
			try host.click("Add variable", in: sheet)
		} else {
			for _ in 0..<2 { try host.key("\t", code: 48, in: sheet); try await host.settle() }
		}
		try await host.settle()
		try host.key("\r", code: 36, modifiers: capsLock ? [.shift, .capsLock] : .shift, in: sheet)
		let text = try await host.waitForText("Added CONTROL", in: sheet)
		#expect(keychain.envStorage["sheet-regression"]?.environments["default"]?["CONTROL"] == "")
		#expect(host.window.sheets.count == 1)
		#expect(text.contains("Added CONTROL"))
	}

	@Test("many environments keep the variable fields and actions inside a bounded sheet")
	func manyEnvironmentsFit() throws {
		let environments = Dictionary(uniqueKeysWithValues: (0..<90).map { (String(format: "env%03d", $0), [String: String]()) })
		let (store, _) = makeStore(environments: environments)
		let host = SheetTestHost(AddVariableSheet(store: store, projectId: "sheet-regression", environment: "env000"), size: NSSize(width: 560, height: 640))
		defer { host.window.close() }
		#expect(host.view.fittingSize.height <= 640)
		#expect(try host.text().contains("Add variable"))
		#expect(try host.text().contains("Cancel"))
	}
}

private struct InspectorInteractionFixture: View {
	@Bindable var store: VaultStore
	@State private var revealedKeys: Set<String> = []

	var body: some View {
		if let project = store.selectedProject {
			VaultInspectorView(store: store, project: project, snapshot: VaultWorkspaceSnapshot(project: project),
				environments: ["default", "production"], mode: .matrix, selectedKey: "TOKEN", revealedKeys: $revealedKeys,
				onClose: {}, onCopySecret: { _, _ in }, onDeleteSecret: { _, _ in })
				.frame(width: 300, height: 640)
		}
	}
}

private struct AddVariablePresentedFixture: View {
	let store: VaultStore
	@State private var shown = true

	var body: some View {
		Color.clear.frame(width: 800, height: 650)
			.sheet(isPresented: $shown) {
				AddVariableSheet(store: store, projectId: "sheet-regression", environment: "default", initialKey: "CONTROL")
			}
	}
}
