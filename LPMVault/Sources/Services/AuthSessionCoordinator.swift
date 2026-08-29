import CryptoKit
import Darwin
import Dispatch
import Foundation
import Security

enum AuthSessionCoordinatorError: Error, LocalizedError, Sendable {
	case incompleteCredentials
	case invalidExpiry
	case reusedRefreshToken
	case credentialStorage(String)
	case stateFile(String)
	case unsupportedCredentialBackend

	var errorDescription: String? {
		switch self {
		case .incompleteCredentials:
			"The server returned an incomplete login session."
		case .invalidExpiry:
			"The server returned an invalid or expired login session."
		case .reusedRefreshToken:
			"The server did not rotate the refresh credential."
		case .credentialStorage(let message):
			"Credential storage failed: \(message)"
		case .stateFile(let message):
			"Session metadata failed: \(message)"
		case .unsupportedCredentialBackend:
			"This session is stored in the Rust client's encrypted fallback. Sign in from LPM Vault to move it to Keychain."
		}
	}
}

enum AuthSessionRefreshError: Error, LocalizedError, Sendable {
	case rejected
	case invalidResponse
	case transport
	case server(Int)

	var errorDescription: String? {
		switch self {
		case .rejected:
			"The server rejected the shared LPM session."
		case .invalidResponse:
			"The server returned an invalid refresh response."
		case .transport:
			"The shared LPM session could not be refreshed because of a network error."
		case .server(let status):
			"The shared LPM session refresh failed with HTTP status \(status)."
		}
	}
}

struct AuthSessionAuthorityGeneration: Equatable, Sendable {
	let device: UInt64
	let inode: UInt64
	let size: Int64
	let modifiedSeconds: Int64
	let modifiedNanoseconds: Int64
	let changedSeconds: Int64
	let changedNanoseconds: Int64
}

struct AuthSessionAuthorization: Sendable {
	let token: String
	let authorityGeneration: AuthSessionAuthorityGeneration
}

protocol AuthCredentialBackend: Sendable {
	func read(account: String) throws -> String?
	func write(_ credential: String, account: String) throws
	func delete(account: String) throws
}

struct KeychainAuthCredentialBackend: AuthCredentialBackend {
	let service: String

	func read(account: String) throws -> String? {
		var query = baseQuery(account: account)
		query[kSecMatchLimit as String] = kSecMatchLimitOne
		query[kSecReturnData as String] = true

		var result: CFTypeRef?
		let status = SecItemCopyMatching(query as CFDictionary, &result)
		if status == errSecItemNotFound { return nil }
		guard status == errSecSuccess else {
			throw AuthSessionCoordinatorError.credentialStorage(
				"Keychain read returned status \(status)."
			)
		}
		guard let data = result as? Data,
			let value = String(data: data, encoding: .utf8)?
				.trimmingCharacters(in: .whitespacesAndNewlines),
			!value.isEmpty
		else { return nil }
		return value
	}

	func write(_ credential: String, account: String) throws {
		let query = baseQuery(account: account)
		let attributes: [String: Any] = [
			kSecValueData as String: Data(credential.utf8),
			kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
		]
		let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
		if updateStatus == errSecSuccess { return }
		guard updateStatus == errSecItemNotFound else {
			throw AuthSessionCoordinatorError.credentialStorage(
				"Keychain update returned status \(updateStatus)."
			)
		}

		var add = query
		add[kSecValueData as String] = Data(credential.utf8)
		add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
		let addStatus = SecItemAdd(add as CFDictionary, nil)
		guard addStatus == errSecSuccess else {
			throw AuthSessionCoordinatorError.credentialStorage(
				"Keychain write returned status \(addStatus)."
			)
		}
	}

	func delete(account: String) throws {
		let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
		if status == errSecSuccess || status == errSecItemNotFound { return }

		// Keychain items created by an older `security` CLI path can reject
		// query-based deletion. The CLI can remove those items without reading
		// their value, which is the same compatibility fallback used by Rust.
		if status == errSecInvalidOwnerEdit {
			let result = runSecurityDelete(account: account)
			if result == 0 || result == 44 { return }
		}
		throw AuthSessionCoordinatorError.credentialStorage(
			"Keychain delete returned status \(status)."
		)
	}

	private func baseQuery(account: String) -> [String: Any] {
		[
			kSecClass as String: kSecClassGenericPassword,
			kSecAttrService as String: service,
			kSecAttrAccount as String: account,
		]
	}

	private func runSecurityDelete(account: String) -> Int32 {
		let process = Process()
		process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
		process.arguments = [
			"delete-generic-password", "-s", service, "-a", account,
		]
		process.standardInput = FileHandle.nullDevice
		process.standardOutput = FileHandle.nullDevice
		process.standardError = FileHandle.nullDevice
		do {
			try process.run()
			process.waitUntilExit()
			return process.terminationStatus
		} catch {
			return -1
		}
	}
}

/// The cross-process refresh transaction shared with `lpm-auth`.
///
/// Lock paths, credential identifiers, authority JSON, and commit ordering
/// intentionally mirror the Rust client. Keep changes to this type covered by
/// `CurrentContractTests` so the two independently compiled clients cannot
/// silently drift apart.
struct AuthSessionCoordinator: Sendable {
	typealias RefreshOperation = @Sendable (
		_ refreshToken: String,
		_ registryURL: String,
		_ baseURL: URL
	) async throws -> AuthSessionCredentials

