import Foundation
import Testing
@testable import LPMVault

struct CoolifyInstanceTests {
	private func origin(_ text: String) -> String? {
		try? CoolifyInstance.parse(text).get().origin
	}

	@Test("an address without a scheme uses https, and is kept lowercased without a default port or a path")
	func canonicalizes() {
		#expect(origin("coolify.example.com") == "https://coolify.example.com")
		#expect(origin("  HTTPS://Coolify.Example.COM/  ") == "https://coolify.example.com")
		#expect(origin("https://coolify.example.com:443") == "https://coolify.example.com")
		#expect(origin("https://coolify.example.com:8443") == "https://coolify.example.com:8443")
		#expect(origin("https://coolify.example.com/api/v1") == "https://coolify.example.com", "Coolify's documentation shows the API's own address")
		#expect(origin("https://app.coolify.io/api/") == "https://app.coolify.io")
		#expect(origin("https://203.0.113.7:8000") == "https://203.0.113.7:8000")
	}

	@Test("plain HTTP is accepted only to this Mac itself, as through an SSH tunnel")
	func refusesPlainHTTPElsewhere() {
		#expect(CoolifyInstance.parse("http://coolify.example.com") == .failure(.insecure))
		#expect(CoolifyInstance.parse("http://203.0.113.7:8000") == .failure(.insecure))
		#expect(CoolifyInstance.parse("http://192.168.1.20:8000") == .failure(.insecure))
		#expect(origin("http://localhost:8000") == "http://localhost:8000")
		#expect(origin("http://127.0.0.1:8000") == "http://127.0.0.1:8000")
		#expect(origin("http://[::1]:8000") == "http://[::1]:8000")
		#expect(origin("http://localhost:80") == "http://localhost")
	}

	@Test("an address with anything besides a host and port is refused")
	func refusesOtherParts() {
		for text in [
			"", "   ", "https://", "ftp://coolify.example.com", "https://user:pass@coolify.example.com",
			"https://coolify.example.com/projects", "https://coolify.example.com/?x=1", "https://coolify.example.com/#top",
			"https://coolify example.com", "https://-coolify.example.com", "https://coolify..example.com",
			"https://coolify.example.com:0", "https://coolify.example.com:70000", "https://[fe80::1%25en0]",
		] {
			#expect(CoolifyInstance.parse(text) == .failure(.invalid), "\(text)")
		}
	}

	@Test("a stored origin reads back only in its canonical form")
	func storedOrigin() {
		#expect(CoolifyInstance(origin: "https://coolify.example.com")?.address == "coolify.example.com")
		#expect(CoolifyInstance(origin: "http://localhost:8000")?.address == "localhost:8000")
		#expect(CoolifyInstance(origin: "coolify.example.com") == nil)
		#expect(CoolifyInstance(origin: "https://Coolify.example.com") == nil)
		#expect(CoolifyInstance(origin: "https://coolify.example.com/") == nil)
	}

	@Test("API requests go under /api/v1 on the instance")
	func apiURL() throws {
		let instance = try CoolifyInstance.parse("https://coolify.example.com:8443").get()
		#expect(instance.url(["teams", "current"])?.absoluteString == "https://coolify.example.com:8443/api/v1/teams/current")
	}
}

struct CoolifyClientTests {
	private func client(_ route: PlatformHTTPStub.Route, token: String = "3|coolify-token") throws -> CoolifyClient {
		CoolifyClient(instance: try CoolifyInstance.parse(route.baseURL.absoluteString).get(), token: token, session: route.session)
	}

	@Test("the team comes from the token, which every request carries, asking for JSON")
	func readsTeam() async throws {
		let route = PlatformHTTPStub.coolify { _ in .json(200, ["id": 0, "name": "Root Team", "description": NSNull(), "personal_team": true]) }
		#expect(try await client(route).team().get() == CoolifyTeam(id: "0", name: "Root Team"))
		let request = try #require(route.requests.first)
		#expect(request.url.path() == "/api/v1/team")
		#expect(request.header("Authorization") == "Bearer 3|coolify-token")
		#expect(request.header("Accept") == "application/json")
	}

	@Test("before Coolify 4.3 the team is read from its older path")
	func olderTeamPath() async throws {
		let route = PlatformHTTPStub.coolify { request in
			request.url.path() == "/api/v1/teams/current"
				? .json(200, ["id": 7, "name": "Northwind"])
				: .json(404, ["message": "Not found.", "docs": "https://coolify.io/docs"])
		}
		#expect(try await client(route).team().get() == CoolifyTeam(id: "7", name: "Northwind"))
		#expect(route.requests.map { $0.url.path() } == ["/api/v1/team", "/api/v1/teams/current"])
	}

