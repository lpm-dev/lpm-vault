import Foundation

/// A platform account this Mac can publish to. The access token stays in
/// this Mac's Keychain and isn't part of the connection.
struct PlatformConnection: Identifiable, Hashable, Sendable {
	enum Account: Hashable, Sendable {
		case vercel(VercelConnectionAccount)
	}

	/// The same for every connection to one platform account, so connecting
	/// that account again replaces it.
	var id: String { Self.id(for: account) }
	let account: Account
	let connectedAt: Date

	var platform: PublishPlatform {
		switch account {
		case .vercel: .vercel
		}
	}

	/// The account's name, such as a Vercel team's.
	var name: String {
		switch account {
		case .vercel(let vercel): vercel.name
		}
	}

	static func id(for account: Account) -> String {
		switch account {
		case .vercel(let vercel): vercelID(accountID: vercel.ownerID)
		}
	}

	/// The connection to the Vercel team, or personal account, with this ID.
	static func vercelID(accountID: String) -> String {
		"vercel.\(accountID)"
	}
}

/// A Vercel team, or a personal account, reached through one installation
/// of the LPM Vault integration.
struct VercelConnectionAccount: Hashable, Sendable {
	let installationID: String
	/// Nil for a personal account.
	let teamID: String?
	let userID: String
	let name: String
	let slug: String?

	/// The team, or for a personal account the user, whose projects the connection reaches.
	var ownerID: String { teamID ?? userID }
	var isTeam: Bool { teamID != nil }
}
