import AppKit
import SwiftUI

/// Raw text's code view: an environment as read-only text, with a line
/// number beside each line. A selection takes whole lines, and copying hands
/// `onCopy` the keys of the lines selected, so what's copied holds the real
/// values even of lines shown masked.
struct VaultRawTextView: NSViewRepresentable {
	let text: VaultRawText
	let label: String
	@Binding var selectedLineCount: Int
	let onCopy: ([String]) -> Void

	func makeCoordinator() -> Coordinator { Coordinator(self) }

	func makeNSView(context: Context) -> NSScrollView {
		let textView = CodeTextView(usingTextLayoutManager: false)
		textView.configureAsCode(label: label)
		textView.isEditable = false
		textView.delegate = context.coordinator
		let coordinator = context.coordinator
		textView.onCopy = { [weak coordinator] ranges in coordinator?.copy(ranges) }
		let scrollView = VaultCodeTextView.scrollView(for: textView)
		show(text, in: textView, coordinator: coordinator)
		return scrollView
	}

	func updateNSView(_ scrollView: NSScrollView, context: Context) {
		context.coordinator.parent = self
		guard let textView = scrollView.documentView as? CodeTextView else { return }
		textView.setAccessibilityLabel(label)
		show(text, in: textView, coordinator: context.coordinator)
	}

	static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
		(scrollView.documentView as? CodeTextView)?.onCopy = nil
	}

	/// Shows `text`, keeping selected the lines of the keys that were, as
	/// when values are revealed or refreshed.
	private func show(_ text: VaultRawText, in textView: CodeTextView, coordinator: Coordinator) {
		guard coordinator.shown != text else { return }
		let selectedKeys = Set(coordinator.shown?.lines(touchedBy: textView.selectedRanges.map(\.rangeValue)).map(\.key) ?? [])
		coordinator.shown = text
		textView.textStorage?.setAttributedString(Self.attributed(text))
		textView.textDidReplace()
		textView.setSelectedRanges(Self.ranges(of: text.lines.filter { selectedKeys.contains($0.key) }, in: text), affinity: .downstream,
			stillSelecting: false)
	}

	/// The whole lines given, joined where they're next to each other, or an empty selection at the start.
	private static func ranges(of lines: [VaultRawText.Line], in text: VaultRawText) -> [NSValue] {
		var ranges: [NSRange] = []
		let length = (text.string as NSString).length
		for line in lines {
			let end = min(NSMaxRange(line.range) + 1, length)
			if let last = ranges.last, NSMaxRange(last) == line.range.location {
				ranges[ranges.count - 1].length = end - last.location
			} else {
				ranges.append(NSRange(location: line.range.location, length: end - line.range.location))
			}
		}
		return (ranges.isEmpty ? [NSRange(location: 0, length: 0)] : ranges).map { NSValue(range: $0) }
	}

	static func attributed(_ text: VaultRawText) -> NSAttributedString {
		let result = NSMutableAttributedString(string: text.string, attributes: VaultCodeTextView.baseAttributes)
		let maskAttributes: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor(VaultPalette.masked), .kern: 1.0]
		for line in text.lines {
			let keyLength = line.key.utf16.count
			result.addAttributes(VaultCodeTextView.keyAttributes, range: NSRange(location: line.range.location, length: keyLength))
			result.addAttributes(VaultCodeTextView.equalsAttributes, range: NSRange(location: line.range.location + keyLength, length: 1))
			if !line.isShown {
				result.addAttributes(maskAttributes,
					range: NSRange(location: line.range.location + keyLength + 1, length: line.range.length - keyLength - 1))
			}
		}
		return result
	}

	@MainActor
	final class Coordinator: NSObject, NSTextViewDelegate {
		var parent: VaultRawTextView
		var shown: VaultRawText?

		init(_ parent: VaultRawTextView) { self.parent = parent }

		func copy(_ ranges: [NSRange]) {
			guard let shown else { return }
			let keys = shown.lines(touchedBy: ranges).map(\.key)
			if !keys.isEmpty { parent.onCopy(keys) }
		}

		func textViewDidChangeSelection(_ notification: Notification) {
			guard let textView = notification.object as? NSTextView, let shown else { return }
			let count = shown.lines(touchedBy: textView.selectedRanges.map(\.rangeValue)).count
			guard count != parent.selectedLineCount else { return }
			// A selection can change while SwiftUI updates the view, when it can't take new state.
			let selectedLineCount = parent.$selectedLineCount
			DispatchQueue.main.async { selectedLineCount.wrappedValue = count }
		}
	}

	/// Read-only code whose selection takes whole lines.
	final class CodeTextView: VaultCodeTextView {
		override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
			let text = string as NSString
			let lines = ranges.map { value in
				let range = value.rangeValue
				return range.length > 0 && NSMaxRange(range) <= text.length ? NSValue(range: text.lineRange(for: range)) : value
			}
			super.setSelectedRanges(lines, affinity: affinity, stillSelecting: stillSelecting)
		}
	}
}

