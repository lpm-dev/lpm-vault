import AppKit
import ApplicationServices
import SwiftUI
import Testing

/// What native UI tests read of a window or view: its accessibility tree,
/// as VoiceOver reads it. Text is matched exactly as the app sets it, so a
/// test reads the same on every Mac and runner.
///
/// SwiftUI builds its tree only once an assistive client asks for one, so the
/// first read asks this process about itself through the accessibility API,
/// which needs no permission for a process's own elements. Everything after
/// that is read in-process, without the window server, so it reads the same
/// with the screen locked.
@MainActor
enum AccessibilityTree {
	struct Element {
		let role: NSAccessibility.Role?
		let label: String?
		let title: String?
		let value: String?
		let placeholder: String?
		let help: String?
		let identifier: String?
		/// In screen coordinates, as accessibility reports frames.
		let frame: CGRect
		/// The part of `frame` its scroll areas show; empty when it's scrolled out of view.
		let visibleFrame: CGRect
		let isEnabled: Bool
		fileprivate let object: AnyObject

		/// What it says, as VoiceOver reads it out: its label, title and value.
		var texts: [String] {
			var texts: [String] = []
			for text in [label, title, value] {
				if let text, !text.isEmpty, !texts.contains(text) { texts.append(text) }
			}
			return texts
		}

		var isInteractive: Bool {
			guard let role else { return false }
			return Self.interactiveRoles.contains(role)
		}

		/// How an element's text holds what's looked for.
		enum Match: CaseIterable {
			/// It's all the element says.
			case exact
			/// It begins what the element says, as a key begins its row's label.
			case leading
			/// It's somewhere in what the element says, as whole words, so "PORT"
			/// isn't found in "Import" but "REGION" is in "ACME_PUBLIC_REGION".
			case words
		}

		/// Whether it says `text` as `match` describes.
		func says(_ text: String, exactly: Bool = true, options: String.CompareOptions = []) -> Bool {
			says(text, as: exactly ? .exact : .words, options: options)
		}

		func says(_ text: String, as match: Match, options: String.CompareOptions = []) -> Bool {
			texts.contains { said in
				if match == .exact { return said.compare(text, options: options) == .orderedSame }
				var searched = said.startIndex..<said.endIndex
				while let range = said.range(of: text, options: options, range: searched) {
					if match == .leading, range.lowerBound != said.startIndex { return false }
					let before = range.lowerBound == said.startIndex ? nil : said[said.index(before: range.lowerBound)]
					let after = range.upperBound == said.endIndex ? nil : said[range.upperBound]
					if !(before.map(Self.isWordCharacter) ?? false), !(after.map(Self.isWordCharacter) ?? false) { return true }
					if match == .leading { return false }
					searched = said.index(after: range.lowerBound)..<said.endIndex
				}
				return false
			}
		}

		private static func isWordCharacter(_ character: Character) -> Bool {
			character.isLetter || character.isNumber
		}

		/// Performs its action, as VoiceOver's VO-Space does, without a click.
		@discardableResult
		func press() -> Bool {
			object.accessibilityPerformPress?() ?? false
		}

		/// Whether it's a SwiftUI control that a press works as a click on. On
		/// CI's macOS 15 runners, mouse events a test sends don't reliably reach
		/// SwiftUI controls, and a press needs none.
		var isPressable: Bool {
			guard let role, Self.pressableRoles.contains(role), !(object is NSView), let object = object as? NSObject else { return false }
			return object.responds(to: #selector(NSAccessibilityProtocol.accessibilityPerformPress))
		}

		private static let pressableRoles: Set<NSAccessibility.Role> = [.button, .link, .checkBox, .disclosureTriangle]

		private static let interactiveRoles: Set<NSAccessibility.Role> = [
			.button, .checkBox, .radioButton, .popUpButton, .menuButton, .menuItem, .link, .disclosureTriangle,
			.textField, .comboBox, .slider, .incrementor, .cell, .row,
		]
	}

	/// A row of text as it's laid out on screen: the visible elements whose
	/// middles are level, read left to right.
	struct Line {
		let text: String
		/// The line's bounds, normalized to the view it was read in, from its bottom-left.
		let bounds: CGRect
		/// The bounds of the first element saying the label looked for, normalized the same way.
		let labelBounds: CGRect?
	}

	private static var isActive = false

