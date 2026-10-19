import CryptoKit
import Foundation

/// The signed-in LPM session a platform connection is started with.
struct PlatformSession: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
	let token: String
	/// The LPM user the Registry must sign its answers for.
	let principalID: String
	let baseURL: URL
	/// The Registry the session is signed in to, which issues what's connected through it.
	let issuer: PlatformIssuer

	var description: String { "PlatformSession(principal: \(principalID), issuer: \(issuer.rawValue), token: <redacted>)" }
	var debugDescription: String { description }
	var customMirror: Mirror { Mirror(self, children: ["principalID": principalID, "baseURL": baseURL, "issuer": issuer]) }
}

/// A platform LPM Vault connects in the browser through the Registry, whose
/// OAuth code exchange needs a client secret only the Registry holds. Its raw
/// value names the platform in the Registry's routes and signed answers, and
/// in the path the browser returns to on this Mac.
enum BrowserPlatform: String, CaseIterable, Sendable {
	case vercel
	case netlify
	case github
	case cloudflare

	var publishPlatform: PublishPlatform {
		switch self {
		case .vercel: .vercel
		case .netlify: .netlify
		case .github: .github
		case .cloudflare: .cloudflare
		}
	}

	/// The browser platform `platform` is, or nil for one connected otherwise, such as Coolify with a token.
	init?(_ platform: PublishPlatform) {
		switch platform {
		case .vercel: self = .vercel
		case .netlify: self = .netlify
		case .github: self = .github
		case .cloudflare: self = .cloudflare
		case .coolify: return nil
		}
	}

	var displayName: String { publishPlatform.displayName }
}

enum PlatformAuthorizationError: Error, Equatable, Sendable {
	/// The LPM session is missing or no longer valid.
	case signedOut
	/// The LPM credential can't start platform connections.
	case forbidden
	/// The Registry can't connect this platform right now.
	case unavailable
	/// The platform answered, but refused the app's own request; asking again later can work.
	case platformRefused
	case rateLimited
	/// Too many connections are already open; finish or cancel them first.
	case tooManyOpen
	case transport
	/// An answer that isn't signed for this request, this person and this authorization.
	case invalidResponse
	case cancelled
	case server(Int)
}

/// A connection the Registry started, as it signed it for this request.
struct StartedPlatformAuthorization: Equatable, Sendable {
	/// A lowercase UUID; it also binds the encrypted grant.
	let id: String
	/// The platform's page where the person approves LPM Vault, carrying the single-use state.
	let pageURL: URL
	let expiresAt: Date
}

/// Where a connection stands when this Mac asks for its result.
enum PlatformAuthorizationOutcome: Equatable, Sendable {
	/// The grant, sealed to the connection's key, completed `age` seconds ago,
	/// so its tokens' lifetimes count from then; 0 from a Registry that doesn't say.
	case ready(PlatformAuthorizationEnvelope.Sealed, age: Int)
	/// The browser hasn't finished on the Registry yet.
	case pending
	/// The platform or the Registry refused it, with the Registry's code.
	case failed(code: String)
	case expired
	/// The proof isn't the one the browser brought back for this connection.
	case proofMismatch
	/// Gone: collected already, cancelled, or never this session's.
	case missing
}

/// Where a token refresh stands, as the Registry answers it.
enum PlatformTokenRefreshOutcome: Equatable, Sendable {
	/// The new tokens, sealed to the attempt's key, issued `age` seconds ago:
	/// a retry collects the tokens a lost answer carried.
	case ready(PlatformAuthorizationEnvelope.Sealed, age: Int)
	/// The attempt isn't finished: another request of it is still refreshing
	/// the token, or this one ran past the Registry's deadline and goes on
	/// for a retry to collect.
	case pending
	/// The platform or the Registry refused it, or the token was already used, with the Registry's code.
	case failed(code: String)
	/// The refresh token expired.
	case expired
	/// The Registry didn't issue the token to the signed-in person, or no longer knows it.
	case unknown
}

/// Refreshes an expiring platform token through the Registry, which holds
/// the client secret the platform's refresh needs.
protocol PlatformTokenRefreshing: Sendable {
	/// Sends `refreshToken` for one attempt, named by `refreshID`, whose
	/// result is sealed to `clientPublicKey`. Sending the same attempt again
	/// collects the result the first request got, for a while.
	func refresh(
		_ platform: BrowserPlatform,
		refreshToken: String,
		clientPublicKey: Data,
		refreshID: String,
		session: PlatformSession
	) async -> Result<PlatformTokenRefreshOutcome, PlatformAuthorizationError>
}

