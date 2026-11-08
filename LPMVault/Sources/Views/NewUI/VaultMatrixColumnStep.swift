import AppKit
import SwiftUI

/// At an edge of the matrix's header, names the environment columns out of
/// view on that side and brings the nearest one whole into view. With room it
/// names the nearest; without, it shows their colors, as the sidebar lists them.
struct VaultColumnStepButton: View {
	enum Direction {
		/// Columns scrolled under the key column.
		case before
		/// Columns past the view's trailing edge.
		case after
	}

	let direction: Direction
	/// The environments out of view on this side, nearest first.
	let environments: [(name: String, color: Color)]
	/// The width the control can take without covering a column's title.
	let room: CGFloat
	let action: () -> Void

	@Environment(\.accessibilityReduceMotion) private var reduceMotion
	@State private var hovering = false

	/// Where an environment column's title starts in its header cell: the cell's inset, its swatch and the gap after it.
	static let titleInset: CGFloat = 12 + 7 + 7
	/// The key column header's own content: its inset, title, gap and sort arrow.
	static var keyHeaderWidth: CGFloat { 20 + headerTitleWidth("Key") + 6 + 9 }

	/// A column title's width in the header's font.
	static func headerTitleWidth(_ title: String) -> CGFloat {
		ceil((title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold)]).width)
	}

	private static let nameFont = NSFont.systemFont(ofSize: 11.5, weight: .medium)
	private static let swatch: CGFloat = 7
	private static let spacing: CGFloat = 5
	private static let chevron: CGFloat = 7
	private static let inset: CGFloat = 8

	/// The width of the control naming `name`.
	static func namedWidth(_ name: String) -> CGFloat {
		let text = ceil((name as NSString).size(withAttributes: [.font: nameFont]).width)
		return inset * 2 + swatch + spacing + text + spacing + chevron
	}

	private var nearest: String { environments.first?.name ?? "" }
	private var named: Bool { room >= Self.namedWidth(nearest) }

	var body: some View {
		Button(action: action) {
			HStack(spacing: Self.spacing) {
				if direction == .before { chevron }
				if named {
					VaultEnvSwatch(color: environments.first?.color ?? VaultPalette.textFaint, size: Self.swatch)
					Text(nearest)
						.font(.system(size: 11.5, weight: .medium))
						.foregroundStyle(VaultPalette.textSecondary)
						.lineLimit(1)
						.fixedSize()
				} else {
					HStack(spacing: 3) {
						ForEach(Array(environments.prefix(3).enumerated()), id: \.offset) { _, environment in
							VaultEnvSwatch(color: environment.color, size: Self.swatch)
						}
					}
				}
				if direction == .after { chevron }
			}
			.padding(.horizontal, Self.inset)
			.frame(height: 22)
			.background {
				RoundedRectangle(cornerRadius: 6, style: .continuous)
					.fill(hovering ? VaultPalette.controlHover : VaultPalette.control)
			}
			.overlay {
				RoundedRectangle(cornerRadius: 6, style: .continuous)
					.strokeBorder(VaultPalette.border, lineWidth: 1)
			}
			.contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
		}
		.buttonStyle(.plain)
		.onHover { hovering = $0 }
		.animation(reduceMotion ? nil : VaultMotion.quick, value: hovering)
		.help(help)
		.accessibilityLabel("Show \(nearest)")
	}

	private var chevron: some View {
		Image(systemName: direction == .after ? "chevron.right" : "chevron.left")
			.font(.system(size: 9, weight: .semibold))
			.foregroundStyle(VaultPalette.textTertiary)
			.frame(width: Self.chevron)
			.accessibilityHidden(true)
	}

	private var help: String {
		guard environments.count > 1 else { return "Scroll to \(nearest)" }
		return "Scroll to \(nearest), the nearest of \(environments.count) environments out of view"
	}
}

/// Where a scroll view is asked to scroll sideways. Each request is a new
/// one, even to the same place, so a step after a person scrolled away still moves.
struct VaultHorizontalScrollTarget: Equatable {
	private(set) var x: CGFloat = 0
	private(set) var serial = 0

	mutating func scroll(to x: CGFloat) {
		self.x = x
		serial += 1
	}
}

/// Scrolls the scroll view it sits in sideways to each new target, keeping
/// its vertical position: eased over a few frames, or at once under Reduce
/// Motion. Each frame scrolls the clip view as a person's scroll does, so the
/// scroll view sees every step; a scroll by the person meanwhile ends it.
struct VaultHorizontalScroller: NSViewRepresentable {
	let target: VaultHorizontalScrollTarget

	func makeNSView(context: Context) -> ScrollerView { ScrollerView() }

	func updateNSView(_ view: ScrollerView, context: Context) {
		view.scroll(to: target)
	}

	static func dismantleNSView(_ view: ScrollerView, coordinator: ()) {
		view.stop()
	}

	final class ScrollerView: NSView {
		static let duration: CFTimeInterval = 0.22

		private var serial = 0
		private var link: CADisplayLink?
		private var step: (from: CGFloat, to: CGFloat, start: CFTimeInterval?, last: CGFloat)?

		override func hitTest(_ point: NSPoint) -> NSView? { nil }

		override func viewDidMoveToWindow() {
			super.viewDidMoveToWindow()
			if window == nil { stop() }
		}

		func scroll(to target: VaultHorizontalScrollTarget) {
			guard target.serial != serial else { return }
			serial = target.serial
			guard let clip = enclosingScrollView?.contentView else { return }
			var bounds = clip.bounds
			bounds.origin.x = target.x
			let destination = clip.constrainBoundsRect(bounds).origin.x
			stop()
			guard destination != clip.bounds.origin.x else { return }
			guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, window != nil else {
				move(to: destination)
				return
			}
			step = (clip.bounds.origin.x, destination, nil, clip.bounds.origin.x)
			let link = displayLink(target: self, selector: #selector(advance))
			link.add(to: .main, forMode: .common)
			self.link = link
		}

		func stop() {
			link?.invalidate()
			link = nil
			step = nil
		}

		@objc private func advance(_ link: CADisplayLink) {
			guard var step, let clip = enclosingScrollView?.contentView else { return stop() }
			// The person scrolled meanwhile: theirs wins.
			guard abs(clip.bounds.origin.x - step.last) < 0.5 else { return stop() }
			let start = step.start ?? link.timestamp
			let progress = min(1, (link.targetTimestamp - start) / Self.duration)
			let eased = 1 - pow(1 - progress, 3)
			step.start = start
			step.last = move(to: step.from + (step.to - step.from) * eased)
			self.step = step
			if progress >= 1 { stop() }
		}

		/// Scrolls to `x`, keeping the vertical position; returns where it got to.
		@discardableResult
		private func move(to x: CGFloat) -> CGFloat {
			guard let scrollView = enclosingScrollView else { return x }
			let clip = scrollView.contentView
			var bounds = clip.bounds
			bounds.origin.x = x
			let origin = clip.constrainBoundsRect(bounds).origin
			clip.scroll(to: origin)
			scrollView.reflectScrolledClipView(clip)
			return origin.x
		}
	}
}
