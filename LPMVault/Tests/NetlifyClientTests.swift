import Foundation
import Testing
@testable import LPMVault

struct NetlifyClientTests {
	private func tickets(_ route: PlatformHTTPStub.Route) -> NetlifyAuthorizationClient {
		NetlifyAuthorizationClient(baseURL: route.baseURL, session: route.session)
	}

	private func client(_ route: PlatformHTTPStub.Route) -> NetlifyClient {
		NetlifyClient(token: "nfo_secret", baseURL: route.baseURL, session: route.session)
	}

	@Test("a ticket is started with the client ID and no token, and reads as waiting until Netlify says it's authorized")
	func createsTicket() async throws {
		let route = PlatformHTTPStub.platform { request in
			switch request.url.path() {
			case "/api/v1/oauth/tickets": .json(201, ["id": "fbcfa897596f279a9396ec7ae7eaf868", "client_id": "lpm_client", "authorized": NSNull(), "message": NSNull()])
			default: .json(200, ["id": "fbcfa897596f279a9396ec7ae7eaf868", "authorized": true])
			}
		}
		let ticket = try await tickets(route).createTicket(clientID: "lpm_client").get()
		#expect(ticket == NetlifyTicket(id: "fbcfa897596f279a9396ec7ae7eaf868", isAuthorized: false))
		let request = try #require(route.requests.first)
		#expect(request.method == "POST" && request.query["client_id"] == "lpm_client")
		#expect(request.header("Authorization") == nil)
		#expect(request.header("User-Agent") == NetlifyHTTP.userAgent)

		#expect(try await tickets(route).ticket(ticket.id).get().isAuthorized)
		#expect(route.requests.last?.url.path() == "/api/v1/oauth/tickets/fbcfa897596f279a9396ec7ae7eaf868")
	}

	@Test("an answer about another ticket, or an ID that isn't safe in a path, is refused")
	func refusesForeignTickets() async {
		let other = PlatformHTTPStub.platform { _ in .json(200, ["id": "another", "authorized": true]) }
		#expect(await tickets(other).ticket("mine") == .failure(.invalidResponse))
		let unsafe = PlatformHTTPStub.platform { _ in .json(200, ["id": "../x", "authorized": false]) }
		#expect(await tickets(unsafe).createTicket(clientID: "lpm_client") == .failure(.invalidResponse))
		#expect(await tickets(unsafe).ticket("../user") == .failure(.invalidResponse))
		#expect(await tickets(unsafe).exchange("a/b") == .failure(.invalidResponse))
		#expect(unsafe.requests.count == 1, "Unsafe IDs never reach Netlify")
	}

	@Test("exchanging an approved ticket reads the token and whose it is; a malformed token is refused")
	func exchanges() async throws {
		let route = PlatformHTTPStub.platform { _ in
			.json(201, ["id": "tok_1", "access_token": "nfo_granted", "user_id": "5f1a2b3c4d5e6f7a8b9c0d1e", "user_email": "tolga@example.com\u{202E}"])
		}
		let grant = try await tickets(route).exchange("ticket_1").get()
		#expect(grant.accessToken == "nfo_granted" && grant.userID == "5f1a2b3c4d5e6f7a8b9c0d1e")
		#expect(grant.email == #"tolga@example.com\u{202e}"#)
		#expect(route.requests.first?.method == "POST" && route.requests.first?.url.path() == "/api/v1/oauth/tickets/ticket_1/exchange")
		#expect(route.requests.first?.header("Authorization") == nil)

		let spaced = PlatformHTTPStub.platform { _ in .json(201, ["access_token": "nfo has space", "user_id": "u1"]) }
		#expect(await tickets(spaced).exchange("ticket_1") == .failure(.invalidResponse))
		let foreignUser = PlatformHTTPStub.platform { _ in .json(201, ["access_token": "nfo_ok", "user_id": "../u"]) }
		#expect(await tickets(foreignUser).exchange("ticket_1") == .failure(.invalidResponse))
	}

