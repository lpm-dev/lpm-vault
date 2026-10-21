import AppKit
import SwiftUI

/// What quitting would lose, and whether to save it, discard it, or stay.
struct VaultQuitSheet: View {
	let coordinator: VaultQuitCoordinator

	/// Rows past this many scroll, so a long list stays the height of a few.
	static let shownRows = 6
	static let rowHeight: CGFloat = 50

	/// Hides the edits listed while the app is inactive, as the window it's attached to does.
	@State private var isObscured = !NSApp.isActive

	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			header
			VStack(alignment: .leading, spacing: 16) {
				if !coordinator.items.isEmpty { list }
				if coordinator.phase == .saving { progress }
				if let callout { callout }
			}
			.padding(.horizontal, 24)
			.padding(.bottom, 18)
			VaultSheetFooter {
				Text(footnote)
					.font(.system(size: 11.5))
					.foregroundStyle(VaultPalette.textTertiary)
					.fixedSize(horizontal: false, vertical: true)
			} actions: {
				actions
			}
		}
		.frame(width: 480)
		.background(VaultPalette.content)
		.vaultPrivacyProtected(isObscured)
		.onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in isObscured = true }
		.onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in isObscured = false }
		.onChange(of: coordinator.phase) { _, phase in announce(phase) }
		.onChange(of: coordinator.isFinishingOverdue) { _, overdue in
			if overdue { announce(coordinator.phase) }
		}
	}

	private func announce(_ phase: VaultQuitCoordinator.Phase) {
		guard phase != .idle else { return }
		AccessibilityNotification.Announcement("\(title). \(subtitle)").post()
	}

	// MARK: - Header

	private var header: some View {
		HStack(alignment: .top, spacing: 12) {
			VStack(alignment: .leading, spacing: 3) {
				Text(title)
					.font(.system(size: 17, weight: .bold))
					.foregroundStyle(VaultPalette.textPrimary)
					.accessibilityAddTraits(.isHeader)
				Text(subtitle)
					.font(.system(size: 12.5))
					.foregroundStyle(VaultPalette.textTertiary)
					.lineSpacing(2)
					.fixedSize(horizontal: false, vertical: true)
			}
			.frame(maxWidth: .infinity, alignment: .leading)
			VaultSheetCloseButton(label: "Cancel quitting") { coordinator.cancel() }
				.disabled(coordinator.phase == .idle)
		}
		.padding(.horizontal, 24)
		.padding(.top, 18)
		.padding(.bottom, 14)
	}

	private var title: String {
		switch coordinator.phase {
		case .idle, .reviewing: return "Quit with unsaved changes?"
		case .finishing: return coordinator.isFinishingOverdue ? "Still saving…" : "Saving…"
		case .saving: return "Saving…"
		case .failed:
			let count = coordinator.failedItems.count
			switch count {
			case 0: return "Edits changed elsewhere"
			case 1: return "One save failed"
			default: return "\(count) saves failed"
			}
		}
	}

	private var subtitle: String {
		switch coordinator.phase {
		case .idle, .reviewing:
			return Self.summary(of: coordinator.items)
		case .finishing:
			return coordinator.isFinishingOverdue
				? "A change is taking longer than usual to save. Quitting now may lose it."
				: "Finishing changes that are being saved before LPM Vault quits."
		case .saving:
			let count = coordinator.items.filter { $0.isSaveable && $0.state != .saved }.count
			return count == 1 ? "Finishing 1 save before quitting." : "Finishing \(count) saves before quitting."
		case .failed:
			let failed = coordinator.failedItems
			if failed.isEmpty {
				return "Some edits changed elsewhere while they were being saved. Review them in the inspector, or quit to discard them."
			}
			guard failed.count == 1, let item = failed.first, case .failed(let reason) = item.state else {
				return "Each row says why it couldn't be saved. Your edits are still in the inspector."
			}
			return "\(item.projectName) · \(reason). Your edit is still in the inspector."
		}
	}

	/// How many edits in how many projects aren't saved, which schema drafts
	/// aren't written, and which open sheets hold something.
	static func summary(of items: [VaultQuitCoordinator.Item]) -> String {
		let keyItems = items.filter { $0.editCount > 0 }
		let edits = keyItems.reduce(0) { $0 + $1.editCount }
		let projects = Set(keyItems.map(\.projectID)).count
		let drafts = items.filter { if case .schema = $0.kind { true } else { false } }.count
		let sheets = items.filter { if case .sheet = $0.kind { true } else { false } }.count
		let settings = Set(items.compactMap { if case .settings = $0.kind { $0.projectID } else { nil } }).count
		var parts: [String] = []
		if edits > 0 {
			let editText = edits == 1 ? "1 edit" : "\(edits) edits"
			let projectText = projects == 1 ? "1 project" : "\(projects) projects"
			parts.append("\(editText) in \(projectText) \(edits == 1 ? "hasn't" : "haven't") been saved to the Keychain")
		}
		if drafts > 0 {
			parts.append(drafts == 1 ? "a schema draft hasn't been written to lpm.json" : "\(drafts) schema drafts haven't been written to lpm.json")
		}
		if settings > 0 {
			parts.append("project settings for \(settings == 1 ? "1 project" : "\(settings) projects") haven't been saved")
		}
		if sheets > 0 {
			parts.append(sheets == 1 ? "a sheet is still open" : "\(sheets) sheets are still open")
		}
		guard let first = parts.first else { return "" }
		let sentence = parts.count == 1 ? first : parts.dropLast().joined(separator: ", ") + ", and " + parts[parts.count - 1]
		return sentence.prefix(1).uppercased() + sentence.dropFirst() + "."
	}

	// MARK: - List

	@ViewBuilder
	private var list: some View {
		let rows = LazyVStack(spacing: 0) {
			ForEach(Array(coordinator.items.enumerated()), id: \.element.id) { index, item in
				if index > 0 { VaultHairline(color: VaultPalette.rowDivider) }
				row(item)
			}
		}
		Group {
			if coordinator.items.count > Self.shownRows {
				ScrollView { rows }
					.frame(height: CGFloat(Self.shownRows) * Self.rowHeight)
			} else {
				rows
			}
		}
		.background(RoundedRectangle(cornerRadius: 10).fill(VaultPalette.control))
		.clipShape(RoundedRectangle(cornerRadius: 10))
		.overlay { RoundedRectangle(cornerRadius: 10).stroke(VaultPalette.border, lineWidth: 1) }
	}

	private func row(_ item: VaultQuitCoordinator.Item) -> some View {
		HStack(spacing: 10) {
			Group {
				switch item.kind {
				case .schema: Text("{}").font(VaultTypography.tabular(11, .bold))
				case .settings: Image(systemName: "gearshape").font(.system(size: 12, weight: .medium))
				case .sheet: Image(systemName: "macwindow").font(.system(size: 12, weight: .medium))
				case .rawText: Image(systemName: "doc.plaintext").font(.system(size: 12, weight: .medium))
				case .keys, .review: Image(systemName: "folder").font(.system(size: 12, weight: .medium))
				}
			}
			.foregroundStyle(VaultPalette.textTertiary)
			.frame(width: 16)
			.accessibilityHidden(true)
			VStack(alignment: .leading, spacing: 2) {
				(Text(item.projectName).fontWeight(.semibold) + Text(" · \(item.subject)"))
					.font(.system(size: 12.5))
					.foregroundStyle(VaultPalette.textPrimary)
					.lineLimit(1)
				Text(item.detail)
					.font(.system(size: 11))
					.foregroundStyle(VaultPalette.textTertiary)
					.lineLimit(1)
					.truncationMode(.middle)
				if case .failed(let reason) = item.state {
					Text(reason)
						.font(.system(size: 11))
						.foregroundStyle(VaultPalette.redText)
						.fixedSize(horizontal: false, vertical: true)
				}
			}
			.frame(maxWidth: .infinity, alignment: .leading)
			status(item)
		}
		.padding(.horizontal, 12)
		.padding(.vertical, 9)
		.frame(minHeight: Self.rowHeight - 1)
		.accessibilityElement(children: .combine)
	}

	@ViewBuilder
	private func status(_ item: VaultQuitCoordinator.Item) -> some View {
		switch item.state {
		case .waiting where coordinator.phase == .saving && item.isSaveable:
			Text("Waiting…")
				.font(.system(size: 11.5))
				.foregroundStyle(VaultPalette.textTertiary)
		case .waiting:
			badge(item.badge, schema: { if case .schema = item.kind { true } else { false } }())
		case .saving:
			ProgressView().controlSize(.small).accessibilityLabel("Saving")
		case .saved:
			Image(systemName: "checkmark.circle.fill")
				.font(.system(size: 13))
				.foregroundStyle(VaultPalette.greenTintText)
				.accessibilityLabel("Saved")
		case .failed:
			Label("Not saved", systemImage: "exclamationmark.circle.fill")
				.font(.system(size: 11.5))
				.foregroundStyle(VaultPalette.redText)
		case .needsReview:
			Text(item.isSheet ? "Open" : "Needs review")
				.font(.system(size: 11.5))
				.foregroundStyle(VaultPalette.orangeTintText)
		}
	}

	private func badge(_ text: String, schema: Bool) -> some View {
		Text(text)
			.font(.system(size: 11, weight: .semibold))
			.foregroundStyle(schema ? VaultPalette.accentText : VaultPalette.orangeTintText)
			.padding(.horizontal, 7)
			.frame(height: 20)
			.background(RoundedRectangle(cornerRadius: 6).fill(schema ? VaultPalette.accentTint : VaultPalette.orangeTint))
	}

	private var progress: some View {
		let saveable = coordinator.items.filter(\.isSaveable)
		let done = saveable.filter { $0.state == .saved || $0.isFailed }.count
		let fraction = saveable.isEmpty ? 0 : CGFloat(done) / CGFloat(saveable.count)
		return Capsule().fill(VaultPalette.neutralTint)
			.frame(height: 4)
			.overlay(alignment: .leading) {
				GeometryReader { proxy in
					Capsule().fill(VaultPalette.accent).frame(width: proxy.size.width * fraction)
				}
			}
			.accessibilityRepresentation {
				ProgressView("Saving", value: Double(done), total: Double(max(saveable.count, 1)))
			}
	}

	private var callout: AnyView? {
		let review = coordinator.needsReviewCount
		switch coordinator.phase {
		case .reviewing where review > 0:
			return AnyView(calloutBox("Edits that can't be saved here stay as they are if you cancel; quitting discards them.",
				systemImage: "exclamationmark.triangle.fill", tint: VaultPalette.orangeTint, text: VaultPalette.orangeTintText))
		case .failed:
			let others = review > 0 ? " Edits that need a review are discarded too." : ""
			return AnyView(calloutBox("Retry, or quit anyway to discard only what couldn't be saved.\(others)",
				systemImage: "exclamationmark.circle.fill", tint: VaultPalette.redTint, text: VaultPalette.redText))
		default:
			return nil
		}
	}

	private func calloutBox(_ message: String, systemImage: String, tint: Color, text: Color) -> some View {
		HStack(alignment: .top, spacing: 8) {
			Image(systemName: systemImage)
				.font(.system(size: 12))
				.padding(.top, 1)
				.accessibilityHidden(true)
			Text(message)
				.font(.system(size: 12))
				.lineSpacing(2)
				.fixedSize(horizontal: false, vertical: true)
		}
		.foregroundStyle(text)
		.padding(.horizontal, 12)
		.padding(.vertical, 10)
		.frame(maxWidth: .infinity, alignment: .leading)
		.background(RoundedRectangle(cornerRadius: 8).fill(tint))
		.accessibilityElement(children: .combine)
	}

	// MARK: - Footer

	private var footnote: String {
		switch coordinator.phase {
		case .idle, .reviewing: return "Saving takes a moment; the app quits when every item is done."
		case .finishing where coordinator.isFinishingOverdue: return "Cancel keeps the app open while it finishes."
		case .finishing, .saving: return "Cancel keeps the app open with your edits intact."
		case .failed:
			let total = coordinator.items.filter(\.isSaveable).count
			return "\(coordinator.savedCount) of \(total) saved."
		}
	}

	@ViewBuilder
	private var actions: some View {
		switch coordinator.phase {
		case .idle, .reviewing:
			VaultBarButton(title: "Discard all", height: 28) { coordinator.discardAndQuit() }
				.help("Discard all (⌘⌫)")
			VaultBarButton(title: "Cancel", height: 28) { coordinator.cancel() }
				.keyboardShortcut(.cancelAction)
			VaultBarButton(title: "Save and quit", filled: true, height: 28) { coordinator.saveAndQuit() }
				.keyboardShortcut(.defaultAction)
		case .finishing where coordinator.isFinishingOverdue:
			VaultBarButton(title: "Quit anyway", height: 28) { coordinator.discardAndQuit() }
			VaultBarButton(title: "Cancel", height: 28) { coordinator.cancel() }
				.keyboardShortcut(.cancelAction)
		case .finishing, .saving:
			VaultBarButton(title: "Cancel", height: 28) { coordinator.cancel() }
				.keyboardShortcut(.cancelAction)
		case .failed:
			VaultBarButton(title: "Quit anyway", height: 28) { coordinator.discardAndQuit() }
			VaultBarButton(title: "Cancel", height: 28) { coordinator.cancel() }
				.keyboardShortcut(.cancelAction)
			if !coordinator.failedItems.isEmpty {
				VaultBarButton(title: "Retry", filled: true, height: 28) { coordinator.saveAndQuit() }
					.keyboardShortcut(.defaultAction)
			}
		}
	}
}

