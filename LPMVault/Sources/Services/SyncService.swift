import Foundation

final class SyncService: @unchecked Sendable {
	private let apiBaseURL: URL
	private let session: URLSession
	private let maximumResponseBytes = 10 * 1024 * 1024

	init(baseURL: URL = VaultConstants.apiBaseURL) {
		apiBaseURL = baseURL
		session = URLSession(
			configuration: .ephemeral,
			delegate: PinnedSessionDelegate(),
			delegateQueue: nil
		)
	}

	struct SyncStatus: Codable, Sendable {
		let vaultId: String?
		let version: Int?
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

	struct PublicKeyRecord: Decodable, Sendable {
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
		var body: [String: Any] = ["encryptedBlob": encryptedBlob]
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
			let (data, response) = try await session.data(for: request)
			guard data.count <= maximumResponseBytes,
				let http = response as? HTTPURLResponse,
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

	func listPersonalProjects(authToken: String) async -> [RemoteProject]? {
		await listProjects(authToken: authToken, path: ["api", "vaults"])
	}

	func listOrgProjects(authToken: String, orgSlug: String) async -> [RemoteProject]? {
		await listProjects(authToken: authToken, path: ["api", "orgs", orgSlug, "vaults"])
	}

	private struct ProjectPage: Decodable {
		let vaults: [RemoteProject]
		let nextCursor: String?
	}

	private func listProjects(authToken: String, path: [String]) async -> [RemoteProject]? {
		guard var url = endpoint(path) else { return nil }
		var projects: [RemoteProject] = []
		var cursor: String?
		var seenCursors: Set<String> = []

		for _ in 0..<101 {
			if let cursor {
				var components = URLComponents(url: url, resolvingAgainstBaseURL: true)
				components?.queryItems = [URLQueryItem(name: "cursor", value: cursor)]
				guard let nextURL = components?.url else { return nil }
				url = nextURL
			}
			guard let page: ProjectPage = await request(
				url: url,
				method: "GET",
				token: authToken,
				signedSuccess: false
			) else { return nil }
			guard projects.count + page.vaults.count <= 10_000 else { return nil }
			projects.append(contentsOf: page.vaults)
			guard let nextCursor = page.nextCursor else { return projects }
			guard !nextCursor.isEmpty, nextCursor.count <= 160,
				seenCursors.insert(nextCursor).inserted
			else { return nil }
			cursor = nextCursor
		}
		return nil
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
			let (data, response) = try await session.data(for: request)
			guard data.count <= maximumResponseBytes,
				let http = response as? HTTPURLResponse
			else { return nil }
			if (200..<300).contains(http.statusCode), signedSuccess {
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
