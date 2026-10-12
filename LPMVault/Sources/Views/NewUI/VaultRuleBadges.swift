import SwiftUI

/// One fact from a key's rules in lpm.json, such as "Required" or "0–10".
struct VaultRuleBadge: View {
	let badge: ProjectEnvSchemaOverview.Badge

	var body: some View {
		Text(badge.text)
			.font(.system(size: 11))
			.foregroundStyle(VaultPalette.textSecondary)
			.lineLimit(1)
			.padding(.horizontal, 7)
			.padding(.vertical, 3)
			.background(RoundedRectangle(cornerRadius: 5).fill(VaultPalette.neutralTint))
			.help(badge.help ?? badge.text)
			.accessibilityLabel(badge.help.map { "\(badge.text): \($0)" } ?? badge.text)
	}
}

/// The file an inherited rule comes from; dashed so it reads as a source, not a rule.
struct VaultSourceBadge: View {
	let source: String
	/// lpm.json overrides the rule `source` declares.
	var isOverridden = false

	var body: some View {
		Text(isOverridden ? "overrides \(source)" : source)
			.font(VaultTypography.mono(10.5))
			.foregroundStyle(VaultPalette.textTertiary)
			.lineLimit(1)
			.padding(.horizontal, 6)
			.padding(.vertical, 2)
			.overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(VaultPalette.textFaint, style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
			.help(isOverridden ? "lpm.json overrides the rule from \(source)" : "Inherited from \(source)")
			.accessibilityLabel(isOverridden ? "Overrides the rule from \(source)" : "Inherited from \(source)")
	}
}

/// Marks a key frameworks expose to the browser. Tables use the compact globe.
struct VaultPublicBadge: View {
	var compact = false

	var body: some View {
		HStack(spacing: 4) {
			Image(systemName: "globe").font(.system(size: compact ? 11 : 10, weight: .semibold))
			if !compact { Text("Public").font(.system(size: 11, weight: .medium)) }
		}
		.foregroundStyle(VaultPalette.publicText)
		.padding(.horizontal, compact ? 0 : 7)
		.padding(.vertical, compact ? 0 : 3)
		.background {
			if !compact { RoundedRectangle(cornerRadius: 5).fill(VaultPalette.publicTint) }
		}
		.help("Public: frameworks expose this key to the browser")
		.accessibilityElement(children: .ignore)
		.accessibilityLabel("Public")
	}
}

/// Places views in rows, wrapping to the next row when the width runs out.
struct VaultFlowLayout: Layout {
	var spacing: CGFloat = 6
	var lineSpacing: CGFloat = 6

	func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
		let rows = rows(for: subviews, width: proposal.width ?? .infinity)
		let width = rows.map(\.width).max() ?? 0
		let height = rows.reduce(0) { $0 + $1.height } + lineSpacing * CGFloat(max(rows.count - 1, 0))
		return CGSize(width: proposal.width.map { min($0, width) } ?? width, height: height)
	}

	func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
		var y = bounds.minY
		for row in rows(for: subviews, width: bounds.width) {
			var x = bounds.minX
			for item in row.items {
				subviews[item.index].place(at: CGPoint(x: x, y: y + (row.height - item.size.height) / 2),
					proposal: ProposedViewSize(item.size))
				x += item.size.width + spacing
			}
			y += row.height + lineSpacing
		}
	}

	private struct Row {
		struct Item {
			let index: Int
			let size: CGSize
		}
		var items: [Item] = []
		var width: CGFloat = 0
		var height: CGFloat = 0
	}

	private func rows(for subviews: Subviews, width: CGFloat) -> [Row] {
		let proposal = ProposedViewSize(width: width.isFinite ? max(0, width) : nil, height: nil)
		var rows: [Row] = []
		var row = Row()
		for index in subviews.indices {
			let size = subviews[index].sizeThatFits(proposal)
			let added = row.items.isEmpty ? size.width : row.width + spacing + size.width
			if !row.items.isEmpty, added > width {
				rows.append(row)
				row = Row()
			}
			row.width = row.items.isEmpty ? size.width : row.width + spacing + size.width
			row.height = max(row.height, size.height)
			row.items.append(.init(index: index, size: size))
		}
		if !row.items.isEmpty { rows.append(row) }
		return rows
	}
}
