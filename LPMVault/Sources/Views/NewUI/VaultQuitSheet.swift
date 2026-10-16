import AppKit
import SwiftUI

/// What quitting would lose, and whether to save it, discard it, or stay.
struct VaultQuitSheet: View {
	let coordinator: VaultQuitCoordinator

	/// Hides the edits listed while the app is inactive, as the window it's attached to does.
	@State private var isObscured = false

	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			header
			VStack(alignment: .leading, spacing: 16) {
				if !coordinator.items.isEmpty { list }
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
	}

	// MARK: - Header

	private var header: some View {
		HStack(alignment: .top, spacing: 12) {
			VStack(alignment: .leading, spacing: 3) {
				Text(title)
					.font(.system(size: 17, weight: .bold))
					.foregroundStyle(VaultPalette.textPrimary)
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
		case .finishing, .saving: return "Saving…"
		case .failed:
			let count = coordinator.failedItems.count
			return count == 1 ? "One save failed" : "\(count) saves failed"
		}
	}

	private var subtitle: String {
		switch coordinator.phase {
		case .idle, .reviewing:
			return Self.summary(of: coordinator.items)
		case .finishing:
			return "Finishing changes that are being saved before LPM Vault quits."
		case .saving:
			let count = coordinator.items.filter { $0.state != .saved && !$0.isReview }.count
			return count == 1 ? "Finishing 1 save before quitting." : "Finishing \(count) saves before quitting."
		case .failed:
			guard let item = coordinator.failedItems.first, case .failed(let reason) = item.state else { return "" }
			return "\(item.projectName) · \(reason)"
		}
	}

	/// How many edits in how many projects aren't saved, and which schema drafts aren't written.
	static func summary(of items: [VaultQuitCoordinator.Item]) -> String {
		let keyItems = items.filter { if case .keys = $0.kind { true } else { false } }
		let edits = keyItems.reduce(0) { $0 + $1.editCount }
		let projects = Set(keyItems.map(\.projectID)).count
		let drafts = items.count - keyItems.count
		var parts: [String] = []
		if edits > 0 {
			let editText = edits == 1 ? "1 edit" : "\(edits) edits"
			let projectText = projects == 1 ? "1 project" : "\(projects) projects"
			parts.append("\(editText) in \(projectText) \(edits == 1 ? "hasn't" : "haven't") been saved to the Keychain")
		}
		if drafts > 0 {
			parts.append(drafts == 1 ? "a schema draft hasn't been written to lpm.json" : "\(drafts) schema drafts haven't been written to lpm.json")
		}
		guard let first = parts.first else { return "" }
		let sentence = parts.count == 2 ? "\(first), and \(parts[1])" : first
		return sentence.prefix(1).uppercased() + sentence.dropFirst() + "."
	}

	// MARK: - List

	private var list: some View {
		VStack(spacing: 0) {
			ForEach(Array(coordinator.items.enumerated()), id: \.element.id) { index, item in
				if index > 0 { VaultHairline(color: VaultPalette.rowDivider) }
				row(item)
			}
		}
		.background(RoundedRectangle(cornerRadius: 10).fill(VaultPalette.control))
		.overlay { RoundedRectangle(cornerRadius: 10).stroke(VaultPalette.border, lineWidth: 1) }
	}

	private func row(_ item: VaultQuitCoordinator.Item) -> some View {
		HStack(spacing: 10) {
			Group {
				if item.kind == .schema {
					Text("{}").font(VaultTypography.mono(11, .bold))
				} else {
					Image(systemName: "folder").font(.system(size: 12, weight: .medium))
				}
			}
			.foregroundStyle(VaultPalette.textTertiary)
			.frame(width: 16)
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
			}
			.frame(maxWidth: .infinity, alignment: .leading)
			status(item)
		}
		.padding(.horizontal, 12)
		.padding(.vertical, 9)
		.accessibilityElement(children: .combine)
	}

