import AppKit
import SwiftUI

/// What an import reads: a file, chosen or dropped, or pasted text, each read
/// as it's given. Only the shown mode's input is imported, and only once its
/// latest version is read without a problem, so a failed or unfinished read
/// never imports earlier values.
struct EnvImportSourceState {
	enum Mode: String, CaseIterable, Identifiable {
		case file = "From file"
		case text = "Paste text"

		var id: Self { self }
	}

	var mode: Mode = .file
	private(set) var file: URL?
	private(set) var fileRevision = 0
	private var fileRead: Result<ImportedEnvFile, EnvFileImportError>?
	/// Why the last drop was turned down; the chosen file stays as it was.
	private(set) var dropProblem: String?
	private(set) var text = ""
	private(set) var textRevision = 0
	private(set) var textIsBlank = true
	private var textRead: (revision: Int, result: Result<ImportedEnvFile, EnvFileImportError>)?

	init(file: URL? = nil) {
		if let file { choose(file) }
	}

	mutating func choose(_ url: URL) {
		mode = .file
		file = url
		fileRevision &+= 1
		fileRead = nil
		dropProblem = nil
	}

	/// Chooses the one file `urls` holds, as a drop gives them, or says why it can't.
	@discardableResult
	mutating func drop(_ urls: [URL]) -> Bool {
		switch EnvImportDrop.file(in: urls) {
		case .success(let url):
			choose(url)
			return true
		case .failure(let problem):
			mode = .file
			dropProblem = problem.message
			return false
		}
	}

	mutating func setText(_ newText: String) {
		text = newText
		textRevision &+= 1
		textIsBlank = newText.allSatisfy(\.isWhitespace)
	}

	mutating func finishReading(_ url: URL, revision: Int, _ result: Result<ImportedEnvFile, EnvFileImportError>) {
		guard revision == fileRevision, url == file else { return }
		if case .failure(.cancelled) = result { return }
		fileRead = result
	}

	mutating func finishReadingText(revision: Int, _ result: Result<ImportedEnvFile, EnvFileImportError>) {
		guard revision == textRevision else { return }
		if case .failure(.cancelled) = result { return }
		textRead = (revision, result)
	}

	/// Whether the shown mode holds nothing to import: no file, or blank text.
	var isEmpty: Bool { mode == .file ? file == nil : textIsBlank }

	/// The shown mode's read of its latest input; nil while that's read.
	var current: Result<ImportedEnvFile, EnvFileImportError>? {
		switch mode {
		case .file: file == nil ? nil : fileRead
		case .text: textIsBlank || textRead?.revision != textRevision ? nil : textRead?.result
		}
	}

	/// The read to show: pasted text keeps showing its last read while newer
	/// text is read, so the count doesn't flicker as it's typed.
	var shownRead: Result<ImportedEnvFile, EnvFileImportError>? {
		switch mode {
		case .file: current
		case .text: textIsBlank ? nil : textRead?.result
		}
	}

	var isReading: Bool { !isEmpty && current == nil }

	var imported: ImportedEnvFile? {
		guard case .success(let imported) = current else { return nil }
		return imported
	}

	var source: EnvImportSource? {
		guard !isEmpty else { return nil }
		return switch mode {
		case .file: file.map(EnvImportSource.file)
		case .text: .pastedText
		}
	}

	/// What's wrong with the shown input, said as the import sheet says it.
	var problem: String? {
		if mode == .file, let dropProblem { return dropProblem }
		guard case .failure(let failure) = shownRead else { return nil }
		return failure.description(for: mode == .file ? (file.map(EnvImportSource.file) ?? .pastedText) : .pastedText)
	}
}

/// The one file a drop onto an import has to hold.
enum EnvImportDrop {
	enum Problem: Error, Equatable {
		case several
		case notAFile
		case folder

		var message: String {
			switch self {
			case .several: "Drop one file at a time."
			case .notAFile: "Drop a file from Finder."
			case .folder: "Drop a file, not a folder."
			}
		}
	}

	static func file(in urls: [URL]) -> Result<URL, Problem> {
		guard let url = urls.first else { return .failure(.notAFile) }
		guard urls.count == 1 else { return .failure(.several) }
		guard url.isFileURL else { return .failure(.notAFile) }
		if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true { return .failure(.folder) }
		return .success(url)
	}
}

extension ImportedEnvFile {
	var countDescription: String { "\(count) \(count == 1 ? "variable" : "variables")" }

