import Foundation

enum CoolifyAPIError: Error, Equatable, Sendable {
	/// The token doesn't work: it was revoked or mistyped, or its user left the team.
	case unauthorized
	/// The instance has its API turned off.
	case apiDisabled
	/// The instance accepts API requests only from allowed IP addresses.
	case addressNotAllowed
	/// The token lacks a permission the request needs, such as write.
	case missingPermission
	/// The token has permissions its user's team role doesn't allow: only
	/// admins and owners can use more than read.
	case roleTooLow
	case forbidden
	case notFound
	/// A variable with the key already exists.
	case conflict
	case rateLimited
	/// Coolify refused the request, with its reason.
	case rejected(String)
	/// The address answered with a redirect, which is never followed.
	case redirected
	/// The instance's certificate isn't one this Mac trusts.
	case untrustedCertificate
	case transport
	case cancelled
	case invalidResponse
	case server(Int)
}

/// A Coolify instance's address. Its API lives under `/api/v1`. Tokens go
/// only over HTTPS, or over plain HTTP to this Mac itself, as through an SSH tunnel.
struct CoolifyInstance: Hashable, Sendable, CustomStringConvertible {
	enum Problem: Error, Equatable, Sendable {
		case invalid
		/// Plain HTTP to another machine would send the token unencrypted.
		case insecure
	}

	/// `scheme://host[:port]`, lowercased, without a default port or a path.
	let origin: String

	private init(canonical origin: String) {
		self.origin = origin
	}

	/// A stored origin, which must already be in its canonical form.
	init?(origin text: String) {
		guard case .success(let instance) = Self.parse(text), instance.origin == text else { return nil }
		self = instance
	}

	/// The address the person typed. The scheme defaults to https, and a
	/// path to the API itself is accepted, since that's what Coolify's
	/// documentation shows.
	static func parse(_ text: String) -> Result<CoolifyInstance, Problem> {
		var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !text.isEmpty, text.utf8.count <= 2_048 else { return .failure(.invalid) }
		if !text.contains("://") { text = "https://" + text }
		guard let components = URLComponents(string: text),
			let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http",
			components.user == nil, components.password == nil, components.query == nil, components.fragment == nil,
			["", "/", "/api", "/api/", "/api/v1", "/api/v1/"].contains(components.percentEncodedPath),
			let host = components.percentEncodedHost?.lowercased(), isValidHost(host)
		else { return .failure(.invalid) }
		if let port = components.port, !(1...65_535).contains(port) { return .failure(.invalid) }
		guard scheme == "https" || isLoopback(host) else { return .failure(.insecure) }
		let defaultPort = scheme == "https" ? 443 : 80
		var origin = "\(scheme)://\(host)"
		if let port = components.port, port != defaultPort { origin += ":\(port)" }
		return .success(CoolifyInstance(canonical: origin))
	}

	/// The host and any port, for display.
	var address: String {
		origin.components(separatedBy: "://").last ?? origin
	}

	var description: String { origin }

	/// The API URL for `path`, whose parts are already safe to put in a path.
	func url(_ path: [String], query: [URLQueryItem] = []) -> URL? {
		guard var components = URLComponents(string: origin) else { return nil }
		components.percentEncodedPath = "/api/v1/" + path.joined(separator: "/")
		components.queryItems = query.isEmpty ? nil : query
		return components.url
	}

	/// A DNS name, an IPv4 address, or a bracketed IPv6 address.
	private static func isValidHost(_ host: String) -> Bool {
		guard !host.isEmpty, host.utf8.count <= 253 else { return false }
		if host.hasPrefix("[") {
			return host.hasSuffix("]") && host.utf8.count > 2
				&& host.utf8.dropFirst().dropLast().allSatisfy { isHexDigit($0) || $0 == 0x3A || $0 == 0x2E }
		}
		let labels = host.split(separator: ".", omittingEmptySubsequences: false)
		return labels.allSatisfy { label in
			!label.isEmpty && label.utf8.count <= 63 && label.utf8.first != 0x2D && label.utf8.last != 0x2D
				&& label.utf8.allSatisfy { isLowercaseAlphanumeric($0) || $0 == 0x2D || $0 == 0x5F }
		}
	}

	private static func isLoopback(_ host: String) -> Bool {
		if host == "localhost" || host == "[::1]" { return true }
		let octets = host.split(separator: ".", omittingEmptySubsequences: false)
		return octets.count == 4 && octets[0] == "127"
			&& octets.allSatisfy { $0.utf8.allSatisfy(isDigit) && UInt8($0) != nil }
	}

	private static func isDigit(_ byte: UInt8) -> Bool { byte >= 0x30 && byte <= 0x39 }
	private static func isHexDigit(_ byte: UInt8) -> Bool { isDigit(byte) || (byte >= 0x61 && byte <= 0x66) }
	private static func isLowercaseAlphanumeric(_ byte: UInt8) -> Bool { isDigit(byte) || (byte >= 0x61 && byte <= 0x7A) }
}

/// The Coolify team an API token belongs to: the team that was current
/// when its user created it.
struct CoolifyTeam: Equatable, Sendable {
	/// Coolify's numeric ID for the team, as decimal digits.
	let id: String
	let name: String

