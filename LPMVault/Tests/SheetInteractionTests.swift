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
		options: String.CompareOptions = [],
		region: CGRect? = nil
	) async throws -> [Line] {
		try await Task.detached(priority: .userInitiated) {
			let request = VNRecognizeTextRequest()
			request.recognitionLevel = level
			request.usesLanguageCorrection = false
			if let region { request.regionOfInterest = region }
			try VNImageRequestHandler(cgImage: image).perform([request])
			return (request.results ?? []).compactMap { observation -> Line? in
				guard let candidate = observation.topCandidates(1).first else { return nil }
				var labelBounds: CGRect?
				if let label, let range = candidate.string.range(of: label, options: options) {
					labelBounds = try? candidate.boundingBox(for: range)?.boundingBox
				}
				// Results inside a region of interest are relative to that region.
				let map: (CGRect) -> CGRect = { box in
					guard let region else { return box }
					return CGRect(
						x: region.minX + box.minX * region.width,
						y: region.minY + box.minY * region.height,
						width: box.width * region.width,
						height: box.height * region.height
					)
				}
				return Line(text: candidate.string, bounds: map(observation.boundingBox), labelBounds: labelBounds.map(map))
			}
		}.value
	}
}

@MainActor
final class SheetTestHost<V: View> {
	let view: NSView
	let window: NSWindow
	/// Generous because one recognition pass can take seconds on CPU-only CI runners;
	/// successful waits return as soon as their condition holds.
	private static var timeout: Duration { .seconds(10) }