/// Raw text's editor: an environment's lines with real values, numbered,
/// each line that can't be saved tinted with why at its end. What's copied
/// or cut goes through `onCopy`, as every copy of a value does.
struct VaultRawTextEditor: NSViewRepresentable {
	let text: String
	let problems: [VaultEnvTextCheck.Problem]
	let problemLines: Set<Int>
	/// The lines whose values hold characters that are hard to see, which never stop a save.
	var warnings: [VaultEnvTextCheck.Problem] = []
	let label: String
	var isEditable = true
	let onChange: (String) -> Void
	let onCopy: (String) -> Void

	func makeCoordinator() -> Coordinator { Coordinator(self) }

	func makeNSView(context: Context) -> NSScrollView {
		let textView = EditorTextView(usingTextLayoutManager: false)
		textView.configureAsCode(label: label)
		textView.isEditable = true
		textView.allowsUndo = true
		textView.isAutomaticQuoteSubstitutionEnabled = false
		textView.isAutomaticDashSubstitutionEnabled = false
		textView.isAutomaticTextReplacementEnabled = false
		textView.isAutomaticSpellingCorrectionEnabled = false
		textView.isContinuousSpellCheckingEnabled = false
		textView.isGrammarCheckingEnabled = false
		textView.isAutomaticTextCompletionEnabled = false
		textView.smartInsertDeleteEnabled = false
		textView.inlinePredictionType = .no
		textView.insertionPointColor = NSColor(VaultPalette.accent)
		textView.typingAttributes = VaultCodeTextView.baseAttributes
		textView.delegate = context.coordinator
		textView.textStorage?.delegate = context.coordinator
		let coordinator = context.coordinator
		textView.onCopy = { [weak coordinator, weak textView] ranges in
			guard let textView else { return }
			let text = textView.string as NSString
			coordinator?.parent.onCopy(ranges.filter { $0.length > 0 }.map { text.substring(with: $0) }.joined(separator: "\n"))
		}
		let scrollView = VaultCodeTextView.scrollView(for: textView)
		textView.string = text
		coordinator.shownText = text
		textView.textDidReplace()
		textView.problems = problems
		textView.problemLines = problemLines
		textView.warnings = warnings
		(scrollView.verticalRulerView as? VaultLineNumberGutter)?.problemLines = problemLines
		// Starts at the empty line after the last key, ready to add one.
		textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
		DispatchQueue.main.async { [weak textView] in textView?.window?.makeFirstResponder(textView) }
		return scrollView
	}

	func updateNSView(_ scrollView: NSScrollView, context: Context) {
		let coordinator = context.coordinator
		coordinator.parent = self
		guard let textView = scrollView.documentView as? EditorTextView else { return }
		textView.setAccessibilityLabel(label)
		textView.isEditable = isEditable
		if ExactText(text) != ExactText(coordinator.shownText) {
			textView.string = text
			coordinator.shownText = text
			textView.undoManager?.removeAllActions()
			textView.textDidReplace()
		}
		if textView.problems != problems { textView.problems = problems }
		if textView.problemLines != problemLines { textView.problemLines = problemLines }
		if textView.warnings != warnings { textView.warnings = warnings }
		if let gutter = scrollView.verticalRulerView as? VaultLineNumberGutter, gutter.problemLines != problemLines {
			gutter.problemLines = problemLines
		}
	}

