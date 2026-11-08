import SwiftUI

/// A view of a project's keys that need attention, which All variables shows filtered.
enum VaultSmartView: CaseIterable {
	/// Keys whose values differ between environments.
	case drift
	/// Keys an environment doesn't set.
	case missing
	/// Keys whose values fail their lpm.json rules.
	case invalid

	var filter: VaultWorkspaceFilter {
		switch self {
		case .drift: .drift
		case .missing: .missing
		case .invalid: .invalid
		}
	}

	/// The glyph that marks a key in this view, the same in the header, the
	/// tables and the status bar.
	var symbol: String {
		switch self {
		case .drift: "notequal"
		// A static mark: a dashed circle reads as something still loading.
		case .missing: "minus.circle"
		case .invalid: "xmark.circle.fill"
		}
	}

	/// Drift is often intended, so its glyph stays quiet; the others need fixing.
	var tint: Color {
		switch self {
		case .drift: VaultPalette.textTertiary
		case .missing: VaultPalette.warningMark
		case .invalid: VaultPalette.problemMark
		}
	}

	/// What the glyph means, for its tooltip and for accessibility.
	var meaning: String {
		switch self {
		case .drift: "Values differ"
		case .missing: "Missing in an environment"
		case .invalid: "Fails its lpm.json rules"
		}
	}

	fileprivate func title(_ count: Int) -> String {
		switch self {
		case .drift: "\(count) drifting"
		case .missing: "\(count) missing"
		case .invalid: "\(count) invalid"
		}
	}

	fileprivate var help: String {
		switch self {
		case .drift: "Show the keys whose values differ between environments"
		case .missing: "Show the keys an environment doesn't set"
		case .invalid: "Show the keys whose values fail their lpm.json rules"
		}
	}
}

/// How many keys each of a project's smart views shows.
struct VaultSmartViewCounts: Equatable {
	let drifting: Int
	let missing: Int
	/// Nil until the project's rules are read and its values checked.
	let invalid: Int?

	init(snapshot: VaultWorkspaceSnapshot, checks: VaultValueCheckPresentation) {
		drifting = snapshot.driftingKeyCount
		missing = snapshot.missingKeyCount
		invalid = checks.hasCheck ? checks.invalidKeys.count : nil
	}

	func count(of view: VaultSmartView) -> Int? {
		switch view {
		case .drift: drifting
		case .missing: missing
		case .invalid: invalid
		}
	}
}

/// A status bar's links to the project's smart views, each opening All
/// variables filtered to its keys. The counts are the project's on every
/// page, so a link's number is how many keys the view it opens lists.
struct VaultSmartViewLinks: View {
	let counts: VaultSmartViewCounts
	/// The smart view All variables shows now, which its link marks.
	var current: VaultWorkspaceFilter?
	/// Whose keys the counts are, said before them, such as "Project" below one environment.
	var scope: String?
	/// Shows only the counts, for a narrow status bar.
	var compact = false
	/// Views whose count the page already says in its own words, which the links leave out.
	var omitted: Set<VaultSmartView> = []
	let open: (VaultSmartView) -> Void

	var body: some View {
		HStack(spacing: 2) {
			if let scope {
				Text(scope)
					.font(.system(size: 11))
					.foregroundStyle(VaultPalette.textFaint)
					.padding(.trailing, 2)
					.accessibilityHidden(true)
			}
			ForEach(VaultSmartView.allCases, id: \.self) { view in
				if !omitted.contains(view), let count = counts.count(of: view) {
					VaultSmartViewLink(view: view, count: count, isCurrent: current == view.filter, compact: compact) { open(view) }
				}
			}
		}
		.fixedSize()
		.accessibilityElement(children: .contain)
		.accessibilityLabel(scope.map { "\($0) smart views" } ?? "Smart views")
	}
}

private struct VaultSmartViewLink: View {
	let view: VaultSmartView
	let count: Int
	let isCurrent: Bool
	let compact: Bool
	let action: () -> Void

	@State private var hovering = false

	private var foreground: Color {
		if view == .invalid, count > 0 { return VaultPalette.redText }
		return isCurrent || hovering ? VaultPalette.textPrimary : VaultPalette.textTertiary
	}

	private var indicator: some View {
		Image(systemName: view.symbol)
			.font(.system(size: 9.5, weight: .semibold))
			.foregroundStyle(view.tint)
			.accessibilityHidden(true)
	}

	var body: some View {
		Button(action: action) {
			HStack(spacing: 5) {
				indicator
				Text(compact ? "\(count)" : view.title(count))
					.font(VaultTypography.tabular(11, isCurrent ? .semibold : .regular))
			}
			.foregroundStyle(foreground)
			.padding(.horizontal, 6)
			.frame(height: 20)
			.background {
				RoundedRectangle(cornerRadius: 5)
					.fill(isCurrent ? VaultPalette.neutralTint : (hovering ? VaultPalette.headerHover : .clear))
			}
			.vaultHoverAnimation(hovering)
		}
		.buttonStyle(VaultPressStyle(cornerRadius: 5))
		.help(view.help)
		.accessibilityLabel(view.title(count))
		.accessibilityAddTraits(isCurrent ? .isSelected : [])
		.onHover { hovering = $0 }
		.vaultPointingHand()
	}
}
