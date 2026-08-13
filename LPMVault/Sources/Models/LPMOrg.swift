import Foundation

struct LPMOrg: Codable, Identifiable, Sendable {
	let id: String
	let slug: String
	let name: String
	let avatarUrl: String?
	let role: String?
}