	/// Which lines the import leaves out, or nil when it leaves none out.
	var skippedLinesDescription: String? {
		guard skippedLineCount > 0, let first = firstSkippedLine else { return nil }
		return skippedLineCount == 1
			? "Line \(first) isn't KEY=value, so it's left out."
			: "\(skippedLineCount) lines aren't KEY=value, so they're left out, starting at line \(first)."
	}
}

/// Where an import's variables come from: a file, dropped or chosen, or
/// pasted text. Reads each as it's given, through the store, so a lock or
/// another project cancels the read.
struct EnvImportSourcePicker: View {
	@Bindable var store: VaultStore
	let projectID: String
	@Binding var state: EnvImportSourceState
	var disabled = false

	@State private var isDropTargeted = false
	@State private var editorFocused = false

	var body: some View {
		VStack(alignment: .leading, spacing: 12) {
			EnvImportModeControl(selection: $state.mode)
			switch state.mode {
			case .file: dropZone
			case .text: pasteBox
			}
			if let problem = state.problem {
				note(problem, color: VaultPalette.redText)
			} else if let skipped = (try? state.shownRead?.get())?.skippedLinesDescription {
				note(skipped, color: VaultPalette.orangeTintText)
			}
		}
		.disabled(disabled)
		.dropDestination(for: URL.self) { urls, _ in
			guard !disabled else { return false }
			store.recordUserActivity()
			return state.drop(urls)
		} isTargeted: { isDropTargeted = $0 }
		.task(id: state.fileRevision) {
			guard let url = state.file else { return }
			let revision = state.fileRevision
			let result = await store.loadEnvImport(.file(url), for: projectID)
			state.finishReading(url, revision: revision, result)
		}
		.task(id: state.textRevision) {
			guard !state.textIsBlank else { return }
			let revision = state.textRevision
			let result = await store.loadEnvImport(.text(state.text), for: projectID)
			state.finishReadingText(revision: revision, result)
		}
	}