	@Test("the user is read with the token, and its names have their direction controls escaped")
	func readsUser() async throws {
		let route = PlatformHTTPStub.platform { _ in
			.json(200, ["id": "5f1a2b3c4d5e6f7a8b9c0d1e", "full_name": "Tolga\u{2066}", "email": "tolga@example.com", "site_count": 3])
		}
		let user = try await client(route).user().get()
		#expect(user == NetlifyUser(id: "5f1a2b3c4d5e6f7a8b9c0d1e", name: #"Tolga\u{2066}"#, email: "tolga@example.com"))
		let request = try #require(route.requests.first)
		#expect(request.url.path() == "/api/v1/user" && request.header("Authorization") == "Bearer nfo_secret")
	}

	@Test(
		"each refusal maps to what it means, and Netlify's message is never kept",
		arguments: [
			(401, NetlifyAPIError.unauthorized), (403, .forbidden), (404, .notFound), (422, .rejected(status: 422)),
			(429, .rateLimited(until: Date(timeIntervalSince1970: 1_800_000_000))), (500, .server(500)), (302, .server(302)),
		]
	)
	func refusals(status: Int, expected: NetlifyAPIError) async {
		let route = PlatformHTTPStub.platform { _ in
			.json(status, ["code": status, "message": "nfo_secret was refused"], headers: ["X-RateLimit-Reset": "1800000000", "Location": "https://elsewhere.test/"])
		}
		#expect(await client(route).user() == .failure(expected))
		#expect(route.requests.count == 1, "A redirect is never followed")
	}

	@Test("a cancelled task sends nothing")
	func cancelledSendsNothing() async {
		let route = PlatformHTTPStub.platform { _ in .json(200, ["id": "u1"]) }
		let client = client(route)
		let task = Task {
			withUnsafeCurrentTask { $0?.cancel() }
			return await client.user()
		}
		#expect(await task.value == .failure(.cancelled))
		#expect(route.requests.isEmpty)
	}

	@Test("clients made without a session share one, so connecting leaves no session behind")
	func sharesSession() {
		#expect(NetlifyClient(token: "a").session === NetlifyClient(token: "b").session)
		#expect(NetlifyAuthorizationClient().session === NetlifyClient(token: "a").session)
	}

	@Test("a client, a grant, a ticket or a connection never prints its token or the ticket's ID")
	func redacted() {
		let values: [Any] = [
			NetlifyClient(token: "nfo_secret_token"),
			NetlifyGrant(accessToken: "nfo_secret_token", userID: "u1", email: nil),
			NetlifyTicket(id: "ticket_secret_token", isAuthorized: true),
			NetlifyConnection(user: NetlifyUser(id: "u1", name: "Tolga", email: nil), token: "nfo_secret_token"),
		]
		for value in values {
			var dumped = ""
			dump(value, to: &dumped)
			for text in [String(describing: value), String(reflecting: value), dumped] {
				#expect(!text.contains("secret_token"), "\(text)")
			}
		}
	}
}

/// Answers a connector's ticket calls from a script, and records them.
private final class FakeTickets: NetlifyAuthorizationClientProtocol, @unchecked Sendable {
	private let lock = NSLock()
	var created: Result<NetlifyTicket, NetlifyAPIError> = .success(NetlifyTicket(id: "ticket_1", isAuthorized: false))
	/// Each check's answer in turn; the last one repeats.
	var checks: [Result<NetlifyTicket, NetlifyAPIError>] = [.success(NetlifyTicket(id: "ticket_1", isAuthorized: true))]
	var exchanges: [Result<NetlifyGrant, NetlifyAPIError>] = [.success(NetlifyGrant(accessToken: "nfo_granted", userID: "u1", email: "tolga@example.com"))]
	private var log: [String] = []

	var calls: [String] { lock.withLock { log } }

	func createTicket(clientID: String) async -> Result<NetlifyTicket, NetlifyAPIError> {
		lock.withLock {
			log.append("create \(clientID)")
			return created
		}
	}

