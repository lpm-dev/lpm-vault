import Foundation

/// Why a Cloudflare API request didn't give LPM Vault what it asked for.
enum CloudflareAPIError: Error, Equatable, Sendable {
	/// The token no longer works, as after it expired or the person revoked LPM Vault.
	case unauthorized
	/// The token can't reach this, as when the person's role on the account
	/// can't change Workers, or the account wasn't chosen when connecting.
	case forbidden
	/// The Worker isn't there, as after it was deleted.
	case notFound
	case rateLimited(until: Date?)
	/// Cloudflare refused the request, with its HTTP status and error codes.
	/// Its messages are never shown: one could echo what was sent.
	case refused(status: Int, codes: [Int])
	/// The request never left this Mac: its connection couldn't be made.
	case unreachable
	/// The connection failed after the request may have reached Cloudflare.
	case transport
	case cancelled
	case invalidResponse
	case server(Int)
	/// Cloudflare redirected the request. A redirect is never followed.
	case moved

	/// Cloudflare's code for a Worker that doesn't exist.
	static let workerMissingCode = 10_007
	/// Cloudflare's codes for a Worker whose newest version isn't fully
	/// deployed, which refuse a change to its secrets.
	static let newestVersionNotDeployedCodes: Set<Int> = [10_214, 10_215]
	/// Cloudflare's code for a name another binding of the Worker uses.
	static let nameTakenCode = 10_053
	/// Cloudflare's code for more text bindings than the Worker's plan allows.
	static let tooManyBindingsCode = 10_055

	/// Whether Cloudflare refused the request with any of `codes`.
	func refused(with codes: Set<Int>) -> Bool {
		if case .refused(_, let given) = self { return given.contains(where: codes.contains) }
		return false
	}
}

/// A Worker as Cloudflare names it now.
struct CloudflareWorker: Equatable, Sendable {
	/// Cloudflare's ID for the Worker, which outlasts a rename.
	let id: String
	/// The Worker's script name, which the secrets API is addressed by.
	let name: String
}

/// What a binding of a Worker version is, as far as publishing goes.
enum CloudflareBindingKind: Equatable, Sendable {
	case secretText
	case plainText
	case json
	/// Any other kind, such as `secret_key` or a storage binding.
	case other

	init(type: String) {
		switch type {
		case "secret_text": self = .secretText
		case "plain_text": self = .plainText
		case "json": self = .json
		default: self = .other
		}
	}

	/// Whether it counts toward the Worker's limit on text bindings, which
	/// secrets and plain and JSON variables share.
	var isText: Bool { self != .other }
}

/// One version of a Worker: its code, settings and bindings at a moment.
struct CloudflareVersion: Equatable, Sendable {
	let id: String
	/// Counts up from 1 for each version of the Worker.
	let number: Int
	let createdAt: Date
	/// The client that made it, such as `wrangler`, `dash` or `api`; nil when Cloudflare didn't say.
	let source: String?
	/// What made it, such as `upload` or `secret`; nil when Cloudflare didn't say.
	let trigger: String?
	/// The version's bindings by name.
	let bindings: [String: CloudflareBindingKind]
}

/// Which versions serve a Worker's traffic.
struct CloudflareDeployment: Equatable, Sendable {
	struct Share: Equatable, Sendable {
		let versionID: String
		let percentage: Double
	}

	let id: String
	let createdAt: Date
	let trigger: String?
	let versions: [Share]
	/// When Cloudflare answered, on its own clock; nil when it didn't say.
	let answeredAt: Date?

	/// The version that serves all traffic; nil while traffic is split.
	var soleVersionID: String? {
		versions.count == 1 && versions[0].percentage == 100 ? versions[0].versionID : nil
	}
}

/// What changing a Worker's secrets left it with.
struct CloudflareSecretsUpdate: Equatable, Sendable {
	/// Every secret the Worker has now, by name.
	let names: Set<String>
	/// When Cloudflare answered, on its own clock; nil when it didn't say.
	let answeredAt: Date?
}

protocol CloudflareClientProtocol: Sendable {
	/// The Worker with the ID or script name, as Cloudflare names it now.
	func worker(_ idOrName: String, in account: String) async -> Result<CloudflareWorker, CloudflareAPIError>
	/// The Worker's newest version, by the Worker's ID.
	func newestVersion(ofWorker id: String, in account: String) async -> Result<CloudflareVersion, CloudflareAPIError>
	/// The deployment that serves the Worker's traffic now, by its script name.
	func activeDeployment(ofScript name: String, in account: String) async -> Result<CloudflareDeployment, CloudflareAPIError>
	/// Sets the Worker's secrets in `secrets`, leaving its others as they
	/// are, as one new version that's deployed at once.
	func updateSecrets(_ secrets: [String: String], ofScript name: String, in account: String) async
		-> Result<CloudflareSecretsUpdate, CloudflareAPIError>
}