/// What the Registry did with a token LPM Vault asked it to revoke.
enum PlatformTokenRevocationOutcome: Equatable, Sendable {
	/// The platform ended the token's family, or already had.
	case accepted
	/// Whether the family ended can't be told: the token isn't one the
	/// Registry can still end, as one already spent or unknown to it.
	case unconfirmed
	/// The token was renewed by the attempt the request named: its result,
	/// sealed to the attempt's key, issued `age` seconds ago, is what to revoke.
	case superseded(PlatformAuthorizationEnvelope.Sealed, age: Int)
	/// A renewal of the token is still running; asking again later finishes the revocation.
	case busy
	/// Not done now; ask again after `seconds`.
	case retry(after: Int)
}

/// Revokes a platform refresh token through the Registry, which holds the
/// client secret revoking needs. Holding the token is the authority; the
/// LPM session only authenticates and rate-limits the request.
protocol PlatformTokenRevoking: Sendable {
	/// Revokes `token` for the cleanup `revocationID` names. With `attempt`,
	/// a renewal of the token that may have been sent, the Registry can hand
	/// over the tokens that renewal issued.
	func revoke(
		_ platform: BrowserPlatform,
		token: String,
		revocationID: String,
		attempt: (id: String, publicKey: Data)?,
		session: PlatformSession
	) async -> Result<PlatformTokenRevocationOutcome, PlatformAuthorizationError>
}

protocol PlatformAuthorizationClientProtocol: Sendable {
	func start(
		_ platform: BrowserPlatform,
		clientPublicKey: Data,
		loopbackPort: UInt16,
		session: PlatformSession
	) async -> Result<StartedPlatformAuthorization, PlatformAuthorizationError>
	func redeem(
		_ authorizationID: String,
		on platform: BrowserPlatform,
		proof: String,
		session: PlatformSession
	) async -> Result<PlatformAuthorizationOutcome, PlatformAuthorizationError>
	func cancel(_ authorizationID: String, on platform: BrowserPlatform, session: PlatformSession) async
}

/// The Registry's platform connection routes. Every answer that carries a
/// result must be signed by the Registry and name this request's nonce, the
/// signed-in person, the platform and the connection, so nothing another
/// request, another person or another platform caused is accepted.
struct PlatformAuthorizationClient: PlatformAuthorizationClientProtocol, PlatformTokenRefreshing, PlatformTokenRevoking {
	static let nonceHeader = "x-lpm-platform-request-nonce"
	private static let maximumResponseBytes = 64 * 1024

	let session: URLSession

	/// The session clients use unless given one. A session holds its
	/// delegate until it's invalidated, so one per process serves every
	/// connection attempt: it keeps no cookies, cache or credentials.
	static let sharedSession = URLSession(
		configuration: BoundedHTTPResponse.ephemeralConfiguration(requestTimeout: 15, resourceTimeout: 30),
		delegate: PinnedSessionDelegate(),
		delegateQueue: nil
	)

	init(session: URLSession? = nil) {
		self.session = session ?? Self.sharedSession
	}

	func start(
		_ platform: BrowserPlatform,
		clientPublicKey: Data,
		loopbackPort: UInt16,
		session platformSession: PlatformSession
	) async -> Result<StartedPlatformAuthorization, PlatformAuthorizationError> {
		guard clientPublicKey.count == 65, clientPublicKey.first == 0x04, loopbackPort >= 1024,
			let url = URL(string: "/api/vault/platforms/\(platform.rawValue)/authorizations", relativeTo: platformSession.baseURL),
			let body = try? JSONSerialization.data(withJSONObject: [
				"publicKey": clientPublicKey.base64EncodedString(),
				"loopbackPort": Int(loopbackPort),
			])
		else { return .failure(.invalidResponse) }
		let nonce = Self.makeNonce()
		return await send(url: url, body: body, nonce: nonce, session: platformSession).flatMap { http, data in
			guard http.statusCode == 201 else { return .failure(Self.failure(status: http.statusCode, body: data)) }
			guard let object = Self.signedObject(
				http, data, nonce: nonce, principalID: platformSession.principalID, platform: platform),
				let id = object["authorizationId"] as? String, Self.isCanonicalUUID(id),
				let pageText = object["installUrl"] as? String,
				let pageURL = Self.validatedPageURL(pageText, for: platform, registry: platformSession.baseURL),
				let expiresText = object["expiresAt"] as? String,
				let expiresAt = Self.date(expiresText)
			else { return .failure(.invalidResponse) }
			return .success(StartedPlatformAuthorization(id: id, pageURL: pageURL, expiresAt: expiresAt))
		}
	}

