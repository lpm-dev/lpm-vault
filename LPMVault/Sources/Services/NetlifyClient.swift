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

/// A site a Netlify connection reaches, with the team that owns it.
struct NetlifySite: Identifiable, Equatable, Sendable {
	let id: String
	/// The site's name, which is also its unique Netlify subdomain.
	let name: String
	let teamID: String
	let teamName: String
}

/// One of a site's variables, without its values.
struct NetlifyVariable: Equatable, Sendable {
	/// Where one of the variable's values applies.
	enum Context: Hashable, Sendable {
		/// Every deploy context that has no value of its own.
		case all
		case production
		case deployPreview
		case branchDeploy
		/// Local development with the Netlify CLI.
		case dev
		case devServer
		case branch(String)
		case other(String)

		init(_ name: String, parameter: String?) {
			switch name {
			case "all": self = .all
			case "production": self = .production
			case "deploy-preview": self = .deployPreview
			case "branch-deploy": self = .branchDeploy
			case "dev": self = .dev
			case "dev-server": self = .devServer
			case "branch": self = .branch(parameter ?? "")
			default: self = .other(name)
			}
		}

		/// Branch names and unknown contexts compare byte for byte, as Netlify
		/// keeps them; see `NetlifyPublishTarget.Context`.
		static func == (lhs: Context, rhs: Context) -> Bool {
			switch (lhs, rhs) {
			case (.all, .all), (.production, .production), (.deployPreview, .deployPreview), (.branchDeploy, .branchDeploy),
				(.dev, .dev), (.devServer, .devServer):
				true
			case (.branch(let left), .branch(let right)), (.other(let left), .other(let right)): left.utf8.elementsEqual(right.utf8)
			default: false
			}
		}

		func hash(into hasher: inout Hasher) {
			switch self {
			case .all: hasher.combine(0)
			case .production: hasher.combine(1)
			case .deployPreview: hasher.combine(2)
			case .branchDeploy: hasher.combine(3)
			case .dev: hasher.combine(4)
			case .devServer: hasher.combine(5)
			case .branch(let name):
				hasher.combine(6)
				NetlifyPublishTarget.Context.hashBytes(of: name, into: &hasher)
			case .other(let name):
				hasher.combine(7)
				NetlifyPublishTarget.Context.hashBytes(of: name, into: &hasher)
			}
		}

		/// The context a publish destination writes.
		init(_ context: NetlifyPublishTarget.Context) {
			switch context {
			case .production: self = .production
			case .deployPreview: self = .deployPreview
			case .branchDeploy: self = .branchDeploy
			case .branch(let name): self = .branch(name)
			}
		}
	}

	struct Value: Equatable, Sendable {
		let id: String
		let context: Context
	}

	let key: String
	/// Netlify keeps the values write-only, except one for local development.
	let isSecret: Bool
	let values: [Value]
	/// When any of the variable's values, or the variable, last changed.
	let updatedAt: Date?
}

/// A value to write to one deploy context of a site's variable. The value
/// never appears when it's printed, logged or dumped.
struct NetlifyVariableWrite: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
	let key: String
	let value: String
	let context: NetlifyPublishTarget.Context
	/// Whether a new variable is created as a secret. A value added to an
	/// existing variable is stored the way the variable is.
	let isSecret: Bool

	var description: String { "NetlifyVariableWrite(\(key), \(context.identifier), secret: \(isSecret), value: <redacted>)" }
	var debugDescription: String { description }
	var customMirror: Mirror { Mirror(self, children: ["key": key, "context": context.identifier, "isSecret": isSecret]) }
}

