import Darwin
import Foundation
import OSLog
import Security

private let keychainLogger = Logger(subsystem: "dev.lpm.vault", category: "Keychain")

@_silgen_name("flock")
private func lpmFileLock(_ descriptor: Int32, _ operation: Int32) -> Int32

enum VaultKeychainTransactionLock {
	private final class State: @unchecked Sendable {
		let processLock = NSRecursiveLock()
		var depth = 0
		var descriptor: Int32 = -1
	}

	private static let state = State()
	private static let lockName = ".vault-keychain.lock"

	static func withLock<T>(_ operation: () throws -> T) throws -> T {
		state.processLock.lock()
		if state.depth == 0 {
			do {
				state.descriptor = try openLockFile()
			} catch {
				state.processLock.unlock()
				throw error
			}
		}
		state.depth += 1
		defer {
			state.depth -= 1
			if state.depth == 0 {
				_ = lpmFileLock(state.descriptor, LOCK_UN)
				_ = Darwin.close(state.descriptor)
				state.descriptor = -1
			}
			state.processLock.unlock()
		}
		return try operation()
	}

	private static func openLockFile() throws -> Int32 {
		let homeURL = FileManager.default.homeDirectoryForCurrentUser
		let homeDescriptor = homeURL.withUnsafeFileSystemRepresentation { path in
			guard let path else { return Int32(-1) }
			return Darwin.open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
		}
		guard homeDescriptor >= 0 else {
			throw KeychainStoreError.status(operation: "open home directory", code: OSStatus(errno))
		}
		defer { _ = Darwin.close(homeDescriptor) }

		let lpmName = ".lpm"
		if lpmName.withCString({ Darwin.mkdirat(homeDescriptor, $0, 0o700) }) != 0,
			errno != EEXIST
		{
			throw KeychainStoreError.status(
				operation: "create transaction directory", code: OSStatus(errno))
		}
		let directoryDescriptor = lpmName.withCString {
			Darwin.openat(homeDescriptor, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
		}
		guard directoryDescriptor >= 0 else {
			throw KeychainStoreError.status(
				operation: "open transaction directory", code: OSStatus(errno))
		}
		defer { _ = Darwin.close(directoryDescriptor) }

		var directoryMetadata = stat()
		guard Darwin.fstat(directoryDescriptor, &directoryMetadata) == 0,
			(directoryMetadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
			directoryMetadata.st_uid == Darwin.geteuid(),
			Darwin.fchmod(directoryDescriptor, 0o700) == 0
		else {
			let code = errno == 0 ? EPERM : errno
			throw KeychainStoreError.status(
				operation: "validate transaction directory", code: OSStatus(code))
		}

		let descriptor = lockName.withCString {
			Darwin.openat(
				directoryDescriptor,
				$0,
				O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
				0o600
			)
		}
		guard descriptor >= 0 else {
			throw KeychainStoreError.status(
				operation: "open transaction lock", code: OSStatus(errno))
		}

		var metadata = stat()
		guard Darwin.fstat(descriptor, &metadata) == 0,
			(metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
			metadata.st_uid == Darwin.geteuid(),
			Darwin.fchmod(descriptor, 0o600) == 0
		else {
			let code = errno == 0 ? EPERM : errno
			_ = Darwin.close(descriptor)
			throw KeychainStoreError.status(
				operation: "validate transaction lock", code: OSStatus(code))
		}

		while lpmFileLock(descriptor, LOCK_EX) != 0 {
			if errno == EINTR { continue }
			let code = errno
			_ = Darwin.close(descriptor)
			throw KeychainStoreError.status(
				operation: "acquire transaction lock", code: OSStatus(code))
		}
		return descriptor
	}
}

// MARK: - Protocol

protocol KeychainServiceProtocol: Sendable {
	func withKeychainTransaction<T>(_ operation: () -> T) -> Result<T, KeychainError>
	func listProjects() -> [VaultProject]
	func getEnvironments(vaultId: String) -> [String: [String: String]]?
	func saveEnvironments(
		vaultId: String,
		projectName: String,
		projectPath: String,
		environments: [String: [String: String]]
	) -> KeychainResult
	func createEnvironments(
		vaultId: String,
		projectName: String,
		projectPath: String,
		environments: [String: [String: String]]
	) -> KeychainResult
	func deleteProject(vaultId: String) -> Bool
	func removeFromSidebar(vaultId: String) -> Bool

	// Generic data storage (for metadata, associations, etc.)
	func readData(account: String) -> Data?
	func readDataResult(account: String) -> Result<Data?, KeychainError>
	@discardableResult func writeData(account: String, data: Data) -> Bool
	@discardableResult func deleteData(account: String) -> Bool

	// Legacy compatibility
	func getSecrets(vaultId: String) -> [String: String]?
	func saveSecrets(
		vaultId: String,
		projectName: String,
		projectPath: String,
		secrets: [String: String]
	) -> KeychainResult
}

enum KeychainResult: Sendable {
	case success
	case successWithWarning(String)
	case failure(KeychainError)
}

enum KeychainError: Error, CustomStringConvertible, Sendable {
	case encodingFailed
	case itemNotFound
	case accessDenied
	case keychainLocked
	case missingEntitlement
	case duplicateItem
	case unexpectedStatus(OSStatus)
	case dataTooLarge(Int)

	var description: String {
		switch self {
		case .encodingFailed:
			return "Failed to encode secrets as JSON"
		case .itemNotFound:
			return "Keychain item not found"
		case .accessDenied:
			return "Keychain access denied. Open Keychain Access and allow LPM Vault."
		case .keychainLocked:
			return "The Data Protection Keychain is locked. Unlock your login Keychain and retry."
		case .missingEntitlement:
			return
				"This LPM Vault build is not signed for the shared Keychain access group. Install an official build."
		case .duplicateItem:
			return "Keychain item already exists"
		case .unexpectedStatus(let status):
			return "Keychain error: \(status)"
		case .dataTooLarge(let size):
			return "Env project data too large: \(size) bytes (Keychain limit ~100KB)"
		}
	}

}

enum KeychainStoreLocation: Equatable, Sendable {
	case shared
	case legacy
}

enum KeychainStoreError: Error, LocalizedError, Equatable, Sendable {
	case status(operation: String, code: OSStatus)
	case migrationConflict
	case migrationVerificationFailed

	var errorDescription: String? {
		switch self {
		case .status(_, let code) where code == errSecMissingEntitlement:
			"This LPM build is not signed for the shared Keychain access group. Install an official build."
		case .status(let operation, let code):
			"Keychain \(operation) failed (OSStatus \(code))."
		case .migrationConflict:
			"Keychain values changed during a secure update. Finish other LPM operations and retry."
		case .migrationVerificationFailed:
			"Keychain migration verification failed. The legacy value was preserved."
		}
	}

	var statusCode: OSStatus? {
		guard case .status(_, let code) = self else { return nil }
		return code
	}
}

protocol KeychainStoreBackend {
	func read(service: String, account: String, location: KeychainStoreLocation) throws -> Data?
	func write(service: String, account: String, data: Data, location: KeychainStoreLocation) throws
	func add(service: String, account: String, data: Data, location: KeychainStoreLocation) throws
	@discardableResult
	func delete(service: String, account: String, location: KeychainStoreLocation) throws -> Bool
}

struct SecurityKeychainStoreBackend: KeychainStoreBackend {
	static func identityQuery(
		service: String,
		account: String,
		location: KeychainStoreLocation
	) throws -> [String: Any] {
		var query: [String: Any] = [
			kSecClass as String: kSecClassGenericPassword,
			kSecAttrService as String: service,
			kSecAttrAccount as String: account,
		]
		switch location {
		case .shared:
			query[kSecAttrAccessGroup as String] = VaultConstants.keychainAccessGroup
			query[kSecUseDataProtectionKeychain as String] = true
		case .legacy:
			var defaultKeychain: SecKeychain?
			let status = SecKeychainCopyDefault(&defaultKeychain)
			guard status == errSecSuccess, let defaultKeychain else {
				throw KeychainStoreError.status(operation: "locate legacy keychain", code: status)
			}
			query[kSecUseKeychain as String] = defaultKeychain
		}
		return query
	}

	func read(service: String, account: String, location: KeychainStoreLocation) throws -> Data? {
		var query = try Self.identityQuery(service: service, account: account, location: location)
		query[kSecReturnData as String] = true
		query[kSecMatchLimit as String] = kSecMatchLimitOne

		var result: AnyObject?
		let status = SecItemCopyMatching(query as CFDictionary, &result)
		if status == errSecItemNotFound { return nil }
		guard status == errSecSuccess else {
			throw KeychainStoreError.status(operation: "read", code: status)
		}
		guard let data = result as? Data else {
			throw KeychainStoreError.status(operation: "read", code: errSecInternalComponent)
		}
		return data
	}

	func write(
		service: String,
		account: String,
		data: Data,
		location: KeychainStoreLocation
	) throws {
		let query = try Self.identityQuery(service: service, account: account, location: location)
		let attributes: [String: Any] = [kSecValueData as String: data]
		let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
		if updateStatus == errSecSuccess { return }
		guard updateStatus == errSecItemNotFound else {
			throw KeychainStoreError.status(operation: "write", code: updateStatus)
		}

		do {
			try add(service: service, account: account, data: data, location: location)
		} catch KeychainStoreError.status(_, errSecDuplicateItem) {
			let retryStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
			guard retryStatus == errSecSuccess else {
				throw KeychainStoreError.status(operation: "write", code: retryStatus)
			}
		}
	}

	func add(
		service: String,
		account: String,
		data: Data,
		location: KeychainStoreLocation
	) throws {
		var query = try Self.identityQuery(service: service, account: account, location: location)
		query[kSecValueData as String] = data
		if location == .shared {
			query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
		}
		let status = SecItemAdd(query as CFDictionary, nil)
		guard status == errSecSuccess else {
			throw KeychainStoreError.status(operation: "add", code: status)
		}
	}

	func delete(
		service: String,
		account: String,
		location: KeychainStoreLocation
	) throws -> Bool {
		let query = try Self.identityQuery(service: service, account: account, location: location)
		let status = SecItemDelete(query as CFDictionary)
		if status == errSecItemNotFound { return false }
		guard status == errSecSuccess else {
			throw KeychainStoreError.status(operation: "delete", code: status)
		}
		return true
	}
}

final class SharedKeychainStore: @unchecked Sendable {
	private static let legacyCutoverAccount = "__legacy_keychain_cutover_v1__"
	private static let legacyCutoverValue = Data("protected-only-v1".utf8)
	private static let reconciliationAttempts = 3

	enum Mode: Equatable, Sendable {
		case shared
		case legacyTesting
	}

	private let service: String
	private let backend: any KeychainStoreBackend
	private let mode: Mode

	init(
		service: String,
		backend: any KeychainStoreBackend = SecurityKeychainStoreBackend(),
		mode: Mode = .shared
	) {
		self.service = service
		self.backend = backend
		self.mode = mode
	}

	func read(account: String) throws -> Data? {
		try VaultKeychainTransactionLock.withLock {
			if mode == .legacyTesting {
				return try backend.read(service: service, account: account, location: .legacy)
			}
			return try readReconciled(account: account)
		}
	}

	func write(account: String, data: Data) throws {
		try VaultKeychainTransactionLock.withLock {
			if mode == .legacyTesting {
				try backend.write(service: service, account: account, data: data, location: .legacy)
				return
			}

			let previous = try readReconciled(account: account)
			let compatibilityActive = try legacyCompatibilityActive()
			if compatibilityActive {
				try backend.write(service: service, account: account, data: data, location: .legacy)
				guard
					try backend.read(service: service, account: account, location: .legacy) == data
				else {
					throw KeychainStoreError.migrationConflict
				}
			}
			do {
				try writeSharedWithRetry(account: account, data: data)
				guard try backend.read(service: service, account: account, location: .shared) == data
				else {
					throw KeychainStoreError.migrationConflict
				}
				if compatibilityActive {
					guard
						try backend.read(
							service: service, account: account, location: .legacy) == data
					else {
						throw KeychainStoreError.migrationConflict
					}
				}
			} catch {
				let operationError = error
				if compatibilityActive {
					try restoreLegacy(
						account: account, attempted: data, previous: previous)
				}
				throw operationError
			}
		}
	}

	func add(account: String, data: Data) throws {
		try VaultKeychainTransactionLock.withLock {
			if mode == .legacyTesting {
				guard try backend.read(service: service, account: account, location: .legacy) == nil
				else {
					throw KeychainStoreError.status(operation: "add", code: errSecDuplicateItem)
				}
				try backend.add(service: service, account: account, data: data, location: .legacy)
				guard try backend.read(service: service, account: account, location: .legacy) == data
				else {
					throw KeychainStoreError.migrationConflict
				}
				return
			}

			let existing = try readReconciled(account: account)
			let compatibilityActive = try legacyCompatibilityActive()
			if let existing {
				if compatibilityActive, existing == data { return }
				throw KeychainStoreError.status(operation: "add", code: errSecDuplicateItem)
			}
			if compatibilityActive {
				do {
					try backend.add(service: service, account: account, data: data, location: .legacy)
				} catch let error as KeychainStoreError where error.statusCode == errSecDuplicateItem {
					_ = try readReconciled(account: account)
					throw error
				}
				guard try backend.read(service: service, account: account, location: .legacy) == data
				else {
					throw KeychainStoreError.migrationConflict
				}
			}
			do {
				try addSharedWithRetry(account: account, data: data)
				guard try backend.read(service: service, account: account, location: .shared) == data
				else {
					throw KeychainStoreError.migrationConflict
				}
				if compatibilityActive {
					guard
						try backend.read(
							service: service, account: account, location: .legacy) == data
					else {
						throw KeychainStoreError.migrationConflict
					}
				}
			} catch {
				let operationError = error
				if compatibilityActive {
					try restoreLegacy(account: account, attempted: data, previous: nil)
				}
				throw operationError
			}
		}
	}

	private func writeSharedWithRetry(account: String, data: Data) throws {
		do {
			try backend.write(service: service, account: account, data: data, location: .shared)
		} catch {
			if try backend.read(service: service, account: account, location: .shared) == data {
				return
			}
			try backend.write(service: service, account: account, data: data, location: .shared)
		}
	}

	private func addSharedWithRetry(account: String, data: Data) throws {
		do {
			try backend.add(service: service, account: account, data: data, location: .shared)
		} catch {
			if try backend.read(service: service, account: account, location: .shared) == data {
				return
			}
			try backend.add(service: service, account: account, data: data, location: .shared)
		}
	}

	private func restoreLegacy(account: String, attempted: Data, previous: Data?) throws {
		guard try backend.read(service: service, account: account, location: .legacy) == attempted
		else {
			throw KeychainStoreError.migrationConflict
		}
		if let previous {
			try backend.write(
				service: service, account: account, data: previous, location: .legacy)
		} else {
			_ = try backend.delete(service: service, account: account, location: .legacy)
		}
		guard try backend.read(service: service, account: account, location: .legacy) == previous
		else {
			throw KeychainStoreError.migrationVerificationFailed
		}
	}

	@discardableResult
	func delete(account: String) throws -> Bool {
		try VaultKeychainTransactionLock.withLock {
			if mode == .legacyTesting {
				return try backend.delete(service: service, account: account, location: .legacy)
			}
			guard try readReconciled(account: account) != nil else { return false }
			let deletedLegacy = try backend.delete(
				service: service, account: account, location: .legacy)
			let deletedShared = try backend.delete(
				service: service, account: account, location: .shared)
			return deletedLegacy || deletedShared
		}
	}

	private func readReconciled(account: String) throws -> Data? {
		guard try legacyCompatibilityActive() else {
			return try backend.read(service: service, account: account, location: .shared)
		}

		// Until the coordinated cutover, the released CLI can update only the
		// legacy item. Repair the protected copy from that authoritative value.
		for _ in 0..<Self.reconciliationAttempts {
			let legacy = try backend.read(service: service, account: account, location: .legacy)
			let shared = try backend.read(service: service, account: account, location: .shared)
			guard let legacy else {
				guard let shared else { return nil }
				do {
					try backend.add(
						service: service,
						account: account,
						data: shared,
						location: .legacy
					)
				} catch let error as KeychainStoreError where error.statusCode == errSecDuplicateItem {
					continue
				}
				guard
					try backend.read(service: service, account: account, location: .legacy) == shared,
					try backend.read(service: service, account: account, location: .shared) == shared
				else {
					throw KeychainStoreError.migrationVerificationFailed
				}
				return shared
			}

			if shared != legacy {
				try backend.write(
					service: service, account: account, data: legacy, location: .shared)
			}

			let verifiedShared = try backend.read(
				service: service,
				account: account,
				location: .shared
			)
			let verifiedLegacy = try backend.read(
				service: service,
				account: account,
				location: .legacy
			)
			if verifiedLegacy != legacy { continue }
			guard verifiedShared == legacy else {
				throw KeychainStoreError.migrationVerificationFailed
			}
			return legacy
		}
		throw KeychainStoreError.migrationConflict
	}

	private func legacyCompatibilityActive() throws -> Bool {
		switch try backend.read(
			service: service,
			account: Self.legacyCutoverAccount,
			location: .shared
		) {
		case nil:
			return true
		case Self.legacyCutoverValue:
			return false
		case .some:
			throw KeychainStoreError.migrationConflict
		}
	}

}

// MARK: - Index Entry (stored in a separate Keychain item for reliable listing)

private struct VaultIndexEntry: Codable {
	let id: String
	var name: String
	var path: String
}

// MARK: - Environments Wrapper (new Keychain data format)

/// Wraps environment data so we can distinguish from the old flat format.
private struct EnvironmentsWrapper: Codable {
	let environments: [String: [String: String]]
}

// MARK: - Implementation

/// Keychain-backed vault storage.
///
/// Uses two types of Keychain items per service:
/// 1. **Index item** (account: `__index__`) — JSON array of `{id, name, path}` for project discovery
/// 2. **Data items** (account: `{vault-id}`) — JSON dict of secrets per project
///
/// This design avoids `kSecMatchLimitAll` which is unreliable in some macOS contexts.
final class KeychainService: KeychainServiceProtocol, @unchecked Sendable {
	private let store: SharedKeychainStore
	private let indexAccount = "__index__"

	init() {
		self.store = SharedKeychainStore(service: VaultConstants.keychainService)
	}

	#if DEBUG
		init(legacyTestingService: String) {
			self.store = SharedKeychainStore(service: legacyTestingService, mode: .legacyTesting)
		}
	#endif

	// MARK: - Public API

	func withKeychainTransaction<T>(_ operation: () -> T) -> Result<T, KeychainError> {
		do {
			return .success(try VaultKeychainTransactionLock.withLock(operation))
		} catch let error as KeychainStoreError {
			return .failure(keychainError(from: error))
		} catch {
			return .failure(.unexpectedStatus(errSecInternalComponent))
		}
	}

	func listProjects() -> [VaultProject] {
		let index = readIndex()
		return index.map { entry in
			let environments = getEnvironments(vaultId: entry.id) ?? ["default": [:]]
			return VaultProject(
				id: entry.id,
				name: entry.name,
				path: entry.path,
				environments: environments
			)
		}
	}

	/// Read environments from Keychain. Handles backwards compatibility:
	/// - New format: `{"environments": {"local": {...}, "live": {...}}}`
	/// - Old format: `{"KEY": "VALUE"}` → migrated to `{"default": {"KEY": "VALUE"}}`
	func getEnvironments(vaultId: String) -> [String: [String: String]]? {
		guard let data = readItem(account: vaultId) else { return nil }

		// Try new format first
		if let wrapper = try? JSONDecoder().decode(EnvironmentsWrapper.self, from: data) {
			return wrapper.environments
		}

		// Fall back to old flat format → wrap in "default"
		if let flat = try? JSONDecoder().decode([String: String].self, from: data) {
			return ["default": flat]
		}

		return nil
	}

	func saveEnvironments(
		vaultId: String,
		projectName: String,
		projectPath: String,
		environments: [String: [String: String]]
	) -> KeychainResult {
		guard EnvValidation.isSafeVaultId(vaultId) else {
			return .failure(.accessDenied)
		}
		let wrapper = EnvironmentsWrapper(environments: environments)
		guard let data = try? JSONEncoder().encode(wrapper) else {
			return .failure(.encodingFailed)
		}
		return saveData(
			vaultId: vaultId, projectName: projectName, projectPath: projectPath, data: data)
	}

	/// Creates a new env project without ever updating an existing Keychain
	/// account. This is the import boundary shared with the Rust CLI.
	func createEnvironments(
		vaultId: String,
		projectName: String,
		projectPath: String,
		environments: [String: [String: String]]
	) -> KeychainResult {
		guard EnvValidation.isSafeVaultId(vaultId) else { return .failure(.accessDenied) }
		let wrapper = EnvironmentsWrapper(environments: environments)
		guard let data = try? JSONEncoder().encode(wrapper) else {
			return .failure(.encodingFailed)
		}
		guard data.count <= VaultConstants.maxVaultSizeWarning else {
			return .failure(.dataTooLarge(data.count))
		}

		do {
			return try VaultKeychainTransactionLock.withLock {
				let previousIndex = try readIndexThrowing()
				try store.add(account: vaultId, data: data)
				var index = previousIndex
				index.append(VaultIndexEntry(id: vaultId, name: projectName, path: projectPath))
				do {
					try writeIndexThrowing(index)
				} catch {
					_ = try store.delete(account: vaultId)
					try writeIndexThrowing(previousIndex)
					throw error
				}
				if data.count > VaultConstants.maxVaultSizeWarning * 9 / 10 {
					return .successWithWarning(
						"Env project is approaching size limit (\(data.count) bytes)")
				}
				return .success
			}
		} catch let error as KeychainStoreError where error.statusCode == errSecDuplicateItem {
			return .failure(.duplicateItem)
		} catch let error as KeychainStoreError {
			return .failure(keychainError(from: error))
		} catch {
			return .failure(.unexpectedStatus(errSecInternalComponent))
		}
	}

	// Generic data storage
	func readData(account: String) -> Data? {
		try? readDataResult(account: account).get()
	}

	func readDataResult(account: String) -> Result<Data?, KeychainError> {
		do {
			return .success(try readItemThrowing(account: account))
		} catch let error as KeychainStoreError {
			return .failure(keychainError(from: error))
		} catch {
			return .failure(.unexpectedStatus(errSecInternalComponent))
		}
	}

	@discardableResult
	func writeData(account: String, data: Data) -> Bool {
		writeItem(account: account, data: data)
	}

	@discardableResult
	func deleteData(account: String) -> Bool {
		do {
			_ = try store.delete(account: account)
			return true
		} catch {
			return false
		}
	}

	// Legacy compatibility
	func getSecrets(vaultId: String) -> [String: String]? {
		getEnvironments(vaultId: vaultId)?["default"]
	}

	func saveSecrets(
		vaultId: String,
		projectName: String,
		projectPath: String,
		secrets: [String: String]
	) -> KeychainResult {
		do {
			return try VaultKeychainTransactionLock.withLock {
				var environments = try getEnvironmentsThrowing(vaultId: vaultId) ?? [:]
				environments["default"] = secrets
				return saveEnvironments(
					vaultId: vaultId,
					projectName: projectName,
					projectPath: projectPath,
					environments: environments
				)
			}
		} catch let error as KeychainStoreError {
			return .failure(keychainError(from: error))
		} catch {
			return .failure(.unexpectedStatus(errSecInternalComponent))
		}
	}

	// MARK: - Data Save (shared)

	private func saveData(
		vaultId: String,
		projectName: String,
		projectPath: String,
		data: Data
	) -> KeychainResult {

		if data.count > VaultConstants.maxVaultSizeWarning {
			return .failure(.dataTooLarge(data.count))
		}

		let warning =
			data.count > VaultConstants.maxVaultSizeWarning * 9 / 10
			? "Env project is approaching size limit (\(data.count) bytes)"
			: nil

		do {
			return try VaultKeychainTransactionLock.withLock {
				let previousData = try readItemThrowing(account: vaultId)
				let previousIndex = try readIndexThrowing()
				try writeItemThrowing(account: vaultId, data: data)

				var index = previousIndex
				if let i = index.firstIndex(where: { $0.id == vaultId }) {
					index[i].name = projectName
					index[i].path = projectPath
				} else {
					index.append(VaultIndexEntry(id: vaultId, name: projectName, path: projectPath))
				}
				do {
					try writeIndexThrowing(index)
				} catch {
					if let previousData {
						try writeItemThrowing(account: vaultId, data: previousData)
					} else {
						_ = try store.delete(account: vaultId)
					}
					try writeIndexThrowing(previousIndex)
					throw error
				}

				return warning.map(KeychainResult.successWithWarning) ?? .success
			}
		} catch let error as KeychainStoreError {
			return .failure(keychainError(from: error))
		} catch {
			return .failure(.unexpectedStatus(errSecInternalComponent))
		}
	}

	func deleteProject(vaultId: String) -> Bool {
		do {
			return try VaultKeychainTransactionLock.withLock {
				let previousData = try readItemThrowing(account: vaultId)
				let previousIndex = try readIndexThrowing()
				_ = try store.delete(account: vaultId)

				var index = previousIndex
				index.removeAll { $0.id == vaultId }
				do {
					try writeIndexThrowing(index)
				} catch {
					if let previousData {
						try writeItemThrowing(account: vaultId, data: previousData)
					}
					try writeIndexThrowing(previousIndex)
					throw error
				}
				return true
			}
		} catch {
			return false
		}
	}

	/// Remove from sidebar only — keeps Keychain data intact.
	/// The project can be re-added by opening the same folder.
	func removeFromSidebar(vaultId: String) -> Bool {
		do {
			return try VaultKeychainTransactionLock.withLock {
				var index = try readIndexThrowing()
				index.removeAll { $0.id == vaultId }
				try writeIndexThrowing(index)
				return true
			}
		} catch {
			return false
		}
	}

	// MARK: - Private: Low-level Keychain Operations

	private func readItem(account: String) -> Data? {
		do {
			return try readItemThrowing(account: account)
		} catch {
			keychainLogger.error(
				"Keychain read failed: \(String(describing: error), privacy: .public)")
			return nil
		}
	}

	private func writeItem(account: String, data: Data) -> Bool {
		do {
			try writeItemThrowing(account: account, data: data)
			return true
		} catch {
			keychainLogger.error(
				"Keychain write failed: \(String(describing: error), privacy: .public)")
			return false
		}
	}

	private func readItemThrowing(account: String) throws -> Data? {
		try store.read(account: account)
	}

	private func writeItemThrowing(account: String, data: Data) throws {
		try store.write(account: account, data: data)
	}

	private func keychainError(from error: KeychainStoreError) -> KeychainError {
		return switch error.statusCode {
		case errSecItemNotFound:
			.itemNotFound
		case errSecDuplicateItem:
			.duplicateItem
		case errSecAuthFailed:
			.accessDenied
		case errSecInteractionNotAllowed:
			.keychainLocked
		case errSecMissingEntitlement:
			.missingEntitlement
		case let status?:
			.unexpectedStatus(status)
		case nil:
			.unexpectedStatus(errSecInternalComponent)
		}
	}

	// MARK: - Private: Index Management

	private func readIndex() -> [VaultIndexEntry] {
		do {
			return try readIndexThrowing()
		} catch {
			keychainLogger.error(
				"Keychain index read failed: \(String(describing: error), privacy: .public)")
			return []
		}
	}

	@discardableResult
	private func writeIndex(_ entries: [VaultIndexEntry]) -> Bool {
		do {
			try writeIndexThrowing(entries)
			return true
		} catch {
			return false
		}
	}

	private func readIndexThrowing() throws -> [VaultIndexEntry] {
		guard let data = try readItemThrowing(account: indexAccount) else { return [] }
		return try JSONDecoder().decode([VaultIndexEntry].self, from: data)
	}

	private func writeIndexThrowing(_ entries: [VaultIndexEntry]) throws {
		let data = try JSONEncoder().encode(entries)
		try writeItemThrowing(account: indexAccount, data: data)
	}

	private func getEnvironmentsThrowing(vaultId: String) throws -> [String: [String: String]]? {
		guard let data = try readItemThrowing(account: vaultId) else { return nil }
		if let wrapper = try? JSONDecoder().decode(EnvironmentsWrapper.self, from: data) {
			return wrapper.environments
		}
		if let flat = try? JSONDecoder().decode([String: String].self, from: data) {
			return ["default": flat]
		}
		throw KeychainStoreError.status(operation: "decode vault data", code: errSecDecode)
	}
}