	func ticket(_ id: String) async -> Result<NetlifyTicket, NetlifyAPIError> {
		lock.withLock {
			log.append("check \(id)")
			return checks.count > 1 ? checks.removeFirst() : checks[0]
		}
	}

	func exchange(_ ticketID: String) async -> Result<NetlifyGrant, NetlifyAPIError> {
		lock.withLock {
			log.append("exchange \(ticketID)")
			return exchanges.count > 1 ? exchanges.removeFirst() : exchanges[0]
		}
	}
}

private struct FakeNetlify: NetlifyClientProtocol {
	var user: Result<NetlifyUser, NetlifyAPIError> = .success(NetlifyUser(id: "u1", name: "Tolga", email: "tolga@example.com"))
	func user() async -> Result<NetlifyUser, NetlifyAPIError> { user }
}

private final class OpenedPages: @unchecked Sendable {
	private let lock = NSLock()
	private var opened: [URL] = []
	var urls: [URL] { lock.withLock { opened } }
	func append(_ url: URL) { lock.withLock { opened.append(url) } }
}

struct NetlifyConnectorTests {
	private func connector(_ tickets: FakeTickets, netlify: FakeNetlify = FakeNetlify(), tokens: TokenSink? = nil) -> NetlifyConnector {
		var connector = NetlifyConnector(clientID: "lpm_client", authorizations: tickets, client: { token in
			tokens?.append(token)
			return netlify
		})
		connector.pollInterval = .milliseconds(5)
		connector.maximumPollInterval = .milliseconds(20)
		connector.maximumWait = .seconds(5)
		return connector
	}

	@Test("connecting opens Netlify's Authorize page for the ticket, waits for approval, exchanges it once and reads whose token it is")
	func connects() async throws {
		let tickets = FakeTickets()
		let waiting = Result<NetlifyTicket, NetlifyAPIError>.success(NetlifyTicket(id: "ticket_1", isAuthorized: false))
		tickets.checks = [waiting, waiting, .success(NetlifyTicket(id: "ticket_1", isAuthorized: true))]
		let opened = OpenedPages()
		let tokens = TokenSink()
		let connection = try await connector(tickets, tokens: tokens).connect { opened.append($0) }.get()
		#expect(opened.urls == [URL(string: "https://app.netlify.com/authorize?response_type=ticket&ticket=ticket_1")!])
		#expect(connection.token == "nfo_granted" && connection.user == NetlifyUser(id: "u1", name: "Tolga", email: "tolga@example.com"))
		#expect(tickets.calls == ["create lpm_client", "check ticket_1", "check ticket_1", "check ticket_1", "exchange ticket_1"])
		#expect(tokens.tokens == ["nfo_granted"])
	}

	@Test("LPM Vault's own client ID is one the ticket request sends, and the connector uses it")
	func shippedClientID() {
		#expect(NetlifyHTTP.isValidIdentifier(VaultConstants.netlifyOAuthClientID))
		#expect(NetlifyConnector().clientID == VaultConstants.netlifyOAuthClientID)
	}

	@Test("Netlify refusing LPM Vault's app ends before any page opens")
	func appRefused() async {
		let tickets = FakeTickets()
		tickets.created = .failure(.unauthorized)
		let opened = OpenedPages()
		#expect(await connector(tickets).connect { opened.append($0) } == .failure(.unavailable))
		#expect(opened.urls.isEmpty)
	}

	@Test("a ticket Netlify drops while the person decides ends the connection as refused, and nothing is exchanged")
	func denied() async {
		let tickets = FakeTickets()
		tickets.checks = [.success(NetlifyTicket(id: "ticket_1", isAuthorized: false)), .failure(.notFound)]
		#expect(await connector(tickets).connect { _ in } == .failure(.denied))
		#expect(!tickets.calls.contains { $0.hasPrefix("exchange") })
	}