	@Test("Coolify's refusals are told apart by their messages")
	func refusals() async throws {
		let cases: [(PlatformHTTPStub.Reply, CoolifyAPIError)] = [
			(.json(401, ["message": "Unauthenticated."]), .unauthorized),
			(.json(400, ["message": "Invalid token.", "docs": "https://coolify.io/docs/api-reference/authorization"]), .unauthorized),
			(.json(403, ["success": true, "message": "API is disabled."]), .apiDisabled),
			(.json(403, ["success": true, "message": "You are not allowed to access the API."]), .addressNotAllowed),
			(.json(403, ["message": "Missing required permissions: read"]), .missingPermission),
			(.json(403, ["message": "This API token has permissions (write) that exceed your current role as a team member. Members are restricted to read-only API access."]), .roleTooLow),
			(.json(403, ["message": "Missing required team role."]), .roleTooLow),
			(.json(403, ["message": "This action is unauthorized."]), .forbidden),
			(.json(429, ["message": "Too Many Attempts."]), .rateLimited),
			(.json(422, ["message": "Validation failed.", "errors": ["key": ["Bad"]]]), .rejected("Validation failed. (key)")),
			(.json(302, [:], headers: ["Location": "https://evil.example/login"]), .redirected),
			(.json(503, ["message": "Down"]), .server(503)),
			(.json(200, ["id": "not a number", "name": "Root"]), .invalidResponse),
			(.json(200, ["id": 3, "name": "  "]), .invalidResponse),
		]
		for (reply, expected) in cases {
			let route = PlatformHTTPStub.coolify { _ in reply }
			#expect(try await client(route).team() == .failure(expected), "\(reply.status) → \(expected)")
		}
	}

	@Test("a team name's direction controls are escaped, so it can't disguise itself")
	func escapesTeamName() async throws {
		let route = PlatformHTTPStub.coolify { _ in .json(200, ["id": 0, "name": "Root\u{202E}maeT \u{2067}x\u{2069}"]) }
		#expect(try await client(route).team().get().name == #"Root\u{202e}maeT \u{2067}x\u{2069}"#)
	}

	@Test("a refusal shows only Coolify's own fixed messages and field names, never text that could echo what was sent")
	func rejectionText() async throws {
		let echo = PlatformHTTPStub.coolify { _ in
			.json(422, ["message": "Value s3cret-value for 3|coolify-token is invalid\u{202E}", "errors": ["value": ["s3cret-value"], "s3cret-value": ["x"]]])
		}
		#expect(try await client(echo).team() == .failure(.rejected("(value)")))
		let known = PlatformHTTPStub.coolify { _ in .json(422, ["message": "Validation failed.", "errors": ["key": ["The key format is invalid."], "is_preview": ["x"]]]) }
		#expect(try await client(known).team() == .failure(.rejected("Validation failed. (is_preview, key)")))
	}

	@Test("clients made without a session share one, so a client leaves no session behind")
	func sharesSession() throws {
		let instance = try CoolifyInstance.parse("coolify.example.com").get()
		let first = CoolifyClient(instance: instance, token: "1|a")
		let second = CoolifyClient(instance: instance, token: "2|b")
		#expect(first.session === second.session && first.session === CoolifyClient.sharedSession)
		#expect(VercelClient(token: "a").session === VercelClient(token: "b").session)
		let route = PlatformHTTPStub.coolify { _ in .json(200, [:]) }
		#expect(CoolifyClient(instance: instance, token: "1|a", session: route.session).session === route.session)
	}

	@Test("an address that isn't Coolify answers not found on both paths")
	func notCoolify() async throws {
		let route = PlatformHTTPStub.coolify { _ in PlatformHTTPStub.Reply(status: 404, headers: ["Content-Type": "text/html"], body: Data("<html>".utf8)) }
		#expect(try await client(route).team() == .failure(.notFound))
		#expect(route.requests.count == 2)
	}

	@Test("a token that isn't printable ASCII is never sent")
	func refusesInvalidToken() async throws {
		let route = PlatformHTTPStub.coolify { _ in .json(200, ["id": 0, "name": "Root"]) }
		#expect(try await client(route, token: "has space").team() == .failure(.unauthorized))
		#expect(try await client(route, token: "").team() == .failure(.unauthorized))
		#expect(route.requests.isEmpty)
	}

