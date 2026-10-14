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
		_ = try await client(projects).projects(teamID: "team_acme", ownerID: "team_acme").get()
		#expect(projects.requests.first?.query["teamId"] == "team_acme")
		_ = try await client(projects).projects(teamID: nil, ownerID: "team_acme").get()
		#expect(projects.requests.last?.query["teamId"] == nil)
	}

	@Test("names Vercel sends have their direction controls escaped, so they can't disguise themselves")
	func escapesNames() async throws {
		let route = PlatformHTTPStub.platform { request in
			switch request.url.path() {
			case "/v2/teams/team_acme": .json(200, ["name": "Ac\u{2028}me\u{202E}", "slug": "acme"])
			case "/v9/projects/prj_1/custom-environments": .json(200, ["environments": [["id": "env_1", "slug": "qa\u{2066}"]]])
			default: .json(200, ["projects": [["id": "prj_1", "name": "api\u{200F}", "accountId": "team_acme"]], "pagination": ["count": 1, "next": NSNull()]])
			}
		}
		#expect(try await client(route).account(teamID: "team_acme").get().name == #"Ac\u{2028}me\u{202e}"#)
		#expect(try await client(route).projects(teamID: "team_acme", ownerID: "team_acme").get().first?.name == #"api\u{200f}"#)
		#expect(try await client(route).customEnvironments(projectID: "prj_1", teamID: "team_acme").get().first?.slug == #"qa\u{2066}"#)
	}

	@Test("a later batch Vercel answers unreadably keeps the earlier batches' variables and fails only its own")
	func malformedLaterBatch() async throws {
		let route = PlatformHTTPStub.platform { request in
			guard let body = try? JSONSerialization.jsonObject(with: request.body) as? [[String: Any]] else { return .json(400, [:]) }
			if body.count == VercelClient.createBatchSize {
				return .json(201, ["created": body.map { ["id": "env_\($0["key"] as! String)", "key": $0["key"]!, "type": "sensitive", "target": ["production"]] }])
			}
			return PlatformHTTPStub.Reply(status: 200, body: Data("{not json".utf8))
		}
		let writes = (0...VercelClient.createBatchSize).map {
			VercelVariableWrite(key: "KEY_\($0)", value: "v", storage: .sensitive, targets: [.production], customEnvironmentIDs: [])
		}
		let results = try await client(route).create(writes, projectID: "prj_1", teamID: nil).get()
		#expect(results.count == writes.count)
		#expect(results.values.filter { if case .success = $0 { true } else { false } }.count == VercelClient.createBatchSize)
		#expect(results["KEY_\(VercelClient.createBatchSize)"] == .failure(.invalidResponse))
	}

	@Test("a page of more projects than asked for, or a listing past its byte budget or deadline, fails")
	func boundsProjectListing() async throws {
		let oversized = PlatformHTTPStub.platform { _ in
			.json(200, ["projects": (0...VercelClient.projectPageSize).map { ["id": "prj_\($0)", "name": "p\($0)", "accountId": "team_acme"] },
				"pagination": ["next": NSNull()]])
		}
		#expect(await client(oversized).projects(teamID: "team_acme", ownerID: "team_acme") == .failure(.invalidResponse))
		let endless = PlatformHTTPStub.platform { request in
			let page = Int(request.query["from"] ?? "0") ?? 0
			return .json(200, ["projects": [["id": "prj_\(page)", "name": String(repeating: "n", count: 400), "accountId": "team_acme"]],
				"pagination": ["next": page + 1]])
		}
		let budget = VercelClient(token: "vca_secret", baseURL: endless.baseURL, session: endless.session,
			limits: .init(projectBytes: 4_000, projectDeadline: .seconds(60)))
		#expect(await budget.projects(teamID: "team_acme", ownerID: "team_acme") == .failure(.invalidResponse))
		#expect(endless.requests.count < 20)
		let late = VercelClient(token: "vca_secret", baseURL: endless.baseURL, session: endless.session,
			limits: .init(projectBytes: 1_000_000, projectDeadline: .zero))
		let before = endless.requests.count
		#expect(await late.projects(teamID: "team_acme", ownerID: "team_acme") == .failure(.invalidResponse))
		#expect(endless.requests.count - before == 1)
	}

	@Test("a project another account owns fails the listing")
	func refusesForeignProjects() async throws {
		let route = PlatformHTTPStub.platform { _ in
			.json(200, ["projects": [["id": "prj_1", "name": "api", "accountId": "team_acme"], ["id": "prj_2", "name": "web", "accountId": "team_other"]],
				"pagination": ["next": NSNull()]])
		}
		#expect(await client(route).projects(teamID: "team_acme", ownerID: "team_acme") == .failure(.invalidResponse))
	}

	@Test("a variable reads as a Secret unless Vercel says it's Config and its type is readable")
	func secretUnlessKnownReadable() async throws {
		let route = PlatformHTTPStub.platform { _ in
			.json(200, ["envs": [
				["id": "env_1", "key": "FUTURE", "type": "encrypted", "visibility": "future-mode", "target": ["production"]],
				["id": "env_2", "key": "CONTRADICTORY", "type": "sensitive", "visibility": "config", "target": ["production"]],
				["id": "env_3", "key": "LEGACY", "type": "encrypted", "target": ["production"]],
				["id": "env_4", "key": "CONFIG", "type": "encrypted", "visibility": "config", "target": ["production"]],
				["id": "env_5", "key": "SECRET", "type": "encrypted", "visibility": "secret", "target": ["production"]],
			]])
		}
		let variables = try await client(route).variables(projectID: "prj_1", teamID: nil).get().variables
		let secret = Dictionary(uniqueKeysWithValues: variables.map { ($0.key, $0.isSecret) })
		#expect(secret == ["FUTURE": true, "CONTRADICTORY": true, "LEGACY": false, "CONFIG": false, "SECRET": true])
	}

	@Test("a refusal shows Vercel's error code, never its message, which could echo what was sent")
	func refusalShowsCodeOnly() async throws {
		let route = PlatformHTTPStub.platform { _ in
			.json(400, ["error": ["code": "bad_value", "message": "invalid: s3cret-value for vca_secret \u{202E}"]])
		}
		let result = await client(route).replace("env_1", key: "API", value: "s3cret-value", storage: .sensitive, projectID: "prj_1", teamID: nil)
		guard case .failure(let error) = result else { Issue.record("Not refused"); return }
		let shown = VercelPublishing.message(error)
		#expect(shown == "Vercel refused it (bad_value).")
		let odd = PlatformHTTPStub.platform { _ in .json(409, ["error": ["code": "leak: s3cret-value", "message": "x"]]) }
		guard case .failure(let other) = await client(odd).replace("env_1", key: "API", value: "s3cret-value", storage: .sensitive, projectID: "prj_1", teamID: nil) else {
			Issue.record("Not refused"); return
		}
		#expect(!VercelPublishing.message(other).contains("s3cret-value"))
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
		let projects = try await client(route).projects(teamID: "team_acme", ownerID: "team_acme").get()
		#expect(projects.map(\.id) == ["prj_1", "prj_2", "prj_3"])
		#expect(route.requests.allSatisfy { $0.query["limit"] == String(VercelClient.projectPageSize) })
	}

	@Test("a cursor that repeats would loop forever, so it's refused")
	func refusesRepeatingCursor() async {
		let route = PlatformHTTPStub.platform { _ in
			.json(200, ["projects": [["id": "prj_1", "name": "api", "accountId": "team_acme"]], "pagination": ["count": 1, "next": "same"]])
		}
		#expect(await client(route).projects(teamID: nil, ownerID: "team_acme") == .failure(.invalidResponse))
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

	@Test("creating sends each key, value, protection and target exactly, and returns each key's own result")
	func creates() async throws {
		let value = "line one\nline \"two\" ✓"
		let route = PlatformHTTPStub.platform { _ in
			.json(201, [
				"created": [["id": "env_new", "key": "API_TOKEN", "type": "sensitive", "target": ["production"], "value": ""]],
				"failed": [["error": ["code": "ENV_ALREADY_EXISTS", "message": "The variable already exists.\u{0007}", "key": "TAKEN"]]],
			])
		}
		let writes = [
			VercelVariableWrite(key: "API_TOKEN", value: value, storage: .sensitive, targets: [.production], customEnvironmentIDs: []),
			VercelVariableWrite(key: "TAKEN", value: "", storage: .encrypted, targets: [], customEnvironmentIDs: ["env_custom1"]),
		]
		let results = try await client(route).create(writes, projectID: "prj_1", teamID: "team_acme").get()
		#expect(try results["API_TOKEN"]?.get().id == "env_new")
		#expect(results["TAKEN"] == .failure(.rejected(code: "ENV_ALREADY_EXISTS")))
		let request = try #require(route.requests.first)
		#expect(request.method == "POST" && request.url.path() == "/v10/projects/prj_1/env" && request.query["upsert"] == nil)
		let sent = try #require(try JSONSerialization.jsonObject(with: request.body) as? [[String: Any]])
		#expect(sent.count == 2)
		#expect(sent[0]["value"] as? String == value && sent[0]["type"] as? String == "sensitive")
		#expect(sent[0]["target"] as? [String] == ["production"] && sent[0]["customEnvironmentIds"] == nil)
		#expect(sent[1]["customEnvironmentIds"] as? [String] == ["env_custom1"] && sent[1]["target"] == nil)
	}

	@Test("many variables go in batches, and a key Vercel neither created nor refused isn't reported as created")
	func createsInBatches() async throws {
		let route = PlatformHTTPStub.platform { request in
			let sent = (try? JSONSerialization.jsonObject(with: request.body) as? [[String: Any]]) ?? []
			let created = sent.compactMap { $0["key"] as? String }.filter { $0 != "KEY_7" }.map { key in
				["id": "env_\(key)", "key": key, "type": "sensitive", "target": ["preview"], "value": ""] as [String: Any]
			}
			return .json(201, ["created": created, "failed": []])
		}
		let writes = (0..<(VercelClient.createBatchSize + 5)).map {
			VercelVariableWrite(key: "KEY_\($0)", value: "v", storage: .sensitive, targets: [.preview], customEnvironmentIDs: [])
		}
		let results = try await client(route).create(writes, projectID: "prj_1", teamID: nil).get()
		#expect(route.requests.count == 2)
		#expect(results.count == writes.count)
		#expect(results["KEY_7"] == .failure(.invalidResponse))
		#expect(results.filter { (try? $0.value.get()) != nil }.count == writes.count - 1)
	}

	@Test("a refusal of the whole request comes back once, before anything is created")
	func createRefused() async {
		let route = PlatformHTTPStub.platform { _ in .json(401, ["error": ["message": "Not authorized"]]) }
		let write = VercelVariableWrite(key: "A", value: "v", storage: .sensitive, targets: [.preview], customEnvironmentIDs: [])
		#expect(await client(route).create([write], projectID: "prj_1", teamID: nil) == .failure(.unauthorized))
	}

	@Test("Vercel's Config or Secret label decides, a contradictory one reads as a Secret, and older variables fall back to their type")
	func readsVisibility() async throws {
		let route = PlatformHTTPStub.platform { _ in
			.json(200, ["envs": [
				["id": "env_1", "key": "A", "type": "encrypted", "visibility": "secret", "target": ["preview"], "value": ""],
				["id": "env_2", "key": "B", "type": "sensitive", "visibility": "config", "target": ["preview"], "value": ""],
				["id": "env_3", "key": "C", "type": "sensitive", "target": ["preview"], "value": ""],
				["id": "env_4", "key": "D", "type": "encrypted", "target": ["preview"], "value": "x"],
			]])
		}
		let list = try await client(route).variables(projectID: "prj_1", teamID: nil).get()
		#expect(list.variables.map(\.isSecret) == [true, true, true, false])
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
		let updated = try await client(route).replace("env_1", key: "API_TOKEN", value: "s3cret", storage: .sensitive, projectID: "prj_1", teamID: nil).get()
		#expect(updated.kind == .sensitive)
		#expect(route.requests.last?.json?["visibility"] as? String == "secret")
		_ = try await client(route).replace("env_1", key: "API_TOKEN", value: "info", storage: .encrypted, projectID: "prj_1", teamID: nil).get()
		#expect(route.requests.last?.json?["visibility"] as? String == "config")
	}

	@Test("new variables name their type and visibility as Vercel requires")
	func createStatesVisibility() async throws {
		let route = PlatformHTTPStub.platform { request in
			Self.enforcingVisibility(request) {
				.json(201, ["created": [
					["id": "env_secret", "key": "API_TOKEN", "type": "sensitive", "target": ["production"], "value": ""],
					["id": "env_config", "key": "LOG_LEVEL", "type": "encrypted", "target": ["production"], "value": ""],
				], "failed": []])
			}
		}
		let writes = [
			VercelVariableWrite(key: "API_TOKEN", value: "s3cret", storage: .sensitive, targets: [.production], customEnvironmentIDs: []),
			VercelVariableWrite(key: "LOG_LEVEL", value: "info", storage: .encrypted, targets: [.production], customEnvironmentIDs: []),
		]
		let results = try await client(route).create(writes, projectID: "prj_1", teamID: nil).get()
		#expect(try results["API_TOKEN"]?.get().id == "env_secret" && results["LOG_LEVEL"]?.get().id == "env_config")
		let request = try #require(route.requests.last)
		let sent = try #require(try JSONSerialization.jsonObject(with: request.body) as? [[String: Any]])
		#expect(sent.map { $0["visibility"] as? String } == ["secret", "config"])
	}

	@Test("replacing changes only the value and protection of that variable")
	func replaces() async throws {
		let route = PlatformHTTPStub.platform { _ in
			.json(200, ["id": "env_1", "key": "API_TOKEN", "type": "sensitive", "target": ["production", "preview"], "value": ""])
		}
		let updated = try await client(route).replace("env_1", key: "API_TOKEN", value: "", storage: .sensitive, projectID: "prj_1", teamID: nil).get()
		#expect(updated.targets == [.production, .preview])
		#expect(await client(route).replace("env_1", key: "OTHER", value: "", storage: .sensitive, projectID: "prj_1", teamID: nil) == .failure(.invalidResponse),
			"An answer naming another key isn't taken for this variable")
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
				.rejected(code: "ENV_ALREADY_EXISTS")),
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
		let delegate = RedirectRefusingHTTPDelegate()
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
