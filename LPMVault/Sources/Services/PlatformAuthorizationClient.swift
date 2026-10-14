import CryptoKit
import Foundation

/// The signed-in LPM session a platform connection is started with.
struct PlatformSession: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
	let token: String
	/// The LPM user the Registry must sign its answers for.
	let principalID: String
	let baseURL: URL

	var description: String { "PlatformSession(principal: \(principalID), token: <redacted>)" }
	var debugDescription: String { description }
	var customMirror: Mirror { Mirror(self, children: ["principalID": principalID, "baseURL": baseURL]) }
}

enum PlatformAuthorizationError: Error, Equatable, Sendable {
	/// The LPM session is missing or no longer valid.
	case signedOut
	/// The LPM credential can't start platform connections.
	case forbidden
	/// The Registry can't connect this platform right now.
	case unavailable
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
	/// Vercel's install page, carrying the single-use state.
	let installURL: URL
	let expiresAt: Date
}

/// Where a connection stands when this Mac asks for its result.
enum PlatformAuthorizationOutcome: Equatable, Sendable {
	case ready(PlatformAuthorizationEnvelope.Sealed)
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

protocol PlatformAuthorizationClientProtocol: Sendable {
	func startVercel(
		clientPublicKey: Data,
		loopbackPort: UInt16,
		session: PlatformSession
	) async -> Result<StartedPlatformAuthorization, PlatformAuthorizationError>
	func redeem(
		_ authorizationID: String,
		proof: String,
		session: PlatformSession
	) async -> Result<PlatformAuthorizationOutcome, PlatformAuthorizationError>
	func cancel(_ authorizationID: String, session: PlatformSession) async
}

/// The Registry's platform connection routes. Every answer that carries a
/// result must be signed by the Registry and name this request's nonce, the
/// signed-in person and the connection, so nothing another request or
/// another person caused is accepted.
struct PlatformAuthorizationClient: PlatformAuthorizationClientProtocol {
	static let nonceHeader = "x-lpm-platform-request-nonce"
	private static let maximumResponseBytes = 64 * 1024

	private let session: URLSession

	init(session: URLSession? = nil) {
		self.session = session ?? URLSession(
			configuration: BoundedHTTPResponse.ephemeralConfiguration(requestTimeout: 15, resourceTimeout: 30),
			delegate: PinnedSessionDelegate(),
			delegateQueue: nil
		)
	}

	func startVercel(
		clientPublicKey: Data,
		loopbackPort: UInt16,
		session platformSession: PlatformSession
	) async -> Result<StartedPlatformAuthorization, PlatformAuthorizationError> {
		guard clientPublicKey.count == 65, clientPublicKey.first == 0x04, loopbackPort >= 1024,
			let url = URL(string: "/api/vault/platforms/vercel/authorizations", relativeTo: platformSession.baseURL),
			let body = try? JSONSerialization.data(withJSONObject: [
				"publicKey": clientPublicKey.base64EncodedString(),
				"loopbackPort": Int(loopbackPort),
			])
		else { return .failure(.invalidResponse) }
		let nonce = Self.makeNonce()
		return await send(url: url, body: body, nonce: nonce, session: platformSession).flatMap { http, data in
			guard http.statusCode == 201 else { return .failure(Self.failure(status: http.statusCode, body: data)) }
			guard let object = Self.signedObject(http, data, nonce: nonce, principalID: platformSession.principalID),
				let id = object["authorizationId"] as? String, Self.isCanonicalUUID(id),
				let installText = object["installUrl"] as? String,
				let installURL = Self.validatedInstallURL(installText),
				let expiresText = object["expiresAt"] as? String,
				let expiresAt = Self.date(expiresText)
			else { return .failure(.invalidResponse) }
			return .success(StartedPlatformAuthorization(id: id, installURL: installURL, expiresAt: expiresAt))
		}
	}

	func redeem(
		_ authorizationID: String,
		proof: String,
		session platformSession: PlatformSession
	) async -> Result<PlatformAuthorizationOutcome, PlatformAuthorizationError> {
		guard Self.isCanonicalUUID(authorizationID), Self.isOneTimeValue(proof),
			let url = URL(
				string: "/api/vault/platforms/vercel/authorizations/\(authorizationID)/redeem",
				relativeTo: platformSession.baseURL),
			let body = try? JSONSerialization.data(withJSONObject: ["proof": proof])
		else { return .failure(.invalidResponse) }
		let nonce = Self.makeNonce()
		return await send(url: url, body: body, nonce: nonce, session: platformSession).flatMap { http, data in
			guard [200, 202, 403, 404, 409, 410].contains(http.statusCode) else {
				return .failure(Self.failure(status: http.statusCode, body: data))
			}
			// An unsigned 403 or 404 comes from authentication, before the route signs anything.
			guard let object = Self.signedObject(http, data, nonce: nonce, principalID: platformSession.principalID),
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
				guard let envelope = object["envelope"],
					let envelopeData = try? JSONSerialization.data(withJSONObject: envelope),
					let sealed = try? JSONDecoder().decode(PlatformAuthorizationEnvelope.Sealed.self, from: envelopeData)
				else { return .failure(.invalidResponse) }
				return .success(.ready(sealed))
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

	func cancel(_ authorizationID: String, session platformSession: PlatformSession) async {
		guard Self.isCanonicalUUID(authorizationID),
			let url = URL(
				string: "/api/vault/platforms/vercel/authorizations/\(authorizationID)",
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
	/// nonce, for `principalID`, about Vercel.
	private static func signedObject(
		_ http: HTTPURLResponse,
		_ data: Data,
		nonce: String,
		principalID: String
	) -> [String: Any]? {
		guard PinnedSessionDelegate.verifyResponseSignature(http, body: data, requireSignature: true),
			let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
			object["requestNonce"] as? String == nonce,
			object["principalId"] as? String == principalID,
			object["platform"] as? String == "vercel"
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
		case (429, "too_many_authorizations"): return .tooManyOpen
		case (429, _): return .rateLimited
		default: return .server(status)
		}
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

	/// Vercel's install page for an integration, and nothing else, so a
	/// signed answer can't send the browser anywhere unexpected.
	static func validatedInstallURL(_ text: String) -> URL? {
		guard text.utf8.count <= 2_048,
			let components = URLComponents(string: text),
			components.scheme == "https", components.host == "vercel.com",
			components.user == nil, components.password == nil, components.port == nil, components.fragment == nil
		else { return nil }
		let path = components.path.split(separator: "/", omittingEmptySubsequences: false)
		guard path.count == 4, path[0].isEmpty, path[1] == "integrations", path[3] == "new",
			VercelPublishTarget.isValidIdentifier(String(path[2])),
			let items = components.queryItems, items.count == 1, items[0].name == "state",
			let state = items[0].value, isOneTimeValue(state)
		else { return nil }
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
