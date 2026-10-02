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
		let dividers = VaultMetrics.paneDivider * (showsInspector ? 2 : 1)
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

	/// Center of the hairline on the sidebar's trailing edge.
	var sidebarDividerCenter: CGFloat {
		sidebar.width + VaultMetrics.paneDivider / 2
	}

	/// Center of the hairline on the inspector's leading edge.
	var inspectorDividerCenter: CGFloat {
		sidebar.width + VaultMetrics.paneDivider + content + VaultMetrics.paneDivider / 2
	}

	static func clamp(_ candidate: CGFloat, minimum: CGFloat, maximum: CGFloat) -> CGFloat {
		min(max(minimum, maximum), max(minimum, candidate))
	}
}

enum VaultPaneEdge {
	case leading
	case trailing

	var dragDirection: CGFloat {
		switch self {
		case .leading: -1
		case .trailing: 1
		}
	}
}

/// A side pane with its hairline on the edge facing the content. Resizing is
/// handled by a ``VaultPaneResizeHandle`` drawn above the whole workspace.
struct VaultResizablePane<Content: View>: View {
	let width: CGFloat
	let edge: VaultPaneEdge
	let content: Content

	init(width: CGFloat, edge: VaultPaneEdge, @ViewBuilder content: () -> Content) {
		self.width = width
		self.edge = edge
		self.content = content()
	}

	var body: some View {
		HStack(spacing: 0) {
			if edge == .leading { hairline }
			content
				.frame(width: width)
				.clipped()
			if edge == .trailing { hairline }
		}
		.frame(width: width + VaultMetrics.paneDivider)
	}

	private var hairline: some View {
		VaultHairline(color: VaultPalette.sidebarBorder, axis: .vertical)
			.frame(width: VaultMetrics.paneDivider)
	}
}

/// Pointer and accessibility target for resizing a pane. It must be laid out
/// above every pane: AppKit only routes clicks to it where no later sibling
/// view covers it, and its target reaches into both neighbors of the hairline.
struct VaultPaneResizeHandle: View {
	@Binding var width: CGFloat
	let bounds: VaultPaneBounds
	let edge: VaultPaneEdge
	let accessibilityLabel: String
	let onResize: () -> Void

	@State private var dragStartWidth: CGFloat?

	var body: some View {
		VaultResizeTrackingArea(
			label: accessibilityLabel,
			width: bounds.width,
			onAdjust: { adjustment in
				commit(clamp(bounds.width + adjustment))
			},
			onDragChanged: { translation in
				let start = dragStartWidth ?? bounds.width
				dragStartWidth = start
				commit(clamp(start + edge.dragDirection * translation))
			},
			onDragEnded: { translation in
				let start = dragStartWidth ?? bounds.width
				dragStartWidth = nil
				commit(clamp(start + edge.dragDirection * translation))
			}
		)
		.frame(width: VaultMetrics.paneDividerHitWidth)
	}

	private func commit(_ candidate: CGFloat) {
		defer { onResize() }
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