	func redeem(
		_ authorizationID: String,
		on platform: BrowserPlatform,
		proof: String,
		session platformSession: PlatformSession
	) async -> Result<PlatformAuthorizationOutcome, PlatformAuthorizationError> {
		guard Self.isCanonicalUUID(authorizationID), Self.isOneTimeValue(proof),
			let url = URL(
				string: "/api/vault/platforms/\(platform.rawValue)/authorizations/\(authorizationID)/redeem",
				relativeTo: platformSession.baseURL),
			let body = try? JSONSerialization.data(withJSONObject: ["proof": proof])
		else { return .failure(.invalidResponse) }
		let nonce = Self.makeNonce()
		return await send(url: url, body: body, nonce: nonce, session: platformSession).flatMap { http, data in
			guard [200, 202, 403, 404, 409, 410].contains(http.statusCode) else {
				return .failure(Self.failure(status: http.statusCode, body: data))
			}
			// An unsigned 403 or 404 comes from authentication, before the route signs anything.
			guard let object = Self.signedObject(
				http, data, nonce: nonce, principalID: platformSession.principalID, platform: platform),
				object["authorizationId"] as? String == authorizationID,
				let status = object["status"] as? String
			else {
				switch http.statusCode {
				case 403: return .failure(.forbidden)
				case 404: return .failure(.server(404))
				default: return .failure(.invalidResponse)
				}
			}
			switch (http.statusCode, status) {
			case (200, "ready"):
				guard let sealed = Self.sealed(object["envelope"]) else { return .failure(.invalidResponse) }
				// A Registry from before redemptions said their age gives none; one that says must say it well.
				guard object["ageSeconds"] == nil || Self.age(object["ageSeconds"]) != nil else { return .failure(.invalidResponse) }
				return .success(.ready(sealed, age: Self.age(object["ageSeconds"]) ?? 0))
			case (202, "pending"): return .success(.pending)
			case (409, "failed"):
				let code = (object["code"] as? String).flatMap { Self.isFailureCode($0) ? $0 : nil } ?? "server_error"
				return .success(.failed(code: code))
			case (410, "expired"): return .success(.expired)
			case (403, "proof_mismatch"): return .success(.proofMismatch)
			case (404, "missing"): return .success(.missing)
			default: return .failure(.invalidResponse)
			}
		}
	}

	func refresh(
		_ platform: BrowserPlatform,
		refreshToken: String,
		clientPublicKey: Data,
		refreshID: String,
		session platformSession: PlatformSession
	) async -> Result<PlatformTokenRefreshOutcome, PlatformAuthorizationError> {
		guard clientPublicKey.count == 65, clientPublicKey.first == 0x04, Self.isCanonicalUUID(refreshID),
			PlatformTokens.isValidToken(refreshToken),
			let url = URL(string: "/api/vault/platforms/\(platform.rawValue)/tokens", relativeTo: platformSession.baseURL),
			let body = try? JSONSerialization.data(withJSONObject: [
				"refreshToken": refreshToken,
				"publicKey": clientPublicKey.base64EncodedString(),
				"refreshId": refreshID,
			])
		else { return .failure(.invalidResponse) }
		let nonce = Self.makeNonce()
		return await send(url: url, body: body, nonce: nonce, session: platformSession).flatMap { http, data in
			guard [200, 202, 404, 409, 410].contains(http.statusCode) else {
				return .failure(Self.failure(status: http.statusCode, body: data))
			}
			// An unsigned 404 comes from a Registry without the route, before anything is signed.
			guard let object = Self.signedObject(
				http, data, nonce: nonce, principalID: platformSession.principalID, platform: platform),
				object["refreshId"] as? String == refreshID,
				let status = object["status"] as? String
			else { return .failure(http.statusCode == 404 ? .server(404) : .invalidResponse) }
			switch (http.statusCode, status) {
			case (200, "ready"):
				guard let sealed = Self.sealed(object["envelope"]), let age = Self.age(object["ageSeconds"]) else {
					return .failure(.invalidResponse)
				}
				return .success(.ready(sealed, age: age))
			case (202, "pending"): return .success(.pending)
			case (409, "failed"):
				let code = (object["code"] as? String).flatMap { Self.isFailureCode($0) ? $0 : nil } ?? "server_error"
				return .success(.failed(code: code))
			case (410, "expired"): return .success(.expired)
			case (404, "unknown"): return .success(.unknown)
			default: return .failure(.invalidResponse)
			}
		}
	}