	@Test("a ticket not approved in time ends the connection, near its deadline, without an exchange")
	func timesOut() async {
		let tickets = FakeTickets()
		tickets.checks = [.success(NetlifyTicket(id: "ticket_1", isAuthorized: false))]
		var connector = connector(tickets)
		connector.maximumWait = .milliseconds(150)
		let started = ContinuousClock.now
		#expect(await connector.connect { _ in } == .failure(.timedOut))
		#expect(ContinuousClock.now - started < .seconds(10))
		#expect(!tickets.calls.contains { $0.hasPrefix("exchange") })
	}

	@Test("checks Netlify couldn't answer, or answered with a rate limit, don't end the wait once it answers again")
	func survivesTransientChecks() async throws {
		let tickets = FakeTickets()
		tickets.checks = [
			.failure(.transport), .failure(.server(503)), .failure(.rateLimited(until: nil)),
			.success(NetlifyTicket(id: "ticket_1", isAuthorized: true)),
		]
		var connector = connector(tickets)
		connector.maximumPollInterval = .milliseconds(10)
		#expect(try await connector.connect { _ in }.get().token == "nfo_granted")
		#expect(tickets.calls.filter { $0.hasPrefix("check") }.count == 4)
	}

	@Test("an exchange Netlify couldn't answer is tried again; a refused one means the approval is gone")
	func exchangeRetries() async throws {
		let tickets = FakeTickets()
		tickets.exchanges = [.failure(.transport), .success(NetlifyGrant(accessToken: "nfo_second", userID: "u1", email: nil))]
		#expect(try await connector(tickets).connect { _ in }.get().token == "nfo_second")
		#expect(tickets.calls.filter { $0.hasPrefix("exchange") }.count == 2)

		let refused = FakeTickets()
		refused.exchanges = [.failure(.unauthorized)]
		#expect(await connector(refused).connect { _ in } == .failure(.denied))
	}

	@Test("a token Netlify refuses at once isn't kept, and one issued to another user than it says is refused")
	func checksToken() async {
		var rejected = FakeNetlify()
		rejected.user = .failure(.unauthorized)
		#expect(await connector(FakeTickets(), netlify: rejected).connect { _ in } == .failure(.tokenRejected))
		var other = FakeNetlify()
		other.user = .success(NetlifyUser(id: "u2", name: "Someone", email: nil))
		#expect(await connector(FakeTickets(), netlify: other).connect { _ in } == .failure(.invalidResponse))
	}

	@Test("a name Netlify can't return right now doesn't lose a token that can't be collected again")
	func keepsTokenWithoutName() async throws {
		var unreachable = FakeNetlify()
		unreachable.user = .failure(.transport)
		let connection = try await connector(FakeTickets(), netlify: unreachable).connect { _ in }.get()
		#expect(connection.user == NetlifyUser(id: "u1", name: nil, email: "tolga@example.com"))
		let tickets = FakeTickets()
		tickets.exchanges = [.success(NetlifyGrant(accessToken: "nfo_granted", userID: nil, email: nil))]
		#expect(await connector(tickets, netlify: unreachable).connect { _ in } == .failure(.transport))
	}

	@Test("cancelling while the person decides stops waiting at once")
	func cancelWhileWaiting() async throws {
		let tickets = FakeTickets()
		tickets.checks = [.success(NetlifyTicket(id: "ticket_1", isAuthorized: false))]
		var connector = connector(tickets)
		connector.maximumWait = .seconds(60)
		connector.pollInterval = .seconds(30)
		let task = Task { await connector.connect { _ in } }
		try await Task.sleep(for: .milliseconds(30))
		let cancelled = ContinuousClock.now
		task.cancel()
		#expect(await task.value == .failure(.cancelled))
		#expect(ContinuousClock.now - cancelled < .seconds(5))
		#expect(!tickets.calls.contains { $0.hasPrefix("exchange") })
	}
}

private final class TokenSink: @unchecked Sendable {
	private let lock = NSLock()
	private var received: [String] = []
	var tokens: [String] { lock.withLock { received } }
	func append(_ token: String) { lock.withLock { received.append(token) } }
}
