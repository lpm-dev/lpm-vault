import Foundation
import Observation

/// The Destination step's fields for the chosen connection's platform.
enum PublishDestinationForm {
	case vercel(VercelDestinationForm)
	case coolify(CoolifyDestinationForm)
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
