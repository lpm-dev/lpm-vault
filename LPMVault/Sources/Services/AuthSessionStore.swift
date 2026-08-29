import Foundation

struct AuthSessionCredentials: Decodable, Sendable {
	let token: String
	let refreshToken: String
	let expiresIn: Int
	let expiresAt: String

	var isComplete: Bool {
		!token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
			&& !refreshToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
			&& expiresIn > 0
			&& AuthSessionTimestamp.parse(expiresAt) != nil
	}
}

enum AuthSessionTimestamp {
	private static let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
	private static let wholeSeconds = Date.ISO8601FormatStyle(includingFractionalSeconds: false)

	static func parse(_ value: String) -> Date? {
		(try? fractional.parse(value)) ?? (try? wholeSeconds.parse(value))
	}
}

enum AuthSessionStore {
	private static let maximumAuthResponseBytes = 64 * 1024
	private static let refreshSession: URLSession = {
		let configuration = URLSessionConfiguration.ephemeral
		configuration.timeoutIntervalForRequest = 10
		configuration.timeoutIntervalForResource = 10
		return URLSession(
			configuration: configuration,
			delegate: PinnedSessionDelegate(),
			delegateQueue: nil
		)
	}()
	private static let live = AuthSessionCoordinator(
		homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
		credentialBackend: KeychainAuthCredentialBackend(
			service: VaultConstants.cliAuthService
		),
		refreshOperation: performRefresh
	)

	static func scopedAccessAccount(registryURL: String) -> String {
		AuthSessionCoordinator.accessAccount(registryURL: registryURL)
	}

	static func scopedRefreshAccount(registryURL: String) -> String {
		AuthSessionCoordinator.refreshAccount(registryURL: registryURL)
	}

	static func registryURL(for baseURL: URL) -> String {
		baseURL.absoluteString
	}

	static func sessionLockName(registryURL: String) -> String {
		AuthSessionCoordinator.sessionLockName(registryURL: registryURL)
	}

	static func authorityID(kind: String, registryURL: String) -> String? {
		AuthSessionCoordinator.authorityID(kind: kind, registryURL: registryURL)
	}

	static func currentAccessToken(registryURL: String, baseURL: URL) async throws -> String? {
		try await live.currentAccessToken(registryURL: registryURL, baseURL: baseURL)
	}

	static func persist(
		_ credentials: AuthSessionCredentials,
		registryURL: String
	) async throws {
		try await live.persist(credentials, registryURL: registryURL)
	}

	static func clear(registryURL: String) async throws {
		try await live.clear(registryURL: registryURL)
	}

	static func deviceFingerprint() -> String {
		live.deviceFingerprint()
	}

	private static func performRefresh(
		refreshToken: String,
		registryURL _: String,
		baseURL: URL
	) async throws -> AuthSessionCredentials {
		guard let url = URL(string: "/api/cli/refresh", relativeTo: baseURL)?.absoluteURL else {
			throw AuthSessionRefreshError.invalidResponse
		}
		var request = URLRequest(url: url)
		request.httpMethod = "POST"
		request.timeoutInterval = 10
		request.setValue("application/json", forHTTPHeaderField: "Content-Type")
		request.httpBody = try JSONSerialization.data(withJSONObject: [
			"refreshToken": refreshToken,
			"deviceFingerprint": deviceFingerprint(),
		])

		let bytes: URLSession.AsyncBytes
		let response: URLResponse
		do {
			(bytes, response) = try await refreshSession.bytes(for: request)
		} catch is CancellationError {
			throw CancellationError()
		} catch {
			throw AuthSessionRefreshError.transport
		}
		guard let http = response as? HTTPURLResponse else {
			throw AuthSessionRefreshError.invalidResponse
		}
		if http.statusCode == 401 { throw AuthSessionRefreshError.rejected }
		guard (200..<300).contains(http.statusCode) else {
			throw AuthSessionRefreshError.server(http.statusCode)
		}
		if response.expectedContentLength > maximumAuthResponseBytes {
			throw AuthSessionRefreshError.invalidResponse
		}

		var data = Data()
		data.reserveCapacity(
			Int(max(0, min(response.expectedContentLength, Int64(maximumAuthResponseBytes))))
		)
		do {
			for try await byte in bytes {
				guard data.count < maximumAuthResponseBytes else {
					throw AuthSessionRefreshError.invalidResponse
				}
				data.append(byte)
			}
		} catch let error as AuthSessionRefreshError {
			throw error
		} catch is CancellationError {
			throw CancellationError()
		} catch {
			throw AuthSessionRefreshError.transport
		}

		do {
			return try JSONDecoder().decode(AuthSessionCredentials.self, from: data)
		} catch {
			throw AuthSessionRefreshError.invalidResponse
		}
	}
}
