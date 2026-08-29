import Foundation

final class SyncService: @unchecked Sendable {
	private final class RetainedServices: @unchecked Sendable {
		let lock = NSLock()
		var values: [URL: SyncService] = [:]
	}

	private static let retainedServices = RetainedServices()

	static func shared(baseURL: URL = VaultConstants.apiBaseURL) -> SyncService {
		retainedServices.lock.withLock {
			if let retained = retainedServices.values[baseURL] { return retained }
			let service = SyncService(baseURL: baseURL)
			retainedServices.values[baseURL] = service
			return service
		}
	}

	private let apiBaseURL: URL
	private let session: URLSession
	private let maximumResponseBytes = 10 * 1024 * 1024

	init(baseURL: URL = VaultConstants.apiBaseURL, session: URLSession? = nil) {
		apiBaseURL = baseURL
		self.session = session ?? URLSession(
			configuration: .ephemeral,
			delegate: PinnedSessionDelegate(),
			delegateQueue: nil
		)
	}

	struct SyncStatus: Codable, Sendable {
		let vaultId: String?
		let version: Int?
		let cryptoVersion: Int?
		let contentKeyVersion: Int?
		let recipientPublicKeyVersion: Int?
		let recipientPublicKeyFingerprint: String?
		let status: String?
		let error: String?
		let code: String?
		let serverVersion: Int?
		let hint: String?
		let encryptedBlob: String?
		let wrappedKey: String?
		let updatedAt: String?

		var displayError: String? {
			guard let error else { return nil }
			guard let hint, !hint.isEmpty else { return error }
			return "\(error)\n\nHint: \(hint)"
		}
	}

	struct RemoteProject: Decodable, Identifiable {
		let vaultId: String
		let name: String?
		let version: Int?
		let updatedAt: String?
		let updatedBy: String?

		var id: String { vaultId }
	}

	enum ProjectListError: Error, LocalizedError, Sendable, Equatable {
		case cancelled
		case invalidRequest
		case transport
		case unauthorized
		case sessionNotAuthorized
		case forbidden
		case rateLimited
		case server(Int)
		case invalidResponse
		case invalidPagination

		var requiresSignIn: Bool {
			self == .unauthorized || self == .sessionNotAuthorized
		}

		var errorDescription: String? {
			switch self {
			case .cancelled:
				"The request was cancelled."
			case .invalidRequest:
				"LPM Vault could not create the cloud request."
			case .transport:
				"Could not reach lpm.dev. Check your connection and try again."
			case .unauthorized:
				"Your lpm.dev session expired. Sign in again."
			case .sessionNotAuthorized:
				"This lpm.dev session cannot access cloud env projects. Sign in again to create a current session."
			case .forbidden:
				"Your lpm.dev account is not allowed to access these cloud env projects."
			case .rateLimited:
				"lpm.dev received too many requests. Wait a moment and retry."
			case .server(let status):
				"lpm.dev could not load env projects (HTTP \(status)). Try again later."
			case .invalidResponse:
				"lpm.dev returned an invalid env project response."
			case .invalidPagination:
				"lpm.dev returned invalid env project pagination data."
			}
		}
	}

	struct MemberPublicKey: Decodable, Sendable {
		let userId: String
		let role: String
		let publicKey: String?
		let publicKeyVersion: Int?
		let publicKeyFingerprint: String?
		let hasPublicKey: Bool
	}

	struct MemberKeyAccess: Sendable {
		let members: [MemberPublicKey]
		let canReplaceWrappedKeys: Bool
	}

	struct PublicKeyRecord: Decodable, Sendable, Equatable {
		let publicKey: String?
		let publicKeyVersion: Int?
		let publicKeyFingerprint: String?
	}

	struct PublicKeyUploadResponse: Decodable {
		let ok: Bool?
		let status: String?
		let publicKeyVersion: Int?
		let publicKeyFingerprint: String?
		let error: String?
		let code: String?
		let expectedScope: String?
	}

	struct WrappedMemberKey: Encodable, Sendable {
		let userId: String
		let wrappedKey: String
		let publicKeyVersion: Int
		let publicKeyFingerprint: String
	}

	func push(
		authToken: String,
		vaultId: String,
		encryptedBlob: String,
		wrappedKey: String,
		expectedVersion: Int? = nil,
		force: Bool = false,
		name: String? = nil,
		schema: Data? = nil
	) async -> SyncStatus? {
		guard let url = endpoint(["api", "vaults", vaultId, "sync"]) else { return nil }
		var body: [String: Any] = [
			"encryptedBlob": encryptedBlob,
			"wrappedKey": wrappedKey,
			"cryptoVersion": VaultCrypto.currentCryptoVersion,
		]
		if let expectedVersion { body["expectedVersion"] = expectedVersion }
		if force { body["force"] = true }
		if let name, !name.isEmpty { body["name"] = name }
		if let schema,
			let object = try? JSONSerialization.jsonObject(with: schema)
		{
			body["schema"] = object
		}
		return await request(url: url, method: "POST", token: authToken, body: body, signedSuccess: true)
	}

