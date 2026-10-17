import Foundation
import Observation

/// The Destination step's fields for the chosen connection's platform.
enum PublishDestinationForm {
	case vercel(VercelDestinationForm)
	case coolify(CoolifyDestinationForm)
	case netlify(NetlifyDestinationForm)
	case github(GitHubDestinationForm)
}

/// A Vercel project and one of its environments.
@MainActor
@Observable
final class VercelDestinationForm {
	enum Field {
		case project
		case environment
	}

	var projectID: String? {
		didSet {
			guard projectID != oldValue else { return }
			if case .custom = environment { environment = nil }
			didChange(.project)
		}
	}
	var environment: VercelPublishTarget.Environment? {
		didSet { if environment != oldValue { didChange(.environment) } }
	}
	var projects: PublishSession.Loadable<[VercelProject]> = .idle
	var customEnvironments: PublishSession.Loadable<[VercelCustomEnvironment]> = .idle
	@ObservationIgnored var didChange: (Field) -> Void = { _ in }

	init(projectID: String? = nil, environment: VercelPublishTarget.Environment? = nil) {
		self.projectID = projectID
		self.environment = environment
	}

	var project: VercelProject? {
		projects.value?.first { $0.id == projectID }
	}

	/// Every environment the project has, standard ones first.
	var environmentChoices: [VercelPublishTarget.Environment] {
		[.production, .preview, .development] + (customEnvironments.value ?? []).map { .custom(id: $0.id, name: $0.slug) }
	}

	var isComplete: Bool { project != nil && environment != nil }
}

/// A Coolify application or service, and which of its deployments' variables are written.
@MainActor
@Observable
final class CoolifyDestinationForm {
	var resourceID: String? {
		didSet {
			guard resourceID != oldValue else { return }
			if let resource, resource.kind == .service || deployments == nil { deployments = .production }
			didChange()
		}
	}
	var deployments: CoolifyPublishTarget.Deployments? {
		didSet { if deployments != oldValue { didChange() } }
	}
	/// In Coolify's order: by project, environment, then name.
	var resources: PublishSession.Loadable<[CoolifyResource]> = .idle
	@ObservationIgnored var didChange: () -> Void = {}

	init(resourceID: String? = nil, deployments: CoolifyPublishTarget.Deployments? = nil) {
		self.resourceID = resourceID
		self.deployments = deployments
	}

	var resource: CoolifyResource? {
		resources.value?.first { $0.id == resourceID }
	}

	/// A service has no preview deployments.
	var deploymentChoices: [CoolifyPublishTarget.Deployments] {
		resource?.kind == .service ? [.production] : [.production, .preview]
	}

	var isComplete: Bool {
		guard let deployments else { return false }
		return deploymentChoices.contains(deployments) && resource != nil
	}

	/// Each resource's label in the menu, by ID: its name, then the Coolify
	/// project and environment holding it. Coolify doesn't keep names
	/// unique, so labels that would read alike end with the start of their UUID.
	static func labels(for resources: [CoolifyResource]) -> [String: String] {
		let bases = resources.map { resource in
			let place = [resource.projectName, resource.environmentName].compactMap { $0 }.joined(separator: " / ")
			return (id: resource.id, label: place.isEmpty ? resource.name : "\(resource.name) — \(place)")
		}
		var counts: [String: Int] = [:]
		for base in bases { counts[base.label, default: 0] += 1 }
		return Dictionary(bases.map { base in
			(base.id, counts[base.label, default: 0] > 1 ? "\(base.label) · \(base.id.prefix(8))" : base.label)
		}, uniquingKeysWith: { first, _ in first })
	}

	/// Resources sorted the way Coolify's dashboard groups them.
	static func sorted(_ resources: [CoolifyResource]) -> [CoolifyResource] {
		resources.sorted { lhs, rhs in
			for (left, right) in [(lhs.projectName ?? "", rhs.projectName ?? ""), (lhs.environmentName ?? "", rhs.environmentName ?? ""), (lhs.name, rhs.name)] {
				switch left.localizedStandardCompare(right) {
				case .orderedAscending: return true
				case .orderedDescending: return false
				case .orderedSame: continue
				}
			}
			return lhs.id < rhs.id
		}
	}
}

