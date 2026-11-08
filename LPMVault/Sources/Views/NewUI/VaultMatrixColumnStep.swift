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
/// its vertical position: eased, or at once under Reduce Motion.
struct VaultHorizontalScroller: NSViewRepresentable {
	let target: VaultHorizontalScrollTarget

	func makeNSView(context: Context) -> ScrollerView { ScrollerView() }

	func updateNSView(_ view: ScrollerView, context: Context) {
		view.scroll(to: target)
	}

	final class ScrollerView: NSView {
		private var serial = 0

		override func hitTest(_ point: NSPoint) -> NSView? { nil }

		func scroll(to target: VaultHorizontalScrollTarget) {
			guard target.serial != serial else { return }
			serial = target.serial
			guard let scrollView = enclosingScrollView else { return }
			let clip = scrollView.contentView
			var bounds = clip.bounds
			bounds.origin.x = target.x
			let origin = clip.constrainBoundsRect(bounds).origin
			guard origin != clip.bounds.origin else { return }
			if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
				clip.scroll(to: origin)
				scrollView.reflectScrolledClipView(clip)
				return
			}
			NSAnimationContext.runAnimationGroup { context in
				context.duration = 0.22
				context.timingFunction = CAMediaTimingFunction(name: .easeOut)
				clip.animator().setBoundsOrigin(origin)
			} completionHandler: {
				MainActor.assumeIsolated { scrollView.reflectScrolledClipView(clip) }
			}
		}
	}
}
