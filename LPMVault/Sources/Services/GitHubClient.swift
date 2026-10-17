import Foundation

enum GitHubAPIError: Error, Equatable, Sendable {
	/// What a listing lists, so its failures can say which list it was.
	enum Listing: Sendable {
		/// The installations of LPM Vault's app, and their repositories.
		case repositories
		case environments
		case secrets
		case variables
	}

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
	/// GitHub redirected the request, as for a repository renamed or
	/// transferred since its name was read. A redirect is never followed.
	case moved
	/// An organization's single sign-on keeps the token out until the person
	/// signs in with it and connects GitHub again.
	case ssoRequired
	/// GitHub's list was longer than LPM Vault reads.
	case tooLarge(Listing)
	/// GitHub took longer to list than LPM Vault waits, once it had answered.
	case timedOut(Listing)
	/// GitHub refused the token, which another renewal had already replaced;
	/// GitHub applied nothing, and the next request uses the new token.
	case renewed
	/// The connection's token couldn't be renewed, or read, for the request.
	case credentials(PlatformCredentialError)
}

/// The GitHub user a connection's token belongs to.
struct GitHubUser: Equatable, Sendable {
	/// GitHub's numeric ID, which outlasts a renamed login.
	let id: String
	let login: String
	/// The user's profile name; nil when they have none to show.
	let name: String?
}

/// A repository a GitHub connection reaches through an installation of LPM Vault's app.
struct GitHubRepository: Identifiable, Equatable, Sendable {
	/// The person's role on a repository, as far as secrets and variables go.
	enum Permission: Equatable, Sendable {
		/// Changes the repository's secrets and variables, and its environments'.
		case admin
		/// Changes the repository's own secrets and variables.
		case write
		case read
	}

	/// GitHub's numeric ID, which outlasts a rename or a transfer.
	let id: String
	/// `owner/name`.
	let fullName: String
	let isPrivate: Bool
	/// An archived repository is read-only.
	var isArchived = false
	/// Nil when GitHub didn't say.
	var permission: Permission?

	/// Whether the person can change the scope's secrets and variables, as
	/// far as GitHub said: a repository's need write access, an environment's
	/// admin, and an archived repository's can't change.
	func canChange(_ scope: GitHubPublishTarget.Scope) -> Bool {
		guard !isArchived else { return false }
		switch (scope, permission) {
		case (_, nil), (_, .admin?), (.repository, .write?): return true
		case (.environment, .write?), (_, .read?): return false
		}
	}
}

/// An installation of LPM Vault's app whose repositories GitHub left out.
struct GitHubSkippedInstallation: Equatable, Sendable {
	/// The login of the account it's installed on, when GitHub gave one LPM Vault reads.
	let account: String?
	/// Whether it's suspended; otherwise GitHub refused to list its
	/// repositories, as when it was removed meanwhile.
	let isSuspended: Bool
}

/// The repositories a GitHub connection reaches.
struct GitHubRepositoryList: Equatable, Sendable {
	var repositories: [GitHubRepository]
	/// Whether GitHub left out an organization's repositories until the person signs in with its single sign-on.
	var hidesSSORepositories = false
	var skippedInstallations: [GitHubSkippedInstallation] = []
}

/// One of a repository's deployment environments.
struct GitHubEnvironment: Identifiable, Equatable, Sendable {
	let id: String
	/// GitHub's name for it, as its paths use it; shown escaped.
	let name: String
}

/// Where Actions secrets and variables are written: a repository's own, or
/// one of its deployment environments'.
struct GitHubScope: Equatable, Sendable {
	/// `owner/name`.
	let repository: String
	let environment: String?

	/// The path of the scope's secrets or variables, `kind` being either.
	func path(_ kind: String, _ name: String? = nil) -> [String] {
		let owner = String(repository.prefix { $0 != "/" })
		let repo = String(repository.drop { $0 != "/" }.dropFirst())
		let base = ["repos", owner, repo] + (environment.map { ["environments", $0] } ?? ["actions"])
		return base + [kind] + (name.map { [$0] } ?? [])
	}
}

