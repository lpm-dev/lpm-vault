import CryptoKit
import Foundation
import Security

// MARK: - Protocol

protocol LPMAPIServiceProtocol {
	func fetchCurrentUser() async -> LPMUser?
	func fetchCurrentUser(authToken: String) async -> LPMUser?
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
		self.session = URLSession(
			configuration: .ephemeral, delegate: PinnedSessionDelegate(), delegateQueue: nil)
	}

	// MARK: - User

	func fetchCurrentUser() async -> LPMUser? {
		guard let token = readAuthToken() else { return nil }
		return await get(path: "/api/user/me", token: token)
	}

	/// Validate a specific token against the server (used during login
	/// to verify the token works before persisting it to Keychain).
	func fetchCurrentUser(authToken: String) async -> LPMUser? {
		return await get(path: "/api/user/me", token: authToken)
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
	/// Prioritizes the token matching this service's base URL.
	private func readAuthToken() -> String? {
		// Determine primary account based on what server we're talking to
		let primary: String
		if baseURL.host == "localhost" || baseURL.host == "127.0.0.1" {
			primary = "auth-token:\(baseURL.absoluteString)"
		} else {
			primary = "auth-token:https://lpm.dev"
		}

		// Check primary first, then fallbacks
		var accounts = [primary]
		for fallback in ["auth-token:https://lpm.dev", "auth-token:http://localhost:3000", "auth-token"] {
			if fallback != primary { accounts.append(fallback) }
		}

		for account in accounts {
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

		let sem = DispatchSemaphore(value: 0)
		var exitCode: Int32 = -1
		process.terminationHandler = { p in
			exitCode = p.terminationStatus
			sem.signal()
		}

		do {
			try process.run()
		} catch {
			return nil
		}

		let result = sem.wait(timeout: .now() + 10)
		if result == .timedOut {
			process.terminate()
			return nil
		}

		guard exitCode == 0 else { return nil }

		let data = pipe.fileHandleForReading.readDataToEndOfFile()
		let token = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
		return (token?.isEmpty == false) ? token : nil
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
			guard PinnedSessionDelegate.verifyResponseSignature(http, body: data, authToken: token) else {
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
			let (data, response) = try await session.data(for: request)
			guard let http = response as? HTTPURLResponse else { return false }
			guard PinnedSessionDelegate.verifyResponseSignature(http, body: data, authToken: token) else {
				return false
			}
			return http.statusCode == 200
		} catch {
			return false
		}
	}
}
