import Foundation

/// Handles vault cloud sync via LPM API.
final class SyncService {
	private let apiBaseURL: URL
	private let session: URLSession

	init(baseURL: URL = VaultConstants.apiBaseURL) {
		self.apiBaseURL = baseURL
		self.session = URLSession(configuration: .ephemeral)
	}

	// MARK: - Personal Sync

	struct SyncStatus: Codable {
		let vaultId: String?
		let version: Int?
		let status: String?
		let error: String?
		let encryptedBlob: String?
		let wrappedKey: String?
		let updatedAt: String?
	}

	func push(
		authToken: String,
		vaultId: String,
		encryptedBlob: String,
		wrappedKey: String,
		expectedVersion: Int? = nil,
		force: Bool = false
	) async -> SyncStatus? {
		guard let url = URL(string: "/api/vaults/\(vaultId)/sync", relativeTo: apiBaseURL) else {
			return nil
		}

		var body: [String: Any] = [
			"encryptedBlob": encryptedBlob,
			"wrappedKey": wrappedKey,
		]
		if let v = expectedVersion { body["expectedVersion"] = v }
		if force { body["force"] = true }

		return await post(url: url, token: authToken, body: body)
	}

	func pull(authToken: String, vaultId: String) async -> SyncStatus? {
		guard let url = URL(string: "/api/vaults/\(vaultId)/sync", relativeTo: apiBaseURL) else {
			return nil
		}
		return await get(url: url, token: authToken)
	}

	// MARK: - Org Sync

	/// Push a vault to an org with X25519-wrapped keys for each member.
	func pushOrg(
		authToken: String,
		orgSlug: String,
		vaultId: String,
		encryptedBlob: String,
		wrappedKeys: [[String: String]]
	) async -> SyncStatus? {
		guard let url = URL(string: "/api/orgs/\(orgSlug)/vaults/\(vaultId)", relativeTo: apiBaseURL) else {
			return nil
		}

		let body: [String: Any] = [
			"encryptedBlob": encryptedBlob,
			"wrappedKeys": wrappedKeys,
		]

		return await post(url: url, token: authToken, body: body)
	}

	/// Pull a vault from an org. Returns the encrypted blob + the user's wrapped key.
	func pullOrg(
		authToken: String,
		orgSlug: String,
		vaultId: String
	) async -> SyncStatus? {
		guard let url = URL(string: "/api/orgs/\(orgSlug)/vaults/\(vaultId)", relativeTo: apiBaseURL) else {
			return nil
		}
		return await get(url: url, token: authToken)
	}

	// MARK: - Public Key Management

	struct MemberPublicKey: Decodable {
		let userId: String
		let role: String
		let publicKey: String?
		let hasPublicKey: Bool
	}

	/// Fetch all org members' public keys.
	func getOrgMemberKeys(authToken: String, orgSlug: String) async -> [MemberPublicKey] {
		guard let url = URL(string: "/api/orgs/\(orgSlug)/members/public-keys", relativeTo: apiBaseURL) else {
			return []
		}
		let result: [MemberPublicKey]? = await get(url: url, token: authToken)
		return result ?? []
	}

	/// Upload the user's X25519 public key.
	func uploadPublicKey(authToken: String, publicKey: String) async -> Bool {
		guard let url = URL(string: "/api/users/me/public-key", relativeTo: apiBaseURL) else {
			return false
		}
		let body: [String: Any] = ["publicKey": publicKey]
		let _: SyncStatus? = await post(url: url, token: authToken, body: body)
		return true
	}

	// MARK: - Org Vault Discovery

	struct OrgVaultEntry: Decodable, Identifiable {
		let vaultId: String
		let version: Int?
		let updatedAt: String?
		let updatedBy: String?

		var id: String { vaultId }
	}

	private struct OrgVaultsResponse: Decodable {
		let vaults: [OrgVaultEntry]
	}

	/// List all shared vaults for an org.
	func listOrgVaults(authToken: String, orgSlug: String) async -> [OrgVaultEntry] {
		guard let url = URL(string: "/api/orgs/\(orgSlug)/vaults", relativeTo: apiBaseURL) else {
			return []
		}
		let result: OrgVaultsResponse? = await get(url: url, token: authToken)
		return result?.vaults ?? []
	}

	// MARK: - HTTP Helpers

	private func get<T: Decodable>(url: URL, token: String) async -> T? {
		var request = URLRequest(url: url)
		request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

		do {
			let (data, response) = try await session.data(for: request)
			guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
				return nil
			}
			return try JSONDecoder().decode(T.self, from: data)
		} catch {
			return nil
		}
	}

	private func post<T: Decodable>(url: URL, token: String, body: [String: Any]) async -> T? {
		var request = URLRequest(url: url)
		request.httpMethod = "POST"
		request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
		request.setValue("application/json", forHTTPHeaderField: "Content-Type")
		request.httpBody = try? JSONSerialization.data(withJSONObject: body)

		do {
			let (data, response) = try await session.data(for: request)
			guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
				return nil
			}
			return try JSONDecoder().decode(T.self, from: data)
		} catch {
			return nil
		}
	}
}