	func pull(authToken: String, vaultId: String) async -> SyncStatus? {
		guard let url = endpoint(["api", "vaults", vaultId, "sync"]) else { return nil }
		return await request(url: url, method: "GET", token: authToken, signedSuccess: true)
	}

	func pushOrg(
		authToken: String,
		orgSlug: String,
		vaultId: String,
		encryptedBlob: String,
		wrappedKeys: [WrappedMemberKey]?,
		expectedVersion: Int?,
		name: String? = nil,
		schema: Data? = nil
	) async -> SyncStatus? {
		guard let url = endpoint(["api", "orgs", orgSlug, "vaults", vaultId]) else { return nil }
		var body: [String: Any] = [
			"encryptedBlob": encryptedBlob,
			"cryptoVersion": VaultCrypto.currentCryptoVersion,
		]
		if let wrappedKeys,
			let encoded = try? JSONEncoder().encode(wrappedKeys),
			let array = try? JSONSerialization.jsonObject(with: encoded)
		{
			body["wrappedKeys"] = array
		}
		if let expectedVersion { body["expectedVersion"] = expectedVersion }
		if let name, !name.isEmpty { body["name"] = name }
		if let schema,
			let object = try? JSONSerialization.jsonObject(with: schema)
		{
			body["schema"] = object
		}
		return await request(url: url, method: "POST", token: authToken, body: body, signedSuccess: true)
	}

	func pullOrg(authToken: String, orgSlug: String, vaultId: String) async -> SyncStatus? {
		guard let url = endpoint(["api", "orgs", orgSlug, "vaults", vaultId]) else { return nil }
		return await request(url: url, method: "GET", token: authToken, signedSuccess: true)
	}

	func getOrgMemberKeyAccess(authToken: String, orgSlug: String) async -> MemberKeyAccess? {
		guard let url = endpoint(["api", "orgs", orgSlug, "members", "public-keys"]) else { return nil }
		var request = URLRequest(url: url)
		request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
		do {
			let (data, response) = try await BoundedHTTPResponse.load(
				for: request,
				using: session,
				maximumBytes: maximumResponseBytes
			)
			guard let http = response as? HTTPURLResponse,
				http.statusCode == 200
			else { return nil }
			let capability = http.value(forHTTPHeaderField: "X-LPM-Org-Wrapped-Keys-Write")
			guard capability == "allowed" || capability == "forbidden" else { return nil }
			let members = try JSONDecoder().decode([MemberPublicKey].self, from: data)
			return MemberKeyAccess(
				members: members,
				canReplaceWrappedKeys: capability != "forbidden"
			)
		} catch {
			return nil
		}
	}

	func getMyPublicKey(authToken: String) async -> PublicKeyRecord? {
		guard let url = endpoint(["api", "users", "me", "public-key"]) else { return nil }
		return await request(url: url, method: "GET", token: authToken, signedSuccess: false)
	}

	func uploadPublicKey(
		authToken: String,
		publicKey: String,
		stepUpProof: String? = nil
	) async -> PublicKeyUploadResponse? {
		guard let url = endpoint(["api", "users", "me", "public-key"]) else { return nil }
		var headers: [String: String] = [:]
		if let stepUpProof { headers["X-LPM-Step-Up-Proof"] = stepUpProof }
		return await request(
			url: url,
			method: "POST",
			token: authToken,
			body: ["publicKey": publicKey],
			signedSuccess: false,
			headers: headers
		)
	}

	func listPersonalProjects(authToken: String) async -> Result<[RemoteProject], ProjectListError> {
		await listProjects(authToken: authToken, path: ["api", "vaults"])
	}

	func listOrgProjects(authToken: String, orgSlug: String) async -> Result<[RemoteProject], ProjectListError> {
		await listProjects(authToken: authToken, path: ["api", "orgs", orgSlug, "vaults"])
	}

	private struct ProjectPage: Decodable {
		let vaults: [RemoteProject]
		let nextCursor: String?
	}

	private struct ErrorEnvelope: Decodable {
		let error: String?
	}

	private func listProjects(
		authToken: String,
		path: [String]
	) async -> Result<[RemoteProject], ProjectListError> {
		guard var url = endpoint(path) else { return .failure(.invalidRequest) }
		var projects: [RemoteProject] = []
		var cursor: String?
		var seenCursors: Set<String> = []

		for _ in 0..<101 {
			if let cursor {
				var components = URLComponents(url: url, resolvingAgainstBaseURL: true)
				components?.queryItems = [URLQueryItem(name: "cursor", value: cursor)]
				guard let nextURL = components?.url else { return .failure(.invalidRequest) }
				url = nextURL
			}
			let page: ProjectPage
			switch await loadProjectPage(url: url, authToken: authToken) {
			case .success(let loadedPage):
				page = loadedPage
			case .failure(let error):
				return .failure(error)
			}
			guard projects.count + page.vaults.count <= 10_000 else {
				return .failure(.invalidPagination)
			}
			projects.append(contentsOf: page.vaults)
			guard let nextCursor = page.nextCursor else { return .success(projects) }
			guard !nextCursor.isEmpty, nextCursor.count <= 160,
				seenCursors.insert(nextCursor).inserted
			else { return .failure(.invalidPagination) }
			cursor = nextCursor
		}
		return .failure(.invalidPagination)
	}