protocol NetlifyClientProtocol: Sendable {
	/// The user the token belongs to.
	func user() async -> Result<NetlifyUser, NetlifyAPIError>
	/// The sites of every team the user belongs to.
	func sites() async -> Result<[NetlifySite], NetlifyAPIError>
	/// The site's own variables, without their values; a team's shared variables aren't among them.
	func variables(siteID: String, teamID: String) async -> Result<[NetlifyVariable], NetlifyAPIError>
	/// One of the site's own variables, without its values; nil when the site has none with the key.
	func variable(_ key: String, siteID: String, teamID: String) async -> Result<NetlifyVariable?, NetlifyAPIError>
	/// Creates the site variable with one value, for the write's context.
	func create(_ write: NetlifyVariableWrite, siteID: String, teamID: String) async -> Result<NetlifyVariable, NetlifyAPIError>
	/// Sets the existing site variable's value for the write's context, adding one when it has none.
	func setValue(_ write: NetlifyVariableWrite, siteID: String, teamID: String) async -> Result<NetlifyVariable, NetlifyAPIError>
}

/// Requests to Netlify's API. They go only to `baseURL`, redirects are
/// refused so a token never follows one, and Netlify's error messages are
/// never read.
enum NetlifyHTTP {
	static let defaultBaseURL = URL(string: "https://api.netlify.com")!
	static let maximumResponseBytes = 2 * 1024 * 1024
	static let maximumListBytes = 8 * 1024 * 1024
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

	/// The load's answer, or nil once `deadline` passes first, which cancels the load.
	static func load(
		_ request: URLRequest,
		using session: URLSession,
		limit: Int,
		until deadline: ContinuousClock.Instant
	) async -> Result<Data, NetlifyAPIError>? {
		await withTaskGroup(of: Result<Data, NetlifyAPIError>?.self) { group in
			group.addTask { await load(request, using: session, limit: limit) }
			group.addTask {
				try? await Task.sleep(until: deadline, clock: .continuous)
				return nil
			}
			let first = await group.next() ?? nil
			group.cancelAll()
			return first
		}
	}

	/// How long to wait for a rate limit Netlify says lifts at `reset`, or a
	/// minute when it doesn't say; nil when it lifts after the longest wait.
	static func rateLimitWait(until reset: Date?) -> Duration? {
		PlatformRateLimit.wait(until: reset, maximum: maximumRateLimitWait)
	}

	/// Sleeps `wait`, then on until the wall clock passes `reset`.
	static func waitOut(_ wait: Duration, until reset: Date?) async throws {
		try await PlatformRateLimit.waitOut(wait, until: reset)
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

	/// A variable name that's safe in a request path: ASCII letters, digits
	/// and underscores, as Netlify's names are.
	static func isPathSafeKey(_ key: String) -> Bool {
		!key.isEmpty && key.utf8.count <= 255
			&& key.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A) || $0 == 0x5F }
	}

	/// Printable ASCII without spaces, as Netlify issues them.
	static func isValidAccessToken(_ token: String) -> Bool {
		!token.isEmpty && token.utf8.count <= 4_096 && token.utf8.allSatisfy { $0 >= 0x21 && $0 <= 0x7E }
	}
}

