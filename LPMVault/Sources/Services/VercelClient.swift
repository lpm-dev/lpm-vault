import Foundation

enum VercelAPIError: Error, Equatable, Sendable {
	/// The token no longer works, as after the integration is removed on Vercel.
	case unauthorized
	/// The token can't reach this team, project or variable.
	case forbidden
	case notFound
	case rateLimited(until: Date?)
	/// Vercel refused the change, with its error code.
	case rejected(code: String)
	/// Vercel listed the variables across pages, so a review would be incomplete.
	case incompleteList
	case transport
	case cancelled
	case invalidResponse
	case server(Int)
}

/// The Vercel account a connection reaches: a team, or a personal account.
struct VercelAccount: Equatable, Sendable {
	let name: String
	let slug: String?
}

struct VercelProject: Identifiable, Equatable, Sendable {
	let id: String
	let name: String
	/// The team, or for a personal account the user, that owns the project.
	let accountID: String
}

struct VercelCustomEnvironment: Identifiable, Equatable, Sendable {
	let id: String
	let slug: String
}

/// One of a project's environment variables, without its value.
struct VercelEnvironmentVariable: Identifiable, Equatable, Sendable {
	enum Kind: Equatable, Sendable {
		case plain
		case encrypted
		/// Stored so it can't be read back, by anyone.
		case sensitive
		case secret
		case system
		case other(String)

		init(_ text: String) {
			switch text {
			case "plain": self = .plain
			case "encrypted": self = .encrypted
			case "sensitive": self = .sensitive
			case "secret": self = .secret
			case "system": self = .system
			default: self = .other(text)
			}
		}
	}

	enum Target: String, CaseIterable, Sendable {
		case production
		case preview
		case development
	}

	let id: String
	let key: String
	let kind: Kind
	/// Whether Vercel keeps the value write-only: its Secret type, or a
	/// Sensitive variable from before Vercel named the types.
	let isSecret: Bool
	let targets: Set<Target>
	let customEnvironmentIDs: Set<String>
	/// Set when the variable applies only to Preview deployments of one branch.
	let gitBranch: String?
	let updatedAt: Date?
}

struct VercelVariableList: Equatable, Sendable {
	let variables: [VercelEnvironmentVariable]
	/// Production variables the token isn't allowed to see.
	let hiddenProductionCount: Int
}

/// A variable to create or a value to replace. The value never appears when
/// it's printed, logged or dumped.
struct VercelVariableWrite: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
	enum Storage: String, Sendable {
		/// Readable by the team on Vercel.
		case encrypted
		/// Write-only: no one can read it back.
		case sensitive

		/// Vercel's Config or Secret type, which it requires alongside `type`.
		var visibility: String {
			switch self {
			case .encrypted: "config"
			case .sensitive: "secret"
			}
		}
	}

	let key: String
	let value: String
	let storage: Storage
	let targets: Set<VercelEnvironmentVariable.Target>
	let customEnvironmentIDs: Set<String>

	var description: String { "VercelVariableWrite(\(key), \(storage.rawValue), value: <redacted>)" }
	var debugDescription: String { description }
	var customMirror: Mirror {
		Mirror(self, children: ["key": key, "storage": storage.rawValue, "targets": targets.map(\.rawValue).sorted()])
	}
}

protocol VercelClientProtocol: Sendable {
	func account(teamID: String?) async -> Result<VercelAccount, VercelAPIError>
	/// The account's projects; `ownerID` is the team, or for a personal account the user, that must own each.
	func projects(teamID: String?, ownerID: String) async -> Result<[VercelProject], VercelAPIError>
	func customEnvironments(projectID: String, teamID: String?) async -> Result<[VercelCustomEnvironment], VercelAPIError>
	func variables(projectID: String, teamID: String?) async -> Result<VercelVariableList, VercelAPIError>
	/// Creates the variables, in batches; each key's own result, or one
	/// failure when no batch could be sent.
	func create(
		_ writes: [VercelVariableWrite],
		projectID: String,
		teamID: String?
	) async -> Result<[String: Result<VercelEnvironmentVariable, VercelAPIError>], VercelAPIError>
	/// Replaces the value of the variable with this ID, which must still be named `key`.
	func replace(
		_ variableID: String,
		key: String,
		value: String,
		storage: VercelVariableWrite.Storage,
		projectID: String,
		teamID: String?
	) async -> Result<VercelEnvironmentVariable, VercelAPIError>
}