/// A Netlify site and one of its deploy contexts, or one branch's deploys.
@MainActor
@Observable
final class NetlifyDestinationForm {
	/// The context menu's choices; a branch's name is typed.
	enum ContextChoice: Hashable, CaseIterable {
		case production
		case deployPreview
		case branchDeploy
		case branch

		var displayName: String {
			switch self {
			case .production: "Production"
			case .deployPreview: "Deploy Previews"
			case .branchDeploy: "Branch deploys"
			case .branch: "One branch…"
			}
		}
	}

	var siteID: String? {
		didSet { if siteID != oldValue { didChange() } }
	}
	var contextChoice: ContextChoice? {
		didSet { if contextChoice != oldValue { didChange() } }
	}
	/// The branch's name as typed, for a branch's deploys. Compared by bytes,
	/// as Git and Netlify tell branches apart.
	var branch: String {
		didSet { if !branch.utf8.elementsEqual(oldValue.utf8), contextChoice == .branch { didChange() } }
	}
	/// In Netlify's order: by team, then name.
	var sites: PublishSession.Loadable<[NetlifySite]> = .idle
	@ObservationIgnored var didChange: () -> Void = {}

	init(siteID: String? = nil, context: NetlifyPublishTarget.Context? = nil) {
		self.siteID = siteID
		switch context {
		case .production?: contextChoice = .production
		case .deployPreview?: contextChoice = .deployPreview
		case .branchDeploy?: contextChoice = .branchDeploy
		case .branch?: contextChoice = .branch
		case nil: contextChoice = nil
		}
		branch = context?.branch ?? ""
	}

	var site: NetlifySite? {
		sites.value?.first { $0.id == siteID }
	}

	/// The context the fields name; nil until it's chosen, or while a
	/// branch's name isn't one Git and Netlify accept.
	var context: NetlifyPublishTarget.Context? {
		switch contextChoice {
		case .production?: return .production
		case .deployPreview?: return .deployPreview
		case .branchDeploy?: return .branchDeploy
		case .branch?:
			let name = branch.trimmingCharacters(in: .whitespacesAndNewlines)
			return NetlifyPublishTarget.Context.isValidBranch(name) ? .branch(name) : nil
		case nil: return nil
		}
	}

	/// Why the typed branch can't be used, once something is typed.
	var branchProblem: String? {
		guard contextChoice == .branch else { return nil }
		let name = branch.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !name.isEmpty, context == nil else { return nil }
		return "Enter a branch name Git accepts. A name may end in * to cover every branch starting with the rest."
	}

	var isComplete: Bool { site != nil && context != nil }

	/// Each site's label in the menu, by ID: its name, then its team's.
	/// Netlify keeps site names unique, so labels never read alike.
	static func labels(for sites: [NetlifySite]) -> [String: String] {
		Dictionary(sites.map { ($0.id, "\($0.name) — \($0.teamName)") }, uniquingKeysWith: { first, _ in first })
	}

	/// Sites sorted the way Netlify's dashboard groups them: by team, then
	/// name. Nonisolated, so a long list is sorted off the main actor.
	nonisolated static func sorted(_ sites: [NetlifySite]) -> [NetlifySite] {
		sites.sorted { lhs, rhs in
			for (left, right) in [(lhs.teamName, rhs.teamName), (lhs.name, rhs.name)] {
				switch left.localizedStandardCompare(right) {
				case .orderedAscending: return true
				case .orderedDescending: return false
				case .orderedSame: continue
				}
			}
			return lhs.id < rhs.id
		}
	}
}

/// A GitHub repository, and whether its own secrets and variables are
/// written or one deployment environment's.
@MainActor
@Observable
final class GitHubDestinationForm {
	enum Field {
		case repository
		case scope
	}

