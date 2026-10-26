import Foundation

/// Why companion storage stopped an operation on one env project, in the
/// app's words: newer data this app doesn't support, newer data that's
/// damaged, or a change to it that couldn't be finished.
enum CompanionRefusal: Equatable, Sendable {
	case unsupported(feature: String, version: Int, level: CompanionEngine.Level)
	/// Damaged newer data, described as one clause.
	case damaged(String)
	/// An interrupted change LPM Vault couldn't finish, and why.
	case unfinished(String)
	/// The newer data changed since the person reviewed a repair of it.
	case changedSinceReview
	/// The bundled engine couldn't decide, so nothing was touched.
	case engine(String)

	init(_ assessment: CompanionEngine.Assessment) {
		if !assessment.damage.isEmpty {
			self = .damaged(Self.describe(assessment.damage))
		} else if let unsupported = assessment.unsupported {
			self = .unsupported(feature: unsupported.feature, version: unsupported.version, level: unsupported.level)
		} else {
			self = .engine("the project’s newer data allows nothing but maintenance")
		}
	}

	/// What stopped the operation and what to do, where the person is on, or
	/// can open, the project's page.
	var message: String {
		switch self {
		case .unsupported(let feature, let version, .readOnly):
			"This env project uses \(Self.describe(feature: feature)) v\(version), which this version of LPM Vault can only read. Update LPM Vault to change it."
		case .unsupported(let feature, let version, _):
			"This env project uses \(Self.describe(feature: feature)) v\(version), which this version of LPM Vault doesn’t support. Update LPM Vault to open it."
		case .damaged(let reason):
			"This env project’s newer data is damaged: \(reason). Repair it from the project’s page."
		case .unfinished(let reason):
			"LPM Vault couldn’t finish an interrupted change to this env project’s newer data (\(reason)), so its values stay hidden. Try again, or delete the project."
		case .changedSinceReview:
			"This env project’s newer data changed since you reviewed the repair, so nothing was changed. Review the repair again."
		case .engine(let reason):
			"LPM Vault couldn’t check this env project’s newer data (\(reason))."
		}
	}

	/// Why a backup left the project out. A project removed from the sidebar
	/// has no page until its folder is opened again.
	func backupReason(listed: Bool) -> String {
		guard !listed else { return message }
		return switch self {
		case .damaged(let reason):
			"This env project’s newer data is damaged: \(reason). Open its folder in LPM Vault to add it back, then repair it."
		case .unfinished(let reason):
			"LPM Vault couldn’t finish an interrupted change to this env project’s newer data (\(reason)). Open its folder in LPM Vault to add it back, then try again."
		default:
			message
		}
	}

	/// How messages name a feature. Feature names follow the identifier
	/// grammar, so an unknown one is safe to show quoted.
	static func describe(feature: String) -> String {
		switch feature {
		case "overrides": "personal overrides"
		case "history": "local history"
		case "releases": "a release log"
		case "details": "project details"
		default: "the feature \u{201C}\(feature)\u{201D}"
		}
	}

	/// Every damage, as one clause.
	static func describe(_ damage: [CompanionEngine.Assessment.Damage]) -> String {
		ListFormatter.localizedString(byJoining: damage.map(describe))
	}

	/// What one damage is, as a clause.
	static func describe(_ damage: CompanionEngine.Assessment.Damage) -> String {
		let kind = damage.kind.map { "\u{201C}\($0)\u{201D}" } ?? "a"
		return switch damage.code {
		case "invalidMarker": "its feature marker is invalid"
		case "missingRecord": "its \(kind) record is missing"
		case "invalidRecord": "its \(kind) record is invalid"
		case "unlistedRecord": "it has \(kind) records no feature lists"
		case "access": damage.reason ?? "its approval settings contradict each other"
		case "unfinishedChange": "an interrupted change to it can’t be finished"
		default: "it can’t be checked"
		}
	}
}
