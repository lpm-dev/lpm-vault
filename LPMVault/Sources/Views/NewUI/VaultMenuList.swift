import SwiftUI

extension View {
	/// Shows `rows` as a menu in the app's popover while `isPresented`, and
	/// closes it as a row is chosen, before `onChoose` runs.
	func vaultMenu<ID: Hashable>(
		isPresented: Binding<Bool>, rows: [VaultMenuList<ID>.Row], width: CGFloat = 240, label: String,
		arrowEdge: Edge = .bottom, onChoose: @escaping (ID) -> Void
	) -> some View {
		vaultPopover(isPresented: isPresented, arrowEdge: arrowEdge) {
			VaultMenuList(rows: rows, width: width, label: label) { id in
				isPresented.wrappedValue = false
				onChoose(id)
			}
		}
	}
}

/// A menu row as it's drawn: the row sets its own colors for every state.
private struct VaultMenuRowStyle: ButtonStyle {
	func makeBody(configuration: Configuration) -> some View {
		configuration.label
	}
}

/// The coordinate space a scrolling menu measures its rows in. Outside the
/// generic list, so a geometry reader's sendable closure can name it.
private let vaultMenuScrollSpace = "VaultMenuList.scroll"

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
		/// Starts a group without a label, after a line.
		var separated = false
		/// Marks the row as the current choice, as a menu of options does.
		var isChecked = false
		/// A symbol before the title.
		var systemImage: String?
		/// Draws the title in red, for a row that deletes or removes.
		var destructive = false
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
	@Environment(\.vaultPopoverRoom) private var room
	@State private var highlighted: ID?
	/// Where the rows sit in a menu that scrolls, against its visible height.
	@State private var scrolledFrame: CGRect = .zero
	@State private var visibleHeight: CGFloat = 0

	/// The strips above and below a menu that scrolls, which point to the rows past them.
	private static var scrollCue: CGFloat { 14 }

	var body: some View {
		let columnRows = Self.columns(of: rows, count: columns)
		// A menu of options keeps a column for the check, so titles line up whichever is chosen.
		let checks = rows.contains(where: \.isChecked)
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
						} else if row.separated, row.id != columnRows[index].first?.id {
							VaultHairline()
								.padding(.horizontal, 10)
								.padding(.vertical, 5)
								.accessibilityHidden(true)
						}
						rowView(row, checks: checks)
					}
				}
				.frame(maxWidth: .infinity, alignment: .topLeading)
			}
		}
		.padding(6)
		CappedHeight(maximum: min(maximumHeight, room)) {
			ViewThatFits(in: .vertical) {
				list
				// Its own strips, as a long menu's, so a row is never hidden under them.
				VStack(spacing: 0) {
					scrollCue(pointing: .top, shown: scrolledFrame.minY < -0.5)
					ScrollViewReader { proxy in
						ScrollView {
							list.onGeometryChange(for: CGRect.self) { $0.frame(in: .named(vaultMenuScrollSpace)) } action: { scrolledFrame = $0 }
						}
						.coordinateSpace(name: vaultMenuScrollSpace)
						.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { visibleHeight = $0 }
						.onChange(of: highlighted) { _, id in
							if let id { proxy.scrollTo(id) }
						}
					}
					scrollCue(pointing: .bottom, shown: scrolledFrame.maxY > visibleHeight + 0.5)
				}
			}
		}
		.frame(width: width)
		.background {
			// Through the binding, so keys pressed in quick succession each see the last one's row.
			let highlight = $highlighted
			VaultMenuKeys { key in
				switch key {
				case .up: highlight.wrappedValue = Self.row(after: highlight.wrappedValue, by: -1, in: rows)
				case .down: highlight.wrappedValue = Self.row(after: highlight.wrappedValue, by: 1, in: rows)
				case .open:
					guard let chosen = highlight.wrappedValue else { return false }
					onChoose(chosen)
				case .close: dismiss()
				}
				return true
			}
		}
		.accessibilityElement(children: .contain)
		.accessibilityLabel(label)
	}

	private func scrollCue(pointing edge: VerticalEdge, shown: Bool) -> some View {
		Image(systemName: edge == .top ? "chevron.up" : "chevron.down")
			.font(.system(size: 8, weight: .bold))
			.foregroundStyle(VaultPalette.textTertiary)
			.opacity(shown ? 1 : 0)
			.frame(maxWidth: .infinity)
			.frame(height: Self.scrollCue)
			.accessibilityHidden(true)
	}

	private func rowView(_ row: Row, checks: Bool) -> some View {
		let isHighlighted = highlighted == row.id && row.isEnabled
		return Button { onChoose(row.id) } label: {
			HStack(spacing: 8) {
				if checks {
					Image(systemName: "checkmark")
						.font(.system(size: 10, weight: .semibold))
						.foregroundStyle(row.isChecked ? VaultPalette.textPrimary : .clear)
						.frame(width: 12)
						.accessibilityHidden(true)
				}
				if let systemImage = row.systemImage {
					Image(systemName: systemImage)
						.font(.system(size: 11))
						.foregroundStyle(row.isEnabled ? VaultPalette.textSecondary : VaultPalette.textFaint)
						.frame(width: 14)
						.accessibilityHidden(true)
				}
				Text(row.title)
					.font(.system(size: 12.5))
					.foregroundStyle(!row.isEnabled ? VaultPalette.textFaint : (row.destructive ? VaultPalette.redText : VaultPalette.textPrimary))
					.lineLimit(1)
				Spacer(minLength: 4)
				if let detail = row.detail {
					// The same strength on every row, undimmed: a row that can't be chosen says what it needs.
					Text(detail)
						.font(row.detailIsShortcut ? VaultTypography.tabular(11.5) : .system(size: 11))
						.foregroundStyle(VaultPalette.textTertiary)
						.lineLimit(1)
				}
			}
			.padding(.horizontal, 10)
			.frame(height: 28)
			.background(RoundedRectangle(cornerRadius: 6).fill(isHighlighted ? VaultPalette.menuHighlight : .clear))
			.contentShape(Rectangle())
		}
		// Draws the row as given, without the plain style's dimming of a disabled row's reason.
		.buttonStyle(VaultMenuRowStyle())
		// The menu owns the keyboard, as a menu does: the arrow keys move the tint and Tab
		// doesn't stop on each row, so a row needs no focus ring of its own.
		.focusable(false)
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
		.accessibilityAddTraits(row.isChecked ? .isSelected : [])
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