extension VaultQuitCoordinator.Item {
	var isSheet: Bool {
		if case .sheet = kind { true } else { false }
	}

	/// What follows the project's name, such as "3 keys" or "Schema draft".
	var subject: String {
		switch kind {
		case .keys(let keys): keys.count == 1 ? "1 key" : "\(keys.count) keys"
		case .review(let keys): keys.count == 1 ? "1 key needs review" : "\(keys.count) keys need review"
		case .schema: "Schema draft"
		case .settings: "Project settings"
		case .rawText(let environment, _): "\(VaultProject.displayName(for: environment)) as Raw text"
		case .sheet(let title, _): title
		}
	}

	var detail: String {
		switch kind {
		case .keys(let keys):
			keys.map(\.key).joined(separator: ", ") + (keys.count == 1 ? " · inspector edit" : " · inspector edits")
		case .review(let keys):
			keys.map(\.key).joined(separator: ", ") + " · changed elsewhere since the edit"
		case .schema(let changes):
			(changes == 1 ? "1 rule change" : "\(changes) rule changes") + " · lpm.json not written"
		case .settings(let newName, let changesIcon):
			[newName.map { "Name \($0)" }, changesIcon ? (newName == nil ? "Icon" : "icon") : nil]
				.compactMap { $0 }.joined(separator: " and ") + " · not saved"
		case .rawText(_, let summary):
			(summary.isEmpty ? "No value changes" : summary) + " · not saved"
		case .sheet(_, let detail):
			detail
		}
	}

