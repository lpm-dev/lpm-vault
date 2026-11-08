import AppKit
import SwiftUI

extension View {
	/// Shows `content` in the app's popover, on `arrowEdge` of this view, as
	/// SwiftUI's `popover` does, drawn as the app's cards are rather than as
	/// a system popover: no arrow or material, and focus drawn the app's way.
	/// It closes on Esc, on a click outside it, or as the app or window loses
	/// the user's attention. Its content reads the closing action from
	/// `vaultPopoverDismiss`.
	func vaultPopover<Content: View>(
		isPresented: Binding<Bool>, arrowEdge: Edge = .bottom, @ViewBuilder content: @escaping () -> Content
	) -> some View {
		background(VaultPopoverAnchor(isPresented: isPresented, edge: arrowEdge, content: content))
	}

	/// Shows `content` beside this view once the pointer has rested on it for
	/// `delay`, as a tooltip or a hover card does: it never takes the keyboard
	/// or the pointer, and goes as the pointer leaves or anything is clicked.
	func vaultHoverPopover<Content: View>(
		delay: Duration = .milliseconds(600), arrowEdge: Edge, enabled: Bool = true, @ViewBuilder content: @escaping () -> Content
	) -> some View {
		modifier(VaultHoverPopover(delay: delay, edge: arrowEdge, enabled: enabled, popover: content))
	}

	/// A short tooltip in the app's popover, for a control that shows only an icon.
	func vaultTooltip(_ text: String, arrowEdge: Edge = .top) -> some View {
		vaultHoverPopover(delay: .milliseconds(450), arrowEdge: arrowEdge) {
			Text(text)
				.font(.system(size: 11.5))
				.foregroundStyle(VaultPalette.textPrimary)
				.padding(.horizontal, 9)
				.padding(.vertical, 5)
		}
	}

	/// Shows `content` for `item` while it isn't nil, as SwiftUI's `popover(item:)` does.
	func vaultPopover<Item: Identifiable, Content: View>(
		item: Binding<Item?>, arrowEdge: Edge = .bottom, @ViewBuilder content: @escaping (Item) -> Content
	) -> some View {
		vaultPopover(
			isPresented: Binding(get: { item.wrappedValue != nil }, set: { if !$0 { item.wrappedValue = nil } }),
			arrowEdge: arrowEdge
		) {
			if let value = item.wrappedValue { content(value) }
		}
	}
}

/// Closes the popover a view is in; does nothing outside one.
struct VaultPopoverDismissAction: Equatable {
	fileprivate weak var presenter: VaultPopoverPresenter?

	@MainActor
	func callAsFunction() {
		presenter?.dismiss()
	}

	static func == (lhs: Self, rhs: Self) -> Bool { lhs.presenter === rhs.presenter }
}

extension EnvironmentValues {
	@Entry var vaultPopoverDismiss = VaultPopoverDismissAction()
	/// The most height a popover has beside its view inside its window, which
	/// a long menu scrolls within rather than covering the title bar.
	@Entry var vaultPopoverRoom: CGFloat = .infinity
}

private struct VaultHoverPopover<PopoverContent: View>: ViewModifier {
	let delay: Duration
	let edge: Edge
	let enabled: Bool
	let popover: () -> PopoverContent

	@State private var shows = false
	@State private var pending: Task<Void, Never>?

	func body(content: Content) -> some View {
		content
			.onHover { inside in
				pending?.cancel()
				pending = nil
				guard inside, enabled else {
					shows = false
					return
				}
				pending = Task { @MainActor in
					try? await Task.sleep(for: delay)
					if !Task.isCancelled { shows = true }
				}
			}
			.onChange(of: enabled) { _, enabled in if !enabled { shows = false } }
			.onDisappear {
				pending?.cancel()
				shows = false
			}
			.background(VaultPopoverAnchor(isPresented: $shows, edge: edge, passive: true, content: popover))
	}
}

