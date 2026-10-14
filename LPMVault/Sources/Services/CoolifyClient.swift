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
	/// Coolify refused the request, with the part of its reason that's safe to show.
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

/// An application or service a Coolify team can publish to.
struct CoolifyResource: Identifiable, Equatable, Sendable {
	let kind: CoolifyPublishTarget.Resource
	/// Its UUID.
	let id: String
	let name: String
	/// The Coolify project and environment holding it; nil when Coolify didn't list them.
	let projectName: String?
	let environmentName: String?
	/// An application's build pack, such as `dockercompose`.
	let buildPack: String?
}

/// One of a resource's variables, without its value.
struct CoolifyVariable: Identifiable, Equatable, Sendable {
	/// Its UUID.
	let id: String
	let key: String
	/// Whether it belongs to an application's preview deployments.
	let isPreview: Bool
	/// Locked: Coolify shows the value once and never again.
	let isLocked: Bool
	let updatedAt: Date?
}

/// A variable to create or a value to replace. The value never appears when
/// it's printed, logged or dumped.
struct CoolifyVariableWrite: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
	let key: String
	let value: String
	let isPreview: Bool
	/// Locked, so Coolify never shows the value again.
	let isLocked: Bool

	/// Coolify keeps a value with line breaks only as a multiline one.
	var isMultiline: Bool { value.contains("\n") || value.contains("\r") }

	var description: String { "CoolifyVariableWrite(\(key), preview: \(isPreview), locked: \(isLocked), value: <redacted>)" }
	var debugDescription: String { description }
	var customMirror: Mirror { Mirror(self, children: ["key": key, "isPreview": isPreview, "isLocked": isLocked]) }
}

protocol CoolifyClientProtocol: Sendable {
	/// The token's team, which also proves the address is a Coolify instance that accepts the token.
	func team() async -> Result<CoolifyTeam, CoolifyAPIError>
	/// The team's applications and services, with the projects and environments holding them.
	func resources() async -> Result<[CoolifyResource], CoolifyAPIError>
	/// The application's build pack, such as `dockercompose`.
	func buildPack(ofApplication id: String) async -> Result<String?, CoolifyAPIError>
	/// The resource's variables, an application's preview ones included.
	func variables(of resource: CoolifyPublishTarget.Resource, id: String) async -> Result<[CoolifyVariable], CoolifyAPIError>
	/// Creates the variable and returns its UUID; Coolify refuses a key that already exists.
	func create(_ write: CoolifyVariableWrite, in resource: CoolifyPublishTarget.Resource, id: String) async -> Result<String, CoolifyAPIError>
	/// Replaces the value of the variable with the key.
	func update(_ write: CoolifyVariableWrite, in resource: CoolifyPublishTarget.Resource, id: String) async -> Result<CoolifyVariable, CoolifyAPIError>
	func delete(_ variableID: String, in resource: CoolifyPublishTarget.Resource, id: String) async -> Result<Void, CoolifyAPIError>
}

