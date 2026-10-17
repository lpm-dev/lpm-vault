import CryptoKit
import Foundation
@testable import LPMVault

/// Answers requests for hosts registered by tests. Each registration gets
/// its own host, so tests running in parallel never see each other's requests.
final class PlatformHTTPStub: URLProtocol {
	struct Request: Sendable {
		let method: String
		let url: URL
		let headers: [String: String]
		let body: Data

		func header(_ name: String) -> String? {
			headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
		}

		var json: [String: Any]? { try? JSONSerialization.jsonObject(with: body) as? [String: Any] }
		var query: [String: String] {
			Dictionary(
				(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") },
				uniquingKeysWith: { first, _ in first })
		}
	}

	struct Reply: Sendable {
		var status: Int
		var headers: [String: String] = ["Content-Type": "application/json"]
		var body: Data

		static func json(_ status: Int, _ object: Any, headers: [String: String] = [:]) -> Reply {
			var reply = Reply(status: status, body: (try? JSONSerialization.data(withJSONObject: object)) ?? Data())
			reply.headers.merge(headers) { _, new in new }
			return reply
		}
	}

	typealias Handler = @Sendable (Request) -> Reply

	final class Route: @unchecked Sendable {
		let baseURL: URL
		let session: URLSession
		private let lock = NSLock()
		private var log: [Request] = []
		fileprivate let handler: Handler

		fileprivate init(baseURL: URL, session: URLSession, handler: @escaping Handler) {
			self.baseURL = baseURL
			self.session = session
			self.handler = handler
		}

		var requests: [Request] { lock.withLock { log } }
		fileprivate func record(_ request: Request) { lock.withLock { log.append(request) } }
	}

	private static let lock = NSLock()
	nonisolated(unsafe) private static var routes: [String: Route] = [:]
	nonisolated(unsafe) private static var nextPort = 41_000

	/// A route on `http://localhost:<port>`, where DEBUG builds accept the test signing key.
	static func registry(delegate: BoundedHTTPResponseDelegate = BoundedHTTPResponseDelegate(), _ handler: @escaping Handler) -> Route {
		let port = lock.withLock {
			defer { nextPort += 1 }
			return nextPort
		}
		return register(URL(string: "http://localhost:\(port)")!, delegate: delegate, handler)
	}

	/// A route on a unique https host standing in for a platform's API.
	static func platform(delegate: BoundedHTTPResponseDelegate = RedirectRefusingHTTPDelegate(), _ handler: @escaping Handler) -> Route {
		register(URL(string: "https://api-\(UUID().uuidString.lowercased()).vercel.test")!, delegate: delegate, handler)
	}

	/// A route on a unique https host standing in for a Coolify instance.
	static func coolify(_ handler: @escaping Handler) -> Route {
		register(URL(string: "https://coolify-\(UUID().uuidString.lowercased()).test")!, delegate: RedirectRefusingHTTPDelegate(), handler)
	}

	private static func register(_ baseURL: URL, delegate: BoundedHTTPResponseDelegate, _ handler: @escaping Handler) -> Route {
		let configuration = BoundedHTTPResponse.ephemeralConfiguration(requestTimeout: testWaitSeconds, resourceTimeout: testWaitSeconds)
		configuration.protocolClasses = [PlatformHTTPStub.self]
		let route = Route(
			baseURL: baseURL,
			session: URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil),
			handler: handler)
		lock.withLock { routes[key(baseURL)] = route }
		return route
	}

	private static func key(_ url: URL) -> String {
		"\(url.host() ?? ""):\(url.port ?? -1)"
	}

	override class func canInit(with request: URLRequest) -> Bool { true }
	override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

	override func startLoading() {
		guard let url = request.url, let route = Self.lock.withLock({ Self.routes[Self.key(url)] }) else {
			client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
			return
		}
		let recorded = Request(
			method: request.httpMethod ?? "GET",
			url: url,
			headers: request.allHTTPHeaderFields ?? [:],
			body: request.httpBody ?? request.httpBodyStream.map(Self.read) ?? Data())
		route.record(recorded)
		let reply = route.handler(recorded)
		guard let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers) else {
			client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
			return
		}
		client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
		client?.urlProtocol(self, didLoad: reply.body)
		client?.urlProtocolDidFinishLoading(self)
	}

	override func stopLoading() {}

	private static func read(_ stream: InputStream) -> Data {
		stream.open()
		defer { stream.close() }
		var data = Data()
		var buffer = [UInt8](repeating: 0, count: 4_096)
		while stream.hasBytesAvailable {
			let count = stream.read(&buffer, maxLength: buffer.count)
			guard count > 0 else { break }
			data.append(buffer, count: count)
		}
		return data
	}
}