	func revoke(
		_ platform: BrowserPlatform,
		token: String,
		revocationID: String,
		attempt: (id: String, publicKey: Data)?,
		session platformSession: PlatformSession
	) async -> Result<PlatformTokenRevocationOutcome, PlatformAuthorizationError> {
		var fields: [String: Any] = ["token": token, "revocationId": revocationID]
		if let attempt {
			guard Self.isCanonicalUUID(attempt.id), attempt.publicKey.count == 65, attempt.publicKey.first == 0x04 else {
				return .failure(.invalidResponse)
			}
			fields["attempt"] = ["refreshId": attempt.id, "publicKey": attempt.publicKey.base64EncodedString()]
		}
		guard PlatformTokens.isValidToken(token), Self.isCanonicalUUID(revocationID),
			let url = URL(string: "/api/vault/platforms/\(platform.rawValue)/revocations", relativeTo: platformSession.baseURL),
			let body = try? JSONSerialization.data(withJSONObject: fields)
		else { return .failure(.invalidResponse) }
		let nonce = Self.makeNonce()
		return await send(url: url, body: body, nonce: nonce, session: platformSession).flatMap { http, data in
			// Refused before its body is read, as by the per-person limit, a request is unsigned and only waits.
			if http.statusCode == 429 { return .success(.retry(after: Self.retryAfter(http) ?? 60)) }
			guard [200, 202, 503].contains(http.statusCode) else { return .failure(Self.failure(status: http.statusCode, body: data)) }
			guard let object = Self.signedObject(
				http, data, nonce: nonce, principalID: platformSession.principalID, platform: platform),
				object["revocationId"] as? String == revocationID,
				let status = object["status"] as? String
			else { return .failure(http.statusCode == 503 ? Self.failure(status: 503, body: data) : .invalidResponse) }
			switch (http.statusCode, status) {
			case (200, "accepted"): return .success(.accepted)
			case (200, "unconfirmed"): return .success(.unconfirmed)
			case (200, "superseded"):
				guard attempt != nil, let sealed = Self.sealed(object["envelope"]), let age = Self.age(object["ageSeconds"]) else {
					return .failure(.invalidResponse)
				}
				return .success(.superseded(sealed, age: age))
			case (202, "busy"): return .success(.busy)
			case (503, "retry"):
				guard let seconds = PlatformTokens.integer(object["retryAfterSeconds"]), (1...86_400).contains(seconds) else {
					return .failure(.invalidResponse)
				}
				return .success(.retry(after: seconds))
			default: return .failure(.invalidResponse)
			}
		}
	}

	func cancel(_ authorizationID: String, on platform: BrowserPlatform, session platformSession: PlatformSession) async {
		guard Self.isCanonicalUUID(authorizationID),
			let url = URL(
				string: "/api/vault/platforms/\(platform.rawValue)/authorizations/\(authorizationID)",
				relativeTo: platformSession.baseURL)
		else { return }
		var request = URLRequest(url: url)
		request.httpMethod = "DELETE"
		request.setValue("Bearer \(platformSession.token)", forHTTPHeaderField: "Authorization")
		_ = try? await BoundedHTTPResponse.load(for: request, using: session, maximumBytes: Self.maximumResponseBytes)
	}

	// MARK: - Requests

	private func send(
		url: URL,
		body: Data,
		nonce: String,
		session platformSession: PlatformSession
	) async -> Result<(HTTPURLResponse, Data), PlatformAuthorizationError> {
		var request = URLRequest(url: url)
		request.httpMethod = "POST"
		request.httpBody = body
		request.setValue("application/json", forHTTPHeaderField: "Content-Type")
		request.setValue("Bearer \(platformSession.token)", forHTTPHeaderField: "Authorization")
		request.setValue(nonce, forHTTPHeaderField: Self.nonceHeader)
		do {
			let (data, response) = try await BoundedHTTPResponse.load(
				for: request, using: session, maximumBytes: Self.maximumResponseBytes)
			guard let http = response as? HTTPURLResponse else { return .failure(.invalidResponse) }
			return .success((http, data))
		} catch is BoundedHTTPResponse.LoadError {
			return .failure(.invalidResponse)
		} catch is CancellationError {
			return .failure(.cancelled)
		} catch let error as URLError where error.code == .cancelled {
			return .failure(.cancelled)
		} catch {
			return .failure(.transport)
		}
	}