	private enum CredentialKind: String, Sendable {
		case access
		case refresh

		func account(registryURL: String) -> String {
			let prefix = self == .access ? "auth-token" : "lpm-refresh"
			return "\(prefix):\(Self.shortHash(registryURL))"
		}

		func authorityID(registryURL: String) -> String {
			var input = Data(rawValue.utf8)
			input.append(0)
			input.append(Data(registryURL.utf8))
			return SHA256.hash(data: input).hexString
		}

		private static func shortHash(_ value: String) -> String {
			SHA256.hash(data: Data(value.utf8)).prefix(8).hexString
		}
	}

	private struct CredentialAuthorityStore: Codable, Sendable {
		var version: Int
		var credentials: [String: CredentialAuthorityRecord]

		static let empty = CredentialAuthorityStore(version: 1, credentials: [:])
	}

	private struct CredentialAuthorityRecord: Codable, Sendable {
		let state: String
		let backend: String?
		let credentialDigest: String?
		let staleFileCleanupPending: Bool?

		enum CodingKeys: String, CodingKey {
			case state
			case backend
			case credentialDigest = "credential_digest"
			case staleFileCleanupPending = "stale_file_cleanup_pending"
		}

		static func activeKeychain(_ credential: String, cleanupPending: Bool) -> Self {
			Self(
				state: "active",
				backend: "keychain",
				credentialDigest: SHA256.hash(data: Data(credential.utf8)).hexString,
				staleFileCleanupPending: cleanupPending
			)
		}

		static let revoked = Self(
			state: "revoked",
			backend: nil,
			credentialDigest: nil,
			staleFileCleanupPending: nil
		)

		func validate() throws {
			switch state {
			case "revoked":
				guard backend == nil, credentialDigest == nil else {
					throw AuthSessionCoordinatorError.stateFile(
						"Credential authority contains an invalid revoked record."
					)
				}
			case "active":
				guard backend == "keychain" || backend == "encrypted_file_fallback",
					let credentialDigest,
					credentialDigest.count == 64,
					credentialDigest.utf8.allSatisfy(\.isLowercaseHexDigit)
				else {
					throw AuthSessionCoordinatorError.stateFile(
						"Credential authority contains an invalid active record."
					)
				}
			default:
				throw AuthSessionCoordinatorError.stateFile(
					"Credential authority contains an unknown state."
				)
			}
		}
	}

	private static let stateFileSizeLimit = 16 * 1024 * 1024
	private static let refreshWindow: TimeInterval = 5 * 60
	private static let credentialStoreRegistry = "lpm-auth://credential-store"

	let homeDirectory: URL
	let credentialBackend: any AuthCredentialBackend
	let refreshOperation: RefreshOperation
	let now: @Sendable () -> Date

	init(
		homeDirectory: URL,
		credentialBackend: any AuthCredentialBackend,
		refreshOperation: @escaping RefreshOperation,
		now: @escaping @Sendable () -> Date = Date.init
	) {
		self.homeDirectory = homeDirectory
		self.credentialBackend = credentialBackend
		self.refreshOperation = refreshOperation
		self.now = now
	}

	static func accessAccount(registryURL: String) -> String {
		CredentialKind.access.account(registryURL: registryURL)
	}

	static func refreshAccount(registryURL: String) -> String {
		CredentialKind.refresh.account(registryURL: registryURL)
	}

	static func sessionLockName(registryURL: String) -> String {
		let hash = SHA256.hash(data: Data(registryURL.utf8)).prefix(16).hexString
		return "auth-session-\(hash).lock"
	}

	static func authorityID(kind: String, registryURL: String) -> String? {
		guard let kind = CredentialKind(rawValue: kind) else { return nil }
		return kind.authorityID(registryURL: registryURL)
	}

	func sessionLockURL(registryURL: String) -> URL {
		lpmDirectory
			.appendingPathComponent("locks", isDirectory: true)
			.appendingPathComponent(Self.sessionLockName(registryURL: registryURL))
	}

	func currentAccessToken(registryURL: String, baseURL: URL) async throws -> String? {
		let initialAccess = try await readCredential(.access, registryURL: registryURL)
		try Task.checkCancellation()
		let initialShouldRefresh = try shouldRefresh(registryURL: registryURL)
		guard initialAccess == nil || initialShouldRefresh else { return initialAccess }

		let initialRefresh = try await readCredential(.refresh, registryURL: registryURL)
		try Task.checkCancellation()
		guard initialRefresh != nil else { return initialAccess }

		let token: String? = try await CrossProcessFileLock.withExclusive(
			at: sessionLockURL(registryURL: registryURL)
		) {
			// A malformed metadata map must never be overwritten with a partial
			// reconstruction. Rust applies the same fail-closed rule.
			_ = try readExpiryRecordsChecked()

			let currentRefresh = try await readCredential(.refresh, registryURL: registryURL)
			let currentAccess = try await readCredential(.access, registryURL: registryURL)

			if currentRefresh != initialRefresh,
				currentAccess != initialAccess,
				let currentAccess,
				try !shouldRefresh(registryURL: registryURL)
			{
				return currentAccess
			}

			guard let currentRefresh else { return currentAccess }
			do {
				let credentials = try await refreshOperation(
					currentRefresh, registryURL, baseURL
				)
				try validate(credentials)
				guard credentials.refreshToken != currentRefresh else {
					throw AuthSessionCoordinatorError.reusedRefreshToken
				}
				try await persistUnlocked(credentials, registryURL: registryURL)
				return credentials.token
			} catch AuthSessionRefreshError.rejected {
				try await clearRejectedSessionIfCurrent(
					rejectedAccess: currentAccess,
					rejectedRefresh: currentRefresh,
					registryURL: registryURL
				)
				return nil
			} catch AuthSessionRefreshError.transport {
				guard let currentAccess,
					try !isExpired(registryURL: registryURL)
				else { throw AuthSessionRefreshError.transport }
				return currentAccess
			} catch AuthSessionRefreshError.server(let status)
				where status == 408 || status == 429 || (500..<600).contains(status)
			{
				guard let currentAccess,
					try !isExpired(registryURL: registryURL)
				else { throw AuthSessionRefreshError.server(status) }
				return currentAccess
			} catch {
				throw error
			}
		}
		try Task.checkCancellation()
		return token
	}

