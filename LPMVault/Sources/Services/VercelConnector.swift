import Foundation

/// Connects a Vercel account in the browser through the LPM Vault
/// integration; see `BrowserAuthorization`.
struct VercelConnector: Sendable {
	typealias ClientFactory = @Sendable (String) -> any VercelClientProtocol

	var authorization: BrowserAuthorization
	let client: ClientFactory

	init(
		authorization: BrowserAuthorization = BrowserAuthorization(),
		client: @escaping ClientFactory = { VercelClient(token: $0) }
	) {
		self.authorization = authorization
		self.client = client
	}

	/// Runs one connection: `open` shows Vercel's install page, then this
	/// waits for the browser, collects the grant and checks it with Vercel.
	func connect(
		session: PlatformSession,
		open: @escaping @Sendable (URL) async -> Void
	) async -> Result<(grant: VercelGrant, account: VercelAccount), BrowserConnectError> {
		let grant: VercelGrant
		switch await authorization.grant(VercelGrant.self, session: session, open: open) {
		case .success(let value): grant = value
		case .failure(let error): return .failure(error)
		}

		switch await client(grant.accessToken).account(teamID: grant.teamID) {
		case .success(let account):
			return .success((grant, account))
		case .failure(.unauthorized), .failure(.forbidden):
			return .failure(.tokenRejected)
		case .failure(.cancelled):
			return .failure(.cancelled)
		case .failure:
			// The grant is good but its name couldn't be read now; it can't be collected again.
			return .success((grant, VercelAccount(name: grant.teamID == nil ? "Personal account" : "Vercel team", slug: nil)))
		}
	}
}
