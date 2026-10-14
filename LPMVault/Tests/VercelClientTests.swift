import Foundation
import Testing
@testable import LPMVault

struct VercelClientTests {
	private func client(_ route: PlatformHTTPStub.Route) -> VercelClient {
		VercelClient(token: "vca_secret", baseURL: route.baseURL, session: route.session)
	}

	@Test("every request carries the token, and a team's requests name the team")
	func authorizesAndScopes() async throws {
		let route = PlatformHTTPStub.platform { _ in .json(200, ["id": "team_acme", "name": "Acme", "slug": "acme"]) }
		#expect(try await client(route).account(teamID: "team_acme").get() == VercelAccount(name: "Acme", slug: "acme"))
		let request = try #require(route.requests.first)
		#expect(request.url.path() == "/v2/teams/team_acme")
		#expect(request.header("Authorization") == "Bearer vca_secret")

		let projects = PlatformHTTPStub.platform { _ in .json(200, ["projects": [], "pagination": ["count": 0, "next": NSNull()]]) }
		_ = try await client(projects).projects(teamID: "team_acme").get()
		#expect(projects.requests.first?.query["teamId"] == "team_acme")
		_ = try await client(projects).projects(teamID: nil).get()
		#expect(projects.requests.last?.query["teamId"] == nil)
	}

	@Test("a personal account's name comes from the user, by name or else username")
	func personalAccount() async throws {
		let named = PlatformHTTPStub.platform { _ in .json(200, ["user": ["id": "u_1", "name": "Tolga", "username": "tolga"]]) }
		#expect(try await client(named).account(teamID: nil).get() == VercelAccount(name: "Tolga", slug: "tolga"))
		#expect(named.requests.first?.url.path() == "/v2/user")
		let limited = PlatformHTTPStub.platform { _ in .json(200, ["user": ["id": "u_1", "name": NSNull(), "username": "tolga", "limited": true]]) }
		#expect(try await client(limited).account(teamID: nil).get().name == "tolga")
	}

	@Test("projects are read page by page until Vercel has no more, with either cursor form")
	func paginatesProjects() async throws {
		let route = PlatformHTTPStub.platform { request in
			switch request.query["from"] {
			case nil:
				return .json(200, ["projects": [["id": "prj_1", "name": "api", "accountId": "team_acme", "latestDeployments": [["huge": true]]]],
					"pagination": ["count": 1, "next": 1_760_000_000_000]])
			case "1760000000000":
				return .json(200, ["projects": [["id": "prj_2", "name": "web", "accountId": "team_acme"]], "pagination": ["count": 1, "next": "cursor-2"]])
			default:
				return .json(200, ["projects": [["id": "prj_3", "name": "docs", "accountId": "team_acme"]], "pagination": ["count": 1, "next": NSNull()]])
			}
		}
		let projects = try await client(route).projects(teamID: "team_acme").get()
		#expect(projects.map(\.id) == ["prj_1", "prj_2", "prj_3"])
		#expect(route.requests.allSatisfy { $0.query["limit"] == String(VercelClient.projectPageSize) })
	}

	@Test("a cursor that repeats would loop forever, so it's refused")
	func refusesRepeatingCursor() async {
		let route = PlatformHTTPStub.platform { _ in
			.json(200, ["projects": [["id": "prj_1", "name": "api", "accountId": "team_acme"]], "pagination": ["count": 1, "next": "same"]])
		}
		#expect(await client(route).projects(teamID: nil) == .failure(.invalidResponse))
		#expect(route.requests.count == 2)
	}

	@Test("variables are read without values, with their targets, protection and hidden production count")
	func readsVariables() async throws {
		let route = PlatformHTTPStub.platform { _ in
			.json(200, [
				"envs": [
					["id": "env_1", "key": "API_TOKEN", "type": "sensitive", "target": ["production", "preview"], "value": "", "updatedAt": 1_760_000_000_000],
					["id": "env_2", "key": "LOG_LEVEL", "type": "encrypted", "target": "development", "value": "ZW5jcnlwdGVk", "gitBranch": ""],
					["id": "env_3", "key": "STAGING_ONLY", "type": "plain", "target": [], "customEnvironmentIds": ["env_custom1"], "value": "x"],
				],
				"hiddenProductionEnvCount": 2,
			])
		}
		let list = try await client(route).variables(projectID: "prj_1", teamID: "team_acme").get()
		#expect(route.requests.first?.url.path() == "/v10/projects/prj_1/env")
		#expect(list.hiddenProductionCount == 2)
		#expect(list.variables.map(\.key) == ["API_TOKEN", "LOG_LEVEL", "STAGING_ONLY"])
		#expect(list.variables[0].kind == .sensitive && list.variables[0].targets == [.production, .preview])
		#expect(list.variables[0].updatedAt == Date(timeIntervalSince1970: 1_760_000_000))
		#expect(list.variables[1].targets == [.development] && list.variables[1].gitBranch == nil)
		#expect(list.variables[2].customEnvironmentIDs == ["env_custom1"])
	}

