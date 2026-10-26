import SwiftUI

/// What a project's newer data, written by a newer LPM, means for this
/// version of LPM Vault, in words: nil when it means nothing to show.
struct CompanionStatePresentation: Equatable {
	enum Tone: Equatable {
		/// Newer data this version can't fully use; updating fixes it.
		case update
		/// Damaged data; repairing fixes it.
		case damaged
		/// A change to the data that couldn't be finished yet; trying again does.
		case interrupted
	}

	let tone: Tone
	let title: String
	let detail: String
	/// What Repair… runs, as the engine lists them; empty when nothing here repairs it.
	let repairs: [CompanionEngine.Assessment.Repair]
	/// The features a discard removes, when the marker names them.
	private let features: [String]

	/// `unfinished` is why an interrupted change couldn't be finished, when
	/// finishing it was tried.
	init?(_ state: CompanionEngine.Assessment, unfinished: String? = nil) {
		features = state.features.map(\.name)
		if state.needsResume {
			tone = .interrupted
			title = "This project’s newer data has an unfinished change"
			let why = unfinished.map { " It couldn’t be finished: \($0)." } ?? ""
			detail = "LPM Vault finishes it before anything else uses the project, so its values stay hidden until then.\(why)"
			repairs = []
		} else if !state.damage.isEmpty {
			tone = .damaged
			title = "This project’s newer data is damaged"
			let codes = Set(state.damage.map(\.code))
			let consequence = if !codes.isDisjoint(with: ["invalidMarker", "unfinishedChange"]) {
				"Its values stay hidden, and LPM won’t run it, until it’s repaired."
			} else if codes == ["access"] {
				"LPM won’t read it until they’re set again: choose its CLI approval again."
			} else {
				"LPM may refuse to use it until it’s repaired."
			}
			detail = "\(CompanionRefusal.describe(state.damage).capitalizingFirstLetter). \(consequence)"
			repairs = state.repairs
		} else if let unsupported = state.unsupported {
			tone = .update
			title = "This project uses data from a newer LPM"
			detail = CompanionRefusal.unsupported(
				feature: unsupported.feature, version: unsupported.version, level: unsupported.level
			).message
			repairs = []
		} else {
			return nil
		}
	}

	/// The question Repair… asks before it changes anything, saying what
	/// every repair does.
	func repairConfirmation(subject: VaultConfirmation.Subject, perform: @escaping () -> Void) -> VaultConfirmation {
		let message: String
		if repairs.contains(where: { $0.action == .discardProject }) {
			let what = features.isEmpty
				? "all of this project’s newer data on this Mac, such as personal overrides and local history"
				: "all of this project’s newer data on this Mac: \(ListFormatter.localizedString(byJoining: features.map(CompanionRefusal.describe(feature:))))"
			message = "Repairing discards \(what). Its values stay as they are."
		} else {
			let actions = repairs.compactMap { repair -> String? in
				switch repair.action {
				case .removeFeature: "removes \(CompanionRefusal.describe(feature: repair.feature ?? "")) from this project"
				case .removeUnlisted: "deletes the newer data no feature of this project uses"
				case .discardProject: nil
				}
			}
			message = "Repairing \(ListFormatter.localizedString(byJoining: actions)) on this Mac. Its values and other newer data stay as they are."
		}
		return VaultConfirmation(
			symbol: "wrench.and.screwdriver",
			title: "Repair this project’s newer data?",
			message: message,
			subject: subject,
			actions: [.init(title: "Repair", perform: perform)]
		)
	}
}

/// What finishing an interrupted change did to a project's newer data, in words.
struct CompanionNoticePresentation: Equatable {
	let text: String

