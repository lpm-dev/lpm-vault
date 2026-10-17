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
	case coolify
	case netlify
	case github

	var displayName: String {
		switch self {
		case .vercel: "Vercel"
		case .coolify: "Coolify"
		case .netlify: "Netlify"
		case .github: "GitHub"
		}
	}

	var systemImage: String {
		switch self {
		case .vercel: "triangle.fill"
		case .coolify: "server.rack"
		case .netlify: "diamond.fill"
		case .github: "chevron.left.forwardslash.chevron.right"
		}
	}
	/// What a publish sends, counted as the platform calls it: GitHub's
	/// secrets and variables by kind, every other platform's as variables.
	func countedValues(secrets: Int, variables: Int) -> String {
		guard self == .github else { return Self.counted(secrets + variables, "variable") }
		switch (secrets, variables) {
		case (0, 0): return "0 secrets or variables"
		case (_, 0): return Self.counted(secrets, "secret")
		case (0, _): return Self.counted(variables, "variable")
		default: return "\(Self.counted(secrets, "secret")) and \(Self.counted(variables, "variable"))"
		}
	}

	/// What the platform keeps, as a noun for `count` of them: GitHub's
	/// secrets and variables, every other platform's variables.
	func valuesNoun(count: Int) -> String {
		switch self {
		case .github: count == 1 ? "secret or variable" : "secrets and variables"
		default: count == 1 ? "variable" : "variables"
		}
	}

	private static func counted(_ count: Int, _ noun: String) -> String {
		"\(count) \(noun)\(count == 1 ? "" : "s")"
	}
}

enum PublishTarget: Hashable, Sendable {
	case vercel(VercelPublishTarget)
	case coolify(CoolifyPublishTarget)
	case netlify(NetlifyPublishTarget)
	case github(GitHubPublishTarget)

	/// Where a publish writes. Two destinations with the same location would
	/// overwrite each other's values, so a vault keeps at most one per location.
	enum Location: Hashable, Sendable {
		case vercel(teamID: String?, projectID: String, environment: String)
		case coolify(instance: String, resource: CoolifyPublishTarget.Resource, resourceID: String, deployments: CoolifyPublishTarget.Deployments)
		case netlify(siteID: String, context: String)
		case github(repositoryID: String, scope: String)

		/// The places, beside this one, whose values the platform keeps in the
		/// same records, as a Netlify variable keeps its value for every deploy
		/// context of a site with one change time. A publish here moves those
		/// records forward for the others too; nil when no other place shares them.
		var sharedRecords: SharedRecords? {
			switch self {
			case .vercel, .coolify, .github: nil
			case .netlify(let siteID, _): SharedRecords(platform: .netlify, ownerID: siteID)
			}
		}
	}

	/// The records places on one platform share, by the ID of what holds them.
	struct SharedRecords: Hashable, Sendable {
		let platform: PublishPlatform
		/// The platform's ID for what holds the records, such as a Netlify
		/// site, which every stored destination writing there contains.
		let ownerID: String
	}

	var platform: PublishPlatform {
		switch self {
		case .vercel: .vercel
		case .coolify: .coolify
		case .netlify: .netlify
		case .github: .github
		}
	}

	var location: Location {
		switch self {
		case .vercel(let target):
			.vercel(teamID: target.teamID, projectID: target.projectID, environment: target.environment.identifier)
		case .coolify(let target):
			.coolify(instance: target.instance.origin, resource: target.resource, resourceID: target.resourceID, deployments: target.deployments)
		case .netlify(let target):
			.netlify(siteID: target.siteID, context: target.context.identifier)
		case .github(let target):
			.github(repositoryID: target.repositoryID, scope: target.scope.identifier)
		}
	}

	/// The connection that publishes here.
	var connectionID: PlatformConnection.ID {
		switch self {
		case .vercel(let target): target.connectionID
		case .coolify(let target): target.connectionID
		case .netlify(let target): target.connectionID
		case .github(let target): target.connectionID
		}
	}

	/// The account's name when the destination was saved, such as a team's.
	var accountName: String {
		switch self {
		case .vercel(let target): target.teamName
		case .coolify(let target): target.teamName
		case .netlify(let target): target.teamName
		case .github(let target): target.ownerLogin
		}
	}

	/// The name of the connection that publishes here when the destination
	/// was saved: the team's for Vercel and Coolify, the user's for Netlify and GitHub.
	var connectionName: String {
		switch self {
		case .vercel(let target): target.teamName
		case .coolify(let target): target.teamName
		case .netlify(let target): target.userName
		case .github(let target): target.userLogin
		}
	}

