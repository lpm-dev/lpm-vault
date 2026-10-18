import Foundation
import Testing

@testable import LPMVault

/// Answers in the shapes Cloudflare gave a throwaway Worker on 2026-10-18.
enum CloudflareFixture {
	static let account = "832433f01fefba3b0c9edc8bb3749b87"
	static let workerID = "b59eefeb67c046049345364f3688f8f4"
	static let workerName = "lpm-vault-probe"
	static let versionID = "c9d3ffd6-9e5a-4988-875b-f09b4c5220e8"
	static let deploymentID = "a149c365-7e42-47e1-91c0-248e74705985"

	static func envelope(_ result: Any, info: [String: Any]? = nil) -> [String: Any] {
		var envelope: [String: Any] = ["result": result, "success": true, "errors": [], "messages": []]
		if let info { envelope["result_info"] = info }
		return envelope
	}

	static func refusal(_ codes: [Int], message: String = "Refused") -> [String: Any] {
		["result": NSNull(), "success": false, "errors": codes.map { ["code": $0, "message": message] }, "messages": []]
	}

	static func worker(id: String = workerID, name: String = workerName) -> [String: Any] {
		[
			"id": id, "name": name, "tags": [], "logpush": false, "created_on": "2026-10-18T04:09:04.970287Z",
			"updated_on": "2026-10-18T04:14:53.727668Z", "deployed_on": "2026-10-18T04:18:12.049592Z",
		]
	}

	static func version(
		id: String = versionID,
		number: Int = 25,
		createdOn: String = "2026-10-18T04:18:12.049592Z",
		source: String = "api",
		trigger: String = "secret",
		bindings: [[String: Any]]
	) -> [String: Any] {
		[
			"id": id, "number": number, "startup_time_ms": 1, "compatibility_date": "2026-10-01", "main_module": "index.js",
			"annotations": ["workers/triggered_by": trigger], "usage_model": "standard", "urls": [], "source": source,
			"created_on": createdOn, "bindings": bindings, "author_email": "someone@example.com",
		]
	}

	static func deployment(
		id: String = deploymentID,
		createdOn: String = "2026-10-18T04:18:12.049592Z",
		versions: [(String, Double)] = [(versionID, 100)]
	) -> [String: Any] {
		[
			"id": id, "source": "api", "strategy": "percentage", "author_email": "someone@example.com",
			"annotations": ["workers/triggered_by": "secret"], "created_on": createdOn,
			"versions": versions.map { ["version_id": $0.0, "percentage": $0.1] },
		]
	}

	static var bindings: [[String: Any]] {[
		["name": "API_TOKEN", "type": "secret_text"],
		["name": "DATABASE_URL", "type": "secret_text"],
		["name": "CLASH_VAR", "type": "plain_text", "text": "plain"],
		["name": "JSON_VAR", "type": "json", "json": ["a": 1]],
		["name": "SIGNING_KEY", "type": "secret_key", "format": "raw", "algorithm": ["name": "HMAC"], "usages": ["sign"]],
		["name": "CACHE", "type": "kv_namespace", "namespace_id": "0123"],
	]}
}

@Suite("Cloudflare's API")
struct CloudflareClientTests {
	private typealias Fixture = CloudflareFixture
	private let date = "Sun, 18 Oct 2026 04:18:12 GMT"

	private func client(_ route: PlatformHTTPStub.Route) -> CloudflareClient {
		CloudflareClient(token: "cf_token", baseURL: route.baseURL.appending(path: "client/v4"), session: route.session)
	}

	@Test("a Worker is read by its ID or script name, each path segment escaped, with the token and the client named")
	func readsWorker() async throws {
		let route = PlatformHTTPStub.platform { _ in .json(200, Fixture.envelope(Fixture.worker())) }
		let worker = try await client(route).worker(Fixture.workerID, in: Fixture.account).get()
		#expect(worker == CloudflareWorker(id: Fixture.workerID, name: Fixture.workerName))
		let request = try #require(route.requests.first)
		#expect(request.method == "GET")
		#expect(request.url.path() == "/client/v4/accounts/\(Fixture.account)/workers/workers/\(Fixture.workerID)")
		#expect(request.header("Authorization") == "Bearer cf_token")
		#expect(request.header("Accept") == "application/json")
		#expect(request.header("User-Agent")?.hasPrefix("LPM-Vault") == true)
		_ = try await client(route).worker(Fixture.workerName, in: Fixture.account).get()
		#expect(route.requests.last?.url.path() == "/client/v4/accounts/\(Fixture.account)/workers/workers/\(Fixture.workerName)")
	}

