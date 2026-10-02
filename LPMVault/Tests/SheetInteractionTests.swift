import AppKit
import SwiftUI
import Testing
import Vision

@testable import LPMVault

/// Text recognition for window tests. Recognition runs off the main actor so
/// other main-actor suites keep running while Vision works.
enum RenderedText {
	struct Line: Sendable {
		let text: String
		/// Normalized Vision bounds of the whole line.
		let bounds: CGRect
		/// Normalized Vision bounds of the searched label within the line.
		let labelBounds: CGRect?
	}

	static func lines(
		in image: CGImage,
		level: VNRequestTextRecognitionLevel,
		label: String? = nil,
		options: String.CompareOptions = []
	) async throws -> [Line] {
		try await Task.detached(priority: .userInitiated) {
			let request = VNRecognizeTextRequest()
			request.recognitionLevel = level
			request.usesLanguageCorrection = false
			try VNImageRequestHandler(cgImage: image).perform([request])
			return (request.results ?? []).compactMap { observation -> Line? in
				guard let candidate = observation.topCandidates(1).first else { return nil }
				var labelBounds: CGRect?
				if let label, let range = candidate.string.range(of: label, options: options) {
					labelBounds = try? candidate.boundingBox(for: range)?.boundingBox
				}
				return Line(text: candidate.string, bounds: observation.boundingBox, labelBounds: labelBounds)
			}
		}.value
	}
}

@MainActor
final class SheetTestHost<V: View> {
	let view: NSView
	let window: NSWindow
	private static var timeout: Duration { .seconds(3) }

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

	/// Fixed pause before asserting that something did not happen.
	func settle() async throws {
		for _ in 0..<8 {
			view.layoutSubtreeIfNeeded()
			try await Task.sleep(for: .milliseconds(10))
		}
	}

	/// Returns as soon as `condition` holds, or `false` after the timeout.
	@discardableResult
	func waitUntil(_ condition: () throws -> Bool) async throws -> Bool {
		let deadline = ContinuousClock.now.advanced(by: Self.timeout)
		repeat {
			view.layoutSubtreeIfNeeded()
			if try condition() { return true }
			try await Task.sleep(for: .milliseconds(5))
		} while ContinuousClock.now < deadline
		return try condition()
	}

	/// Definitive recognition, for assertions that text is absent or present right now.
	func text(in targetWindow: NSWindow? = nil) async throws -> OCRText {
		let lines = try await RenderedText.lines(in: snapshot(targetWindow?.contentView ?? view), level: .accurate)
		return OCRText(lines.map(\.text).joined(separator: "\n"))
	}

	/// Polls with fast recognition and confirms with accurate recognition before giving up.
	func waitForText(_ expected: String, in targetWindow: NSWindow? = nil) async throws -> Bool {
		let target = targetWindow?.contentView ?? view
		let deadline = ContinuousClock.now.advanced(by: Self.timeout)
		repeat {
			target.layoutSubtreeIfNeeded()
			let lines = try await RenderedText.lines(in: snapshot(target), level: .fast)
			if OCRText(lines.map(\.text).joined(separator: "\n")).contains(expected) { return true }
			try await Task.sleep(for: .milliseconds(20))
		} while ContinuousClock.now < deadline
		return try await text(in: targetWindow).contains(expected)
	}

	/// Clicks the rendered label once it appears, using real mouse events.
	func click(_ label: String, in targetWindow: NSWindow? = nil, caseInsensitive: Bool = false) async throws {
		let window = targetWindow ?? self.window
		let target = try #require(window.contentView)
		let options: String.CompareOptions = caseInsensitive ? .caseInsensitive : []
		// Accurate recognition: fast mode returns whole-line boxes for substrings,
		// which can place the click between neighboring buttons.
		let deadline = ContinuousClock.now.advanced(by: Self.timeout)
		var bounds: CGRect?
		repeat {
			target.layoutSubtreeIfNeeded()
			bounds = try await labelBounds(label, in: target, level: .accurate, options: options)
			if bounds == nil { try await Task.sleep(for: .milliseconds(20)) }
		} while bounds == nil && ContinuousClock.now < deadline
		let box = try #require(bounds, "Missing button \(label)")
		let point = target.convert(
			NSPoint(x: box.midX * target.bounds.width, y: (target.isFlipped ? 1 - box.midY : box.midY) * target.bounds.height),
			to: nil
		)
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
		let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
		window.sendEvent(event)
	}

