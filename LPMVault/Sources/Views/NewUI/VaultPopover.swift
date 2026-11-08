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
}

/// Sits behind the view a popover is shown for, so the popover knows where it is.
private struct VaultPopoverAnchor<Content: View>: NSViewRepresentable {
	@Binding var isPresented: Bool
	let edge: Edge
	let content: () -> Content

	func makeCoordinator() -> VaultPopoverPresenter { VaultPopoverPresenter() }

	func makeNSView(context: Context) -> NSView { VaultPopoverAnchorView() }

	func updateNSView(_ view: NSView, context: Context) {
		let presenter = context.coordinator
		presenter.anchor = view
		presenter.edge = edge
		let binding = $isPresented
		presenter.onDismiss = { binding.wrappedValue = false }
		guard isPresented else {
			presenter.close()
			return
		}
		// The popover's window isn't under this view, so the view's environment goes with it;
		// the closing action is set inside it, where the whole environment doesn't replace it.
		presenter.show(AnyView(
			content()
				.environment(\.vaultPopoverDismiss, VaultPopoverDismissAction(presenter: presenter))
				.environment(\.self, context.environment)
		))
	}

	static func dismantleNSView(_ view: NSView, coordinator: VaultPopoverPresenter) {
		coordinator.close()
	}
}

private final class VaultPopoverAnchorView: NSView {
	override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The window a popover shows in. Its class name says Popover, as the
/// system's does, for whatever looks for one.
final class VaultPopoverPanel: NSPanel {
	var onCancel: () -> Void = {}

	override var canBecomeKey: Bool { true }
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
	var onDismiss: () -> Void = {}

	private var panel: VaultPopoverPanel?
	private var hosting: NSHostingView<AnyView>?
	private var monitor: Any?
	private var keyMonitor: Any?
	private var observers: [any NSObjectProtocol] = []
	private var size: CGSize = .zero

	/// How far a popover sits from the view it's shown for, and from the screen's edges.
	nonisolated static let gap: CGFloat = 6
	nonisolated static let screenMargin: CGFloat = 8

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
		self.panel = panel
		self.hosting = hosting
		resize(to: hosting.fittingSize)
		parent.addChildWindow(panel, ordered: .above)
		panel.makeKey()
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
		panel.orderOut(nil)
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

	private func resize(to newSize: CGSize) {
		guard let panel, let anchor, let window = anchor.window, newSize.width > 0, newSize.height > 0 else { return }
		size = newSize
		let anchorFrame = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
		let content = window.contentView.map { window.convertToScreen($0.convert($0.bounds, to: nil)) } ?? window.frame
		let frame = Self.frame(
			size: newSize,
			beside: anchorFrame,
			on: edge,
			window: Self.area(of: content, for: anchorFrame),
			screen: (window.screen ?? NSScreen.main)?.visibleFrame ?? .infinite
		)
		panel.setFrame(frame, display: true)
		panel.invalidateShadow()
	}

	/// The part of `window` a popover for `anchor` may cover: all of it but
	/// the app's title bar, which a popover from the content leaves clear.
	nonisolated static func area(of window: CGRect, for anchor: CGRect) -> CGRect {
		let content = window.divided(atDistance: VaultMetrics.titleBar, from: .maxYEdge).remainder
		return anchor.maxY <= content.maxY ? content : window
	}

	/// Where a popover of `size` goes beside `anchor`: on `edge`, or on the
	/// opposite edge when there's no room, inside `window` when either has
	/// room there and otherwise inside `screen`, as a menu goes past its
	/// window. Below or above, it starts at the anchor's leading edge, as a
	/// menu does; beside, it's centered on it.
	nonisolated static func frame(size: CGSize, beside anchor: CGRect, on edge: Edge, window: CGRect, screen: CGRect) -> CGRect {
		let screenBounds = screen.insetBy(dx: screenMargin, dy: screenMargin)
		for bounds in [window.intersection(screen).insetBy(dx: screenMargin, dy: screenMargin), screenBounds] {
			if let origin = origin(size: size, beside: anchor, on: edge, in: bounds) { return CGRect(origin: origin, size: size) }
		}
		// No room on either side: on `edge`, over the anchor if it must be, on the screen.
		var origin = switch edge {
		case .bottom: CGPoint(x: anchor.minX, y: anchor.minY - gap - size.height)
		case .top: CGPoint(x: anchor.minX, y: anchor.maxY + gap)
		case .leading: CGPoint(x: anchor.minX - gap - size.width, y: anchor.midY - size.height / 2)
		case .trailing: CGPoint(x: anchor.maxX + gap, y: anchor.midY - size.height / 2)
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
			return CGPoint(x: along(anchor.minX, from: bounds.minX, to: bounds.maxX - size.width), y: y)
		case .leading, .trailing:
			let before = anchor.minX - gap - size.width
			let after = anchor.maxX + gap
			let fitsBefore = before >= bounds.minX
			let fitsAfter = after + size.width <= bounds.maxX
			guard fitsBefore || fitsAfter else { return nil }
			let x = edge == .leading ? (fitsBefore ? before : after) : (fitsAfter ? after : before)
			return CGPoint(x: x, y: along(anchor.midY - size.height / 2, from: bounds.minY, to: bounds.maxY - size.height))
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
			.background(VaultPalette.control)
			.clipShape(RoundedRectangle(cornerRadius: 10))
			.overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(VaultPalette.border, lineWidth: 1) }
			.fixedSize()
			.onGeometryChange(for: CGSize.self) { $0.size } action: { onSize($0) }
	}
}
