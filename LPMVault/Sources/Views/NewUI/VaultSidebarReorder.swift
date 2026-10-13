import AppKit
import Observation
import SwiftUI

/// Drag-to-reorder for the sidebar's projects. The dragged project's group
/// lifts and follows the pointer, the projects it passes slide out of its way,
/// and a line marks where it will land. The pointer gesture drives all of this
/// state and ends it, so nothing outlives a drag.
@Observable
@MainActor
final class VaultSidebarReorder {
	/// The sidebar's visible list, which stays put while its content scrolls.
	nonisolated static let viewportSpace = "vault-sidebar-viewport"
	/// The column of project groups, which scrolls with the list.
	nonisolated static let contentSpace = "vault-sidebar-projects"
	nonisolated static let liftScale: CGFloat = 1.02
	nonisolated static let gripWidth: CGFloat = 10
	static let settle = Animation.easeOut(duration: 0.16)
	/// How close to the list's top or bottom edge a drag starts scrolling it.
	nonisolated static let autoscrollZone: CGFloat = 32
	/// Scroll speed, in points per second, with the pointer at or past an edge.
	nonisolated static let autoscrollSpeed: CGFloat = 640

	struct Lift: Equatable {
		let projectId: String
		/// The visible projects, in order, when the drag began.
		let order: [String]
		let from: Int
		fileprivate(set) var height: CGFloat
	}

	struct Move: Equatable {
		let projectId: String
		let targetId: String
		let placement: VaultProjectPlacement
	}

	private(set) var lift: Lift?
	/// Where the lifted project would land, as an index into `lift.order`.
	private(set) var target = 0
	/// How far the lifted group has moved from its place.
	private(set) var offset: CGFloat = 0
	/// Points per second to scroll the list by; negative scrolls toward the top.
	private(set) var autoscrollVelocity: CGFloat = 0

	@ObservationIgnored private(set) var frames: [String: CGRect] = [:]
	@ObservationIgnored private(set) var contentTop: CGFloat = 0
	@ObservationIgnored private(set) var viewportSize: CGSize = .zero
	@ObservationIgnored private var origin: CGFloat = 0
	@ObservationIgnored private var grab: CGFloat = 0
	@ObservationIgnored private var grabInViewport: CGFloat = 0
	@ObservationIgnored private var pointer: CGPoint = .zero
	@ObservationIgnored private var isCancelled = false

	/// Records where a project's group is laid out among the projects, or
	/// forgets it once the group leaves the list.
	func setFrame(_ frame: CGRect?, for projectId: String) {
		guard let frame else {
			frames[projectId] = nil
			return
		}
		frames[projectId] = frame
		guard var lift, lift.projectId == projectId else { return }
		// Keeps the lifted group under the pointer when something above it changes size.
		grab += frame.minY - origin
		origin = frame.minY
		if lift.height != frame.height {
			lift.height = frame.height
			self.lift = lift
		}
		update()
	}

	/// Records where the projects' top edge is in the visible list, which
	/// changes as it scrolls.
	func setContentTop(_ top: CGFloat) {
		guard contentTop != top else { return }
		contentTop = top
		update()
	}

	func setViewportSize(_ size: CGSize) {
		viewportSize = size
	}

	/// Follows a drag that began on `projectId`'s row. Points are in `viewportSpace`.
	func drag(_ projectId: String, in order: [String], from start: CGPoint, to location: CGPoint) {
		guard !isCancelled else { return }
		if lift?.projectId != projectId {
			guard let from = order.firstIndex(of: projectId), let frame = frames[projectId] else { return }
			origin = frame.minY
			grab = start.y - contentTop
			grabInViewport = start.y
			offset = 0
			target = from
			lift = Lift(projectId: projectId, order: order, from: from, height: frame.height)
		}
		pointer = location
		update()
	}

	/// Ends the drag and returns the move it asks for, if any.
	func finish() -> Move? {
		defer { end() }
		guard let lift, target != lift.from else { return nil }
		return Move(projectId: lift.projectId, targetId: lift.order[target],
			placement: target < lift.from ? .before : .after)
	}

	/// Drops the drag without moving anything and ignores the rest of the
	/// gesture. Returns whether there was a drag.
	@discardableResult
	func cancel() -> Bool {
		guard lift != nil else { return false }
		reset()
		isCancelled = true
		return true
	}

	/// Cancels the drag when the visible projects are no longer the ones it began with.
	func cancel(unlessShowing order: [String]) {
		if let lift, lift.order != order { cancel() }
	}

