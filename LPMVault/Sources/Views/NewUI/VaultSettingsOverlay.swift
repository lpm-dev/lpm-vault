import SwiftUI

/// Settings and Platforms over the workspace, which stays as it was under a
/// dimmed backdrop: a menu of Settings' parts on the leading side, with a
/// search above it, the part chosen beside it, and a header naming it. Esc
/// clears a search, then closes it, as the close button or a click on the
/// backdrop does.
struct VaultSettingsOverlay: View {
	@Bindable var store: VaultStore
	let category: VaultSettingsCategory

	@State private var search = VaultSettingsSearch()
	@FocusState private var searchFocused: Bool
	// Optional, as a page that shows none of them, such as Platforms, can be shown without them.
	@Environment(VaultAppearanceSettings.self) private var appearance: VaultAppearanceSettings?
	@Environment(VaultQuitSettings.self) private var quit: VaultQuitSettings?
	@Environment(UpdateChecker.self) private var updates: UpdateChecker?

	private var pageDefaults: VaultSettingsPageDefaults {
		VaultSettingsPageDefaults(settings: store.settings, appearance: appearance, quit: quit, updates: updates)
	}

	/// How far the panel stays from the title bar, the window's bottom and its sides.
	static let margin: CGFloat = 40
	static let menuWidth: CGFloat = 200
	/// The space between a page's column of cards and the panel's sides.
	static let contentInset: CGFloat = 28
	static let headerHeight: CGFloat = 58

	/// The width a page's scroll bar takes from it.
	@State private var scrollBar = Self.scrollBarWidth

	/// The widest the panel grows in a large window: the menu, its hairline and
	/// a page's widest column of cards, so no empty strip runs beside them,
	/// with `scrollBar` beside the cards when scroll bars always show.
	static func maximumWidth(scrollBar: CGFloat) -> CGFloat {
		menuWidth + 1 + contentInset + VaultMetrics.formWidth + contentInset + scrollBar
	}

