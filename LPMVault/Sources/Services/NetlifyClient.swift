import Foundation

enum NetlifyAPIError: Error, Equatable, Sendable {
	/// The token no longer works, as after the person revokes LPM Vault on Netlify.
	case unauthorized
	/// The token can't reach this team, site or variable.
	case forbidden
	case notFound
	case rateLimited(until: Date?)
	/// Netlify refused the request, with its HTTP status. Its messages are
	/// never shown: one could echo what was sent.
	case rejected(status: Int)
	case transport
	case cancelled
	case invalidResponse
	case server(Int)
}

/// The Netlify user a connection's token belongs to.
struct NetlifyUser: Equatable, Sendable {
	let id: String
	/// The user's full name; nil when Netlify has none to show.
	let name: String?
	let email: String?
}

/// A request to authorize LPM Vault, which the person approves on Netlify's
/// own page. Its ID is a bearer secret until it's exchanged: whoever holds
/// it can collect the token once it's approved.
struct NetlifyTicket: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
	let id: String
	let isAuthorized: Bool

	var description: String { "NetlifyTicket(id: <redacted>, authorized: \(isAuthorized))" }
	var debugDescription: String { description }
	var customMirror: Mirror { Mirror(self, children: ["isAuthorized": isAuthorized]) }
}

/// The access token an approved ticket was exchanged for. The token never
/// appears when it's printed, logged or dumped.
struct NetlifyGrant: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
	let accessToken: String
	/// The user Netlify issued the token to, when it said.
	let userID: String?
	let email: String?

	var description: String { "NetlifyGrant(user: \(userID ?? "?"), accessToken: <redacted>)" }
	var debugDescription: String { description }
	var customMirror: Mirror { Mirror(self, children: ["userID": userID as Any]) }
}

/// Netlify's OAuth tickets, which need no token: LPM Vault's client ID
/// starts one, and the person approves it in the browser.
protocol NetlifyAuthorizationClientProtocol: Sendable {
	func createTicket(clientID: String) async -> Result<NetlifyTicket, NetlifyAPIError>
	/// The ticket as it is now; `notFound` once Netlify refused or dropped it.
	func ticket(_ id: String) async -> Result<NetlifyTicket, NetlifyAPIError>
	/// Collects the token of an approved ticket. Netlify hands it out once.
	func exchange(_ ticketID: String) async -> Result<NetlifyGrant, NetlifyAPIError>
}

protocol NetlifyClientProtocol: Sendable {
	/// The user the token belongs to.
	func user() async -> Result<NetlifyUser, NetlifyAPIError>
}

/// Requests to Netlify's API. They go only to `baseURL`, redirects are
/// refused so a token never follows one, and Netlify's error messages are
/// never read.
enum NetlifyHTTP {
	static let defaultBaseURL = URL(string: "https://api.netlify.com")!
	static let maximumResponseBytes = 2 * 1024 * 1024
	/// Netlify asks API clients to name themselves.
	static let userAgent = "LPM Vault (https://vault.lpm.dev)"

	/// The session clients use unless given one. A session holds its
	/// delegate until it's invalidated, so one per process serves every
	/// client and token: it keeps no cookies, cache or credentials.
	static let sharedSession = URLSession(
		configuration: BoundedHTTPResponse.ephemeralConfiguration(requestTimeout: 20, resourceTimeout: 60),
		delegate: RedirectRefusingHTTPDelegate(),
		delegateQueue: nil
	)

	/// The API URL for `path`, whose parts must already be safe in a path.
	static func url(_ baseURL: URL, _ path: [String], query: [URLQueryItem] = []) -> URL? {
		guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { return nil }
		components.percentEncodedPath = "/api/v1/" + path.joined(separator: "/")
		components.queryItems = query.isEmpty ? nil : query
		components.fragment = nil
		return components.url
	}

	static func request(_ method: String, _ url: URL, token: String?, body: Data? = nil) -> URLRequest {
		var request = URLRequest(url: url)
		request.httpMethod = method
		request.setValue("application/json", forHTTPHeaderField: "Accept")
		request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
		if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
		if let body {
			request.httpBody = body
			request.setValue("application/json", forHTTPHeaderField: "Content-Type")
		}
		return request
	}

	static func load(_ request: URLRequest, using session: URLSession, limit: Int = maximumResponseBytes) async -> Result<Data, NetlifyAPIError> {
		do {
			let (data, response) = try await BoundedHTTPResponse.load(for: request, using: session, maximumBytes: limit)
			guard let http = response as? HTTPURLResponse else { return .failure(.invalidResponse) }
			guard (200..<300).contains(http.statusCode) else { return .failure(failure(http)) }
			return .success(data)
		} catch is BoundedHTTPResponse.LoadError {
			return .failure(.invalidResponse)
		} catch is CancellationError {
			return .failure(.cancelled)
		} catch let error as URLError where error.code == .cancelled {
			return .failure(.cancelled)
		} catch {
			return .failure(.transport)
		}
	}

	private static func failure(_ http: HTTPURLResponse) -> NetlifyAPIError {
		switch http.statusCode {
		case 401: .unauthorized
		case 403: .forbidden
		case 404: .notFound
		case 429:
			.rateLimited(until: http.value(forHTTPHeaderField: "X-RateLimit-Reset").flatMap(TimeInterval.init).map(Date.init(timeIntervalSince1970:)))
		case 400..<500: .rejected(status: http.statusCode)
		default: .server(http.statusCode)
		}
	}

