import Foundation
import Security

// MARK: - Protocol

protocol LPMAPIServiceProtocol {
	func fetchCurrentUser() async -> LPMUser?
	func fetchPersonalTokens() async -> [LPMToken]
	func revokePersonalToken(id: String) async -> Bool
	func fetchOrgTokens(orgSlug: String) async -> [LPMToken]
	func revokeOrgToken(orgSlug: String, id: String) async -> Bool
}

// MARK: - Implementation

final class LPMAPIService: LPMAPIServiceProtocol {
	private let baseURL: URL
	private let session: URLSession

	init(baseURL: URL = VaultConstants.apiBaseURL) {
		self.baseURL = baseURL
		self.session = URLSession(configuration: .ephemeral)
	}

	// MARK: - User

	func fetchCurrentUser() async -> LPMUser? {
		guard let token = readAuthToken() else { return nil }
		return await get(path: "/api/user/me", token: token)
	}

	// MARK: - Personal Tokens

	func fetchPersonalTokens() async -> [LPMToken] {
		guard let token = readAuthToken() else { return [] }
		let tokens: [LPMToken]? = await get(path: "/api/tokens", token: token)
		return tokens ?? []
	}

	func revokePersonalToken(id: String) async -> Bool {
		guard let token = readAuthToken() else { return false }
		return await delete(path: "/api/tokens/\(id)", token: token)
	}

	// MARK: - Org Tokens

	func fetchOrgTokens(orgSlug: String) async -> [LPMToken] {
		guard let token = readAuthToken() else { return [] }
		let tokens: [LPMToken]? = await get(
			path: "/api/orgs/\(orgSlug)/tokens", token: token)
		return (tokens ?? []).map { t in
			var token = t
			token.orgSlug = orgSlug
			return token
		}
	}

	func revokeOrgToken(orgSlug: String, id: String) async -> Bool {
		guard let token = readAuthToken() else { return false }
		return await delete(path: "/api/orgs/\(orgSlug)/tokens/\(id)", token: token)
	}

	// MARK: - Auth Token from Keychain

	/// Read the CLI auth token from macOS Keychain.
	/// The CLI stores it as service: "lpm-cli", account: "auth-token:{registry_url}"
	private func readAuthToken() -> String? {
		// Account keys to try (both Rust CLI and JS CLI use https://lpm.dev,
		// legacy JS CLI may use plain "auth-token" without registry suffix)
		let accountKeys = [
			"auth-token:https://lpm.dev",
			"auth-token:http://localhost:3000",
			"auth-token",  // Legacy JS CLI unscoped key
		]

		// Try Security framework first (works for items created by this app or with -A flag)
		for account in accountKeys {
			let query: [String: Any] = [
				kSecClass as String: kSecClassGenericPassword,
				kSecAttrService as String: VaultConstants.cliAuthService,
				kSecAttrAccount as String: account,
				kSecReturnData as String: true,
			]

			var result: AnyObject?
			let status = SecItemCopyMatching(query as CFDictionary, &result)

			if status == errSecSuccess,
				let data = result as? Data,
				let token = String(data: data, encoding: .utf8),
				!token.isEmpty
			{
				return token
			}
		}

		// Fallback: try macOS `security` CLI (can read keytar-created items —
		// may prompt for Keychain password once, user clicks "Always Allow")
		for account in accountKeys {
			if let token = readTokenViaSecurity(account: account) {
				return token
			}
		}

		return nil
	}

	private func readTokenViaSecurity(account: String) -> String? {
		let process = Process()
		process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
		process.arguments = [
			"find-generic-password",
			"-s", VaultConstants.cliAuthService,
			"-a", account,
			"-w",
		]

		let pipe = Pipe()
		process.standardOutput = pipe
		process.standardError = FileHandle.nullDevice

		do {
			try process.run()
			process.waitUntilExit()

			if process.terminationStatus == 0 {
				let data = pipe.fileHandleForReading.readDataToEndOfFile()
				let token = String(data: data, encoding: .utf8)?.trimmingCharacters(
					in: .whitespacesAndNewlines)
				if let token, !token.isEmpty {
					return token
				}
			}
		} catch {}

		return nil
	}

	// MARK: - HTTP Helpers

	private func get<T: Decodable>(path: String, token: String) async -> T? {
		guard let url = URL(string: path, relativeTo: baseURL) else { return nil }

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

	private func delete(path: String, token: String) async -> Bool {
		guard let url = URL(string: path, relativeTo: baseURL) else { return false }

		var request = URLRequest(url: url)
		request.httpMethod = "DELETE"
		request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

		do {
			let (_, response) = try await session.data(for: request)
			guard let http = response as? HTTPURLResponse else { return false }
			return http.statusCode == 200
		} catch {
			return false
		}
	}
}
