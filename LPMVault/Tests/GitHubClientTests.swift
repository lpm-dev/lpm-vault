import CryptoKit
import Foundation
import Testing
@testable import LPMVault

struct GitHubHTTPTests {
	private let base = URL(string: "https://api.github.com")!

	@Test("each path segment is escaped on its own, so a name can't add a segment or a query")
	func escapesSegments() throws {
		let url = try #require(GitHubHTTP.url(base, ["repos", "acme", "api", "environments", "prod/eu west?x#y", "secrets"]))
		#expect(url.absoluteString == "https://api.github.com/repos/acme/api/environments/prod%2Feu%20west%3Fx%23y/secrets")
		#expect(GitHubHTTP.url(base, ["repos", ".."]) == nil)
		#expect(GitHubHTTP.url(base, ["repos", ""]) == nil)
		let paged = try #require(GitHubHTTP.url(base, ["user", "installations"], query: [URLQueryItem(name: "per_page", value: "100")]))
		#expect(paged.absoluteString == "https://api.github.com/user/installations?per_page=100")
	}

	@Test("requests name the API version, the client and the token, and ask for GitHub's JSON")
	func requestHeaders() throws {
		let request = GitHubHTTP.request("GET", try #require(GitHubHTTP.url(base, ["user"])), token: "ghu_token")
		#expect(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
		#expect(request.value(forHTTPHeaderField: "X-GitHub-Api-Version") == "2022-11-28")
		#expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer ghu_token")
		#expect(request.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("LPM-Vault") == true)
	}

	private func failure(_ status: Int, headers: [String: String] = [:], message: String? = nil) -> GitHubAPIError {
		let http = HTTPURLResponse(url: base, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
		let body = message.flatMap { try? JSONSerialization.data(withJSONObject: ["message": $0]) } ?? Data()
		return GitHubHTTP.failure(http, body: body, now: Date(timeIntervalSince1970: 1_760_000_000))
	}

	@Test("refusals read as GitHub documents its limits, and a 403 that's no limit as missing access")
	func readsRefusals() {
		#expect(failure(401) == .unauthorized)
		#expect(failure(404) == .notFound)
		#expect(failure(422) == .rejected(status: 422))
		#expect(failure(502) == .server(502))
		#expect(failure(403) == .forbidden)
		#expect(failure(403, message: "Resource not accessible by integration") == .forbidden)
		#expect(failure(403, headers: ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "1760000042"])
			== .rateLimited(until: Date(timeIntervalSince1970: 1_760_000_042)))
		#expect(failure(403, headers: ["Retry-After": "30"]) == .rateLimited(until: Date(timeIntervalSince1970: 1_760_000_030)))
		#expect(failure(429, headers: ["retry-after": "5"]) == .rateLimited(until: Date(timeIntervalSince1970: 1_760_000_005)))
		#expect(failure(403, message: "You have exceeded a secondary rate limit.") == .rateLimited(until: nil))
		#expect(failure(429) == .rateLimited(until: nil))
		#expect(failure(403, headers: ["X-RateLimit-Remaining": "12"]) == .forbidden)
	}

	@Test("a spent limit's reset is read on GitHub's clock, from its answer's Date, so a Mac clock running ahead doesn't ask while it's limited")
	func readsResetOnGitHubsClock() {
		#expect(failure(403, headers: ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "1760000000", "Date": "Thu, 09 Oct 2025 08:52:50 GMT"])
			== .rateLimited(until: Date(timeIntervalSince1970: 1_760_000_030)))
		#expect(failure(403, headers: ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "1759999999"]) == .rateLimited(until: nil),
			"A reset this Mac's clock is past, with no Date to measure it from, says nothing of when the limit lifts")
	}

	@Test("a limit GitHub doesn't time is waited out a minute at first, then two, however many limits came before")
	func unannouncedLimitWaits() {
		#expect(GitHubHTTP.unannouncedLimitWait(after: 0) == .seconds(60))
		#expect(GitHubHTTP.unannouncedLimitWait(after: 1) == .seconds(120))
		#expect(GitHubHTTP.unannouncedLimitWait(after: 4) == .seconds(120))
	}

	@Test("a Link header is read as RFC 8288 writes it: quoted parameters may hold <, >, ; and , and only a link's first rel counts")
	func readsLinks() {
		func next(_ header: String) -> String?? {
			GitHubHTTP.links(header).map { $0.first { $0.relations.contains("next") }?.target }
		}
		#expect(next(#"<?page=2>; title="page < 3"; rel="next""#) == .some("?page=2"))
		#expect(next(#"<a>; rel="prev"; title="x; rel=next, <b>", <c>; rel=next"#) == .some("c"))
		#expect(next(#"<a>; rel="next last""#) == .some("a"))
		#expect(next(#"<a>; REL = "NEXT""#) == .some("a"))
		#expect(next(#"<a>; title="say \"next\""; rel=last"#) == .some(nil))
		#expect(next(#"<a>; rel="prev"; rel="next""#) == .some(nil), "A rel after the first is ignored")
		#expect(next(#" , <a>; rel=next ,, "#) == .some("a"))
		#expect(next("") == .some(nil))
		for malformed in [
			#"<a; rel="next""#, #"<a>; rel="next"#, "garbage", "<a> junk", #"<a>; ="next""#, #"<a>; rel="next" <b>"#, "<a>; rel=", "<a>; rel= , <b>; rel=next",
		] {
			#expect(next(malformed) == nil, "\(malformed)")
		}
	}

	@Test("IDs, logins, app slugs and client IDs take only GitHub's forms")
	func validatesNames() {
		#expect(GitHubHTTP.isValidID("583231") && !GitHubHTTP.isValidID("0583") && !GitHubHTTP.isValidID("-1") && !GitHubHTTP.isValidID(""))
		#expect(!GitHubHTTP.isValidID(String(repeating: "9", count: 21)))
		#expect(GitHubHTTP.isValidLogin("octo-cat") && GitHubHTTP.isValidLogin("mona-cat_octo"), "A managed user's login ends in _ and the enterprise's short code")
		for login in ["", "octo cat", "octo/cat", "octö", String(repeating: "a", count: 40)] { #expect(!GitHubHTTP.isValidLogin(login)) }
		#expect(GitHubHTTP.isValidAppSlug("lpm-vault") && !GitHubHTTP.isValidAppSlug("LPM-Vault") && !GitHubHTTP.isValidAppSlug("lpm/vault"))
		#expect(GitHubHTTP.isValidClientID("Iv23liTestClient01") && GitHubHTTP.isValidClientID("Iv1.8a61f9b3a7aba766"))
		for clientID in ["Iv23 li", ".Iv1", "Iv1..8a61", "Iv1/abc", String(repeating: "x", count: 129)] { #expect(!GitHubHTTP.isValidClientID(clientID)) }
	}
}

struct GitHubClientTests {
	@Test("the user is read by its numeric ID and login, with a safe name")
	func readsUser() async throws {
		let route = PlatformHTTPStub.platform { _ in .json(200, ["id": 583_231, "login": "octocat", "name": "The Octocat\u{202E}", "email": NSNull()]) }
		let user = try await GitHubClient(token: "ghu_token", baseURL: route.baseURL, session: route.session).user().get()
		#expect(user == GitHubUser(id: "583231", login: "octocat", name: "The Octocat".appending("\u{202E}".escapingDirectionControls)))
		let request = try #require(route.requests.first)
		#expect(request.method == "GET" && request.url.path == "/user")
		#expect(request.header("Authorization") == "Bearer ghu_token")
	}

	@Test("a user without a name, an unsafe login or a missing ID reads as GitHub's answer can't be read", arguments: [
		#"{"id":1,"login":"octocat","name":null}"#,
		#"{"id":1,"login":"octo cat"}"#,
		#"{"login":"octocat"}"#,
		#"{"id":0,"login":"octocat"}"#,
	])
	func readsUnusualUsers(json: String) async throws {
		let body = Data(json.utf8)
		let route = PlatformHTTPStub.platform { _ in PlatformHTTPStub.Reply(status: 200, body: body) }
		let result = await GitHubClient(token: "ghu_token", baseURL: route.baseURL, session: route.session).user()
		if json.contains(#""name":null"#) {
			#expect(result == .success(GitHubUser(id: "1", login: "octocat", name: nil)))
		} else {
			#expect(result == .failure(.invalidResponse))
		}
	}

	@Test("the client's session refuses redirects, so the token never follows one, and a redirect reads as a failure")
	func refusesRedirects() async throws {
		let client = GitHubClient(token: "ghu_token")
		#expect(client.session === GitHubHTTP.sharedSession)
		let delegate = try #require(GitHubHTTP.sharedSession.delegate as? RedirectRefusingHTTPDelegate)
		let url = URL(string: "https://api.github.com/user")!
		let response = try #require(HTTPURLResponse(url: url, statusCode: 302, httpVersion: nil, headerFields: ["Location": "https://evil.example/"]))
		let followed = await withCheckedContinuation { continuation in
			delegate.urlSession(
				GitHubHTTP.sharedSession, task: GitHubHTTP.sharedSession.dataTask(with: url), willPerformHTTPRedirection: response,
				newRequest: URLRequest(url: URL(string: "https://evil.example/")!)
			) { continuation.resume(returning: $0) }
		}
		#expect(followed == nil)

		let route = PlatformHTTPStub.platform { _ in
			PlatformHTTPStub.Reply(status: 302, headers: ["Location": "/elsewhere"], body: Data())
		}
		#expect(await GitHubClient(token: "ghu_token", baseURL: route.baseURL, session: route.session).user() == .failure(.moved))
		#expect(route.requests.map(\.url.path) == ["/user"])
	}

	@Test("a managed user's login, with its underscore, is read")
	func readsManagedUser() async {
		let route = PlatformHTTPStub.platform { _ in .json(200, ["id": 7, "login": "mona-cat_octo", "name": "Mona"]) }
		#expect(await GitHubClient(token: "ghu_token", baseURL: route.baseURL, session: route.session).user()
			== .success(GitHubUser(id: "7", login: "mona-cat_octo", name: "Mona")))
	}

	@Test("the client never prints its token")
	func redacted() {
		let client = GitHubClient(token: "ghu_secret_token")
		var dumped = ""
		dump(client, to: &dumped)
		for text in [client.description, String(reflecting: client), dumped] {
			#expect(!text.contains("ghu_secret_token"))
		}
	}
}

