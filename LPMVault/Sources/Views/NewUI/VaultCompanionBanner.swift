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
	/// What Repair… does, when the damage has a repair.
	let repair: CompanionEngine.Assessment.Repair?

	init?(_ state: CompanionEngine.Assessment) {
		let damage = state.damage
		if state.needsResume {
			tone = .interrupted
			title = "This project’s newer data has an unfinished change"
			detail = "LPM Vault finishes it before anything else uses the project, so its values stay hidden until then."
			repair = nil
		} else if let first = damage.first {
			tone = .damaged
			title = "This project’s newer data is damaged"
			let others = damage.count > 1 ? " It has \(damage.count - 1) more problem\(damage.count == 2 ? "" : "s")." : ""
			let consequence = switch first.code {
			case "invalidMarker": "Its values stay hidden, and LPM won’t run it, until it’s repaired."
			case "access": "LPM Vault fixes the approval settings the next time you unlock it."
			default: "LPM may refuse to use it until it’s repaired."
			}
			detail = "\(CompanionRefusal.describe(first).capitalizingFirstLetter).\(others) \(consequence)"
			repair = damage.lazy.compactMap(\.repair).first
		} else if let unsupported = state.unsupported {
			tone = .update
			title = "This project uses data from a newer LPM"
			detail = CompanionRefusal.unsupported(
				feature: unsupported.feature, version: unsupported.version, level: unsupported.level
			).message
			repair = nil
		} else {
			return nil
		}
	}

	/// The question Repair… asks before it changes anything.
	func repairConfirmation(subject: VaultConfirmation.Subject, perform: @escaping () -> Void) -> VaultConfirmation? {
		guard let repair else { return nil }
		let message = switch repair.action {
		case .discardProject:
			"Repairing discards all of this project’s newer data on this Mac, such as personal overrides and local history. Its values stay as they are."
		case .removeFeature:
			"Repairing removes \(CompanionRefusal.describe(feature: repair.feature ?? "")) from this project on this Mac. Its values and other newer data stay as they are."
		case .removeUnlisted:
			"Repairing deletes the newer data no feature of this project uses. Its values and features stay as they are."
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
				case .damaged where presentation.repair != nil:
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
