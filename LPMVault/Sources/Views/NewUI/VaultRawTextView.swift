import AppKit
import SwiftUI

/// Raw text's code view: an environment as read-only text, with a line
/// number beside each line. A selection takes whole lines, and copying hands
/// `onCopy` the keys of the lines selected, so what's copied holds the real
/// values even of lines shown masked. Nothing else takes the text out: not a
/// drag, Services, Look Up or Writing Tools.
struct VaultRawTextView: NSViewRepresentable {
	let text: VaultRawText
	let label: String
	@Binding var selectedLineCount: Int
	let onCopy: ([String]) -> Void

	static let lineHeight: CGFloat = 22
	static let gutterWidth: CGFloat = 40

	func makeCoordinator() -> Coordinator { Coordinator(self) }

	func makeNSView(context: Context) -> NSScrollView {
		// TextKit 1, whose line fragments the gutter numbers.
		let textView = CodeTextView(usingTextLayoutManager: false)
		textView.isEditable = false
		textView.isSelectable = true
		textView.isRichText = false
		textView.importsGraphics = false
		textView.usesFontPanel = false
		textView.usesRuler = false
		textView.isAutomaticLinkDetectionEnabled = false
		textView.isAutomaticDataDetectionEnabled = false
		if #available(macOS 15.0, *) { textView.writingToolsBehavior = .none }
		textView.drawsBackground = false
		textView.textContainerInset = NSSize(width: 0, height: 10)
		textView.textContainer?.lineFragmentPadding = 0
		textView.selectedTextAttributes = [.backgroundColor: NSColor(VaultPalette.accent).withAlphaComponent(0.22)]
		// Lines don't wrap; a long one scrolls sideways, as in a code editor.
		textView.isVerticallyResizable = true
		textView.isHorizontallyResizable = true
		textView.autoresizingMask = [.width, .height]
		textView.minSize = .zero
		textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
		textView.textContainer?.widthTracksTextView = false
		textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
		textView.setAccessibilityLabel(label)
		textView.delegate = context.coordinator
		let coordinator = context.coordinator
		textView.onCopy = { [weak coordinator] ranges in coordinator?.copy(ranges) }

		let scrollView = NSScrollView()
		scrollView.drawsBackground = false
		scrollView.borderType = .noBorder
		scrollView.hasVerticalScroller = true
		scrollView.hasHorizontalScroller = true
		scrollView.autohidesScrollers = true
		scrollView.documentView = textView
		scrollView.verticalRulerView = LineNumberGutter(scrollView: scrollView, textView: textView)
		scrollView.hasVerticalRuler = true
		scrollView.rulersVisible = true
		show(text, in: textView, scrollView: scrollView, coordinator: coordinator)
		return scrollView
	}

	func updateNSView(_ scrollView: NSScrollView, context: Context) {
		context.coordinator.parent = self
		guard let textView = scrollView.documentView as? CodeTextView else { return }
		textView.setAccessibilityLabel(label)
		show(text, in: textView, scrollView: scrollView, coordinator: context.coordinator)
	}

