import Foundation

enum GitHubAPIError: Error, Equatable, Sendable {
	/// The token no longer works, as after it expired or the person revoked LPM Vault.
	case unauthorized
	/// The token can't reach this, as when the person's role on a repository
	/// can't change its secrets, or the app isn't installed there.
	case forbidden
	case notFound
	case rateLimited(until: Date?)
	/// GitHub refused the request, with its HTTP status. Its messages are
	/// never shown: one could echo what was sent.
	case rejected(status: Int)
	case transport
	case cancelled
	case invalidResponse
	case server(Int)
}

/// The GitHub user a connection's token belongs to.
struct GitHubUser: Equatable, Sendable {
	/// GitHub's numeric ID, which outlasts a renamed login.
	let id: String
	let login: String
	/// The user's profile name; nil when they have none to show.
	let name: String?
}

protocol GitHubClientProtocol: Sendable {
	/// The user the token belongs to.
	func user() async -> Result<GitHubUser, GitHubAPIError>
}

/// Requests to GitHub's REST API. They go only to `baseURL`, redirects are
/// refused so a token never follows one, and GitHub's error messages are
/// never shown.
enum GitHubHTTP {
	static let defaultBaseURL = URL(string: "https://api.github.com")!
	/// The REST API version requests ask for, so GitHub's answers keep their shape.
	static let apiVersion = "2022-11-28"
	/// GitHub refuses requests that don't name their client.
	static let userAgent = "LPM-Vault (https://vault.lpm.dev)"
	static let maximumResponseBytes = 2 * 1024 * 1024
	/// The latest a rate limit can lift for a request to wait for it. GitHub
	/// asks for at least a minute when it doesn't say how long.
	static let maximumRateLimitWait: Duration = .seconds(65)
	/// How long after a limit's announced reset the next request goes, so it
	/// doesn't arrive a moment before the limit has lifted.
	static let resetMargin: TimeInterval = 1
	/// The longest a request waits for a limit, its margin included.
	static let longestRateLimitWait = maximumRateLimitWait + .seconds(resetMargin)

	/// The session clients use unless given one; it keeps no cookies, cache or credentials.
	static let sharedSession = URLSession(
		configuration: BoundedHTTPResponse.ephemeralConfiguration(requestTimeout: 20, resourceTimeout: 60),
		delegate: RedirectRefusingHTTPDelegate(),
		delegateQueue: nil
	)

	/// The characters a path segment keeps as they are; everything else is
	/// percent-escaped, so a name can't add a segment or a query.
	private static let segmentCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