/// Sits behind the view a popover is shown for, so the popover knows where it is.
private struct VaultPopoverAnchor<Content: View>: NSViewRepresentable {
	@Binding var isPresented: Bool
	let edge: Edge
	/// Shown without taking the keyboard or the pointer, as a tooltip is.
	var passive = false
	let content: () -> Content

	func makeCoordinator() -> VaultPopoverPresenter { VaultPopoverPresenter() }

	func makeNSView(context: Context) -> NSView { VaultPopoverAnchorView() }

	func updateNSView(_ view: NSView, context: Context) {
		let presenter = context.coordinator
		presenter.anchor = view
		presenter.edge = edge
		presenter.passive = passive
		let binding = $isPresented
		presenter.onDismiss = { binding.wrappedValue = false }
		guard isPresented else {
			presenter.close()
			return
		}
		// The popover's window isn't under this view, so what its content reads of the view's environment goes with it.
		presenter.show(AnyView(
			content()
				.environment(\.vaultPopoverDismiss, VaultPopoverDismissAction(presenter: presenter))
				.environment(\.vaultPopoverRoom, presenter.room())
				.modifier(VaultPopoverInheritedEnvironment(environment: context.environment))
		))
	}

	static func dismantleNSView(_ view: NSView, coordinator: VaultPopoverPresenter) {
		coordinator.close()
	}
}

/// What a popover's content reads of the environment of the view it's shown
/// for. Not the whole environment: handed over whole, it kept every control in
/// the popover enabled, whatever a `.disabled` there said, so a menu row that
/// looked unavailable could still be chosen with VoiceOver.
private struct VaultPopoverInheritedEnvironment: ViewModifier {
	let environment: EnvironmentValues

	func body(content: Content) -> some View {
		content
			.environment(\.colorScheme, environment.colorScheme)
			.environment(\.locale, environment.locale)
			.environment(\.calendar, environment.calendar)
			.environment(\.timeZone, environment.timeZone)
			.environment(\.layoutDirection, environment.layoutDirection)
			.environment(\.dynamicTypeSize, environment.dynamicTypeSize)
			.environment(\.vaultClock, environment.vaultClock)
			.environment(\.vaultContentObscured, environment.vaultContentObscured)
			.environment(\.vaultCopyFeedbackTimer, environment.vaultCopyFeedbackTimer)
			.environment(\.vaultImportUndoTimer, environment.vaultImportUndoTimer)
			.environment(\.vaultEnvFileChooser, environment.vaultEnvFileChooser)
			.environment(\.vaultSchemaKeysSuspended, environment.vaultSchemaKeysSuspended)
	}
}

private final class VaultPopoverAnchorView: NSView {
	override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The window a popover shows in. Its class name says Popover, as the
/// system's does, for whatever looks for one.
final class VaultPopoverPanel: NSPanel {
	var onCancel: () -> Void = {}
	/// Shown without taking the keyboard, as a tooltip or hover card is.
	var isPassive = false
	/// Set as the popover starts to close, while it may still be fading out.
	private(set) var isClosing = false

	func beginClosing() { isClosing = true }

	override var canBecomeKey: Bool { !isPassive }
	override var canBecomeMain: Bool { false }

	override func cancelOperation(_ sender: Any?) {
		onCancel()
	}
}

/// Shows, places and closes one popover.
@MainActor
final class VaultPopoverPresenter: NSObject {
	weak var anchor: NSView?
	var edge: Edge = .bottom
	/// Shown without taking the keyboard or the pointer, and gone at any click.
	var passive = false
	var onDismiss: () -> Void = {}

	private var panel: VaultPopoverPanel?
	private var hosting: NSHostingView<AnyView>?
	private var monitor: Any?
	private var keyMonitor: Any?
	private var observers: [any NSObjectProtocol] = []
	private var size: CGSize = .zero

	/// How far a popover sits from the view it's shown for, and from the screen's and window's edges.
	nonisolated static let gap: CGFloat = 6
	nonisolated static let screenMargin: CGFloat = 8
	nonisolated static let windowMargin: CGFloat = 12