/// Coolify's REST API on one instance, with one API token. Requests go only
/// to the instance, and redirects are refused so the token never follows one.
struct CoolifyClient: CoolifyClientProtocol, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
	static let maximumAccessTokenLength = 4_096
	/// Projects whose environments are read at once.
	static let projectConcurrency = 4
	private static let maximumResponseBytes = 2 * 1024 * 1024
	/// Coolify lists whole applications, compose files included, without pages.
	private static let maximumListBytes = 16 * 1024 * 1024

	private let instance: CoolifyInstance
	private let token: String
	let session: URLSession

	/// The session clients use unless given one. A session holds its
	/// delegate until it's invalidated, so one per process serves every
	/// client and token: it keeps no cookies, cache or credentials.
	static let sharedSession = URLSession(
		configuration: BoundedHTTPResponse.ephemeralConfiguration(requestTimeout: 20, resourceTimeout: 60),
		delegate: RedirectRefusingHTTPDelegate(),
		delegateQueue: nil
	)

	init(instance: CoolifyInstance, token: String, session: URLSession? = nil) {
		self.instance = instance
		self.token = token
		self.session = session ?? Self.sharedSession
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
				let name = ProviderName.display(team.name)
			else { return .failure(.invalidResponse) }
			return .success(CoolifyTeam(id: String(team.id), name: name))
		}
	}

	// MARK: - Resources

	func resources() async -> Result<[CoolifyResource], CoolifyAPIError> {
		async let applicationList = get(["applications"], limit: Self.maximumListBytes)
		async let serviceList = get(["services"], limit: Self.maximumListBytes)
		let environments: [Int: (project: String, environment: String)]
		switch await environmentNames() {
		case .success(let value): environments = value
		case .failure(let error): return .failure(error)
		}
		let applications: [RawResource]
		let services: [RawResource]
		do {
			applications = try decode([RawResource].self, from: await applicationList.get())
			services = try decode([RawResource].self, from: await serviceList.get())
		} catch let error as CoolifyAPIError {
			return .failure(error)
		} catch {
			return .failure(.invalidResponse)
		}
		var resources: [CoolifyResource] = []
		resources.reserveCapacity(applications.count + services.count)
		for (kind, list) in [(CoolifyPublishTarget.Resource.application, applications), (.service, services)] {
			for raw in list {
				guard PlatformIdentifier.isValid(raw.uuid), let name = ProviderName.display(raw.name) ?? ProviderName.display(raw.uuid) else {
					return .failure(.invalidResponse)
				}
				let place = raw.environmentID.flatMap { environments[$0] }
				resources.append(CoolifyResource(
					kind: kind, id: raw.uuid, name: name, projectName: place?.project, environmentName: place?.environment,
					buildPack: kind == .application ? raw.buildPack : nil))
			}
		}
		return .success(resources)
	}

	func buildPack(ofApplication id: String) async -> Result<String?, CoolifyAPIError> {
		guard PlatformIdentifier.isValid(id) else { return .failure(.invalidResponse) }
		return await get(["applications", id], limit: Self.maximumListBytes).flatMap { data in
			guard let application = try? JSONDecoder().decode(RawResource.self, from: data), application.uuid == id else {
				return .failure(.invalidResponse)
			}
			return .success(application.buildPack)
		}
	}

	/// Each environment's project and name, by the environment's ID.
	private func environmentNames() async -> Result<[Int: (project: String, environment: String)], CoolifyAPIError> {
		let projects: [RawProject]
		do {
			projects = try decode([RawProject].self, from: await get(["projects"], limit: Self.maximumListBytes).get())
		} catch let error as CoolifyAPIError {
			return .failure(error)
		} catch {
			return .failure(.invalidResponse)
		}
		guard projects.allSatisfy({ PlatformIdentifier.isValid($0.uuid) }) else { return .failure(.invalidResponse) }
		return await withTaskGroup(of: Result<RawProject, CoolifyAPIError>.self) { group in
			var pending = projects[...]
			func startNext() {
				guard let project = pending.popFirst() else { return }
				group.addTask {
					await get(["projects", project.uuid], limit: Self.maximumListBytes).flatMap { data in
						(try? JSONDecoder().decode(RawProject.self, from: data)).map(Result.success) ?? .failure(.invalidResponse)
					}
				}
			}
			for _ in 0..<Self.projectConcurrency { startNext() }
			var names: [Int: (project: String, environment: String)] = [:]
			while let result = await group.next() {
				switch result {
				case .success(let project):
					let projectName = ProviderName.display(project.name) ?? project.uuid
					for environment in project.environments ?? [] {
						names[environment.id] = (projectName, ProviderName.display(environment.name) ?? String(environment.id))
					}
					startNext()
				case .failure(let error):
					group.cancelAll()
					return .failure(error)
				}
			}
			return .success(names)
		}
	}

	// MARK: - Variables

	func variables(of resource: CoolifyPublishTarget.Resource, id: String) async -> Result<[CoolifyVariable], CoolifyAPIError> {
		guard PlatformIdentifier.isValid(id) else { return .failure(.invalidResponse) }
		return await get([Self.collection(resource), id, "envs"], limit: Self.maximumListBytes).flatMap { data in
			guard let raw = try? JSONDecoder().decode([RawVariable].self, from: data) else { return .failure(.invalidResponse) }
			var variables: [CoolifyVariable] = []
			variables.reserveCapacity(raw.count)
			for item in raw {
				guard let variable = item.variable else { return .failure(.invalidResponse) }
				variables.append(variable)
			}
			return .success(variables)
		}
	}

	func create(_ write: CoolifyVariableWrite, in resource: CoolifyPublishTarget.Resource, id: String) async -> Result<String, CoolifyAPIError> {
		guard PlatformIdentifier.isValid(id), let body = Self.body(write, for: resource) else { return .failure(.invalidResponse) }
		return await send("POST", [Self.collection(resource), id, "envs"], body: body).flatMap { data in
			// An application answers with the new variable's UUID only; a service with the whole variable.
			guard let created = try? JSONDecoder().decode(Created.self, from: data), PlatformIdentifier.isValid(created.uuid) else {
				return .failure(.invalidResponse)
			}
			return .success(created.uuid)
		}
	}

	func update(_ write: CoolifyVariableWrite, in resource: CoolifyPublishTarget.Resource, id: String) async -> Result<CoolifyVariable, CoolifyAPIError> {
		guard PlatformIdentifier.isValid(id), let body = Self.body(write, for: resource) else { return .failure(.invalidResponse) }
		return await send("PATCH", [Self.collection(resource), id, "envs"], body: body).flatMap { data in
			guard let updated = (try? JSONDecoder().decode(RawVariable.self, from: data))?.variable,
				updated.key == write.key, updated.isPreview == write.isPreview
			else { return .failure(.invalidResponse) }
			return .success(updated)
		}
	}

	func delete(_ variableID: String, in resource: CoolifyPublishTarget.Resource, id: String) async -> Result<Void, CoolifyAPIError> {
		guard PlatformIdentifier.isValid(id), PlatformIdentifier.isValid(variableID) else { return .failure(.invalidResponse) }
		return await send("DELETE", [Self.collection(resource), id, "envs", variableID], body: nil).map { _ in () }
	}

	private static func collection(_ resource: CoolifyPublishTarget.Resource) -> String {
		switch resource {
		case .application: "applications"
		case .service: "services"
		}
	}

	/// Every flag Coolify would otherwise reset is sent. Values are literal,
	/// so Coolify passes `$` on instead of reading it as another variable;
	/// whether the variable is used at build time or run time is left as Coolify has it.
	private static func body(_ write: CoolifyVariableWrite, for resource: CoolifyPublishTarget.Resource) -> [String: Any]? {
		guard EnvValidation.isValidVariableName(write.key), resource == .application || !write.isPreview else { return nil }
		var body: [String: Any] = [
			"key": write.key,
			"value": write.value,
			"is_literal": true,
			"is_multiline": write.isMultiline,
			"is_shown_once": write.isLocked,
		]
		// A service has no preview deployments, and Coolify would store the flag as given.
		if resource == .application { body["is_preview"] = write.isPreview }
		return body
	}

	// MARK: - Requests

	private func get(_ path: [String], limit: Int = maximumResponseBytes) async -> Result<Data, CoolifyAPIError> {
		guard let url = instance.url(path) else { return .failure(.invalidResponse) }
		return await load(URLRequest(url: url), limit: limit)
	}

	private func send(_ method: String, _ path: [String], body: [String: Any]?) async -> Result<Data, CoolifyAPIError> {
		guard let url = instance.url(path) else { return .failure(.invalidResponse) }
		var request = URLRequest(url: url)
		request.httpMethod = method
		if let body {
			guard let data = try? JSONSerialization.data(withJSONObject: body) else { return .failure(.invalidResponse) }
			request.httpBody = data
			request.setValue("application/json", forHTTPHeaderField: "Content-Type")
		}
		return await load(request, limit: Self.maximumResponseBytes)
	}

	private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
		do {
			return try JSONDecoder().decode(type, from: data)
		} catch {
			throw CoolifyAPIError.invalidResponse
		}
	}

	private func load(_ request: URLRequest, limit: Int = maximumResponseBytes) async -> Result<Data, CoolifyAPIError> {
		guard Self.isValidAccessToken(token) else { return .failure(.unauthorized) }
		var request = request
		// Without it, Laravel answers a refused token with a redirect to its sign-in page.
		request.setValue("application/json", forHTTPHeaderField: "Accept")
		request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
		do {
			let (data, response) = try await BoundedHTTPResponse.load(for: request, using: session, maximumBytes: limit)
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
		let response = try? JSONDecoder().decode(ErrorResponse.self, from: data)
		let message = response?.message.flatMap(sanitized)
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
		case 400, 422: return .rejected(rejection(message, fields: response?.errors.map { Array($0.keys) } ?? []))
		default: return .server(status)
		}
	}

	/// Coolify's own fixed refusals, which are safe to show.
	private static let knownRefusals: Set<String> = ["Validation failed.", "Bulk data is required.", "UUID is required."]
	/// Fields LPM Vault sends, which a validation refusal can name.
	private static let knownFields: Set<String> = ["key", "value", "is_preview", "is_literal", "is_multiline", "is_shown_once", "comment"]

	/// A refusal's reason, from Coolify's fixed messages and the names of the
	/// fields it refused only. Any other text could echo what was sent, such
	/// as a value or the token.
	private static func rejection(_ message: String?, fields: [String]) -> String {
		let named = Set(fields).intersection(knownFields).sorted()
		let parts = [message.flatMap { knownRefusals.contains($0) ? $0 : nil }, named.isEmpty ? nil : "(\(named.joined(separator: ", ")))"]
		return parts.compactMap { $0 }.joined(separator: " ")
	}

	/// A short single-line text from Coolify, safe to show.
	private static func sanitized(_ text: String) -> String? {
		let line = String(text.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(300))
		return line.isEmpty ? nil : line
	}

	/// Laravel's timestamps, such as `2026-10-14T12:34:56.123456Z`, in UTC.
	static func timestamp(_ text: String) -> Date? {
		let bytes = Array(text.utf8)
		func number(_ range: Range<Int>) -> Int? {
			guard range.upperBound <= bytes.count, bytes[range].allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else { return nil }
			return bytes[range].reduce(0) { $0 * 10 + Int($1 - 0x30) }
		}
		guard bytes.count >= 20, bytes[4] == 0x2D, bytes[7] == 0x2D, bytes[10] == 0x54 || bytes[10] == 0x20,
			bytes[13] == 0x3A, bytes[16] == 0x3A,
			let year = number(0..<4), let month = number(5..<7), let day = number(8..<10),
			let hour = number(11..<13), let minute = number(14..<16), let second = number(17..<19)
		else { return nil }
		var index = 19
		var fraction = 0.0
		if bytes[index] == 0x2E {
			index += 1
			var scale = 0.1
			let start = index
			while index < bytes.count, bytes[index] >= 0x30, bytes[index] <= 0x39 {
				fraction += Double(bytes[index] - 0x30) * scale
				scale /= 10
				index += 1
			}
			guard index > start else { return nil }
		}
		guard bytes[index...].elementsEqual("Z".utf8) || bytes[index...].elementsEqual("+00:00".utf8) else { return nil }
		var calendar = Calendar(identifier: .gregorian)
		calendar.timeZone = TimeZone(identifier: "UTC")!
		let components = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
		guard components.isValidDate(in: calendar), let date = calendar.date(from: components) else { return nil }
		return date.addingTimeInterval(fraction)
	}

	// MARK: - Wire types

	private struct Team: Decodable {
		let id: Int
		let name: String?
	}

	private struct RawProject: Decodable {
		struct Environment: Decodable {
			let id: Int
			let name: String?
		}
		let uuid: String
		let name: String?
		let environments: [Environment]?
	}

	private struct RawResource: Decodable {
		let uuid: String
		let name: String?
		let environmentID: Int?
		let buildPack: String?

		private enum CodingKeys: String, CodingKey {
			case uuid, name
			case environmentID = "environment_id"
			case buildPack = "build_pack"
		}
	}

	private struct Created: Decodable {
		let uuid: String
	}

	/// A variable as Coolify lists it. Its value, which a token allowed to
	/// read sensitive data would also get, is never decoded.
	private struct RawVariable: Decodable {
		let uuid: String?
		let key: String
		let isPreview: Bool
		let isShownOnce: Bool
		let updatedAt: String?

		private enum CodingKeys: String, CodingKey {
			case uuid, key
			case isPreview = "is_preview"
			case isShownOnce = "is_shown_once"
			case updatedAt = "updated_at"
		}

		init(from decoder: Decoder) throws {
			let container = try decoder.container(keyedBy: CodingKeys.self)
			uuid = try container.decodeIfPresent(String.self, forKey: .uuid)
			key = try container.decode(String.self, forKey: .key)
			isPreview = try Self.flag(container, .isPreview)
			isShownOnce = try Self.flag(container, .isShownOnce)
			updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt)
		}

		/// A flag Coolify sends as a boolean, or as 0 or 1 from a column it doesn't cast.
		private static func flag(_ container: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) throws -> Bool {
			if let value = try? container.decodeIfPresent(Bool.self, forKey: key) { return value }
			switch try container.decodeIfPresent(Int.self, forKey: key) {
			case nil, 0?: return false
			case 1?: return true
			default: throw CoolifyAPIError.invalidResponse
			}
		}

		var variable: CoolifyVariable? {
			guard let uuid, PlatformIdentifier.isValid(uuid), !key.isEmpty, key.utf8.count <= 1_024 else { return nil }
			let updated: Date?
			if let updatedAt {
				guard let date = CoolifyClient.timestamp(updatedAt) else { return nil }
				updated = date
			} else {
				updated = nil
			}
			return CoolifyVariable(id: uuid, key: key, isPreview: isPreview, isLocked: isShownOnce, updatedAt: updated)
		}
	}

	private struct ErrorResponse: Decodable {
		let message: String?
		let errors: [String: [String]]?

		private enum CodingKeys: String, CodingKey { case message, errors }

		init(from decoder: Decoder) throws {
			let container = try decoder.container(keyedBy: CodingKeys.self)
			message = try? container.decodeIfPresent(String.self, forKey: .message)
			errors = try? container.decodeIfPresent([String: [String]].self, forKey: .errors)
		}
	}
}
