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
	/// The longest wait for a rate limit to lift; Netlify's window is a minute.
	static let maximumRateLimitWait: Duration = .seconds(65)

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

	static func request(_ method: String, _ url: URL, token: String, body: Data? = nil) -> URLRequest {
		var request = URLRequest(url: url)
		request.httpMethod = method
		request.setValue("application/json", forHTTPHeaderField: "Accept")
		request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
		request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
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

	/// How long to wait for a rate limit Netlify says lifts at `reset`, or a
	/// minute when it doesn't say; nil when it lifts after the longest wait.
	static func rateLimitWait(until reset: Date?) -> Duration? {
		let seconds = reset?.timeIntervalSinceNow ?? 60
		// Compared as a number first: a far-off or infinite reset traps as a duration.
		guard seconds.isFinite, seconds <= Double(maximumRateLimitWait.components.seconds) else { return nil }
		return .milliseconds(Int64(max(0, seconds) * 1_000))
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

	/// IDs Netlify assigns, such as users', teams' and sites', use only
	/// characters that are safe in a request path.
	static func isValidIdentifier(_ text: String) -> Bool {
		PlatformIdentifier.isValid(text)
	}

	/// Printable ASCII without spaces, as Netlify issues them.
	static func isValidAccessToken(_ token: String) -> Bool {
		!token.isEmpty && token.utf8.count <= 4_096 && token.utf8.allSatisfy { $0 >= 0x21 && $0 <= 0x7E }
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