	func key(_ character: String, code: UInt16, modifiers: NSEvent.ModifierFlags = [], in targetWindow: NSWindow) throws {
		let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: targetWindow.windowNumber, context: nil, characters: character, charactersIgnoringModifiers: character, isARepeat: false, keyCode: code))
		NSApplication.shared.sendEvent(event)
	}

	func escape() throws -> Bool {
		let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
		return window.performKeyEquivalent(with: event)
	}

	var value: String { textFields(in: view).first { $0 is NSSecureTextField }?.stringValue ?? "" }

	var isKeyFieldEnabled: Bool { textFields(in: view).first { !($0 is NSSecureTextField) }?.isEnabled ?? false }

	/// Normalized bounds of the line containing `label`.
	func bounds(of label: String) async throws -> CGRect {
		let lines = try await RenderedText.lines(in: snapshot(view, scale: 3), level: .accurate)
		return try #require(lines.first { OCRText($0.text).contains(label) }?.bounds)
	}

	func line(containing label: String) async throws -> String {
		let lines = try await RenderedText.lines(in: snapshot(view), level: .accurate)
		return try #require(lines.map(\.text).first { $0.contains(label) })
	}

	func generatorWindow() async throws -> NSWindow {
		let deadline = ContinuousClock.now.advanced(by: Self.timeout)
		repeat {
			if let panel = try await visibleGeneratorWindow() {
				try await settle()
				return panel
			}
			try await Task.sleep(for: .milliseconds(10))
		} while ContinuousClock.now < deadline
		throw CocoaError(.coderValueNotFound)
	}

	func waitForGeneratorDismissal(_ panel: NSWindow) async throws -> Bool {
		try await waitUntil { !panel.isVisible }
	}

	/// The generator is the only popover these fixtures present. Fall back to its
	/// rendered heading in case a future macOS hosts popovers in another window class.
	func visibleGeneratorWindow() async throws -> NSWindow? {
		let candidates = NSApp.windows.filter { $0 !== window && $0.isVisible && !($0.contentView?.bounds.isEmpty ?? true) }
		if let popover = candidates.first(where: { $0.className.contains("Popover") }) { return popover }
		for candidate in candidates where !window.sheets.contains(candidate) {
			guard let content = candidate.contentView else { continue }
			let lines = try await RenderedText.lines(in: snapshot(content), level: .fast)
			if OCRText(lines.map(\.text).joined(separator: " ")).contains("GENERATE VALUE") { return candidate }
		}
		return nil
	}

	private func labelBounds(_ label: String, in target: NSView, level: VNRequestTextRecognitionLevel, options: String.CompareOptions) async throws -> CGRect? {
		let lines = try await RenderedText.lines(in: snapshot(target), level: level, label: label, options: options)
		return lines.lazy.compactMap(\.labelBounds).first
	}

	private func textFields(in view: NSView) -> [NSTextField] {
		if let field = view as? NSTextField { return [field] }
		return view.subviews.flatMap { textFields(in: $0) }
	}

	private func snapshot(_ target: NSView, scale: Int? = nil) throws -> CGImage {
		target.layoutSubtreeIfNeeded()
		let bitmap: NSBitmapImageRep
		if let scale {
			bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(target.bounds.width) * scale, pixelsHigh: Int(target.bounds.height) * scale, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
			bitmap.size = target.bounds.size
		} else {
			bitmap = try #require(target.bitmapImageRepForCachingDisplay(in: target.bounds))
		}
		target.cacheDisplay(in: target.bounds, to: bitmap)
		return try #require(bitmap.cgImage)
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

	private func stored(_ keychain: MockKeychainService, _ environment: String, _ key: String) -> String? {
		keychain.envStorage["sheet-regression"]?.environments[environment]?[key]
	}

	@Test("lock-screen encryption note stays centered above the bottom", arguments: [NSSize(width: 1040, height: 640), NSSize(width: 1400, height: 900)], [ColorScheme.light, .dark])
	func lockScreenFooter(size: NSSize, scheme: ColorScheme) async throws {
		let (store, _) = makeStore()
		store.lock()
		let host = SheetTestHost(ContentView(store: store).environment(\.colorScheme, scheme), size: size)
		defer { host.window.close() }
		try await host.settle()
		let bounds = try await host.bounds(of: "Values stay encrypted")
		#expect(abs(bounds.midX - 0.5) * host.view.bounds.width < 3)
		#expect((15...28).contains(bounds.minY * host.view.bounds.height))
		#expect(try await host.line(containing: "Unlock").range(of: #"Unlock\s+\S*L"#, options: .regularExpression) != nil)
	}

	@Test("inspector generation changes only the draft until saved", arguments: [ColorScheme.light, .dark])
	func inspectorGeneratorDraft(scheme: ColorScheme) async throws {
		let (store, keychain) = makeStore(environments: ["default": ["TOKEN": "old"], "production": ["TOKEN": "production-old"]])
		store.selectedEnvironment = "default"
		let host = SheetTestHost(InspectorInteractionFixture(store: store).environment(\.colorScheme, scheme), size: NSSize(width: 300, height: 640))
		defer { host.window.close() }
		try await host.settle()
		try await host.click("Generate")
		let panel = try await host.generatorWindow()
		try await host.click("Password", in: panel)
		try await host.waitUntil { host.value != "old" }
		let generated = host.value
		#expect(generated.count == SecretValueGenerator.defaultLength)
		#expect(generated != "old")
		#expect(stored(keychain, "default", "TOKEN") == "old")
		// Synthetic clicks bypass the popover's outside-click monitor, so close it with its button.
		try await host.click("Generate")
		#expect(try await host.waitForGeneratorDismissal(panel))
		try await host.click("Revert")
		try await host.waitUntil { host.value == "old" }
		#expect(host.value == "old")
		try await host.click("Generate")
		let secondPanel = try await host.generatorWindow()
		try await host.click("UUID v4", in: secondPanel, caseInsensitive: true)
		try await host.waitUntil { UUID(uuidString: host.value) != nil }
		let second = host.value
		#expect(UUID(uuidString: second) != nil)
		try await host.click("Save")
		try await host.waitUntil { stored(keychain, "default", "TOKEN") == second }
		#expect(stored(keychain, "default", "TOKEN") == second)
		#expect(stored(keychain, "production", "TOKEN") == "production-old")
	}

	@Test("inspector generation cannot replace a pending save or conflicting draft", arguments: ["save", "conflict"])
	func inspectorGeneratorUnavailable(reason: String) async throws {
		let (store, keychain) = makeStore(environments: ["default": ["TOKEN": "old"]])
		let host = SheetTestHost(InspectorInteractionFixture(store: store), size: NSSize(width: 300, height: 640))
		defer { host.window.close() }
		try await host.settle()
		try await host.click("Generate")
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
				DispatchQueue.global().async { continuation.resume(returning: entered.wait(timeout: .now() + 3) == .success) }
			}
			try #require(didEnter)
		} else {
			store.projects[0].environments["default"]?["TOKEN"] = "external"
			#expect(try await host.waitForText("This value changed outside the editor."))
		}
		#expect(try await host.waitForGeneratorDismissal(panel))
		#expect(try await host.visibleGeneratorWindow() == nil)
		try await host.click("Generate")
		try await host.settle()
		#expect(try await host.visibleGeneratorWindow() == nil)
		#expect(host.value == generated)
		if reason == "conflict" {
			try await host.click("Revert")
			try await host.waitUntil { host.value == "external" }
			#expect(host.value == "external")
			try await host.click("Generate")
			let recoveredPanel = try await host.generatorWindow()
			try await host.click("Generate")
			#expect(try await host.waitForGeneratorDismissal(recoveredPanel))
		}
	}

	@Test("cancel is unavailable while an add transaction is committing")
	func cancelUnavailableDuringCommit() async throws {
		let (store, keychain) = makeStore()
		let host = SheetTestHost(AddVariableSheet(store: store, projectId: "sheet-regression", environment: "default", initialKey: "COMMITTING"), size: NSSize(width: 560, height: 520))
		defer { host.window.close() }
		let entered = DispatchSemaphore(value: 0)
		let release = DispatchSemaphore(value: 0)
		keychain.beforeKeychainTransaction = { entered.signal(); release.wait() }
		defer { release.signal() }
		try await host.settle()
		try await host.click("Add to")
		let didEnter = await withCheckedContinuation { continuation in
			DispatchQueue.global().async { continuation.resume(returning: entered.wait(timeout: .now() + 3) == .success) }
		}
		try #require(didEnter)
		try await host.settle()
		try await host.click("Cancel")
		try await host.settle()
		#expect(try host.escape() == false)
		#expect(host.isKeyFieldEnabled == false)
		release.signal()
		try await host.waitUntil { stored(keychain, "default", "COMMITTING") == "" }
		#expect(stored(keychain, "default", "COMMITTING") == "")
	}

	@Test("privacy changes clear a draft even while a transaction is committing", arguments: [false, true])
	func privacyClearsCommittingDraft(changeProject: Bool) async throws {
		let (store, keychain) = makeStore()
		let host = SheetTestHost(AddVariableSheet(store: store, projectId: "sheet-regression", environment: "default", initialKey: "PRIVATE"), size: NSSize(width: 560, height: 520))
		defer { host.window.close() }
		try await host.settle()
		try host.enterValue("synthetic-value")
		try await host.waitUntil { host.value == "synthetic-value" }
		try #require(host.value == "synthetic-value")
		let entered = DispatchSemaphore(value: 0)
		let release = DispatchSemaphore(value: 0)
		keychain.beforeKeychainTransaction = { entered.signal(); release.wait() }
		defer { release.signal() }
		try await host.click("Add to")
		let didEnter = await withCheckedContinuation { continuation in
			DispatchQueue.global().async { continuation.resume(returning: entered.wait(timeout: .now() + 3) == .success) }
		}
		try #require(didEnter)
		if changeProject { store.selectedProjectId = nil } else { store.lock() }
		try await host.waitUntil { host.value.isEmpty }
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
		try await host.click("write file")
		try await host.click("Choose folder")
		#expect(try await host.waitForText("Replace vault ID"))
		try await host.settle()
		#expect(try Data(contentsOf: config) == original)
	}

	@Test("the connect sheet names LPM CLI after checking its link status")
	func connectProductNames() async throws {
		let (store, _) = makeStore()
		let host = SheetTestHost(ConnectCLISheet(store: store, projectId: "sheet-regression"), size: NSSize(width: 600, height: 560))
		defer { host.window.close() }
		#expect(try await host.waitForText("Install LPM CLI"))
		#expect(try await host.text().contains("Connect to the LPM CLI"))
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
		try await first.click("write file")
		try await first.click("Choose folder")
		try #require(try await first.waitForText("Write lpm.json"))
		try await first.click("Write")
		try #require(try await first.waitForText("Linked in lpm.json"))
		first.window.close()
		let second = SheetTestHost(ConnectCLISheet(store: store, projectId: "sheet-regression", localFolderDefaults: defaults), size: NSSize(width: 600, height: 560))
		defer { second.window.close() }
		#expect(try await second.waitForText("Linked in lpm.json"))
	}

	@Test("adding and keeping open preserves the success confirmation through UI updates")
	func keepOpenConfirmation() async throws {
		let (store, keychain) = makeStore()
		let host = SheetTestHost(AddVariableSheet(store: store, projectId: "sheet-regression", environment: "default", initialKey: "TOKEN"), size: NSSize(width: 560, height: 520))
		defer { host.window.close() }
		try await host.settle()
		try host.returnWhileEditing("key")
		try await host.waitUntil { stored(keychain, "default", "TOKEN") == "" }
		#expect(stored(keychain, "default", "TOKEN") == "")
		#expect(try await host.waitForText("Added TOKEN"))
		try host.enterKey("NEXT")
		try await host.settle()
		#expect(try await !host.text().contains("Added TOKEN"))
	}

	@Test("Shift Return keeps the sheet open from every focused field", arguments: ["key", "secure value", "revealed value"], [false, true])
	func focusedKeepOpen(target: String, capsLock: Bool) async throws {
		let (store, keychain) = makeStore()
		let host = SheetTestHost(AddVariableSheet(store: store, projectId: "sheet-regression", environment: "default", initialKey: "FOCUSED", initialValueRevealed: target == "revealed value"), size: NSSize(width: 560, height: 520))
		defer { host.window.close() }
		try await host.settle()
		try host.returnWhileEditing(target, modifiers: capsLock ? [.shift, .capsLock] : .shift)
		#expect(try await host.waitForText("Added FOCUSED"))
		#expect(stored(keychain, "default", "FOCUSED") != nil)
	}

	@Test("ordinary Return advances from the key and submits from the value")
	func ordinaryReturnPreservesFieldActions() async throws {
		let (store, keychain) = makeStore()
		let host = SheetTestHost(AddVariableSheet(store: store, projectId: "sheet-regression", environment: "default", initialKey: "ORDINARY"), size: NSSize(width: 560, height: 520))
		defer { host.window.close() }
		try await host.settle()
		try host.returnWhileEditing("key", modifiers: [])
		try await host.settle()
		#expect(stored(keychain, "default", "ORDINARY") == nil)
		try host.returnWhileEditing("secure value", modifiers: [])
		try await host.waitUntil { stored(keychain, "default", "ORDINARY") == "" }
		#expect(stored(keychain, "default", "ORDINARY") == "")
		try await host.settle()
		#expect(try await !host.text().contains("Added ORDINARY"))
	}

	@Test("Shift Return keeps a presented sheet open after focus leaves a text field", arguments: ["generator", "tab"], [false, true])
	func keepOpenAfterControlFocus(transition: String, capsLock: Bool) async throws {
		let (store, keychain) = makeStore()
		let host = SheetTestHost(AddVariablePresentedFixture(store: store), size: NSSize(width: 800, height: 650))
		defer {
			for sheet in host.window.sheets { host.window.endSheet(sheet); sheet.orderOut(nil) }
			host.window.close()
		}
		try await host.waitUntil { host.window.sheets.first != nil }
		let sheet = try #require(host.window.sheets.first)
		try await focusControl(transition, in: sheet, host: host)
		try host.key("\r", code: 36, modifiers: capsLock ? [.shift, .capsLock] : .shift, in: sheet)
		#expect(try await host.waitForText("Added CONTROL", in: sheet))
		#expect(stored(keychain, "default", "CONTROL") == "")
		#expect(host.window.sheets.count == 1)
	}

	@Test("many environments keep the variable fields and actions inside a bounded sheet")
	func manyEnvironmentsFit() async throws {
		let environments = Dictionary(uniqueKeysWithValues: (0..<90).map { (String(format: "env%03d", $0), [String: String]()) })
		let (store, _) = makeStore(environments: environments)
		let host = SheetTestHost(AddVariableSheet(store: store, projectId: "sheet-regression", environment: "env000"), size: NSSize(width: 560, height: 640))
		defer { host.window.close() }
		#expect(host.view.fittingSize.height <= 640)
		let rendered = try await host.text()
		#expect(rendered.contains("Add variable"))
		#expect(rendered.contains("Cancel"))
	}

	@Test("ordinary Return closes the presented sheet after returning focus from controls", arguments: ["generator", "tab"], [0, 1, 2, 3])
	func ordinaryReturnAfterControlFocus(transition: String, sample: Int) async throws {
		let (store, keychain) = makeStore()
		let key = "CONTROL_\(sample)"
		let host = SheetTestHost(AddVariablePresentedFixture(store: store, key: key), size: NSSize(width: 800, height: 650))
		defer {
			for sheet in host.window.sheets { host.window.endSheet(sheet); sheet.orderOut(nil) }
			host.window.close()
		}
		try await host.waitUntil { host.window.sheets.first != nil }
		let sheet = try #require(host.window.sheets.first)
		try await focusControl(transition, in: sheet, host: host)
		// A focused button can suppress AppKit's default Return action.
		try #require(sheet.makeFirstResponder(nil))
		try #require(sheet.firstResponder === sheet)
		try host.key("\r", code: 36, in: sheet)
		try await host.waitUntil { host.window.sheets.isEmpty }
		#expect(stored(keychain, "default", key) == "")
		#expect(keychain.updateEnvironmentsCallCount == 1)
		#expect(host.window.sheets.isEmpty)
	}

	/// Moves focus off the sheet's text fields: through the generator popover, or by tabbing to a control.
	private func focusControl(_ transition: String, in sheet: NSWindow, host: SheetTestHost<AddVariablePresentedFixture>) async throws {
		if transition == "generator" {
			try await host.click("Generate", in: sheet)
			_ = try await host.generatorWindow()
			try await host.click("Add variable", in: sheet)
		} else {
			for _ in 0..<2 { try host.key("\t", code: 48, in: sheet); try await host.settle() }
		}
		try await host.settle()
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
	var key = "CONTROL"
	@State private var shown = true

	var body: some View {
		Color.clear.frame(width: 800, height: 650)
			.sheet(isPresented: $shown) {
				AddVariableSheet(store: store, projectId: "sheet-regression", environment: "default", initialKey: key)
			}
	}
}
