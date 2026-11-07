import SwiftUI

/// An environment's name with its color, as history's rows and reviews show it.
struct VaultHistoryEnvironmentChip: View {
	let name: String
	let color: Color

	/// The environment's color in the project's order, or a neutral one for
	/// an environment that's gone.
	init(_ name: String, in ordered: [String]) {
		self.name = name
		color = ordered.firstIndex(of: name).map { VaultPalette.environment($0) } ?? VaultPalette.textTertiary
	}

	var body: some View {
		HStack(spacing: 5) {
			VaultEnvSwatch(color: color, size: 6)
			Text(VaultProject.displayName(for: name))
				.font(.system(size: 11, weight: .medium))
				.foregroundStyle(VaultPalette.textSecondary)
				.lineLimit(1)
				.truncationMode(.middle)
		}
		.padding(.horizontal, 6)
		.frame(height: 20)
		.background(RoundedRectangle(cornerRadius: 5).fill(VaultPalette.neutralTint))
		.fixedSize(horizontal: false, vertical: true)
	}
}

/// A value from history or a review: masked until revealed, "not set" when
/// the key had none, or why it isn't known.
struct VaultHistoryValueField: View {
	enum Content: Equatable {
		case hidden
		case shown(String)
		case absent
		case unknown(String)
	}

	let content: Content
	/// What the field holds, as VoiceOver names it: "Value of API_KEY now".
	let label: String

	private var isValue: Bool {
		switch content {
		case .hidden, .shown: true
		case .absent, .unknown: false
		}
	}

	var body: some View {
		Group {
			switch content {
			case .hidden:
				VaultValueText(text: VaultValueText.mask)
			case .shown(let value):
				VaultValueText(text: value.isEmpty ? "(empty)" : value, masked: false)
			case .absent:
				Text("not set").italic().foregroundStyle(VaultPalette.textTertiary)
			case .unknown(let reason):
				Text(reason).italic().foregroundStyle(VaultPalette.textTertiary)
			}
		}
		.font(.system(size: 12))
		.lineLimit(1)
		.truncationMode(.tail)
		.frame(maxWidth: .infinity, alignment: .leading)
		.padding(.horizontal, 8)
		.frame(height: 28)
		.background(RoundedRectangle(cornerRadius: 5).fill(isValue ? VaultPalette.control : .clear))
		.overlay {
			RoundedRectangle(cornerRadius: 5)
				.strokeBorder(VaultPalette.border, style: StrokeStyle(lineWidth: 1, dash: isValue ? [] : [3]))
		}
		.accessibilityElement(children: .ignore)
		.accessibilityLabel(label)
		.accessibilityValue(spoken)
	}

	private var spoken: String {
		switch content {
		case .hidden: "hidden"
		case .shown(let value): value.isEmpty ? "empty" : value
		case .absent: "not set"
		case .unknown(let reason): reason
		}
	}
}

/// A notice under a review's row: a warning, or information.
struct VaultHistoryNotice: View {
	let text: String
	var warns = true
	/// Drawn in a tinted box, for a notice that weighs on the decision.
	var boxed = false

	var body: some View {
		HStack(alignment: .firstTextBaseline, spacing: 6) {
			Image(systemName: warns ? "exclamationmark.triangle" : "info.circle")
				.font(.system(size: 11))
				.accessibilityHidden(true)
			Text(text)
				.font(.system(size: 11.5))
				.fixedSize(horizontal: false, vertical: true)
				.frame(maxWidth: .infinity, alignment: .leading)
		}
		.foregroundStyle(warns ? VaultPalette.orangeTintText : VaultPalette.textTertiary)
		.padding(boxed ? 10 : 0)
		.background { if boxed { RoundedRectangle(cornerRadius: 6).fill(VaultPalette.orangeTint) } }
		.accessibilityElement(children: .combine)
	}
}

/// What a rollback just applied left, with Undo for a short while, wherever
/// the project's values show: the History page, a key's inspector, the table.
struct VaultHistoryUndoToast: View {
	let store: VaultStore

	private var history: VaultLocalHistory { store.history }

	var body: some View {
		if let applied = history.applied, applied.projectID == store.selectedProjectId {
			VaultToast(hasButton: applied.undo == .available || applied.undo == .undoing) {
				switch applied.undo {
				case .available, .undoing:
					Image(systemName: "checkmark")
						.font(.system(size: 11, weight: .bold))
						.foregroundStyle(VaultPalette.toastConfirmation)
						.accessibilityHidden(true)
					Text(applied.keys == 0
						? (applied.isUndo ? "Undid the change" : "Rolled back")
						: "\(applied.isUndo ? "Undid" : "Rolled back") \(applied.keys.counted("key"))")
					Button {
						Task { await history.undoApplied() }
					} label: {
						Label(applied.undo == .undoing ? "Undoing…" : "Undo", systemImage: "arrow.uturn.backward")
							.font(.system(size: 12, weight: .semibold))
							.foregroundStyle(VaultPalette.toastAction)
					}
					.buttonStyle(.plain)
					.vaultPointingHand()
					.disabled(applied.undo == .undoing)
					.help(applied.isUndo ? "Put back what the undo replaced" : "Put back what the rollback replaced")
					Rectangle()
						.fill(VaultPalette.toastDivider)
						.frame(width: 1, height: 16)
						.accessibilityHidden(true)
					TimelineView(.periodic(from: applied.savedAt, by: 1)) { context in
						let left = max(0, VaultFeedbackTimer.undoSeconds - Int(context.date.timeIntervalSince(applied.savedAt)))
						Text("\(left)s")
							.font(VaultTypography.tabular(11))
							.foregroundStyle(VaultPalette.toastSecondaryText)
							.accessibilityLabel("\(left) seconds left to undo")
					}
				case .undone:
					Image(systemName: "arrow.uturn.backward")
						.font(.system(size: 11, weight: .bold))
						.foregroundStyle(VaultPalette.toastConfirmation)
						.accessibilityHidden(true)
					Text("Put the values back as they were")
				case .reviewing:
					Image(systemName: "exclamationmark.triangle.fill")
						.font(.system(size: 11, weight: .bold))
						.foregroundStyle(VaultPalette.orange)
						.accessibilityHidden(true)
					Text("Not everything can be put back exactly, so review the undo")
				case .failed(let message):
					Image(systemName: "exclamationmark.triangle.fill")
						.font(.system(size: 11, weight: .bold))
						.foregroundStyle(VaultPalette.orange)
						.accessibilityHidden(true)
					Text(message)
				}
			}
		}
	}
}
