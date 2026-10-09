import Foundation

/// A group of keys as lpm.json declares it: which of its members must be
/// set together. The LPM CLI checks a group only as a whole.
struct ProjectEnvSchemaGroup: Equatable, Sendable {
	enum Mode: String, CaseIterable, Sendable {
		case exactlyOne, atLeastOne, allOrNone

		/// Such as "Exactly one of", which the group's members follow.
		var title: String {
			switch self {
			case .exactlyOne: "Exactly one of"
			case .atLeastOne: "At least one of"
			case .allOrNone: "All or none of"
			}
		}

		var detail: String {
			switch self {
			case .exactlyOne: "one key set, the others unset"
			case .atLeastOne: "any number set, but not none"
			case .allOrNone: "set together or not at all"
			}
		}
	}

	var mode: Mode
	/// In lpm.json's order.
	var members: [String]

	/// The most members the LPM CLI accepts across a schema's groups, and the most groups.
	static let maximumMembers = 4096
	static let maximumGroups = 128

	init(mode: Mode = .allOrNone, members: [String] = []) {
		self.mode = mode
		self.members = members
	}

	/// A group's declaration; nil when it isn't a group the LPM CLI reads.
	init?(_ json: LPMConfigJSON?) {
		guard case .string(let raw)? = json?["mode"], let mode = Mode(rawValue: raw), case .array(let values)? = json?["vars"] else { return nil }
		var members: [String] = []
		members.reserveCapacity(values.count)
		for value in values {
			guard case .string(let member) = value else { return nil }
			members.append(member)
		}
		self.init(mode: mode, members: members)
	}

	/// The declaration, keeping the members `json` has besides the mode and
	/// the members in their place.
	func json(updating json: LPMConfigJSON? = nil) -> LPMConfigJSON {
		var updated = json ?? .object([])
		updated.set(.string(mode.rawValue), forKey: "mode")
		updated.set(.array(members.map(LPMConfigJSON.string)), forKey: "vars")
		return updated
	}

	/// Such as "Exactly one of PASSWORD, OAUTH_TOKEN".
	var summary: String { "\(mode.title) \(members.joined(separator: ", "))" }

	/// What a group of one member does, which isn't what a group is for.
	var hint: String? {
		guard members.count == 1 else { return nil }
		return mode == .allOrNone ? "With one key this always passes." : "With one key this works like Required."
	}
}