/// Signs Registry answers the way it does, with RFC 8032's first test key,
/// which DEBUG builds trust only for responses from localhost.
enum RegistryTestSigner {
	static let keyID = "vault-test-rfc8032"
	private static let key = try! Curve25519.Signing.PrivateKey(rawRepresentation: Data([
		0x9d, 0x61, 0xb1, 0x9d, 0xef, 0xfd, 0x5a, 0x60, 0xba, 0x84, 0x4a, 0xf4, 0x92, 0xec, 0x2c, 0xc4,
		0x44, 0x49, 0xc5, 0x69, 0x7b, 0x32, 0x69, 0x19, 0x70, 0x3b, 0xac, 0x03, 0x1c, 0xae, 0x7f, 0x60,
	]))

	static func signed(_ status: Int, _ object: Any) -> PlatformHTTPStub.Reply {
		let body = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
		var frame = Data("lpm-authenticated-response\0".utf8)
		frame.append(4)
		withUnsafeBytes(of: UInt16(status).bigEndian) { frame.append(contentsOf: $0) }
		frame.append(UInt8(keyID.utf8.count))
		frame.append(contentsOf: keyID.utf8)
		withUnsafeBytes(of: UInt64(body.count).bigEndian) { frame.append(contentsOf: $0) }
		frame.append(contentsOf: SHA256.hash(data: body))
		let signature = try! key.signature(for: frame)
		return PlatformHTTPStub.Reply(
			status: status,
			headers: [
				"Content-Type": "application/json",
				"X-LPM-Response-Key-ID": keyID,
				"X-LPM-Response-Signature": PlatformAuthorizationClient.base64URL(signature),
			],
			body: body)
	}
}

/// Seals a grant the way the Registry's `sealAuthorizationResult` does.
enum RegistryTestSealer {
	static func seal(_ payload: [String: Any], authorizationID: String, to clientPublicKey: Data) throws -> PlatformAuthorizationEnvelope.Sealed {
		let client = try P256.KeyAgreement.PublicKey(x963Representation: clientPublicKey)
		let ephemeral = P256.KeyAgreement.PrivateKey()
		let shared = try ephemeral.sharedSecretFromKeyAgreement(with: client)
		let domain = Data(PlatformAuthorizationEnvelope.domain.utf8) + [0]
		let key = shared.hkdfDerivedSymmetricKey(
			using: SHA256.self,
			salt: Data(authorizationID.utf8),
			sharedInfo: domain + clientPublicKey + ephemeral.publicKey.x963Representation,
			outputByteCount: 32)
		let box = try AES.GCM.seal(
			try JSONSerialization.data(withJSONObject: payload), using: key,
			authenticating: domain + Data(authorizationID.utf8))
		return PlatformAuthorizationEnvelope.Sealed(
			version: 1,
			ephemeralPublicKey: ephemeral.publicKey.x963Representation.base64EncodedString(),
			nonce: Data(box.nonce).base64EncodedString(),
			ciphertext: (box.ciphertext + box.tag).base64EncodedString())
	}
}

extension PlatformAuthorizationEnvelope.Sealed {
	var json: [String: Any] {
		["version": version, "ephemeralPublicKey": ephemeralPublicKey, "nonce": nonce, "ciphertext": ciphertext]
	}
}

let platformTestPrincipal = "user_lpm_0001"

func platformTestSession(_ baseURL: URL) -> PlatformSession {
	PlatformSession(token: "lpm_session_token", principalID: platformTestPrincipal, baseURL: baseURL)
}

/// The query of a return to the Mac's listener, signed as a local Registry
/// signs it: with the RFC 8032 test key.
func platformTestReturn(authorization: String, proof: String? = nil, error: String? = nil, next: String? = nil) -> String {
	let outcome: PlatformConnectionListener.Outcome = proof.map { .proof($0) } ?? .error(error ?? "")
	let keyID = "vault-test-rfc8032"
	let seed = Data(base64Encoded: "nWGxne/9WmC6hEr0kuwsxERJxWl7MmkZcDusAxyuf2A=")!
	let message = PlatformConnectionListener.signedMessage(authorizationID: authorization, outcome: outcome, next: next, keyID: keyID)!
	let signature = try! Curve25519.Signing.PrivateKey(rawRepresentation: seed).signature(for: message)
	var query = URLComponents()
	query.queryItems = [URLQueryItem(name: "authorization", value: authorization)]
		+ (proof.map { [URLQueryItem(name: "proof", value: $0)] } ?? [URLQueryItem(name: "error", value: error)])
		+ (next.map { [URLQueryItem(name: "next", value: $0)] } ?? [])
		+ [URLQueryItem(name: "key", value: keyID), URLQueryItem(name: "signature", value: PlatformAuthorizationClient.base64URL(signature))]
	return query.percentEncodedQuery!
}

/// The Registry a test signs its returns as, which trusts the test key.
let platformTestRegistry = URL(string: "http://127.0.0.1:3000")!

func platformTestOneTimeValue() -> String {
	PlatformAuthorizationClient.base64URL(SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) })
}
