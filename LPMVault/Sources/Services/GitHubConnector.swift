import Foundation

/// A GitHub user's authorization of LPM Vault's GitHub App, with when its
/// tokens arrived. The tokens never appear when it's printed, logged or dumped.
struct GitHubConnection: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
	let user: GitHubUser
	let tokens: PlatformTokens
	let appSlug: String
	/// When the grant was opened, which the tokens' lifetimes count from.
	let receivedAt: Date

	var description: String { "GitHubConnection(user: \(user.id), app: \(appSlug), tokens: <redacted>)" }
	var debugDescription: String { description }
	var customMirror: Mirror { Mirror(self, children: ["user": user.id, "appSlug": appSlug]) }
}

/// Connects a GitHub account in the browser through LPM Vault's GitHub App;
/// see `BrowserAuthorization`. The token reaches the repositories the app is
/// installed on that the person can reach.
struct GitHubConnector: Sendable {
	typealias ClientFactory = @Sendable (String) -> any GitHubClientProtocol

	var authorization: BrowserAuthorization
	let client: ClientFactory
	/// The wall clock, which the grant's arrival and rate limits are read on.
	var now: @Sendable () -> Date = { Date() }
	var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
	/// How many more times the user is read after GitHub couldn't answer or
	/// was limiting requests. A connection is saved under its user, and its
	/// grant can't be collected again.
	var userRetries = 2
	var retryDelay: Duration = .seconds(1)

	init(
		authorization: BrowserAuthorization = BrowserAuthorization(),
		client: @escaping ClientFactory = { GitHubClient(token: $0) }
	) {
		self.authorization = authorization
		self.client = client
	}

	/// Runs one connection: `open` shows GitHub's authorize page, then this
	/// waits for the browser, collects the tokens and reads whose they are.
	func connect(
		session: PlatformSession,
		open: @escaping @Sendable (URL) async -> Void
	) async -> Result<GitHubConnection, BrowserConnectError> {
		let grant: GitHubGrant
		switch await authorization.grant(GitHubGrant.self, session: session, open: open) {
		case .success(let value): grant = value
		case .failure(let error): return .failure(error)
		}
		let receivedAt = now()

		let github = client(grant.tokens.accessToken)
		var rateLimitWaits = 0
		for attempt in 0...userRetries {
			let wait: Duration
			var lifts: Date?
			let giveUp: BrowserConnectError
			switch await github.user() {
			case .success(let user):
				return .success(GitHubConnection(user: user, tokens: grant.tokens, appSlug: grant.appSlug, receivedAt: receivedAt))
			case .failure(.unauthorized), .failure(.forbidden):
				return .failure(.tokenRejected)
			case .failure(.cancelled):
				return .failure(.cancelled)
			case .failure(.rateLimited(nil)):
				// Every limit waited out counts, as GitHub asks for longer waits while one continues.
				wait = GitHubHTTP.unannouncedLimitWait(after: rateLimitWaits)
				rateLimitWaits += 1
				giveUp = .platformRateLimited(until: nil)
			case .failure(.rateLimited(let reset)):
				guard let limit = GitHubHTTP.rateLimitWait(until: reset, now: now()) else { return .failure(.platformRateLimited(until: reset)) }
				wait = limit.wait
				lifts = limit.lifts
				rateLimitWaits += 1
				giveUp = .platformRateLimited(until: reset)
			case .failure(.transport), .failure(.server):
				wait = retryDelay * (attempt + 1)
				giveUp = .transport
			case .failure(.notFound), .failure(.rejected), .failure(.invalidResponse):
				return .failure(.accountUnreadable)
			}
			guard attempt < userRetries else { return .failure(giveUp) }
			do {
				try await PlatformRateLimit.waitOut(wait, until: lifts, atMost: GitHubHTTP.longestRateLimitWait, date: now, sleep: sleep)
			} catch {
				return .failure(.cancelled)
			}
		}
		return .failure(.transport)
	}
}