	@ViewBuilder
	private func status(_ item: VaultQuitCoordinator.Item) -> some View {
		switch item.state {
		case .waiting where coordinator.phase == .saving:
			Circle().strokeBorder(VaultPalette.border, lineWidth: 2).frame(width: 14, height: 14)
				.accessibilityLabel("Waiting")
		case .waiting:
			badge(item.badge, schema: item.kind == .schema)
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
			Text("Needs review")
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

	private var callout: AnyView? {
		switch coordinator.phase {
		case .reviewing where coordinator.needsReviewCount > 0:
			return AnyView(calloutBox("Edits to keys that changed elsewhere can't be saved here. Cancel to review them in the inspector; quitting discards them.",
				tint: VaultPalette.orangeTint, text: VaultPalette.orangeTintText))
		case .failed:
			return AnyView(calloutBox("Retry, or quit anyway to discard only what couldn't be saved. Your other edits are saved.",
				tint: VaultPalette.redTint, text: VaultPalette.redText))
		default:
			return nil
		}
	}

	private func calloutBox(_ message: String, tint: Color, text: Color) -> some View {
		Text(message)
			.font(.system(size: 12))
			.foregroundStyle(text)
			.lineSpacing(2)
			.fixedSize(horizontal: false, vertical: true)
			.padding(.horizontal, 12)
			.padding(.vertical, 10)
			.frame(maxWidth: .infinity, alignment: .leading)
			.background(RoundedRectangle(cornerRadius: 8).fill(tint))
	}

	// MARK: - Footer

	private var footnote: String {
		switch coordinator.phase {
		case .idle, .reviewing: return "Saving takes a moment; the app quits when every item is done."
		case .finishing, .saving: return "Cancel keeps the app open with your edits intact."
		case .failed:
			let total = coordinator.items.filter { !$0.isReview }.count
			return "\(coordinator.savedCount) of \(total) saved."
		}
	}

	@ViewBuilder
	private var actions: some View {
		switch coordinator.phase {
		case .idle, .reviewing:
			VaultBarButton(title: "Discard all", height: 28) { coordinator.discardAndQuit() }
			VaultBarButton(title: "Cancel", height: 28) { coordinator.cancel() }
				.keyboardShortcut(.cancelAction)
			VaultBarButton(title: "Save and quit", filled: true, height: 28) { coordinator.saveAndQuit() }
				.keyboardShortcut(.defaultAction)
		case .finishing, .saving:
			VaultBarButton(title: "Cancel", height: 28) { coordinator.cancel() }
				.keyboardShortcut(.cancelAction)
		case .failed:
			VaultBarButton(title: "Quit anyway", height: 28) { coordinator.discardAndQuit() }
			VaultBarButton(title: "Cancel", height: 28) { coordinator.cancel() }
				.keyboardShortcut(.cancelAction)
			VaultBarButton(title: "Retry", filled: true, height: 28) { coordinator.saveAndQuit() }
				.keyboardShortcut(.defaultAction)
		}
	}
}

extension VaultQuitCoordinator.Item {
	var isReview: Bool {
		if case .needsReview = state { true } else { false }
	}
}

/// Attaches the quit sheet to the app's window, or to a sheet already on it.
@MainActor
final class VaultQuitSheetPresenter: VaultQuitCoordinator.Presenter {
	private(set) var sheet: NSWindow?

	func present(_ coordinator: VaultQuitCoordinator) -> Bool {
		if sheet != nil { return true }
		guard let window = VaultMainWindow.current, window.isVisible else { return false }
		var parent = window
		while let attached = parent.attachedSheet { parent = attached }
		let controller = NSHostingController(rootView: VaultQuitSheet(coordinator: coordinator))
		controller.sizingOptions = .preferredContentSize
		let sheet = NSWindow(contentViewController: controller)
		sheet.styleMask = [.titled, .fullSizeContentView]
		sheet.titleVisibility = .hidden
		sheet.titlebarAppearsTransparent = true
		NSApp.activate()
		window.makeKeyAndOrderFront(nil)
		parent.beginSheet(sheet)
		self.sheet = sheet
		return true
	}

	func dismiss() {
		guard let sheet else { return }
		sheet.sheetParent?.endSheet(sheet)
		sheet.orderOut(nil)
		self.sheet = nil
	}
}

/// The app's one window, once it's shown, for what needs a window outside SwiftUI.
@MainActor
enum VaultMainWindow {
	static weak var current: NSWindow?
}
