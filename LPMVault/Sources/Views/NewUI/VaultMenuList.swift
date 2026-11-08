import SwiftUI

/// A menu's choices in a popover, drawn as the app's other lists are: the row
/// under the pointer or the arrow keys tinted, a title on the leading side and
/// what it needs, or its shortcut, on the trailing side, grouped under
/// section labels. Return chooses the tinted row and Esc closes the popover.
struct VaultMenuList<ID: Hashable>: View {
	struct Row: Identifiable {
		let id: ID
		let title: String
		/// What the row needs or does, or its shortcut, on its trailing side.
		var detail: String?
		/// Shows `detail` as a shortcut, in the system font's even digits.
		var detailIsShortcut = false
		var isEnabled = true
		/// The section label the row starts, when it starts one.
		var section: String?
	}

	let rows: [Row]
	var width: CGFloat = 240
	/// Lays the sections out side by side, so a long menu shows whole rather
	/// than scrolling. The arrow keys still go through the rows in reading order.
	var columns = 1
	/// The rows show this tall at most, then scroll, as a long menu does.
	var maximumHeight: CGFloat = 420
	/// What VoiceOver calls the menu.
	let label: String
	let onChoose: (ID) -> Void

	@Environment(\.vaultPopoverDismiss) private var dismiss
	@State private var highlighted: ID?

	var body: some View {
		let columnRows = Self.columns(of: rows, count: columns)
		let list = HStack(alignment: .top, spacing: 6) {
			ForEach(columnRows.indices, id: \.self) { index in
				VStack(alignment: .leading, spacing: 1) {
					ForEach(columnRows[index]) { row in
						if let section = row.section {
							Text(section)
								.vaultSectionLabel()
								.padding(.horizontal, 10)
								.padding(.top, row.id == columnRows[index].first?.id ? 4 : 10)
								.padding(.bottom, 3)
								.accessibilityAddTraits(.isHeader)
						}
						rowView(row)
					}
				}
				.frame(maxWidth: .infinity, alignment: .topLeading)
			}
		}
		.padding(6)
		CappedHeight(maximum: maximumHeight) {
			ViewThatFits(in: .vertical) {
				list
				ScrollViewReader { proxy in
					ScrollView { list }
						.onChange(of: highlighted) { _, id in
							if let id { proxy.scrollTo(id) }
						}
				}
			}
		}
		.frame(width: width)
		.background {
			VaultMenuKeys { key in
				switch key {
				case .up: highlighted = Self.row(after: highlighted, by: -1, in: rows)
				case .down: highlighted = Self.row(after: highlighted, by: 1, in: rows)
				case .open:
					guard let highlighted else { return false }
					onChoose(highlighted)
				case .close: dismiss()
				}
				return true
			}
		}
		.accessibilityElement(children: .contain)
		.accessibilityLabel(label)
	}

	private func rowView(_ row: Row) -> some View {
		let isHighlighted = highlighted == row.id && row.isEnabled
		return Button { onChoose(row.id) } label: {
			HStack(spacing: 10) {
				Text(row.title)
					.font(.system(size: 12.5))
					.foregroundStyle(row.isEnabled ? VaultPalette.textPrimary : VaultPalette.textFaint)
					.lineLimit(1)
				Spacer(minLength: 12)
				if let detail = row.detail {
					Text(detail)
						.font(row.detailIsShortcut ? VaultTypography.tabular(11.5) : .system(size: 11))
						.foregroundStyle(row.isEnabled ? VaultPalette.textTertiary : VaultPalette.textFaint)
						.lineLimit(1)
				}
			}
			.padding(.horizontal, 10)
			.frame(height: 28)
			.background(RoundedRectangle(cornerRadius: 6).fill(isHighlighted ? VaultPalette.menuHighlight : .clear))
			.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		// The arrow keys move the tint, so a row needs no focus ring of its own.
		.focusEffectDisabled()
		.disabled(!row.isEnabled)
		.onHover { inside in
			if inside, row.isEnabled {
				highlighted = row.id
			} else if highlighted == row.id {
				highlighted = nil
			}
		}
		.id(row.id)
		.accessibilityLabel(row.title)
		.accessibilityHint(row.detail ?? "")
		.accessibilityAddTraits(isHighlighted ? .isSelected : [])
	}

	/// `rows` split into at most `count` columns at section starts, keeping
	/// their order down and then across, so that the tallest column, counting
	/// a section's label as a row, is as short as it can be.
	static func columns(of rows: [Row], count: Int) -> [[Row]] {
		guard count > 1, !rows.isEmpty else { return [rows] }
		var sections: [[Row]] = []
		for row in rows {
			if row.section != nil || sections.isEmpty { sections.append([row]) } else { sections[sections.count - 1].append(row) }
		}
		let heights = sections.map { $0.count + ($0.first?.section == nil ? 0 : 1) }
		// The shortest tallest column for the sections from `start` in `columns` columns, and where each begins.
		func best(from start: Int, columns: Int) -> (tallest: Int, starts: [Int]) {
			let rest = heights[start...].reduce(0, +)
			guard columns > 1, start < sections.count - 1 else { return (rest, [start]) }
			var choice = (tallest: rest, starts: [start])
			var first = 0
			for end in start..<(sections.count - 1) {
				first += heights[end]
				let after = best(from: end + 1, columns: columns - 1)
				let tallest = max(first, after.tallest)
				if tallest < choice.tallest { choice = (tallest, [start] + after.starts) }
			}
			return choice
		}
		let starts = best(from: 0, columns: count).starts
		return starts.indices.map { index in
			let end = index + 1 < starts.count ? starts[index + 1] : sections.count
			return sections[starts[index]..<end].flatMap { $0 }
		}
	}

	/// The enabled row a step up or down from `current`, around from either end, as in a menu.
	static func row(after current: ID?, by step: Int, in rows: [Row]) -> ID? {
		let enabled = rows.filter(\.isEnabled).map(\.id)
		guard !enabled.isEmpty else { return nil }
		guard let current, let index = enabled.firstIndex(of: current) else { return step > 0 ? enabled.first : enabled.last }
		return enabled[(index + step % enabled.count + enabled.count) % enabled.count]
	}
}
