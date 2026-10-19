import Foundation

/// A Cloudflare login's approval of LPM Vault, checked and read: whose it
/// is, the accounts it reaches, and its tokens. The tokens never appear when
/// it's printed, logged or dumped.
struct CloudflareConnection: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
	/// The login's key; see `CloudflareLogin.key(subject:)`.
	let login: String
	let accounts: [CloudflareAccount]
	let grant: CloudflareGrant
	let issuer: PlatformIssuer
	let clientID: String
	/// The approval's generation, new with every connection.
	let generation: String
	/// When the Registry completed the grant, which its tokens' lifetimes count from.
	let receivedAt: Date

	var connectionID: PlatformConnection.ID { PlatformConnection.cloudflareID(issuer: issuer, login: login) }

	var description: String { "CloudflareConnection(\(generation), \(accounts.count) accounts, tokens: <redacted>)" }
	var debugDescription: String { description }
	var customMirror: Mirror { Mirror(self, children: ["generation": generation, "accounts": accounts.count, "issuer": issuer]) }
}

/// Connects a Cloudflare login in the browser through the Registry; see
/// `BrowserAuthorization`. Once the grant is collected, every way out but
/// handing it over revokes it: a cancellation, or a login whose identity or
/// accounts don't check out, through `discard`, which writes a cleanup entry
/// when the revocation can't be confirmed at once.
struct CloudflareConnector: Sendable {
	typealias IdentityFactory = @Sendable (String) -> any CloudflareIdentityProtocol
	/// Revokes a grant LPM Vault won't keep; see `PlatformCredentials.discard`.
	typealias Discard = @Sendable (_ refreshToken: String, _ connectionID: PlatformConnection.ID, _ generation: String, _ issuer: PlatformIssuer, _ clientID: String) async -> Void

	/// The connection a grant whose login isn't known yet is discarded under; no record is ever saved there.
	static let unknownLogin = "cloudflare.unknown"

	var authorization: BrowserAuthorization
	let identity: IdentityFactory
	let discard: Discard
	var now: @Sendable () -> Date = { Date() }
	var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
	/// How many more times the identity and accounts are read after Cloudflare
	/// couldn't answer or was limiting requests: the grant can't be collected again.
	var readRetries = 2
	var retryDelay: Duration = .seconds(1)
	var productionClientID: String? = CloudflareOAuth.productionClientID

	init(
		authorization: BrowserAuthorization = BrowserAuthorization(),
		identity: @escaping IdentityFactory = { CloudflareClient(token: $0) },
		discard: @escaping Discard
	) {
		self.authorization = authorization
		self.identity = identity
		self.discard = discard
	}

	/// Runs one connection: `open` shows Cloudflare's approval page, then
	/// this waits for the browser, collects the tokens, and reads whose they
	/// are and the accounts they reach.
	func connect(
		session: PlatformSession,
		open: @escaping @Sendable (URL) async -> Void
	) async -> Result<CloudflareConnection, BrowserConnectError> {
		let issuer = session.issuer
		guard CloudflareOAuth.isAvailable(through: issuer, productionClientID: productionClientID) else { return .failure(.unavailable) }
		let productionClientID = productionClientID
		let collected: BrowserGrant<CloudflareGrant>
		switch await authorization.grant(
			CloudflareGrant.self, session: session, collectsAfterReturn: true,
			acceptsPage: { page in
				PlatformAuthorizationClient.cloudflareClientID(of: page)
					.map { CloudflareOAuth.accepts($0, for: issuer, productionClientID: productionClientID) } ?? false
			},
			open: open)
		{
		case .success(let value): collected = value
		case .failure(let error): return .failure(error)
		}
		guard let clientID = PlatformAuthorizationClient.cloudflareClientID(of: collected.pageURL) else { return .failure(.invalidResponse) }
		let grant = collected.grant
		let generation = CloudflareConnectionAccount.makeGeneration()
		func dropped(_ error: BrowserConnectError, login: String? = nil) async -> Result<CloudflareConnection, BrowserConnectError> {
			let connectionID = login.map { PlatformConnection.cloudflareID(issuer: issuer, login: $0) } ?? Self.unknownLogin
			await discard(grant.expiry.refreshToken, connectionID, generation, issuer, clientID)
			return .failure(error)
		}
		if collected.wasCancelled { return await dropped(.cancelled) }
		let receivedAt = now().addingTimeInterval(-TimeInterval(collected.age))
		// One already due is still good for the moments reading it takes, and renews on first use; one expired isn't.
		guard receivedAt.addingTimeInterval(TimeInterval(grant.expiry.accessTokenLifetime)) > now() else { return await dropped(.expired) }

		let cloudflare = identity(grant.tokens.accessToken)
		let subject: String
		switch await read({ await cloudflare.userInfo(clientID: clientID) }) {
		case .success(let info): subject = info.subject
		case .failure(let error): return await dropped(error)
		}
		let login = CloudflareLogin.key(subject: subject)
		let accounts: [CloudflareAccount]
		switch await read({ await cloudflare.accounts() }) {
		case .success(let value) where value.isEmpty: return await dropped(.noAccounts, login: login)
		case .success(let value): accounts = value
		case .failure(let error): return await dropped(error, login: login)
		}
		if Task.isCancelled { return await dropped(.cancelled, login: login) }
		return .success(CloudflareConnection(
			login: login, accounts: accounts, grant: grant, issuer: issuer, clientID: clientID, generation: generation, receivedAt: receivedAt))
	}

	/// One read of the new grant, asked again after Cloudflare couldn't
	/// answer or limited requests, up to `readRetries` more times.
	private func read<Value: Sendable>(_ request: @Sendable () async -> Result<Value, CloudflareAPIError>) async -> Result<Value, BrowserConnectError> {
		for attempt in 0...readRetries {
			let wait: Duration
			var lifts: Date?
			let giveUp: BrowserConnectError
			switch await request() {
			case .success(let value):
				return .success(value)
			case .failure(.unauthorized), .failure(.forbidden):
				return .failure(.tokenRejected)
			case .failure(.cancelled):
				return .failure(.cancelled)
			case .failure(.rateLimited(let until)):
				guard let limit = PlatformRateLimit.wait(until: until, maximum: CloudflarePublishing.maximumRateLimitWait, now: now()) else {
					return .failure(.platformRateLimited(until: until))
				}
				wait = limit
				lifts = until
				giveUp = .platformRateLimited(until: until)
			case .failure(.transport), .failure(.unreachable), .failure(.server):
				wait = retryDelay * (attempt + 1)
				giveUp = .transport
			case .failure(.notFound), .failure(.refused), .failure(.invalidResponse), .failure(.moved), .failure(.credentials), .failure(.renewed):
				return .failure(.accountUnreadable)
			}
			guard attempt < readRetries else { return .failure(giveUp) }
			do {
				try await PlatformRateLimit.waitOut(wait, until: lifts, atMost: CloudflarePublishing.maximumRateLimitWait, date: now, sleep: sleep)
			} catch {
				return .failure(.cancelled)
			}
		}
		return .failure(.transport)
	}
}
