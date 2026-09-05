import Foundation

struct LPMUser: Codable, Identifiable, Sendable {
	let id: String
	let username: String
	let name: String?
	let email: String?
	let avatarUrl: String?
	let plan: String?
	let createdAt: String?
	let orgs: [LPMOrg]?

	var hasValidRoutingIdentity: Bool {
		guard Self.isValidIdentityComponent(id),
			Self.isValidIdentityComponent(username),
			(orgs?.count ?? 0) <= 256
		else { return false }
		var organizationIDs: Set<String> = []
		var organizationSlugs: Set<String> = []
		for organization in orgs ?? [] {
			guard Self.isValidIdentityComponent(organization.id),
				EnvValidation.isSafeOrgSlug(organization.slug),
				organizationIDs.insert(organization.id).inserted,
				organizationSlugs.insert(organization.slug).inserted
			else { return false }
		}
		return true
	}

	private static func isValidIdentityComponent(_ value: String) -> Bool {
		!value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
			&& value.utf8.count <= 256
			&& !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
	}
}