/// Netlify's REST API with one connection's access token. Requests go only
/// to `baseURL`, and redirects are refused so the token never follows one.
struct NetlifyClient: NetlifyClientProtocol, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
	static let sitePageSize = 100
	static let maximumSitePages = 100

	/// How much listing the user's sites may read.
	struct Limits: Sendable {
		/// Everything one listing reads, in bytes.
		var siteBytes = 64 * 1024 * 1024
		/// How long one listing may take, every page included.
		var siteDeadline: Duration = .seconds(120)
	}

	private let token: String
	private let baseURL: URL
	private let limits: Limits
	let session: URLSession

	init(token: String, baseURL: URL = NetlifyHTTP.defaultBaseURL, session: URLSession? = nil, limits: Limits = Limits()) {
		self.token = token
		self.baseURL = baseURL
		self.session = session ?? NetlifyHTTP.sharedSession
		self.limits = limits
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

	/// Reads the sites page by page, within the listing's byte budget and
	/// deadline, which a page still loading doesn't outlast. A page holding
	/// more sites than asked for, or a site listed twice, fails the listing.
	func sites() async -> Result<[NetlifySite], NetlifyAPIError> {
		var sites: [NetlifySite] = []
		var seen: Set<String> = []
		var remaining = limits.siteBytes
		let deadline = ContinuousClock.now.advanced(by: limits.siteDeadline)
		for page in 1...Self.maximumSitePages {
			guard page == 1 || ContinuousClock.now < deadline, remaining > 0 else { return .failure(.invalidResponse) }
			let query = [
				URLQueryItem(name: "filter", value: "all"),
				URLQueryItem(name: "page", value: String(page)),
				URLQueryItem(name: "per_page", value: String(Self.sitePageSize)),
			]
			guard let url = NetlifyHTTP.url(baseURL, ["sites"], query: query) else { return .failure(.invalidResponse) }
			let request = NetlifyHTTP.request("GET", url, token: token)
			guard let loaded = await NetlifyHTTP.load(request, using: session, limit: min(NetlifyHTTP.maximumListBytes, remaining), until: deadline)
			else { return .failure(Task.isCancelled ? .cancelled : .invalidResponse) }
			let data: Data
			switch loaded {
			case .success(let value): data = value
			case .failure(let error): return .failure(error)
			}
			remaining -= data.count
			guard let decoded = try? JSONDecoder().decode([RawSite].self, from: data), decoded.count <= Self.sitePageSize else {
				return .failure(.invalidResponse)
			}
			for raw in decoded {
				guard let site = raw.site, seen.insert(site.id).inserted else { return .failure(.invalidResponse) }
				sites.append(site)
			}
			if decoded.count < Self.sitePageSize { return .success(sites) }
		}
		return .failure(.invalidResponse)
	}

	func variables(siteID: String, teamID: String) async -> Result<[NetlifyVariable], NetlifyAPIError> {
		guard let url = Self.envURL(baseURL, siteID: siteID, teamID: teamID) else { return .failure(.invalidResponse) }
		return await NetlifyHTTP.load(NetlifyHTTP.request("GET", url, token: token), using: session, limit: NetlifyHTTP.maximumListBytes)
			.flatMap { data in
				guard let decoded = try? JSONDecoder().decode([RawVariable].self, from: data) else { return .failure(.invalidResponse) }
				var variables: [NetlifyVariable] = []
				variables.reserveCapacity(decoded.count)
				for raw in decoded {
					guard let variable = raw.variable else { return .failure(.invalidResponse) }
					variables.append(variable)
				}
				return .success(variables)
			}
	}

	func variable(_ key: String, siteID: String, teamID: String) async -> Result<NetlifyVariable?, NetlifyAPIError> {
		guard NetlifyHTTP.isPathSafeKey(key), let url = Self.envURL(baseURL, siteID: siteID, teamID: teamID, key: key) else {
			return .failure(.invalidResponse)
		}
		switch await NetlifyHTTP.load(NetlifyHTTP.request("GET", url, token: token), using: session) {
		case .success(let data):
			guard let variable = (try? JSONDecoder().decode(RawVariable.self, from: data))?.variable, variable.key == key else {
				return .failure(.invalidResponse)
			}
			return .success(variable)
		case .failure(.notFound):
			return .success(nil)
		case .failure(let error):
			return .failure(error)
		}
	}

	func create(_ write: NetlifyVariableWrite, siteID: String, teamID: String) async -> Result<NetlifyVariable, NetlifyAPIError> {
		guard NetlifyHTTP.isPathSafeKey(write.key), let url = Self.envURL(baseURL, siteID: siteID, teamID: teamID) else {
			return .failure(.invalidResponse)
		}
		var variable: [String: Any] = ["key": write.key, "is_secret": write.isSecret, "values": [Self.value(write)]]
		// Netlify refuses a secret in post-processing, and needs a free plan's secret to name its scopes.
		if write.isSecret { variable["scopes"] = ["builds", "functions", "runtime"] }
		guard let body = try? JSONSerialization.data(withJSONObject: [variable]) else { return .failure(.invalidResponse) }
		return await NetlifyHTTP.load(NetlifyHTTP.request("POST", url, token: token, body: body), using: session).flatMap { data in
			guard let decoded = try? JSONDecoder().decode([RawVariable].self, from: data), decoded.count == 1,
				let created = decoded[0].variable, created.key == write.key
			else { return .failure(.invalidResponse) }
			return .success(created)
		}
	}

	func setValue(_ write: NetlifyVariableWrite, siteID: String, teamID: String) async -> Result<NetlifyVariable, NetlifyAPIError> {
		guard NetlifyHTTP.isPathSafeKey(write.key), let url = Self.envURL(baseURL, siteID: siteID, teamID: teamID, key: write.key),
			let body = try? JSONSerialization.data(withJSONObject: Self.value(write))
		else { return .failure(.invalidResponse) }
		return await NetlifyHTTP.load(NetlifyHTTP.request("PATCH", url, token: token, body: body), using: session).flatMap { data in
			guard let updated = (try? JSONDecoder().decode(RawVariable.self, from: data))?.variable, updated.key == write.key else {
				return .failure(.invalidResponse)
			}
			return .success(updated)
		}
	}

	/// A site's variables, or one of them, under the team that owns the site.
	/// The site always goes in the query: without it, Netlify reads and
	/// writes the team's shared variables, which every site of the team gets.
	private static func envURL(_ baseURL: URL, siteID: String, teamID: String, key: String? = nil) -> URL? {
		guard NetlifyHTTP.isValidIdentifier(siteID), NetlifyHTTP.isValidIdentifier(teamID) else { return nil }
		return NetlifyHTTP.url(
			baseURL, ["accounts", teamID, "env"] + (key.map { [$0] } ?? []), query: [URLQueryItem(name: "site_id", value: siteID)])
	}

	private static func value(_ write: NetlifyVariableWrite) -> [String: Any] {
		var value: [String: Any] = ["context": write.context.apiName, "value": write.value]
		if let branch = write.context.branch { value["context_parameter"] = branch }
		return value
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

	private struct RawSite: Decodable {
		let id: String
		let name: String
		let accountID: String?
		let accountName: String?
		let accountSlug: String?

		private enum CodingKeys: String, CodingKey {
			case id, name
			case accountID = "account_id"
			case accountName = "account_name"
			case accountSlug = "account_slug"
		}

		var site: NetlifySite? {
			guard NetlifyHTTP.isValidIdentifier(id), let name = ProviderName.display(name),
				let accountID, NetlifyHTTP.isValidIdentifier(accountID),
				let teamName = ProviderName.display(accountName) ?? ProviderName.display(accountSlug)
			else { return nil }
			return NetlifySite(id: id, name: name, teamID: accountID, teamName: teamName)
		}
	}

	/// A variable as Netlify lists it. Its values' text is never decoded.
	private struct RawVariable: Decodable {
		struct Value: Decodable {
			let id: String?
			let context: String
			let contextParameter: String?

			private enum CodingKeys: String, CodingKey {
				case id, context
				case contextParameter = "context_parameter"
			}
		}

		let key: String
		let isSecret: Bool?
		let values: [Value]?
		let updatedAt: String?

		private enum CodingKeys: String, CodingKey {
			case key, values
			case isSecret = "is_secret"
			case updatedAt = "updated_at"
		}

		var variable: NetlifyVariable? {
			guard !key.isEmpty, key.utf8.count <= 1_024 else { return nil }
			var values: [NetlifyVariable.Value] = []
			for value in self.values ?? [] {
				guard let id = value.id, NetlifyHTTP.isValidIdentifier(id) else { return nil }
				let parameter = value.contextParameter.flatMap { $0.isEmpty ? nil : $0 }
				values.append(NetlifyVariable.Value(id: id, context: NetlifyVariable.Context(value.context, parameter: parameter)))
			}
			var updatedAt: Date?
			if let text = self.updatedAt {
				guard let date = PlatformTimestamp.utc(text) else { return nil }
				updatedAt = date
			}
			// A variable from before Netlify's secrets reads as readable, so a review warns rather than trusts it.
			return NetlifyVariable(key: key, isSecret: isSecret == true, values: values, updatedAt: updatedAt)
		}
	}
}