	static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
		coordinator.undoManager.removeAllActions()
		(scrollView.documentView as? EditorTextView)?.onCopy = nil
	}

	@MainActor
	final class Coordinator: NSObject, NSTextViewDelegate, @preconcurrency NSTextStorageDelegate {
		var parent: VaultRawTextEditor
		var shownText = ""
		/// The editor's own, so nothing typed outlives it in the window's history.
		let undoManager = UndoManager()

		init(_ parent: VaultRawTextEditor) { self.parent = parent }

		func undoManager(for view: NSTextView) -> UndoManager? { undoManager }

		func textDidChange(_ notification: Notification) {
			guard let textView = notification.object as? NSTextView else { return }
			shownText = textView.string
			parent.onChange(shownText)
		}

		func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
			range editedRange: NSRange, changeInLength delta: Int)
		{
			guard editedMask.contains(.editedCharacters) else { return }
			VaultCodeTextView.color(textStorage, in: editedRange)
		}
	}

	/// Editable code that takes only plain text, from the pasteboard or a drag,
	/// and marks the lines that can't be saved.
	final class EditorTextView: VaultCodeTextView {
		var problems: [VaultEnvTextCheck.Problem] = [] {
			didSet { needsDisplay = true }
		}
		/// The lines to tint: each problem's, and the line a duplicate repeats.
		var problemLines: Set<Int> = [] {
			didSet { needsDisplay = true }
		}
		/// Lines whose values hold characters that are hard to see, tinted
		/// apart from problems, which they never are.
		var warnings: [VaultEnvTextCheck.Problem] = [] {
			didSet { needsDisplay = true }
		}

		override var readablePasteboardTypes: [NSPasteboard.PasteboardType] { [.string] }
		override var acceptableDragTypes: [NSPasteboard.PasteboardType] { [.string] }

		override func cut(_ sender: Any?) {
			guard isEditable, selectedRanges.contains(where: { $0.rangeValue.length > 0 }) else { return }
			copy(sender)
			delete(sender)
		}

		/// Line breaks from Windows or old Macs become this editor's own, which its lines are counted by.
		override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
			guard let string = pboard.string(forType: .string) else { return false }
			insertText(string.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n"),
				replacementRange: selectedRange())
			return true
		}

		override func drawBackground(in rect: NSRect) {
			super.drawBackground(in: rect)
			guard !problemLines.isEmpty || !warnings.isEmpty, let layoutManager else { return }
			let text = string as NSString
			let starts = lineStarts
			let tint = NSColor(VaultPalette.redTint)
			let attributes: [NSAttributedString.Key: Any] = [
				.font: NSFont.systemFont(ofSize: 11.5, weight: .medium),
				.foregroundColor: NSColor(VaultPalette.redText),
			]
			func row(of line: Int) -> NSRect? {
				guard line >= 1, line <= starts.count else { return nil }
				let start = starts[line - 1]
				var fragment = if start >= text.length {
					layoutManager.extraLineFragmentRect
				} else {
					layoutManager.lineFragmentRect(forGlyphAt: layoutManager.glyphIndexForCharacter(at: start), effectiveRange: nil)
				}
				guard !fragment.isEmpty else { return nil }
				fragment.origin.y += textContainerOrigin.y
				let row = NSRect(x: bounds.minX, y: fragment.minY, width: bounds.width, height: fragment.height)
				return row.intersects(rect) ? row : nil
			}
			// Only the lines on screen, however many lines have problems.
			guard let textContainer else { return }
			let inContainer = rect.offsetBy(dx: -textContainerOrigin.x, dy: -textContainerOrigin.y)
			let characters = layoutManager.characterRange(
				forGlyphRange: layoutManager.glyphRange(forBoundingRect: inContainer, in: textContainer), actualGlyphRange: nil)
			let shown = (VaultLineNumberGutter.line(containing: characters.location, starts: starts) + 1)...(
				VaultLineNumberGutter.line(containing: NSMaxRange(characters), starts: starts) + 1)
			let visible = visibleRect
			let warningTint = NSColor(VaultPalette.orangeTint)
			let warningAttributes: [NSAttributedString.Key: Any] = [
				.font: NSFont.systemFont(ofSize: 11.5, weight: .medium),
				.foregroundColor: NSColor(VaultPalette.orangeTintText),
			]
			for warning in warnings where shown.contains(warning.line) && !problemLines.contains(warning.line) {
				guard let row = row(of: warning.line) else { continue }
				warningTint.setFill()
				row.fill()
				let reason = warning.message as NSString
				let size = reason.size(withAttributes: warningAttributes)
				let pill = NSRect(x: visible.maxX - size.width - 20, y: row.minY, width: size.width + 20, height: row.height)
				pill.fill()
				reason.draw(at: NSPoint(x: pill.minX + 8, y: row.midY - size.height / 2), withAttributes: warningAttributes)
			}
			tint.setFill()
			for line in shown where problemLines.contains(line) {
				row(of: line)?.fill()
			}
			for problem in problems where shown.contains(problem.line) {
				guard let row = row(of: problem.line) else { continue }
				let reason = problem.message as NSString
				let size = reason.size(withAttributes: attributes)
				let pill = NSRect(x: visible.maxX - size.width - 20, y: row.minY, width: size.width + 20, height: row.height)
				tint.setFill()
				pill.fill()
				reason.draw(at: NSPoint(x: pill.minX + 8, y: row.midY - size.height / 2), withAttributes: attributes)
			}
		}

		override func viewDidMoveToWindow() {
			super.viewDidMoveToWindow()
			guard let clip = enclosingScrollView?.contentView else { return }
			clip.postsBoundsChangedNotifications = true
			NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: nil)
			NotificationCenter.default.addObserver(self, selector: #selector(clipScrolled), name: NSView.boundsDidChangeNotification, object: clip)
		}

		/// The reasons sit at the visible right edge, which moves as the text scrolls sideways.
		@objc private func clipScrolled() {
			if !problems.isEmpty || !warnings.isEmpty { needsDisplay = true }
		}
	}
}

