import SwiftUI

/// A note under a review: a risk to weigh before publishing, or how the
/// platform uses what's sent.
struct PublishNote: Equatable, Sendable {
	enum Kind: Equatable, Sendable {
		case risk
		case info
	}

	let kind: Kind
	let symbol: String
	/// What the note is about, said first and in bold.
	let lead: String?
	let detail: String

	init(_ kind: Kind, _ symbol: String, lead: String? = nil, _ detail: String) {
		self.kind = kind
		self.symbol = symbol
		self.lead = lead
		self.detail = detail
	}

	/// The whole note, as it reads.
	var text: String { lead.map { "\($0) \(detail)" } ?? detail }
}

/// A review's notes, each beside its icon: orange for a risk, quiet for the rest.
struct PublishNoteList: View {
	let notes: [PublishNote]
	/// Why the review failed to change, said last and in red.
	var error: String?

	var body: some View {
		if !notes.isEmpty || error != nil {
			VStack(alignment: .leading, spacing: 10) {
				ForEach(Array(notes.enumerated()), id: \.offset) { _, note in
					let risk = note.kind == .risk
					row(symbol: note.symbol, tint: risk ? VaultPalette.orangeTintText : VaultPalette.textSecondary) {
						(note.lead.map { Text("\($0) ").fontWeight(.semibold) } ?? Text(verbatim: "")) + Text(note.detail)
					}
					.foregroundStyle(risk ? VaultPalette.textPrimary : VaultPalette.textSecondary)
				}
				if let error {
					row(symbol: "exclamationmark.octagon", tint: VaultPalette.redText) { Text(error) }
						.foregroundStyle(VaultPalette.redText)
				}
			}
			.padding(.horizontal, 4)
			.padding(.top, 2)
		}
	}

	private func row(symbol: String, tint: Color, @ViewBuilder text: () -> Text) -> some View {
		HStack(alignment: .firstTextBaseline, spacing: 10) {
			Image(systemName: symbol)
				.font(.system(size: 11.5, weight: .medium))
				.foregroundStyle(tint)
				.frame(width: 16)
				.accessibilityHidden(true)
			text()
				.font(.system(size: 12))
				.lineSpacing(2)
				.fixedSize(horizontal: false, vertical: true)
				.frame(maxWidth: .infinity, alignment: .leading)
		}
	}
}

/// Where a publish goes: the Vault project and environment, then the
/// platform's place and the account holding it. Each side's name keeps its
/// end when it's cut short, since names like a dated test project's differ
/// there; the whole of each line is in its tooltip.
struct PublishRoute: View {
	struct Side: Equatable {
		let title: String
		let detail: String
	}

	let source: Side
	let sourceIcon: ProjectIconAppearance
	let platform: PublishPlatform?
	let destination: Side
	/// Whether the platform's place is chosen yet.
	let isChosen: Bool
	/// The connection publishing there, as its tooltip names it.
	let connection: String?

	var body: some View {
		HStack(spacing: 12) {
			side(label: "FROM VAULT", side: source, titleColor: VaultPalette.textPrimary, help: [source.title, source.detail]) {
				if case .folder = sourceIcon {
					VaultAppMark(size: 22)
				} else {
					VaultProjectIconView(appearance: sourceIcon, size: 22).accessibilityHidden(true)
				}
			}
			Image(systemName: "arrow.right")
				.font(.system(size: 11, weight: .semibold))
				.foregroundStyle(VaultPalette.textTertiary)
				.frame(width: 28)
				.accessibilityHidden(true)
			side(
				label: "TO \(platform?.displayName.uppercased() ?? "PLATFORM")", side: destination,
				titleColor: isChosen ? VaultPalette.accentText : VaultPalette.textTertiary,
				help: [isChosen ? destination.title : nil, destination.detail, connection.map { "Through \($0)" }]
			) {
				if let platform {
					PlatformLogo(platform: platform, size: 22)
				} else {
					Image(systemName: "questionmark")
						.font(.system(size: 10, weight: .bold))
						.foregroundStyle(VaultPalette.textTertiary)
						.frame(width: 22, height: 22)
						.background(RoundedRectangle(cornerRadius: 6).fill(VaultPalette.neutralTint))
						.accessibilityHidden(true)
				}
			}
		}
		.padding(.horizontal, 14)
		.padding(.vertical, 12)
		.background(RoundedRectangle(cornerRadius: 10).fill(VaultPalette.headerRow))
		.overlay { RoundedRectangle(cornerRadius: 10).stroke(VaultPalette.border, lineWidth: 1) }
	}