	/// A team ID that can only be digits, so it's safe in a request path or a Keychain account.
	static func isValidID(_ text: String) -> Bool {
		!text.isEmpty && text.utf8.count <= 20 && text.utf8.allSatisfy { $0 >= 0x30 && $0 <= 0x39 }
	}
}

protocol CoolifyClientProtocol: Sendable {
	/// The token's team, which also proves the address is a Coolify instance that accepts the token.
	func team() async -> Result<CoolifyTeam, CoolifyAPIError>
}

/// Coolify's REST API on one instance, with one API token. Requests go only
/// to the instance, and redirects are refused so the token never follows one.
struct CoolifyClient: CoolifyClientProtocol, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
	static let maximumAccessTokenLength = 4_096
	private static let maximumResponseBytes = 2 * 1024 * 1024

	private let instance: CoolifyInstance
	private let token: String
	private let session: URLSession

	init(instance: CoolifyInstance, token: String, session: URLSession? = nil) {
		self.instance = instance
		self.token = token
		self.session = session ?? URLSession(
			configuration: BoundedHTTPResponse.ephemeralConfiguration(requestTimeout: 20, resourceTimeout: 60),
			delegate: RedirectRefusingHTTPDelegate(),
			delegateQueue: nil
		)
	}

	/// Printable ASCII without spaces, as Coolify issues them.
	static func isValidAccessToken(_ token: String) -> Bool {
		!token.isEmpty && token.utf8.count <= maximumAccessTokenLength
			&& token.utf8.allSatisfy { $0 >= 0x21 && $0 <= 0x7E }
	}

	var description: String { "CoolifyClient(\(instance.origin), token: <redacted>)" }
	var debugDescription: String { description }
	var customMirror: Mirror { Mirror(self, children: ["instance": instance.origin]) }

	// MARK: - Team

	func team() async -> Result<CoolifyTeam, CoolifyAPIError> {
		var response = await get(["team"])
		// Coolify before 4.3 names the token's team only by its older path.
		if case .failure(.notFound) = response {
			response = await get(["teams", "current"])
		}
		return response.flatMap { data in
			guard let team = try? JSONDecoder().decode(Team.self, from: data), team.id >= 0,
				let name = Self.displayName(team.name)
			else { return .failure(.invalidResponse) }
			return .success(CoolifyTeam(id: String(team.id), name: name))
		}
	}

	// MARK: - Requests

	private func get(_ path: [String]) async -> Result<Data, CoolifyAPIError> {
		guard let url = instance.url(path) else { return .failure(.invalidResponse) }
		return await load(URLRequest(url: url))
	}

	private func load(_ request: URLRequest) async -> Result<Data, CoolifyAPIError> {
		guard Self.isValidAccessToken(token) else { return .failure(.unauthorized) }
		var request = request
		// Without it, Laravel answers a refused token with a redirect to its sign-in page.
		request.setValue("application/json", forHTTPHeaderField: "Accept")
		request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
		do {
			let (data, response) = try await BoundedHTTPResponse.load(for: request, using: session, maximumBytes: Self.maximumResponseBytes)
			guard let http = response as? HTTPURLResponse else { return .failure(.invalidResponse) }
			guard (200..<300).contains(http.statusCode) else { return .failure(Self.failure(http.statusCode, data)) }
			return .success(data)
		} catch is BoundedHTTPResponse.LoadError {
			return .failure(.invalidResponse)
		} catch is CancellationError {
			return .failure(.cancelled)
		} catch let error as URLError {
			switch error.code {
			case .cancelled: return .failure(.cancelled)
			case .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot,
				.serverCertificateNotYetValid, .clientCertificateRejected, .secureConnectionFailed:
				return .failure(.untrustedCertificate)
			default: return .failure(.transport)
			}
		} catch {
			return .failure(.transport)
		}
	}

	/// Coolify tells its refusals apart only by their messages.
	private static func failure(_ status: Int, _ data: Data) -> CoolifyAPIError {
		let message = (try? JSONDecoder().decode(ErrorResponse.self, from: data))?.message.flatMap(sanitized)
		switch status {
		case 300..<400: return .redirected
		case 400 where message == "Invalid token.": return .unauthorized
		case 401: return .unauthorized
		case 403:
			switch message {
			case "API is disabled."?: return .apiDisabled
			case "You are not allowed to access the API."?: return .addressNotAllowed
			case let text? where text.hasPrefix("Missing required permissions"): return .missingPermission
			case let text? where text.contains("exceed your current role") || text == "Missing required team role.": return .roleTooLow
			default: return .forbidden
			}
		case 404: return .notFound
		case 409: return .conflict
		case 429: return .rateLimited
		case 400, 422: return .rejected(message ?? "")
		default: return .server(status)
		}
	}

	/// A short single-line text from Coolify, safe to show.
	private static func sanitized(_ text: String) -> String? {
		let line = String(text.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(300))
		return line.isEmpty ? nil : line
	}

	static func displayName(_ text: String?) -> String? {
		guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
			text.utf8.count <= 512, !text.unicodeScalars.contains(where: { $0.properties.generalCategory == .control })
		else { return nil }
		return text
	}

	// MARK: - Wire types

	private struct Team: Decodable {
		let id: Int
		let name: String?
	}

	private struct ErrorResponse: Decodable {
		let message: String?
	}
}