/// Code text that nothing takes out but its owner, through `onCopy`: not a
/// drag, Services, Look Up or Writing Tools. Its lines don't wrap; a long
/// one scrolls sideways.
class VaultCodeTextView: NSTextView {
	static let lineHeight: CGFloat = 22
	static let gutterWidth: CGFloat = 40

	var onCopy: (([NSRange]) -> Void)?

	static var baseAttributes: [NSAttributedString.Key: Any] {
		let font = VaultTypography.codeNSFont(12.5)
		let paragraph = NSMutableParagraphStyle()
		paragraph.minimumLineHeight = lineHeight
		paragraph.maximumLineHeight = lineHeight
		return [
			.font: font,
			.foregroundColor: NSColor(VaultPalette.textPrimary),
			.paragraphStyle: paragraph,
			// TextKit puts a taller line's extra height above its text; raising
			// the baseline by half of it centers the text.
			.baselineOffset: (lineHeight - NSLayoutManager().defaultLineHeight(for: font)) / 2,
		]
	}

	static var keyAttributes: [NSAttributedString.Key: Any] {
		[.font: VaultTypography.codeNSFont(12.5, .semibold), .foregroundColor: NSColor(VaultPalette.accentText)]
	}

	static var equalsAttributes: [NSAttributedString.Key: Any] {
		[.foregroundColor: NSColor(VaultPalette.textTertiary)]
	}

