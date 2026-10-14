import Foundation

enum CoolifyConnectError: Error, Equatable, Sendable {
	case invalidAddress
	case insecureAddress
	case invalidToken
	case unauthorized
	case apiDisabled
	case addressNotAllowed
	case missingPermission
	case roleTooLow
	case forbidden
	/// The address answered, but not as Coolify's API.
	case notCoolify
	case redirected
	case untrustedCertificate
	case rateLimited
	case unreachable
	case cancelled
	case invalidResponse

	var message: String {
		switch self {
		case .invalidAddress: "Enter your Coolify address, such as https://coolify.example.com."
		case .insecureAddress: "Coolify's address must start with https://, so the token isn't sent unencrypted. For an instance without a domain, open an SSH tunnel and use http://localhost with the tunnel's port."
		case .invalidToken: "Paste the whole API token Coolify showed when you created it."
		case .unauthorized: "Coolify didn't accept this token. It may be mistyped or revoked."
		case .apiDisabled: "Coolify's API is turned off. Turn on API access in Coolify's Settings → Advanced, then connect again."
		case .addressNotAllowed: "Coolify accepts API requests only from allowed IP addresses. Add this Mac's address to Allowed API IPs in Coolify's Settings → Advanced, then connect again."
		case .missingPermission: "This token can't read its team. Create a token with the Read and Write permissions."
		case .roleTooLow: "Only a team's admins and owners can use a token with write permissions. Ask an admin of the team to connect, or to make you an admin."
		case .forbidden: "Coolify refused this token."
		case .notCoolify: "That address doesn't answer like Coolify. Check the address."
		case .redirected: "That address redirects somewhere else. Enter the address Coolify itself uses."
		case .untrustedCertificate: "This Mac doesn't trust the certificate at that address, so the token wasn't sent."
		case .rateLimited: "Coolify is limiting requests. Wait a minute, then try again."
		case .unreachable: "Coolify couldn't be reached at that address. Check the address and your network."
		case .cancelled: "Connecting Coolify was cancelled."
		case .invalidResponse: "That address answered in a way LPM Vault couldn't read. Check the address."
		}
	}
}

/// A Coolify team reached with an API token. The token never appears when
/// it's printed, logged or dumped.
struct CoolifyConnection: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
	let instance: CoolifyInstance
	let team: CoolifyTeam
	let token: String

	var description: String { "CoolifyConnection(\(instance.origin), team: \(team.id), token: <redacted>)" }
	var debugDescription: String { description }
	var customMirror: Mirror { Mirror(self, children: ["instance": instance.origin, "team": team.id]) }
}

/// Connects a team on a Coolify instance with an API token the person
/// created there. The token is checked with Coolify before anything is saved.
struct CoolifyConnector: Sendable {
	typealias ClientFactory = @Sendable (CoolifyInstance, String) -> any CoolifyClientProtocol

	let client: ClientFactory

	init(client: @escaping ClientFactory = { CoolifyClient(instance: $0, token: $1) }) {
		self.client = client
	}

	/// The instance at `address`, the team `token` belongs to, and the token as it's stored.
	func connect(address: String, token: String) async -> Result<CoolifyConnection, CoolifyConnectError> {
		let instance: CoolifyInstance
		switch CoolifyInstance.parse(address) {
		case .success(let value): instance = value
		case .failure(.invalid): return .failure(.invalidAddress)
		case .failure(.insecure): return .failure(.insecureAddress)
		}
		let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
		guard CoolifyClient.isValidAccessToken(token) else { return .failure(.invalidToken) }
		return await client(instance, token).team()
			.map { CoolifyConnection(instance: instance, team: $0, token: token) }
			.mapError(Self.connectError)
	}

	private static func connectError(_ error: CoolifyAPIError) -> CoolifyConnectError {
		switch error {
		case .unauthorized: .unauthorized
		case .apiDisabled: .apiDisabled
		case .addressNotAllowed: .addressNotAllowed
		case .missingPermission: .missingPermission
		case .roleTooLow: .roleTooLow
		case .forbidden: .forbidden
		case .notFound, .conflict, .rejected, .server: .notCoolify
		case .redirected: .redirected
		case .untrustedCertificate: .untrustedCertificate
		case .rateLimited: .rateLimited
		case .transport: .unreachable
		case .cancelled: .cancelled
		case .invalidResponse: .invalidResponse
		}
	}
}
