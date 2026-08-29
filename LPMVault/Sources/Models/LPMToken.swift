import Foundation

struct LPMToken: Codable, Identifiable, Sendable {
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
		return AuthSessionTimestamp.parse(expiresAt)
	}

	var daysUntilExpiry: Int? {
		daysUntilExpiry(at: Date())
	}

	func daysUntilExpiry(at now: Date) -> Int? {
		guard let date = expiresDate else { return nil }
		let interval = date.timeIntervalSince(now)
		if interval < 0 { return -1 }
		return Int(ceil(interval / 86_400))
	}

	var expiryStatus: ExpiryStatus {
		expiryStatus(at: Date())
	}

	func expiryStatus(at now: Date) -> ExpiryStatus {
		guard let date = expiresDate else { return .noExpiry }
		if date <= now { return .expired }
		guard let days = daysUntilExpiry(at: now) else { return .noExpiry }
		if days < 0 { return .expired }
		if days <= 7 { return .critical }
		if days <= 30 { return .warning }
		return .healthy
	}

	enum ExpiryStatus: Sendable {
		case healthy    // >30 days
		case warning    // 7-30 days
		case critical   // <7 days
		case expired
		case noExpiry
	}
}
