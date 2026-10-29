import AppKit
import SwiftUI

/// The field an env value is typed or pasted in, which hands every edit to
/// `text` byte for byte. SwiftUI's TextField and SecureField compare the
/// field with their binding by canonical equivalence, so an edit to an
/// equivalent value, such as U+2000 replaced by U+2002 or é by e and U+0301,
/// never reached the binding and the old characters were saved. Automatic
/// substitutions, such as smart quotes, are off, since they change a value too.
struct VaultValueField: NSViewRepresentable {
	@Binding var text: String
	/// Whether the field is being edited. Setting it starts editing; the field
	/// sets it as editing starts and ends.
	@Binding var isFocused: Bool
	let label: String
	let placeholder: String
	let isSecure: Bool
	let font: NSFont
	/// Lines a value wraps to before it scrolls; 1 keeps it on one line.
	var maxLines = 1
	var isEnabled = true
	/// Whether edits can be undone. A search term mustn't stay behind in the
	/// window's undo history.
	var recordsUndo = true
	/// Return with the modifiers held, among Shift, Control, Option and Command;
	/// true when it handled the press, which otherwise submits.
	var onReturn: (NSEvent.ModifierFlags) -> Bool = { _ in false }
	var onSubmit: () -> Void = {}

	func makeCoordinator() -> Coordinator { Coordinator(self) }

	func makeNSView(context: Context) -> NSTextField {
		let field: NSTextField & ValueFieldFocus = isSecure ? SecureValueTextField() : PlainValueTextField()
		field.isBordered = false
		field.isBezeled = false
		field.drawsBackground = false
		field.focusRingType = .none
		field.textColor = NSColor(VaultPalette.textPrimary)
		field.isAutomaticTextCompletionEnabled = false
		field.allowsCharacterPickerTouchBarItem = false
		// Keeps macOS from offering saved passwords in a field that holds a secret
		// value. A one-time-code field is the only secure field it doesn't offer
		// them in; for a few minutes after a verification code arrives in Messages
		// or Mail, it offers that code instead.
		if isSecure { field.contentType = .oneTimeCode }
		// Single-line mode drops the line breaks of a pasted value, such as a
		// private key's, so a field kept on one line scrolls instead.
		field.usesSingleLineMode = false
		if maxLines > 1 {
			field.cell?.wraps = true
			field.cell?.isScrollable = false
			field.lineBreakMode = .byCharWrapping
		} else {
			field.cell?.wraps = false
			field.cell?.isScrollable = true
		}
		field.setContentHuggingPriority(.defaultLow, for: .horizontal)
		field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
		field.stringValue = text
		field.recordsUndo = recordsUndo
		field.delegate = context.coordinator
		field.onFocusChange = { [weak coordinator = context.coordinator] focused in coordinator?.focusChanged(focused) }
		apply(to: field)
		return field
	}

	func updateNSView(_ field: NSTextField, context: Context) {
		context.coordinator.parent = self
		if ExactText(field.stringValue) != ExactText(text) { field.stringValue = text }
		apply(to: field)
		if isFocused, !context.coordinator.isEditing {
			DispatchQueue.main.async { [weak field] in
				guard let field, let window = field.window, field.currentEditor() == nil || window.firstResponder !== field.currentEditor() else { return }
				window.makeFirstResponder(field)
			}
		}
	}

	static func dismantleNSView(_ field: NSTextField, coordinator: Coordinator) {
		(field as? ValueFieldFocus)?.onFocusChange = nil
	}

	func sizeThatFits(_ proposal: ProposedViewSize, nsView field: NSTextField, context: Context) -> CGSize? {
		let width = proposal.width.map { $0.isFinite ? $0 : 200 } ?? 200
		let lineHeight = ceil(font.ascender - font.descender + font.leading)
		guard maxLines > 1 else { return CGSize(width: width, height: lineHeight) }
		let used = NSAttributedString(string: text.isEmpty ? " " : text, attributes: [.font: font])
			.boundingRect(with: NSSize(width: max(width - 4, 1), height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading])
		let lines = min(max(Int((ceil(used.height) / lineHeight).rounded(.up)), 1), maxLines)
		return CGSize(width: width, height: CGFloat(lines) * lineHeight)
	}