	/// What the platform calls the place, such as a project, then the part of it written to.
	var placeName: String {
		switch self {
		case .vercel(let target): "\(target.projectName) / \(target.environment.displayName)"
		case .coolify(let target): "\(target.resourceName) / \(target.deployments.displayName)"
		case .netlify(let target): "\(target.siteName) / \(target.context.displayName)"
		case .github(let target): "\(target.repositoryName) / \(target.scope.displayName)"
		}
	}

	/// What tells the place apart from others with the same name, such as
	/// the Coolify project, environment and instance holding a resource.
	var placeDetail: String? {
		switch self {
		case .vercel, .netlify, .github: return nil
		case .coolify(let target):
			let place = [target.projectName, target.environmentName].compactMap { $0 }.joined(separator: " / ")
			return place.isEmpty ? target.instance.address : "\(place) on \(target.instance.address)"
		}
	}

	fileprivate var invalidity: PublishDestinationInvalidity? {
		switch self {
		case .vercel(let target): target.invalidity
		case .coolify(let target): target.invalidity
		case .netlify(let target): target.invalidity
		case .github(let target): target.invalidity
		}
	}
}

/// IDs a platform assigns, such as Vercel's `prj_…` and Coolify's UUIDs,
/// use only these characters, so one can go into a request path without escaping.
enum PlatformIdentifier {
	static let maximumLength = 100