struct GitHubGrantTests {
	private let expiring: [String: Any] = [
		"platform": "github", "accessToken": "ghu_access", "accessTokenExpiresIn": 28_800,
		"refreshToken": "ghr_refresh", "refreshTokenExpiresIn": 15_897_600, "appSlug": "lpm-vault",
	]

	@Test("a GitHub grant carries the app's slug with tokens that expire, or that don't")
	func readsGrant() throws {
		let grant = try #require(GitHubGrant(payload: expiring))
		#expect(grant.appSlug == "lpm-vault" && grant.tokens.accessToken == "ghu_access")
		#expect(grant.tokens.expiry?.refreshToken == "ghr_refresh")
		let lasting = try #require(GitHubGrant(payload: ["platform": "github", "accessToken": "ghu_lasting", "appSlug": "lpm-vault"]))
		#expect(lasting.tokens.expiry == nil)
	}

	@Test("a grant without a well-formed slug or tokens is refused")
	func refusesMalformed() {
		#expect(GitHubGrant(payload: expiring.filter { $0.key != "appSlug" }) == nil)
		#expect(GitHubGrant(payload: expiring.merging(["appSlug": "LPM Vault"]) { _, new in new }) == nil)
		#expect(GitHubGrant(payload: expiring.filter { $0.key != "refreshTokenExpiresIn" }) == nil)
	}