	var repositoryID: String? {
		didSet {
			guard repositoryID != oldValue else { return }
			environments = .idle
			scope = repositoryID == nil ? nil : .repository
			didChange(.repository)
		}
	}
	var scope: GitHubPublishTarget.Scope? {
		didSet { if scope?.identifier != oldValue?.identifier { didChange(.scope) } }
	}
	/// By `owner/name`.
	var repositories: PublishSession.Loadable<[GitHubRepository]> = .idle
	/// Whether GitHub left out an organization's repositories until the person signs in with its single sign-on.
	var hidesSSORepositories = false
	/// Installations of the app GitHub left out, as when one is suspended.
	var skippedInstallations: [GitHubSkippedInstallation] = []
	/// The chosen repository's deployment environments.
	var environments: PublishSession.Loadable<[GitHubEnvironment]> = .idle
	@ObservationIgnored var didChange: (Field) -> Void = { _ in }

	init(repositoryID: String? = nil, scope: GitHubPublishTarget.Scope? = nil) {
		self.repositoryID = repositoryID
		self.scope = scope
	}

	var repository: GitHubRepository? {
		repositories.value?.first { $0.id == repositoryID }
	}

	/// The repository's own secrets and variables, then each environment's.
	/// A chosen environment stays a choice until the environments are listed.
	var scopeChoices: [GitHubPublishTarget.Scope] {
		if let environments = environments.value {
			return [.repository] + environments.map { .environment(id: $0.id, name: $0.name) }
		}
		if let scope, case .environment = scope { return [.repository, scope] }
		return [.repository]
	}

	var isComplete: Bool {
		guard repository != nil, let scope else { return false }
		return scopeChoices.contains { $0.identifier == scope.identifier }
	}

	/// A choice in one of the form's menus: what it says, and whether it can be chosen.
	struct Option: Equatable, Sendable {
		let id: String
		let label: String
		let isAvailable: Bool
	}

	/// The repositories, each saying whether it's private, as its icon
	/// alone doesn't to VoiceOver, why the person can't change its secrets
	/// and variables when they can't, and its ID when its name looks like
	/// another's.
	var repositoryOptions: [Option] {
		let repositories = repositories.value ?? []
		let keys = repositories.map { GitHubPublishTarget.lookalikeKey($0.fullName) }
		var lookalikes: [String: Int] = [:]
		lookalikes.reserveCapacity(repositories.count)
		for key in keys { lookalikes[key, default: 0] += 1 }
		return zip(repositories, keys).map { repository, key in
			let name = lookalikes[key, default: 0] > 1 ? "\(repository.fullName) (ID \(repository.id))" : repository.fullName
			var label = "\(name) · \(repository.isPrivate ? "Private" : "Public")"
			if repository.isArchived {
				label += " · Archived"
			} else if !repository.canChange(.repository) {
				label += " · Read-only"
			}
			return Option(id: repository.id, label: label, isAvailable: repository.canChange(.repository))
		}
	}

	/// The scope choices, each one the person can't change saying why, and
	/// each environment whose name looks like another's showing its ID.
	var scopeOptions: [Option] {
		let repository = self.repository
		let choices = scopeChoices
		let keys = choices.map { scope -> String? in
			guard case .environment(_, let name) = scope else { return nil }
			return GitHubPublishTarget.lookalikeKey(name)
		}
		var lookalikes: [String: Int] = [:]
		lookalikes.reserveCapacity(choices.count)
		for case let key? in keys { lookalikes[key, default: 0] += 1 }
		return zip(choices, keys).map { scope, key in
			let name = scope.displayName(showingID: key.map { lookalikes[$0, default: 0] > 1 } ?? false)
			guard let repository, !repository.canChange(scope) else {
				return Option(id: scope.identifier, label: name, isAvailable: true)
			}
			let reason = repository.isArchived ? "Archived" : repository.permission == .read ? "Read-only" : "Needs admin access"
			return Option(id: scope.identifier, label: "\(name) · \(reason)", isAvailable: false)
		}
	}

	/// Repositories sorted by `owner/name`. Nonisolated, so a long list is sorted off the main actor.
	nonisolated static func sorted(_ repositories: [GitHubRepository]) -> [GitHubRepository] {
		repositories.sorted { lhs, rhs in
			switch lhs.fullName.localizedStandardCompare(rhs.fullName) {
			case .orderedAscending: true
			case .orderedDescending: false
			case .orderedSame: lhs.id < rhs.id
			}
		}
	}
}
