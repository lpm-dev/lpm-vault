import Foundation
import Testing
@testable import LPMVault

struct NetlifyClientTests {
	private func client(_ route: PlatformHTTPStub.Route) -> NetlifyClient {
		NetlifyClient(token: "nfo_secret", baseURL: route.baseURL, session: route.session)
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
		#expect(request.header("User-Agent") == NetlifyHTTP.userAgent)
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

	@Test("a rate limit is waited out until Netlify says it lifts, a minute when it doesn't say, and not when it lifts after the longest wait, however far off or malformed")
	func rateLimitWait() throws {
		#expect(NetlifyHTTP.rateLimitWait(until: nil) == .seconds(60))
		#expect(NetlifyHTTP.rateLimitWait(until: Date(timeIntervalSinceNow: -5)) == .zero)
		#expect(NetlifyHTTP.rateLimitWait(until: Date(timeIntervalSince1970: -1e20)) == .zero)
		let lifts = Date(timeIntervalSinceNow: 30)
		let soon = try #require(NetlifyHTTP.rateLimitWait(until: lifts))
		#expect(soon >= .seconds(lifts.timeIntervalSinceNow) && soon <= .seconds(30), "\(soon) covers what was left when it was worked out")
		let longest = Date(timeIntervalSinceNow: Double(NetlifyHTTP.maximumRateLimitWait.components.seconds) + 3_600)
		for reset in [longest, Date(timeIntervalSince1970: 1e20), Date(timeIntervalSince1970: .infinity), Date(timeIntervalSince1970: .nan)] {
			#expect(NetlifyHTTP.rateLimitWait(until: reset) == nil)
		}
	}

	@Test("the wait for a rate limit covers all the time left, never stopping short of when it lifts")
	func rateLimitWaitRoundsUp() throws {
		for left in [0.4, 0.0004, 1.2345678] {
			let reset = Date(timeIntervalSinceNow: left)
			let wait = try #require(NetlifyHTTP.rateLimitWait(until: reset))
			let waited = Double(wait.components.seconds) + Double(wait.components.attoseconds) / 1e18
			#expect(Date(timeIntervalSinceNow: waited) >= reset, "A wait of \(wait) stops short of a limit lifting in \(left) s")
		}
	}

	@Test("waiting out a rate limit returns only once the wall clock has passed it, though the sleep's own clock may run ahead")
	func waitsForTheWallClock() async throws {
		let reset = Date(timeIntervalSinceNow: 0.05)
		// A sleep that ends at once stands in for a sleep clock running ahead of the wall clock.
		try await NetlifyHTTP.waitOut(.zero, until: reset)
		#expect(Date() >= reset)
		try await NetlifyHTTP.waitOut(.milliseconds(1), until: nil)
	}

	private func site(_ id: String, team: String = "team_northwind", teamName: Any = "Northwind") -> [String: Any] {
		["id": id, "name": "site-\(id)", "account_id": team, "account_name": teamName, "account_slug": "northwind",
			"build_settings": ["env": ["IGNORED": "x"]], "published_deploy": ["id": "d1"]]
	}

	@Test("sites are read page by page across the user's teams, with each site's team")
	func listsSites() async throws {
		let route = PlatformHTTPStub.platform { request in
			let page = Int(request.query["page"] ?? "1") ?? 1
			let count = page == 1 ? NetlifyClient.sitePageSize : 3
			return .json(200, (0..<count).map { site("s\(page)-\($0)", teamName: page == 2 ? NSNull() : "Northwind") })
		}
		let sites = try await client(route).sites().get()
		#expect(sites.count == NetlifyClient.sitePageSize + 3)
		#expect(sites.first == NetlifySite(id: "s1-0", name: "site-s1-0", teamID: "team_northwind", teamName: "Northwind"))
		#expect(sites.last?.teamName == "northwind", "A team without a name reads by its slug")
		#expect(route.requests.map { $0.query["page"] } == ["1", "2"])
		#expect(route.requests.allSatisfy { $0.query["filter"] == "all" && $0.query["per_page"] == "100" && $0.url.path() == "/api/v1/sites" })
	}

	@Test("a page of more sites than asked for, a site listed twice, an unsafe ID, or a listing past its budget or deadline fails")
	func boundsSites() async throws {
		let oversized = PlatformHTTPStub.platform { _ in .json(200, (0...NetlifyClient.sitePageSize).map { site("s\($0)") }) }
		#expect(await client(oversized).sites() == .failure(.invalidResponse))
		let twice = PlatformHTTPStub.platform { _ in .json(200, [site("s1"), site("s1")]) }
		#expect(await client(twice).sites() == .failure(.invalidResponse))
		let unsafe = PlatformHTTPStub.platform { _ in .json(200, [site("../x")]) }
		#expect(await client(unsafe).sites() == .failure(.invalidResponse))
		let foreignTeam = PlatformHTTPStub.platform { _ in .json(200, [site("s1", team: "a/b")]) }
		#expect(await client(foreignTeam).sites() == .failure(.invalidResponse))

		let endless = PlatformHTTPStub.platform { request in
			let page = request.query["page"] ?? "1"
			return .json(200, (0..<NetlifyClient.sitePageSize).map { site("p\(page)-\($0)") })
		}
		let budget = NetlifyClient(token: "nfo_secret", baseURL: endless.baseURL, session: endless.session,
			limits: .init(siteBytes: 40_000, siteDeadline: .seconds(60)))
		#expect(await budget.sites() == .failure(.invalidResponse))
		#expect(endless.requests.count < 5)
		let late = NetlifyClient(token: "nfo_secret", baseURL: endless.baseURL, session: endless.session,
			limits: .init(siteBytes: 64 * 1024 * 1024, siteDeadline: .zero))
		let before = endless.requests.count
		#expect(await late.sites() == .failure(.invalidResponse))
		#expect(endless.requests.count - before <= 1, "Nothing loads past the deadline")
	}

	@Test("a page that arrives after the listing's deadline fails the listing, though it's the last", .hangLimit)
	func lateLastPage() async throws {
		let lastPage = DispatchSemaphore(value: 0)
		defer { lastPage.signal() }
		let route = PlatformHTTPStub.platform { _ in
			lastPage.wait()
			return .json(200, [self.site("late")])
		}
		let client = NetlifyClient(token: "nfo_secret", baseURL: route.baseURL, session: route.session,
			limits: .init(siteBytes: 64 * 1024 * 1024, siteDeadline: .zero))
		#expect(await client.sites() == .failure(.invalidResponse), "The listing ends at its deadline: the page arrives only after it returns")
	}

	@Test("a site's variables are read under its team, with the site in the query, and without their values")
	func readsVariables() async throws {
		let route = PlatformHTTPStub.platform { _ in
			.json(200, [
				["key": "API_TOKEN", "scopes": ["builds", "functions", "runtime"], "is_secret": true, "updated_at": "2026-10-14T12:34:56.789Z",
					"values": [["id": "v1", "context": "production", "value": "s3cret-value"], ["id": "v2", "context": "branch", "context_parameter": "staging", "value": "x"]]],
				["key": "LEGACY", "values": [["id": "v3", "context": "all", "value": "plain"]], "updated_at": "2020-01-01T00:00:00Z"],
				["key": "ODD", "is_secret": false, "values": [["id": "v4", "context": "something-new", "value": "y"]]],
			])
		}
		let variables = try await client(route).variables(siteID: "site-1", teamID: "team_northwind").get()
		let request = try #require(route.requests.first)
		#expect(request.url.path() == "/api/v1/accounts/team_northwind/env" && request.query["site_id"] == "site-1")
		#expect(request.header("Authorization") == "Bearer nfo_secret")
		#expect(variables == [
			NetlifyVariable(key: "API_TOKEN", isSecret: true, values: [
				NetlifyVariable.Value(id: "v1", context: .production), NetlifyVariable.Value(id: "v2", context: .branch("staging")),
			], updatedAt: Date(timeIntervalSince1970: 1_791_981_296.789)),
			NetlifyVariable(key: "LEGACY", isSecret: false, values: [NetlifyVariable.Value(id: "v3", context: .all)],
				updatedAt: Date(timeIntervalSince1970: 1_577_836_800)),
			NetlifyVariable(key: "ODD", isSecret: false, values: [NetlifyVariable.Value(id: "v4", context: .other("something-new"))], updatedAt: nil),
		])
		var dumped = ""
		dump(variables, to: &dumped)
		#expect(!dumped.contains("s3cret-value"))
	}

	@Test("a value without a safe ID, or a time Netlify didn't write as UTC, makes the listing unreadable")
	func refusesMalformedVariables() async {
		for variable: [String: Any] in [
			["key": "A", "values": [["context": "production", "value": "x"]]],
			["key": "A", "values": [["id": "../v", "context": "production", "value": "x"]]],
			["key": "A", "values": [], "updated_at": "2026-10-14T12:34:56+02:00"],
			["key": "", "values": []],
		] {
			let body = (try? JSONSerialization.data(withJSONObject: [variable])) ?? Data()
			let route = PlatformHTTPStub.platform { _ in PlatformHTTPStub.Reply(status: 200, body: body) }
			#expect(await client(route).variables(siteID: "site-1", teamID: "team_1") == .failure(.invalidResponse))
		}
	}

	@Test("a new variable is created on the site with its context's value; a secret names Netlify's secret scopes, a readable one none")
	func creates() async throws {
		let route = PlatformHTTPStub.platform { request in
			guard let body = try? JSONSerialization.jsonObject(with: request.body) as? [[String: Any]], let key = body.first?["key"] as? String else {
				return .json(400, [:])
			}
			return .json(201, [["key": key, "is_secret": body.first?["is_secret"] as Any, "updated_at": "2026-10-14T12:34:56Z",
				"values": [["id": "v1", "context": "branch", "context_parameter": "release/*", "value": "masked"]]]])
		}
		let secret = NetlifyVariableWrite(key: "API_TOKEN", value: "s3cret", context: .branch("release/*"), isSecret: true)
		let created = try await client(route).create(secret, siteID: "site-1", teamID: "team_1").get()
		#expect(created.key == "API_TOKEN" && created.isSecret && created.values.first?.context == .branch("release/*"))
		let request = try #require(route.requests.first)
		#expect(request.method == "POST" && request.url.path() == "/api/v1/accounts/team_1/env" && request.query["site_id"] == "site-1")
		let body = try #require(try JSONSerialization.jsonObject(with: request.body) as? [[String: Any]])
		#expect(body.count == 1 && body[0]["key"] as? String == "API_TOKEN" && body[0]["is_secret"] as? Bool == true)
		#expect(body[0]["scopes"] as? [String] == ["builds", "functions", "runtime"])
		let value = try #require((body[0]["values"] as? [[String: Any]])?.first)
		#expect(value["context"] as? String == "branch" && value["context_parameter"] as? String == "release/*" && value["value"] as? String == "s3cret")

		_ = try await client(route).create(
			NetlifyVariableWrite(key: "PUBLIC_URL", value: "https://x", context: .production, isSecret: false), siteID: "site-1", teamID: "team_1").get()
		let readable = try #require(try JSONSerialization.jsonObject(with: route.requests[1].body) as? [[String: Any]])
		#expect(readable[0]["scopes"] == nil && readable[0]["is_secret"] as? Bool == false)
		#expect((readable[0]["values"] as? [[String: Any]])?.first?["context_parameter"] == nil)
	}

	@Test("a value is set on the site's variable by its name, and an answer about another variable is refused")
	func setsValue() async throws {
		let route = PlatformHTTPStub.platform { request in
			.json(201, ["key": request.url.lastPathComponent, "is_secret": true, "values": [["id": "v9", "context": "deploy-preview", "value": "x"]]])
		}
		let write = NetlifyVariableWrite(key: "API_TOKEN", value: "s3cret", context: .deployPreview, isSecret: true)
		#expect(try await client(route).setValue(write, siteID: "site-1", teamID: "team_1").get().values.first?.id == "v9")
		let request = try #require(route.requests.first)
		#expect(request.method == "PATCH" && request.url.path() == "/api/v1/accounts/team_1/env/API_TOKEN" && request.query["site_id"] == "site-1")
		let body = try #require(request.json)
		#expect(body["context"] as? String == "deploy-preview" && body["value"] as? String == "s3cret" && body["context_parameter"] == nil)

		let other = PlatformHTTPStub.platform { _ in .json(201, ["key": "OTHER", "values": []]) }
		#expect(await client(other).setValue(write, siteID: "site-1", teamID: "team_1") == .failure(.invalidResponse))
	}

	@Test("one variable is read under the site's team with the site in the query; one the site doesn't have reads as none")
	func readsOneVariable() async throws {
		let route = PlatformHTTPStub.platform { request in
			request.url.lastPathComponent == "MISSING"
				? .json(404, ["code": 404, "message": "Not Found"])
				: .json(200, ["key": request.url.lastPathComponent, "is_secret": true, "values": [["id": "v1", "context": "production", "value": "x"]]])
		}
		let variable = try await client(route).variable("API_TOKEN", siteID: "site-1", teamID: "team_1").get()
		#expect(variable?.key == "API_TOKEN" && variable?.values.first?.id == "v1")
		let request = try #require(route.requests.first)
		#expect(request.method == "GET" && request.url.path() == "/api/v1/accounts/team_1/env/API_TOKEN" && request.query["site_id"] == "site-1")
		#expect(try await client(route).variable("MISSING", siteID: "site-1", teamID: "team_1").get() == nil)
		let other = PlatformHTTPStub.platform { _ in .json(200, ["key": "OTHER", "values": []]) }
		#expect(await client(other).variable("API_TOKEN", siteID: "site-1", teamID: "team_1") == .failure(.invalidResponse))
	}

	@Test("a write with an unsafe name, site or team sends nothing")
	func unsafeWrites() async {
		let route = PlatformHTTPStub.platform { _ in .json(201, []) }
		let unsafe = NetlifyVariableWrite(key: "A/B", value: "v", context: .production, isSecret: true)
		let safe = NetlifyVariableWrite(key: "A", value: "v", context: .production, isSecret: true)
		#expect(await client(route).setValue(unsafe, siteID: "site-1", teamID: "team_1") == .failure(.invalidResponse))
		#expect(await client(route).create(unsafe, siteID: "site-1", teamID: "team_1") == .failure(.invalidResponse))
		#expect(await client(route).create(safe, siteID: "../site", teamID: "team_1") == .failure(.invalidResponse))
		#expect(await client(route).variables(siteID: "site-1", teamID: "team?x") == .failure(.invalidResponse))
		#expect(route.requests.isEmpty)
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
	}

	@Test("a client, a grant or a connection never prints its token")
	func redacted() throws {
		let values: [Any] = [
			NetlifyClient(token: "nfo_secret_token"),
			try #require(NetlifyGrant(accessToken: "nfo_secret_token")),
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