/// Requests to Cloudflare's API. They go only to `baseURL`, redirects are
/// refused so a token never follows one, and Cloudflare's error messages
/// are never shown, only its numeric codes.
enum CloudflareHTTP {
	static let defaultBaseURL = URL(string: "https://api.cloudflare.com/client/v4")!
	static let userAgent = "LPM-Vault (https://vault.lpm.dev)"
	/// The largest answer read. A version lists every binding, and a name can take 2,712 bytes.
	static let maximumResponseBytes = 4 * 1024 * 1024
	/// The most error codes kept from one refusal.
	static let maximumErrorCodes = 16

	/// The session clients use unless given one; it keeps no cookies, cache or credentials.
	static let sharedSession = URLSession(
		configuration: BoundedHTTPResponse.ephemeralConfiguration(requestTimeout: 20, resourceTimeout: 60),
		delegate: RedirectRefusingHTTPDelegate(),
		delegateQueue: nil
	)

	static func request(_ method: String, _ url: URL, token: String, body: Data? = nil, contentType: String = "application/json") -> URLRequest {
		var request = URLRequest(url: url)
		request.httpMethod = method
		request.setValue("application/json", forHTTPHeaderField: "Accept")
		request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
		request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
		if let body {
			request.httpBody = body
			request.setValue(contentType, forHTTPHeaderField: "Content-Type")
		}
		return request
	}

	/// The answer's `result` and headers when Cloudflare accepted the request.
	static func load(
		_ request: URLRequest,
		using session: URLSession,
		limit: Int = maximumResponseBytes,
		now: @Sendable () -> Date = { Date() }
	) async -> Result<(result: Any, response: HTTPURLResponse), CloudflareAPIError> {
		let data: Data
		let http: HTTPURLResponse
		do {
			let (body, response) = try await BoundedHTTPResponse.load(for: request, using: session, maximumBytes: limit)
			guard let answer = response as? HTTPURLResponse else { return .failure(.invalidResponse) }
			data = body
			http = answer
		} catch is BoundedHTTPResponse.LoadError {
			return .failure(.invalidResponse)
		} catch is CancellationError {
			return .failure(.cancelled)
		} catch let error as URLError {
			return .failure(failure(error))
		} catch {
			return .failure(.transport)
		}
		guard (200..<300).contains(http.statusCode) else { return .failure(failure(http, body: data, now: now())) }
		guard let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
			envelope["success"] as? Bool == true, let result = envelope["result"]
		else { return .failure(.invalidResponse) }
		return .success((result, http))
	}

	/// A failure without an answer. Only a connection that couldn't be made
	/// proves the request never left this Mac; anything later may have
	/// reached Cloudflare.
	static func failure(_ error: URLError) -> CloudflareAPIError {
		switch error.code {
		case .cancelled: .cancelled
		case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .notConnectedToInternet, .internationalRoamingOff,
			.dataNotAllowed, .appTransportSecurityRequiresSecureConnection, .secureConnectionFailed, .serverCertificateHasBadDate,
			.serverCertificateUntrusted, .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid, .clientCertificateRejected,
			.clientCertificateRequired:
			.unreachable
		default: .transport
		}
	}

	/// A refusal, read by its status and Cloudflare's numeric codes. A rate
	/// limit says when it lifts in `Retry-After`, or else in its
	/// `Ratelimit` header's `t`, in seconds.
	static func failure(_ http: HTTPURLResponse, body: Data, now: Date = Date()) -> CloudflareAPIError {
		let status = http.statusCode
		if (300..<400).contains(status) { return .moved }
		if status == 429 { return .rateLimited(until: retryAfter(http).map { now.addingTimeInterval($0) }) }
		let codes = errorCodes(body)
		if codes.contains(CloudflareAPIError.workerMissingCode) { return .notFound }
		switch status {
		case 401: return .unauthorized
		case 403: return .forbidden
		case 404: return .notFound
		case 400..<500: return .refused(status: status, codes: codes)
		default: return .server(status)
		}
	}

	/// The seconds a rate limit asks to wait, from `Retry-After` or the
	/// `Ratelimit` header's `t`; nil when neither says.
	static func retryAfter(_ http: HTTPURLResponse) -> TimeInterval? {
		if let header = http.value(forHTTPHeaderField: "Retry-After"), let seconds = seconds(header) { return seconds }
		guard let header = http.value(forHTTPHeaderField: "Ratelimit") else { return nil }
		for parameter in header.split(separator: ";").dropFirst() {
			let parts = parameter.split(separator: "=", maxSplits: 1)
			guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == "t" else { continue }
			return seconds(String(parts[1]))
		}
		return nil
	}