	/// IDs Netlify assigns, such as tickets', users' and sites', use only
	/// characters that are safe in a request path.
	static func isValidIdentifier(_ text: String) -> Bool {
		PlatformIdentifier.isValid(text)
	}

	/// Printable ASCII without spaces, as Netlify issues them.
	static func isValidAccessToken(_ token: String) -> Bool {
		!token.isEmpty && token.utf8.count <= 4_096 && token.utf8.allSatisfy { $0 >= 0x21 && $0 <= 0x7E }
	}
}

/// Netlify's OAuth ticket endpoints, which LPM Vault calls without a token.
struct NetlifyAuthorizationClient: NetlifyAuthorizationClientProtocol {
	private let baseURL: URL
	let session: URLSession

	init(baseURL: URL = NetlifyHTTP.defaultBaseURL, session: URLSession? = nil) {
		self.baseURL = baseURL
		self.session = session ?? NetlifyHTTP.sharedSession
	}

	func createTicket(clientID: String) async -> Result<NetlifyTicket, NetlifyAPIError> {
		guard NetlifyHTTP.isValidIdentifier(clientID),
			let url = NetlifyHTTP.url(baseURL, ["oauth", "tickets"], query: [URLQueryItem(name: "client_id", value: clientID)])
		else { return .failure(.invalidResponse) }
		return await NetlifyHTTP.load(NetlifyHTTP.request("POST", url, token: nil), using: session).flatMap(Self.ticket)
	}

	func ticket(_ id: String) async -> Result<NetlifyTicket, NetlifyAPIError> {
		guard NetlifyHTTP.isValidIdentifier(id), let url = NetlifyHTTP.url(baseURL, ["oauth", "tickets", id]) else {
			return .failure(.invalidResponse)
		}
		return await NetlifyHTTP.load(NetlifyHTTP.request("GET", url, token: nil), using: session).flatMap(Self.ticket).flatMap { ticket in
			ticket.id == id ? .success(ticket) : .failure(.invalidResponse)
		}
	}

	func exchange(_ ticketID: String) async -> Result<NetlifyGrant, NetlifyAPIError> {
		guard NetlifyHTTP.isValidIdentifier(ticketID), let url = NetlifyHTTP.url(baseURL, ["oauth", "tickets", ticketID, "exchange"]) else {
			return .failure(.invalidResponse)
		}
		return await NetlifyHTTP.load(NetlifyHTTP.request("POST", url, token: nil), using: session).flatMap { data in
			guard let decoded = try? JSONDecoder().decode(AccessToken.self, from: data),
				NetlifyHTTP.isValidAccessToken(decoded.accessToken),
				decoded.userID.map(NetlifyHTTP.isValidIdentifier) ?? true
			else { return .failure(.invalidResponse) }
			return .success(NetlifyGrant(
				accessToken: decoded.accessToken, userID: decoded.userID, email: ProviderName.display(decoded.userEmail)))
		}
	}

	private static func ticket(_ data: Data) -> Result<NetlifyTicket, NetlifyAPIError> {
		guard let decoded = try? JSONDecoder().decode(Ticket.self, from: data), NetlifyHTTP.isValidIdentifier(decoded.id) else {
			return .failure(.invalidResponse)
		}
		// A ticket waiting for the person reads `authorized: null`.
		return .success(NetlifyTicket(id: decoded.id, isAuthorized: decoded.authorized == true))
	}

	private struct Ticket: Decodable {
		let id: String
		let authorized: Bool?
	}

	private struct AccessToken: Decodable {
		let accessToken: String
		let userID: String?
		let userEmail: String?

		private enum CodingKeys: String, CodingKey {
			case accessToken = "access_token"
			case userID = "user_id"
			case userEmail = "user_email"
		}
	}
}

/// Netlify's REST API with one connection's access token. Requests go only
/// to `baseURL`, and redirects are refused so the token never follows one.
struct NetlifyClient: NetlifyClientProtocol, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
	private let token: String
	private let baseURL: URL
	let session: URLSession

	init(token: String, baseURL: URL = NetlifyHTTP.defaultBaseURL, session: URLSession? = nil) {
		self.token = token
		self.baseURL = baseURL
		self.session = session ?? NetlifyHTTP.sharedSession
	}

	var description: String { "NetlifyClient(\(baseURL.host() ?? "?"), token: <redacted>)" }
	var debugDescription: String { description }
	var customMirror: Mirror { Mirror(self, children: ["baseURL": baseURL]) }

	func user() async -> Result<NetlifyUser, NetlifyAPIError> {
		guard let url = NetlifyHTTP.url(baseURL, ["user"]) else { return .failure(.invalidResponse) }
		return await NetlifyHTTP.load(NetlifyHTTP.request("GET", url, token: token), using: session).flatMap { data in
			guard let user = try? JSONDecoder().decode(User.self, from: data), NetlifyHTTP.isValidIdentifier(user.id) else {
				return .failure(.invalidResponse)
			}
			return .success(NetlifyUser(id: user.id, name: ProviderName.display(user.fullName), email: ProviderName.display(user.email)))
		}
	}

	private struct User: Decodable {
		let id: String
		let fullName: String?
		let email: String?

		private enum CodingKeys: String, CodingKey {
			case id, email
			case fullName = "full_name"
		}
	}
}