	/// The body as an object, when the Registry signed it for this request's
	/// nonce, for `principalID`, about `platform`.
	private static func signedObject(
		_ http: HTTPURLResponse,
		_ data: Data,
		nonce: String,
		principalID: String,
		platform: BrowserPlatform
	) -> [String: Any]? {
		guard PinnedSessionDelegate.verifyResponseSignature(http, body: data, requireSignature: true),
			let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
			object["requestNonce"] as? String == nonce,
			object["principalId"] as? String == principalID,
			object["platform"] as? String == platform.rawValue
		else { return nil }
		return object
	}

	/// Failures the Registry answers before it signs anything. Their codes
	/// only choose a message, so they're read without a signature.
	private static func failure(status: Int, body: Data) -> PlatformAuthorizationError {
		let code = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["code"] as? String
		switch (status, code) {
		case (401, _): return .signedOut
		case (403, _): return .forbidden
		case (503, "platform_unavailable"): return .unavailable
		case (503, "platform_refused"): return .platformRefused
		case (429, "too_many_authorizations"): return .tooManyOpen
		case (429, _): return .rateLimited
		default: return .server(status)
		}
	}

	/// A sealed result as an answer carries it.
	private static func sealed(_ value: Any?) -> PlatformAuthorizationEnvelope.Sealed? {
		guard let value, let data = try? JSONSerialization.data(withJSONObject: value) else { return nil }
		return try? JSONDecoder().decode(PlatformAuthorizationEnvelope.Sealed.self, from: data)
	}

	/// How long ago a result was issued, in whole seconds within a token's life.
	private static func age(_ value: Any?) -> Int? {
		guard let age = PlatformTokens.integer(value), age >= 0, age <= PlatformTokens.maximumLifetime else { return nil }
		return age
	}