	private static func seconds(_ text: String) -> TimeInterval? {
		let trimmed = text.trimmingCharacters(in: .whitespaces)
		guard !trimmed.isEmpty, trimmed.utf8.count <= 10, trimmed.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else { return nil }
		return TimeInterval(trimmed)
	}

	/// Cloudflare's numeric error codes, at most `maximumErrorCodes`.
	static func errorCodes(_ body: Data) -> [Int] {
		guard let envelope = try? JSONSerialization.jsonObject(with: body.prefix(64 * 1024)) as? [String: Any],
			let errors = envelope["errors"] as? [Any]
		else { return [] }
		return errors.prefix(maximumErrorCodes).compactMap { ($0 as? [String: Any]).flatMap { PlatformTokens.integer($0["code"]) } }
	}

	/// A Cloudflare account's or Worker's ID: 32 lowercase hexadecimal digits.
	static func isValidID(_ text: String) -> Bool {
		text.utf8.count == 32 && text.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }
	}

	/// A Worker's script name, as Cloudflare's API takes it: lowercase
	/// letters, digits, hyphens and underscores, not starting with a hyphen.
	static func isValidScriptName(_ text: String) -> Bool {
		guard let first = text.utf8.first, first != 0x2D, text.utf8.count <= 255 else { return false }
		return text.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x7A) || $0 == 0x2D || $0 == 0x5F }
	}

	/// A version's or deployment's ID: a UUID in lowercase.
	static func isValidVersionID(_ text: String) -> Bool {
		UUID(uuidString: text).map { $0.uuidString.lowercased() == text } ?? false
	}

	/// A time as Cloudflare writes one, `2026-10-18T04:18:12.049592Z`, with
	/// or without the fraction.
	static func date(_ value: Any?) -> Date? {
		guard let text = value as? String, text.utf8.count <= 40 else { return nil }
		if let date = try? Date(text, strategy: fractionalDate) { return date }
		return try? Date(text, strategy: .iso8601)
	}

	private static let fractionalDate = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
}

