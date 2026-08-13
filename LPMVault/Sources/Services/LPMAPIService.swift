import Foundation

// MARK: - Protocol

protocol LPMAPIServiceProtocol: Sendable {
	func fetchCurrentUser() async -> LPMUser?
	func fetchCurrentUser(authToken: String) async -> LPMUser?
	func fetchPersonalTokens() async -> [LPMToken]
	func revokePersonalToken(id: String) async -> Bool
	func fetchOrgTokens(orgSlug: String) async -> [LPMToken]
	func revokeOrgToken(orgSlug: String, id: String) async -> Bool
}

// MARK: - Implementation

final class LPMAPIService: LPMAPIServiceProtocol, @unchecked Sendable {
	private let baseURL: URL
	private let session: URLSession
	private let maximumResponseBytes = 2 * 1024 * 1024
	private let maximumTokenPages = 101
	private let maximumTokens = 10_000

	init(baseURL: URL = VaultConstants.apiBaseURL, session: URLSession? = nil) {
		self.baseURL = baseURL
		self.session = session ?? URLSession(
			configuration: .ephemeral, delegate: PinnedSessionDelegate(), delegateQueue: nil)
	}

	// MARK: - User

	func fetchCurrentUser() async -> LPMUser? {
		guard let token = await authToken() else { return nil }
		return await get(path: "/api/user/me", token: token)
	}

	/// Validate a specific token against the server (used during login
	/// to verify the token works before persisting it to Keychain).
	func fetchCurrentUser(authToken: String) async -> LPMUser? {
		return await get(path: "/api/user/me", token: authToken)
	}

	// MARK: - Personal Tokens

	func fetchPersonalTokens() async -> [LPMToken] {
		guard let token = await authToken() else { return [] }
		return await fetchPersonalTokens(authToken: token) ?? []
	}

	func fetchPersonalTokens(authToken: String) async -> [LPMToken]? {
		await fetchTokenPages(path: ["api", "tokens"], token: authToken)
	}

	func revokePersonalToken(id: String) async -> Bool {
		guard let token = await authToken() else { return false }
		guard let url = endpoint(["api", "tokens", id]) else { return false }
		return await delete(url: url, token: token)
	}

	// MARK: - Org Tokens

	func fetchOrgTokens(orgSlug: String) async -> [LPMToken] {
		guard let token = await authToken() else { return [] }
		return await fetchOrgTokens(orgSlug: orgSlug, authToken: token) ?? []
	}

	func fetchOrgTokens(orgSlug: String, authToken: String) async -> [LPMToken]? {
		guard let tokens = await fetchTokenPages(
			path: ["api", "orgs", orgSlug, "tokens"],
			token: authToken
		) else { return nil }
		return tokens.map { t in
			var token = t
			token.orgSlug = orgSlug
			return token
		}
	}

	func revokeOrgToken(orgSlug: String, id: String) async -> Bool {
		guard let token = await authToken() else { return false }
		guard let url = endpoint(["api", "orgs", orgSlug, "tokens", id]) else { return false }
		return await delete(url: url, token: token)
	}

	private func authToken() async -> String? {
		return await AuthSessionStore.currentAccessToken(
			registryURL: AuthSessionStore.registryURL(for: baseURL),
			baseURL: baseURL
		)
	}

	// MARK: - HTTP Helpers

	private func fetchTokenPages(path: [String], token: String) async -> [LPMToken]? {
		guard let baseEndpoint = endpoint(path) else { return nil }
		var tokens: [LPMToken] = []
		var cursor: String?
		var seenCursors: Set<String> = []

		for _ in 0..<maximumTokenPages {
			guard var components = URLComponents(url: baseEndpoint, resolvingAgainstBaseURL: false) else {
				return nil
			}
			components.queryItems = [URLQueryItem(name: "limit", value: "100")]
			if let cursor {
				components.queryItems?.append(URLQueryItem(name: "cursor", value: cursor))
			}
			guard let url = components.url else { return nil }

			var request = URLRequest(url: url)
			request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
			do {
				let (data, response) = try await session.data(for: request)
				guard data.count <= maximumResponseBytes,
					let http = response as? HTTPURLResponse,
					http.statusCode == 200,
					PinnedSessionDelegate.verifyResponseSignature(http, body: data, authToken: token),
					tokens.count <= maximumTokens
				else { return nil }

				let page = try JSONDecoder().decode([LPMToken].self, from: data)
				guard tokens.count + page.count <= maximumTokens else { return nil }
				tokens.append(contentsOf: page)

				guard let nextCursor = http.value(forHTTPHeaderField: "X-LPM-Next-Cursor") else {
					return tokens
				}
				guard !nextCursor.isEmpty, nextCursor.count <= 160,
					seenCursors.insert(nextCursor).inserted
				else {
					return nil
				}
				cursor = nextCursor
			} catch {
				return nil
			}
		}
		return nil
	}

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

	private func delete(url: URL, token: String) async -> Bool {
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

	private func endpoint(_ pathSegments: [String]) -> URL? {
		var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
		let encodedPath = pathSegments
			.map { $0.addingPercentEncoding(withAllowedCharacters: .lpmPathSegmentAllowed) ?? "" }
			.joined(separator: "/")
		components?.percentEncodedPath = "/\(encodedPath)"
		components?.query = nil
		components?.fragment = nil
		return components?.url
	}
}

private extension CharacterSet {
	static let lpmPathSegmentAllowed: CharacterSet = {
		var allowed = CharacterSet.urlPathAllowed
		allowed.remove(charactersIn: "/?#%")
		return allowed
	}()
}
