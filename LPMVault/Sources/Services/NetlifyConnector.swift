import Foundation

/// A Netlify user's authorization of LPM Vault. The token never appears
/// when it's printed, logged or dumped.
struct NetlifyConnection: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
	let user: NetlifyUser
	let token: String

	var description: String { "NetlifyConnection(user: \(user.id), token: <redacted>)" }
	var debugDescription: String { description }
	var customMirror: Mirror { Mirror(self, children: ["user": user.id]) }
}

/// Connects a Netlify account in the browser through LPM Vault's OAuth app
/// on Netlify; see `BrowserAuthorization`. The token reaches every team of
/// the Netlify user who approves it.
struct NetlifyConnector: Sendable {
	typealias ClientFactory = @Sendable (String) -> any NetlifyClientProtocol

	var authorization: BrowserAuthorization
	let client: ClientFactory
	/// How many more times the user is read after Netlify couldn't answer or
	/// was limiting requests. A connection is saved under its user, and its
	/// grant can't be collected again.
	var userRetries = 2
	var retryDelay: Duration = .seconds(1)

	init(
		authorization: BrowserAuthorization = BrowserAuthorization(),
		client: @escaping ClientFactory = { NetlifyClient(token: $0) }
	) {
		self.authorization = authorization
		self.client = client
	}

	/// Runs one connection: `open` shows Netlify's Authorize page, then this
	/// waits for the browser, collects the token and reads whose it is.
	func connect(
		session: PlatformSession,
		open: @escaping @Sendable (URL) async -> Void
	) async -> Result<NetlifyConnection, BrowserConnectError> {
		let grant: NetlifyGrant
		switch await authorization.grant(NetlifyGrant.self, session: session, open: open) {
		case .success(let value): grant = value
		case .failure(let error): return .failure(error)
		}

		let netlify = client(grant.accessToken)
		for attempt in 0...userRetries {
			let wait: Duration
			var lifts: Date?
			let giveUp: BrowserConnectError
			switch await netlify.user() {
			case .success(let user):
				return .success(NetlifyConnection(user: user, token: grant.accessToken))
			case .failure(.unauthorized), .failure(.forbidden):
				return .failure(.tokenRejected)
			case .failure(.cancelled):
				return .failure(.cancelled)
			case .failure(.rateLimited(let reset)):
				guard let limit = NetlifyHTTP.rateLimitWait(until: reset) else { return .failure(.platformRateLimited) }
				wait = limit
				lifts = reset
				giveUp = .platformRateLimited
			case .failure(.transport), .failure(.server):
				wait = retryDelay * (attempt + 1)
				giveUp = .transport
			case .failure(.notFound), .failure(.rejected), .failure(.invalidResponse):
				return .failure(.accountUnreadable)
			}
			guard attempt < userRetries else { return .failure(giveUp) }
			do { try await NetlifyHTTP.waitOut(wait, until: lifts) } catch { return .failure(.cancelled) }
		}
		return .failure(.transport)
	}
}
