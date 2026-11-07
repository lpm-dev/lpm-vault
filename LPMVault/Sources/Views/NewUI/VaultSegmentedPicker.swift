import AppKit
import SwiftUI

/// One of a few choices, in segments of one width: the selected one in the
/// tint every selected control in the app uses. A native segmented control
/// underneath takes clicks, the keyboard and accessibility, as VoiceOver and
/// Voice Control expect; this only draws over it.
struct VaultSegmentedPicker<Value: Hashable>: View {
	/// What VoiceOver calls the control.
	let title: String
	let options: [(value: Value, title: String)]
	@Binding var selection: Value

	@Environment(\.isEnabled) private var isEnabled

	private static var font: NSFont { .systemFont(ofSize: 12, weight: .semibold) }

	/// Wide enough for the longest title in the bolder selected weight, so selecting never moves a segment.
	private var segmentWidth: CGFloat {
		let widest = options.map { ($0.title as NSString).size(withAttributes: [.font: Self.font]).width }.max() ?? 0
		return ceil(widest) + 24
	}

	private var selectedIndex: Int? { options.firstIndex { $0.value == selection } }

	var body: some View {
		VaultNativeSegments(
			label: title,
			titles: options.map(\.title),
			selectedIndex: selectedIndex,
			onSelect: { index in if options.indices.contains(index) { selection = options[index].value } }
		)
		.frame(width: segmentWidth * CGFloat(options.count), height: 26)
		.overlay { look.allowsHitTesting(false).accessibilityHidden(true) }
	}

	private var look: some View {
		HStack(spacing: 0) {
			ForEach(Array(options.enumerated()), id: \.offset) { index, option in
				let selected = index == selectedIndex
				Text(option.title)
					.font(.system(size: 12, weight: selected ? .semibold : .regular))
					.foregroundStyle(selected ? VaultPalette.selectedText : VaultPalette.textSecondary)
					.lineLimit(1)
					.frame(maxWidth: .infinity, maxHeight: .infinity)
					.background {
						if selected {
							RoundedRectangle(cornerRadius: 5)
								.fill(VaultPalette.selectedFill)
								.overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(VaultPalette.selectedBorder, lineWidth: 1) }
								.padding(2)
						}
					}
			}
		}
		.background(RoundedRectangle(cornerRadius: 7).fill(VaultPalette.control))
		.overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(VaultPalette.border, lineWidth: 1) }
		.opacity(isEnabled ? 1 : 0.5)
	}
}

/// The native control under `VaultSegmentedPicker`, with segments of one width so they line up with what's drawn.
private struct VaultNativeSegments: NSViewRepresentable {
	let label: String
	let titles: [String]
	let selectedIndex: Int?
	let onSelect: (Int) -> Void

	func makeCoordinator() -> Coordinator { Coordinator(onSelect: onSelect) }

	func makeNSView(context: Context) -> NSSegmentedControl {
		let control = NSSegmentedControl(labels: titles, trackingMode: .selectOne,
			target: context.coordinator, action: #selector(Coordinator.changed(_:)))
		control.segmentDistribution = .fillEqually
		control.setContentHuggingPriority(.defaultLow, for: .horizontal)
		control.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
		update(control)
		return control
	}

	func updateNSView(_ control: NSSegmentedControl, context: Context) {
		context.coordinator.onSelect = onSelect
		if control.segmentCount != titles.count { control.segmentCount = titles.count }
		for (index, title) in titles.enumerated() where control.label(forSegment: index) != title {
			control.setLabel(title, forSegment: index)
		}
		update(control)
	}

	private func update(_ control: NSSegmentedControl) {
		let index = selectedIndex ?? -1
		if control.selectedSegment != index { control.selectedSegment = index }
		if control.accessibilityLabel() != label { control.setAccessibilityLabel(label) }
	}

	@MainActor
	final class Coordinator: NSObject {
		var onSelect: (Int) -> Void

		init(onSelect: @escaping (Int) -> Void) {
			self.onSelect = onSelect
		}

		@objc func changed(_ sender: NSSegmentedControl) {
			onSelect(sender.selectedSegment)
		}
	}
}