	/// Makes SwiftUI build its accessibility tree, as an assistive client's
	/// first request does.
	static func activate() {
		guard !isActive else { return }
		isActive = true
		// A test process never finishes launching on its own, and until it has,
		// it can't answer an accessibility request, even its own.
		NSApplication.shared.finishLaunching()
		var role: CFTypeRef?
		let result = AXUIElementCopyAttributeValue(AXUIElementCreateApplication(getpid()), kAXRoleAttribute as CFString, &role)
		if result != .success { Issue.record("Accessibility didn't answer this process's request: \(result.rawValue)") }
	}

	/// Every element in `root`, a window or a view, in the tree's reading order.
	static func elements(in root: NSObject) -> [Element] {
		activate()
		var elements: [Element] = []
		var visited = Set<ObjectIdentifier>()
		func visit(_ object: AnyObject, depth: Int, clip: CGRect) {
			guard depth < 96, visited.insert(ObjectIdentifier(object)).inserted else { return }
			let element = element(object, clip: clip)
			elements.append(element)
			let childClip = element.role == .scrollArea ? element.visibleFrame : clip
			for case let child as AnyObject in (attribute(object, #selector(NSAccessibilityProtocol.accessibilityChildren)) as? [Any]) ?? [] {
				// A sheet or other window is read on its own, as it's drawn on its own.
				if child is NSWindow, child !== root { continue }
				visit(child, depth: depth + 1, clip: childClip)
			}
		}
		visit(root, depth: 0, clip: .infinite)
		return elements
	}

	/// The elements of `root` drawn within `area` of `view`, in `view`'s
	/// coordinates, or anywhere in `view` when there's no area.
	static func visibleElements(in root: NSObject, of view: NSView, area: CGRect? = nil) -> [Element] {
		guard let window = view.window else { return elements(in: root).filter { !$0.texts.isEmpty } }
		let screenArea = window.convertToScreen(view.convert(area ?? view.visibleRect, to: nil))
		return elements(in: root).filter { element in
			!element.visibleFrame.isEmpty && element.visibleFrame.intersects(screenArea)
		}
	}

	/// The text of `view` as lines laid out on screen, within `region` when
	/// given, in the normalized coordinates of `view` from its bottom-left.
	static func lines(in view: NSView, root: NSObject? = nil, region: CGRect? = nil, label: String? = nil,
		options: String.CompareOptions = []) -> [Line]
	{
		let area = region.map { normalized in
			let bounds = view.bounds
			let rect = CGRect(x: normalized.minX * bounds.width, y: normalized.minY * bounds.height,
				width: normalized.width * bounds.width, height: normalized.height * bounds.height)
			return view.isFlipped ? CGRect(x: rect.minX, y: bounds.height - rect.maxY, width: rect.width, height: rect.height) : rect
		}
		let visible = visibleElements(in: root ?? view.window ?? view, of: view, area: area).filter { !$0.texts.isEmpty }
		var rows: [[(element: Element, bounds: CGRect)]] = []
		for element in visible {
			let bounds = normalizedBounds(of: element, in: view)
			if let index = rows.firstIndex(where: { row in
				row.contains { abs($0.bounds.midY - bounds.midY) <= max($0.bounds.height, bounds.height) / 2 }
			}) {
				rows[index].append((element, bounds))
			} else {
				rows.append([(element, bounds)])
			}
		}
		return rows
			.map { $0.sorted { $0.bounds.minX < $1.bounds.minX } }
			.sorted { ($0.first?.bounds.midY ?? 0) > ($1.first?.bounds.midY ?? 0) }
			.map { row in
				let bounds = row.dropFirst().reduce(row[0].bounds) { $0.union($1.bounds) }
				let labelBounds = label.flatMap { label in
					row.first { $0.element.says(label, exactly: false, options: options) }?.bounds
				}
				return Line(text: row.flatMap(\.element.texts).joined(separator: " "), bounds: bounds, labelBounds: labelBounds)
			}
	}

	/// What `view` says, line by line.
	static func text(in view: NSView, root: NSObject? = nil, area: CGRect? = nil) -> AccessibleText {
		let region = area.map { area in
			CGRect(x: area.minX / view.bounds.width, y: (view.isFlipped ? view.bounds.height - area.maxY : area.minY) / view.bounds.height,
				width: area.width / view.bounds.width, height: area.height / view.bounds.height)
		}
		return AccessibleText(lines(in: view, root: root, region: region).map(\.text))
	}

	/// What a view outside any window says, as for a view rendered on its own.
	static func strings(in view: NSView) -> [String] {
		elements(in: view).flatMap(\.texts)
	}

	/// `element`'s frame in `view`, normalized to its size from the bottom-left.
	static func normalizedBounds(of element: Element, in view: NSView) -> CGRect {
		guard let window = view.window, view.bounds.width > 0, view.bounds.height > 0 else { return .zero }
		var local = view.convert(window.convertFromScreen(element.frame), from: nil)
		if view.isFlipped { local.origin.y = view.bounds.height - local.maxY }
		return CGRect(x: local.minX / view.bounds.width, y: local.minY / view.bounds.height,
			width: local.width / view.bounds.width, height: local.height / view.bounds.height)
	}

	/// The center of what's shown of `element`, in `window`'s coordinates, where a click lands on it.
	static func center(of element: Element, in window: NSWindow) -> NSPoint {
		var frame = window.convertFromScreen(element.visibleFrame.isEmpty ? element.frame : element.visibleFrame)
		if let content = window.contentView {
			let shown = frame.intersection(content.convert(content.bounds, to: nil))
			if !shown.isEmpty { frame = shown }
		}
		return NSPoint(x: frame.midX, y: frame.midY)
	}

	private static func element(_ object: AnyObject, clip: CGRect) -> Element {
		let frame = object.accessibilityFrame?() ?? .zero
		return Element(
			role: string(attribute(object, #selector(NSAccessibilityProtocol.accessibilityRole))).map(NSAccessibility.Role.init(rawValue:)),
			label: string(attribute(object, #selector(NSAccessibilityProtocol.accessibilityLabel))),
			title: string(attribute(object, #selector(NSAccessibilityProtocol.accessibilityTitle))),
			value: string(attribute(object, #selector(NSAccessibilityProtocol.accessibilityValue))),
			placeholder: string(attribute(object, #selector(NSAccessibilityProtocol.accessibilityPlaceholderValue))),
			help: string(attribute(object, #selector(NSAccessibilityProtocol.accessibilityHelp))),
			identifier: string(attribute(object, #selector(NSAccessibilityProtocol.accessibilityIdentifier))),
			frame: frame,
			visibleFrame: frame.intersection(clip),
			isEnabled: object.isAccessibilityEnabled?() ?? true,
			object: object
		)
	}

	/// An object-valued attribute, read untyped: elements return attributed
	/// strings where strings are declared, which typed calls can't take.
	private static func attribute(_ object: AnyObject, _ selector: Selector) -> Any? {
		guard let object = object as? NSObject, object.responds(to: selector) else { return nil }
		return object.perform(selector)?.takeUnretainedValue()
	}

	private static func string(_ value: Any?) -> String? {
		switch value {
		case let text as String: text
		case let text as NSAttributedString: text.string
		default: nil
		}
	}
}

/// The text a view says, line by line. Letter case doesn't count: views draw
/// some text uppercased, as section labels, that they say as it's written.
struct AccessibleText: CustomStringConvertible {
	let lines: [String]

	init(_ lines: [String]) {
		self.lines = lines
	}

	/// Whether `expected` is said on one line, or across lines next to each other.
	func contains(_ expected: String, options: String.CompareOptions = .caseInsensitive) -> Bool {
		lines.contains { $0.range(of: expected, options: options) != nil }
			|| lines.joined(separator: " ").range(of: expected, options: options) != nil
	}

	var description: String { lines.joined(separator: "\n") }
}

extension SheetTestHost {
	/// Attaches how the host's view looks to the running test, for a failure to
	/// show, and keeps it in LPM_TEST_SNAPSHOT_DIR when that names a folder, as CI does.
	func attachSnapshot(named name: String, of target: NSView? = nil) throws {
		let image = NSBitmapImageRep(cgImage: try snapshot(target ?? view))
		let data = try #require(image.representation(using: .png, properties: [:]))
		Attachment.record(data, named: name + ".png")
		guard let folder = ProcessInfo.processInfo.environment["LPM_TEST_SNAPSHOT_DIR"], !folder.isEmpty else { return }
		let label = String(String.UnicodeScalarView(name.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? $0 : "-" }).prefix(60))
		try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
		try? data.write(to: URL(filePath: folder, directoryHint: .isDirectory).appending(path: "\(label)-\(UUID().uuidString.prefix(8)).png"))
	}

	/// What's drawn of the element saying `label`, in the host view's coordinates
	/// from the bottom-left: the bounds of its ink, without the padding its frame
	/// has, for checks of where text lines up.
	func drawnFrame(saying label: String, region: CGRect? = nil) async throws -> CGRect {
		let element = try await waitForElement(saying: label, region: region)
		let bounds = AccessibilityTree.normalizedBounds(of: element, in: view)
		let image = try snapshot(view)
		let width = image.width, height = image.height
		let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
			space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
		context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
		let pixels = try #require(context.data).assumingMemoryBound(to: UInt8.self)
		let minColumn = max(0, Int(bounds.minX * CGFloat(width))), maxColumn = min(width, Int((bounds.maxX * CGFloat(width)).rounded(.up)))
		let minRow = max(0, Int((1 - bounds.maxY) * CGFloat(height))), maxRow = min(height, Int(((1 - bounds.minY) * CGFloat(height)).rounded(.up)))
		try #require(minColumn < maxColumn && minRow < maxRow, "\(label) has no area")
		func color(_ column: Int, _ row: Int) -> (Int, Int, Int) {
			let pixel = (row * width + column) * 4
			return (Int(pixels[pixel]), Int(pixels[pixel + 1]), Int(pixels[pixel + 2]))
		}
		// The background is the color most of the frame has. Lines across the
		// whole frame, such as a cell's hairlines or a divider, aren't its text.
		var counts: [Int: Int] = [:]
		for row in minRow..<maxRow {
			for column in minColumn..<maxColumn { let (r, g, b) = color(column, row); counts[(r << 16) | (g << 8) | b, default: 0] += 1 }
		}
		let background = try #require(counts.max { $0.value < $1.value }?.key)
		let (red, green, blue) = (background >> 16, (background >> 8) & 255, background & 255)
		let columns = maxColumn - minColumn, rows = maxRow - minRow
		var isInk = [Bool](repeating: false, count: columns * rows)
		var rowInk = [Int](repeating: 0, count: rows), columnInk = [Int](repeating: 0, count: columns)
		for row in 0..<rows {
			for column in 0..<columns {
				let (r, g, b) = color(minColumn + column, minRow + row)
				guard abs(r - red) + abs(g - green) + abs(b - blue) > 60 else { continue }
				isInk[row * columns + column] = true
				rowInk[row] += 1
				columnInk[column] += 1
			}
		}
		var ink: (minX: Int, maxX: Int, minY: Int, maxY: Int)?
		for row in 0..<rows where rowInk[row] * 20 < columns * 19 {
			for column in 0..<columns where isInk[row * columns + column] && columnInk[column] * 20 < rows * 19 {
				let (x, y) = (minColumn + column, minRow + row)
				ink = (min(ink?.minX ?? x, x), max(ink?.maxX ?? x, x), min(ink?.minY ?? y, y), max(ink?.maxY ?? y, y))
			}
		}
		let drawn = try #require(ink, "Nothing is drawn where \(label) is")
		let scale = CGFloat(width) / view.bounds.width
		return CGRect(x: CGFloat(drawn.minX) / scale, y: CGFloat(height - 1 - drawn.maxY) / scale,
			width: CGFloat(drawn.maxX - drawn.minX + 1) / scale, height: CGFloat(drawn.maxY - drawn.minY + 1) / scale)
	}

	/// The lines the host's view says, within `region` when given, in
	/// normalized coordinates from the view's bottom-left.
	func lines(in region: CGRect? = nil, label: String? = nil, options: String.CompareOptions = []) -> [AccessibilityTree.Line] {
		view.layoutSubtreeIfNeeded()
		return AccessibilityTree.lines(in: view, root: window, region: region, label: label, options: options)
	}
}

extension AccessibilityTree {
	/// What `view` says laid out in a test window of its own, at `size` or at
	/// its fitting size, once it settles. `attaching` records how it looks.
	static func text<V: View>(of view: V, size: CGSize? = nil, appearance: NSAppearance? = nil, attaching name: String? = nil)
		async throws -> AccessibleText
	{
		let fitting = size ?? NSHostingView(rootView: view).fittingSize
		let host = SheetTestHost(view, size: NSSize(width: fitting.width, height: fitting.height), keepsRequestedSize: true, usesHostingView: true)
		defer { host.window.close() }
		if let appearance { host.view.appearance = appearance }
		try await host.settle()
		if let name {
			let image = NSBitmapImageRep(cgImage: try host.snapshot(host.view))
			Attachment.record(try #require(image.representation(using: .png, properties: [:])), named: name)
		}
		return try await host.text()
	}
}