	/// Returns one validated access credential bound to the atomic authority
	/// file generation that authorized it. Later suspension checks can compare
	/// this identity with one lstat(2), without reopening Keychain or parsing
	/// the complete authority map.
	func currentAccessAuthorization(
		registryURL: String,
		baseURL: URL
	) async throws -> AuthSessionAuthorization? {
		_ = try await currentAccessToken(registryURL: registryURL, baseURL: baseURL)
		return try await withCredentialStoreLock {
			guard let token = try readCredentialUnlocked(
				.access,
				registryURL: registryURL
			) else { return nil }
			return AuthSessionAuthorization(
				token: token,
				authorityGeneration: try authorityGeneration()
			)
		}
	}

	func isAuthorityGenerationCurrent(
		_ generation: AuthSessionAuthorityGeneration
	) -> Bool {
		guard let current = try? authorityGeneration() else { return false }
		return current == generation
	}

	func persist(_ credentials: AuthSessionCredentials, registryURL: String) async throws {
		try validate(credentials)
		try await CrossProcessFileLock.withExclusive(
			at: sessionLockURL(registryURL: registryURL)
		) {
			try await persistUnlocked(credentials, registryURL: registryURL)
		}
	}

	func clear(registryURL: String) async throws {
		try await CrossProcessFileLock.withExclusive(
			at: sessionLockURL(registryURL: registryURL)
		) {
			_ = Darwin.unlink(
				lpmDirectory.appendingPathComponent(".token-check").path
			)
			var errors: [Error] = []
			do {
				try await withCredentialStoreLock {
					try revokeAndDeleteCredentialsUnlocked(
						kinds: [.access, .refresh],
						registryURL: registryURL
					)
				}
			} catch {
				errors.append(error)
			}
			do {
				try await removeExpiry(registryURL: registryURL)
			} catch {
				errors.append(error)
			}
			guard errors.isEmpty else {
				throw AuthSessionCoordinatorError.credentialStorage(
					errors.map(\.localizedDescription).joined(separator: "; ")
				)
			}
		}
	}

	func deviceFingerprint() throws -> String {
		if let existing = try? readDeviceIdentifier() { return existing }

		try ensurePrivateDirectory(lpmDirectory)
		return try CrossProcessFileLock.withSingleExclusive(
			at: lpmDirectory.appendingPathComponent("device-id.lock")
		) {
			if let existing = try readDeviceIdentifier() { return existing }
			let identifier = Self.randomIdentifier()
			try SecureStateFile.write(
				Data(identifier.utf8),
				to: deviceIdentifierURL
			)
			guard let persisted = try readDeviceIdentifier() else {
				throw AuthSessionCoordinatorError.stateFile(
					"The device identifier could not be verified after writing."
				)
			}
			return persisted
		}
	}

	#if DEBUG
	// Test support for simulating a legacy/non-conforming peer that changes
	// credentials without the per-registry session lock while a request is in
	// flight. Credential and expiry locks are still honored.
	func persistWithoutSessionLockForTesting(
		_ credentials: AuthSessionCredentials,
		registryURL: String
	) async throws {
		try validate(credentials)
		try await persistUnlocked(credentials, registryURL: registryURL)
	}

	func writeCredentialWithoutSessionLockForTesting(
		_ credential: String,
		kind: String,
		registryURL: String
	) async throws {
		guard let credentialKind = CredentialKind(rawValue: kind) else {
			throw AuthSessionCoordinatorError.credentialStorage("Unknown credential kind.")
		}
		try await writeCredential(
			credential,
			kind: credentialKind,
			registryURL: registryURL
		)
	}
	#endif

	private var lpmDirectory: URL {
		homeDirectory.appendingPathComponent(".lpm", isDirectory: true)
	}

	private var authorityURL: URL {
		lpmDirectory.appendingPathComponent(".credential-authority.json")
	}

	private var expiryURL: URL {
		lpmDirectory.appendingPathComponent(".token-expiry.json")
	}

	private var expiryLockURL: URL {
		lpmDirectory.appendingPathComponent(".token-expiry.lock")
	}

	private var credentialStoreLockURL: URL {
		sessionLockURL(registryURL: Self.credentialStoreRegistry)
	}

	private var deviceIdentifierURL: URL {
		lpmDirectory.appendingPathComponent("device-id")
	}

	private func validate(_ credentials: AuthSessionCredentials) throws {
		guard credentials.isComplete else {
			throw AuthSessionCoordinatorError.incompleteCredentials
		}
		guard let expiry = AuthSessionTimestamp.parse(credentials.expiresAt),
			expiry > now()
		else { throw AuthSessionCoordinatorError.invalidExpiry }
	}