	/// Colors the lines `range` touches as `KEY=value` lines: the key in the
	/// accent, or red when it isn't a valid name, `=` dimmed, comments dimmed.
	static func color(_ storage: NSTextStorage, in range: NSRange) {
		let text = storage.string as NSString
		let lines = text.lineRange(for: NSRange(location: min(range.location, text.length), length: 0)).location
		let end = NSMaxRange(text.lineRange(for: NSRange(location: min(NSMaxRange(range), text.length), length: 0)))
		let paragraphs = NSRange(location: lines, length: end - lines)
		storage.setAttributes(baseAttributes, range: paragraphs)
		text.enumerateSubstrings(in: paragraphs, options: [.byLines, .substringNotRequired]) { _, line, _, _ in
			let content = text.substring(with: line)
			let leading = content.prefix { $0 == " " || $0 == "\t" }.utf16.count
			let body = content.dropFirst(leading)
			if body.hasPrefix("#") {
				storage.addAttribute(.foregroundColor, value: NSColor(VaultPalette.textTertiary), range: line)
				return
			}
			let exportLength = body.hasPrefix("export ") ? "export ".utf16.count : 0
			guard let equals = body.firstIndex(of: "=") else { return }
			let keyStart = line.location + leading + exportLength
			let keyLength = body[..<equals].utf16.count - exportLength
			guard keyLength >= 0 else { return }
			let key = text.substring(with: NSRange(location: keyStart, length: keyLength)).trimmingDotenvBlanks()
			var attributes = keyAttributes
			if !EnvValidation.isValidVariableName(key) { attributes[.foregroundColor] = NSColor(VaultPalette.redText) }
			storage.addAttributes(attributes, range: NSRange(location: keyStart, length: keyLength))
			storage.addAttributes(equalsAttributes, range: NSRange(location: keyStart + keyLength, length: 1))
		}
	}

	/// A scroll view showing `textView`, with its line numbers in a gutter.
	static func scrollView(for textView: VaultCodeTextView) -> NSScrollView {
		let scrollView = NSScrollView()
		scrollView.drawsBackground = false
		scrollView.borderType = .noBorder
		scrollView.hasVerticalScroller = true
		scrollView.hasHorizontalScroller = true
		scrollView.autohidesScrollers = true
		scrollView.documentView = textView
		scrollView.verticalRulerView = VaultLineNumberGutter(scrollView: scrollView, textView: textView)
		scrollView.hasVerticalRuler = true
		scrollView.rulersVisible = true
		return scrollView
	}

	func configureAsCode(label: String) {
		// TextKit 1's line fragments are what the gutter numbers.
		isSelectable = true
		isRichText = false
		importsGraphics = false
		usesFontPanel = false
		usesRuler = false
		isAutomaticLinkDetectionEnabled = false
		isAutomaticDataDetectionEnabled = false
		if #available(macOS 15.0, *) { writingToolsBehavior = .none }
		drawsBackground = false
		textContainerInset = NSSize(width: 0, height: 10)
		textContainer?.lineFragmentPadding = 0
		selectedTextAttributes = [.backgroundColor: NSColor(VaultPalette.accent).withAlphaComponent(0.22)]
		isVerticallyResizable = true
		isHorizontallyResizable = true
		autoresizingMask = [.width, .height]
		minSize = .zero
		maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
		textContainer?.widthTracksTextView = false
		textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
		setAccessibilityLabel(label)
	}

	private var cachedLineStarts: [Int]?

	/// Where each line begins, an empty last line's included, counted once for
	/// each change of the text rather than on every draw, which scrolling asks for many times.
	var lineStarts: [Int] {
		if let cachedLineStarts { return cachedLineStarts }
		let text = string as NSString
		var starts = [0]
		var index = 0
		while index < text.length {
			let found = text.range(of: "\n", options: .literal, range: NSRange(location: index, length: text.length - index))
			guard found.location != NSNotFound else { break }
			starts.append(NSMaxRange(found))
			index = NSMaxRange(found)
		}
		cachedLineStarts = starts
		return starts
	}

	/// Counts lines again, after the text was set rather than typed.
	func textDidReplace() {
		cachedLineStarts = nil
		enclosingScrollView?.verticalRulerView?.needsDisplay = true
		needsDisplay = true
	}