	private func apply(to field: NSTextField) {
		if field.font != font { field.font = font }
		if field.placeholderString != placeholder { field.placeholderString = placeholder }
		if field.accessibilityLabel() != label { field.setAccessibilityLabel(label) }
		if field.isEnabled != isEnabled { field.isEnabled = isEnabled }
		if maxLines > 1, field.maximumNumberOfLines != maxLines { field.maximumNumberOfLines = maxLines }
	}

	@MainActor
	final class Coordinator: NSObject, NSTextFieldDelegate {
		var parent: VaultValueField
		private(set) var isEditing = false

		init(_ parent: VaultValueField) { self.parent = parent }

		func controlTextDidChange(_ notification: Notification) {
			guard let field = notification.object as? NSTextField else { return }
			let typed = field.stringValue
			if ExactText(typed) != ExactText(parent.text) { parent.text = typed }
		}

		func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
			guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
			let modifiers = (NSApp.currentEvent?.modifierFlags ?? []).intersection([.shift, .control, .option, .command])
			if !parent.onReturn(modifiers) { parent.onSubmit() }
			return true
		}

		/// Reported after the update that caused it, since SwiftUI's state can't change during one.
		func focusChanged(_ focused: Bool) {
			isEditing = focused
			DispatchQueue.main.async { [weak self] in
				guard let self, self.isEditing == focused, self.parent.isFocused != focused else { return }
				self.parent.isFocused = focused
			}
		}
	}
}

/// Says when a value field starts and stops being edited, and turns off the
/// field editor's substitutions as editing starts, since the window shares
/// one field editor among its fields.
@MainActor
protocol ValueFieldFocus: AnyObject {
	var onFocusChange: ((Bool) -> Void)? { get set }
	var recordsUndo: Bool { get set }
}

extension ValueFieldFocus where Self: NSTextField {
	func editingBegan() {
		if let editor = currentEditor() as? NSTextView {
			editor.allowsUndo = recordsUndo
			editor.isAutomaticQuoteSubstitutionEnabled = false
			editor.isAutomaticDashSubstitutionEnabled = false
			editor.isAutomaticTextReplacementEnabled = false
			editor.isAutomaticSpellingCorrectionEnabled = false
			editor.isContinuousSpellCheckingEnabled = false
			editor.isGrammarCheckingEnabled = false
			editor.isAutomaticLinkDetectionEnabled = false
			editor.isAutomaticDataDetectionEnabled = false
			editor.isAutomaticTextCompletionEnabled = false
			editor.smartInsertDeleteEnabled = false
			editor.inlinePredictionType = .no
			if #available(macOS 15.0, *) { editor.writingToolsBehavior = .none }
		}
		onFocusChange?(true)
	}
}

private final class PlainValueTextField: NSTextField, ValueFieldFocus {
	var onFocusChange: ((Bool) -> Void)?
	var recordsUndo = true

	override func becomeFirstResponder() -> Bool {
		let became = super.becomeFirstResponder()
		if became { editingBegan() }
		return became
	}

	override func textDidEndEditing(_ notification: Notification) {
		if !recordsUndo { (notification.object as? NSTextView)?.allowsUndo = true }
		super.textDidEndEditing(notification)
		onFocusChange?(false)
	}
}

private final class SecureValueTextField: NSSecureTextField, ValueFieldFocus {
	var onFocusChange: ((Bool) -> Void)?
	var recordsUndo = true

	override func becomeFirstResponder() -> Bool {
		let became = super.becomeFirstResponder()
		if became { editingBegan() }
		return became
	}

	override func textDidEndEditing(_ notification: Notification) {
		if !recordsUndo { (notification.object as? NSTextView)?.allowsUndo = true }
		super.textDidEndEditing(notification)
		onFocusChange?(false)
	}
}