	private var dropZone: some View {
		let highlighted = isDropTargeted || state.file != nil
		return HStack(spacing: 14) {
			Image(systemName: state.file == nil ? "arrow.down.doc" : "doc.text")
				.font(.system(size: 17))
				.foregroundStyle(highlighted ? VaultPalette.accentForeground : VaultPalette.textTertiary)
				.frame(width: 40, height: 40)
				.background(RoundedRectangle(cornerRadius: 10).fill(VaultPalette.neutralTint))
				.accessibilityHidden(true)
			VStack(alignment: .leading, spacing: 3) {
				if let file = state.file {
					Text(file.lastPathComponent)
						.font(VaultTypography.tabular(13, .semibold))
						.foregroundStyle(VaultPalette.textPrimary)
						.lineLimit(1)
						.truncationMode(.middle)
					HStack(spacing: 0) {
						if let read = fileRead {
							Text(read + " · ").layoutPriority(1)
						}
						// The folder gives way first, from its start, keeping its last folders.
						Text((file.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)
							.truncationMode(.head)
					}
					.font(.system(size: 11.5))
					.foregroundStyle(VaultPalette.textTertiary)
					.lineLimit(1)
				} else {
					Text("Drop an .env file here")
						.font(.system(size: 13, weight: .semibold))
						.foregroundStyle(VaultPalette.textPrimary)
					Text("or choose one from a folder")
						.font(.system(size: 11.5))
						.foregroundStyle(VaultPalette.textTertiary)
				}
			}
			Spacer(minLength: 8)
			Button(state.file == nil ? "Choose File…" : "Change", action: chooseFile)
				.buttonStyle(.plain)
				.font(.system(size: 12, weight: .semibold))
				.foregroundStyle(VaultPalette.accentForeground)
				.vaultPointingHand()
				.help(state.file == nil ? "Choose an .env file to import" : "Choose another file")
		}
		.padding(.horizontal, 16)
		.padding(.vertical, 18)
		.background(RoundedRectangle(cornerRadius: 10).fill(highlighted ? VaultPalette.accent.opacity(0.07) : .clear))
		.overlay {
			RoundedRectangle(cornerRadius: 10)
				.strokeBorder(highlighted ? VaultPalette.accent.opacity(0.55) : VaultPalette.border, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
		}
		.accessibilityElement(children: .contain)
		.accessibilityLabel("Drop an .env file")
	}

	/// How many variables the file holds and its size, once read; what it
	/// says while it's read; nothing when the read failed, which the sheet says below.
	private var fileRead: String? {
		switch state.shownRead {
		case .success(let imported):
			"\(imported.countDescription) · \(ByteCountFormatter.string(fromByteCount: Int64(imported.byteCount), countStyle: .file))"
		case .failure: nil
		case nil: "Reading…"
		}
	}

	private var pasteBox: some View {
		VStack(alignment: .leading, spacing: 6) {
			EnvImportPasteEditor(
				text: Binding(get: { state.text }, set: { state.setText($0) }),
				isFocused: $editorFocused,
				isEditable: !disabled
			)
			.overlay(alignment: .topLeading) {
				if state.text.isEmpty {
					Text("API_URL=https://api.example.com\nexport TOKEN=\"…\"\n# Comments and blank lines are ignored")
						.font(VaultTypography.code(12))
						.foregroundStyle(VaultPalette.textFaint)
						.padding(.horizontal, 13)
						.padding(.vertical, 8)
						.allowsHitTesting(false)
						.accessibilityHidden(true)
				}
			}
			.frame(height: 148)
			.clipShape(RoundedRectangle(cornerRadius: 8))
			.vaultInputField(focused: editorFocused, invalid: state.problem != nil)
			HStack(spacing: 8) {
				Text(textCount)
					.font(.system(size: 11.5))
					.foregroundStyle(VaultPalette.textTertiary)
					.lineLimit(1)
				Spacer(minLength: 8)
				if !state.text.isEmpty {
					Button("Clear") { state.setText("") }
						.buttonStyle(.plain)
						.font(.system(size: 11.5, weight: .medium))
						.foregroundStyle(VaultPalette.accentForeground)
						.vaultPointingHand()
						.help("Clear the pasted text")
				}
			}
		}
	}

	private var textCount: String {
		if state.textIsBlank { return "Paste KEY=value lines, as an .env file holds them" }
		switch state.shownRead {
		case .success(let imported): return imported.countDescription
		case .failure: return "Nothing to import yet"
		case nil: return "Reading…"
		}
	}

	private func note(_ text: String, color: Color) -> some View {
		Text(text)
			.font(.system(size: 11.5))
			.foregroundStyle(color)
			.lineLimit(3)
			.fixedSize(horizontal: false, vertical: true)
	}

	private func chooseFile() {
		guard !disabled else { return }
		let panel = NSOpenPanel()
		panel.canChooseFiles = true
		panel.canChooseDirectories = false
		panel.allowsMultipleSelection = false
		// .env files are dotfiles, which the panel hides otherwise.
		panel.showsHiddenFiles = true
		panel.message = "Choose an .env file to import"
		panel.prompt = "Choose"
		guard runVaultPrivacyAwareModal(panel) == .OK, let url = panel.url else { return }
		store.recordUserActivity()
		state.choose(url)
	}
}

/// From file or Paste text, drawn as one control the sheet's width.
private struct EnvImportModeControl: View {
	@Binding var selection: EnvImportSourceState.Mode

	var body: some View {
		HStack(spacing: 2) {
			ForEach(EnvImportSourceState.Mode.allCases) { mode in
				Segment(title: mode.rawValue, selected: mode == selection) { selection = mode }
			}
		}
		.padding(2)
		.background(RoundedRectangle(cornerRadius: 8).fill(VaultPalette.neutralTint.opacity(0.6)))
		.overlay { RoundedRectangle(cornerRadius: 8).stroke(VaultPalette.border, lineWidth: 1) }
		.accessibilityElement(children: .contain)
		.accessibilityLabel("Import from")
	}

	private struct Segment: View {
		let title: String
		let selected: Bool
		let action: () -> Void
		@State private var hovering = false

		var body: some View {
			Button(action: action) {
				Text(title)
					.font(.system(size: 12.5, weight: selected ? .semibold : .regular))
					.foregroundStyle(selected ? Color.white : VaultPalette.textSecondary)
					.frame(maxWidth: .infinity)
					.frame(height: 26)
					.background(RoundedRectangle(cornerRadius: 6).fill(selected ? VaultPalette.strongFill : (hovering ? VaultPalette.sidebarHover : .clear)))
					.contentShape(Rectangle())
			}
			.buttonStyle(.plain)
			.onHover { hovering = $0 }
			.accessibilityAddTraits(selected ? .isSelected : [])
		}
	}
}

/// A plain-text box for pasted variables. It's AppKit's, as SwiftUI's
/// TextEditor can't turn off what would change a value as it's typed or
/// pasted: smart quotes and dashes, text replacement, spelling correction,
/// inline predictions and Writing Tools. It keeps its own undo history, so
/// nothing pasted outlives it in the window's.
struct EnvImportPasteEditor: NSViewRepresentable {
	@Binding var text: String
	@Binding var isFocused: Bool
	var isEditable = true

	func makeCoordinator() -> Coordinator { Coordinator(self) }

	func makeNSView(context: Context) -> NSScrollView {
		let textView = PasteTextView(frame: .zero)
		textView.isRichText = false
		textView.importsGraphics = false
		textView.allowsImageEditing = false
		textView.usesFontPanel = false
		textView.usesRuler = false
		textView.isAutomaticQuoteSubstitutionEnabled = false
		textView.isAutomaticDashSubstitutionEnabled = false
		textView.isAutomaticTextReplacementEnabled = false
		textView.isAutomaticSpellingCorrectionEnabled = false
		textView.isContinuousSpellCheckingEnabled = false
		textView.isGrammarCheckingEnabled = false
		textView.isAutomaticLinkDetectionEnabled = false
		textView.isAutomaticDataDetectionEnabled = false
		textView.isAutomaticTextCompletionEnabled = false
		textView.smartInsertDeleteEnabled = false
		textView.inlinePredictionType = .no
		if #available(macOS 15.0, *) { textView.writingToolsBehavior = .none }
		textView.allowsUndo = true
		textView.font = VaultTypography.codeNSFont(12)
		textView.textColor = .labelColor
		textView.insertionPointColor = NSColor(VaultPalette.accent)
		textView.drawsBackground = false
		textView.textContainerInset = NSSize(width: 8, height: 8)
		textView.isVerticallyResizable = true
		textView.isHorizontallyResizable = false
		textView.autoresizingMask = [.width]
		textView.minSize = .zero
		textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
		textView.textContainer?.widthTracksTextView = true
		textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
		textView.setAccessibilityLabel("Variables to import")
		textView.setAccessibilityPlaceholderValue("Paste KEY=value lines")
		textView.string = text
		textView.delegate = context.coordinator
		textView.onFocusChange = { focused in context.coordinator.parent.isFocused = focused }
		context.coordinator.shownText = text

		let scrollView = NSScrollView()
		scrollView.drawsBackground = false
		scrollView.borderType = .noBorder
		scrollView.hasVerticalScroller = true
		scrollView.autohidesScrollers = true
		scrollView.documentView = textView
		// Shown as Paste text is chosen, ready for ⌘V.
		DispatchQueue.main.async { [weak textView] in
			guard let textView, textView.isEditable else { return }
			textView.window?.makeFirstResponder(textView)
		}
		return scrollView
	}

	func updateNSView(_ scrollView: NSScrollView, context: Context) {
		context.coordinator.parent = self
		guard let textView = scrollView.documentView as? NSTextView else { return }
		textView.isEditable = isEditable
		textView.isSelectable = true
		// The text comes from the box almost always; it's set only when
		// something else changed it, such as Clear.
		if text != context.coordinator.shownText {
			textView.string = text
			context.coordinator.shownText = text
			context.coordinator.undoManager.removeAllActions()
		}
	}

	static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
		coordinator.undoManager.removeAllActions()
		(scrollView.documentView as? PasteTextView)?.onFocusChange = nil
	}

	@MainActor
	final class Coordinator: NSObject, NSTextViewDelegate {
		var parent: EnvImportPasteEditor
		var shownText = ""
		let undoManager = UndoManager()

		init(_ parent: EnvImportPasteEditor) { self.parent = parent }

		func textDidChange(_ notification: Notification) {
			guard let textView = notification.object as? NSTextView else { return }
			shownText = textView.string
			parent.text = shownText
		}

		func undoManager(for view: NSTextView) -> UndoManager? { undoManager }
	}

	/// Takes only plain text, from the pasteboard or a drag, so a dropped file
	/// reaches the import as a file instead of becoming its path in the text.
	final class PasteTextView: NSTextView {
		var onFocusChange: ((Bool) -> Void)?

		override var readablePasteboardTypes: [NSPasteboard.PasteboardType] { [.string] }
		override var acceptableDragTypes: [NSPasteboard.PasteboardType] { [.string] }

		override func becomeFirstResponder() -> Bool {
			let became = super.becomeFirstResponder()
			if became { onFocusChange?(true) }
			return became
		}

		override func resignFirstResponder() -> Bool {
			let resigned = super.resignFirstResponder()
			if resigned { onFocusChange?(false) }
			return resigned
		}
	}
}