	@Test("a list Vercel split into pages would make a review incomplete, so it's refused")
	func refusesPagedVariables() async {
		let route = PlatformHTTPStub.platform { _ in
			.json(200, ["envs": [["id": "env_1", "key": "A", "type": "plain", "target": ["preview"], "value": "x"]], "pagination": ["count": 1, "next": 17, "prev": NSNull()]])
		}
		#expect(await client(route).variables(projectID: "prj_1", teamID: nil) == .failure(.incompleteList))
	}

	@Test("creating sends the key, value, protection and targets exactly; Vercel's refusal comes back with its code")
	func creates() async throws {
		let value = "line one\nline \"two\" ✓"
		let route = PlatformHTTPStub.platform { request in
			if request.json?["key"] as? String == "TAKEN" {
				return .json(201, ["failed": [["error": ["code": "ENV_ALREADY_EXISTS", "message": "The variable already exists.\u{0007}"]]]])
			}
			return .json(201, ["created": ["id": "env_new", "key": "API_TOKEN", "type": "sensitive", "target": ["production"], "value": ""], "failed": []])
		}
		let write = VercelVariableWrite(key: "API_TOKEN", value: value, storage: .sensitive, targets: [.production], customEnvironmentIDs: [])
		let created = try await client(route).create(write, projectID: "prj_1", teamID: "team_acme").get()
		#expect(created.id == "env_new" && created.kind == .sensitive)
		let request = try #require(route.requests.first)
		#expect(request.method == "POST" && request.url.path() == "/v10/projects/prj_1/env" && request.query["upsert"] == nil)
		#expect(request.json?["value"] as? String == value)
		#expect(request.json?["type"] as? String == "sensitive")
		#expect(request.json?["target"] as? [String] == ["production"])
		#expect(request.json?["customEnvironmentIds"] == nil)

		let taken = VercelVariableWrite(key: "TAKEN", value: "", storage: .encrypted, targets: [], customEnvironmentIDs: ["env_custom1"])
		#expect(await client(route).create(taken, projectID: "prj_1", teamID: nil)
			== .failure(.rejected(code: "ENV_ALREADY_EXISTS", message: "The variable already exists.")))
		#expect(route.requests.last?.json?["customEnvironmentIds"] as? [String] == ["env_custom1"])
	}

	/// Answers like Vercel, which refuses a Secret that doesn't also say it's one.
	private static func enforcingVisibility(_ request: PlatformHTTPStub.Request, reply: () -> PlatformHTTPStub.Reply) -> PlatformHTTPStub.Reply {
		let writes = (try? JSONSerialization.jsonObject(with: request.body)).flatMap { $0 as? [[String: Any]] ?? ($0 as? [String: Any]).map { [$0] } } ?? []
		for write in writes where write["type"] as? String == "sensitive" && write["visibility"] as? String != "secret" {
			return .json(400, ["error": ["code": "bad_request", "message": "Environment variables with type: sensitive must use visibility: secret."]])
		}
		for write in writes where write["type"] as? String == "encrypted" && write["visibility"] as? String != "config" {
			return .json(400, ["error": ["code": "bad_request", "message": "Environment variables with type: encrypted must use visibility: config."]])
		}
		return reply()
	}

	@Test("a Config variable replaced with a Secret, or the other way, names its type and visibility as Vercel requires")
	func replaceStatesVisibility() async throws {
		let route = PlatformHTTPStub.platform { request in
			Self.enforcingVisibility(request) {
				.json(200, ["id": "env_1", "key": "API_TOKEN", "type": "sensitive", "visibility": "secret", "target": ["production"], "value": ""])
			}
		}
		let updated = try await client(route).replace("env_1", value: "s3cret", storage: .sensitive, projectID: "prj_1", teamID: nil).get()
		#expect(updated.kind == .sensitive)
		#expect(route.requests.last?.json?["visibility"] as? String == "secret")
		_ = try await client(route).replace("env_1", value: "info", storage: .encrypted, projectID: "prj_1", teamID: nil).get()
		#expect(route.requests.last?.json?["visibility"] as? String == "config")
	}

	@Test("a new variable names its type and visibility as Vercel requires")
	func createStatesVisibility() async throws {
		let route = PlatformHTTPStub.platform { request in
			Self.enforcingVisibility(request) {
				.json(201, ["created": ["id": "env_new", "key": "API_TOKEN", "type": "sensitive", "target": ["production"], "value": ""], "failed": []])
			}
		}
		let write = VercelVariableWrite(key: "API_TOKEN", value: "s3cret", storage: .sensitive, targets: [.production], customEnvironmentIDs: [])
		_ = try await client(route).create(write, projectID: "prj_1", teamID: nil).get()
		#expect(route.requests.last?.json?["visibility"] as? String == "secret")
	}

	@Test("replacing changes only the value and protection of that variable")
	func replaces() async throws {
		let route = PlatformHTTPStub.platform { _ in
			.json(200, ["id": "env_1", "key": "API_TOKEN", "type": "sensitive", "target": ["production", "preview"], "value": ""])
		}
		let updated = try await client(route).replace("env_1", value: "", storage: .sensitive, projectID: "prj_1", teamID: nil).get()
		#expect(updated.targets == [.production, .preview])
		let request = try #require(route.requests.first)
		#expect(request.method == "PATCH" && request.url.path() == "/v9/projects/prj_1/env/env_1")
		#expect(Set(request.json?.keys ?? [:].keys) == ["value", "type", "visibility"])
		#expect(request.json?["value"] as? String == "")
	}

	@Test(
		"Vercel's refusals map to what the person can do about them",
		arguments: [
			(401, [:], VercelAPIError.unauthorized),
			(403, [:], .forbidden),
			(404, [:], .notFound),
			(429, ["X-RateLimit-Reset": "1760000000"], .rateLimited(until: Date(timeIntervalSince1970: 1_760_000_000))),
			(500, [:], .server(500)),
		] as [(Int, [String: String], VercelAPIError)]
	)
	func refusals(status: Int, headers: [String: String], expected: VercelAPIError) async {
		let route = PlatformHTTPStub.platform { _ in .json(status, ["error": ["message": "no"]], headers: headers) }
		#expect(await client(route).customEnvironments(projectID: "prj_1", teamID: nil) == .failure(expected))
	}

	@Test(
		"a token Vercel no longer accepts needs reconnecting; a refused permission or a conflict doesn't",
		arguments: [
			(#"{"error":{"code":"forbidden","message":"Not authorized","invalidToken":true}}"#, VercelAPIError.unauthorized),
			(#"{"error":{"code":"forbidden","message":"You don't have permission"}}"#, .forbidden),
			(#"{"error":{"code":"ENV_ALREADY_EXISTS","message":"The variable already exists."}}"#,
				.rejected(code: "ENV_ALREADY_EXISTS", message: "The variable already exists.")),
			("{}", .forbidden),
		]
	)
	func forbiddenKinds(body: String, expected: VercelAPIError) async {
		let route = PlatformHTTPStub.platform { _ in PlatformHTTPStub.Reply(status: 403, body: Data(body.utf8)) }
		#expect(await client(route).variables(projectID: "prj_1", teamID: nil) == .failure(expected))
	}

	@Test("an ID that could change the request's path is never sent")
	func refusesUnsafeIdentifiers() async {
		let route = PlatformHTTPStub.platform { _ in .json(200, [:]) }
		#expect(await client(route).variables(projectID: "../teams", teamID: nil) == .failure(.invalidResponse))
		#expect(await client(route).account(teamID: "team/../x") == .failure(.invalidResponse))
		#expect(route.requests.isEmpty)
	}

	@Test("redirects are refused, so the token never follows one to another host")
	func refusesRedirects() async throws {
		let delegate = VercelSessionDelegate()
		let session = URLSession(configuration: .ephemeral)
		let task = session.dataTask(with: URL(string: "https://api.vercel.com/v2/user")!)
		let response = try #require(HTTPURLResponse(
			url: URL(string: "https://api.vercel.com/v2/user")!, statusCode: 302, httpVersion: nil,
			headerFields: ["Location": "https://evil.example/"]))
		let followed = await withCheckedContinuation { continuation in
			delegate.urlSession(
				session, task: task, willPerformHTTPRedirection: response,
				newRequest: URLRequest(url: URL(string: "https://evil.example/")!)
			) { continuation.resume(returning: $0) }
		}
		#expect(followed == nil)
	}

	@Test("neither the client nor a write prints the token or the value")
	func redacts() {
		let client = VercelClient(token: "vca_secret")
		let write = VercelVariableWrite(key: "API_TOKEN", value: "s3cret-value", storage: .sensitive, targets: [.production], customEnvironmentIDs: [])
		var dumped = ""
		dump(client, to: &dumped)
		dump(write, to: &dumped)
		for text in [client.description, String(reflecting: client), write.description, String(reflecting: write), dumped] {
			#expect(!text.contains("vca_secret") && !text.contains("s3cret-value"))
		}
	}
}