	private func persistUnlocked(
		_ credentials: AuthSessionCredentials,
		registryURL: String
	) async throws {
		// Refuse to consume/replace credentials if the final metadata commit
		// cannot safely begin from the complete existing map.
		_ = try readExpiryRecordsChecked()

		// The server consumes the predecessor refresh token. Its replacement is
		// therefore the recovery credential and must become durable first.
		try await writeCredential(
			credentials.refreshToken,
			kind: .refresh,
			registryURL: registryURL
		)
		try await writeCredential(
			credentials.token,
			kind: .access,
			registryURL: registryURL
		)
		try await writeExpiry(credentials.expiresAt, registryURL: registryURL)
	}

	private func readCredential(
		_ kind: CredentialKind,
		registryURL: String
	) async throws -> String? {
		try await withCredentialStoreLock {
			try readCredentialUnlocked(kind, registryURL: registryURL)
		}
	}

	private func readCredentialUnlocked(
		_ kind: CredentialKind,
		registryURL: String
	) throws -> String? {
		var store = try readAuthorityStoreChecked()
		let authorityID = kind.authorityID(registryURL: registryURL)
		let account = kind.account(registryURL: registryURL)

		if let authority = store.credentials[authorityID] {
			try authority.validate()
			if authority.state == "revoked" { return nil }
			guard authority.backend == "keychain" else {
				throw AuthSessionCoordinatorError.unsupportedCredentialBackend
			}
			guard let credential = try credentialBackend.read(account: account),
				authority.credentialDigest
					== SHA256.hash(data: Data(credential.utf8)).hexString
			else {
				// An authority record with cleanup pending is also the durable
				// crash marker for an interrupted backend commit. Treat it as an
				// unavailable access credential so the rotated refresh credential
				// can repair the session instead of stranding it.
				if authority.staleFileCleanupPending == true { return nil }
				throw AuthSessionCoordinatorError.credentialStorage(
					"The Keychain credential does not match its authority record."
				)
			}
			return credential
		}

		guard !encryptedFallbackMayExist else {
			throw AuthSessionCoordinatorError.unsupportedCredentialBackend
		}

		if let credential = try credentialBackend.read(account: account) {
			store.credentials[authorityID] = .activeKeychain(
				credential,
				cleanupPending: false
			)
			try writeAuthorityStore(store)
			return credential
		}

		// Migrate the pre-hash access-token account while holding the same
		// global store lock used by Rust credential readers.
		if kind == .access {
			let legacyAccount = "auth-token:\(registryURL)"
			if let credential = try credentialBackend.read(account: legacyAccount) {
				try credentialBackend.write(credential, account: account)
				store.credentials[authorityID] = .activeKeychain(
					credential,
					cleanupPending: false
				)
				try writeAuthorityStore(store)
				try credentialBackend.delete(account: legacyAccount)
				return credential
			}
		}
		return nil
	}

	private func writeCredential(
		_ credential: String,
		kind: CredentialKind,
		registryURL: String
	) async throws {
		try await withCredentialStoreLock {
			var store = try readAuthorityStoreChecked()
			let authorityID = kind.authorityID(registryURL: registryURL)
			store.credentials[authorityID] = .activeKeychain(
				credential,
				cleanupPending: true
			)
			// Publish intent before touching the backend. A crash can hide an old
			// token, but can never make it authoritative again.
			try writeAuthorityStore(store)
			try credentialBackend.write(
				credential,
				account: kind.account(registryURL: registryURL)
			)

			if !encryptedFallbackMayExist {
				store.credentials[authorityID] = .activeKeychain(
					credential,
					cleanupPending: false
				)
				try writeAuthorityStore(store)
			}
		}
	}

	private func clearRejectedSessionIfCurrent(
		rejectedAccess: String?,
		rejectedRefresh: String,
		registryURL: String
	) async throws {
		try await withCredentialStoreLock {
			let currentAccess = try readCredentialUnlocked(
				.access,
				registryURL: registryURL
			)
			let currentRefresh = try readCredentialUnlocked(
				.refresh,
				registryURL: registryURL
			)

			var kinds: [CredentialKind] = []
			if currentAccess == rejectedAccess {
				kinds.append(.access)
			}
			if currentRefresh == rejectedRefresh { kinds.append(.refresh) }
			var errors: [Error] = []
			if currentAccess == rejectedAccess {
				do {
					try await removeExpiry(registryURL: registryURL)
				} catch {
					errors.append(error)
				}
			}
			do {
				try revokeAndDeleteCredentialsUnlocked(
					kinds: kinds,
					registryURL: registryURL
				)
			} catch {
				errors.append(error)
			}
			guard errors.isEmpty else {
				throw AuthSessionCoordinatorError.credentialStorage(
					errors.map(\.localizedDescription).joined(separator: "; ")
				)
			}
		}
	}

	private func revokeAndDeleteCredentialsUnlocked(
		kinds: [CredentialKind],
		registryURL: String
	) throws {
		guard !kinds.isEmpty else { return }
		var store = try readAuthorityStoreChecked()
		for kind in kinds {
			store.credentials[kind.authorityID(registryURL: registryURL)] = .revoked
		}
		try writeAuthorityStore(store)

		var errors: [Error] = []
		for kind in kinds {
			do {
				try credentialBackend.delete(
					account: kind.account(registryURL: registryURL)
				)
			} catch {
				errors.append(error)
			}
			if kind == .access {
				do {
					try credentialBackend.delete(account: "auth-token:\(registryURL)")
				} catch {
					errors.append(error)
				}
			}
		}
		guard errors.isEmpty else {
			throw AuthSessionCoordinatorError.credentialStorage(
				errors.map(\.localizedDescription).joined(separator: "; ")
			)
		}
	}

