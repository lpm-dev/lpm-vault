import CryptoKit
import Foundation
import Security

struct AuthSessionCredentials: Decodable, Sendable {
	let token: String
	let refreshToken: String
	let expiresIn: Int
	let expiresAt: String

	var isComplete: Bool {
		!token.isEmpty
			&& !refreshToken.isEmpty
			&& expiresIn > 0
			&& ISO8601DateFormatter().date(from: expiresAt) != nil
	}
}

enum AuthSessionStore {
	private static let accessAccountPrefix = "auth-token"
	private static let refreshAccountPrefix = "lpm-refresh"
	private static let maximumAuthResponseBytes = 64 * 1024

	static func scopedAccessAccount(registryURL: String) -> String {
		"\(accessAccountPrefix):\(registryHash(registryURL))"
	}

	static func scopedRefreshAccount(registryURL: String) -> String {
		"\(refreshAccountPrefix):\(registryHash(registryURL))"
	}

	static func registryURL(for baseURL: URL) -> String {
		baseURL.absoluteString
	}

	static func readAccessToken(registryURL: String) -> String? {
		let accounts = [
			scopedAccessAccount(registryURL: registryURL),
			"auth-token:\(registryURL)",
		]
		return firstCredential(accounts: accounts)
	}

	static func currentAccessToken(registryURL: String, baseURL: URL) async -> String? {
		let accessToken = readAccessToken(registryURL: registryURL)
		guard accessToken == nil || shouldRefresh(registryURL: registryURL) else { return accessToken }

		// Keep the normal access-token path to one Keychain read. The refresh
		// item can prompt separately on macOS, so inspect it only when rotation
		// or refresh-only recovery is actually required.
		let refreshToken = readCredential(account: scopedRefreshAccount(registryURL: registryURL))
		guard let refreshToken else { return accessToken }

		do {
			return try await refresh(
				refreshToken: refreshToken,
				registryURL: registryURL,
				baseURL: baseURL
			).token
		} catch RefreshError.rejected {
			clear(registryURL: registryURL)
			return nil
		} catch {
			return isExpired(registryURL: registryURL) ? nil : accessToken
		}
	}

	static func persist(_ credentials: AuthSessionCredentials, registryURL: String) throws {
		guard credentials.isComplete else { throw StorageError.incompleteCredentials }
		try writeCredential(
			credentials.token,
			account: scopedAccessAccount(registryURL: registryURL)
		)
		try writeCredential(
			credentials.refreshToken,
			account: scopedRefreshAccount(registryURL: registryURL)
		)
		writeExpiry(credentials.expiresAt, registryURL: registryURL)
	}

	static func clear(registryURL: String) {
		let accounts = [
			scopedAccessAccount(registryURL: registryURL),
			scopedRefreshAccount(registryURL: registryURL),
			"auth-token:\(registryURL)",
		]
		for account in accounts {
			_ = runSecurity([
				"delete-generic-password", "-s", VaultConstants.cliAuthService,
				"-a", account,
			])
		}
		removeExpiry(registryURL: registryURL)
	}

	static func deviceFingerprint() -> String {
		if let existing = readDeviceIdentifier() { return existing.lowercased() }

		var bytes = [UInt8](repeating: 0, count: 32)
		let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
		guard status == errSecSuccess else { return UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() }
		let identifier = bytes.map { String(format: "%02x", $0) }.joined()
		persistDeviceIdentifier(identifier)
		return identifier
	}

	private static func refresh(
		refreshToken: String,
		registryURL: String,
		baseURL: URL
	) async throws -> AuthSessionCredentials {
		guard let url = URL(string: "/api/cli/refresh", relativeTo: baseURL) else {
			throw RefreshError.invalidURL
		}
		var request = URLRequest(url: url)
		request.httpMethod = "POST"
		request.setValue("application/json", forHTTPHeaderField: "Content-Type")
		request.httpBody = try JSONSerialization.data(withJSONObject: [
			"refreshToken": refreshToken,
			"deviceFingerprint": deviceFingerprint(),
		])

		let session = URLSession(
			configuration: .ephemeral,
			delegate: PinnedSessionDelegate(),
			delegateQueue: nil
		)
		let (data, response) = try await session.data(for: request)
		guard let http = response as? HTTPURLResponse
		else {
			throw RefreshError.invalidResponse
		}
		guard data.count <= maximumAuthResponseBytes else { throw RefreshError.invalidResponse }
		if http.statusCode == 401 { throw RefreshError.rejected }
		guard (200..<300).contains(http.statusCode) else { throw RefreshError.server(http.statusCode) }

		let credentials = try JSONDecoder().decode(AuthSessionCredentials.self, from: data)
		guard credentials.isComplete else { throw RefreshError.invalidResponse }
		try persist(credentials, registryURL: registryURL)
		return credentials
	}

	private static func registryHash(_ registryURL: String) -> String {
		SHA256.hash(data: Data(registryURL.utf8))
			.prefix(8)
			.map { String(format: "%02x", $0) }
			.joined()
	}

	private static func firstCredential(accounts: [String]) -> String? {
		for account in accounts {
			if let value = readCredential(account: account) { return value }
		}
		return nil
	}

