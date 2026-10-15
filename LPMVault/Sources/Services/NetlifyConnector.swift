import Foundation

enum NetlifyConnectError: Error, Equatable, Sendable {
	/// Netlify refused LPM Vault's OAuth app.
	case unavailable
	case rateLimited
	/// Netlify dropped the request: it was refused, or it expired there.
	case denied
	/// The person didn't authorize LPM Vault before the connection expired.
	case timedOut
	case cancelled
	/// Netlify refused the token it had just granted.
	case tokenRejected
	case transport
	case invalidResponse

	var message: String {
		switch self {
		case .unavailable: "Connecting Netlify isn't available right now. Try again later."
		case .rateLimited: "Netlify is limiting requests. Wait a minute, then try again."
		case .denied: "Netlify didn't authorize LPM Vault, or the request expired. Connect again."
		case .timedOut: "The connection expired before LPM Vault was authorized on Netlify. Connect again."
		case .cancelled: "Connecting Netlify was cancelled."
		case .tokenRejected: "Netlify didn't accept the new connection. Connect again."
		case .transport: "Netlify couldn't be reached. Check your network and try again."
		case .invalidResponse: "Netlify answered in a way LPM Vault couldn't read. Try again."
		}
	}
}

/// A Netlify user's authorization of LPM Vault. The token never appears
/// when it's printed, logged or dumped.
struct NetlifyConnection: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
	let user: NetlifyUser
	let token: String

	var description: String { "NetlifyConnection(user: \(user.id), token: <redacted>)" }
	var debugDescription: String { description }
	var customMirror: Mirror { Mirror(self, children: ["user": user.id]) }
}

/// Connects a Netlify account through Netlify's OAuth ticket flow, as the
/// Netlify CLI does. LPM Vault's OAuth app starts a ticket with its public
/// client ID, the person approves it on Netlify's page, and this Mac
/// exchanges it for the token straight from Netlify. No client secret is
/// involved, so no server of LPM's ever sees the token.
struct NetlifyConnector: Sendable {
	typealias ClientFactory = @Sendable (String) -> any NetlifyClientProtocol

	static let authorizeURL = URL(string: "https://app.netlify.com/authorize")!

	let clientID: String
	let authorizations: any NetlifyAuthorizationClientProtocol
	let client: ClientFactory
	/// How long the person has to approve the ticket.
	var maximumWait: Duration = .seconds(15 * 60)
	/// How often the ticket is checked while the person decides.
	var pollInterval: Duration = .seconds(2)
	/// The longest wait between checks after Netlify couldn't answer.
	var maximumPollInterval: Duration = .seconds(30)
	/// How many more times an exchange is tried after Netlify couldn't answer it.
	var exchangeRetries = 2
	var now: @Sendable () -> Date = { Date() }

	init(
		clientID: String = VaultConstants.netlifyOAuthClientID,
		authorizations: any NetlifyAuthorizationClientProtocol = NetlifyAuthorizationClient(),
		client: @escaping ClientFactory = { NetlifyClient(token: $0) }
	) {
		self.clientID = clientID
		self.authorizations = authorizations
		self.client = client
	}

	/// The page where the person approves `ticket`.
	static func authorizeURL(for ticket: NetlifyTicket) -> URL? {
		guard var components = URLComponents(url: authorizeURL, resolvingAgainstBaseURL: false) else { return nil }
		components.queryItems = [URLQueryItem(name: "response_type", value: "ticket"), URLQueryItem(name: "ticket", value: ticket.id)]
		return components.url
	}

