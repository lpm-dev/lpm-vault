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