	private func withCredentialStoreLock<T: Sendable>(
		_ operation: @escaping @Sendable () async throws -> T
	) async throws -> T {
		try await CrossProcessFileLock.withExclusive(
			at: credentialStoreLockURL,
			operation: operation
		)
	}

	private func readAuthorityStoreChecked() throws -> CredentialAuthorityStore {
		guard let data = try SecureStateFile.read(
			from: authorityURL,
			maximumBytes: Self.stateFileSizeLimit
		) else { return .empty }
		do {
			guard let rawStore = try JSONSerialization.jsonObject(with: data)
				as? [String: Any],
				Set(rawStore.keys) == ["version", "credentials"]
			else {
				throw AuthSessionCoordinatorError.stateFile(
					"Credential-authority JSON has an invalid shape."
				)
			}
			let store = try JSONDecoder().decode(CredentialAuthorityStore.self, from: data)
			guard store.version == 1 else {
				throw AuthSessionCoordinatorError.stateFile(
					"Unsupported credential-authority schema version \(store.version)."
				)
			}
			for record in store.credentials.values { try record.validate() }
			return store
		} catch let error as AuthSessionCoordinatorError {
			throw error
		} catch {
			throw AuthSessionCoordinatorError.stateFile(
				"Credential-authority JSON is invalid."
			)
		}
	}

	private func writeAuthorityStore(_ store: CredentialAuthorityStore) throws {
		do {
			let encoder = JSONEncoder()
			encoder.outputFormatting = [.sortedKeys]
			try SecureStateFile.write(encoder.encode(store), to: authorityURL)
		} catch let error as AuthSessionCoordinatorError {
			throw error
		} catch {
			throw AuthSessionCoordinatorError.stateFile(
				"Credential-authority metadata could not be committed."
			)
		}
	}

	private func authorityGeneration() throws -> AuthSessionAuthorityGeneration {
		var metadata = stat()
		guard Darwin.lstat(authorityURL.path, &metadata) == 0 else {
			throw AuthSessionCoordinatorError.stateFile(
				"Credential-authority metadata is unavailable."
			)
		}
		guard (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
			metadata.st_uid == Darwin.geteuid(),
			metadata.st_nlink == 1,
			(metadata.st_mode & 0o077) == 0,
			metadata.st_size > 0,
			metadata.st_size <= Self.stateFileSizeLimit
		else {
			throw AuthSessionCoordinatorError.stateFile(
				"Credential-authority metadata is not a secure bounded regular file."
			)
		}
		return AuthSessionAuthorityGeneration(
			device: UInt64(metadata.st_dev),
			inode: UInt64(metadata.st_ino),
			size: metadata.st_size,
			modifiedSeconds: Int64(metadata.st_mtimespec.tv_sec),
			modifiedNanoseconds: Int64(metadata.st_mtimespec.tv_nsec),
			changedSeconds: Int64(metadata.st_ctimespec.tv_sec),
			changedNanoseconds: Int64(metadata.st_ctimespec.tv_nsec)
		)
	}

	private func readExpiryRecordsChecked() throws -> [String: [String: Any]] {
		guard let data = try SecureStateFile.read(
			from: expiryURL,
			maximumBytes: Self.stateFileSizeLimit
		) else { return [:] }
		do {
			guard let records = try JSONSerialization.jsonObject(with: data)
				as? [String: [String: Any]]
			else {
				throw AuthSessionCoordinatorError.stateFile(
					"Token-expiry metadata is not an object."
				)
			}
			for record in records.values {
				guard record["expires"] is String,
					record["reminded_7d"] is Bool,
					record["reminded_1d"] is Bool,
					record["otp_required"].map({ $0 is Bool }) ?? true,
					record["session_access_expires_at"].map({
						$0 is String || $0 is NSNull
					}) ?? true
				else {
					throw AuthSessionCoordinatorError.stateFile(
						"Token-expiry metadata contains an invalid record."
					)
				}
			}
			return records
		} catch let error as AuthSessionCoordinatorError {
			throw error
		} catch {
			throw AuthSessionCoordinatorError.stateFile(
				"Token-expiry JSON is invalid."
			)
		}
	}

	private func writeExpiry(_ expiresAt: String, registryURL: String) async throws {
		try await CrossProcessFileLock.withExclusive(at: expiryLockURL) {
			var records = try readExpiryRecordsChecked()
			var record = records[registryURL] ?? [:]
			record["expires"] = ""
			record["reminded_7d"] = false
			record["reminded_1d"] = false
			record["session_access_expires_at"] = expiresAt
			record["otp_required"] = record["otp_required"] as? Bool ?? false
			records[registryURL] = record
			try writeExpiryRecords(records)
		}
	}

	private func removeExpiry(registryURL: String) async throws {
		try await CrossProcessFileLock.withExclusive(at: expiryLockURL) {
			var records = try readExpiryRecordsChecked()
			guard records.removeValue(forKey: registryURL) != nil else { return }
			try writeExpiryRecords(records)
		}
	}

	private func writeExpiryRecords(_ records: [String: [String: Any]]) throws {
		guard JSONSerialization.isValidJSONObject(records) else {
			throw AuthSessionCoordinatorError.stateFile(
				"Token-expiry metadata cannot be encoded."
			)
		}
		let data = try JSONSerialization.data(
			withJSONObject: records,
			options: [.prettyPrinted, .sortedKeys]
		)
		try SecureStateFile.write(data, to: expiryURL)
	}

	private func shouldRefresh(registryURL: String) throws -> Bool {
		guard let expiry = try accessExpiry(registryURL: registryURL) else { return true }
		return expiry.timeIntervalSince(now()) <= Self.refreshWindow
	}

	private func isExpired(registryURL: String) throws -> Bool {
		guard let expiry = try accessExpiry(registryURL: registryURL) else { return false }
		return expiry <= now()
	}

	private func accessExpiry(registryURL: String) throws -> Date? {
		guard let value = try readExpiryRecordsChecked()[registryURL]?["session_access_expires_at"]
			as? String
		else { return nil }
		guard let expiry = AuthSessionTimestamp.parse(value) else {
			throw AuthSessionCoordinatorError.stateFile(
				"The stored session expiry is invalid."
			)
		}
		return expiry
	}

	private var encryptedFallbackMayExist: Bool {
		FileManager.default.fileExists(
			atPath: lpmDirectory.appendingPathComponent(".credentials").path
		)
	}

	private func readDeviceIdentifier() throws -> String? {
		guard let data = try SecureStateFile.read(
			from: deviceIdentifierURL,
			maximumBytes: 4 * 1024
		),
			let value = String(data: data, encoding: .utf8)?
				.trimmingCharacters(in: .whitespacesAndNewlines),
			value.count == 64,
			value.utf8.allSatisfy(\.isHexDigit)
		else { return nil }
		return value.lowercased()
	}

	private func ensurePrivateDirectory(_ directory: URL) throws {
		try FileManager.default.createDirectory(
			at: directory,
			withIntermediateDirectories: true
		)
		try FileManager.default.setAttributes(
			[.posixPermissions: 0o700],
			ofItemAtPath: directory.path
		)
	}

	private static func randomIdentifier() -> String {
		var bytes = [UInt8](repeating: 0, count: 32)
		if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess {
			return bytes.map { String(format: "%02x", $0) }.joined()
		}
		return SHA256.hash(data: Data(UUID().uuidString.utf8)).hexString
	}
}

/// A writer-preference advisory lock compatible with
/// `lpm_common::paths::with_exclusive_lock`.
enum CrossProcessFileLock {
	private typealias FlockFunction = @convention(c) (Int32, Int32) -> Int32
	private static let blockingQueue = DispatchQueue(
		label: "dev.lpm.vault.auth-file-lock",
		qos: .utility,
		attributes: .concurrent
	)
	private static let processGate = ProcessExclusiveGate()
	private static let flockFunction: FlockFunction = {
		guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "flock") else {
			fatalError("The platform does not provide flock(2).")
		}
		return unsafeBitCast(symbol, to: FlockFunction.self)
	}()