	/// What a page's scroll bar takes from it: nothing where scroll bars show
	/// only while scrolling, as with a trackpad, and their width where they
	/// always show, as with a mouse or the setting that asks for it.
	static var scrollBarWidth: CGFloat {
		NSScroller.preferredScrollerStyle == .legacy ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) : 0
	}

	var body: some View {
		GeometryReader { geometry in
			let frame = Self.panelFrame(in: geometry.size, scrollBar: scrollBar)
			ZStack(alignment: .topLeading) {
				VaultPalette.scrim
					.overlay { VaultClickCatcher { store.closeAccountPage() } }
					.accessibilityHidden(true)
				windowControls
				panel
					.frame(width: frame.width, height: frame.height)
					.position(x: frame.midX, y: frame.midY)
			}
			.frame(width: geometry.size.width, height: geometry.size.height)
		}
		// From the window's top, as the workspace under it runs under the
		// system's title bar inset: otherwise the backdrop leaves the title
		// bar undimmed and the panel sits that inset lower.
		.ignoresSafeArea(.container, edges: .top)
		// Its keys work wherever focus is in the window, unless a sheet, such as a backup's, is over it.
		.background(VaultMenuKeys { handle($0) })
		.onReceive(NotificationCenter.default.publisher(for: .findSettings)) { _ in searchFocused = true }
		.onChange(of: category) { _, category in search.pageShown(category) }
		.onReceive(NotificationCenter.default.publisher(for: NSScroller.preferredScrollerStyleDidChangeNotification)) { _ in
			scrollBar = Self.scrollBarWidth
		}
	}

	/// Esc clears a search before it closes Settings. From the search field,
	/// the arrows show the result above or below, and Return the one shown or
	/// the best. The arrows stay the search's there even with no result
	/// further, so they don't move the field's caret instead.
	private func handle(_ key: VaultMenuKeys.Key) -> Bool {
		switch key {
		case .close:
			if search.query.isEmpty {
				store.closeAccountPage()
			} else {
				search.clear()
			}
			return true
		case .up, .down:
			guard searchFocused, search.isSearching else { return false }
			if let entry = search.result(movingBy: key == .down ? 1 : -1) { show(entry) }
			return true
		case .open:
			guard searchFocused, search.isSearching, let entry = search.resultForReturn else { return false }
			show(entry)
			return true
		case .left, .right:
			return false
		}
	}

	/// Opens `entry`'s page, which brings it into view and tints it a moment.
	private func show(_ entry: VaultSettingsEntry) {
		if store.shownSettingsCategory != entry.category { store.showSettings(entry.category) }
		search.choose(entry)
		AccessibilityNotification.Announcement("\(entry.title), in \(entry.category.title)").post()
	}

	/// Where the panel sits in a window `size` big, from its top-left: clear
	/// of the title bar by the margin, as far from the bottom, centered, and no
	/// wider than `maximumWidth(scrollBar:)`.
	static func panelFrame(in size: CGSize, scrollBar: CGFloat = 0) -> CGRect {
		let top = VaultMetrics.titleBar + margin
		let width = max(0, min(maximumWidth(scrollBar: scrollBar), size.width - 2 * margin))
		return CGRect(x: (size.width - width) / 2, y: top, width: width, height: max(0, size.height - top - margin))
	}

	/// The window's buttons above the backdrop, where the title bar draws
	/// them, as a window's own stay above what it shows. The rest of the
	/// title bar still moves the window.
	private var windowControls: some View {
		HStack(spacing: 0) {
			VaultTrafficLights()
			Spacer(minLength: 0)
		}
		.padding(.leading, VaultMetrics.windowButtonsInset)
		.frame(height: VaultMetrics.titleBar)
		.background(VaultWindowDragArea())
	}

	private var panel: some View {
		VStack(spacing: 0) {
			header
			VaultHairline()
			HStack(spacing: 0) {
				VaultSettingsMenuColumn(store: store, category: category, search: search, searchFocused: $searchFocused, show: show)
				VaultHairline(axis: .vertical)
				VaultSettingsContent(store: store, category: category)
					.id(category)
					.environment(\.vaultSettingsHighlight, search.highlight)
					.frame(maxWidth: .infinity, maxHeight: .infinity)
			}
		}
		.background(VaultPalette.content)
		.clipShape(RoundedRectangle(cornerRadius: 12))
		.overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(VaultPalette.popoverBorder, lineWidth: 1) }
		.shadow(color: VaultPalette.shadow.opacity(0.22), radius: 28, y: 14)
		// A modal group: VoiceOver stays in it. Its header says what it is.
		.accessibilityElement(children: .contain)
		.accessibilityAddTraits(.isModal)
	}

	private var header: some View {
		HStack(spacing: 10) {
			HStack(spacing: 10) {
				Text("Settings")
					.foregroundStyle(VaultPalette.textTertiary)
				// The same chevron as every other path in the app, such as All Keys › Project Settings.
				Image(systemName: "chevron.right")
					.font(.system(size: 10, weight: .semibold))
					.foregroundStyle(VaultPalette.textFaint)
					.accessibilityHidden(true)
				Text(category.title)
					.foregroundStyle(VaultPalette.textPrimary)
					.accessibilityAddTraits(.isHeader)
			}
			.font(.system(size: 15, weight: .semibold))
			.lineLimit(1)
			Spacer(minLength: 12)
			if pageDefaults.hasChanges(on: category) {
				VaultBarButton(title: "Restore Defaults", height: 28) { pageDefaults.restore(category) }
					.help("Put this page’s settings back as LPM Vault first had them")
			}
			closeButton
		}
		.padding(.horizontal, 20)
		.frame(height: Self.headerHeight)
	}

	/// The close every sheet has, so the overlay closes as they do.
	private var closeButton: some View {
		VaultSheetCloseButton(label: "Close Settings") { store.closeAccountPage() }
	}
}

/// Settings' menu: the search above its parts, or what the search found in
/// their place. Its own view, so what's typed updates it alone.
private struct VaultSettingsMenuColumn: View {
	let store: VaultStore
	let category: VaultSettingsCategory
	let search: VaultSettingsSearch
	var searchFocused: FocusState<Bool>.Binding
	let show: (VaultSettingsEntry) -> Void