	@Test("an unreachable instance is a transport failure")
	func unreachable() async throws {
		let route = PlatformHTTPStub.coolify { _ in .json(200, [:]) }
		let elsewhere = CoolifyClient(
			instance: try CoolifyInstance.parse("https://coolify-unregistered.test").get(), token: "1|t", session: route.session)
		#expect(await elsewhere.team() == .failure(.transport))
	}

	@Test("resources come with the project and environment holding them, read four projects at a time at most")
	func listsResources() async throws {
		let route = PlatformHTTPStub.coolify { request in
			switch request.url.path() {
			case "/api/v1/projects":
				return .json(200, [["id": 1, "uuid": "proj-store", "name": "Storefront", "description": NSNull()], ["id": 2, "uuid": "proj-ops", "name": "Ops"]])
			case "/api/v1/projects/proj-store":
				return .json(200, ["id": 1, "uuid": "proj-store", "name": "Storefront", "environments": [["id": 10, "name": "production", "uuid": "env-1"], ["id": 11, "name": "staging"]]])
			case "/api/v1/projects/proj-ops":
				return .json(200, ["id": 2, "uuid": "proj-ops", "name": "Ops", "environments": [["id": 20, "name": "production"]]])
			case "/api/v1/applications":
				return .json(200, [
					["uuid": "app-api", "name": "api", "environment_id": 10, "build_pack": "dockercompose", "docker_compose_raw": String(repeating: "x", count: 4_096)],
					["uuid": "app-web", "name": "web", "environment_id": 11, "build_pack": "nixpacks"],
				])
			case "/api/v1/services":
				return .json(200, [["uuid": "svc-db", "name": "db", "environment_id": 20, "build_pack": "ignored"], ["uuid": "svc-orphan", "name": "orphan", "environment_id": 99]])
			default:
				return .json(404, ["message": "Not found."])
			}
		}
		let resources = try await client(route).resources().get()
		#expect(resources == [
			CoolifyResource(kind: .application, id: "app-api", name: "api", projectName: "Storefront", environmentName: "production", buildPack: "dockercompose"),
			CoolifyResource(kind: .application, id: "app-web", name: "web", projectName: "Storefront", environmentName: "staging", buildPack: "nixpacks"),
			CoolifyResource(kind: .service, id: "svc-db", name: "db", projectName: "Ops", environmentName: "production", buildPack: nil),
			CoolifyResource(kind: .service, id: "svc-orphan", name: "orphan", projectName: nil, environmentName: nil, buildPack: nil),
		])
		#expect(CoolifyClient.projectConcurrency == 4)
	}

	@Test("a project UUID that could change the request's path fails the listing before it's used")
	func refusesUnsafeProject() async throws {
		let route = PlatformHTTPStub.coolify { request in
			request.url.path() == "/api/v1/projects" ? .json(200, [["id": 1, "uuid": "../teams", "name": "x"]]) : .json(200, [])
		}
		#expect(try await client(route).resources() == .failure(.invalidResponse))
		#expect(!route.requests.contains { $0.url.path().contains("teams") })
	}

	@Test("variables are read without their values, whether Coolify sends flags as booleans or numbers")
	func readsVariables() async throws {
		let route = PlatformHTTPStub.coolify { _ in
			.json(200, [
				["uuid": "env-1", "key": "API_TOKEN", "value": "s3cret-if-sensitive", "real_value": "s3cret-if-sensitive",
					"is_preview": false, "is_shown_once": true, "updated_at": "2026-10-14T12:34:56.123456Z"],
				["uuid": "env-2", "key": "API_TOKEN", "is_preview": 1, "is_shown_once": 0, "updated_at": "2026-10-14T12:34:56Z"],
				["uuid": "env-3", "key": "LOG_LEVEL", "is_preview": NSNull(), "updated_at": NSNull()],
			])
		}
		let variables = try await client(route).variables(of: .application, id: "app-api").get()
		#expect(route.requests.first?.url.path() == "/api/v1/applications/app-api/envs")
		#expect(variables.map(\.id) == ["env-1", "env-2", "env-3"])
		#expect(variables[0].isLocked && !variables[0].isPreview && variables[1].isPreview && !variables[1].isLocked)
		#expect(variables[0].updatedAt == Date(timeIntervalSince1970: 1_791_981_296.123456))
		#expect(variables[2].updatedAt == nil && !variables[2].isPreview)
		#expect(!String(describing: variables).contains("s3cret"))

		let services = PlatformHTTPStub.coolify { _ in .json(200, [["uuid": "env-1", "key": "A", "is_shown_once": 2]]) }
		#expect(try await client(services).variables(of: .service, id: "svc-db") == .failure(.invalidResponse))
		#expect(services.requests.first?.url.path() == "/api/v1/services/svc-db/envs")
	}

	@Test("Laravel's timestamps read to the microsecond, in UTC; anything else isn't a time")
	func timestamps() {
		#expect(CoolifyClient.timestamp("2026-10-14T12:34:56.000000Z") == Date(timeIntervalSince1970: 1_791_981_296))
		#expect(CoolifyClient.timestamp("2026-10-14 12:34:56+00:00") == Date(timeIntervalSince1970: 1_791_981_296))
		#expect(CoolifyClient.timestamp("2026-10-14T12:34:56.5Z") == Date(timeIntervalSince1970: 1_791_981_296.5))
		for text in ["2026-10-14T12:34:56", "2026-02-30T00:00:00Z", "2026-10-14T12:34:56.Z", "2026-10-14T12:34:56+02:00", "yesterday"] {
			#expect(CoolifyClient.timestamp(text) == nil, "\(text)")
		}
	}

	@Test("a write sends every flag Coolify would otherwise reset, keeps values literal, and names preview deployments only for an application")
	func writes() async throws {
		let route = PlatformHTTPStub.coolify { request in
			switch (request.method, request.url.path()) {
			case ("POST", "/api/v1/applications/app-api/envs"): return .json(201, ["uuid": "env-new"])
			case ("POST", "/api/v1/services/svc-db/envs"):
				return .json(201, ["uuid": "env-svc", "key": "TOKEN", "is_preview": false, "is_shown_once": true, "updated_at": "2026-10-14T12:00:00.000000Z"])
			case ("PATCH", "/api/v1/applications/app-api/envs"):
				return .json(201, ["uuid": "env-old", "key": "TOKEN", "is_preview": true, "is_shown_once": false, "updated_at": "2026-10-14T12:00:01.000000Z"])
			case ("DELETE", "/api/v1/applications/app-api/envs/env-new"): return .json(200, ["message": "Environment variable deleted."])
			default: return .json(404, ["message": "Not found."])
			}
		}
		let client = try client(route)
		let secret = CoolifyVariableWrite(key: "TOKEN", value: "line1\nline2", isPreview: false, isLocked: true)
		#expect(try await client.create(secret, in: .application, id: "app-api").get() == "env-new")
		let body = try #require(route.requests.last?.json)
		#expect(body as NSDictionary == ["key": "TOKEN", "value": "line1\nline2", "is_literal": true, "is_multiline": true, "is_shown_once": true, "is_preview": false] as NSDictionary)
		#expect(route.requests.last?.header("Content-Type") == "application/json")

		#expect(try await client.create(secret, in: .service, id: "svc-db").get() == "env-svc")
		#expect(route.requests.last?.json?["is_preview"] == nil, "A service has no preview deployments")

		let replace = CoolifyVariableWrite(key: "TOKEN", value: "plain", isPreview: true, isLocked: false)
		let updated = try await client.update(replace, in: .application, id: "app-api").get()
		#expect(updated.id == "env-old" && updated.isPreview && route.requests.last?.json?["is_multiline"] as? Bool == false)
		#expect(await client.update(CoolifyVariableWrite(key: "OTHER", value: "x", isPreview: true, isLocked: false), in: .application, id: "app-api")
			== .failure(.invalidResponse), "An answer about another variable isn't taken for this one")

		try await client.delete("env-new", in: .application, id: "app-api").get()
		#expect(await client.create(CoolifyVariableWrite(key: "A", value: "x", isPreview: true, isLocked: false), in: .service, id: "svc-db")
			== .failure(.invalidResponse), "A preview write to a service is never sent")
		guard case .failure(.invalidResponse) = await client.delete("../x", in: .application, id: "app-api") else {
			Issue.record("An unsafe variable ID was sent")
			return
		}
		#expect(route.requests.count == 5)
	}

	@Test("an existing key is a conflict, and the application's build pack is read from the application")
	func conflictAndBuildPack() async throws {
		let route = PlatformHTTPStub.coolify { request in
			request.method == "POST"
				? .json(409, ["message": "Environment variable already exists. Use PATCH request to update it."])
				: .json(200, ["uuid": "app-api", "name": "api", "build_pack": "dockercompose"])
		}
		let client = try client(route)
		#expect(await client.create(CoolifyVariableWrite(key: "A", value: "x", isPreview: false, isLocked: false), in: .application, id: "app-api") == .failure(.conflict))
		#expect(try await client.buildPack(ofApplication: "app-api").get() == "dockercompose")
		#expect(route.requests.last?.url.path() == "/api/v1/applications/app-api")
	}

	@Test("the client never prints its token")
	func redacts() throws {
		let client = CoolifyClient(instance: try CoolifyInstance.parse("coolify.example.com").get(), token: "3|s3cret-token")
		let connection = CoolifyConnection(
			instance: try CoolifyInstance.parse("coolify.example.com").get(), team: CoolifyTeam(id: "0", name: "Root"), token: "3|s3cret-token")
		let write = CoolifyVariableWrite(key: "API", value: "s3cret-value", isPreview: false, isLocked: true)
		var dumped = ""
		dump(client, to: &dumped)
		dump(connection, to: &dumped)
		dump(write, to: &dumped)
		for text in [client.description, String(reflecting: client), connection.description, String(reflecting: connection),
			write.description, String(reflecting: write), dumped] {
			#expect(!text.contains("s3cret-token") && !text.contains("s3cret-value"))
		}
	}
}

