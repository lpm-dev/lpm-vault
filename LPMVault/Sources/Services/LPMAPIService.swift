import Foundation

// MARK: - Protocol

enum LPMAPIError: LocalizedError, Sendable, Equatable {
	case cancelled
	case invalidRequest
	case transport
	case unauthorized
	case forbidden
	case server(Int)
	case invalidResponse
	case invalidSignature

	var errorDescription: String? {
		switch self {
		case .cancelled: "The request was cancelled."
		case .invalidRequest: "The API request was invalid."
		case .transport: "The server request failed. Check your connection and try again."
		case .unauthorized: "Your lpm.dev session is no longer authorized."
		case .forbidden: "Your account does not have permission for this request."
		case .server(let status): "The server returned HTTP \(status)."
		case .invalidResponse: "The server returned an invalid response."
		case .invalidSignature: "The server response signature was invalid."
		}
	}
}

typealias LPMAPIResult<Value: Sendable> = Result<Value, LPMAPIError>

protocol LPMAPIServiceProtocol: Sendable {
	func fetchCurrentUser(authToken: String) async -> LPMAPIResult<LPMUser>
	func fetchPersonalTokens(authToken: String) async -> LPMAPIResult<[LPMToken]>
	func revokePersonalToken(id: String, authToken: String) async -> LPMAPIResult<Void>
	func fetchOrgTokens(orgSlug: String, authToken: String) async -> LPMAPIResult<[LPMToken]>
	func revokeOrgToken(orgSlug: String, id: String, authToken: String) async -> LPMAPIResult<Void>
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
		if let session {
			self.session = session
		} else {
			let configuration = URLSessionConfiguration.ephemeral
			configuration.httpShouldSetCookies = false
			configuration.httpCookieStorage = nil
			configuration.urlCredentialStorage = nil
			configuration.urlCache = nil
			configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
			self.session = URLSession(
				configuration: configuration,
				delegate: PinnedSessionDelegate(),
				delegateQueue: nil
			)
		}
	}

	// MARK: - User

	/// Validate a specific token against the server (used during login
	/// to verify the token works before persisting it to Keychain).
	func fetchCurrentUser(authToken: String) async -> LPMAPIResult<LPMUser> {
		await get(path: "/api/user/me", token: authToken)
	}

	// MARK: - Personal Tokens

	func fetchPersonalTokens(authToken: String) async -> LPMAPIResult<[LPMToken]> {
		await fetchTokenPages(path: ["api", "tokens"], token: authToken)
	}

	func revokePersonalToken(id: String, authToken: String) async -> LPMAPIResult<Void> {
		guard let url = endpoint(["api", "tokens", id]) else { return .failure(.invalidRequest) }
		return await delete(url: url, token: authToken)
	}

	// MARK: - Org Tokens

	func fetchOrgTokens(orgSlug: String, authToken: String) async -> LPMAPIResult<[LPMToken]> {
		let result = await fetchTokenPages(
			path: ["api", "orgs", orgSlug, "tokens"],
			token: authToken
		)
		return result.map { tokens in
			tokens.map { value in
				var token = value
				token.orgSlug = orgSlug
				return token
			}
		}
	}

	func revokeOrgToken(orgSlug: String, id: String, authToken: String) async -> LPMAPIResult<Void> {
		guard let url = endpoint(["api", "orgs", orgSlug, "tokens", id]) else {
			return .failure(.invalidRequest)
		}
		return await delete(url: url, token: authToken)
	}

	// MARK: - HTTP Helpers

	private func fetchTokenPages(path: [String], token: String) async -> LPMAPIResult<[LPMToken]> {
		guard let baseEndpoint = endpoint(path) else { return .failure(.invalidRequest) }
		var tokens: [LPMToken] = []
		var cursor: String?
		var seenCursors: Set<String> = []

		for _ in 0..<maximumTokenPages {
			guard !Task.isCancelled else { return .failure(.cancelled) }
			guard var components = URLComponents(url: baseEndpoint, resolvingAgainstBaseURL: false) else {
				return .failure(.invalidRequest)
			}
			components.queryItems = [URLQueryItem(name: "limit", value: "100")]
			if let cursor {
				components.queryItems?.append(URLQueryItem(name: "cursor", value: cursor))
			}
			guard let url = components.url else { return .failure(.invalidRequest) }

			var request = URLRequest(url: url)
			request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
			do {
				let (data, response) = try await BoundedHTTPResponse.load(
					for: request,
					using: session,
					maximumBytes: maximumResponseBytes
				)
				guard let http = response as? HTTPURLResponse,
					tokens.count <= maximumTokens
				else { return .failure(.invalidResponse) }
				guard http.statusCode == 200 else { return .failure(error(for: http.statusCode)) }
				guard PinnedSessionDelegate.verifyResponseSignature(http, body: data, authToken: token) else {
					return .failure(.invalidSignature)
				}

				guard let page = try? JSONDecoder().decode([LPMToken].self, from: data) else {
					return .failure(.invalidResponse)
				}
				guard tokens.count + page.count <= maximumTokens else { return .failure(.invalidResponse) }
				tokens.append(contentsOf: page)

				guard let nextCursor = http.value(forHTTPHeaderField: "X-LPM-Next-Cursor") else {
					return .success(tokens)
				}
				guard !nextCursor.isEmpty, nextCursor.count <= 160,
					seenCursors.insert(nextCursor).inserted
				else {
					return .failure(.invalidResponse)
				}
				cursor = nextCursor
			} catch is BoundedHTTPResponse.LoadError {
				return .failure(.invalidResponse)
			} catch is CancellationError {
				return .failure(.cancelled)
			} catch {
				return .failure(.transport)
			}
		}
		return .failure(.invalidResponse)
	}

	private func get<T: Decodable & Sendable>(path: String, token: String) async -> LPMAPIResult<T> {
		guard let url = URL(string: path, relativeTo: baseURL) else { return .failure(.invalidRequest) }

		var request = URLRequest(url: url)
		request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

		do {
			let (data, response) = try await BoundedHTTPResponse.load(
				for: request,
				using: session,
				maximumBytes: maximumResponseBytes
			)
			guard let http = response as? HTTPURLResponse
			else { return .failure(.invalidResponse) }
			guard http.statusCode == 200 else { return .failure(error(for: http.statusCode)) }
			guard PinnedSessionDelegate.verifyResponseSignature(http, body: data, authToken: token) else {
				return .failure(.invalidSignature)
			}
			guard let value = try? JSONDecoder().decode(T.self, from: data) else {
				return .failure(.invalidResponse)
			}
			return .success(value)
		} catch is BoundedHTTPResponse.LoadError {
			return .failure(.invalidResponse)
		} catch is CancellationError {
			return .failure(.cancelled)
		} catch {
			return .failure(.transport)
		}
	}

	private func delete(url: URL, token: String) async -> LPMAPIResult<Void> {
		var request = URLRequest(url: url)
		request.httpMethod = "DELETE"
		request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

		do {
			let (data, response) = try await BoundedHTTPResponse.load(
				for: request,
				using: session,
				maximumBytes: maximumResponseBytes
			)
			guard let http = response as? HTTPURLResponse
			else { return .failure(.invalidResponse) }
			guard PinnedSessionDelegate.verifyResponseSignature(http, body: data, authToken: token) else {
				return .failure(.invalidSignature)
			}
			guard http.statusCode == 200 else { return .failure(error(for: http.statusCode)) }
			return .success(())
		} catch is BoundedHTTPResponse.LoadError {
			return .failure(.invalidResponse)
		} catch is CancellationError {
			return .failure(.cancelled)
		} catch {
			return .failure(.transport)
		}
	}

	private func error(for statusCode: Int) -> LPMAPIError {
		switch statusCode {
		case 401: .unauthorized
		case 403: .forbidden
		default: .server(statusCode)
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