	/// The seconds `Retry-After` asks to wait, within a day.
	private static func retryAfter(_ http: HTTPURLResponse) -> Int? {
		guard let text = http.value(forHTTPHeaderField: "Retry-After"), text.utf8.count <= 6,
			text.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }), let seconds = Int(text), (1...86_400).contains(seconds)
		else { return nil }
		return seconds
	}

	// MARK: - Validation

	/// 32 random bytes as unpadded base64url, which the Registry requires.
	static func makeNonce() -> String {
		let bytes = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
		return base64URL(bytes)
	}

	static func base64URL(_ data: Data) -> String {
		data.base64EncodedString()
			.replacingOccurrences(of: "+", with: "-")
			.replacingOccurrences(of: "/", with: "_")
			.replacingOccurrences(of: "=", with: "")
	}

	/// A UUID in the lowercase form the Registry issues.
	static func isCanonicalUUID(_ text: String) -> Bool {
		guard let uuid = UUID(uuidString: text) else { return false }
		return uuid.uuidString.lowercased() == text
	}

	/// The Registry's one-time values: 43 characters of unpadded base64url.
	static func isOneTimeValue(_ text: String) -> Bool {
		text.utf8.count == 43 && text.utf8.allSatisfy(isBase64URLByte)
	}

	static func isFailureCode(_ text: String) -> Bool {
		!text.isEmpty && text.utf8.count <= 64
			&& text.utf8.allSatisfy { ($0 >= 0x61 && $0 <= 0x7A) || $0 == 0x5F }
	}

	/// The platform's page for approving LPM Vault, and nothing else, so a
	/// signed answer can't send the browser anywhere unexpected: Vercel's
	/// install page for an integration, or Netlify's Authorize page for an
	/// OAuth app that returns the code to `registry`'s callback.
	static func validatedPageURL(_ text: String, for platform: BrowserPlatform, registry: URL) -> URL? {
		guard text.utf8.count <= 2_048,
			let components = URLComponents(string: text),
			components.scheme == "https",
			components.user == nil, components.password == nil, components.port == nil, components.fragment == nil,
			let items = components.queryItems
		else { return nil }
		var query: [String: String] = [:]
		for item in items {
			guard let value = item.value, query.updateValue(value, forKey: item.name) == nil else { return nil }
		}
		let isValid = switch platform {
		case .vercel: isVercelInstallPage(components, query: query)
		case .netlify: isNetlifyAuthorizePage(components, query: query, registry: registry)
		case .github: isGitHubAuthorizePage(components, query: query, registry: registry)
		case .cloudflare: isCloudflareAuthorizePage(components, query: query, registry: registry)
		}
		return isValid ? components.url : nil
	}

	private static func isVercelInstallPage(_ components: URLComponents, query: [String: String]) -> Bool {
		let path = components.path.split(separator: "/", omittingEmptySubsequences: false)
		return components.host == "vercel.com"
			&& path.count == 4 && path[0].isEmpty && path[1] == "integrations" && path[3] == "new"
			&& VercelPublishTarget.isValidIdentifier(String(path[2]))
			&& query.count == 1 && query["state"].map(isOneTimeValue) == true
	}

	private static func isNetlifyAuthorizePage(_ components: URLComponents, query: [String: String], registry: URL) -> Bool {
		guard let callback = callbackURL(for: .netlify, registry: registry)?.absoluteString else { return false }
		return components.host == "app.netlify.com" && components.path == "/authorize"
			&& query.count == 4
			&& query["client_id"].map(NetlifyHTTP.isValidIdentifier) == true
			&& query["response_type"] == "code"
			&& query["redirect_uri"] == callback
			&& query["state"].map(isOneTimeValue) == true
	}

	/// GitHub's page for authorizing LPM Vault's GitHub App: an expiring token,
	/// the account picker, and the PKCE challenge of the verifier the Registry keeps.
	private static func isGitHubAuthorizePage(_ components: URLComponents, query: [String: String], registry: URL) -> Bool {
		guard let callback = callbackURL(for: .github, registry: registry)?.absoluteString else { return false }
		return components.host == "github.com" && components.path == "/login/oauth/authorize"
			&& query.count == 7
			&& query["client_id"].map(GitHubHTTP.isValidClientID) == true
			&& query["redirect_uri"] == callback
			&& query["state"].map(isOneTimeValue) == true
			&& query["scope"] == "offline_access"
			&& query["prompt"] == "select_account"
			&& query["code_challenge"].map(isOneTimeValue) == true
			&& query["code_challenge_method"] == "S256"
	}

	/// Cloudflare's page for approving LPM Vault for the accounts the person
	/// picks: the scopes LPM Vault needs, and the PKCE challenge of the
	/// verifier the Registry keeps. Which client may ask is checked against
	/// the Registry's issuer; see `CloudflareOAuth.accepts`.
	private static func isCloudflareAuthorizePage(_ components: URLComponents, query: [String: String], registry: URL) -> Bool {
		guard let callback = callbackURL(for: .cloudflare, registry: registry)?.absoluteString else { return false }
		return components.host == CloudflareOAuth.authorizeURL.host() && components.path == CloudflareOAuth.authorizeURL.path()
			&& query.count == 7
			&& query["response_type"] == "code"
			&& query["client_id"].map(CloudflareOAuth.isValidClientID) == true
			&& query["redirect_uri"] == callback
			// The Registry writes the query as a form does, so the scopes' spaces arrive as `+`, which no scope contains.
			&& query["scope"]?.replacingOccurrences(of: "+", with: " ") == CloudflareOAuth.scope
			&& query["state"].map(isOneTimeValue) == true
			&& query["code_challenge"].map(isOneTimeValue) == true
			&& query["code_challenge_method"] == "S256"
	}

	/// The client a page asks Cloudflare to approve, as its `client_id` names it.
	static func cloudflareClientID(of page: URL) -> String? {
		URLComponents(url: page, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "client_id" }?.value
	}

	/// Where the platform returns the browser with its code: `registry`'s
	/// callback for the platform, on the Registry's origin.
	static func callbackURL(for platform: BrowserPlatform, registry: URL) -> URL? {
		guard var components = URLComponents(url: registry, resolvingAgainstBaseURL: true) else { return nil }
		components.path = "/api/vault/platforms/\(platform.rawValue)/callback"
		components.query = nil
		components.fragment = nil
		components.user = nil
		components.password = nil
		return components.url
	}

	private static func isBase64URLByte(_ byte: UInt8) -> Bool {
		(byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
			|| byte == 0x2D || byte == 0x5F
	}

	private static func date(_ text: String) -> Date? {
		let formatter = ISO8601DateFormatter()
		formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
		return formatter.date(from: text)
	}
}
