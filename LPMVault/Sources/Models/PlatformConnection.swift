import Foundation

/// A platform account this Mac can publish to. The access token stays in
/// this Mac's Keychain and isn't part of the connection.
struct PlatformConnection: Identifiable, Hashable, Sendable {
	enum Account: Hashable, Sendable {
		case vercel(VercelConnectionAccount)
		case coolify(CoolifyConnectionAccount)
	}

	/// The same for every connection to one platform account, so connecting
	/// that account again replaces it.
	var id: String { Self.id(for: account) }
	let account: Account
	let connectedAt: Date

	var platform: PublishPlatform {
		switch account {
		case .vercel: .vercel
		case .coolify: .coolify
		}
	}

	/// The account's name, such as a Vercel or Coolify team's.
	var name: String {
		switch account {
		case .vercel(let vercel): vercel.name
		case .coolify(let coolify): coolify.teamName
		}
	}

	static func id(for account: Account) -> String {
		switch account {
		case .vercel(let vercel): vercelID(accountID: vercel.ownerID)
		case .coolify(let coolify): coolifyID(instance: coolify.instance, teamID: coolify.teamID)
		}
	}

	/// The connection to the Vercel team, or personal account, with this ID.
	static func vercelID(accountID: String) -> String {
		"vercel.\(accountID)"
	}

	/// The connection to the team with this ID on the Coolify instance.
	static func coolifyID(instance: CoolifyInstance, teamID: String) -> String {
		"coolify.\(teamID).\(instance.origin)"
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

/// A team on a Coolify instance, reached with an API token its member created.
struct CoolifyConnectionAccount: Hashable, Sendable {
	let instance: CoolifyInstance
	let teamID: String
	/// The team's name when it was connected.
	let teamName: String
}

/// A name a platform sends, such as a team's or a project's, made safe to
/// show: trimmed, with each character that could hide or reorder the text
/// around it written as an escape, so a name can't disguise itself or what
/// follows it.
enum ProviderName {
	static let maximumBytes = 512

	/// Nil when nothing is left to show, or the name is too long.
	static func display(_ text: String?) -> String? {
		guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
		let shown = trimmed.escapingDirectionControls
		return shown.utf8.count <= maximumBytes ? shown : nil
	}
}
