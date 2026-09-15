import AppKit
import SwiftUI

struct VaultPaneBounds {
	var width: CGFloat
	var minimum: CGFloat
	var maximum: CGFloat
}

struct VaultPaneBudget {
	let sidebar: VaultPaneBounds
	let inspector: VaultPaneBounds
	let content: CGFloat

	init(
		available: CGFloat,
		requestedSidebar: CGFloat,
		requestedInspector: CGFloat,
		showsInspector: Bool
	) {
		let dividers = VaultMetrics.sidebarDivider
			+ (showsInspector ? VaultMetrics.inspectorDivider : 0)
		let usable = max(0, available - dividers)
		let minimums = VaultMetrics.sidebarMinimum
			+ (showsInspector ? VaultMetrics.inspectorMinimum : 0)
		let contentFloor = min(VaultMetrics.contentMinimum, max(0, usable - minimums))

		let inspectorRequest = showsInspector
			? Self.clamp(
				requestedInspector,
				minimum: VaultMetrics.inspectorMinimum,
				maximum: VaultMetrics.inspectorMaximum
			)
			: 0

		let sidebarCeiling = min(
			VaultMetrics.sidebarMaximum,
			max(VaultMetrics.sidebarMinimum, usable - contentFloor - inspectorRequest)
		)
		var sidebarBounds = VaultPaneBounds(
			width: Self.clamp(
				requestedSidebar,
				minimum: VaultMetrics.sidebarMinimum,
				maximum: sidebarCeiling
			),
			minimum: min(VaultMetrics.sidebarMinimum, sidebarCeiling),
			maximum: sidebarCeiling
		)

		var inspectorBounds = VaultPaneBounds(width: 0, minimum: 0, maximum: 0)
		if showsInspector {
			let ceiling = min(
				VaultMetrics.inspectorMaximum,
				max(VaultMetrics.inspectorMinimum, usable - contentFloor - sidebarBounds.width)
			)
			inspectorBounds = VaultPaneBounds(
				width: Self.clamp(
					requestedInspector,
					minimum: VaultMetrics.inspectorMinimum,
					maximum: ceiling
				),
				minimum: min(VaultMetrics.inspectorMinimum, ceiling),
				maximum: ceiling
			)
		}

		let requested = sidebarBounds.width + inspectorBounds.width
		if requested > usable, requested > 0 {
			let scale = usable / requested
			sidebarBounds.width *= scale
			sidebarBounds.minimum = min(sidebarBounds.minimum, sidebarBounds.width)
			sidebarBounds.maximum = sidebarBounds.width
			inspectorBounds.width *= scale
			inspectorBounds.minimum = min(inspectorBounds.minimum, inspectorBounds.width)
			inspectorBounds.maximum = inspectorBounds.width
		}

		sidebar = sidebarBounds
		inspector = inspectorBounds
		content = max(0, usable - sidebarBounds.width - inspectorBounds.width)
	}

	static func clamp(_ candidate: CGFloat, minimum: CGFloat, maximum: CGFloat) -> CGFloat {
		min(max(minimum, maximum), max(minimum, candidate))
	}
}

struct VaultResizablePane<Content: View>: View {
	enum Edge {
		case leading
		case trailing

		var dragDirection: CGFloat {
			switch self {
			case .leading: -1
			case .trailing: 1
			}
		}
	}

	@Binding var width: CGFloat
	let bounds: VaultPaneBounds
	let edge: Edge
	let dividerWidth: CGFloat
	let accessibilityLabel: String
	let onResize: () -> Void
	let content: Content

	@State private var dragStartWidth: CGFloat?

	init(
		width: Binding<CGFloat>,
		bounds: VaultPaneBounds,
		edge: Edge,
		dividerWidth: CGFloat,
		accessibilityLabel: String,
		onResize: @escaping () -> Void,
		@ViewBuilder content: () -> Content
	) {
		_width = width
		self.bounds = bounds
		self.edge = edge
		self.dividerWidth = dividerWidth
		self.accessibilityLabel = accessibilityLabel
		self.onResize = onResize
		self.content = content()
	}