	/// Clears everything once the gesture is over, however it ended.
	func end() {
		reset()
		isCancelled = false
	}

	/// How far the project at `index` slides to make room for the lifted one.
	func shift(at index: Int) -> CGFloat {
		guard let lift, index != lift.from else { return 0 }
		if lift.from < target, index > lift.from, index <= target { return -lift.height }
		if target < lift.from, index >= target, index < lift.from { return lift.height }
		return 0
	}

	/// The edge of the project at `index` that the landing line marks, if any:
	/// the top of the one the lifted project would go before, or the bottom of
	/// the one it would go after.
	func landingEdge(at index: Int) -> VerticalEdge? {
		guard let lift, index == target, target != lift.from else { return nil }
		return target < lift.from ? .top : .bottom
	}

	/// Which projects draw over which: the lifted one over everything, and the
	/// one with the landing line, which straddles its edge, over its neighbors.
	func layer(at index: Int) -> Double {
		guard let lift else { return 0 }
		if index == lift.from { return 2 }
		return index == target ? 1 : 0
	}

	/// Where a group lands once its leading edge passes the middle of the
	/// groups it moves over. `frames` holds each group's place before the drag.
	nonisolated static func landing(from: Int, order: [String], frames: [String: CGRect],
		origin: CGFloat, height: CGFloat, offset: CGFloat) -> Int {
		var landing = from
		if offset < 0 {
			let top = origin + offset
			var index = from - 1
			while index >= 0, let frame = frames[order[index]], top < frame.midY {
				landing = index
				index -= 1
			}
		} else if offset > 0 {
			let bottom = origin + height + offset
			var index = from + 1
			while index < order.count, let frame = frames[order[index]], bottom > frame.midY {
				landing = index
				index += 1
			}
		}
		return landing
	}

	/// How fast to scroll for a pointer `pointerY` points below the list's top
	/// edge. Scrolling only goes the way the pointer has moved since `grabY`, so
	/// grabbing a row near an edge doesn't scroll the list from under it.
	nonisolated static func autoscrollVelocity(pointerY: CGFloat, grabY: CGFloat, viewportHeight: CGFloat) -> CGFloat {
		guard viewportHeight > 0 else { return 0 }
		let zone = min(autoscrollZone, viewportHeight / 4)
		if pointerY < zone, pointerY < grabY {
			return -autoscrollSpeed * min(1, (zone - pointerY) / zone)
		}
		if pointerY > viewportHeight - zone, pointerY > grabY {
			return autoscrollSpeed * min(1, (pointerY - viewportHeight + zone) / zone)
		}
		return 0
	}

	private func update() {
		guard let lift else { return }
		var moved = pointer.y - contentTop - grab
		if let first = lift.order.first.flatMap({ frames[$0] }) { moved = max(moved, first.minY - origin) }
		if let last = lift.order.last.flatMap({ frames[$0] }) { moved = min(moved, last.maxY - lift.height - origin) }
		if offset != moved { offset = moved }
		// Outside the sidebar the drag lands nowhere, and the list stays still.
		let inside = pointer.x >= 0 && pointer.x <= viewportSize.width
		let landing = inside
			? Self.landing(from: lift.from, order: lift.order, frames: frames, origin: origin, height: lift.height, offset: moved)
			: lift.from
		if target != landing { target = landing }
		let velocity = inside
			? Self.autoscrollVelocity(pointerY: pointer.y, grabY: grabInViewport, viewportHeight: viewportSize.height)
			: 0
		if autoscrollVelocity != velocity { autoscrollVelocity = velocity }
	}

	private func reset() {
		if lift != nil { lift = nil }
		if target != 0 { target = 0 }
		if offset != 0 { offset = 0 }
		if autoscrollVelocity != 0 { autoscrollVelocity = 0 }
	}
}

/// Scrolls the list it's placed in while a drag holds the pointer near the
/// list's top or bottom edge.
struct VaultSidebarAutoscroll: View {
	let reorder: VaultSidebarReorder

	var body: some View {
		Scroller(velocity: reorder.autoscrollVelocity)
	}

	private struct Scroller: NSViewRepresentable {
		let velocity: CGFloat

		func makeNSView(context: Context) -> ScrollerView { ScrollerView() }

		func updateNSView(_ view: ScrollerView, context: Context) {
			view.velocity = velocity
		}