	init(_ notice: CompanionEngine.Plan.Notice) {
		let unfinished = "which an earlier run left unfinished"
		text = switch notice.kind {
		case "deletion": "LPM Vault finished deleting this project’s newer data, \(unfinished)."
		case "discard": "LPM Vault finished discarding this project’s newer data, \(unfinished)."
		case "restoreUndone": "LPM Vault undid a restore of this project’s newer data that an earlier run left unfinished. Run the restore again."
		case "restore": "LPM Vault finished restoring this project’s newer data, \(unfinished)."
		case "featureRemoval" where !notice.features.isEmpty:
			"LPM Vault finished removing \(ListFormatter.localizedString(byJoining: notice.features.map(CompanionRefusal.describe(feature:)))) from this project’s newer data, \(unfinished)."
		default: "LPM Vault finished a change to this project’s newer data, \(unfinished)."
		}
	}
}

/// A banner saying what finishing an interrupted change did, until dismissed.
struct VaultCompanionNoticeBanner: View {
	let presentation: CompanionNoticePresentation
	let onDismiss: () -> Void

	var body: some View {
		VStack(spacing: 0) {
			HStack(spacing: 10) {
				Image(systemName: "checkmark.circle.fill")
					.font(.system(size: 11))
					.foregroundStyle(VaultPalette.orange)
					.accessibilityHidden(true)
				Text(presentation.text)
					.font(.system(size: 11.5))
					.foregroundStyle(VaultPalette.orangeTintText)
					.fixedSize(horizontal: false, vertical: true)
				Spacer(minLength: 12)
				VaultBarButton(title: "Dismiss", height: 24, action: onDismiss)
			}
			.padding(.horizontal, 16)
			.padding(.vertical, 8)
			.background(VaultPalette.orangeTint)
			VaultHairline(color: VaultPalette.titleBarBorder)
		}
	}
}

/// A banner over the workspace for a project whose newer data this version
/// of LPM Vault can't fully use, or that's damaged.
struct VaultCompanionBanner: View {
	let presentation: CompanionStatePresentation
	let isRepairing: Bool
	let isRetrying: Bool
	let onRepair: () -> Void
	let onRetry: () -> Void
	@Environment(UpdateChecker.self) private var updateChecker

	var body: some View {
		VStack(spacing: 0) {
			HStack(spacing: 10) {
				Image(systemName: symbol)
					.font(.system(size: 11))
					.foregroundStyle(presentation.tone == .damaged ? VaultPalette.red : VaultPalette.orange)
					.accessibilityHidden(true)
				VStack(alignment: .leading, spacing: 2) {
					Text(presentation.title)
						.font(.system(size: 12, weight: .semibold))
					Text(presentation.detail)
						.font(.system(size: 11.5))
						.fixedSize(horizontal: false, vertical: true)
				}
				.foregroundStyle(presentation.tone == .damaged ? VaultPalette.redText : VaultPalette.orangeTintText)
				.accessibilityElement(children: .combine)
				Spacer(minLength: 12)
				switch presentation.tone {
				case .damaged where !presentation.repairs.isEmpty:
					VaultBarButton(title: isRepairing ? "Repairing…" : "Repair…", filled: true, disabled: isRepairing, height: 24, action: onRepair)
				case .update:
					VaultBarButton(title: "Check for Updates…", disabled: !updateChecker.canCheckForUpdates, height: 24) {
						updateChecker.checkForUpdates()
					}
				case .interrupted:
					VaultBarButton(title: isRetrying ? "Trying…" : "Try Again", disabled: isRetrying, height: 24, action: onRetry)
				case .damaged:
					EmptyView()
				}
			}
			.padding(.horizontal, 16)
			.padding(.vertical, 8)
			.background(presentation.tone == .damaged ? VaultPalette.redTint : VaultPalette.orangeTint)
			VaultHairline(color: VaultPalette.titleBarBorder)
		}
	}
}

private extension VaultCompanionBanner {
	var symbol: String {
		switch presentation.tone {
		case .damaged: "exclamationmark.triangle.fill"
		case .update: "arrow.up.circle.fill"
		case .interrupted: "clock.arrow.circlepath"
		}
	}
}

private extension String {
	var capitalizingFirstLetter: String {
		prefix(1).uppercased() + dropFirst()
	}
}