	/// The API URL for `path`, each segment escaped on its own.
	static func url(_ baseURL: URL, _ path: [String], query: [URLQueryItem] = []) -> URL? {
		guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false), !path.isEmpty else { return nil }
		var segments: [String] = []
		segments.reserveCapacity(path.count)
		for segment in path {
			guard !segment.isEmpty, segment != ".", segment != "..",
				let escaped = segment.addingPercentEncoding(withAllowedCharacters: segmentCharacters)
			else { return nil }
			segments.append(escaped)
		}
		components.percentEncodedPath = "/" + segments.joined(separator: "/")
		components.queryItems = query.isEmpty ? nil : query
		components.fragment = nil
		return components.url
	}

	static func request(_ method: String, _ url: URL, token: String, body: Data? = nil) -> URLRequest {
		var request = URLRequest(url: url)
		request.httpMethod = method
		request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
		request.setValue(apiVersion, forHTTPHeaderField: "X-GitHub-Api-Version")
		request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
		request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
		if let body {
			request.httpBody = body
			request.setValue("application/json", forHTTPHeaderField: "Content-Type")
		}
		return request
	}

	/// The answer's body and headers when GitHub accepted the request.
	static func load(
		_ request: URLRequest,
		using session: URLSession,
		limit: Int = maximumResponseBytes
	) async -> Result<(data: Data, response: HTTPURLResponse), GitHubAPIError> {
		do {
			let (data, response) = try await BoundedHTTPResponse.load(for: request, using: session, maximumBytes: limit)
			guard let http = response as? HTTPURLResponse else { return .failure(.invalidResponse) }
			guard (200..<300).contains(http.statusCode) else { return .failure(failure(http, body: data)) }
			return .success((data, http))
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

	/// How long to wait at `now` for a rate limit that lifts at `reset`, and
	/// the moment past it the next request may go; a minute when GitHub
	/// doesn't say. Nil when it lifts later than a request waits for.
	static func rateLimitWait(until reset: Date?, now: Date = Date()) -> (wait: Duration, lifts: Date?)? {
		guard let wait = PlatformRateLimit.wait(until: reset, maximum: maximumRateLimitWait, now: now) else { return nil }
		guard let reset else { return (wait, nil) }
		return (wait + .seconds(resetMargin), reset.addingTimeInterval(resetMargin))
	}

	/// How long to wait out a limit GitHub doesn't say the end of, after
	/// `count` such limits in a row: a minute, then twice as long each time,
	/// as GitHub asks while a limit continues.
	static func unannouncedLimitWait(after count: Int) -> Duration {
		.seconds(60 << count)
	}

	/// A refusal, read the way GitHub documents its limits: a primary limit
	/// spent says when it resets, on GitHub's clock, a secondary one how many
	/// seconds to wait, and one that says neither means a minute. A 403
	/// that's no limit is the token lacking access; its message is read only
	/// to tell the two apart.
	static func failure(_ http: HTTPURLResponse, body: Data, now: Date = Date()) -> GitHubAPIError {
		let status = http.statusCode
		if status == 403 || status == 429 {
			if let seconds = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init), seconds.isFinite, seconds >= 0 {
				return .rateLimited(until: now.addingTimeInterval(seconds))
			}
			if http.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0" {
				return .rateLimited(
					until: http.value(forHTTPHeaderField: "X-RateLimit-Reset").flatMap(TimeInterval.init).flatMap {
						PlatformRateLimit.lifts(atReset: $0, answered: http, now: now)
					})
			}
			if status == 429 || mentionsRateLimit(body) { return .rateLimited(until: nil) }
			return .forbidden
		}
		switch status {
		case 401: return .unauthorized
		case 404: return .notFound
		case 400..<500: return .rejected(status: status)
		default: return .server(status)
		}
	}

	private static func mentionsRateLimit(_ body: Data) -> Bool {
		guard let object = try? JSONSerialization.jsonObject(with: body.prefix(64 * 1024)) as? [String: Any],
			let message = object["message"] as? String
		else { return false }
		return message.range(of: "rate limit", options: .caseInsensitive) != nil
	}

	/// GitHub's numeric IDs, as decimal text without a sign or leading zero.
	static func isValidID(_ text: String) -> Bool {
		!text.isEmpty && text.utf8.count <= 20 && text.first != "0" && text.utf8.allSatisfy { $0 >= 0x30 && $0 <= 0x39 }
	}

	/// A user's or organization's login: letters, digits, hyphens and, for a
	/// managed user of an enterprise, the underscore before its short code; up to 39.
	static func isValidLogin(_ text: String) -> Bool {
		!text.isEmpty && text.utf8.count <= 39
			&& text.utf8.allSatisfy {
				($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A) || $0 == 0x2D || $0 == 0x5F
			}
	}

	/// A GitHub App's slug: lowercase letters, digits and hyphens.
	static func isValidAppSlug(_ text: String) -> Bool {
		!text.isEmpty && text.utf8.count <= 64
			&& text.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x7A) || $0 == 0x2D }
	}

	/// A GitHub App's client ID: `Iv23li…`, or `Iv1.…` for an older app.
	/// Letters, digits, dots, underscores and hyphens, starting with a letter
	/// or digit, without two dots together; up to 128, as the Registry takes it.
	static func isValidClientID(_ text: String) -> Bool {
		let bytes = text.utf8
		guard let first = bytes.first, bytes.count <= 128, first != 0x2E, first != 0x5F, first != 0x2D, !text.contains("..") else { return false }
		return bytes.allSatisfy {
			($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A) || $0 == 0x2E || $0 == 0x5F || $0 == 0x2D
		}
	}

	/// A numeric ID as JSON carries it, as decimal text.
	static func id(_ number: Int64) -> String? {
		number > 0 ? String(number) : nil
	}
}

/// GitHub's REST API with one connection's access token. Requests go only to
/// `baseURL`, and redirects are refused so the token never follows one.
struct GitHubClient: GitHubClientProtocol, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
	private let token: String
	private let baseURL: URL
	let session: URLSession

	init(token: String, baseURL: URL = GitHubHTTP.defaultBaseURL, session: URLSession? = nil) {
		self.token = token
		self.baseURL = baseURL
		self.session = session ?? GitHubHTTP.sharedSession
	}

	var description: String { "GitHubClient(\(baseURL.host() ?? "?"), token: <redacted>)" }
	var debugDescription: String { description }
	var customMirror: Mirror { Mirror(self, children: ["baseURL": baseURL]) }

	func user() async -> Result<GitHubUser, GitHubAPIError> {
		guard let url = GitHubHTTP.url(baseURL, ["user"]) else { return .failure(.invalidResponse) }
		return await GitHubHTTP.load(GitHubHTTP.request("GET", url, token: token), using: session).flatMap { loaded in
			guard let user = try? JSONDecoder().decode(User.self, from: loaded.data), let id = GitHubHTTP.id(user.id),
				GitHubHTTP.isValidLogin(user.login)
			else { return .failure(.invalidResponse) }
			return .success(GitHubUser(id: id, login: user.login, name: ProviderName.display(user.name)))
		}
	}

	private struct User: Decodable {
		let id: Int64
		let login: String
		let name: String?
	}
}
