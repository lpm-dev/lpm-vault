import Foundation

/// A place a Vault environment is published to, such as a Vercel project's
/// Production environment. It holds the platform's identifiers and the
/// person's key choices, never credentials or values, so it can later sync
/// with its vault to another Mac.
struct PublishDestination: Identifiable, Hashable, Sendable {
	let id: UUID
	/// The Vault environment whose values are published.
	var sourceEnvironment: String
	var target: PublishTarget
	/// Keys the person chose not to publish here. Keys the source gains later
	/// are offered, so a review shows them before anything is sent.
	var excludedKeys: Set<String>
	let createdAt: Date
	/// Moves forward with every change the store saves, so it also tells
	/// whether the destination changed since it was read.
	var updatedAt: Date {
		didSet { updatedAt = PublishTimestamp.normalized(updatedAt) }
	}

	init(
		id: UUID = UUID(),
		sourceEnvironment: String,
		target: PublishTarget,
		excludedKeys: Set<String> = [],
		createdAt: Date,
		updatedAt: Date? = nil
	) {
		self.id = id
		self.sourceEnvironment = sourceEnvironment
		self.target = target
		self.excludedKeys = excludedKeys
		self.createdAt = PublishTimestamp.normalized(createdAt)
		self.updatedAt = PublishTimestamp.normalized(updatedAt ?? createdAt)
	}

	/// Why the destination can't be stored, or nil when it can.
	var invalidity: PublishDestinationInvalidity? {
		guard EnvValidation.isValidEnvironmentName(sourceEnvironment) else { return .sourceEnvironment }
		guard excludedKeys.count <= Self.maximumExcludedKeys,
			excludedKeys.allSatisfy(EnvValidation.isValidVariableName)
		else { return .excludedKeys }
		guard updatedAt >= createdAt else { return .timestamps }
		return target.invalidity
	}

	static let maximumExcludedKeys = 16_384
}

enum PublishDestinationInvalidity: Equatable, Sendable {
	case sourceEnvironment
	case excludedKeys
	case timestamps
	case targetIdentifier
	case targetName
}

enum PublishPlatform: String, CaseIterable, Sendable {
	case vercel

	var displayName: String {
		switch self {
		case .vercel: "Vercel"
		}
	}
}

enum PublishTarget: Hashable, Sendable {
	case vercel(VercelPublishTarget)

	/// Where a publish writes. Two destinations with the same location would
	/// overwrite each other's values, so a vault keeps at most one per location.
	enum Location: Hashable, Sendable {
		case vercel(teamID: String?, projectID: String, environment: String)
	}

	var platform: PublishPlatform {
		switch self {
		case .vercel: .vercel
		}
	}

	var location: Location {
		switch self {
		case .vercel(let target):
			.vercel(teamID: target.teamID, projectID: target.projectID, environment: target.environment.identifier)
		}
	}

	fileprivate var invalidity: PublishDestinationInvalidity? {
		switch self {
		case .vercel(let target): target.invalidity
		}
	}
}

struct VercelPublishTarget: Hashable, Sendable {
	enum Environment: Hashable, Sendable {
		case production
		case preview
		case development
		/// A custom environment, by its Vercel ID; its name is kept for display.
		case custom(id: String, name: String)

		/// The environment's stable identity on Vercel.
		var identifier: String {
			switch self {
			case .production: "production"
			case .preview: "preview"
			case .development: "development"
			case .custom(let id, _): "custom:\(id)"
			}
		}

		var displayName: String {
			switch self {
			case .production: "Production"
			case .preview: "Preview"
			case .development: "Development"
			case .custom(_, let name): name
			}
		}
	}

	/// The team's ID, or nil for a personal account.
	let teamID: String?
	/// The team's or account's name when the destination was saved, for display.
	var teamName: String
	let projectID: String
	/// The project's name when the destination was saved, for display.
	var projectName: String
	var environment: Environment

	init(teamID: String?, teamName: String, projectID: String, projectName: String, environment: Environment) {
		self.teamID = teamID
		self.teamName = teamName
		self.projectID = projectID
		self.projectName = projectName
		self.environment = environment
	}

	/// The longest ID the LPM CLI accepts from Vercel.
	static let maximumIdentifierLength = 100
	static let maximumNameBytes = 512

	fileprivate var invalidity: PublishDestinationInvalidity? {
		var identifiers = [projectID]
		var names = [teamName, projectName]
		if let teamID { identifiers.append(teamID) }
		if case .custom(let id, let name) = environment {
			identifiers.append(id)
			names.append(name)
		}
		guard identifiers.allSatisfy(Self.isValidIdentifier) else { return .targetIdentifier }
		guard names.allSatisfy(Self.isValidName) else { return .targetName }
		return nil
	}

	/// Vercel's IDs, such as `prj_…` and `team_…`, use only these characters,
	/// so one can go into a request path without escaping.
	static func isValidIdentifier(_ text: String) -> Bool {
		!text.isEmpty && text.utf8.count <= maximumIdentifierLength
			&& text.utf8.allSatisfy { byte in
				(byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
					|| byte == 0x5F || byte == 0x2D
			}
	}

	/// A display name. It's shown with its direction controls escaped.
	private static func isValidName(_ text: String) -> Bool {
		!text.isEmpty && text.utf8.count <= maximumNameBytes && text.trimmingCharacters(in: .whitespaces) == text
			&& !text.unicodeScalars.contains { $0.properties.generalCategory == .control }
	}
}

/// Publish timestamps are stored to the millisecond, the precision platforms
/// report, so a record reads back exactly as it was written. They're kept
/// between 1970 and the end of 9999, so a platform's impossible time can't
/// trap or produce a record that can't be read back.
enum PublishTimestamp {
	static let maximumMilliseconds: Int64 = 253_402_300_799_999

	static func normalized(_ date: Date) -> Date {
		self.date(milliseconds: milliseconds(date))
	}

	static func milliseconds(_ date: Date) -> Int64 {
		let milliseconds = (date.timeIntervalSince1970 * 1_000).rounded()
		guard !milliseconds.isNaN, milliseconds > 0 else { return 0 }
		return milliseconds >= Double(maximumMilliseconds) ? maximumMilliseconds : Int64(milliseconds)
	}

	static func date(milliseconds: Int64) -> Date {
		Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
	}

	/// `date`, or the first stored time after `previous` when `date` isn't
	/// later, so every change to a record gets a time of its own even when
	/// the clock stalls or steps back.
	static func next(after previous: Date, at date: Date) -> Date {
		self.date(milliseconds: max(milliseconds(date), min(milliseconds(previous) + 1, maximumMilliseconds)))
	}
}
