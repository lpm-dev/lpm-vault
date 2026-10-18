import Foundation

/// A platform account this Mac can publish to. The access token stays in
/// this Mac's Keychain and isn't part of the connection.
struct PlatformConnection: Identifiable, Hashable, Sendable {
	enum Account: Hashable, Sendable {
		case vercel(VercelConnectionAccount)
		case coolify(CoolifyConnectionAccount)
		case netlify(NetlifyConnectionAccount)
		case github(GitHubConnectionAccount)
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
		case .netlify: .netlify
		case .github: .github
		}
	}

	/// The account's name, such as a Vercel or Coolify team's, or a Netlify or GitHub user's.
	var name: String {
		switch account {
		case .vercel(let vercel): vercel.name
		case .coolify(let coolify): coolify.teamName
		case .netlify(let netlify): netlify.name
		case .github(let github): github.name ?? github.login
		}
	}

	/// What tells the account apart from another with the same name: a
	/// Vercel team's slug, a personal account's username or else its user,
	/// the Coolify instance's address and the team's ID there, a Netlify
	/// user's email or else its ID, or a GitHub user's login.
	var detail: String {
		switch account {
		case .vercel(let vercel) where vercel.isTeam: vercel.slug ?? vercel.ownerID
		case .vercel(let vercel): "personal · \(vercel.slug ?? vercel.userID)"
		case .coolify(let coolify): "\(coolify.instance.address) · team \(coolify.teamID)"
		case .netlify(let netlify): netlify.email ?? "user \(netlify.userID)"
		case .github(let github): "@\(github.login)"
		}
	}

	static func id(for account: Account) -> String {
		switch account {
		case .vercel(let vercel): vercelID(accountID: vercel.ownerID)
		case .coolify(let coolify): coolifyID(instance: coolify.instance, teamID: coolify.teamID)
		case .netlify(let netlify): netlifyID(userID: netlify.userID)
		case .github(let github): githubID(userID: github.userID)
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

	/// The connection to the Netlify user with this ID.
	static func netlifyID(userID: String) -> String {
		"netlify.\(userID)"
	}

	/// The connection to the GitHub user with this numeric ID.
	static func githubID(userID: String) -> String {
		"github.\(userID)"
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

/// A Netlify user who authorized LPM Vault. Netlify's tokens reach every
/// team the user belongs to, so one connection serves all of them.
struct NetlifyConnectionAccount: Hashable, Sendable {
	let userID: String
	/// The user's name when it was connected, or else its email.
	let name: String
	let email: String?
}

/// A GitHub user who authorized LPM Vault's GitHub App. One connection
/// reaches every account the app is installed on that the user can reach.
struct GitHubConnectionAccount: Hashable, Sendable {
	/// GitHub's numeric ID for the user.
	let userID: String
	/// The user's login when it was connected.
	let login: String
	/// The user's profile name when it was connected; nil when they have none.
	let name: String?
	/// The slug of the GitHub App the connection authorized, whose page
	/// installs it on more accounts and repositories.
	let appSlug: String

	/// The page where the person installs LPM Vault's app on an account and
	/// chooses its repositories.
	var installURL: URL? {
		URL(string: "https://github.com/apps/\(appSlug)/installations/new")
	}
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