	private static func readCredential(account: String) -> String? {
		let result = runSecurity([
			"find-generic-password", "-s", VaultConstants.cliAuthService,
			"-a", account, "-w",
		])
		guard result.status == 0, !result.output.isEmpty else { return nil }
		return result.output
	}

	private static func writeCredential(_ credential: String, account: String) throws {
		_ = runSecurity([
			"delete-generic-password", "-s", VaultConstants.cliAuthService,
			"-a", account,
		])
		let result = runSecurity([
			"add-generic-password", "-s", VaultConstants.cliAuthService,
			"-a", account, "-w",
		], input: credential)
		guard result.status == 0 else { throw StorageError.keychainWriteFailed }
	}

	private static func shouldRefresh(registryURL: String) -> Bool {
		guard let expiry = accessExpiry(registryURL: registryURL) else { return true }
		return expiry.timeIntervalSinceNow <= 5 * 60
	}

	private static func isExpired(registryURL: String) -> Bool {
		guard let expiry = accessExpiry(registryURL: registryURL) else { return false }
		return expiry <= Date()
	}

	private static func accessExpiry(registryURL: String) -> Date? {
		guard let record = readExpiryRecords()[registryURL],
			let expiresAt = record["session_access_expires_at"] as? String
		else { return nil }
		return ISO8601DateFormatter().date(from: expiresAt)
	}

	private static func writeExpiry(_ expiresAt: String, registryURL: String) {
		var records = readExpiryRecords()
		var record = records[registryURL] ?? [:]
		record["expires"] = ""
		record["reminded_7d"] = false
		record["reminded_1d"] = false
		record["session_access_expires_at"] = expiresAt
		records[registryURL] = record
		writeExpiryRecords(records)
	}

	private static func removeExpiry(registryURL: String) {
		var records = readExpiryRecords()
		records.removeValue(forKey: registryURL)
		writeExpiryRecords(records)
	}

	private static func readExpiryRecords() -> [String: [String: Any]] {
		guard let path = expiryMetadataURL(),
			let data = try? Data(contentsOf: path),
			let object = try? JSONSerialization.jsonObject(with: data),
			let records = object as? [String: [String: Any]]
		else {
			return [:]
		}
		return records
	}

	private static func writeExpiryRecords(_ records: [String: [String: Any]]) {
		guard let path = expiryMetadataURL(),
			JSONSerialization.isValidJSONObject(records),
			let data = try? JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys])
		else { return }
		try? FileManager.default.createDirectory(
			at: path.deletingLastPathComponent(),
			withIntermediateDirectories: true
		)
		try? data.write(to: path, options: .atomic)
		try? FileManager.default.setAttributes(
			[.posixPermissions: 0o600],
			ofItemAtPath: path.path
		)
	}

	private static func expiryMetadataURL() -> URL? {
		FileManager.default.homeDirectoryForCurrentUser
			.appendingPathComponent(".lpm", isDirectory: true)
			.appendingPathComponent(".token-expiry.json")
	}

	private static func deviceIdentifierURL() -> URL {
		FileManager.default.homeDirectoryForCurrentUser
			.appendingPathComponent(".lpm", isDirectory: true)
			.appendingPathComponent("device-id")
	}

	private static func readDeviceIdentifier() -> String? {
		guard let value = try? String(contentsOf: deviceIdentifierURL(), encoding: .utf8)
			.trimmingCharacters(in: .whitespacesAndNewlines),
			value.count == 64
		else { return nil }
		guard value.utf8.allSatisfy({ byte in
				(byte >= 48 && byte <= 57) || (byte >= 65 && byte <= 70) || (byte >= 97 && byte <= 102)
			})
		else { return nil }
		return value
	}

	private static func persistDeviceIdentifier(_ identifier: String) {
		let url = deviceIdentifierURL()
		try? FileManager.default.createDirectory(
			at: url.deletingLastPathComponent(),
			withIntermediateDirectories: true
		)
		try? Data(identifier.utf8).write(to: url, options: .atomic)
		try? FileManager.default.setAttributes(
			[.posixPermissions: 0o600],
			ofItemAtPath: url.path
		)
	}

	private static func runSecurity(
		_ arguments: [String],
		input: String? = nil
	) -> (status: Int32, output: String) {
		let process = Process()
		process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
		process.arguments = arguments
		let output = Pipe()
		process.standardOutput = output
		process.standardError = FileHandle.nullDevice
		let inputPipe = input.map { _ in Pipe() }
		process.standardInput = inputPipe
		do {
			try process.run()
			if let input, let inputPipe {
				inputPipe.fileHandleForWriting.write(Data((input + "\n").utf8))
				inputPipe.fileHandleForWriting.closeFile()
			}
			process.waitUntilExit()
		} catch {
			return (-1, "")
		}
		let data = output.fileHandleForReading.readDataToEndOfFile()
		let value = String(data: data, encoding: .utf8)?
			.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
		return (process.terminationStatus, value)
	}

	private enum RefreshError: Error {
		case invalidURL
		case invalidResponse
		case rejected
		case server(Int)
	}

	private enum StorageError: Error {
		case incompleteCredentials
		case keychainWriteFailed
	}
}