	func show(_ content: AnyView) {
		let root = AnyView(VaultPopoverCard(content: content) { [weak self] size in self?.resize(to: size) })
		if let hosting {
			hosting.rootView = root
			return
		}
		guard let anchor, let parent = anchor.window else { return }
		let hosting = NSHostingView(rootView: root)
		let panel = VaultPopoverPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
		panel.isOpaque = false
		panel.backgroundColor = .clear
		panel.hasShadow = true
		panel.isReleasedWhenClosed = false
		panel.hidesOnDeactivate = false
		panel.animationBehavior = .none
		panel.appearance = parent.effectiveAppearance
		panel.contentView = hosting
		panel.onCancel = { [weak self] in self?.dismiss() }
		panel.isPassive = passive
		// A passive one lets the pointer through, so it never covers what it describes.
		panel.ignoresMouseEvents = passive
		self.panel = panel
		self.hosting = hosting
		resize(to: hosting.fittingSize)
		parent.addChildWindow(panel, ordered: .above)
		if !passive { panel.makeKey() }
		if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
			panel.alphaValue = 0
			NSAnimationContext.runAnimationGroup { context in
				context.duration = 0.12
				panel.animator().alphaValue = 1
			}
		}
		watch(parent: parent)
	}

	/// Asks the view that shows the popover to stop, which closes it.
	func dismiss() {
		onDismiss()
		close()
	}

	func close() {
		guard let panel else { return }
		let hadKeys = panel.isKeyWindow
		if let monitor { NSEvent.removeMonitor(monitor) }
		monitor = nil
		if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
		keyMonitor = nil
		observers.forEach(NotificationCenter.default.removeObserver)
		observers.removeAll()
		let parent = panel.parent
		parent?.removeChildWindow(panel)
		panel.beginClosing()
		// It fades out as it faded in, unless Reduce Motion is on or its window is going; only its removal waits.
		if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || !panel.isVisible || parent?.isVisible != true {
			panel.orderOut(nil)
		} else {
			NSAnimationContext.runAnimationGroup { context in
				context.duration = 0.1
				panel.animator().alphaValue = 0
			} completionHandler: {
				MainActor.assumeIsolated { panel.orderOut(nil) }
			}
			// A fade can be cut short, as while the app is busy; the panel goes regardless.
			Task { @MainActor in
				try? await Task.sleep(for: .milliseconds(200))
				panel.orderOut(nil)
			}
		}
		self.panel = nil
		hosting = nil
		size = .zero
		// Keys go back to the window the popover was shown over, unless they've
		// gone elsewhere already, as to a popover opened in its place.
		if hadKeys, let parent, parent.isVisible { parent.makeKey() }
	}