	@Test("an account, Worker or script name Cloudflare wouldn't give is refused before anything is sent")
	func refusesMalformedNames() async {
		let route = PlatformHTTPStub.platform { _ in .json(200, Fixture.envelope(Fixture.worker())) }
		let client = client(route)
		#expect(await client.worker("../accounts", in: Fixture.account) == .failure(.invalidResponse))
		#expect(await client.worker(Fixture.workerID, in: "ACCOUNT") == .failure(.invalidResponse))
		#expect(await client.newestVersion(ofWorker: Fixture.workerName, in: Fixture.account) == .failure(.invalidResponse))
		#expect(await client.activeDeployment(ofScript: "-dash", in: Fixture.account) == .failure(.invalidResponse))
		#expect(await client.updateSecrets(["A": "1"], ofScript: "Upper", in: Fixture.account) == .failure(.invalidResponse))
		#expect(await client.updateSecrets([:], ofScript: Fixture.workerName, in: Fixture.account) == .failure(.invalidResponse))
		#expect(route.requests.isEmpty)
	}

	@Test("a Worker whose ID or name isn't one Cloudflare gives is unreadable")
	func refusesMalformedWorker() async {
		for worker in [Fixture.worker(id: "XYZ"), Fixture.worker(name: "Has Space"), ["id": Fixture.workerID]] {
			let reply = PlatformHTTPStub.Reply.json(200, Fixture.envelope(worker))
			let route = PlatformHTTPStub.platform { _ in reply }
			#expect(await client(route).worker(Fixture.workerID, in: Fixture.account) == .failure(.invalidResponse))
		}
	}