	var badge: String {
		switch kind {
		case .keys, .review: editCount == 1 ? "1 edit" : "\(editCount) edits"
		case .schema, .settings, .rawText: "draft"
		case .sheet: "open"
		}
	}
}

extension View {
	/// Lists what this sheet holds among what quitting would discard, while
	/// `detail` says what's typed into it; nil once there's nothing.
	func vaultUnsavedSheetWork(_ store: VaultStore?, projectID: String?, projectName: String, title: String, detail: String?) -> some View {
		modifier(VaultUnsavedSheetWork(store: store, projectID: projectID, projectName: projectName, title: title, detail: detail))
	}
}

private struct VaultUnsavedSheetWork: ViewModifier {
	let store: VaultStore?
	let projectID: String?
	let projectName: String
	let title: String
	let detail: String?
	@State private var id = UUID()

	func body(content: Content) -> some View {
		content
			.onAppear(perform: update)
			.onChange(of: detail) { _, _ in update() }
			.onDisappear { store?.releaseSheetWork(id) }
	}

	private func update() {
		guard let store else { return }
		guard let detail else { return store.releaseSheetWork(id) }
		store.holdSheetWork(.init(id: id, projectID: projectID, projectName: projectName, title: title, detail: detail))
	}
}

/// Attaches the quit sheet to the app's window, or to a sheet already on it,
/// and attaches it again when that sheet closes under it.
@MainActor
final class VaultQuitSheetPresenter: VaultQuitCoordinator.Presenter {
	private(set) var sheet: NSWindow?
	private weak var coordinator: VaultQuitCoordinator?
	private var parentObservers: [any NSObjectProtocol] = []
	private var keyMonitor: Any?