	override func didChangeText() {
		cachedLineStarts = nil
		super.didChangeText()
		enclosingScrollView?.verticalRulerView?.needsDisplay = true
	}

	override func copy(_ sender: Any?) {
		onCopy?(selectedRanges.map(\.rangeValue))
	}

	override func menu(for event: NSEvent) -> NSMenu? {
		let menu = NSMenu()
		var items: [(String, Selector, String)] = [("Copy", #selector(copy(_:)), "c")]
		if isEditable { items = [("Cut", #selector(cut(_:)), "x")] + items + [("Paste", #selector(paste(_:)), "v")] }
		for (title, action, key) in items + [("Select All", #selector(selectAll(_:)), "a")] {
			menu.addItem(withTitle: title, action: action, keyEquivalent: key).target = self
		}
		return menu
	}

	override func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool { false }

	override func dragSelection(with event: NSEvent, offset mouseOffset: NSSize, slideBack: Bool) -> Bool { false }

	override func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?,
		returnType: NSPasteboard.PasteboardType?) -> Any? { nil }

	override func quickLook(with event: NSEvent) {}
}

/// The line numbers beside code, which aren't part of it, so no selection
/// takes them. A line that can't be saved has its number in red.
final class VaultLineNumberGutter: NSRulerView {
	private static let numberFont = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .regular)

	var problemLines: Set<Int> = [] {
		didSet { needsDisplay = true }
	}

	init(scrollView: NSScrollView, textView: VaultCodeTextView) {
		super.init(scrollView: scrollView, orientation: .verticalRuler)
		clientView = textView
		ruleThickness = VaultCodeTextView.gutterWidth
	}

	@available(*, unavailable)
	required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

	override var isOpaque: Bool { false }

	override func draw(_ dirtyRect: NSRect) {
		drawHashMarksAndLabels(in: dirtyRect)
	}

	override func drawHashMarksAndLabels(in rect: NSRect) {
		guard let textView = clientView as? VaultCodeTextView, let layoutManager = textView.layoutManager,
			let container = textView.textContainer
		else { return }
		let text = textView.string as NSString
		let starts = textView.lineStarts
		let origin = textView.textContainerOrigin
		let glyphs = layoutManager.glyphRange(forBoundingRect: convert(rect, to: textView).offsetBy(dx: -origin.x, dy: -origin.y), in: container)
		let characters = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
		let color = NSColor(VaultPalette.textTertiary).usingColorSpace(.sRGB)?.withAlphaComponent(0.6) ?? .tertiaryLabelColor
		let problemColor = NSColor(VaultPalette.redText)
		var line = Self.line(containing: characters.location, starts: starts)
		while line < starts.count, starts[line] <= NSMaxRange(characters) {
			let fragment = if starts[line] >= text.length {
				layoutManager.extraLineFragmentRect
			} else {
				layoutManager.lineFragmentRect(forGlyphAt: layoutManager.glyphIndexForCharacter(at: starts[line]), effectiveRange: nil)
			}
			line += 1
			guard !fragment.isEmpty else { continue }
			let attributes: [NSAttributedString.Key: Any] = [
				.font: Self.numberFont,
				.foregroundColor: problemLines.contains(line) ? problemColor : color,
			]
			let label = "\(line)" as NSString
			let size = label.size(withAttributes: attributes)
			let top = convert(NSPoint(x: 0, y: fragment.minY + origin.y), from: textView).y
			label.draw(at: NSPoint(x: ruleThickness - 12 - size.width, y: top + (fragment.height - size.height) / 2), withAttributes: attributes)
		}
	}

	/// The index of the last line starting at or before `location`.
	static func line(containing location: Int, starts: [Int]) -> Int {
		var low = 0
		var high = starts.count
		while low < high {
			let middle = (low + high) / 2
			if starts[middle] <= location { low = middle + 1 } else { high = middle }
		}
		return max(0, low - 1)
	}
}