	/// `keepsRequestedSize` stops the hosting view from shrinking to the content's minimum size.
	init(_ root: V, size: NSSize, keepsRequestedSize: Bool = false) {
		let controller = NSHostingController(rootView: root)
		if keepsRequestedSize { controller.sizingOptions = [] }
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

	/// Tries fast recognition, then accurate recognition for small text, on each pass.
	/// `footer` limits rendering and recognition to the bottom points of the window.
	func waitForText(_ expected: String, in targetWindow: NSWindow? = nil, footer: CGFloat? = nil) async throws -> Bool {
		let target = try #require(targetWindow?.contentView ?? view)
		let area = footer.map { bottomBand(of: target, height: $0) }
		let deadline = ContinuousClock.now.advanced(by: Self.timeout)
		repeat {
			let image = try snapshot(target, rect: area)
			for level in [VNRequestTextRecognitionLevel.fast, .accurate] {
				let lines = try await RenderedText.lines(in: image, level: level)
				if OCRText(lines.map(\.text).joined(separator: "\n")).contains(expected) { return true }
			}
			try await Task.sleep(for: .milliseconds(20))
		} while ContinuousClock.now < deadline
		return false
	}

	/// Clicks the rendered label once it appears, using real mouse events.
	func click(_ label: String, in targetWindow: NSWindow? = nil, caseInsensitive: Bool = false) async throws {
		let window = targetWindow ?? self.window
		let target = try #require(window.contentView)
		let options: String.CompareOptions = caseInsensitive ? .caseInsensitive : []
		let deadline = ContinuousClock.now.advanced(by: Self.timeout)
		var bounds: CGRect?
		repeat {
			bounds = try await labelBounds(label, in: target, options: options)
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

	/// Bounds, in points from the bottom-left, of everything drawn over the solid
	/// background within the bottom `band` points, plus the text recognized there.
	func bottomInk(band: CGFloat) async throws -> (bounds: CGRect, text: OCRText) {
		let image = try snapshot(view, rect: bottomBand(of: view, height: band))
		let scale = CGFloat(image.width) / view.bounds.width
		let width = image.width, height = image.height
		let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
		context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
		let pixels = try #require(context.data).assumingMemoryBound(to: UInt8.self)
		// Bitmap memory starts with the top row. Sample the background mid-band and
		// skip the window's rounded corners.
		let margin = Int(12 * scale)
		let sample = ((height / 2) * width + margin) * 4
		let red = Int(pixels[sample]), green = Int(pixels[sample + 1]), blue = Int(pixels[sample + 2])
		var minX = Int.max, maxX = Int.min, minTop = Int.max, maxTop = Int.min
		for top in 0..<height {
			var pixel = (top * width + margin) * 4
			for column in margin..<(width - margin) {
				let difference = abs(Int(pixels[pixel]) - red) + abs(Int(pixels[pixel + 1]) - green) + abs(Int(pixels[pixel + 2]) - blue)
				if difference > 24 {
					if column < minX { minX = column }
					if column > maxX { maxX = column }
					if top < minTop { minTop = top }
					if top > maxTop { maxTop = top }
				}
				pixel += 4
			}
		}
		try #require(minX <= maxX, "Nothing drawn in the bottom \(band) points")
		let bounds = CGRect(
			x: CGFloat(minX) / scale,
			y: CGFloat(height - 1 - maxTop) / scale,
			width: CGFloat(maxX - minX + 1) / scale,
			height: CGFloat(maxTop - minTop + 1) / scale
		)
		let region = CGRect(
			x: bounds.minX / view.bounds.width,
			y: bounds.minY / band,
			width: bounds.width / view.bounds.width,
			height: bounds.height / band
		).insetBy(dx: -0.01, dy: -0.1).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
		let lines = try await RenderedText.lines(in: image, level: .accurate, region: region)
		return (bounds, OCRText(lines.map(\.text).joined(separator: " ")))
	}

	/// Recognizes the line containing `label` within `rect` (view coordinates).
	func line(containing label: String, rect: NSRect) async throws -> String {
		let lines = try await RenderedText.lines(in: snapshot(view, rect: rect), level: .accurate)
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

	/// Fast mode finds the line cheaply but reports whole-line boxes for substrings, which
	/// can land a click between neighboring buttons. Accurate mode then reads only that line.
	private func labelBounds(_ label: String, in target: NSView, options: String.CompareOptions) async throws -> CGRect? {
		let image = try snapshot(target)
		let fast = try await RenderedText.lines(in: image, level: .fast, label: label, options: options)
		if let line = fast.first(where: { $0.labelBounds != nil }) {
			let strip = line.bounds.insetBy(dx: -0.02, dy: -line.bounds.height).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
			let refined = try await RenderedText.lines(in: image, level: .accurate, label: label, options: options, region: strip)
			if let bounds = refined.lazy.compactMap(\.labelBounds).first { return bounds }
		}
		let accurate = try await RenderedText.lines(in: image, level: .accurate, label: label, options: options)
		return accurate.lazy.compactMap(\.labelBounds).first
	}

	private func textFields(in view: NSView) -> [NSTextField] {
		if let field = view as? NSTextField { return [field] }
		return view.subviews.flatMap { textFields(in: $0) }
	}

	/// Renders `rect` (view coordinates, whole view by default) at the backing scale.
	private func snapshot(_ target: NSView, rect: NSRect? = nil) throws -> CGImage {
		target.layoutSubtreeIfNeeded()
		let area = rect ?? target.bounds
		let bitmap = try #require(target.bitmapImageRepForCachingDisplay(in: area))
		target.cacheDisplay(in: area, to: bitmap)
		return try #require(bitmap.cgImage)
	}

	/// The bottom `height` points of `target`, in its own coordinates.
	private func bottomBand(of target: NSView, height: CGFloat) -> NSRect {
		NSRect(x: 0, y: target.isFlipped ? target.bounds.height - height : 0, width: target.bounds.width, height: height)
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
		let host = SheetTestHost(ContentView(store: store).environment(\.colorScheme, scheme), size: size, keepsRequestedSize: true)
		defer { host.window.close() }
		try await host.settle()
		let note = try await host.bottomInk(band: 60)
		#expect(host.view.bounds.size == size)
		#expect(note.text.contains("Values stay encrypted"))
		#expect(abs(note.bounds.midX - host.view.bounds.width / 2) < 3)
		#expect((15...28).contains(note.bounds.minY))
		let center = host.view.bounds.insetBy(dx: host.view.bounds.width * 0.25, dy: host.view.bounds.height * 0.25)
		#expect(try await host.line(containing: "Unlock", rect: center).range(of: #"Unlock\s+\S*L"#, options: .regularExpression) != nil)
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
		#expect(try await host.waitForText("Added TOKEN", footer: 80))
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
		#expect(try await host.waitForText("Added FOCUSED", footer: 80))
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
		#expect(try await host.waitForText("Added CONTROL", in: sheet, footer: 80))
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
