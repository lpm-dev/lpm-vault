import Foundation

struct LPMUser: Codable, Identifiable {
	let id: String
	let username: String
	let name: String?
	let email: String?
	let avatarUrl: String?
	let plan: String?
	let createdAt: String?
	let orgs: [LPMOrg]?
}