struct CoolifyConnectorTests {
	private final class Recorder: @unchecked Sendable {
		private let lock = NSLock()
		private var calls: [(origin: String, token: String)] = []
		var recorded: [(origin: String, token: String)] { lock.withLock { calls } }
		func append(_ origin: String, _ token: String) { lock.withLock { calls.append((origin, token)) } }
	}

	private func connector(_ answer: Result<CoolifyTeam, CoolifyAPIError>, recorder: Recorder = Recorder()) -> CoolifyConnector {
		CoolifyConnector { instance, token in
			recorder.append(instance.origin, token)
			let api = FakeCoolifyAPI()
			api.team = answer
			return api
		}
	}

	@Test("the address and token are checked with the instance, and the token is kept without surrounding space")
	func connects() async throws {
		let recorder = Recorder()
		let team = CoolifyTeam(id: "0", name: "Root Team")
		let connected = try await connector(.success(team), recorder: recorder)
			.connect(address: "coolify.example.com", token: "  3|abc\n").get()
		#expect(connected.instance.origin == "https://coolify.example.com" && connected.team == team && connected.token == "3|abc")
		#expect(recorder.recorded.map(\.token) == ["3|abc"])
	}

	@Test("a bad address or token is refused before anything is sent")
	func refusesInput() async {
		let recorder = Recorder()
		let connector = connector(.success(CoolifyTeam(id: "0", name: "Root")), recorder: recorder)
		#expect(await connector.connect(address: "coolify.example.com/projects", token: "3|abc") == .failure(.invalidAddress))
		#expect(await connector.connect(address: "http://coolify.example.com", token: "3|abc") == .failure(.insecureAddress))
		#expect(await connector.connect(address: "coolify.example.com", token: " \n") == .failure(.invalidToken))
		#expect(await connector.connect(address: "coolify.example.com", token: "3|a b") == .failure(.invalidToken))
		#expect(recorder.recorded.isEmpty)
	}

	@Test("each refusal says what to change in Coolify")
	func explainsRefusals() async {
		let cases: [(CoolifyAPIError, CoolifyConnectError)] = [
			(.unauthorized, .unauthorized), (.apiDisabled, .apiDisabled), (.addressNotAllowed, .addressNotAllowed),
			(.missingPermission, .missingPermission), (.roleTooLow, .roleTooLow), (.notFound, .notCoolify),
			(.redirected, .redirected), (.untrustedCertificate, .untrustedCertificate), (.transport, .unreachable),
			(.server(502), .notCoolify), (.invalidResponse, .invalidResponse),
		]
		for (error, expected) in cases {
			#expect(await connector(.failure(error)).connect(address: "coolify.example.com", token: "3|abc") == .failure(expected))
		}
		#expect(CoolifyConnectError.apiDisabled.message.contains("Settings → Advanced"))
		#expect(CoolifyConnectError.insecureAddress.message.contains("SSH tunnel"))
	}
}
