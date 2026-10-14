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
			(.json(422, ["message": "Validation failed.", "errors": ["key": ["Bad"]]]), .rejected("Validation failed.")),
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

	@Test("the client never prints its token")
	func redacts() throws {
		let client = CoolifyClient(instance: try CoolifyInstance.parse("coolify.example.com").get(), token: "3|s3cret-token")
		let connection = CoolifyConnection(
			instance: try CoolifyInstance.parse("coolify.example.com").get(), team: CoolifyTeam(id: "0", name: "Root"), token: "3|s3cret-token")
		var dumped = ""
		dump(client, to: &dumped)
		dump(connection, to: &dumped)
		for text in [client.description, String(reflecting: client), connection.description, String(reflecting: connection), dumped] {
			#expect(!text.contains("s3cret-token"))
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

	private struct FakeClient: CoolifyClientProtocol {
		let answer: Result<CoolifyTeam, CoolifyAPIError>
		func team() async -> Result<CoolifyTeam, CoolifyAPIError> { answer }
	}

	private func connector(_ answer: Result<CoolifyTeam, CoolifyAPIError>, recorder: Recorder = Recorder()) -> CoolifyConnector {
		CoolifyConnector { instance, token in
			recorder.append(instance.origin, token)
			return FakeClient(answer: answer)
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