/// Cloudflare's API with one connection's access token. Requests go only
/// to `baseURL`, and redirects are refused so the token never follows one.
struct CloudflareClient: CloudflareClientProtocol, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
	private let token: String
	private let baseURL: URL
	let session: URLSession

	init(token: String, baseURL: URL = CloudflareHTTP.defaultBaseURL, session: URLSession? = nil) {
		self.token = token
		self.baseURL = baseURL
		self.session = session ?? CloudflareHTTP.sharedSession
	}

	var description: String { "CloudflareClient(\(baseURL.host() ?? "?"), token: <redacted>)" }
	var debugDescription: String { description }
	var customMirror: Mirror { Mirror(self, children: ["baseURL": baseURL]) }

	func worker(_ idOrName: String, in account: String) async -> Result<CloudflareWorker, CloudflareAPIError> {
		guard CloudflareHTTP.isValidID(account),
			CloudflareHTTP.isValidID(idOrName) || CloudflareHTTP.isValidScriptName(idOrName),
			let url = PlatformURL.url(baseURL, ["accounts", account, "workers", "workers", idOrName])
		else { return .failure(.invalidResponse) }
		return await CloudflareHTTP.load(CloudflareHTTP.request("GET", url, token: token), using: session).flatMap { loaded in
			guard let object = loaded.result as? [String: Any], let id = object["id"] as? String, CloudflareHTTP.isValidID(id),
				let name = object["name"] as? String, CloudflareHTTP.isValidScriptName(name)
			else { return .failure(.invalidResponse) }
			return .success(CloudflareWorker(id: id, name: name))
		}
	}

	func newestVersion(ofWorker id: String, in account: String) async -> Result<CloudflareVersion, CloudflareAPIError> {
		guard CloudflareHTTP.isValidID(account), CloudflareHTTP.isValidID(id),
			let url = PlatformURL.url(
				baseURL, ["accounts", account, "workers", "workers", id, "versions"],
				query: [URLQueryItem(name: "page", value: "1"), URLQueryItem(name: "per_page", value: "1")])
		else { return .failure(.invalidResponse) }
		return await CloudflareHTTP.load(CloudflareHTTP.request("GET", url, token: token), using: session).flatMap { loaded in
			guard let items = loaded.result as? [Any], let first = items.first, let version = Self.version(first) else {
				return .failure(.invalidResponse)
			}
			return .success(version)
		}
	}

	func activeDeployment(ofScript name: String, in account: String) async -> Result<CloudflareDeployment, CloudflareAPIError> {
		guard CloudflareHTTP.isValidID(account), CloudflareHTTP.isValidScriptName(name),
			let url = PlatformURL.url(baseURL, ["accounts", account, "workers", "scripts", name, "deployments"])
		else { return .failure(.invalidResponse) }
		return await CloudflareHTTP.load(CloudflareHTTP.request("GET", url, token: token), using: session).flatMap { loaded in
			guard let result = loaded.result as? [String: Any], let deployments = result["deployments"] as? [Any],
				let first = deployments.first, let deployment = Self.deployment(first, answeredAt: PlatformRateLimit.date(of: loaded.response))
			else { return .failure(.invalidResponse) }
			return .success(deployment)
		}
	}

	func updateSecrets(_ secrets: [String: String], ofScript name: String, in account: String) async
		-> Result<CloudflareSecretsUpdate, CloudflareAPIError>
	{
		var patch: [String: Any] = [:]
		for (key, value) in secrets { patch[key] = ["name": key, "type": "secret_text", "text": value] }
		guard CloudflareHTTP.isValidID(account), CloudflareHTTP.isValidScriptName(name), !secrets.isEmpty,
			let url = PlatformURL.url(baseURL, ["accounts", account, "workers", "scripts", name, "secrets-bulk"]),
			let body = try? JSONSerialization.data(withJSONObject: ["secrets": patch])
		else { return .failure(.invalidResponse) }
		let request = CloudflareHTTP.request("PATCH", url, token: token, body: body, contentType: "application/merge-patch+json")
		return await CloudflareHTTP.load(request, using: session).flatMap { loaded in
			guard let result = loaded.result as? [String: Any] else { return .failure(.invalidResponse) }
			var names: Set<String> = []
			for (key, value) in result {
				guard let secret = value as? [String: Any], secret["name"] as? String == key, secret["type"] is String else {
					return .failure(.invalidResponse)
				}
				names.insert(key)
			}
			return .success(CloudflareSecretsUpdate(names: names, answeredAt: PlatformRateLimit.date(of: loaded.response)))
		}
	}

	// MARK: - Decoding

	/// A version as the Workers API lists it; nil when it isn't one, or
	/// names a binding twice.
	static func version(_ json: Any) -> CloudflareVersion? {
		guard let object = json as? [String: Any], let id = object["id"] as? String, CloudflareHTTP.isValidVersionID(id),
			let number = PlatformTokens.integer(object["number"]), number > 0,
			let createdAt = CloudflareHTTP.date(object["created_on"]),
			let rawBindings = object["bindings"] as? [Any]
		else { return nil }
		var bindings: [String: CloudflareBindingKind] = [:]
		for raw in rawBindings {
			guard let binding = raw as? [String: Any], let name = binding["name"] as? String, !name.isEmpty,
				let type = binding["type"] as? String,
				bindings.updateValue(CloudflareBindingKind(type: type), forKey: name) == nil
			else { return nil }
		}
		let annotations = object["annotations"] as? [String: Any]
		return CloudflareVersion(
			id: id, number: number, createdAt: createdAt, source: object["source"] as? String,
			trigger: annotations?["workers/triggered_by"] as? String, bindings: bindings)
	}

	/// A deployment as Cloudflare lists it; nil when it isn't one, or its
	/// versions don't share all traffic between them.
	static func deployment(_ json: Any, answeredAt: Date?) -> CloudflareDeployment? {
		guard let object = json as? [String: Any], let id = object["id"] as? String, CloudflareHTTP.isValidVersionID(id),
			let createdAt = CloudflareHTTP.date(object["created_on"]), let rawVersions = object["versions"] as? [Any],
			!rawVersions.isEmpty, rawVersions.count <= 2
		else { return nil }
		var shares: [CloudflareDeployment.Share] = []
		var total = 0.0
		for raw in rawVersions {
			guard let share = raw as? [String: Any], let versionID = share["version_id"] as? String,
				CloudflareHTTP.isValidVersionID(versionID), let percentage = (share["percentage"] as? NSNumber)?.doubleValue,
				percentage.isFinite, percentage > 0, percentage <= 100, !shares.contains(where: { $0.versionID == versionID })
			else { return nil }
			shares.append(.init(versionID: versionID, percentage: percentage))
			total += percentage
		}
		guard abs(total - 100) < 0.001 else { return nil }
		let annotations = object["annotations"] as? [String: Any]
		return CloudflareDeployment(
			id: id, createdAt: createdAt, trigger: annotations?["workers/triggered_by"] as? String, versions: shares, answeredAt: answeredAt)
	}
}