/// Vercel's REST API with one connection's access token. Requests go only
/// to `baseURL`, and redirects are refused so the token never follows one.
struct VercelClient: VercelClientProtocol, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
	static let defaultBaseURL = URL(string: "https://api.vercel.com")!
	static let projectPageSize = 50
	static let maximumProjectPages = 200
	private static let maximumPageBytes = 8 * 1024 * 1024
	private static let maximumResponseBytes = 2 * 1024 * 1024

	private let token: String
	private let baseURL: URL
	let session: URLSession

	/// The session clients use unless given one. A session holds its
	/// delegate until it's invalidated, so one per process serves every
	/// client and token: it keeps no cookies, cache or credentials.
	static let sharedSession = URLSession(
		configuration: BoundedHTTPResponse.ephemeralConfiguration(requestTimeout: 20, resourceTimeout: 60),
		delegate: RedirectRefusingHTTPDelegate(),
		delegateQueue: nil
	)

	/// How much listing an account's projects may read.
	struct Limits: Sendable {
		/// Everything one listing reads, in bytes.
		var projectBytes = 64 * 1024 * 1024
		/// How long one listing may take, every page included.
		var projectDeadline: Duration = .seconds(120)
	}

	private let limits: Limits

	init(token: String, baseURL: URL = VercelClient.defaultBaseURL, session: URLSession? = nil, limits: Limits = Limits()) {
		self.token = token
		self.baseURL = baseURL
		self.session = session ?? Self.sharedSession
		self.limits = limits
	}

	var description: String { "VercelClient(\(baseURL.host() ?? "?"), token: <redacted>)" }
	var debugDescription: String { description }
	var customMirror: Mirror { Mirror(self, children: ["baseURL": baseURL]) }

	// MARK: - Account and projects

	func account(teamID: String?) async -> Result<VercelAccount, VercelAPIError> {
		if let teamID {
			guard VercelPublishTarget.isValidIdentifier(teamID) else { return .failure(.invalidResponse) }
			return await get(["v2", "teams", teamID], query: [], limit: Self.maximumResponseBytes).flatMap { data in
				guard let team = try? JSONDecoder().decode(Team.self, from: data),
					let name = ProviderName.display(team.name) ?? ProviderName.display(team.slug)
				else { return .failure(.invalidResponse) }
				return .success(VercelAccount(name: name, slug: ProviderName.display(team.slug)))
			}
		}
		return await get(["v2", "user"], query: [], limit: Self.maximumResponseBytes).flatMap { data in
			guard let user = try? JSONDecoder().decode(UserResponse.self, from: data).user,
				let name = ProviderName.display(user.name) ?? ProviderName.display(user.username)
			else { return .failure(.invalidResponse) }
			return .success(VercelAccount(name: name, slug: ProviderName.display(user.username)))
		}
	}

	/// Reads the projects page by page, within the listing's byte budget and
	/// deadline. A page holding more projects than asked for, or a project
	/// another account owns, fails the listing.
	func projects(teamID: String?, ownerID: String) async -> Result<[VercelProject], VercelAPIError> {
		var projects: [VercelProject] = []
		var cursor: String?
		var seenCursors: Set<String> = []
		var remaining = limits.projectBytes
		let deadline = ContinuousClock.now.advanced(by: limits.projectDeadline)
		for page in 0..<Self.maximumProjectPages {
			guard page == 0 || ContinuousClock.now < deadline, remaining > 0 else { return .failure(.invalidResponse) }
			var query = [URLQueryItem(name: "limit", value: String(Self.projectPageSize))]
			if let cursor { query.append(URLQueryItem(name: "from", value: cursor)) }
			let data: Data
			switch await get(["v10", "projects"], query: query, teamID: teamID, limit: min(Self.maximumPageBytes, remaining)) {
			case .success(let page): data = page
			case .failure(let error): return .failure(error)
			}
			remaining -= data.count
			guard let decoded = try? JSONDecoder().decode(ProjectPage.self, from: data), decoded.projects.count <= Self.projectPageSize else {
				return .failure(.invalidResponse)
			}
			for project in decoded.projects {
				guard VercelPublishTarget.isValidIdentifier(project.id), project.accountId == ownerID,
					let name = ProviderName.display(project.name)
				else { return .failure(.invalidResponse) }
				projects.append(VercelProject(id: project.id, name: name, accountID: project.accountId))
			}
			guard let next = decoded.next else { return .success(projects) }
			guard !next.isEmpty, next.utf8.count <= 512, seenCursors.insert(next).inserted else {
				return .failure(.invalidResponse)
			}
			cursor = next
		}
		return .failure(.invalidResponse)
	}

	func customEnvironments(projectID: String, teamID: String?) async -> Result<[VercelCustomEnvironment], VercelAPIError> {
		guard VercelPublishTarget.isValidIdentifier(projectID) else { return .failure(.invalidResponse) }
		return await get(["v9", "projects", projectID, "custom-environments"], query: [], teamID: teamID, limit: Self.maximumResponseBytes)
			.flatMap { data in
				guard let decoded = try? JSONDecoder().decode(CustomEnvironments.self, from: data) else {
					return .failure(.invalidResponse)
				}
				var environments: [VercelCustomEnvironment] = []
				for environment in decoded.environments {
					guard VercelPublishTarget.isValidIdentifier(environment.id), let slug = ProviderName.display(environment.slug) else {
						return .failure(.invalidResponse)
					}
					environments.append(VercelCustomEnvironment(id: environment.id, slug: slug))
				}
				return .success(environments)
			}
	}

	// MARK: - Variables

	func variables(projectID: String, teamID: String?) async -> Result<VercelVariableList, VercelAPIError> {
		guard VercelPublishTarget.isValidIdentifier(projectID) else { return .failure(.invalidResponse) }
		return await get(["v10", "projects", projectID, "env"], query: [], teamID: teamID, limit: Self.maximumPageBytes)
			.flatMap { data in
				guard let decoded = try? JSONDecoder().decode(VariableList.self, from: data) else {
					return .failure(.invalidResponse)
				}
				if decoded.pagination?.next != nil { return .failure(.incompleteList) }
				var variables: [VercelEnvironmentVariable] = []
				variables.reserveCapacity(decoded.envs.count)
				for raw in decoded.envs {
					guard let variable = raw.variable else { return .failure(.invalidResponse) }
					variables.append(variable)
				}
				return .success(VercelVariableList(
					variables: variables,
					hiddenProductionCount: max(0, decoded.hiddenProductionEnvCount ?? 0)
				))
			}
	}

	static let createBatchSize = 50

	func create(
		_ writes: [VercelVariableWrite],
		projectID: String,
		teamID: String?
	) async -> Result<[String: Result<VercelEnvironmentVariable, VercelAPIError>], VercelAPIError> {
		guard VercelPublishTarget.isValidIdentifier(projectID),
			Set(writes.map(\.key)).count == writes.count,
			writes.allSatisfy({ write in
				!write.key.isEmpty && (!write.targets.isEmpty || !write.customEnvironmentIDs.isEmpty)
					&& write.customEnvironmentIDs.allSatisfy(VercelPublishTarget.isValidIdentifier)
			})
		else { return .failure(.invalidResponse) }
		var results: [String: Result<VercelEnvironmentVariable, VercelAPIError>] = [:]
		var start = writes.startIndex
		while start < writes.endIndex {
			let batch = writes[start..<min(start + Self.createBatchSize, writes.endIndex)]
			start = batch.endIndex
			let body: [[String: Any]] = batch.map { write in
				var object: [String: Any] = [
					"key": write.key, "value": write.value, "type": write.storage.rawValue, "visibility": write.storage.visibility,
				]
				if !write.targets.isEmpty { object["target"] = write.targets.map(\.rawValue).sorted() }
				if !write.customEnvironmentIDs.isEmpty { object["customEnvironmentIds"] = write.customEnvironmentIDs.sorted() }
				return object
			}
			let response = await send("POST", ["v10", "projects", projectID, "env"], body: body, teamID: teamID)
			guard case .success(let data) = response else {
				if case .failure(let error) = response {
					// Later batches would meet the same refusal, so nothing more is sent.
					guard results.isEmpty else {
						for write in writes[batch.startIndex...] { results[write.key] = .failure(error) }
						return .success(results)
					}
					return .failure(error)
				}
				return .failure(.invalidResponse)
			}
			guard let decoded = try? JSONDecoder().decode(CreateResponse.self, from: data) else {
				// Earlier batches' variables were created; only this batch's outcome is unknown, and nothing more is sent.
				guard results.isEmpty else {
					for write in writes[batch.startIndex...] { results[write.key] = .failure(.invalidResponse) }
					return .success(results)
				}
				return .failure(.invalidResponse)
			}
			let keys = Set(batch.map(\.key))
			for raw in decoded.created ?? [] {
				guard let created = raw.variable, keys.contains(created.key) else { continue }
				results[created.key] = .success(created)
			}
			for failure in decoded.failed ?? [] {
				guard let key = failure.error.key ?? failure.error.envVarKey, keys.contains(key), results[key] == nil else { continue }
				results[key] = .failure(.rejected(code: failure.error.code.flatMap(Self.errorCode) ?? "unknown"))
			}
			for write in batch where results[write.key] == nil {
				results[write.key] = .failure(.invalidResponse)
			}
		}
		return .success(results)
	}

	func replace(
		_ variableID: String,
		key: String,
		value: String,
		storage: VercelVariableWrite.Storage,
		projectID: String,
		teamID: String?
	) async -> Result<VercelEnvironmentVariable, VercelAPIError> {
		guard VercelPublishTarget.isValidIdentifier(projectID), VercelPublishTarget.isValidIdentifier(variableID) else {
			return .failure(.invalidResponse)
		}
		let body: [String: Any] = ["value": value, "type": storage.rawValue, "visibility": storage.visibility]
		return await send("PATCH", ["v9", "projects", projectID, "env", variableID], body: body, teamID: teamID).flatMap { data in
			guard let updated = (try? JSONDecoder().decode(RawVariable.self, from: data))?.variable, updated.id == variableID,
				updated.key == key
			else { return .failure(.invalidResponse) }
			return .success(updated)
		}
	}

	// MARK: - Requests

	private func get(
		_ path: [String],
		query: [URLQueryItem],
		teamID: String? = nil,
		limit: Int
	) async -> Result<Data, VercelAPIError> {
		guard let url = url(path, query: query, teamID: teamID) else { return .failure(.invalidResponse) }
		var request = URLRequest(url: url)
		request.setValue("application/json", forHTTPHeaderField: "Accept")
		return await load(request, limit: limit)
	}

	private func send(
		_ method: String,
		_ path: [String],
		body: Any,
		teamID: String?
	) async -> Result<Data, VercelAPIError> {
		guard let url = url(path, query: [], teamID: teamID),
			let data = try? JSONSerialization.data(withJSONObject: body)
		else { return .failure(.invalidResponse) }
		var request = URLRequest(url: url)
		request.httpMethod = method
		request.httpBody = data
		request.setValue("application/json", forHTTPHeaderField: "Content-Type")
		request.setValue("application/json", forHTTPHeaderField: "Accept")
		return await load(request, limit: Self.maximumResponseBytes)
	}

	private func load(_ request: URLRequest, limit: Int) async -> Result<Data, VercelAPIError> {
		var request = request
		request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
		do {
			let (data, response) = try await BoundedHTTPResponse.load(for: request, using: session, maximumBytes: limit)
			guard let http = response as? HTTPURLResponse else { return .failure(.invalidResponse) }
			guard (200..<300).contains(http.statusCode) else { return .failure(Self.failure(http, data)) }
			return .success(data)
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

	private func url(_ path: [String], query: [URLQueryItem], teamID: String?) -> URL? {
		guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { return nil }
		components.percentEncodedPath = "/" + path.joined(separator: "/")
		var items = query
		if let teamID {
			guard VercelPublishTarget.isValidIdentifier(teamID) else { return nil }
			items.append(URLQueryItem(name: "teamId", value: teamID))
		}
		components.queryItems = items.isEmpty ? nil : items
		components.fragment = nil
		return components.url
	}

	private static func failure(_ http: HTTPURLResponse, _ data: Data) -> VercelAPIError {
		let error = (try? JSONDecoder().decode(ErrorResponse.self, from: data))?.error
		// Vercel answers a token it no longer accepts, as after the integration
		// is uninstalled, with 403 rather than 401.
		if error?.invalidToken == true { return .unauthorized }
		switch http.statusCode {
		case 401: return .unauthorized
		case 403 where error?.code == "forbidden": return .forbidden
		case 404: return .notFound
		case 429:
			let reset = http.value(forHTTPHeaderField: "X-RateLimit-Reset").flatMap(TimeInterval.init)
			return .rateLimited(until: reset.map(Date.init(timeIntervalSince1970:)))
		case 400, 403, 409:
			if let code = error?.code {
				return .rejected(code: errorCode(code) ?? "unknown")
			}
			return http.statusCode == 403 ? .forbidden : .server(http.statusCode)
		default:
			return .server(http.statusCode)
		}
	}

	/// Vercel's error code when it's an identifier, as its codes are. Its
	/// messages are never shown: one could echo a value or the token sent.
	private static func errorCode(_ text: String) -> String? {
		guard !text.isEmpty, text.utf8.count <= 64,
			text.utf8.allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A) || $0 == 0x5F || $0 == 0x2D || $0 == 0x2E })
		else { return nil }
		return text
	}

	// MARK: - Wire types

	private struct Team: Decodable {
		let name: String?
		let slug: String?
	}

	private struct UserResponse: Decodable {
		struct User: Decodable {
			let name: String?
			let username: String?
		}
		let user: User
	}

	private struct ProjectPage: Decodable {
		struct Project: Decodable {
			let id: String
			let name: String
			let accountId: String
		}
		let projects: [Project]
		let next: String?

		private enum CodingKeys: String, CodingKey { case projects, pagination }
		private enum PaginationKeys: String, CodingKey { case next }

		init(from decoder: Decoder) throws {
			// Older responses are a bare array of projects.
			if let projects = try? decoder.singleValueContainer().decode([Project].self) {
				self.projects = projects
				next = nil
				return
			}
			let container = try decoder.container(keyedBy: CodingKeys.self)
			projects = try container.decode([Project].self, forKey: .projects)
			guard container.contains(.pagination), try !container.decodeNil(forKey: .pagination) else {
				next = nil
				return
			}
			let pagination = try container.nestedContainer(keyedBy: PaginationKeys.self, forKey: .pagination)
			let hasNext = try pagination.contains(.next) && !pagination.decodeNil(forKey: .next)
			if !hasNext {
				next = nil
			} else if let number = try? pagination.decode(Int64.self, forKey: .next) {
				next = String(number)
			} else {
				next = try pagination.decode(String.self, forKey: .next)
			}
		}
	}

	private struct CustomEnvironments: Decodable {
		struct Environment: Decodable {
			let id: String
			let slug: String
		}
		let environments: [Environment]
	}

	private struct VariableList: Decodable {
		struct Pagination: Decodable {
			let next: Double?
		}
		let envs: [RawVariable]
		let pagination: Pagination?
		let hiddenProductionEnvCount: Int?
	}

	private struct RawVariable: Decodable {
		let id: String?
		let key: String
		let type: String
		let visibility: String?
		let target: [String]
		let customEnvironmentIds: [String]?
		let gitBranch: String?
		let updatedAt: Double?

		private enum CodingKeys: String, CodingKey { case id, key, type, visibility, target, customEnvironmentIds, gitBranch, updatedAt }

		init(from decoder: Decoder) throws {
			let container = try decoder.container(keyedBy: CodingKeys.self)
			id = try container.decodeIfPresent(String.self, forKey: .id)
			key = try container.decode(String.self, forKey: .key)
			type = try container.decode(String.self, forKey: .type)
			visibility = try container.decodeIfPresent(String.self, forKey: .visibility)
			if let targets = try? container.decodeIfPresent([String].self, forKey: .target) {
				target = targets
			} else if let single = try? container.decodeIfPresent(String.self, forKey: .target) {
				target = [single]
			} else {
				target = []
			}
			customEnvironmentIds = try container.decodeIfPresent([String].self, forKey: .customEnvironmentIds)
			gitBranch = try container.decodeIfPresent(String.self, forKey: .gitBranch)
			updatedAt = try container.decodeIfPresent(Double.self, forKey: .updatedAt)
		}

		var variable: VercelEnvironmentVariable? {
			guard let id, VercelPublishTarget.isValidIdentifier(id), !key.isEmpty, key.utf8.count <= 1_024 else { return nil }
			var targets: Set<VercelEnvironmentVariable.Target> = []
			for name in target {
				guard let target = VercelEnvironmentVariable.Target(rawValue: name) else { return nil }
				targets.insert(target)
			}
			let customIDs = customEnvironmentIds ?? []
			guard customIDs.allSatisfy(VercelPublishTarget.isValidIdentifier) else { return nil }
			let kind = VercelEnvironmentVariable.Kind(type)
			return VercelEnvironmentVariable(
				id: id,
				key: key,
				kind: kind,
				isSecret: VercelClient.isSecret(visibility: visibility, kind: kind),
				targets: targets,
				customEnvironmentIDs: Set(customIDs),
				gitBranch: gitBranch.flatMap { $0.isEmpty ? nil : $0 },
				updatedAt: updatedAt.map { Date(timeIntervalSince1970: $0 / 1_000) }
			)
		}
	}

	/// Readable only when Vercel says Config, or, before it named
	/// visibilities, when the type is a readable one. Anything else, such as a
	/// visibility this version doesn't know, reads as a Secret.
	private static func isSecret(visibility: String?, kind: VercelEnvironmentVariable.Kind) -> Bool {
		let writeOnlyType = kind == .sensitive || kind == .secret
		switch visibility {
		case nil: return writeOnlyType
		case "config"?: return writeOnlyType
		default: return true
		}
	}

	private struct CreateResponse: Decodable {
		struct Failure: Decodable {
			struct Detail: Decodable {
				let code: String?
				let message: String?
				let key: String?
				let envVarKey: String?
			}
			let error: Detail
		}
		let created: [RawVariable]?
		let failed: [Failure]?

		private enum CodingKeys: String, CodingKey { case created, failed }

		init(from decoder: Decoder) throws {
			let container = try decoder.container(keyedBy: CodingKeys.self)
			if let many = try? container.decodeIfPresent([RawVariable].self, forKey: .created) {
				created = many
			} else if let one = try container.decodeIfPresent(RawVariable.self, forKey: .created) {
				created = [one]
			} else {
				created = nil
			}
			failed = try container.decodeIfPresent([Failure].self, forKey: .failed)
		}
	}

	private struct ErrorResponse: Decodable {
		struct Detail: Decodable {
			let code: String?
			let message: String?
			let invalidToken: Bool?
		}
		let error: Detail?
	}
}