	private func watch(parent: NSWindow) {
		monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
			MainActor.assumeIsolated { self?.closeIfOutside(event) }
			return event
		}
		// Esc closes it as a menu's does, whichever of it or its window has the keyboard: a
		// text field takes Esc for completion, so it wouldn't reach the popover's window.
		keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
			guard event.keyCode == 53, event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else { return event }
			let handled = MainActor.assumeIsolated { self?.closeOnEscape(event) ?? false }
			return handled ? nil : event
		}
		let endings: [(Notification.Name, NSObject?)] = [
			(NSApplication.didResignActiveNotification, nil),
			(NSWindow.willCloseNotification, parent),
			(NSWindow.willBeginSheetNotification, parent),
			(NSWindow.didMiniaturizeNotification, parent),
		]
		observers = endings.map { name, object in
			NotificationCenter.default.addObserver(forName: name, object: object, queue: nil) { [weak self] _ in
				MainActor.assumeIsolated { self?.dismiss() }
			}
		}
	}

	private func closeOnEscape(_ event: NSEvent) -> Bool {
		guard let panel, event.window === panel || (event.window === panel.parent && panel.parent?.attachedSheet == nil) else { return false }
		dismiss()
		return true
	}

	/// A click outside the popover closes it, and still does what it does there;
	/// a click on the view it's shown for is left to that view, which toggles it.
	private func closeIfOutside(_ event: NSEvent) {
		guard let panel else { return }
		// A tooltip or hover card goes at any click, on the view it's for too.
		if passive {
			dismiss()
			return
		}
		// A click in a popover shown from this one, such as a menu, is inside it.
		var window = event.window
		while let current = window {
			if current === panel { return }
			window = current.parent
		}
		if let anchor, let window = anchor.window, event.window === window,
			anchor.convert(anchor.bounds, to: nil).contains(event.locationInWindow)
		{
			return
		}
		dismiss()
	}

	/// Where the anchor is and the room around it, in screen coordinates.
	private func placement() -> (anchor: CGRect, window: CGRect, screen: CGRect)? {
		guard let anchor, let window = anchor.window else { return nil }
		let anchorFrame = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
		let content = window.contentView.map { window.convertToScreen($0.convert($0.bounds, to: nil)) } ?? window.frame
		return (anchorFrame, Self.area(of: content, for: anchorFrame), (window.screen ?? NSScreen.main)?.visibleFrame ?? .infinite)
	}

	/// The most height the popover has beside its anchor inside the window.
	func room() -> CGFloat {
		guard let placement = placement() else { return .infinity }
		return Self.room(beside: placement.anchor, on: edge, window: placement.window, screen: placement.screen)
	}

	private func resize(to newSize: CGSize) {
		guard let panel, let placement = placement(), newSize.width > 0, newSize.height > 0 else { return }
		size = newSize
		let frame = Self.frame(size: newSize, beside: placement.anchor, on: edge, window: placement.window, screen: placement.screen)
		panel.setFrame(frame, display: true)
		panel.invalidateShadow()
	}

	/// Below this, a window has too little room for a menu to be any use, so it uses the screen's, as a menu goes past its window.
	nonisolated static let minimumRoom: CGFloat = 200
	/// How far a popover beside its view rises above the view's top, so a
	/// menu's first row, inside the card's inset, sits level with the view.
	nonisolated static let besideLift: CGFloat = 6

	/// The most height a popover beside `anchor` has: the larger of the room
	/// below and above it, or the whole height beside it, inside `window`
	/// when that's enough to be of use and otherwise on `screen`.
	nonisolated static func room(beside anchor: CGRect, on edge: Edge, window: CGRect, screen: CGRect) -> CGFloat {
		func room(in bounds: CGRect) -> CGFloat? {
			guard !bounds.isNull, bounds.height.isFinite else { return nil }
			return switch edge {
			case .top, .bottom: max(anchor.minY - gap - bounds.minY, bounds.maxY - anchor.maxY - gap, 0)
			case .leading, .trailing: bounds.height
			}
		}
		let screenBounds = screen.insetBy(dx: screenMargin, dy: screenMargin)
		if let inWindow = room(in: window.insetBy(dx: windowMargin, dy: windowMargin).intersection(screenBounds)), inWindow >= minimumRoom {
			return inWindow
		}
		return room(in: screenBounds) ?? .infinity
	}

	/// The part of `window` a popover for `anchor` may cover: all of it but
	/// the app's title bar and the status bar along its bottom, which a popover
	/// from the content between them leaves clear.
	nonisolated static func area(of window: CGRect, for anchor: CGRect) -> CGRect {
		let belowTitleBar = window.divided(atDistance: VaultMetrics.titleBar, from: .maxYEdge).remainder
		guard anchor.maxY <= belowTitleBar.maxY else { return window }
		let content = belowTitleBar.divided(atDistance: VaultMetrics.statusBar, from: .minYEdge).remainder
		return anchor.minY >= content.minY ? content : belowTitleBar
	}

	/// Where a popover of `size` goes beside `anchor`: on `edge`, or on the
	/// opposite edge when there's no room, inside `window` when either has
	/// room there and otherwise inside `screen`, as a menu goes past its
	/// window. Below or above, it starts at the anchor's leading edge, as a
	/// menu does; beside, level with its top, as a submenu does.
	nonisolated static func frame(size: CGSize, beside anchor: CGRect, on edge: Edge, window: CGRect, screen: CGRect) -> CGRect {
		let screenBounds = screen.insetBy(dx: screenMargin, dy: screenMargin)
		for bounds in [window.insetBy(dx: windowMargin, dy: windowMargin).intersection(screenBounds), screenBounds] {
			if let origin = origin(size: size, beside: anchor, on: edge, in: bounds) { return CGRect(origin: origin, size: size) }
		}
		// No room on either side: on `edge`, over the anchor if it must be, on the screen.
		var origin = switch edge {
		case .bottom: CGPoint(x: anchor.minX, y: anchor.minY - gap - size.height)
		case .top: CGPoint(x: anchor.minX, y: anchor.maxY + gap)
		case .leading: CGPoint(x: anchor.minX - gap - size.width, y: anchor.maxY + besideLift - size.height)
		case .trailing: CGPoint(x: anchor.maxX + gap, y: anchor.maxY + besideLift - size.height)
		}
		if screenBounds.width.isFinite, screenBounds.height.isFinite {
			origin.x = min(max(origin.x, screenBounds.minX), screenBounds.maxX - size.width)
			origin.y = min(max(origin.y, screenBounds.minY), screenBounds.maxY - size.height)
		}
		return CGRect(origin: origin, size: size)
	}

	/// The popover's origin on `edge` of `anchor`, or on the opposite edge,
	/// kept inside `bounds` along the edge; nil when neither side has room.
	private nonisolated static func origin(size: CGSize, beside anchor: CGRect, on edge: Edge, in bounds: CGRect) -> CGPoint? {
		guard !bounds.isNull, size.width <= bounds.width, size.height <= bounds.height else { return nil }
		func along(_ value: CGFloat, from low: CGFloat, to high: CGFloat) -> CGFloat { min(max(value, low), high) }
		switch edge {
		case .bottom, .top:
			let below = anchor.minY - gap - size.height
			let above = anchor.maxY + gap
			let fitsBelow = below >= bounds.minY
			let fitsAbove = above + size.height <= bounds.maxY
			guard fitsBelow || fitsAbove else { return nil }
			let y = edge == .bottom ? (fitsBelow ? below : above) : (fitsAbove ? above : below)
			// From the anchor's leading edge, or hanging back from its trailing edge where that
			// runs out of room, as a menu near the screen's edge does.
			let x = anchor.minX + size.width <= bounds.maxX ? anchor.minX : anchor.maxX - size.width
			return CGPoint(x: along(x, from: bounds.minX, to: bounds.maxX - size.width), y: y)
		case .leading, .trailing:
			let before = anchor.minX - gap - size.width
			let after = anchor.maxX + gap
			let fitsBefore = before >= bounds.minX
			let fitsAfter = after + size.width <= bounds.maxX
			guard fitsBefore || fitsAfter else { return nil }
			let x = edge == .leading ? (fitsBefore ? before : after) : (fitsAfter ? after : before)
			return CGPoint(x: x, y: along(anchor.maxY + besideLift - size.height, from: bounds.minY, to: bounds.maxY - size.height))
		}
	}
}

/// A popover's card: the content on the control surface, edged and rounded
/// like the app's other floating surfaces, at its own ideal size.
private struct VaultPopoverCard: View {
	let content: AnyView
	let onSize: (CGSize) -> Void

	var body: some View {
		content
			.background(VaultPalette.popover)
			.clipShape(RoundedRectangle(cornerRadius: 10))
			.overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(VaultPalette.popoverBorder, lineWidth: 1) }
			.fixedSize()
			.onGeometryChange(for: CGSize.self) { $0.size } action: { onSize($0) }
	}
}