	@Test("a sealed GitHub grant opens only as GitHub's, and never prints its tokens")
	func opensSealed() throws {
		let key = P256.KeyAgreement.PrivateKey()
		let id = UUID().uuidString.lowercased()
		let sealed = try RegistryTestSealer.seal(expiring, authorizationID: id, to: key.publicKey.x963Representation)
		let grant = try PlatformAuthorizationEnvelope.open(sealed, as: GitHubGrant.self, authorizationID: id, clientKey: key).get()
		#expect(PlatformAuthorizationEnvelope.open(sealed, as: NetlifyGrant.self, authorizationID: id, clientKey: key) == .failure(.invalidGrant))
		var dumped = ""
		dump(grant, to: &dumped)
		for text in [grant.description, String(reflecting: grant), dumped] {
			#expect(!text.contains("ghu_access") && !text.contains("ghr_refresh"))
		}
	}
}

struct GitHubAuthorizePageTests {
	private let registry = URL(string: "https://lpm.dev")!

	private func page(_ overrides: [String: String?] = [:]) -> String {
		var query: [String: String?] = [
			"client_id": "Iv23liTestClient01",
			"redirect_uri": "https://lpm.dev/api/vault/platforms/github/callback",
			"state": platformTestOneTimeValue(),
			"scope": "offline_access",
			"prompt": "select_account",
			"code_challenge": platformTestOneTimeValue(),
			"code_challenge_method": "S256",
		]
		query.merge(overrides) { _, new in new }
		var components = URLComponents(string: "https://github.com/login/oauth/authorize")!
		components.queryItems = query.compactMap { name, value in value.map { URLQueryItem(name: name, value: $0) } }
		return components.string!
	}

	@Test("GitHub's authorize page for the app, returning to the Registry with PKCE, is opened, for a classic app too")
	func acceptsPage() {
		#expect(PlatformAuthorizationClient.validatedPageURL(page(), for: .github, registry: registry) != nil)
		#expect(PlatformAuthorizationClient.validatedPageURL(page(["client_id": "Iv1.8a61f9b3a7aba766"]), for: .github, registry: registry) != nil)
	}

	@Test("any other page, or one changed in any way, isn't", arguments: [
		["redirect_uri": "https://evil.example/api/vault/platforms/github/callback"],
		["scope": "repo"],
		["prompt": nil],
		["code_challenge": nil],
		["code_challenge_method": "plain"],
		["state": "short"],
		["client_id": "bad id"],
		["login": "someone"],
	])
	func refusesChanged(overrides: [String: String?]) {
		#expect(PlatformAuthorizationClient.validatedPageURL(page(overrides), for: .github, registry: registry) == nil)
	}

	@Test("another host or path isn't GitHub's authorize page")
	func refusesHosts() {
		for text in [
			page().replacingOccurrences(of: "https://github.com", with: "https://github.com.evil.example"),
			page().replacingOccurrences(of: "/login/oauth/authorize", with: "/login/oauth/authorize/x"),
			page().replacingOccurrences(of: "https://", with: "http://"),
		] {
			#expect(PlatformAuthorizationClient.validatedPageURL(text, for: .github, registry: registry) == nil)
		}
		#expect(PlatformAuthorizationClient.validatedPageURL(page(), for: .netlify, registry: registry) == nil)
	}
}