	private func side(
		label: String, side: Side, titleColor: Color, help: [String?], @ViewBuilder mark: () -> some View
	) -> some View {
		VStack(alignment: .leading, spacing: 5) {
			Text(label).vaultSectionLabel().lineLimit(1)
			HStack(spacing: 8) {
				mark()
				VStack(alignment: .leading, spacing: 1) {
					Text(side.title)
						.font(VaultTypography.tabular(12.5, .semibold))
						.foregroundStyle(titleColor)
						.lineLimit(1)
						.truncationMode(.head)
					if !side.detail.isEmpty {
						Text(side.detail)
							.font(.system(size: 11.5))
							.foregroundStyle(VaultPalette.textTertiary)
							.lineLimit(1)
					}
				}
			}
		}
		.frame(maxWidth: .infinity, alignment: .leading)
		.contentShape(Rectangle())
		.accessibilityElement(children: .combine)
		.help(help.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n"))
	}
}

/// What publishing the chosen keys does, counted as the review's Planned Action column says it.
struct PublishSummaryPills: View {
	let summary: PublishPlan.Summary

	var body: some View {
		ViewThatFits(in: .horizontal) {
			pills(hidden: .labeled)
			pills(hidden: .iconOnly)
		}
	}

	private enum HiddenValues {
		case labeled
		case iconOnly
	}

	private func pills(hidden: HiddenValues) -> some View {
		HStack(spacing: 6) {
			ForEach(Self.pills(for: summary), id: \.text) { pill in
				VaultTagBadge(text: pill.text, foreground: pill.tone.foreground, background: pill.tone.background, size: 11)
			}
			Group {
				switch hidden {
				case .labeled:
					Label("Values hidden", systemImage: "lock")
				case .iconOnly:
					Image(systemName: "lock")
						.help("Values hidden")
						.accessibilityLabel("Values hidden")
				}
			}
			.font(.system(size: 11.5))
			.foregroundStyle(VaultPalette.textTertiary)
			.padding(.leading, 6)
		}
		.fixedSize()
	}

	struct Pill: Equatable {
		enum Tone: Equatable {
			case add, replace, blocked, quiet

			var foreground: Color {
				switch self {
				case .add: VaultPalette.greenTintText
				case .replace: VaultPalette.orangeTintText
				case .blocked: VaultPalette.redText
				case .quiet: VaultPalette.textTertiary
				}
			}

			var background: Color {
				switch self {
				case .add: VaultPalette.greenTint
				case .replace: VaultPalette.orangeTint
				case .blocked: VaultPalette.redTint
				case .quiet: VaultPalette.neutralTint
				}
			}
		}

		let text: String
		let tone: Tone
	}

	/// A pill for each action with keys, in the column's order: what's sent, then what isn't.
	static func pills(for summary: PublishPlan.Summary) -> [Pill] {
		[
			(summary.adding, "add", Pill.Tone.add),
			(summary.replacing, "replace", .replace),
			(summary.blocked, "can't publish", .blocked),
			(summary.upToDate, "up to date", .quiet),
			(summary.skipped, "skipped", .quiet),
		]
		.filter { $0.0 > 0 }
		.map { Pill(text: "\($0.0) \($0.1)", tone: $0.2) }
	}
}
