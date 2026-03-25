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