	/// Runs one connection: `open` shows Netlify's Authorize page, then this
	/// waits for the person's approval, collects the token and reads whose it is.
	func connect(open: @escaping @Sendable (URL) async -> Void) async -> Result<NetlifyConnection, NetlifyConnectError> {
		guard !Task.isCancelled else { return .failure(.cancelled) }
		let ticket: NetlifyTicket
		switch await authorizations.createTicket(clientID: clientID) {
		case .success(let value): ticket = value
		case .failure(.unauthorized), .failure(.forbidden), .failure(.notFound), .failure(.rejected): return .failure(.unavailable)
		case .failure(let error): return .failure(Self.connectError(error))
		}
		guard let url = Self.authorizeURL(for: ticket) else { return .failure(.invalidResponse) }
		guard !Task.isCancelled else { return .failure(.cancelled) }
		await open(url)

		if let failure = await waitForApproval(of: ticket) { return .failure(failure) }

		let grant: NetlifyGrant
		switch await exchange(ticket) {
		case .success(let value): grant = value
		case .failure(let error): return .failure(error)
		}

		switch await client(grant.accessToken).user() {
		case .success(let user):
			guard grant.userID.map({ $0 == user.id }) ?? true else { return .failure(.invalidResponse) }
			return .success(NetlifyConnection(user: NetlifyUser(id: user.id, name: user.name, email: user.email ?? grant.email), token: grant.accessToken))
		case .failure(.unauthorized), .failure(.forbidden):
			return .failure(.tokenRejected)
		case .failure(.cancelled):
			return .failure(.cancelled)
		case .failure(let error):
			// The ticket can't be exchanged again, so a token Netlify said whose it is is kept without its name.
			guard let userID = grant.userID else { return .failure(Self.connectError(error)) }
			return .success(NetlifyConnection(user: NetlifyUser(id: userID, name: nil, email: grant.email), token: grant.accessToken))
		}
	}

	/// Checks the ticket until the person approves it; the reason it ended
	/// otherwise, or nil once it's approved. Checks Netlify couldn't answer
	/// are tried again, each time a little later. The last check is made at
	/// the deadline, so an approval given in time is kept.
	private func waitForApproval(of ticket: NetlifyTicket) async -> NetlifyConnectError? {
		let clock = ContinuousClock()
		let deadline = clock.now.advanced(by: maximumWait)
		var delay = pollInterval
		while true {
			let remaining = clock.now.duration(to: deadline)
			guard remaining > .zero else { return .timedOut }
			do {
				try await Task.sleep(for: min(delay, remaining))
			} catch {
				return .cancelled
			}
			switch await authorizations.ticket(ticket.id) {
			case .success(let current) where current.isAuthorized:
				return nil
			case .success:
				delay = pollInterval
			case .failure(.notFound):
				return .denied
			case .failure(.cancelled):
				return .cancelled
			case .failure(.rateLimited(let until)):
				delay = waitUntil(until)
			case .failure(.transport), .failure(.server):
				delay = min(delay * 2, maximumPollInterval)
			case .failure(.unauthorized), .failure(.forbidden), .failure(.rejected), .failure(.invalidResponse):
				return .invalidResponse
			}
		}
	}

	/// Exchanges the approved ticket, trying again a few times when Netlify
	/// couldn't answer, since the token can't be collected any other way.
	private func exchange(_ ticket: NetlifyTicket) async -> Result<NetlifyGrant, NetlifyConnectError> {
		var delay = pollInterval
		for attempt in 0...exchangeRetries {
			switch await authorizations.exchange(ticket.id) {
			case .success(let grant):
				return .success(grant)
			case .failure(.unauthorized), .failure(.notFound):
				return .failure(.denied)
			case .failure(let error) where attempt < exchangeRetries && Self.isTransient(error):
				if case .rateLimited(let until) = error { delay = waitUntil(until) }
				do { try await Task.sleep(for: delay) } catch { return .failure(.cancelled) }
				delay = min(delay * 2, maximumPollInterval)
			case .failure(let error):
				return .failure(Self.connectError(error))
			}
		}
		return .failure(.transport)
	}

	/// How long to wait for a rate limit that lifts at `until`, within the polling bounds.
	private func waitUntil(_ until: Date?) -> Duration {
		guard let until else { return maximumPollInterval }
		let seconds = until.timeIntervalSince(now())
		guard seconds.isFinite, seconds > 0 else { return pollInterval }
		return min(max(.milliseconds(Int64(seconds * 1_000)), pollInterval), maximumPollInterval * 2)
	}

	private static func isTransient(_ error: NetlifyAPIError) -> Bool {
		switch error {
		case .transport, .server, .rateLimited: true
		default: false
		}
	}

	private static func connectError(_ error: NetlifyAPIError) -> NetlifyConnectError {
		switch error {
		case .unauthorized, .forbidden: .tokenRejected
		case .notFound: .denied
		case .rateLimited: .rateLimited
		case .transport, .server: .transport
		case .cancelled: .cancelled
		case .rejected, .invalidResponse: .invalidResponse
		}
	}
}
