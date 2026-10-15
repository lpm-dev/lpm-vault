import Foundation
import Observation

/// The Destination step's fields for the chosen connection's platform.
enum PublishDestinationForm {
	case vercel(VercelDestinationForm)
	case coolify(CoolifyDestinationForm)
	case netlify(NetlifyDestinationForm)
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
	/// The branch's name as typed, for a branch's deploys.
	var branch: String {
		didSet { if branch != oldValue, contextChoice == .branch { didChange() } }
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