/// A secret or variable of a scope, without its value: GitHub never shows a
/// secret's, and a variable's isn't needed.
struct GitHubValueRecord: Equatable, Sendable {
	let name: String
	/// When GitHub last wrote it, to the second.
	let updatedAt: Date
}

/// The key a scope's secrets are sealed to.
struct GitHubPublicKey: Equatable, Sendable {
	let id: String
	/// A 32-byte Curve25519 public key.
	let key: Data
}

/// A secret's value sealed to a scope's key. The ciphertext isn't secret,
/// but it's kept out of printing like a value.
struct GitHubSealedSecret: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
	let ciphertext: Data
	let keyID: String

	var description: String { "GitHubSealedSecret(key: \(keyID), ciphertext: <redacted>)" }
	var debugDescription: String { description }
	var customMirror: Mirror { Mirror(self, children: ["keyID": keyID]) }
}

protocol GitHubClientProtocol: Sendable {
	/// The user the token belongs to.
	func user() async -> Result<GitHubUser, GitHubAPIError>
	/// Every repository the token reaches through installations of the app.
	func repositories() async -> Result<GitHubRepositoryList, GitHubAPIError>
	/// The repository with the ID, as it's named now.
	func repository(id: String) async -> Result<GitHubRepository, GitHubAPIError>
	/// The repository's deployment environments.
	func environments(of repository: String) async -> Result<[GitHubEnvironment], GitHubAPIError>
	/// The repository's environment with the name; nil when it has none.
	func environment(named name: String, of repository: String) async -> Result<GitHubEnvironment?, GitHubAPIError>
	/// The scope's secrets, without their values.
	func secrets(in scope: GitHubScope) async -> Result<[GitHubValueRecord], GitHubAPIError>
	/// One secret of the scope; nil when it has none with the name.
	func secret(_ name: String, in scope: GitHubScope) async -> Result<GitHubValueRecord?, GitHubAPIError>
	/// The key the scope's secrets are sealed to.
	func publicKey(of scope: GitHubScope) async -> Result<GitHubPublicKey, GitHubAPIError>
	/// Creates or replaces the scope's secret with a sealed value.
	func setSecret(_ name: String, to sealed: GitHubSealedSecret, in scope: GitHubScope) async -> Result<Void, GitHubAPIError>
	/// The scope's variables, without their values.
	func variables(in scope: GitHubScope) async -> Result<[GitHubValueRecord], GitHubAPIError>
	/// One variable of the scope, without its value; nil when it has none with the name.
	func variable(_ name: String, in scope: GitHubScope) async -> Result<GitHubValueRecord?, GitHubAPIError>
	func createVariable(_ name: String, value: String, in scope: GitHubScope) async -> Result<Void, GitHubAPIError>
	func updateVariable(_ name: String, value: String, in scope: GitHubScope) async -> Result<Void, GitHubAPIError>
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
		await loadCounted(request, using: session, limit: limit).result
	}

	/// `load`'s answer, with how many bytes GitHub's body took, accepted or
	/// refused, and whether it was cut off at `limit`, which reads as unreadable.
	static func loadCounted(
		_ request: URLRequest,
		using session: URLSession,
		limit: Int = maximumResponseBytes
	) async -> (result: Result<(data: Data, response: HTTPURLResponse), GitHubAPIError>, bytes: Int, cutOff: Bool) {
		do {
			let (data, response) = try await BoundedHTTPResponse.load(for: request, using: session, maximumBytes: limit)
			guard let http = response as? HTTPURLResponse else { return (.failure(.invalidResponse), data.count, false) }
			guard (200..<300).contains(http.statusCode) else { return (.failure(failure(http, body: data)), data.count, false) }
			return (.success((data, http)), data.count, false)
		} catch BoundedHTTPResponse.LoadError.responseTooLarge {
			return (.failure(.invalidResponse), limit, true)
		} catch is BoundedHTTPResponse.LoadError {
			return (.failure(.invalidResponse), 0, false)
		} catch is CancellationError {
			return (.failure(.cancelled), 0, false)
		} catch let error as URLError where error.code == .cancelled {
			return (.failure(.cancelled), 0, false)
		} catch {
			return (.failure(.transport), 0, false)
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
	/// `count` earlier waits for limits: a minute at first, then two, as
	/// GitHub asks for longer waits while limits continue. Two minutes is
	/// the longest, as a request waits out only a few.
	static func unannouncedLimitWait(after count: Int) -> Duration {
		.seconds(count == 0 ? 60 : 120)
	}

	/// A refusal, read the way GitHub documents its limits: a primary limit
	/// spent says when it resets, on GitHub's clock, a secondary one how many
	/// seconds to wait, and one that says neither means a minute. A 403
	/// that's no limit is the token lacking access, or kept out by an
	/// organization's single sign-on when GitHub says so; its message is read
	/// only to tell a limit apart.
	static func failure(_ http: HTTPURLResponse, body: Data, now: Date = Date()) -> GitHubAPIError {
		let status = http.statusCode
		if (300..<400).contains(status) { return .moved }
		if status == 403 || status == 404,
			http.value(forHTTPHeaderField: "X-GitHub-SSO")?.lowercased().hasPrefix("required") == true
		{
			return .ssoRequired
		}
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
	/// How much one listing may read.
	struct Limits: Sendable {
		/// Everything one listing reads, every page included, in bytes.
		var listBytes = 64 * 1024 * 1024
		/// The most one page of a list may take, in bytes.
		var pageBytes = GitHubHTTP.maximumResponseBytes * 4
		/// How long one listing may take, every page included.
		var listDeadline: Duration = .seconds(120)
		/// The most pages one list is read in.
		var maximumPages = 100
		/// Returns once a listing's deadline passes; a test stands in its own moment.
		var deadlinePasses: @Sendable (ContinuousClock.Instant) async -> Void = { deadline in
			try? await Task.sleep(until: deadline, clock: .continuous)
		}
	}

	private let token: String
	private let baseURL: URL
	private let limits: Limits
	let session: URLSession

	init(token: String, baseURL: URL = GitHubHTTP.defaultBaseURL, session: URLSession? = nil, limits: Limits = Limits()) {
		self.token = token
		self.baseURL = baseURL
		self.session = session ?? GitHubHTTP.sharedSession
		self.limits = limits
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

	/// Installations and their repositories are listed leniently: one GitHub
	/// lists in a form LPM Vault doesn't read is left out, rather than the list.
	func repositories() async -> Result<GitHubRepositoryList, GitHubAPIError> {
		var budget = Budget(limits)
		let installations: Listed<Installation?>
		switch await list(
			["user", "installations"], field: "installations", listing: .repositories, perPage: 100, lenient: true, budget: &budget,
			as: Installation.self)
		{
		case .success(let value): installations = value
		case .failure(let error): return .failure(error)
		}
		var listed = GitHubRepositoryList(repositories: [], hidesSSORepositories: installations.hidesSSOResults)
		var seen: Set<String> = []
		var read: Set<String> = []
		for installation in installations.items {
			guard let installation, let id = GitHubHTTP.id(installation.id),
				// An installation a shifting list repeats is read once.
				read.insert(id).inserted
			else { continue }
			guard installation.suspendedAt == nil else {
				listed.skippedInstallations.append(GitHubSkippedInstallation(account: installation.account, isSuspended: true))
				continue
			}
			let path = ["user", "installations", id, "repositories"]
			switch await list(path, field: "repositories", listing: .repositories, perPage: 100, lenient: true, budget: &budget, as: RawRepository.self) {
			case .success(let raws):
				listed.hidesSSORepositories = listed.hidesSSORepositories || raws.hidesSSOResults
				// One repository can't be in two installations, but a list never shows it twice.
				for repository in raws.items.lazy.compactMap({ $0?.repository }) where seen.insert(repository.id).inserted {
					listed.repositories.append(repository)
				}
			case .failure(.ssoRequired):
				listed.hidesSSORepositories = true
			case .failure(.forbidden), .failure(.notFound):
				// One installation's refusal leaves the others' repositories.
				listed.skippedInstallations.append(GitHubSkippedInstallation(account: installation.account, isSuspended: false))
			case .failure(let error):
				return .failure(error)
			}
		}
		return .success(listed)
	}

	func repository(id: String) async -> Result<GitHubRepository, GitHubAPIError> {
		guard GitHubHTTP.isValidID(id), let url = GitHubHTTP.url(baseURL, ["repositories", id]) else { return .failure(.invalidResponse) }
		return await GitHubHTTP.load(GitHubHTTP.request("GET", url, token: token), using: session).flatMap { loaded in
			guard let repository = (try? JSONDecoder().decode(RawRepository.self, from: loaded.data))?.repository, repository.id == id else {
				return .failure(.invalidResponse)
			}
			return .success(repository)
		}
	}

	func environment(named name: String, of repository: String) async -> Result<GitHubEnvironment?, GitHubAPIError> {
		guard GitHubPublishTarget.isValidFullName(repository), GitHubPublishTarget.Scope.isValidEnvironmentName(name),
			let url = GitHubHTTP.url(baseURL, ["repos"] + repository.split(separator: "/").map(String.init) + ["environments", name])
		else { return .failure(.invalidResponse) }
		switch await GitHubHTTP.load(GitHubHTTP.request("GET", url, token: token), using: session) {
		case .success(let loaded):
			guard let environment = (try? JSONDecoder().decode(RawEnvironment.self, from: loaded.data))?.environment else {
				return .failure(.invalidResponse)
			}
			return .success(environment)
		case .failure(.notFound):
			return .success(nil)
		case .failure(let error):
			return .failure(error)
		}
	}

	/// Listed leniently: an environment whose name LPM Vault doesn't take is
	/// left out. A repository without environments may answer without the list.
	func environments(of repository: String) async -> Result<[GitHubEnvironment], GitHubAPIError> {
		guard GitHubPublishTarget.isValidFullName(repository) else { return .failure(.invalidResponse) }
		var budget = Budget(limits)
		let path = ["repos"] + repository.split(separator: "/").map(String.init) + ["environments"]
		return await list(path, field: "environments", listing: .environments, perPage: 100, lenient: true, budget: &budget, as: RawEnvironment.self)
			.map { $0.items.compactMap { $0?.environment } }
	}

	func secrets(in scope: GitHubScope) async -> Result<[GitHubValueRecord], GitHubAPIError> {
		await records(scope.path("secrets"), field: "secrets", listing: .secrets, perPage: 100)
	}

	func secret(_ name: String, in scope: GitHubScope) async -> Result<GitHubValueRecord?, GitHubAPIError> {
		await record(scope.path("secrets", name), named: name)
	}

	func publicKey(of scope: GitHubScope) async -> Result<GitHubPublicKey, GitHubAPIError> {
		guard let url = GitHubHTTP.url(baseURL, scope.path("secrets", "public-key")) else { return .failure(.invalidResponse) }
		return await GitHubHTTP.load(GitHubHTTP.request("GET", url, token: token), using: session).flatMap { loaded in
			guard let raw = try? JSONDecoder().decode(RawPublicKey.self, from: loaded.data), PlatformIdentifier.isValid(raw.keyID),
				let key = Data(base64Encoded: raw.key), key.count == SealedBox.publicKeyBytes
			else { return .failure(.invalidResponse) }
			return .success(GitHubPublicKey(id: raw.keyID, key: key))
		}
	}

	func setSecret(_ name: String, to sealed: GitHubSealedSecret, in scope: GitHubScope) async -> Result<Void, GitHubAPIError> {
		guard GitHubPublishing.isAcceptedKey(name), let url = GitHubHTTP.url(baseURL, scope.path("secrets", name)),
			let body = try? JSONSerialization.data(withJSONObject: ["encrypted_value": sealed.ciphertext.base64EncodedString(), "key_id": sealed.keyID])
		else { return .failure(.invalidResponse) }
		return await GitHubHTTP.load(GitHubHTTP.request("PUT", url, token: token, body: body), using: session).map { _ in () }
	}

	func variables(in scope: GitHubScope) async -> Result<[GitHubValueRecord], GitHubAPIError> {
		await records(scope.path("variables"), field: "variables", listing: .variables, perPage: 30)
	}

	func variable(_ name: String, in scope: GitHubScope) async -> Result<GitHubValueRecord?, GitHubAPIError> {
		await record(scope.path("variables", name), named: name)
	}

	func createVariable(_ name: String, value: String, in scope: GitHubScope) async -> Result<Void, GitHubAPIError> {
		guard GitHubPublishing.isAcceptedKey(name), let url = GitHubHTTP.url(baseURL, scope.path("variables")),
			let body = try? JSONSerialization.data(withJSONObject: ["name": name, "value": value])
		else { return .failure(.invalidResponse) }
		return await GitHubHTTP.load(GitHubHTTP.request("POST", url, token: token, body: body), using: session).map { _ in () }
	}

	func updateVariable(_ name: String, value: String, in scope: GitHubScope) async -> Result<Void, GitHubAPIError> {
		guard GitHubPublishing.isAcceptedKey(name), let url = GitHubHTTP.url(baseURL, scope.path("variables", name)),
			let body = try? JSONSerialization.data(withJSONObject: ["name": name, "value": value])
		else { return .failure(.invalidResponse) }
		return await GitHubHTTP.load(GitHubHTTP.request("PATCH", url, token: token, body: body), using: session).map { _ in () }
	}

	// MARK: - Lists

	/// What a listing may still read, shared by every page of it.
	private struct Budget {
		var bytes: Int
		let deadline: ContinuousClock.Instant
		let deadlinePasses: @Sendable (ContinuousClock.Instant) async -> Void
		/// Pages read so far by every list sharing the budget.
		var pagesRead = 0

		init(_ limits: Limits) {
			bytes = limits.listBytes
			deadline = ContinuousClock.now.advanced(by: limits.listDeadline)
			deadlinePasses = limits.deadlinePasses
		}

		/// What running out of time means for `listing`: GitHub too slow once
		/// it had answered, and unreachable when it hadn't.
		func timedOut(_ listing: GitHubAPIError.Listing) -> GitHubAPIError {
			pagesRead > 0 ? .timedOut(listing) : .transport
		}
	}

	/// A list's items, and whether GitHub said it left out results an
	/// organization's single sign-on hides.
	private struct Listed<Item: Sendable>: Sendable {
		var items: [Item] = []
		var hidesSSOResults = false
	}

	/// Every item of a paged list, read page by page within `budget`. Running
	/// out of pages or bytes is `.tooLarge`, and of time `.timedOut`, or
	/// `.transport` before GitHub answered; a page cut off at its own limit
	/// is unreadable.
	///
	/// A strict list, as of secrets or variables, must agree with itself: a
	/// page with more items than asked for, more items than the total GitHub
	/// gave, or a total that changes between pages fails it. A lenient one, as
	/// of repositories, reads what GitHub lists: an item it can't decode is
	/// nil, a total that shifts while it's read is followed, and a missing
	/// list with no total is empty. Either ends at a short page, or when
	/// GitHub's `Link` names no next page; LPM Vault builds each page's URL
	/// itself, so the token never follows one GitHub sends.
	private func list<Item: Decodable & Sendable>(
		_ path: [String],
		field: String,
		listing: GitHubAPIError.Listing,
		perPage: Int,
		lenient: Bool = false,
		budget: inout Budget,
		as _: Item.Type
	) async -> Result<Listed<Item?>, GitHubAPIError> {
		var listed = Listed<Item?>()
		var total: Int?
		for page in 1...limits.maximumPages {
			guard budget.bytes > 0 else { return .failure(.tooLarge(listing)) }
			guard budget.pagesRead == 0 || ContinuousClock.now < budget.deadline else { return .failure(budget.timedOut(listing)) }
			let query = [URLQueryItem(name: "per_page", value: String(perPage)), URLQueryItem(name: "page", value: String(page))]
			guard let url = GitHubHTTP.url(baseURL, path, query: query) else { return .failure(.invalidResponse) }
			let request = GitHubHTTP.request("GET", url, token: token)
			let budgetBinds = budget.bytes <= limits.pageBytes
			guard let loaded = await Self.load(
				request, using: session, limit: min(limits.pageBytes, budget.bytes), until: budget.deadline,
				deadlinePasses: budget.deadlinePasses)
			else { return .failure(Task.isCancelled ? .cancelled : budget.timedOut(listing)) }
			// A refusal's body counts too, as one installation's refusal leaves the listing going.
			budget.bytes -= loaded.bytes
			if loaded.cutOff, budgetBinds { return .failure(.tooLarge(listing)) }
			let data: Data
			let response: HTTPURLResponse
			switch loaded.result {
			case .success(let value): (data, response) = value
			case .failure(let error): return .failure(error)
			}
			budget.pagesRead += 1
			if response.value(forHTTPHeaderField: "X-GitHub-SSO")?.lowercased().hasPrefix("partial-results") == true {
				listed.hidesSSOResults = true
			}
			guard let decoded = try? GitHubListPage<Item>.decode(data, field: field, lenient: lenient, maximumItems: perPage) else {
				return .failure(.invalidResponse)
			}
			listed.items.append(contentsOf: decoded.items)
			if !lenient {
				guard let pageTotal = decoded.totalCount, pageTotal >= 0, total == nil || total == pageTotal, listed.items.count <= pageTotal else {
					return .failure(.invalidResponse)
				}
				total = pageTotal
				if listed.items.count == pageTotal || decoded.items.count < perPage {
					return listed.items.count == pageTotal ? .success(listed) : .failure(.invalidResponse)
				}
			} else if !Self.hasNextPage(response, itemCount: decoded.items.count, perPage: perPage) {
				return .success(listed)
			}
		}
		return .failure(.tooLarge(listing))
	}

	/// Whether a list goes on past this page: as its `Link` says, as GitHub
	/// asks lists be followed, and without one, when the page was full.
	private static func hasNextPage(_ response: HTTPURLResponse, itemCount: Int, perPage: Int) -> Bool {
		guard let link = response.value(forHTTPHeaderField: "Link") else { return itemCount == perPage }
		return link.split(separator: ",").contains { part in
			part.split(separator: ";").dropFirst().contains { $0.trimmingCharacters(in: .whitespaces) == #"rel="next""# }
		}
	}

	/// The load's answer as `loadCounted` gives it, or nil once `deadline` passes first, which cancels the load.
	private static func load(
		_ request: URLRequest,
		using session: URLSession,
		limit: Int,
		until deadline: ContinuousClock.Instant,
		deadlinePasses: @escaping @Sendable (ContinuousClock.Instant) async -> Void
	) async -> (result: Result<(Data, HTTPURLResponse), GitHubAPIError>, bytes: Int, cutOff: Bool)? {
		await withTaskGroup(of: (result: Result<(Data, HTTPURLResponse), GitHubAPIError>, bytes: Int, cutOff: Bool)?.self) { group in
			group.addTask {
				let loaded = await GitHubHTTP.loadCounted(request, using: session, limit: limit)
				return (loaded.result.map { ($0.data, $0.response) }, loaded.bytes, loaded.cutOff)
			}
			group.addTask {
				await deadlinePasses(deadline)
				return nil
			}
			let first = await group.next() ?? nil
			group.cancelAll()
			return first
		}
	}

	private func records(
		_ path: [String],
		field: String,
		listing: GitHubAPIError.Listing,
		perPage: Int
	) async -> Result<[GitHubValueRecord], GitHubAPIError> {
		var budget = Budget(limits)
		return await list(path, field: field, listing: listing, perPage: perPage, budget: &budget, as: RawRecord.self).flatMap { raws in
			var records: [GitHubValueRecord] = []
			records.reserveCapacity(raws.items.count)
			for raw in raws.items {
				guard let record = raw?.record else { return .failure(.invalidResponse) }
				records.append(record)
			}
			return .success(records)
		}
	}

	private func record(_ path: [String], named name: String) async -> Result<GitHubValueRecord?, GitHubAPIError> {
		guard GitHubPublishing.isAcceptedKey(name), let url = GitHubHTTP.url(baseURL, path) else { return .failure(.invalidResponse) }
		switch await GitHubHTTP.load(GitHubHTTP.request("GET", url, token: token), using: session) {
		case .success(let loaded):
			guard let record = (try? JSONDecoder().decode(RawRecord.self, from: loaded.data))?.record, record.name == name else {
				return .failure(.invalidResponse)
			}
			return .success(record)
		case .failure(.notFound):
			return .success(nil)
		case .failure(let error):
			return .failure(error)
		}
	}

	// MARK: - Answers

	private struct User: Decodable {
		let id: Int64
		let login: String
		let name: String?
	}

	private struct Installation: Decodable, Sendable {
		private struct Account: Decodable {
			let login: String?
		}

		let id: Int64
		/// The login of the account it's installed on, when GitHub gave a valid one.
		let account: String?
		let suspendedAt: String?

		private enum CodingKeys: String, CodingKey {
			case id
			case account
			case suspendedAt = "suspended_at"
		}

		init(from decoder: any Decoder) throws {
			let container = try decoder.container(keyedBy: CodingKeys.self)
			id = try container.decode(Int64.self, forKey: .id)
			suspendedAt = try container.decodeIfPresent(String.self, forKey: .suspendedAt)
			// An account in another form, as an enterprise's, leaves the installation unnamed rather than unlisted.
			account = (try? container.decodeIfPresent(Account.self, forKey: .account))?.login.flatMap { GitHubHTTP.isValidLogin($0) ? $0 : nil }
		}
	}

	private struct RawRepository: Decodable, Sendable {
		/// The person's roles on the repository, as GitHub lists them.
		struct Permissions: Decodable, Sendable {
			let admin: Bool?
			let maintain: Bool?
			let push: Bool?
		}

		let id: Int64
		let fullName: String
		let isPrivate: Bool?
		let archived: Bool?
		let permissions: Permissions?

		private enum CodingKeys: String, CodingKey {
			case id
			case fullName = "full_name"
			case isPrivate = "private"
			case archived
			case permissions
		}

		var repository: GitHubRepository? {
			guard let id = GitHubHTTP.id(id), GitHubPublishTarget.isValidFullName(fullName) else { return nil }
			let permission: GitHubRepository.Permission? = permissions.map { roles in
				if roles.admin == true { return .admin }
				return roles.push == true || roles.maintain == true ? .write : .read
			}
			return GitHubRepository(id: id, fullName: fullName, isPrivate: isPrivate ?? true, isArchived: archived ?? false, permission: permission)
		}
	}

	private struct RawEnvironment: Decodable, Sendable {
		let id: Int64
		let name: String

		var environment: GitHubEnvironment? {
			guard let id = GitHubHTTP.id(id), GitHubPublishTarget.Scope.isValidEnvironmentName(name) else { return nil }
			return GitHubEnvironment(id: id, name: name)
		}
	}

	/// A secret or variable as GitHub lists it. A variable's value is never decoded.
	private struct RawRecord: Decodable, Sendable {
		let name: String
		let updatedAt: String

		private enum CodingKeys: String, CodingKey {
			case name
			case updatedAt = "updated_at"
		}

		var record: GitHubValueRecord? {
			guard GitHubPublishing.isRemoteName(name), let date = PlatformTimestamp.utc(updatedAt) else { return nil }
			return GitHubValueRecord(name: name, updatedAt: date)
		}
	}

	private struct RawPublicKey: Decodable {
		let keyID: String
		let key: String

		private enum CodingKeys: String, CodingKey {
			case keyID = "key_id"
			case key
		}
	}
}

/// One page of a list GitHub answers with its total and the items under
/// `field`. The page's item count is checked before any item is decoded, so
/// an overlong page costs nothing more than its parsing. On a lenient list
/// an item that doesn't decode is nil, and a page without the list is empty
/// when its total is missing or zero.
struct GitHubListPage<Item: Decodable>: Decodable {
	let totalCount: Int?
	let items: [Item?]

	private static var fieldKey: CodingUserInfoKey { CodingUserInfoKey(rawValue: "field")! }
	private static var lenientKey: CodingUserInfoKey { CodingUserInfoKey(rawValue: "lenient")! }
	private static var maximumItemsKey: CodingUserInfoKey { CodingUserInfoKey(rawValue: "maximumItems")! }

	static func decode(_ data: Data, field: String, lenient: Bool, maximumItems: Int) throws -> Self {
		let decoder = JSONDecoder()
		decoder.userInfo[fieldKey] = field
		decoder.userInfo[lenientKey] = lenient
		decoder.userInfo[maximumItemsKey] = maximumItems
		return try decoder.decode(Self.self, from: data)
	}

	private struct Key: CodingKey {
		let stringValue: String
		var intValue: Int? { nil }
		init(stringValue: String) { self.stringValue = stringValue }
		init?(intValue: Int) { nil }
	}

	/// An item that's nil when it doesn't decode, so a list reads past it.
	private struct Lenient: Decodable {
		let item: Item?
		init(from decoder: any Decoder) throws { item = try? Item(from: decoder) }
	}

	init(from decoder: any Decoder) throws {
		guard let field = decoder.userInfo[Self.fieldKey] as? String, let maximumItems = decoder.userInfo[Self.maximumItemsKey] as? Int else {
			throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "No field"))
		}
		let lenient = decoder.userInfo[Self.lenientKey] as? Bool ?? false
		let container = try decoder.container(keyedBy: Key.self)
		let itemsKey = Key(stringValue: field)
		totalCount = lenient
			? try container.decodeIfPresent(Int.self, forKey: Key(stringValue: "total_count"))
			: try container.decode(Int.self, forKey: Key(stringValue: "total_count"))
		guard container.contains(itemsKey) else {
			guard lenient, (totalCount ?? 0) == 0 else {
				throw DecodingError.keyNotFound(itemsKey, .init(codingPath: [], debugDescription: "No items"))
			}
			items = []
			return
		}
		var list = try container.nestedUnkeyedContainer(forKey: itemsKey)
		guard let count = list.count, count <= maximumItems else {
			throw DecodingError.dataCorrupted(.init(codingPath: [itemsKey], debugDescription: "More items than a page holds"))
		}
		var items: [Item?] = []
		items.reserveCapacity(count)
		while !list.isAtEnd {
			if lenient {
				items.append(try list.decode(Lenient.self).item)
			} else {
				items.append(try list.decode(Item.self))
			}
		}
		self.items = items
	}
}