	private final class Handle: @unchecked Sendable {
		private let descriptors: [Int32]

		init(descriptors: [Int32]) {
			self.descriptors = descriptors
		}

		deinit {
			for descriptor in descriptors.reversed() {
				_ = CrossProcessFileLock.flockFunction(descriptor, LOCK_UN)
				_ = Darwin.close(descriptor)
			}
		}
	}

	static func withExclusive<T: Sendable>(
		at path: URL,
		operation: @escaping @Sendable () async throws -> T
	) async throws -> T {
		let gateID = UUID()
		let gatePath = path.standardizedFileURL.path
		let gateCancellation = LockAcquisitionCancellation()
		try await withTaskCancellationHandler {
			try await processGate.acquire(
				path: gatePath,
				id: gateID,
				cancellation: gateCancellation
			)
		} onCancel: {
			gateCancellation.cancel()
			Task { await processGate.cancel(id: gateID) }
		}

		do {
			let value = try await withOSExclusive(at: path, operation: operation)
			await processGate.release(path: gatePath, id: gateID)
			return value
		} catch {
			await processGate.release(path: gatePath, id: gateID)
			throw error
		}
	}

	static func withSingleExclusive<T>(
		at path: URL,
		operation: () throws -> T
	) throws -> T {
		let handle = try acquireSingleExclusive(at: path)
		defer { withExtendedLifetime(handle) {} }
		return try operation()
	}

	private static func withOSExclusive<T: Sendable>(
		at path: URL,
		operation: @escaping @Sendable () async throws -> T
	) async throws -> T {
		let cancellation = LockAcquisitionCancellation()
		let handle = try await withTaskCancellationHandler {
			try Task.checkCancellation()
			return try await withCheckedThrowingContinuation { continuation in
				blockingQueue.async {
					do {
						continuation.resume(
							returning: try acquireExclusive(
								at: path,
								cancellation: cancellation
							)
						)
					} catch {
						continuation.resume(throwing: error)
					}
				}
			}
		} onCancel: {
			cancellation.cancel()
		}
		defer { withExtendedLifetime(handle) {} }
		try Task.checkCancellation()

		// Once the critical section begins, finish it independently of caller
		// cancellation. A refresh token may already be consumed by the server,
		// so abandoning persistence would strand the shared session.
		let transaction = Task.detached(operation: operation)
		let result = await transaction.result
		return try result.get()
	}