	private var liveWidth: CGFloat {
		clamp(bounds.width)
	}

	var body: some View {
		HStack(spacing: 0) {
			if edge == .leading { divider }
			content
				.frame(width: liveWidth)
				.clipped()
			if edge == .trailing { divider }
		}
		.frame(width: liveWidth + dividerWidth)
	}

	private var divider: some View {
		ZStack {
			VaultHairline(color: VaultPalette.sidebarBorder, axis: .vertical)

			VaultResizeTrackingArea(
				label: accessibilityLabel,
				width: liveWidth,
				onAdjust: { adjustment in
					commit(clamp(bounds.width + adjustment))
					onResize()
				},
				onDragChanged: { translation in
					let start = dragStartWidth ?? bounds.width
					dragStartWidth = start
					commit(clamp(start + edge.dragDirection * translation))
					onResize()
				},
				onDragEnded: { translation in
					let start = dragStartWidth ?? bounds.width
					dragStartWidth = nil
					commit(clamp(start + edge.dragDirection * translation))
					onResize()
				}
			)
			.frame(maxWidth: .infinity, maxHeight: .infinity)
		}
		.frame(width: dividerWidth)
		.contentShape(Rectangle())
	}

	private func commit(_ candidate: CGFloat) {
		guard candidate != width else { return }
		var transaction = Transaction()
		transaction.animation = nil
		withTransaction(transaction) {
			width = candidate
		}
	}

	private func clamp(_ candidate: CGFloat) -> CGFloat {
		VaultPaneBudget.clamp(candidate, minimum: bounds.minimum, maximum: bounds.maximum)
	}
}

private struct VaultResizeTrackingArea: NSViewRepresentable {
	let label: String
	let width: CGFloat
	let onAdjust: (CGFloat) -> Void
	let onDragChanged: (CGFloat) -> Void
	let onDragEnded: (CGFloat) -> Void

	func makeNSView(context: Context) -> VaultResizeTrackingView {
		let view = VaultResizeTrackingView()
		view.setAccessibilityElement(true)
		view.setAccessibilityRole(.splitter)
		view.setAccessibilityOrientation(.vertical)
		return view
	}

	func updateNSView(_ nsView: VaultResizeTrackingView, context: Context) {
		nsView.setAccessibilityLabel(label)
		nsView.setAccessibilityValue("\(Int(width)) points")
		nsView.onAdjust = onAdjust
		nsView.onDragChanged = onDragChanged
		nsView.onDragEnded = onDragEnded
	}

	static func dismantleNSView(_ nsView: VaultResizeTrackingView, coordinator: ()) {
		nsView.onAdjust = nil
		nsView.onDragChanged = nil
		nsView.onDragEnded = nil
	}
}

final class VaultResizeTrackingView: NSView {
	var onAdjust: ((CGFloat) -> Void)?
	var onDragChanged: ((CGFloat) -> Void)?
	var onDragEnded: ((CGFloat) -> Void)?
	private var dragStartX: CGFloat?

	override func accessibilityPerformIncrement() -> Bool {
		guard let onAdjust else { return false }
		onAdjust(20)
		return true
	}

	override func accessibilityPerformDecrement() -> Bool {
		guard let onAdjust else { return false }
		onAdjust(-20)
		return true
	}

	override var acceptsFirstResponder: Bool { false }

	override func resetCursorRects() {
		super.resetCursorRects()
		addCursorRect(bounds, cursor: .resizeLeftRight)
	}

	override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
		true
	}

	override func mouseDown(with event: NSEvent) {
		dragStartX = currentMouseX(fallback: event)
	}

	override func mouseDragged(with event: NSEvent) {
		guard let dragStartX else { return }
		onDragChanged?(currentMouseX(fallback: event) - dragStartX)
	}

	override func mouseUp(with event: NSEvent) {
		guard let dragStartX else { return }
		let translation = currentMouseX(fallback: event) - dragStartX
		self.dragStartX = nil
		onDragEnded?(translation)
	}

	private func currentMouseX(fallback event: NSEvent) -> CGFloat {
		window?.mouseLocationOutsideOfEventStream.x ?? event.locationInWindow.x
	}
}