		static func dismantleNSView(_ view: ScrollerView, coordinator: ()) {
			view.velocity = 0
		}
	}

	final class ScrollerView: NSView {
		var velocity: CGFloat = 0 {
			didSet { velocity == 0 ? stop() : start() }
		}
		var isScrolling: Bool { link != nil }
		private var link: CADisplayLink?
		private var lastFrame: CFTimeInterval?

		override func hitTest(_ point: NSPoint) -> NSView? { nil }

		override func viewDidMoveToWindow() {
			super.viewDidMoveToWindow()
			if window == nil { stop() } else if velocity != 0 { start() }
		}

		/// Scrolls the list by what `velocity` covers in `interval` seconds, up to its ends.
		func advance(by interval: CFTimeInterval) {
			guard let scrollView = enclosingScrollView, let document = scrollView.documentView else { return }
			let clip = scrollView.contentView
			var bounds = clip.bounds
			bounds.origin.y += velocity * interval * (document.isFlipped ? 1 : -1)
			let origin = clip.constrainBoundsRect(bounds).origin
			guard origin != clip.bounds.origin else { return }
			clip.scroll(to: origin)
			scrollView.reflectScrolledClipView(clip)
		}

		private func start() {
			guard link == nil, window != nil else { return }
			let link = displayLink(target: self, selector: #selector(step))
			link.add(to: .main, forMode: .common)
			self.link = link
		}

		private func stop() {
			link?.invalidate()
			link = nil
			lastFrame = nil
		}

		@objc private func step(_ link: CADisplayLink) {
			if let lastFrame { advance(by: link.timestamp - lastFrame) }
			lastFrame = link.timestamp
		}
	}
}

/// The sidebar's keys: ⌥↑ and ⌥↓ move the selected project, unless a text
/// field is being edited, and Esc cancels a drag. None applies while a sheet
/// is attached. Each action returns whether it did anything; when not, the
/// key goes on as usual.
struct VaultSidebarKeys: NSViewRepresentable {
	var move: (Int) -> Bool
	var cancelDrag: () -> Bool

	enum Key: Equatable, Sendable {
		case move(Int)
		case cancelDrag
	}

	/// The sidebar key a key press is, if any.
	nonisolated static func key(modifiers: NSEvent.ModifierFlags, keyCode: UInt16) -> Key? {
		switch (modifiers.intersection([.command, .option, .control, .shift]), keyCode) {
		case (.option, 126): .move(-1)
		case (.option, 125): .move(1)
		case ([], 53): .cancelDrag
		default: nil
		}
	}

	func makeNSView(context: Context) -> MonitorView { MonitorView() }

	func updateNSView(_ view: MonitorView, context: Context) {
		view.keys = self
	}

	final class MonitorView: NSView {
		var keys = VaultSidebarKeys(move: { _ in false }, cancelDrag: { false })
		private var monitor: Any?

		override func hitTest(_ point: NSPoint) -> NSView? { nil }

		override func viewDidMoveToWindow() {
			super.viewDidMoveToWindow()
			if let monitor {
				NSEvent.removeMonitor(monitor)
				self.monitor = nil
			}
			guard window != nil else { return }
			monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
				guard let key = VaultSidebarKeys.key(modifiers: event.modifierFlags, keyCode: event.keyCode) else { return event }
				let windowNumber = event.windowNumber
				let handled = MainActor.assumeIsolated { self?.handle(key, inWindow: windowNumber) ?? false }
				return handled ? nil : event
			}
		}

		private func handle(_ key: Key, inWindow windowNumber: Int) -> Bool {
			guard let window, window.windowNumber == windowNumber, window.attachedSheet == nil else { return false }
			switch key {
			case .cancelDrag:
				return keys.cancelDrag()
			case .move(let step):
				return window.firstResponder is NSText ? false : keys.move(step)
			}
		}
	}
}

/// The three bars that show a project can be dragged.
struct VaultSidebarGrip: View {
	let reorder: VaultSidebarReorder
	let projectId: String

	var body: some View {
		VStack(spacing: 2) {
			ForEach(0..<3, id: \.self) { _ in
				RoundedRectangle(cornerRadius: 1).frame(height: 2)
			}
		}
		.frame(width: VaultSidebarReorder.gripWidth)
		.foregroundStyle(VaultPalette.textTertiary)
		.opacity(reorder.lift?.projectId == projectId ? 1 : 0.45)
		.accessibilityHidden(true)
	}
}