	private func loadProjectPage(
		url: URL,
		authToken: String
	) async -> Result<ProjectPage, ProjectListError> {
		var request = URLRequest(url: url)
		request.httpMethod = "GET"
		request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
		do {
			let (data, response) = try await BoundedHTTPResponse.load(
				for: request,
				using: session,
				maximumBytes: maximumResponseBytes
			)
			guard let http = response as? HTTPURLResponse else {
				return .failure(.invalidResponse)
			}
			switch http.statusCode {
			case 200..<300:
				guard let page = try? JSONDecoder().decode(ProjectPage.self, from: data) else {
					return .failure(.invalidResponse)
				}
				return .success(page)
			case 401:
				return .failure(.unauthorized)
			case 403:
				let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: data)
				let normalized = envelope?.error?.lowercased() ?? ""
				if normalized.contains("requires a cli session")
					|| normalized.contains("run `lpm login`")
				{
					return .failure(.sessionNotAuthorized)
				}
				return .failure(.forbidden)
			case 429:
				return .failure(.rateLimited)
			default:
				return .failure(.server(http.statusCode))
			}
		} catch is CancellationError {
			return .failure(.cancelled)
		} catch is BoundedHTTPResponse.LoadError {
			return .failure(.invalidResponse)
		} catch {
			return .failure(.transport)
		}
	}

	private func endpoint(_ pathSegments: [String]) -> URL? {
		var components = URLComponents(url: apiBaseURL, resolvingAgainstBaseURL: false)
		let encodedPath = pathSegments
			.map { segment in
				segment.addingPercentEncoding(withAllowedCharacters: .urlPathSegmentAllowed) ?? ""
			}
			.joined(separator: "/")
		components?.percentEncodedPath = "/\(encodedPath)"
		components?.query = nil
		components?.fragment = nil
		return components?.url
	}

	private func request<T: Decodable>(
		url: URL,
		method: String,
		token: String,
		body: [String: Any]? = nil,
		signedSuccess: Bool,
		headers: [String: String] = [:]
	) async -> T? {
		var request = URLRequest(url: url)
		request.httpMethod = method
		request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
		for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
		if let body {
			request.setValue("application/json", forHTTPHeaderField: "Content-Type")
			request.httpBody = try? JSONSerialization.data(withJSONObject: body)
		}

		do {
			let (data, response) = try await BoundedHTTPResponse.load(
				for: request,
				using: session,
				maximumBytes: maximumResponseBytes
			)
			guard let http = response as? HTTPURLResponse
			else { return nil }
			guard (200..<300).contains(http.statusCode) else { return nil }
			if signedSuccess {
				guard PinnedSessionDelegate.verifyResponseSignature(
					http,
					body: data,
					authToken: token,
					requireSignature: true
				) else { return nil }
			}
			return try JSONDecoder().decode(T.self, from: data)
		} catch {
			return nil
		}
	}
}

/// The organization-sync surface used by `VaultStore`. Keeping this narrow
/// makes authorization races testable without replacing unrelated API calls.
protocol OrgSyncServiceProtocol: Sendable {
	func pushOrg(
		authToken: String,
		orgSlug: String,
		vaultId: String,
		encryptedBlob: String,
		wrappedKeys: [SyncService.WrappedMemberKey]?,
		expectedVersion: Int?,
		name: String?,
		schema: Data?
	) async -> SyncService.SyncStatus?

	func pullOrg(
		authToken: String,
		orgSlug: String,
		vaultId: String
	) async -> SyncService.SyncStatus?

	func getOrgMemberKeyAccess(
		authToken: String,
		orgSlug: String
	) async -> SyncService.MemberKeyAccess?

	func getMyPublicKey(authToken: String) async -> SyncService.PublicKeyRecord?
}

extension SyncService: OrgSyncServiceProtocol {}

protocol PersonalSyncServiceProtocol: Sendable {
	func push(
		authToken: String,
		vaultId: String,
		encryptedBlob: String,
		wrappedKey: String,
		expectedVersion: Int?,
		force: Bool,
		name: String?,
		schema: Data?
	) async -> SyncService.SyncStatus?

	func pull(authToken: String, vaultId: String) async -> SyncService.SyncStatus?
}

extension SyncService: PersonalSyncServiceProtocol {}

private extension CharacterSet {
	static let urlPathSegmentAllowed: CharacterSet = {
		var allowed = CharacterSet.urlPathAllowed
		allowed.remove(charactersIn: "/?#%")
		return allowed
	}()
}
