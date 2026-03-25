import Foundation

struct LPMToken: Codable, Identifiable {
	let id: String
	let name: String
	let scope: String?
	let expiresAt: String?
	let lastUsedAt: String?
	let downloadCount: Int?
	let createdAt: String?

	/// Org slug this token belongs to (set client-side, not from API)
	var orgSlug: String?

	enum CodingKeys: String, CodingKey {
		case id, name, scope, expiresAt, lastUsedAt, downloadCount, createdAt
	}

	var expiresDate: Date? {
		guard let expiresAt else { return nil }
		return ISO8601DateFormatter().date(from: expiresAt)
	}

	var daysUntilExpiry: Int? {
		guard let date = expiresDate else { return nil }
		return Calendar.current.dateComponents([.day], from: Date(), to: date).day
	}

	var expiryStatus: ExpiryStatus {
		guard let days = daysUntilExpiry else { return .noExpiry }
		if days < 0 { return .expired }
		if days <= 7 { return .critical }
		if days <= 30 { return .warning }
		return .healthy
	}

	enum ExpiryStatus {
		case healthy    // >30 days
		case warning    // 7-30 days
		case critical   // <7 days
		case expired
		case noExpiry
	}
}
