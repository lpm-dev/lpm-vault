import Foundation

/// A place a Vault environment is published to, such as a Vercel project's
/// Production environment. It holds the platform's identifiers and the
/// person's key choices, never credentials or values, so it can travel with
/// its vault to another Mac.
struct PublishDestination: Identifiable, Hashable, Sendable {
	let id: UUID
	/// The Vault environment whose values are published.
	var sourceEnvironment: String
	var target: PublishTarget
	/// Keys the person chose not to publish here. Keys the source gains later
	/// are offered, so a review shows them before anything is sent.
	var excludedKeys: Set<String>
	let createdAt: Date
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
	static let maximumNameLength = 256

	fileprivate var invalidity: PublishDestinationInvalidity? {
		var identifiers = [projectID]
		var names = [teamName, projectName]
		if let teamID { identifiers.append(teamID) }
		if case .custom(let id, let name) = environment {
			identifiers.append(id)
			names.append(name)
		}
		guard identifiers.allSatisfy({ Self.isValid($0, maximumLength: Self.maximumIdentifierLength) && !$0.contains(" ") })
		else { return .targetIdentifier }
		guard names.allSatisfy({ Self.isValid($0, maximumLength: Self.maximumNameLength) }) else { return .targetName }
		return nil
	}

	private static func isValid(_ text: String, maximumLength: Int) -> Bool {
		!text.isEmpty && text.count <= maximumLength && text.trimmingCharacters(in: .whitespaces) == text
			&& !text.unicodeScalars.contains { $0.properties.generalCategory == .control }
	}
}

/// Publish timestamps are stored to the millisecond, the precision platforms
/// report, so a record reads back exactly as it was written.
enum PublishTimestamp {
	static func normalized(_ date: Date) -> Date {
		self.date(milliseconds: milliseconds(date))
	}

	static func milliseconds(_ date: Date) -> Int64 {
		Int64((date.timeIntervalSince1970 * 1_000).rounded())
	}

	static func date(milliseconds: Int64) -> Date {
		Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
	}
}