	static func isValid(_ text: String) -> Bool {
		!text.isEmpty && text.utf8.count <= maximumLength
			&& text.utf8.allSatisfy { byte in
				(byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
					|| byte == 0x5F || byte == 0x2D
			}
	}

	/// A display name. It's shown with its direction controls escaped.
	static func isValidName(_ text: String) -> Bool {
		!text.isEmpty && text.utf8.count <= 512 && text.trimmingCharacters(in: .whitespaces) == text
			&& !text.unicodeScalars.contains { $0.properties.generalCategory == .control }
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
	/// The team, or for a personal account the user, whose connection
	/// publishes here; for a team it's the team's ID.
	let accountID: String
	/// The team's or account's name when the destination was saved, for display.
	var teamName: String
	let projectID: String
	/// The project's name when the destination was saved, for display.
	var projectName: String
	var environment: Environment

	init(teamID: String?, accountID: String, teamName: String, projectID: String, projectName: String, environment: Environment) {
		self.teamID = teamID
		self.accountID = accountID
		self.teamName = teamName
		self.projectID = projectID
		self.projectName = projectName
		self.environment = environment
	}

	/// The longest ID the LPM CLI accepts from Vercel.
	static let maximumIdentifierLength = PlatformIdentifier.maximumLength

	/// The connection that publishes here.
	var connectionID: PlatformConnection.ID { PlatformConnection.vercelID(accountID: accountID) }

	fileprivate var invalidity: PublishDestinationInvalidity? {
		var identifiers = [projectID, accountID]
		var names = [teamName, projectName]
		if let teamID {
			guard teamID == accountID else { return .targetIdentifier }
			identifiers.append(teamID)
		}
		if case .custom(let id, let name) = environment {
			identifiers.append(id)
			names.append(name)
		}
		guard identifiers.allSatisfy(Self.isValidIdentifier) else { return .targetIdentifier }
		guard names.allSatisfy(PlatformIdentifier.isValidName) else { return .targetName }
		return nil
	}

	/// Vercel's IDs, such as `prj_…` and `team_…`.
	static func isValidIdentifier(_ text: String) -> Bool {
		PlatformIdentifier.isValid(text)
	}
}

/// A Coolify application's or service's variables, on one instance.
struct CoolifyPublishTarget: Hashable, Sendable {
	enum Resource: String, Hashable, Sendable {
		case application
		/// A service, such as one of Coolify's one-click stacks.
		case service

		var displayName: String {
			switch self {
			case .application: "Application"
			case .service: "Service"
			}
		}
	}

	/// Which deployments' variables are written. Only an application has
	/// preview deployments, with variables of their own.
	enum Deployments: String, Hashable, Sendable {
		case production
		case preview

		var displayName: String {
			switch self {
			case .production: "Production"
			case .preview: "Preview deployments"
			}
		}
	}

	let instance: CoolifyInstance
	let teamID: String
	/// The team's name when the destination was saved, for display.
	var teamName: String
	let resource: Resource
	/// The application's or service's UUID.
	let resourceID: String
	/// The resource's name when the destination was saved, for display.
	var resourceName: String
	/// The Coolify project and environment holding the resource, for display;
	/// nil when Coolify didn't name them.
	var projectName: String?
	var environmentName: String?
	var deployments: Deployments

	/// The connection that publishes here.
	var connectionID: PlatformConnection.ID { PlatformConnection.coolifyID(instance: instance, teamID: teamID) }

	fileprivate var invalidity: PublishDestinationInvalidity? {
		guard CoolifyTeam.isValidID(teamID), PlatformIdentifier.isValid(resourceID),
			resource == .application || deployments == .production
		else { return .targetIdentifier }
		guard [teamName, resourceName].allSatisfy(PlatformIdentifier.isValidName),
			[projectName, environmentName].allSatisfy({ $0.map(PlatformIdentifier.isValidName) ?? true })
		else {
			return .targetName
		}
		return nil
	}
}

/// A Netlify site's values for one deploy context. Netlify keeps one
/// variable per key for the whole site, holding a value for each context.
struct NetlifyPublishTarget: Hashable, Sendable {
	/// Branch names are compared byte for byte, as Git and Netlify compare
	/// them, not by Swift's canonical equivalence, which would take a
	/// precomposed `é` and a decomposed one for the same branch.
	enum Context: Hashable, Sendable {
		case production
		case deployPreview
		case branchDeploy
		/// The deploys of one branch, by its name. A name ending in `*` covers
		/// every branch that starts with the rest.
		case branch(String)

		/// The context's stable identity on Netlify, in ASCII: a branch's name
		/// has `%` and every byte outside ASCII percent-escaped, so equal
		/// identities are equal bytes.
		var identifier: String {
			switch self {
			case .production: "production"
			case .deployPreview: "deploy-preview"
			case .branchDeploy: "branch-deploy"
			case .branch(let name): "branch:\(Self.escapingNonASCII(name))"
			}
		}

		static func == (lhs: Context, rhs: Context) -> Bool {
			switch (lhs, rhs) {
			case (.production, .production), (.deployPreview, .deployPreview), (.branchDeploy, .branchDeploy): true
			case (.branch(let left), .branch(let right)): left.utf8.elementsEqual(right.utf8)
			default: false
			}
		}

		func hash(into hasher: inout Hasher) {
			switch self {
			case .production: hasher.combine(0)
			case .deployPreview: hasher.combine(1)
			case .branchDeploy: hasher.combine(2)
			case .branch(let name):
				hasher.combine(3)
				Self.hashBytes(of: name, into: &hasher)
			}
		}

		static func hashBytes(of text: String, into hasher: inout Hasher) {
			hasher.combine(text.utf8.count)
			for byte in text.utf8 { hasher.combine(byte) }
		}

		private static func escapingNonASCII(_ text: String) -> String {
			var escaped = ""
			escaped.reserveCapacity(text.utf8.count)
			for byte in text.utf8 {
				if byte < 0x80, byte != 0x25 {
					escaped.unicodeScalars.append(Unicode.Scalar(byte))
				} else {
					escaped += "%" + String(byte, radix: 16, uppercase: true).leftPadding(to: 2)
				}
			}
			return escaped
		}

		var displayName: String {
			switch self {
			case .production: "Production"
			case .deployPreview: "Deploy Previews"
			case .branchDeploy: "Branch deploys"
			case .branch(let name): "Branch \(name)"
			}
		}

		/// Netlify's name for the context in its API.
		var apiName: String {
			switch self {
			case .production: "production"
			case .deployPreview: "deploy-preview"
			case .branchDeploy: "branch-deploy"
			case .branch: "branch"
			}
		}

		/// The branch a branch's context is for.
		var branch: String? {
			if case .branch(let name) = self { return name }
			return nil
		}

		static let maximumBranchBytes = 255

		/// A branch name Git accepts, which may end in Netlify's `*` wildcard:
		/// printable, without spaces or the characters Git refuses in a ref,
		/// and without anything that could hide or reorder text around it.
		/// No part between slashes may be empty, start with a dot or end in `.lock`.
		static func isValidBranch(_ name: String) -> Bool {
			guard !name.isEmpty, name.utf8.count <= maximumBranchBytes,
				!name.hasPrefix("-"), !name.hasSuffix("."), !name.contains(".."), !name.contains("@{"), name != "@",
				name.split(separator: "/", omittingEmptySubsequences: false)
					.allSatisfy({ !$0.isEmpty && !$0.hasPrefix(".") && !$0.hasSuffix(".lock") })
			else { return false }
			let pattern = name.hasSuffix("*") ? name.dropLast() : name[...]
			guard !pattern.isEmpty else { return false }
			return pattern.unicodeScalars.allSatisfy { scalar in
				switch scalar.properties.generalCategory {
				case .control, .format, .spaceSeparator, .lineSeparator, .paragraphSeparator, .privateUse, .surrogate, .unassigned:
					return false
				default:
					return !"~^:?*[\\".unicodeScalars.contains(scalar)
				}
			}
		}
	}

	/// The Netlify user whose connection publishes here.
	let userID: String
	/// The user's name when the destination was saved, for display.
	var userName: String
	/// The team that owns the site, which Netlify's API names it by.
	let teamID: String
	/// The team's name when the destination was saved, for display.
	var teamName: String
	let siteID: String
	/// The site's name when the destination was saved, for display.
	var siteName: String
	var context: Context

	/// The connection that publishes here.
	var connectionID: PlatformConnection.ID { PlatformConnection.netlifyID(userID: userID) }

	fileprivate var invalidity: PublishDestinationInvalidity? {
		guard [userID, teamID, siteID].allSatisfy(PlatformIdentifier.isValid),
			context.branch.map(Context.isValidBranch) ?? true
		else { return .targetIdentifier }
		guard [userName, teamName, siteName].allSatisfy(PlatformIdentifier.isValidName) else { return .targetName }
		return nil
	}
}

/// A GitHub repository's Actions secrets and variables: the repository's
/// own, which every workflow gets, or one deployment environment's, which only
/// jobs that name the environment get, over the repository's.
struct GitHubPublishTarget: Hashable, Sendable {
	enum Scope: Hashable, Sendable {
		case repository
		/// A deployment environment, by GitHub's numeric ID, which outlasts the
		/// environment being shown under another name; its name is what
		/// GitHub's paths use.
		case environment(id: String, name: String)

		/// The scope's stable identity on GitHub.
		var identifier: String {
			switch self {
			case .repository: "repository"
			case .environment(let id, _): "environment:\(id)"
			}
		}

		var displayName: String {
			switch self {
			case .repository: "Repository"
			case .environment(let id, let name): "Environment \(Self.shownName(id: id, name: name))"
			}
		}

		/// An environment's name as LPM Vault shows it: escaped, and followed
		/// by its ID when the name could pass for another's, as one with any
		/// character beyond printable ASCII, a backslash or "(ID" that an
		/// escape or an ID shows, or a space at either end could. A shown ID
		/// is read back from the end, so no two environments show alike.
		static func shownName(id: String, name: String) -> String {
			let plain = name.utf8.allSatisfy { $0 >= 0x20 && $0 <= 0x7E } && !name.contains("\\")
				&& name.range(of: "(id", options: .caseInsensitive) == nil && name.first != " " && name.last != " "
			return plain ? name : "\(name.escapingInvisibleCharacters) (ID \(id))"
		}

		/// The environment's name in GitHub's paths; nil for the repository's own.
		var environmentName: String? {
			if case .environment(_, let name) = self { return name }
			return nil
		}

		/// The longest environment name GitHub accepts.
		static let maximumEnvironmentNameCharacters = 255

		/// An environment's name as GitHub accepts it: up to 255 characters,
		/// none of them a control character.
		static func isValidEnvironmentName(_ name: String) -> Bool {
			!name.isEmpty && name.count <= maximumEnvironmentNameCharacters
				&& !name.unicodeScalars.contains { $0.properties.generalCategory == .control }
		}
	}

	/// The GitHub user whose connection publishes here.
	let userID: String
	/// The user's login when the destination was saved, for display.
	var userLogin: String
	/// GitHub's numeric ID for the repository, which outlasts a rename or a transfer.
	let repositoryID: String
	/// The repository's `owner/name` when the destination was saved. GitHub's
	/// paths use it, so a review reads the current one first.
	var repositoryName: String
	var scope: Scope

	/// The connection that publishes here.
	var connectionID: PlatformConnection.ID { PlatformConnection.githubID(userID: userID) }

	/// The account that owns the repository, from its full name.
	var ownerLogin: String { String(repositoryName.prefix { $0 != "/" }) }

	fileprivate var invalidity: PublishDestinationInvalidity? {
		var identifiers = [userID, repositoryID]
		if case .environment(let id, _) = scope { identifiers.append(id) }
		guard identifiers.allSatisfy(GitHubHTTP.isValidID) else { return .targetIdentifier }
		guard GitHubHTTP.isValidLogin(userLogin), Self.isValidFullName(repositoryName),
			scope.environmentName.map(Scope.isValidEnvironmentName) ?? true
		else { return .targetName }
		return nil
	}

	/// A repository's `owner/name`: the owner's login, then letters, digits,
	/// `.`, `-` and `_`, as GitHub names repositories.
	static func isValidFullName(_ text: String) -> Bool {
		let parts = text.split(separator: "/", omittingEmptySubsequences: false)
		guard parts.count == 2, GitHubHTTP.isValidLogin(String(parts[0])) else { return false }
		let name = parts[1]
		return !name.isEmpty && name.utf8.count <= 100 && name != "." && name != ".."
			&& name.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A) || $0 == 0x2E || $0 == 0x2D || $0 == 0x5F }
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

	/// Whether a record's time still names one write. Every write moves the
	/// time strictly forward until it reaches the maximum, where later
	/// writes keep the same time.
	static func identifiesOneWrite(_ date: Date) -> Bool {
		milliseconds(date) < maximumMilliseconds
	}
}

private extension String {
	func leftPadding(to length: Int) -> String {
		count >= length ? self : String(repeating: "0", count: length - count) + self
	}
}