	private static func acquireExclusive(
		at path: URL,
		cancellation: LockAcquisitionCancellation
	) throws -> Handle {
		try ensureLockDirectory(path.deletingLastPathComponent())
		let queue = path.appendingSuffix(".writer-queue")
		let intent = path.appendingSuffix(".writer-intent")
		var held: [Int32] = []
		do {
			let queueFD = try openAndLock(
				queue,
				operation: LOCK_SH,
				cancellation: cancellation
			)
			held.append(queueFD)
			let intentFD = try openAndLock(
				intent,
				operation: LOCK_EX,
				cancellation: cancellation
			)
			held.append(intentFD)
			let dataFD = try openAndLock(
				path,
				operation: LOCK_EX,
				cancellation: cancellation
			)
			held.append(dataFD)
			return Handle(descriptors: held)
		} catch {
			for descriptor in held.reversed() {
				_ = flockFunction(descriptor, LOCK_UN)
				_ = Darwin.close(descriptor)
			}
			throw error
		}
	}

	private static func acquireSingleExclusive(at path: URL) throws -> Handle {
		try ensureLockDirectory(path.deletingLastPathComponent())
		return Handle(descriptors: [try openAndLock(path, operation: LOCK_EX)])
	}

	private static func ensureLockDirectory(_ directory: URL) throws {
		try FileManager.default.createDirectory(
			at: directory,
			withIntermediateDirectories: true
		)
		try FileManager.default.setAttributes(
			[.posixPermissions: 0o700],
			ofItemAtPath: directory.path
		)
		if directory.lastPathComponent == "locks" {
			try FileManager.default.setAttributes(
				[.posixPermissions: 0o700],
				ofItemAtPath: directory.deletingLastPathComponent().path
			)
		}
	}

	private static func openAndLock(
		_ path: URL,
		operation: Int32,
		cancellation: LockAcquisitionCancellation? = nil
	) throws -> Int32 {
		let descriptor = Darwin.open(path.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
		guard descriptor >= 0 else {
			throw AuthSessionCoordinatorError.stateFile(
				"Could not open lock \(path.lastPathComponent): \(errnoDescription())."
			)
		}
		guard Darwin.fchmod(descriptor, 0o600) == 0 else {
			let message = errnoDescription()
			_ = Darwin.close(descriptor)
			throw AuthSessionCoordinatorError.stateFile(
				"Could not secure lock \(path.lastPathComponent): \(message)."
			)
		}
		if let cancellation {
			while true {
				if cancellation.isCancelled {
					_ = Darwin.close(descriptor)
					throw CancellationError()
				}
				if flockFunction(descriptor, operation | LOCK_NB) == 0 { break }
				let lockError = errno
				guard lockError == EWOULDBLOCK || lockError == EAGAIN else {
					let message = String(cString: strerror(lockError))
					_ = Darwin.close(descriptor)
					throw AuthSessionCoordinatorError.stateFile(
						"Could not acquire lock \(path.lastPathComponent): \(message)."
					)
				}
				Thread.sleep(forTimeInterval: 0.05)
			}
		} else if flockFunction(descriptor, operation) != 0 {
			let message = errnoDescription()
			_ = Darwin.close(descriptor)
			throw AuthSessionCoordinatorError.stateFile(
				"Could not acquire lock \(path.lastPathComponent): \(message)."
			)
		}
		return descriptor
	}

	private static func errnoDescription() -> String {
		String(cString: strerror(errno))
	}
}

private final class LockAcquisitionCancellation: @unchecked Sendable {
	private let lock = NSLock()
	private var cancelled = false

	var isCancelled: Bool {
		lock.withLock { cancelled }
	}

	func cancel() {
		lock.withLock { cancelled = true }
	}
}

private actor ProcessExclusiveGate {
	private struct WaitQueue {
		var ids: [UUID] = []
		var head = 0

		mutating func append(_ id: UUID) {
			ids.append(id)
		}

		mutating func popFirst() -> UUID? {
			guard head < ids.count else { return nil }
			defer {
				head += 1
				if head >= 64, head * 2 >= ids.count {
					ids.removeFirst(head)
					head = 0
				}
			}
			return ids[head]
		}
	}

	private var ownerByPath: [String: UUID] = [:]
	private var grantedPaths: [UUID: String] = [:]
	private var waiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
	private var queues: [String: WaitQueue] = [:]

	func acquire(
		path: String,
		id: UUID,
		cancellation: LockAcquisitionCancellation
	) async throws {
		if cancellation.isCancelled || Task.isCancelled {
			throw CancellationError()
		}
		if ownerByPath[path] == nil {
			ownerByPath[path] = id
			grantedPaths[id] = path
			return
		}

		try await withCheckedThrowingContinuation {
			(continuation: CheckedContinuation<Void, any Error>) in
			if cancellation.isCancelled || Task.isCancelled {
				continuation.resume(throwing: CancellationError())
				return
			}
			waiters[id] = continuation
			queues[path, default: WaitQueue()].append(id)
		}
	}

	func cancel(id: UUID) {
		if let continuation = waiters.removeValue(forKey: id) {
			continuation.resume(throwing: CancellationError())
		}
	}

	func release(path: String, id: UUID) {
		guard ownerByPath[path] == id else { return }
		grantedPaths.removeValue(forKey: id)

		while var queue = queues[path], let nextID = queue.popFirst() {
			queues[path] = queue
			guard let continuation = waiters.removeValue(forKey: nextID) else {
				continue
			}
			ownerByPath[path] = nextID
			grantedPaths[nextID] = path
			continuation.resume()
			return
		}
		queues.removeValue(forKey: path)
		ownerByPath.removeValue(forKey: path)
	}
}

private enum SecureStateFile {
	static func read(from url: URL, maximumBytes: Int) throws -> Data? {
		let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC)
		if descriptor < 0 {
			if errno == ENOENT { return nil }
			throw AuthSessionCoordinatorError.stateFile(
				"Could not open \(url.lastPathComponent): \(errnoDescription())."
			)
		}
		defer { _ = Darwin.close(descriptor) }