	static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
		(scrollView.documentView as? CodeTextView)?.onCopy = nil
	}

	/// Shows `text`, keeping selected the lines of the keys that were, as
	/// when values are revealed or refreshed.
	private func show(_ text: VaultRawText, in textView: CodeTextView, scrollView: NSScrollView, coordinator: Coordinator) {
		guard coordinator.shown != text else { return }
		let selectedKeys = Set(coordinator.shown?.lines(touchedBy: textView.selectedRanges.map(\.rangeValue)).map(\.key) ?? [])
		coordinator.shown = text
		textView.textStorage?.setAttributedString(Self.attributed(text))
		(scrollView.verticalRulerView as? LineNumberGutter)?.invalidateLineNumbers()
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
		let font = VaultTypography.codeNSFont(12.5)
		let paragraph = NSMutableParagraphStyle()
		paragraph.minimumLineHeight = lineHeight
		paragraph.maximumLineHeight = lineHeight
		let result = NSMutableAttributedString(string: text.string, attributes: [
			.font: font,
			.foregroundColor: NSColor(VaultPalette.textPrimary),
			.paragraphStyle: paragraph,
			// TextKit puts a taller line's extra height above its text; raising
			// the baseline by half of it centers the text.
			.baselineOffset: (lineHeight - NSLayoutManager().defaultLineHeight(for: font)) / 2,
		])
		let keyAttributes: [NSAttributedString.Key: Any] = [
			.font: VaultTypography.codeNSFont(12.5, .semibold),
			.foregroundColor: NSColor(VaultPalette.accentText),
		]
		let maskAttributes: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor(VaultPalette.masked), .kern: 1.0]
		for line in text.lines {
			let keyLength = line.key.utf16.count
			result.addAttributes(keyAttributes, range: NSRange(location: line.range.location, length: keyLength))
			result.addAttribute(.foregroundColor, value: NSColor(VaultPalette.textTertiary),
				range: NSRange(location: line.range.location + keyLength, length: 1))
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

	/// Read-only text whose selection takes whole lines, and which leaves
	/// copying to its owner.
	final class CodeTextView: NSTextView {
		var onCopy: (([NSRange]) -> Void)?

		override func copy(_ sender: Any?) {
			onCopy?(selectedRanges.map(\.rangeValue))
		}

		override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
			let text = string as NSString
			let lines = ranges.map { value in
				let range = value.rangeValue
				return range.length > 0 && NSMaxRange(range) <= text.length ? NSValue(range: text.lineRange(for: range)) : value
			}
			super.setSelectedRanges(lines, affinity: affinity, stillSelecting: stillSelecting)
		}

		override func menu(for event: NSEvent) -> NSMenu? {
			let menu = NSMenu()
			for (title, action, key) in [("Copy", #selector(copy(_:)), "c"), ("Select All", #selector(selectAll(_:)), "a")] {
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

	/// The line numbers beside the text, which aren't part of it, so no selection takes them.
	final class LineNumberGutter: NSRulerView {
		init(scrollView: NSScrollView, textView: NSTextView) {
			super.init(scrollView: scrollView, orientation: .verticalRuler)
			clientView = textView
			ruleThickness = VaultRawTextView.gutterWidth
		}

		@available(*, unavailable)
		required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

		private static let numberFont = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .regular)

		override var isOpaque: Bool { false }

		override func draw(_ dirtyRect: NSRect) {
			drawHashMarksAndLabels(in: dirtyRect)
		}

		override func drawHashMarksAndLabels(in rect: NSRect) {
			guard let textView = clientView as? NSTextView, let layoutManager = textView.layoutManager,
				let container = textView.textContainer
			else { return }
			let text = textView.string as NSString
			guard text.length > 0 else { return }
			let visible = convert(rect, to: textView)
			let glyphs = layoutManager.glyphRange(forBoundingRect: visible, in: container)
			let characters = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
			let attributes: [NSAttributedString.Key: Any] = [
				.font: Self.numberFont,
				.foregroundColor: NSColor(VaultPalette.textTertiary).usingColorSpace(.sRGB)?.withAlphaComponent(0.6) ?? .tertiaryLabelColor,
			]
			let starts = lineStarts(of: text)
			let origin = textView.textContainerOrigin
			var line = Self.line(containing: characters.location, starts: starts)
			while line < starts.count, starts[line] <= NSMaxRange(characters) {
				let glyph = layoutManager.glyphIndexForCharacter(at: starts[line])
				let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
				let baseline = convert(NSPoint(x: 0, y: fragment.minY + origin.y + layoutManager.location(forGlyphAt: glyph).y), from: textView).y
				let label = "\(line + 1)" as NSString
				let width = label.size(withAttributes: attributes).width
				label.draw(at: NSPoint(x: ruleThickness - 12 - width, y: baseline - Self.numberFont.ascender), withAttributes: attributes)
				line += 1
			}
		}

		private var cachedLineStarts: [Int]?

		/// Numbers the lines again from the text, once it's changed.
		func invalidateLineNumbers() {
			cachedLineStarts = nil
			needsDisplay = true
		}

		/// Where each line begins, counted once for each change of the text
		/// rather than on every draw, which scrolling asks for many times.
		private func lineStarts(of text: NSString) -> [Int] {
			if let cachedLineStarts { return cachedLineStarts }
			var starts = [0]
			var index = 0
			while index < text.length {
				let found = text.range(of: "\n", options: .literal, range: NSRange(location: index, length: text.length - index))
				guard found.location != NSNotFound, NSMaxRange(found) < text.length else { break }
				starts.append(NSMaxRange(found))
				index = NSMaxRange(found)
			}
			cachedLineStarts = starts
			return starts
		}

		/// The index of the last line starting at or before `location`.
		private static func line(containing location: Int, starts: [Int]) -> Int {
			var low = 0
			var high = starts.count
			while low < high {
				let middle = (low + high) / 2
				if starts[middle] <= location { low = middle + 1 } else { high = middle }
			}
			return max(0, low - 1)
		}
	}
}