	@Test("the newest version is read by the Worker's ID, one item, with every binding by kind and its microsecond time")
	func readsNewestVersion() async throws {
		let route = PlatformHTTPStub.platform { _ in
			.json(200, Fixture.envelope([Fixture.version(bindings: Fixture.bindings)], info: ["page": 1, "per_page": 1, "count": 1, "total_count": 25]))
		}
		let version = try await client(route).newestVersion(ofWorker: Fixture.workerID, in: Fixture.account).get()
		#expect(version.id == Fixture.versionID && version.number == 25 && version.source == "api" && version.trigger == "secret")
		#expect(abs(version.createdAt.timeIntervalSince1970 - 1_792_297_092.049_592) < 0.000_01)
		#expect(PublishTimestamp.milliseconds(version.createdAt) == 1_792_297_092_050)
		#expect(version.bindings == [
			"API_TOKEN": .secretText, "DATABASE_URL": .secretText, "CLASH_VAR": .plainText, "JSON_VAR": .json,
			"SIGNING_KEY": .other, "CACHE": .other,
		])
		let request = try #require(route.requests.first)
		#expect(request.url.path() == "/client/v4/accounts/\(Fixture.account)/workers/workers/\(Fixture.workerID)/versions")
		#expect(request.query == ["page": "1", "per_page": "1"])
	}

	@Test("a version that names a binding twice, lists no bindings, or has no ID, number or time is unreadable")
	func refusesMalformedVersion() async {
		var duplicated = Fixture.bindings
		duplicated.append(["name": "API_TOKEN", "type": "plain_text"])
		var unbound = Fixture.version(bindings: [])
		unbound.removeValue(forKey: "bindings")
		let malformed: [[String: Any]] = [
			Fixture.version(bindings: duplicated), unbound, Fixture.version(id: "not-a-uuid", bindings: []),
			Fixture.version(number: 0, bindings: []), Fixture.version(createdOn: "yesterday", bindings: []),
		]
		for version in malformed {
			let reply = PlatformHTTPStub.Reply.json(200, Fixture.envelope([version]))
			let route = PlatformHTTPStub.platform { _ in reply }
			#expect(await client(route).newestVersion(ofWorker: Fixture.workerID, in: Fixture.account) == .failure(.invalidResponse))
		}
		let empty = PlatformHTTPStub.platform { _ in .json(200, Fixture.envelope([Any]())) }
		#expect(await client(empty).newestVersion(ofWorker: Fixture.workerID, in: Fixture.account) == .failure(.invalidResponse))
	}

	@Test("the active deployment is the newest Cloudflare lists, read by script name, with Cloudflare's answer time")
	func readsActiveDeployment() async throws {
		let earlier = Fixture.deployment(id: "074ee547-ac34-4008-a043-575eea94e883", createdOn: "2026-10-18T04:09:19.92407Z")
		let listed = PlatformHTTPStub.Reply.json(200, Fixture.envelope(["deployments": [Fixture.deployment(), earlier]]), headers: ["Date": date])
		let route = PlatformHTTPStub.platform { _ in listed }
		let deployment = try await client(route).activeDeployment(ofScript: Fixture.workerName, in: Fixture.account).get()
		#expect(deployment.id == Fixture.deploymentID && deployment.soleVersionID == Fixture.versionID && deployment.trigger == "secret")
		#expect(deployment.answeredAt == Date(timeIntervalSince1970: 1_792_297_092))
		#expect(route.requests.first?.url.path() == "/client/v4/accounts/\(Fixture.account)/workers/scripts/\(Fixture.workerName)/deployments")

		let split = PlatformHTTPStub.platform { _ in
			.json(200, Fixture.envelope(["deployments": [Fixture.deployment(versions: [(Fixture.versionID, 50), ("ac32cb89-8179-4b2c-a972-7568496494c9", 50)])]]))
		}
		let shared = try await client(split).activeDeployment(ofScript: Fixture.workerName, in: Fixture.account).get()
		#expect(shared.soleVersionID == nil && shared.versions.count == 2)
	}

	@Test("a deployment whose versions don't share all traffic, or repeat, is unreadable")
	func refusesMalformedDeployment() async {
		let other = "ac32cb89-8179-4b2c-a972-7568496494c9"
		let cases: [[(String, Double)]] = [
			[(Fixture.versionID, 60)], [(Fixture.versionID, 50), (Fixture.versionID, 50)], [(Fixture.versionID, 0), (other, 100)], [],
		]
		for versions in cases {
			let reply = PlatformHTTPStub.Reply.json(200, Fixture.envelope(["deployments": [Fixture.deployment(versions: versions)]]))
			let route = PlatformHTTPStub.platform { _ in reply }
			#expect(await client(route).activeDeployment(ofScript: Fixture.workerName, in: Fixture.account) == .failure(.invalidResponse))
		}
	}

	@Test("secrets are set as one merge patch of secret_text bindings, and the answer lists every secret the Worker has")
	func updatesSecrets() async throws {
		let route = PlatformHTTPStub.platform { _ in
			.json(
				200,
				Fixture.envelope([
					"API_TOKEN": ["name": "API_TOKEN", "type": "secret_text"], "NEW_KEY": ["name": "NEW_KEY", "type": "secret_text"],
					"DATABASE_URL": ["name": "DATABASE_URL", "type": "secret_text"],
				]),
				headers: ["Date": date])
		}
		let update = try await client(route).updateSecrets(
			["API_TOKEN": "tok", "NEW_KEY": "a \"quoted\" value"], ofScript: Fixture.workerName, in: Fixture.account
		).get()
		#expect(update.names == ["API_TOKEN", "NEW_KEY", "DATABASE_URL"])
		#expect(update.answeredAt == Date(timeIntervalSince1970: 1_792_297_092))
		let request = try #require(route.requests.first)
		#expect(request.method == "PATCH")
		#expect(request.url.path() == "/client/v4/accounts/\(Fixture.account)/workers/scripts/\(Fixture.workerName)/secrets-bulk")
		#expect(request.header("Content-Type") == "application/merge-patch+json")
		let secrets = try #require(request.json?["secrets"] as? [String: [String: String]])
		#expect(secrets == [
			"API_TOKEN": ["name": "API_TOKEN", "type": "secret_text", "text": "tok"],
			"NEW_KEY": ["name": "NEW_KEY", "type": "secret_text", "text": "a \"quoted\" value"],
		])
		#expect(request.json?.count == 1, "Nothing but the secrets is sent: Cloudflare ignores version tags here")
	}

	@Test("a secrets answer whose entries don't name themselves is unreadable")
	func refusesMalformedSecretsAnswer() async {
		for result in [["A": ["name": "B", "type": "secret_text"]], ["A": "secret_text"], ["A": ["name": "A"]]] as [[String: Any]] {
			let reply = PlatformHTTPStub.Reply.json(200, Fixture.envelope(result))
			let route = PlatformHTTPStub.platform { _ in reply }
			#expect(await client(route).updateSecrets(["A": "1"], ofScript: Fixture.workerName, in: Fixture.account) == .failure(.invalidResponse))
		}
	}

	@Test("refusals read by status and Cloudflare's codes, never its messages, which could echo what was sent")
	func readsRefusals() async {
		func refusal(_ status: Int, _ body: [String: Any], headers: [String: String] = [:]) async -> Result<CloudflareSecretsUpdate, CloudflareAPIError> {
			let reply = PlatformHTTPStub.Reply.json(status, body, headers: headers)
			let route = PlatformHTTPStub.platform { _ in reply }
			return await client(route).updateSecrets(["A": "value-sentinel"], ofScript: Fixture.workerName, in: Fixture.account)
		}
		#expect(await refusal(401, Fixture.refusal([10_000])) == .failure(.unauthorized))
		#expect(await refusal(403, Fixture.refusal([10_000])) == .failure(.forbidden))
		#expect(await refusal(404, Fixture.refusal([10_007])) == .failure(.notFound))
		#expect(await refusal(400, Fixture.refusal([10_007])) == .failure(.notFound), "Cloudflare's code for a missing Worker says so whatever the status")
		#expect(await refusal(400, Fixture.refusal([10_053], message: "Binding name 'value-sentinel' already in use"))
			== .failure(.refused(status: 400, codes: [10_053])))
		#expect(await refusal(400, Fixture.refusal([10_215])) == .failure(.refused(status: 400, codes: [10_215])))
		#expect(await refusal(500, Fixture.refusal([10_013])) == .failure(.server(500)))
		#expect(await refusal(200, ["result": NSNull(), "success": false, "errors": [], "messages": []]) == .failure(.invalidResponse))
		#expect(CloudflareAPIError.refused(status: 400, codes: [10_215]).refused(with: CloudflareAPIError.newestVersionNotDeployedCodes))
		#expect(!CloudflareAPIError.refused(status: 400, codes: [10_053]).refused(with: CloudflareAPIError.newestVersionNotDeployedCodes))
	}

	@Test("a rate limit says when it lifts by Retry-After, or else by its Ratelimit header's t")
	func readsRateLimits() {
		let now = Date(timeIntervalSince1970: 1_760_000_000)
		func failure(_ headers: [String: String]) -> CloudflareAPIError {
			let http = HTTPURLResponse(url: CloudflareHTTP.defaultBaseURL, statusCode: 429, httpVersion: "HTTP/1.1", headerFields: headers)!
			return CloudflareHTTP.failure(http, body: Data(), now: now)
		}
		#expect(failure(["Retry-After": "30"]) == .rateLimited(until: now.addingTimeInterval(30)))
		#expect(failure(["Ratelimit": #""default";r=0;t=42"#]) == .rateLimited(until: now.addingTimeInterval(42)))
		#expect(failure(["Retry-After": "soon", "Ratelimit": #""default";r=0;t=7"#]) == .rateLimited(until: now.addingTimeInterval(7)))
		#expect(failure(["Ratelimit": #""default";r=0;t=-1"#]) == .rateLimited(until: nil))
		#expect(failure([:]) == .rateLimited(until: nil))
	}

	@Test("a redirect is refused, never followed with the token")
	func refusesRedirects() async {
		let route = PlatformHTTPStub.platform { _ in
			PlatformHTTPStub.Reply(status: 302, headers: ["Location": "https://elsewhere.test/steal"], body: Data())
		}
		#expect(await client(route).worker(Fixture.workerID, in: Fixture.account) == .failure(.moved))
		#expect(route.requests.count == 1)
	}

	@Test("only a connection that couldn't be made proves a request never left this Mac")
	func classifiesTransportFailures() {
		for code in [URLError.Code.cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .notConnectedToInternet, .secureConnectionFailed] {
			#expect(CloudflareHTTP.failure(URLError(code)) == .unreachable)
		}
		for code in [URLError.Code.timedOut, .networkConnectionLost, .badServerResponse, .cannotParseResponse, .resourceUnavailable] {
			#expect(CloudflareHTTP.failure(URLError(code)) == .transport, "\(code) can come after the request reached Cloudflare")
		}
		#expect(CloudflareHTTP.failure(URLError(.cancelled)) == .cancelled)
	}

	@Test("an answer too large to read is unreadable")
	func refusesOversizedAnswers() async {
		let route = PlatformHTTPStub.platform { _ in
			PlatformHTTPStub.Reply(status: 200, body: Data(repeating: 0x20, count: CloudflareHTTP.maximumResponseBytes + 1))
		}
		#expect(await client(route).worker(Fixture.workerID, in: Fixture.account) == .failure(.invalidResponse))
	}

	@Test("the token never prints")
	func redacted() {
		let client = CloudflareClient(token: "cf_secret_token")
		var dumped = ""
		dump(client, to: &dumped)
		for text in [String(describing: client), String(reflecting: client), dumped] {
			#expect(!text.contains("cf_secret_token"))
		}
	}
}