		var metadata = stat()
		guard Darwin.fstat(descriptor, &metadata) == 0 else {
			throw AuthSessionCoordinatorError.stateFile(
				"Could not inspect \(url.lastPathComponent)."
			)
		}
		guard (metadata.st_mode & S_IFMT) == S_IFREG,
			metadata.st_size >= 0,
			metadata.st_size <= maximumBytes
		else {
			throw AuthSessionCoordinatorError.stateFile(
				"\(url.lastPathComponent) is not a bounded regular file."
			)
		}

		var data = Data()
		data.reserveCapacity(Int(metadata.st_size))
		var buffer = [UInt8](repeating: 0, count: 16 * 1024)
		while true {
			let count = buffer.withUnsafeMutableBytes { rawBuffer in
				Darwin.read(descriptor, rawBuffer.baseAddress, rawBuffer.count)
			}
			if count == 0 { break }
			if count < 0 {
				if errno == EINTR { continue }
				throw AuthSessionCoordinatorError.stateFile(
					"Could not read \(url.lastPathComponent): \(errnoDescription())."
				)
			}
			guard data.count + count <= maximumBytes else {
				throw AuthSessionCoordinatorError.stateFile(
					"\(url.lastPathComponent) exceeded its size limit."
				)
			}
			data.append(buffer, count: count)
		}
		return data
	}

	static func write(_ data: Data, to url: URL) throws {
		let directory = url.deletingLastPathComponent()
		try FileManager.default.createDirectory(
			at: directory,
			withIntermediateDirectories: true
		)
		try FileManager.default.setAttributes(
			[.posixPermissions: 0o700],
			ofItemAtPath: directory.path
		)

		let temporary = directory.appendingPathComponent(
			".\(url.lastPathComponent).tmp.\(UUID().uuidString)"
		)
		let descriptor = Darwin.open(
			temporary.path,
			O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC,
			0o600
		)
		guard descriptor >= 0 else {
			throw AuthSessionCoordinatorError.stateFile(
				"Could not create temporary metadata: \(errnoDescription())."
			)
		}
		guard Darwin.fchmod(descriptor, 0o600) == 0 else {
			let message = errnoDescription()
			_ = Darwin.close(descriptor)
			_ = Darwin.unlink(temporary.path)
			throw AuthSessionCoordinatorError.stateFile(
				"Could not secure temporary metadata: \(message)."
			)
		}

		var shouldRemoveTemporary = true
		defer {
			_ = Darwin.close(descriptor)
			if shouldRemoveTemporary { _ = Darwin.unlink(temporary.path) }
		}

		try data.withUnsafeBytes { rawBuffer in
			var offset = 0
			while offset < rawBuffer.count {
				let written = Darwin.write(
					descriptor,
					rawBuffer.baseAddress!.advanced(by: offset),
					rawBuffer.count - offset
				)
				if written < 0 {
					if errno == EINTR { continue }
					throw AuthSessionCoordinatorError.stateFile(
						"Could not write metadata: \(errnoDescription())."
					)
				}
				offset += written
			}
		}
		guard Darwin.fsync(descriptor) == 0 else {
			throw AuthSessionCoordinatorError.stateFile(
				"Could not sync metadata: \(errnoDescription())."
			)
		}
		guard Darwin.rename(temporary.path, url.path) == 0 else {
			throw AuthSessionCoordinatorError.stateFile(
				"Could not commit metadata: \(errnoDescription())."
			)
		}
		shouldRemoveTemporary = false
		let directoryDescriptor = Darwin.open(directory.path, O_RDONLY | O_CLOEXEC)
		guard directoryDescriptor >= 0 else {
			throw AuthSessionCoordinatorError.stateFile(
				"Could not open the metadata directory: \(errnoDescription())."
			)
		}
		defer { _ = Darwin.close(directoryDescriptor) }
		guard Darwin.fsync(directoryDescriptor) == 0 else {
			throw AuthSessionCoordinatorError.stateFile(
				"Could not sync the metadata directory: \(errnoDescription())."
			)
		}
	}

	private static func errnoDescription() -> String {
		String(cString: strerror(errno))
	}
}

private extension Sequence where Element == UInt8 {
	var hexString: String {
		map { String(format: "%02x", $0) }.joined()
	}
}

private extension UInt8 {
	var isHexDigit: Bool {
		(self >= 48 && self <= 57) || (self >= 65 && self <= 70) || (self >= 97 && self <= 102)
	}

	var isLowercaseHexDigit: Bool {
		(self >= 48 && self <= 57) || (self >= 97 && self <= 102)
	}
}

private extension URL {
	func appendingSuffix(_ suffix: String) -> URL {
		deletingLastPathComponent()
			.appendingPathComponent(lastPathComponent + suffix)
	}
}