	var body: some View {
		VStack(alignment: .leading, spacing: 1) {
			VaultSettingsSearchField(search: search, focused: searchFocused)
				.padding(.bottom, 10)
			if search.isSearching {
				VaultSettingsSearchResults(search: search, show: show)
			} else {
				ForEach(VaultSettingsCategory.allCases) { item in
					VaultSettingsMenuRow(category: item, selected: item == category) { store.showSettings(item) }
				}
				Spacer(minLength: 12)
			}
			VStack(alignment: .leading, spacing: 2) {
				Text("LPM Vault")
				Text(VaultBuildInfo().displayVersion)
					.lineLimit(2)
			}
			.font(.system(size: 11))
			.foregroundStyle(VaultPalette.textTertiary)
			.padding(.horizontal, 9)
			.padding(.bottom, 4)
		}
		.padding(.horizontal, 10)
		.padding(.vertical, 14)
		.frame(width: VaultSettingsOverlay.menuWidth, alignment: .leading)
		.frame(maxHeight: .infinity)
		.background(VaultPalette.sidebar)
		// Each new set of results is said, even with as many as the last.
		.onChange(of: search.results) { _, _ in
			if let announcement = search.resultsAnnouncement { AccessibilityNotification.Announcement(announcement).post() }
		}
	}
}

/// Which of a Settings page's settings differ from LPM Vault's defaults, and
/// putting them back. The update channel and the LPM home are choices with
/// consequences of their own, never defaults to restore.
@MainActor
struct VaultSettingsPageDefaults {
	let settings: VaultSettings
	var appearance: VaultAppearanceSettings?
	var quit: VaultQuitSettings?
	var updates: UpdateChecker?

	func hasChanges(on category: VaultSettingsCategory) -> Bool {
		let standard = VaultSettings.standard
		switch category {
		case .general:
			return quit.map { $0.selection != VaultQuitShortcut.standard } == true
				|| settings.newProjectsKeepHistory != standard.newProjectsKeepHistory
		case .security: return settings.security != standard.security
		case .appearance: return appearance.map { $0.selection != .system } == true
		case .cli: return settings.newProjectsAskBeforeCLIReads != standard.newProjectsAskBeforeCLIReads
		case .backup: return settings.remindsToBackUp != standard.remindsToBackUp
		case .updates:
			let automatic = BackupAppSection.AutomaticUpdates.standard
			guard let updates, updates.canChangeAutomaticUpdates else { return false }
			return updates.automaticallyChecks != automatic.checks || updates.automaticallyDownloads != automatic.downloads
		case .account, .platforms, .about: return false
		}
	}

	func restore(_ category: VaultSettingsCategory) {
		let standard = VaultSettings.standard
		switch category {
		case .general:
			quit?.selection = VaultQuitShortcut.standard
			settings.newProjectsKeepHistory = standard.newProjectsKeepHistory
		case .security: settings.security = standard.security
		case .appearance: appearance?.selection = .system
		case .cli: settings.newProjectsAskBeforeCLIReads = standard.newProjectsAskBeforeCLIReads
		case .backup: settings.remindsToBackUp = standard.remindsToBackUp
		case .updates:
			let automatic = BackupAppSection.AutomaticUpdates.standard
			updates?.automaticallyChecks = automatic.checks
			updates?.automaticallyDownloads = automatic.downloads
		case .account, .platforms, .about: break
		}
	}
}

/// Takes a click, as AppKit delivers it, whichever window is key.
private struct VaultClickCatcher: NSViewRepresentable {
	let action: () -> Void

	func makeNSView(context: Context) -> CatcherView { CatcherView() }

	func updateNSView(_ view: CatcherView, context: Context) {
		view.action = action
	}

	final class CatcherView: NSView {
		var action: () -> Void = {}

		override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
		override func mouseDown(with event: NSEvent) { action() }
	}
}

private struct VaultSettingsMenuRow: View {
	let category: VaultSettingsCategory
	let selected: Bool
	let action: () -> Void

	@State private var hovering = false

	var body: some View {
		Button(action: action) {
			HStack(spacing: 9) {
				Image(systemName: category.systemImage)
					.font(.system(size: 12.5))
					.foregroundStyle(selected ? VaultPalette.accentForeground : VaultPalette.textTertiary)
					.frame(width: 16)
					.accessibilityHidden(true)
				Text(category.title)
					.font(.system(size: 13, weight: selected ? .semibold : .regular))
					.foregroundStyle(VaultPalette.textPrimary)
					.lineLimit(1)
				Spacer(minLength: 0)
			}
			.padding(.horizontal, 9)
			.frame(height: 30)
			.background(RoundedRectangle(cornerRadius: 7).fill(selected ? VaultPalette.sidebarSelection : (hovering ? VaultPalette.sidebarHover : .clear)))
			.contentShape(Rectangle())
			.vaultHoverAnimation(hovering)
		}
		.buttonStyle(VaultPressStyle())
		.onHover { hovering = $0 }
		.accessibilityAddTraits(selected ? .isSelected : [])
	}
}