	/// ⌘⌫ discards, as Don't Save does in a document's save sheet. The key is
	/// read by its code: a SwiftUI shortcut for it doesn't match the event the
	/// Delete key makes.
	static func isDiscardKey(_ event: NSEvent) -> Bool {
		event.type == .keyDown && event.keyCode == 51
			&& event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function]) == .command
	}

	func present(_ coordinator: VaultQuitCoordinator) -> Bool {
		self.coordinator = coordinator
		if let sheet, sheet.sheetParent != nil { return true }
		guard let window = VaultMainWindow.current else { return false }
		// A hidden app or a minimized window would leave the sheet where no one sees it.
		if NSApp.isHidden { NSApp.unhide(nil) }
		if window.isMiniaturized { window.deminiaturize(nil) }
		guard window.isVisible || window.isMiniaturized else { return false }
		var parent = window
		while let attached = parent.attachedSheet, attached !== sheet { parent = attached }
		let sheet = self.sheet ?? makeSheet(for: coordinator)
		NSApp.activate()
		window.makeKeyAndOrderFront(nil)
		parent.beginSheet(sheet)
		self.sheet = sheet
		watch(parent)
		if keyMonitor == nil {
			keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
				guard let self, event.window === self.sheet, Self.isDiscardKey(event), let shown = self.coordinator,
					shown.phase == .reviewing || shown.phase == .failed
				else { return event }
				shown.discardAndQuit()
				return nil
			}
		}
		return true
	}

	func dismiss() {
		stopWatching()
		if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
		keyMonitor = nil
		guard let sheet else { return }
		sheet.sheetParent?.endSheet(sheet)
		sheet.orderOut(nil)
		self.sheet = nil
	}

	private func makeSheet(for coordinator: VaultQuitCoordinator) -> NSWindow {
		let controller = NSHostingController(rootView: VaultQuitSheet(coordinator: coordinator))
		controller.sizingOptions = .preferredContentSize
		let sheet = NSWindow(contentViewController: controller)
		sheet.styleMask = [.titled, .fullSizeContentView]
		sheet.title = "Quit LPM Vault"
		sheet.titleVisibility = .hidden
		sheet.titlebarAppearsTransparent = true
		return sheet
	}

	/// A sheet the quit sheet is attached to can close under it, as a project's
	/// sheet does when the vault locks; the quit sheet then moves to the window.
	private func watch(_ parent: NSWindow) {
		stopWatching()
		guard parent !== VaultMainWindow.current else { return }
		let center = NotificationCenter.default
		for name in [NSWindow.willCloseNotification, NSWindow.didEndSheetNotification] {
			let object: NSWindow? = name == NSWindow.willCloseNotification ? parent : parent.sheetParent
			parentObservers.append(center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
				MainActor.assumeIsolated { self?.parentClosed() }
			})
		}
	}

	private func parentClosed() {
		// The sheet ends as its parent does, after this notice; present it again once it has.
		DispatchQueue.main.async { [weak self] in
			guard let self, let sheet, sheet.sheetParent == nil || !sheet.isVisible,
				let coordinator, coordinator.isQuitting
			else { return }
			sheet.orderOut(nil)
			self.sheet = nil
			_ = present(coordinator)
		}
	}

	private func stopWatching() {
		for observer in parentObservers { NotificationCenter.default.removeObserver(observer) }
		parentObservers.removeAll()
	}
}

/// The app's one window, once it's shown, for what needs a window outside SwiftUI.
@MainActor
enum VaultMainWindow {
	static weak var current: NSWindow? {
		didSet {
			guard current !== oldValue else { return }
			observeClose()
		}
	}

	/// Called as the main window closes, which can leave Settings open.
	static var onClose: (() -> Void)?
	private static var closeObserver: (any NSObjectProtocol)?

	private static func observeClose() {
		if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
		closeObserver = current.map { window in
			NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
				MainActor.assumeIsolated { onClose?() }
			}
		}
	}
}
