import Darwin
import CryptoKit
import Foundation
import OSLog
import Security

private let keychainLogger = Logger(subsystem: "dev.lpm.vault", category: "Keychain")

enum VaultKeychainRecordContract {
	static let projectIndexMarkerAccount = "__vault_project_index_marker__"
	static let projectMetadataPrefix = "__vault_project_metadata__:"
	static let projectDiscoveryPrefix = "__vault_project_discovery__:"
	static let projectIndexSchemaVersion = 3
	static let syncMetadataRecordPrefix = "__sync_metadata__:"
	static let syncMetadataSchemaVersion = 3
}

@_silgen_name("flock")
private func lpmFileLock(_ descriptor: Int32, _ operation: Int32) -> Int32

enum VaultKeychainTransactionLock {
	private final class State: @unchecked Sendable {
		let processLock = NSRecursiveLock()
		var depth = 0
		var descriptor: Int32 = -1
		var recoveredStores = Set<ObjectIdentifier>()
	}

	private static let state = State()
	private static let lockName = ".vault-keychain.lock"
	private static let directoryName = ".lpm"

	private static func validateDirectory(
		_ descriptor: Int32,
		in homeDescriptor: Int32
	) throws {
		var descriptorMetadata = stat()
		guard Darwin.fstat(descriptor, &descriptorMetadata) == 0 else {
			throw KeychainStoreError.status(
				operation: "inspect transaction directory", code: OSStatus(errno))
		}
		var pathMetadata = stat()
		let pathStatus = directoryName.withCString {
			Darwin.fstatat(homeDescriptor, $0, &pathMetadata, AT_SYMLINK_NOFOLLOW)
		}
		guard pathStatus == 0,
			(descriptorMetadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
			(pathMetadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
			descriptorMetadata.st_uid == Darwin.geteuid(),
			pathMetadata.st_uid == Darwin.geteuid(),
			descriptorMetadata.st_dev == pathMetadata.st_dev,
			descriptorMetadata.st_ino == pathMetadata.st_ino,
			descriptorMetadata.st_mode & 0o777 == 0o700,
			pathMetadata.st_mode & 0o777 == 0o700
		else {
			throw KeychainStoreError.status(
				operation: "validate transaction directory", code: OSStatus(EPERM))
		}
	}

	private static func validateLockFile(
		_ descriptor: Int32,
		in directoryDescriptor: Int32,
		requireSecurePermissions: Bool
	) throws {
		var descriptorMetadata = stat()
		guard Darwin.fstat(descriptor, &descriptorMetadata) == 0 else {
			throw KeychainStoreError.status(
				operation: "inspect transaction lock", code: OSStatus(errno))
		}
		var pathMetadata = stat()
		let pathStatus = lockName.withCString {
			Darwin.fstatat(directoryDescriptor, $0, &pathMetadata, AT_SYMLINK_NOFOLLOW)
		}
		guard pathStatus == 0 else {
			throw KeychainStoreError.status(
				operation: "inspect transaction lock path", code: OSStatus(errno))
		}
		guard (descriptorMetadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
			(pathMetadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
			descriptorMetadata.st_uid == Darwin.geteuid(),
			pathMetadata.st_uid == Darwin.geteuid(),
			descriptorMetadata.st_nlink == 1,
			pathMetadata.st_nlink == 1,
			descriptorMetadata.st_dev == pathMetadata.st_dev,
			descriptorMetadata.st_ino == pathMetadata.st_ino,
			!requireSecurePermissions || descriptorMetadata.st_mode & 0o777 == 0o600
		else {
			throw KeychainStoreError.status(
				operation: "validate transaction lock", code: OSStatus(EPERM))
		}
	}

	static func withLock<T>(_ operation: () throws -> T) throws -> T {
		state.processLock.lock()
		if state.depth == 0 {
			state.recoveredStores.removeAll(keepingCapacity: true)
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
				state.recoveredStores.removeAll(keepingCapacity: true)
				_ = lpmFileLock(state.descriptor, LOCK_UN)
				_ = Darwin.close(state.descriptor)
				state.descriptor = -1
			}
			state.processLock.unlock()
		}
		return try operation()
	}

	static func hasRecovered(_ store: AnyObject) -> Bool {
		precondition(state.depth > 0)
		return state.recoveredStores.contains(ObjectIdentifier(store))
	}

	static func markRecovered(_ store: AnyObject) {
		precondition(state.depth > 0)
		state.recoveredStores.insert(ObjectIdentifier(store))
	}

	static func openLockFile(
		homeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
		beforeLock: () throws -> Void = {}
	) throws -> Int32 {
		let homeDescriptor = homeURL.withUnsafeFileSystemRepresentation { path in
			guard let path else { return Int32(-1) }
			return Darwin.open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
		}
		guard homeDescriptor >= 0 else {
			throw KeychainStoreError.status(operation: "open home directory", code: OSStatus(errno))
		}
		defer { _ = Darwin.close(homeDescriptor) }

		if directoryName.withCString({ Darwin.mkdirat(homeDescriptor, $0, 0o700) }) != 0,
			errno != EEXIST
		{
			throw KeychainStoreError.status(
				operation: "create transaction directory", code: OSStatus(errno))
		}
		let directoryDescriptor = directoryName.withCString {
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
		try validateDirectory(directoryDescriptor, in: homeDescriptor)
		guard descriptor >= 0 else {
			throw KeychainStoreError.status(
				operation: "open transaction lock", code: OSStatus(errno))
		}

		var isLocked = false
		do {
			try validateLockFile(
				descriptor,
				in: directoryDescriptor,
				requireSecurePermissions: false
			)
			guard Darwin.fchmod(descriptor, 0o600) == 0 else {
				throw KeychainStoreError.status(
					operation: "secure transaction lock", code: OSStatus(errno))
			}
			try validateLockFile(
				descriptor,
				in: directoryDescriptor,
				requireSecurePermissions: true
			)
			try validateDirectory(directoryDescriptor, in: homeDescriptor)
			try beforeLock()
			try validateDirectory(directoryDescriptor, in: homeDescriptor)
			try validateLockFile(
				descriptor,
				in: directoryDescriptor,
				requireSecurePermissions: true
			)
			while lpmFileLock(descriptor, LOCK_EX) != 0 {
				if errno == EINTR { continue }
				throw KeychainStoreError.status(
					operation: "acquire transaction lock", code: OSStatus(errno))
			}
			isLocked = true
			try validateDirectory(directoryDescriptor, in: homeDescriptor)
			try validateLockFile(
				descriptor,
				in: directoryDescriptor,
				requireSecurePermissions: true
			)
			return descriptor
		} catch {
			if isLocked { _ = lpmFileLock(descriptor, LOCK_UN) }
			_ = Darwin.close(descriptor)
			throw error
		}
	}
}

// MARK: - Protocol

protocol KeychainServiceProtocol: Sendable {
	func withKeychainTransaction<T>(_ operation: () -> T) -> Result<T, KeychainError>
	func listProjects() -> [VaultProject]
	func listProjectsResult() -> Result<[VaultProject], KeychainError>
	func listProjectMetadataResult() -> Result<[VaultProjectMetadata], KeychainError>
	func getProjectResult(vaultId: String) -> Result<VaultProject?, KeychainError>
	func getEnvironments(vaultId: String) -> [String: [String: String]]?
	func getEnvironmentsResult(
		vaultId: String
	) -> Result<[String: [String: String]]?, KeychainError>
	func saveEnvironments(
		vaultId: String,
		projectName: String,
		projectPath: String,
		environments: [String: [String: String]]
	) -> KeychainResult
	func updateEnvironments(
		vaultId: String,
		environments: [String: [String: String]]
	) -> KeychainResult
	func createEnvironments(
		vaultId: String,
		projectName: String,
		projectPath: String,
		environments: [String: [String: String]]
	) -> KeychainResult
	func removeFromSidebar(vaultId: String) -> Bool
	func applyVaultTransaction(
		project: VaultProjectKeychainMutation?,
		data: [VaultKeychainMutation]
	) -> KeychainResult

	// Generic data storage (for metadata, associations, etc.)
	func readData(account: String) -> Data?
	func readDataResult(account: String) -> Result<Data?, KeychainError>
	@discardableResult func writeData(account: String, data: Data) -> Bool
	@discardableResult func deleteData(account: String) -> Bool

}

enum VaultProjectKeychainMutation: Sendable {
	case create(VaultProject)
	case upsert(VaultProject)
	case update(vaultId: String, environments: [String: [String: String]])
	case delete(vaultId: String, deletePayload: Bool)
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
	case syncCheckpointCapacity
	case projectDiscoveryCapacity
	case transactionOutcomeIndeterminate

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
		case .syncCheckpointCapacity:
			return "This env project has reached the secure sync-authority history limit."
		case .projectDiscoveryCapacity:
			return "The local env-project discovery store has reached its capacity."
		case .transactionOutcomeIndeterminate:
			return "The Keychain transaction may have committed. Local state must be reloaded before another write."
		}
	}

}

enum KeychainStoreError: Error, LocalizedError, Equatable, Sendable {
	case status(operation: String, code: OSStatus)
	case concurrentModification
	case integrityValidationFailed
	case projectDiscoveryCapacity
	case dataTooLarge(Int)
	case transactionOutcomeIndeterminate

	var errorDescription: String? {
		switch self {
		case .status(_, let code) where code == errSecMissingEntitlement:
			"This LPM build is not signed for the shared Keychain access group. Install an official build."
		case .status(let operation, let code):
			"Keychain \(operation) failed (OSStatus \(code))."
		case .concurrentModification:
			"Keychain values changed during a secure update. Finish other LPM operations and retry."
		case .integrityValidationFailed:
			"Keychain transaction integrity validation failed. Reload local state before another write."
		case .projectDiscoveryCapacity:
			"The local env-project discovery store has reached its capacity."
		case .dataTooLarge(let byteCount):
			"Env project data too large: \(byteCount) bytes (Keychain limit ~100KB)."
		case .transactionOutcomeIndeterminate:
			"The Keychain transaction may have committed and must be recovered before another write."
		}
	}

	var statusCode: OSStatus? {
		if case .status(_, let code) = self { return code }
		return nil
	}
}

protocol KeychainStoreBackend {
	func read(service: String, account: String) throws -> Data?
	func write(service: String, account: String, data: Data) throws
	func add(service: String, account: String, data: Data) throws
	@discardableResult
	func delete(service: String, account: String) throws -> Bool
}

struct SecurityKeychainStoreBackend: KeychainStoreBackend {
	private static func scopedQuery(service: String) -> [String: Any] {
		[
			kSecClass as String: kSecClassGenericPassword,
			kSecAttrService as String: service,
			kSecAttrAccessGroup as String: VaultConstants.keychainAccessGroup,
			kSecUseDataProtectionKeychain as String: true,
		]
	}

	static func identityQuery(
		service: String,
		account: String
	) -> [String: Any] {
		var query = scopedQuery(service: service)
		query[kSecAttrAccount as String] = account
		return query
	}

	func read(service: String, account: String) throws -> Data? {
		var query = Self.identityQuery(service: service, account: account)
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
		data: Data
	) throws {
		let query = Self.identityQuery(service: service, account: account)
		let attributes: [String: Any] = [kSecValueData as String: data]
		let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
		if updateStatus == errSecSuccess { return }
		guard updateStatus == errSecItemNotFound else {
			throw KeychainStoreError.status(operation: "write", code: updateStatus)
		}

		do {
			try add(service: service, account: account, data: data)
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
		data: Data
	) throws {
		var query = Self.identityQuery(service: service, account: account)
		query[kSecValueData as String] = data
		query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
		let status = SecItemAdd(query as CFDictionary, nil)
		guard status == errSecSuccess else {
			throw KeychainStoreError.status(operation: "add", code: status)
		}
	}

	func delete(
		service: String,
		account: String
	) throws -> Bool {
		let query = Self.identityQuery(service: service, account: account)
		let status = SecItemDelete(query as CFDictionary)
		if status == errSecItemNotFound { return false }
		guard status == errSecSuccess else {
			throw KeychainStoreError.status(operation: "delete", code: status)
		}
		return true
	}
}

struct VaultKeychainMutation: Sendable {
	let account: String
	let data: Data?
	fileprivate let liveValidation: VaultKeychainLiveValidation?

	static func write(account: String, data: Data) -> Self {
		Self(account: account, data: data, liveValidation: nil)
	}

	fileprivate static func write(
		account: String,
		preparedProjectPayload: PreparedProjectPayload
	) -> Self {
		Self(
			account: account,
			data: preparedProjectPayload.data,
			liveValidation: .projectPayload
		)
	}

	static func delete(account: String) -> Self {
		Self(account: account, data: nil, liveValidation: nil)
	}
}

private enum VaultKeychainLiveValidation: Equatable, Sendable {
	case projectPayload
}

struct VaultKeychainPerformanceSnapshot: Sendable {
	let projectPayloadParseCount: Int
	let projectPayloadHashCount: Int
	let livePayloadReuseCount: Int
}

final class VaultKeychainPerformanceCounters: @unchecked Sendable {
	private let lock = NSLock()
	private var projectPayloadParses = 0
	private var projectPayloadHashes = 0
	private var livePayloadReuses = 0

	var snapshot: VaultKeychainPerformanceSnapshot {
		lock.withLock {
			VaultKeychainPerformanceSnapshot(
				projectPayloadParseCount: projectPayloadParses,
				projectPayloadHashCount: projectPayloadHashes,
				livePayloadReuseCount: livePayloadReuses
			)
		}
	}

	fileprivate func recordProjectPayloadParse() {
		lock.withLock { projectPayloadParses += 1 }
	}

	fileprivate func recordProjectPayloadHash() {
		lock.withLock { projectPayloadHashes += 1 }
	}

	fileprivate func recordLivePayloadReuse() {
		lock.withLock { livePayloadReuses += 1 }
	}
}

private enum VaultTransactionState: String, Codable {
	case preparing
	case committed
}

private enum VaultTransactionRecovery {
	case none
	case discardedPreparing
	case rolledForwardCommitted
}

private struct VaultTransactionJournal: Codable {
	let schemaVersion: Int
	let transactionId: String
	var state: VaultTransactionState
	let operations: [VaultTransactionJournalOperation]
}

private struct VaultTransactionJournalOperation: Codable {
	let action: String
	let targetAccount: String
	let stagedAccount: String?
	let operationSha256: String
}

struct StrictJSONKeyValidator {
	struct ValidationProfile {
		let materializedStringCount: Int
		let copiedInputByteCount: Int
	}

	private static let maximumNestingDepth = 128
	private static let trueLiteral: [UInt8] = [0x74, 0x72, 0x75, 0x65]
	private static let falseLiteral: [UInt8] = [0x66, 0x61, 0x6C, 0x73, 0x65]
	private static let nullLiteral: [UInt8] = [0x6E, 0x75, 0x6C, 0x6C]
	private let bytes: UnsafeBufferPointer<UInt8>
	private var index = 0
	private var materializedStringCount = 0

	static func validate(_ data: Data) throws {
		_ = try validationProfile(data)
	}

	static func validationProfile(_ data: Data) throws -> ValidationProfile {
		try data.withUnsafeBytes { rawBytes in
			var parser = Self(bytes: rawBytes.bindMemory(to: UInt8.self))
			try parser.parseValue(depth: 0)
			parser.skipWhitespace()
			guard parser.index == parser.bytes.count else {
				throw KeychainStoreError.integrityValidationFailed
			}
			return ValidationProfile(
				materializedStringCount: parser.materializedStringCount,
				copiedInputByteCount: 0
			)
		}
	}

	private mutating func parseValue(depth: Int) throws {
		skipWhitespace()
		guard let byte = current else {
			throw KeychainStoreError.integrityValidationFailed
		}
		switch byte {
		case 0x7B:
			guard depth < Self.maximumNestingDepth else {
				throw KeychainStoreError.integrityValidationFailed
			}
			try parseObject(depth: depth)
		case 0x5B:
			guard depth < Self.maximumNestingDepth else {
				throw KeychainStoreError.integrityValidationFailed
			}
			try parseArray(depth: depth)
		case 0x22:
			_ = try parseString(materialize: false)
		case 0x74:
			try consumeLiteral(Self.trueLiteral)
		case 0x66:
			try consumeLiteral(Self.falseLiteral)
		case 0x6E:
			try consumeLiteral(Self.nullLiteral)
		case 0x2D, 0x30...0x39:
			try parseNumber()
		default:
			throw KeychainStoreError.integrityValidationFailed
		}
	}

	private mutating func parseObject(depth: Int) throws {
		try consume(0x7B)
		skipWhitespace()
		if consumeIfPresent(0x7D) { return }
		var keys: Set<String> = []
		while true {
			skipWhitespace()
			guard let key = try parseString(materialize: true) else {
				throw KeychainStoreError.integrityValidationFailed
			}
			guard keys.insert(key).inserted else {
				throw KeychainStoreError.integrityValidationFailed
			}
			skipWhitespace()
			try consume(0x3A)
			try parseValue(depth: depth + 1)
			skipWhitespace()
			if consumeIfPresent(0x7D) { return }
			try consume(0x2C)
		}
	}

	private mutating func parseArray(depth: Int) throws {
		try consume(0x5B)
		skipWhitespace()
		if consumeIfPresent(0x5D) { return }
		while true {
			try parseValue(depth: depth + 1)
			skipWhitespace()
			if consumeIfPresent(0x5D) { return }
			try consume(0x2C)
		}
	}

	private mutating func parseString(materialize: Bool) throws -> String? {
		try consume(0x22)
		var decoded = ""
		while let byte = current {
			switch byte {
			case 0x22:
				index += 1
				if materialize {
					materializedStringCount += 1
					return decoded
				}
				return nil
			case 0x5C:
				index += 1
				guard let escape = current else {
					throw KeychainStoreError.integrityValidationFailed
				}
				index += 1
				let scalar: UnicodeScalar
				if escape == 0x75 {
					scalar = try parseEscapedUnicodeScalar()
				} else {
					guard let escapedScalar = Self.escapedScalar(for: escape) else {
						throw KeychainStoreError.integrityValidationFailed
					}
					scalar = escapedScalar
				}
				if materialize { decoded.unicodeScalars.append(scalar) }
			case 0x00...0x1F:
				throw KeychainStoreError.integrityValidationFailed
			case 0x20...0x7F:
				index += 1
				if materialize, let scalar = UnicodeScalar(Int(byte)) {
					decoded.unicodeScalars.append(scalar)
				}
			default:
				let scalar = try consumeUTF8Scalar()
				if materialize { decoded.unicodeScalars.append(scalar) }
			}
		}
		throw KeychainStoreError.integrityValidationFailed
	}

	private mutating func parseEscapedUnicodeScalar() throws -> UnicodeScalar {
		let first = try consumeHexQuad()
		let value: UInt32
		if (0xD800...0xDBFF).contains(first) {
			guard consumeIfPresent(0x5C), consumeIfPresent(0x75) else {
				throw KeychainStoreError.integrityValidationFailed
			}
			let second = try consumeHexQuad()
			guard (0xDC00...0xDFFF).contains(second) else {
				throw KeychainStoreError.integrityValidationFailed
			}
			value = 0x10000 + ((first - 0xD800) << 10) + (second - 0xDC00)
		} else {
			guard !(0xDC00...0xDFFF).contains(first) else {
				throw KeychainStoreError.integrityValidationFailed
			}
			value = first
		}
		guard let scalar = UnicodeScalar(value) else {
			throw KeychainStoreError.integrityValidationFailed
		}
		return scalar
	}

	private mutating func consumeHexQuad() throws -> UInt32 {
		guard index + 4 <= bytes.count else {
			throw KeychainStoreError.integrityValidationFailed
		}
		var value: UInt32 = 0
		for _ in 0..<4 {
			guard let nibble = Self.hexValue(bytes[index]) else {
				throw KeychainStoreError.integrityValidationFailed
			}
			value = value << 4 | UInt32(nibble)
			index += 1
		}
		return value
	}

	private mutating func consumeUTF8Scalar() throws -> UnicodeScalar {
		let first = bytes[index]
		let length: Int
		let minimum: UInt32
		var value: UInt32
		switch first {
		case 0xC2...0xDF:
			length = 2
			minimum = 0x80
			value = UInt32(first & 0x1F)
		case 0xE0...0xEF:
			length = 3
			minimum = 0x800
			value = UInt32(first & 0x0F)
		case 0xF0...0xF4:
			length = 4
			minimum = 0x10000
			value = UInt32(first & 0x07)
		default:
			throw KeychainStoreError.integrityValidationFailed
		}
		guard index + length <= bytes.count else {
			throw KeychainStoreError.integrityValidationFailed
		}
		for offset in 1..<length {
			let continuation = bytes[index + offset]
			guard (0x80...0xBF).contains(continuation) else {
				throw KeychainStoreError.integrityValidationFailed
			}
			value = value << 6 | UInt32(continuation & 0x3F)
		}
		guard value >= minimum,
			value <= 0x10FFFF,
			!(0xD800...0xDFFF).contains(value),
			let scalar = UnicodeScalar(value)
		else {
			throw KeychainStoreError.integrityValidationFailed
		}
		index += length
		return scalar
	}

	private static func escapedScalar(for byte: UInt8) -> UnicodeScalar? {
		let value: UInt32? = switch byte {
		case 0x22: 0x22
		case 0x5C: 0x5C
		case 0x2F: 0x2F
		case 0x62: 0x08
		case 0x66: 0x0C
		case 0x6E: 0x0A
		case 0x72: 0x0D
		case 0x74: 0x09
		default: nil
		}
		return value.flatMap(UnicodeScalar.init)
	}

	private mutating func parseNumber() throws {
		_ = consumeIfPresent(0x2D)
		guard let first = current else {
			throw KeychainStoreError.integrityValidationFailed
		}
		if first == 0x30 {
			index += 1
			if current.map(Self.isDigit) == true {
				throw KeychainStoreError.integrityValidationFailed
			}
		} else {
			guard (0x31...0x39).contains(first) else {
				throw KeychainStoreError.integrityValidationFailed
			}
			consumeDigits()
		}
		if consumeIfPresent(0x2E) {
			guard current.map(Self.isDigit) == true else {
				throw KeychainStoreError.integrityValidationFailed
			}
			consumeDigits()
		}
		if current == 0x65 || current == 0x45 {
			index += 1
			if current == 0x2B || current == 0x2D { index += 1 }
			guard current.map(Self.isDigit) == true else {
				throw KeychainStoreError.integrityValidationFailed
			}
			consumeDigits()
		}
	}

	private mutating func consumeDigits() {
		while current.map(Self.isDigit) == true { index += 1 }
	}

	private mutating func consumeLiteral(_ literal: [UInt8]) throws {
		guard index + literal.count <= bytes.count,
			bytes[index..<(index + literal.count)].elementsEqual(literal)
		else { throw KeychainStoreError.integrityValidationFailed }
		index += literal.count
	}

	private mutating func consume(_ expected: UInt8) throws {
		guard consumeIfPresent(expected) else {
			throw KeychainStoreError.integrityValidationFailed
		}
	}

	private mutating func consumeIfPresent(_ expected: UInt8) -> Bool {
		guard current == expected else { return false }
		index += 1
		return true
	}

	private mutating func skipWhitespace() {
		while let byte = current {
			switch byte {
			case 0x20, 0x09, 0x0A, 0x0D: index += 1
			default: return
			}
		}
	}

	private var current: UInt8? {
		index < bytes.count ? bytes[index] : nil
	}

	private static func isDigit(_ byte: UInt8) -> Bool {
		(0x30...0x39).contains(byte)
	}

	private static func hexValue(_ byte: UInt8) -> UInt8? {
		switch byte {
		case 0x30...0x39: byte - 0x30
		case 0x41...0x46: byte - 0x41 + 10
		case 0x61...0x66: byte - 0x61 + 10
		default: nil
		}
	}
}

final class SharedKeychainStore: @unchecked Sendable {
	private static let transactionMarkerAccount = "__vault_transaction_v3__"
	private static let transactionStagePrefix = "__vault_transaction_stage_v3__:"
	private static let transactionSchemaVersion = 3
	private static let maximumTransactionOperations = 32
	private static let maximumTransactionMarkerBytes = 64 * 1024
	private static let maximumTransactionValueBytes = 100 * 1024
	private static let operationDigestDomain = Data("lpm-vault-transaction-operation\0".utf8)
	private static let lowercaseHex = Array("0123456789abcdef".utf8)

	private let service: String
	private let backend: any KeychainStoreBackend
	private let performanceCounters: VaultKeychainPerformanceCounters?

	init(
		service: String,
		backend: any KeychainStoreBackend = SecurityKeychainStoreBackend(),
		performanceCounters: VaultKeychainPerformanceCounters? = nil
	) {
		self.service = service
		self.backend = backend
		self.performanceCounters = performanceCounters
	}

	func applyVaultTransaction(_ mutations: [VaultKeychainMutation]) throws {
		try VaultKeychainTransactionLock.withLock {
			try ensureRecoveredUnlocked()
			guard !mutations.isEmpty,
				mutations.count <= Self.maximumTransactionOperations,
				Set(mutations.map(\.account)).count == mutations.count
			else { throw KeychainStoreError.concurrentModification }

			let transactionId = UUID().uuidString.lowercased()
			let operations = try mutations.enumerated().map { index, mutation in
				try validateTransactionTarget(
					account: mutation.account,
					data: mutation.data,
					liveValidation: mutation.liveValidation
				)
				if let data = mutation.data {
					return VaultTransactionJournalOperation(
						action: "write",
						targetAccount: mutation.account,
						stagedAccount: transactionStageAccount(
							transactionId: transactionId, index: index),
						operationSha256: operationSha256(
							action: "write", targetAccount: mutation.account, data: data)
					)
				}
				return VaultTransactionJournalOperation(
					action: "delete",
					targetAccount: mutation.account,
					stagedAccount: nil,
					operationSha256: operationSha256(
						action: "delete", targetAccount: mutation.account, data: nil)
				)
			}
			var journal = VaultTransactionJournal(
				schemaVersion: Self.transactionSchemaVersion,
				transactionId: transactionId,
				state: .preparing,
				operations: operations
			)
			var commitWasVerified = false
			do {
				try writeJournalUnlocked(journal)
				for (mutation, operation) in zip(mutations, operations) {
					if let data = mutation.data, let stage = operation.stagedAccount {
						try writeVerifiedUnlocked(account: stage, data: data)
					}
				}
				journal.state = .committed
				try writeJournalUnlocked(journal)
				commitWasVerified = true
				try rollForwardVaultTransactionUnlocked(journal, liveMutations: mutations)
			} catch {
				let operationError = error
				do {
					let recovery = try recoverVaultTransactionUnlocked()
					let completedAfterMarkerRemoval: Bool
					if commitWasVerified, recovery == .none {
						completedAfterMarkerRemoval = try transactionIsFullyAppliedUnlocked(journal)
					} else {
						completedAfterMarkerRemoval = false
					}
					if recovery == .rolledForwardCommitted
						|| completedAfterMarkerRemoval
					{
						return
					}
				} catch {
					throw KeychainStoreError.transactionOutcomeIndeterminate
				}
				throw operationError
			}
		}
	}

	func recoverVaultTransaction() throws {
		try VaultKeychainTransactionLock.withLock {
			try ensureRecoveredUnlocked()
		}
	}

	private func ensureRecoveredUnlocked() throws {
		guard !VaultKeychainTransactionLock.hasRecovered(self) else { return }
		_ = try recoverVaultTransactionUnlocked()
		VaultKeychainTransactionLock.markRecovered(self)
	}

	private func recoverVaultTransactionUnlocked() throws -> VaultTransactionRecovery {
		guard let markerData = try backend.read(
			service: service,
			account: Self.transactionMarkerAccount
		) else { return .none }
		guard markerData.count <= Self.maximumTransactionMarkerBytes,
			let journal = try? decodeTransactionJournal(markerData)
		else { throw KeychainStoreError.integrityValidationFailed }
		try validateTransactionJournal(journal)
		switch journal.state {
		case .preparing:
			for operation in journal.operations {
				if let stage = operation.stagedAccount {
					try deleteVerifiedUnlocked(account: stage)
				}
			}
			try deleteVerifiedUnlocked(account: Self.transactionMarkerAccount)
			return .discardedPreparing
		case .committed:
			try rollForwardVaultTransactionUnlocked(journal)
			return .rolledForwardCommitted
		}
	}

	private func rollForwardVaultTransactionUnlocked(
		_ journal: VaultTransactionJournal,
		liveMutations: [VaultKeychainMutation]? = nil
	) throws {
		for (index, operation) in journal.operations.enumerated() {
			switch operation.action {
			case "write":
				guard let stage = operation.stagedAccount
				else { throw KeychainStoreError.integrityValidationFailed }
				if let liveMutation = liveMutations?[index],
					liveMutation.account == operation.targetAccount,
					let data = liveMutation.data
				{
					performanceCounters?.recordLivePayloadReuse()
					try writeVerifiedUnlocked(account: operation.targetAccount, data: data)
				} else if let data = try backend.read(
					service: service, account: stage)
				{
					guard data.count <= Self.maximumTransactionValueBytes,
						operationSha256(
							action: "write",
							targetAccount: operation.targetAccount,
							data: data
						) == operation.operationSha256
					else { throw KeychainStoreError.integrityValidationFailed }
					try validateTransactionTarget(account: operation.targetAccount, data: data)
					try writeVerifiedUnlocked(account: operation.targetAccount, data: data)
				} else {
					guard let target = try backend.read(
						service: service,
						account: operation.targetAccount
					), operationSha256(
						action: "write",
						targetAccount: operation.targetAccount,
						data: target
					) == operation.operationSha256
					else { throw KeychainStoreError.integrityValidationFailed }
					try validateTransactionTarget(account: operation.targetAccount, data: target)
				}
			case "delete":
				guard operationSha256(
					action: "delete",
					targetAccount: operation.targetAccount,
					data: nil
				) == operation.operationSha256 else {
					throw KeychainStoreError.integrityValidationFailed
				}
				try deleteVerifiedUnlocked(account: operation.targetAccount)
			default:
				throw KeychainStoreError.integrityValidationFailed
			}
		}
		for operation in journal.operations {
			if let stage = operation.stagedAccount {
				try deleteVerifiedUnlocked(account: stage)
			}
		}
		try deleteVerifiedUnlocked(account: Self.transactionMarkerAccount)
	}

	private func transactionIsFullyAppliedUnlocked(
		_ journal: VaultTransactionJournal
	) throws -> Bool {
		guard try backend.read(service: service, account: Self.transactionMarkerAccount) == nil
		else { return false }
		for operation in journal.operations {
			if let stage = operation.stagedAccount,
				try backend.read(service: service, account: stage) != nil
			{
				return false
			}
			switch operation.action {
			case "write":
				guard let target = try backend.read(
						service: service, account: operation.targetAccount),
					operationSha256(
						action: "write",
						targetAccount: operation.targetAccount,
						data: target
					) == operation.operationSha256
				else { return false }
			case "delete":
				guard try backend.read(
					service: service, account: operation.targetAccount) == nil
				else { return false }
			default:
				return false
			}
		}
		return true
	}

	private func writeJournalUnlocked(_ journal: VaultTransactionJournal) throws {
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.sortedKeys]
		let data = try encoder.encode(journal)
		guard data.count <= Self.maximumTransactionMarkerBytes else {
			throw KeychainStoreError.integrityValidationFailed
		}
		try writeVerifiedUnlocked(account: Self.transactionMarkerAccount, data: data)
	}

	private func decodeTransactionJournal(_ data: Data) throws -> VaultTransactionJournal {
		let object = try jsonObject(data)
		guard Set(object.keys) == ["schemaVersion", "transactionId", "state", "operations"],
			let operations = object["operations"] as? [[String: Any]]
		else { throw KeychainStoreError.integrityValidationFailed }
		for operation in operations {
			guard let action = operation["action"] as? String else {
				throw KeychainStoreError.integrityValidationFailed
			}
			let expectedKeys: Set<String> = switch action {
			case "write": ["action", "targetAccount", "stagedAccount", "operationSha256"]
			case "delete": ["action", "targetAccount", "operationSha256"]
			default: []
			}
			guard !expectedKeys.isEmpty, Set(operation.keys) == expectedKeys else {
				throw KeychainStoreError.integrityValidationFailed
			}
		}
		return try JSONDecoder().decode(VaultTransactionJournal.self, from: data)
	}

	private func jsonObject(_ data: Data) throws -> [String: Any] {
		try StrictJSONKeyValidator.validate(data)
		guard let object = try JSONSerialization.jsonObject(
			with: data,
			options: [.fragmentsAllowed]
		) as? [String: Any] else {
			throw KeychainStoreError.integrityValidationFailed
		}
		return object
	}

	private func requireExactObjectKeys(_ data: Data, _ expected: Set<String>) throws {
		guard Set(try jsonObject(data).keys) == expected else {
			throw KeychainStoreError.integrityValidationFailed
		}
	}

	private func validateTransactionJournal(_ journal: VaultTransactionJournal) throws {
		guard journal.schemaVersion == Self.transactionSchemaVersion,
			journal.transactionId == UUID(uuidString: journal.transactionId)?.uuidString.lowercased(),
			!journal.operations.isEmpty,
			journal.operations.count <= Self.maximumTransactionOperations,
			Set(journal.operations.map(\.targetAccount)).count == journal.operations.count
		else { throw KeychainStoreError.integrityValidationFailed }
		for (index, operation) in journal.operations.enumerated() {
			try validateTransactionTarget(account: operation.targetAccount, data: nil)
			switch operation.action {
			case "write":
				guard operation.stagedAccount == transactionStageAccount(
					transactionId: journal.transactionId, index: index),
					operation.operationSha256.count == 64,
					operation.operationSha256.utf8.allSatisfy({
						(48...57).contains($0) || (97...102).contains($0)
					})
				else { throw KeychainStoreError.integrityValidationFailed }
			case "delete":
				guard operation.stagedAccount == nil,
					operation.operationSha256 == operationSha256(
						action: "delete",
						targetAccount: operation.targetAccount,
						data: nil
					)
				else {
					throw KeychainStoreError.integrityValidationFailed
				}
			default:
				throw KeychainStoreError.integrityValidationFailed
			}
		}
	}

	private func writeVerifiedUnlocked(account: String, data: Data) throws {
		try backend.write(service: service, account: account, data: data)
		guard try backend.read(service: service, account: account) == data
		else { throw KeychainStoreError.integrityValidationFailed }
	}

	private func deleteVerifiedUnlocked(account: String) throws {
		_ = try backend.delete(service: service, account: account)
		guard try backend.read(service: service, account: account) == nil
		else { throw KeychainStoreError.integrityValidationFailed }
	}

	private func transactionStageAccount(transactionId: String, index: Int) -> String {
		Self.transactionStagePrefix + transactionId + ":\(index)"
	}

	private func operationSha256(
		action: String,
		targetAccount: String,
		data: Data?
	) -> String {
		if data != nil, EnvValidation.isSafeVaultId(targetAccount) {
			performanceCounters?.recordProjectPayloadHash()
		}
		var hasher = SHA256()
		hasher.update(data: Self.operationDigestDomain)
		hasher.update(data: Data(action.utf8))
		hasher.update(data: Data([0]))
		hasher.update(data: Data(targetAccount.utf8))
		hasher.update(data: Data([0]))
		if let data { hasher.update(data: data) }
		let digest = hasher.finalize()
		var encoded = [UInt8](repeating: 0, count: SHA256.byteCount * 2)
		for (index, byte) in digest.enumerated() {
			encoded[index * 2] = Self.lowercaseHex[Int(byte >> 4)]
			encoded[index * 2 + 1] = Self.lowercaseHex[Int(byte & 0x0F)]
		}
		return String(decoding: encoded, as: UTF8.self)
	}

	private func validateTransactionTarget(
		account: String,
		data: Data?,
		liveValidation: VaultKeychainLiveValidation? = nil
	) throws {
		guard account.utf8.count <= 512,
			account != Self.transactionMarkerAccount,
			!account.hasPrefix(Self.transactionStagePrefix),
			data?.count ?? 0 <= Self.maximumTransactionValueBytes
		else { throw KeychainStoreError.integrityValidationFailed }
		if EnvValidation.isSafeVaultId(account) {
			if let data {
				if liveValidation == .projectPayload { return }
				performanceCounters?.recordProjectPayloadParse()
				try requireExactObjectKeys(data, ["environments"])
				let payload = try JSONDecoder().decode(EnvironmentsWrapper.self, from: data)
				let environments = payload.environments.isEmpty
					? ["default": [:]]
					: payload.environments
				guard EnvValidation.areValidEnvironments(environments)
				else { throw KeychainStoreError.integrityValidationFailed }
			}
			return
		}
		if account == VaultKeychainRecordContract.projectIndexMarkerAccount {
			if let data {
				try requireExactObjectKeys(
					data, ["schemaVersion", "storageId", "activeShards", "writableShard"])
				let marker = try JSONDecoder().decode(VaultProjectIndexMarker.self, from: data)
				guard marker.schemaVersion == VaultKeychainRecordContract.projectIndexSchemaVersion,
					isValidStorageID(marker.storageId),
					marker.activeShards.count <= 1_024,
					marker.activeShards == marker.activeShards.sorted(),
					Set(marker.activeShards).count == marker.activeShards.count,
					marker.activeShards.allSatisfy({ 0..<1_024 ~= $0 }),
					marker.writableShard.map(marker.activeShards.contains) ?? true
				else { throw KeychainStoreError.integrityValidationFailed }
			}
			return
		}
		if account.hasPrefix(VaultKeychainRecordContract.projectMetadataPrefix) {
			try validateProjectMetadataTarget(account: account, data: data)
			return
		}
		if account.hasPrefix(VaultKeychainRecordContract.projectDiscoveryPrefix) {
			try validateProjectDiscoveryTarget(account: account, data: data)
			return
		}
		if account == "__org_associations__" {
			if let data {
				try StrictJSONKeyValidator.validate(data)
				let associations = try JSONDecoder().decode([String: String].self, from: data)
				guard associations.allSatisfy({
					EnvValidation.isSafeVaultId($0.key) && EnvValidation.isSafeOrgSlug($0.value)
				}) else { throw KeychainStoreError.integrityValidationFailed }
			}
			return
		}
		if account.hasPrefix(VaultKeychainRecordContract.syncMetadataRecordPrefix) {
			try validateSyncMetadataTarget(account: account, data: data)
			return
		}
		throw KeychainStoreError.integrityValidationFailed
	}

	private func validateProjectMetadataTarget(account: String, data: Data?) throws {
		let prefix = VaultKeychainRecordContract.projectMetadataPrefix
		let suffix = account.dropFirst(prefix.count)
		guard let separator = suffix.firstIndex(of: ":") else {
			throw KeychainStoreError.integrityValidationFailed
		}
		let storageID = String(suffix[..<separator])
		let encodedID = String(suffix[suffix.index(after: separator)...])
		guard isValidStorageID(storageID), let vaultID = decodeVaultID(encodedID) else {
			throw KeychainStoreError.integrityValidationFailed
		}
		if let data {
			try requireExactObjectKeys(data, [
				"schemaVersion", "storageId", "id", "name", "path", "discoveryShard",
				"environmentSummaries",
			])
			let record = try JSONDecoder().decode(VaultProjectMetadataRecord.self, from: data)
			guard record.schemaVersion == VaultKeychainRecordContract.projectIndexSchemaVersion,
				record.storageId == storageID,
				record.id == vaultID,
				0..<1_024 ~= record.discoveryShard,
				isValidEnvironmentSummaries(record.environmentSummaries),
				account == projectMetadataAccount(storageID: storageID, vaultID: record.id)
			else { throw KeychainStoreError.integrityValidationFailed }
		}
	}

	private func validateProjectDiscoveryTarget(account: String, data: Data?) throws {
		let prefix = VaultKeychainRecordContract.projectDiscoveryPrefix
		let suffix = account.dropFirst(prefix.count)
		guard let separator = suffix.firstIndex(of: ":") else {
			throw KeychainStoreError.integrityValidationFailed
		}
		let storageID = String(suffix[..<separator])
		let encodedShard = String(suffix[suffix.index(after: separator)...])
		guard isValidStorageID(storageID), encodedShard.count == 3,
			let shard = Int(encodedShard, radix: 16), 0..<1_024 ~= shard
		else { throw KeychainStoreError.integrityValidationFailed }
		if let data {
			try requireExactObjectKeys(
				data, ["schemaVersion", "storageId", "shard", "ids"])
			let record = try JSONDecoder().decode(VaultProjectDiscoveryShard.self, from: data)
			guard record.schemaVersion == VaultKeychainRecordContract.projectIndexSchemaVersion,
				record.storageId == storageID,
				record.shard == shard,
				record.ids.count <= 128,
				record.ids == record.ids.sorted(),
				Set(record.ids).count == record.ids.count,
				record.ids.allSatisfy(EnvValidation.isSafeVaultId),
				account == projectDiscoveryAccount(storageID: storageID, shard: shard)
			else { throw KeychainStoreError.integrityValidationFailed }
		}
	}

	private func validateSyncMetadataTarget(account: String, data: Data?) throws {
		let prefix = VaultKeychainRecordContract.syncMetadataRecordPrefix
		guard let vaultID = decodeVaultID(String(account.dropFirst(prefix.count))),
			account == prefix + encodeVaultID(vaultID)
		else {
			throw KeychainStoreError.integrityValidationFailed
		}
		if let data {
			try requireExactObjectKeys(data, ["schemaVersion", "vaultId", "metadata"])
			let object = try jsonObject(data)
			guard let metadataObject = object["metadata"] as? [String: Any] else {
				throw KeychainStoreError.integrityValidationFailed
			}
			try validateSyncMetadataObject(metadataObject)
			struct Record: Decodable {
				let schemaVersion: Int
				let vaultId: String
				let metadata: SyncMetadata
			}
			let record = try JSONDecoder().decode(Record.self, from: data)
			guard record.schemaVersion == VaultKeychainRecordContract.syncMetadataSchemaVersion,
				record.vaultId == vaultID,
				record.metadata.isValidCurrentWireState
			else {
				throw KeychainStoreError.integrityValidationFailed
			}
		}
	}

	private func validateSyncMetadataObject(_ object: [String: Any]) throws {
		let allowed: Set<String> = [
			"lastSyncedAt", "lastAction", "lastVersion", "isDirty", "binding", "checkpoints",
		]
		guard Set(object.keys).isSubset(of: allowed),
			object["isDirty"] is Bool,
			let checkpoints = object["checkpoints"] as? [[String: Any]]
		else { throw KeychainStoreError.integrityValidationFailed }
		if let binding = object["binding"] as? [String: Any] {
			try validateSyncBindingObject(binding)
		} else if object.keys.contains("binding") {
			throw KeychainStoreError.integrityValidationFailed
		}
		for checkpoint in checkpoints {
			let keys = Set(checkpoint.keys)
			guard keys == ["binding", "lastSyncedAt", "lastAction", "lastVersion"],
				let binding = checkpoint["binding"] as? [String: Any]
			else { throw KeychainStoreError.integrityValidationFailed }
			try validateSyncBindingObject(binding)
		}
	}

	private func validateSyncBindingObject(_ object: [String: Any]) throws {
		guard Set(object.keys) == ["registryURL", "principalID", "scope"] else {
			throw KeychainStoreError.integrityValidationFailed
		}
	}

	private func decodeVaultID(_ encoded: String) -> String? {
		var base64 = encoded.replacingOccurrences(of: "-", with: "+")
			.replacingOccurrences(of: "_", with: "/")
		let padding = (4 - base64.count % 4) % 4
		base64 += String(repeating: "=", count: padding)
		guard let data = Data(base64Encoded: base64),
			let value = String(data: data, encoding: .utf8),
			EnvValidation.isSafeVaultId(value)
		else { return nil }
		return value
	}

	private func isValidStorageID(_ value: String) -> Bool {
		guard value.utf8.count == 36 else { return false }
		return value.utf8.enumerated().allSatisfy { index, byte in
			if [8, 13, 18, 23].contains(index) { return byte == 45 }
			return (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
		}
	}

	private func projectMetadataAccount(storageID: String, vaultID: String) -> String {
		"\(VaultKeychainRecordContract.projectMetadataPrefix)\(storageID):\(encodeVaultID(vaultID))"
	}

	private func projectDiscoveryAccount(storageID: String, shard: Int) -> String {
		"\(VaultKeychainRecordContract.projectDiscoveryPrefix)\(storageID):\(String(format: "%03x", shard))"
	}

	private func encodeVaultID(_ vaultID: String) -> String {
		Data(vaultID.utf8).base64EncodedString()
			.replacingOccurrences(of: "+", with: "-")
			.replacingOccurrences(of: "/", with: "_")
			.replacingOccurrences(of: "=", with: "")
	}

	private func isValidEnvironmentSummaries(
		_ summaries: [VaultProjectEnvironmentSummary]
	) -> Bool {
		!summaries.isEmpty
			&& summaries.map(\.name) == summaries.map(\.name).sorted()
			&& Set(summaries.map(\.name)).count == summaries.count
			&& summaries.allSatisfy {
				EnvValidation.isValidEnvironmentName($0.name) && $0.keyCount >= 0
			}
	}

	func read(account: String) throws -> Data? {
		try VaultKeychainTransactionLock.withLock {
			try ensureRecoveredUnlocked()
			return try backend.read(service: service, account: account)
		}
	}

	func read(accounts: [String]) throws -> [String: Data?] {
		try VaultKeychainTransactionLock.withLock {
			try ensureRecoveredUnlocked()
			var values: [String: Data?] = [:]
			values.reserveCapacity(accounts.count)
			for account in accounts {
				values.updateValue(
					try backend.read(service: service, account: account),
					forKey: account
				)
			}
			return values
		}
	}

	func map<T>(
		accounts: [String],
		_ transform: (String, Data?) throws -> T
	) throws -> [T] {
		try VaultKeychainTransactionLock.withLock {
			try ensureRecoveredUnlocked()
			var results: [T] = []
			results.reserveCapacity(accounts.count)
			for account in accounts {
				let data = try backend.read(service: service, account: account)
				results.append(try transform(account, data))
			}
			return results
		}
	}

	func write(account: String, data: Data) throws {
		try VaultKeychainTransactionLock.withLock {
			try ensureRecoveredUnlocked()
			try writeWithRetry(account: account, data: data)
			guard try backend.read(service: service, account: account) == data else {
				throw KeychainStoreError.concurrentModification
			}
		}
	}

	func add(account: String, data: Data) throws {
		try VaultKeychainTransactionLock.withLock {
			try ensureRecoveredUnlocked()
			let existing = try backend.read(service: service, account: account)
			if let existing {
				if existing == data { return }
				throw KeychainStoreError.status(operation: "add", code: errSecDuplicateItem)
			}
			try addWithRetry(account: account, data: data)
			guard try backend.read(service: service, account: account) == data else {
				throw KeychainStoreError.concurrentModification
			}
		}
	}

	private func writeWithRetry(account: String, data: Data) throws {
		do {
			try backend.write(service: service, account: account, data: data)
		} catch {
			if try backend.read(service: service, account: account) == data {
				return
			}
			try backend.write(service: service, account: account, data: data)
		}
	}

	private func addWithRetry(account: String, data: Data) throws {
		do {
			try backend.add(service: service, account: account, data: data)
		} catch {
			if try backend.read(service: service, account: account) == data {
				return
			}
			try backend.add(service: service, account: account, data: data)
		}
	}

	@discardableResult
	func delete(account: String) throws -> Bool {
		try VaultKeychainTransactionLock.withLock {
			try ensureRecoveredUnlocked()
			return try backend.delete(service: service, account: account)
		}
	}

}

struct VaultProjectEnvironmentSummary: Codable, Equatable, Sendable {
	let name: String
	let keyCount: Int
}

struct VaultProjectMetadata: Equatable, Sendable {
	let id: String
	let name: String
	let path: String
	let environmentSummaries: [VaultProjectEnvironmentSummary]
}

private struct VaultProjectIndexMarker: Codable, Equatable {
	let schemaVersion: Int
	let storageId: String
	var activeShards: [Int]
	var writableShard: Int?

	private enum CodingKeys: String, CodingKey {
		case schemaVersion
		case storageId
		case activeShards
		case writableShard
	}

	init(schemaVersion: Int, storageId: String, activeShards: [Int], writableShard: Int?) {
		self.schemaVersion = schemaVersion
		self.storageId = storageId
		self.activeShards = activeShards
		self.writableShard = writableShard
	}

	init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
		storageId = try container.decode(String.self, forKey: .storageId)
		activeShards = try container.decode([Int].self, forKey: .activeShards)
		writableShard = try container.decodeIfPresent(Int.self, forKey: .writableShard)
	}

	func encode(to encoder: Encoder) throws {
		var container = encoder.container(keyedBy: CodingKeys.self)
		try container.encode(schemaVersion, forKey: .schemaVersion)
		try container.encode(storageId, forKey: .storageId)
		try container.encode(activeShards, forKey: .activeShards)
		try container.encode(writableShard, forKey: .writableShard)
	}
}

private struct VaultProjectMetadataRecord: Codable, Equatable {
	let schemaVersion: Int
	let storageId: String
	let id: String
	var name: String
	var path: String
	let discoveryShard: Int
	var environmentSummaries: [VaultProjectEnvironmentSummary]

	var metadata: VaultProjectMetadata {
		VaultProjectMetadata(
			id: id,
			name: name,
			path: path,
			environmentSummaries: environmentSummaries
		)
	}
}

private struct VaultProjectDiscoveryShard: Codable, Equatable {
	let schemaVersion: Int
	let storageId: String
	let shard: Int
	var ids: [String]
}

private struct VaultProjectIndexState {
	var marker: VaultProjectIndexMarker
	var markerData: Data
}

private struct VaultProjectMetadataSnapshot {
	let record: VaultProjectMetadataRecord
	let data: Data
}

private struct VaultProjectDiscoverySnapshot {
	let envelope: VaultProjectDiscoveryShard
	let data: Data
}

// MARK: - Environments Wrapper

private struct EnvironmentsWrapper: Codable {
	let environments: [String: [String: String]]
}

fileprivate struct PreparedProjectPayload {
	let data: Data
	let environmentSummaries: [VaultProjectEnvironmentSummary]
}

// MARK: - Implementation

/// Keychain-backed vault storage.
///
/// The versioned index uses one marker, one metadata item per vault, and bounded discovery shards.
/// Each vault payload remains in the `{vault-id}` account.
///
/// This design avoids `kSecMatchLimitAll` which is unreliable in some macOS contexts.
final class KeychainService: KeychainServiceProtocol, @unchecked Sendable {
	private static let projectIndexMarkerAccount = VaultKeychainRecordContract.projectIndexMarkerAccount
	private static let projectMetadataPrefix = VaultKeychainRecordContract.projectMetadataPrefix
	private static let projectDiscoveryPrefix = VaultKeychainRecordContract.projectDiscoveryPrefix
	private static let projectIndexSchemaVersion = VaultKeychainRecordContract.projectIndexSchemaVersion
	private static let projectDiscoveryShardCount = 1_024
	private static let maximumProjectDiscoveryShardSize = 128

	private let store: SharedKeychainStore

	init() {
		self.store = SharedKeychainStore(service: VaultConstants.keychainService)
	}

	init(
		testingService: String,
		backend: any KeychainStoreBackend = SecurityKeychainStoreBackend(),
		performanceCounters: VaultKeychainPerformanceCounters? = nil
	) {
		self.store = SharedKeychainStore(
			service: testingService,
			backend: backend,
			performanceCounters: performanceCounters
		)
	}

	// MARK: - Public API

	func withKeychainTransaction<T>(_ operation: () -> T) -> Result<T, KeychainError> {
		do {
			return .success(try VaultKeychainTransactionLock.withLock {
				try store.recoverVaultTransaction()
				return operation()
			})
		} catch let error as KeychainStoreError {
			return .failure(keychainError(from: error))
		} catch {
			return .failure(.unexpectedStatus(errSecInternalComponent))
		}
	}

	func listProjects() -> [VaultProject] {
		switch listProjectsResult() {
		case .success(let projects): return projects
		case .failure(let error):
			keychainLogger.error("Keychain project listing failed: \(error.description, privacy: .public)")
			return []
		}
	}

	func listProjectsResult() -> Result<[VaultProject], KeychainError> {
		do {
			return try VaultKeychainTransactionLock.withLock {
				let metadata = try readProjectMetadataThrowing()
				let entries = Dictionary(uniqueKeysWithValues: metadata.map { ($0.id, $0) })
				let projects = try store.map(accounts: metadata.map(\.id)) { account, data in
					guard let entry = entries[account], let data else {
						throw KeychainStoreError.status(
							operation: "read indexed vault data", code: errSecItemNotFound)
					}
					return VaultProject(
						id: entry.id,
						name: entry.name,
						path: entry.path,
						environments: try decodeEnvironments(data)
					)
				}
				return .success(projects)
			}
		} catch let error as KeychainStoreError {
			return .failure(keychainError(from: error))
		} catch {
			return .failure(.unexpectedStatus(errSecInternalComponent))
		}
	}

	func listProjectMetadataResult() -> Result<[VaultProjectMetadata], KeychainError> {
		do {
			return .success(try VaultKeychainTransactionLock.withLock {
				try readProjectMetadataThrowing()
			})
		} catch let error as KeychainStoreError {
			return .failure(keychainError(from: error))
		} catch {
			return .failure(.unexpectedStatus(errSecInternalComponent))
		}
	}

	func getProjectResult(vaultId: String) -> Result<VaultProject?, KeychainError> {
		do {
			return try VaultKeychainTransactionLock.withLock {
				guard EnvValidation.isSafeVaultId(vaultId) else {
					return .failure(.accessDenied)
				}
				let state = try ensureProjectIndexThrowing()
				guard let entry = try readProjectMetadataRecordThrowing(
					vaultId: vaultId,
					state: state
				)?.record else {
					return .success(nil)
				}
				guard let data = try store.read(account: vaultId) else {
					return .failure(.itemNotFound)
				}
				return .success(VaultProject(
					id: entry.id,
					name: entry.name,
					path: entry.path,
					environments: try decodeEnvironments(data)
				))
			}
		} catch let error as KeychainStoreError {
			return .failure(keychainError(from: error))
		} catch {
			return .failure(.unexpectedStatus(errSecInternalComponent))
		}
	}

	func getEnvironments(vaultId: String) -> [String: [String: String]]? {
		try? getEnvironmentsResult(vaultId: vaultId).get()
	}

	func getEnvironmentsResult(
		vaultId: String
	) -> Result<[String: [String: String]]?, KeychainError> {
		do {
			guard let data = try readItemThrowing(account: vaultId) else { return .success(nil) }
			return .success(try decodeEnvironments(data))
		} catch let error as KeychainStoreError {
			return .failure(keychainError(from: error))
		} catch {
			return .failure(.unexpectedStatus(errSecInternalComponent))
		}
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
		let environments = normalizedEnvironments(environments)
		guard EnvValidation.areValidEnvironments(environments) else {
			return .failure(.encodingFailed)
		}
		guard let payload = try? prepareProjectPayload(environments: environments) else {
			return .failure(.encodingFailed)
		}
		return saveData(
			vaultId: vaultId,
			projectName: projectName,
			projectPath: projectPath,
			payload: payload
		)
	}

	/// Updates only the protected vault payload. Callers must already have
	/// verified that the indexed name and path are unchanged.
	func updateEnvironments(
		vaultId: String,
		environments: [String: [String: String]]
	) -> KeychainResult {
		guard EnvValidation.isSafeVaultId(vaultId) else { return .failure(.accessDenied) }
		let environments = normalizedEnvironments(environments)
		guard EnvValidation.areValidEnvironments(environments),
			let payload = try? prepareProjectPayload(environments: environments)
		else { return .failure(.encodingFailed) }
		guard payload.data.count <= VaultConstants.maxVaultSizeWarning else {
			return .failure(.dataTooLarge(payload.data.count))
		}
		do {
			try VaultKeychainTransactionLock.withLock {
				try updateProjectPayloadThrowing(vaultId: vaultId, payload: payload)
			}
			if payload.data.count > VaultConstants.maxVaultSizeWarning * 9 / 10 {
				return .successWithWarning(
					"Env project is approaching size limit (\(payload.data.count) bytes)")
			}
			return .success
		} catch let error as KeychainStoreError {
			return .failure(keychainError(from: error))
		} catch {
			return .failure(.unexpectedStatus(errSecInternalComponent))
		}
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
		let environments = normalizedEnvironments(environments)
		guard EnvValidation.areValidEnvironments(environments) else {
			return .failure(.encodingFailed)
		}
		guard let payload = try? prepareProjectPayload(environments: environments) else {
			return .failure(.encodingFailed)
		}
		guard payload.data.count <= VaultConstants.maxVaultSizeWarning else {
			return .failure(.dataTooLarge(payload.data.count))
		}

		do {
			return try VaultKeychainTransactionLock.withLock {
				try createProjectRecordsThrowing(
					vaultId: vaultId,
					projectName: projectName,
					projectPath: projectPath,
					payload: payload,
					requirePayloadAbsent: true
				)
				if payload.data.count > VaultConstants.maxVaultSizeWarning * 9 / 10 {
					return .successWithWarning(
						"Env project is approaching size limit (\(payload.data.count) bytes)")
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

	func applyVaultTransaction(
		project: VaultProjectKeychainMutation?,
		data mutations: [VaultKeychainMutation]
	) -> KeychainResult {
		do {
			return try VaultKeychainTransactionLock.withLock {
				let warning: String?
				switch project {
				case .create(let project):
					let payload = try prepareProjectPayload(project)
					try createProjectRecordsThrowing(
						vaultId: project.id,
						projectName: project.name,
						projectPath: project.path,
						payload: payload,
						requirePayloadAbsent: true,
						additionalMutations: mutations
					)
					warning = projectSizeWarning(payload.data.count)
				case .upsert(let project):
					let payload = try prepareProjectPayload(project)
					try upsertProjectRecordsThrowing(
						vaultId: project.id,
						projectName: project.name,
						projectPath: project.path,
						payload: payload,
						additionalMutations: mutations
					)
					warning = projectSizeWarning(payload.data.count)
				case .update(let vaultId, let environments):
					guard EnvValidation.isSafeVaultId(vaultId) else {
						return .failure(.accessDenied)
					}
					let normalized = normalizedEnvironments(environments)
					guard EnvValidation.areValidEnvironments(normalized) else {
						return .failure(.encodingFailed)
					}
					let payload = try prepareProjectPayload(environments: normalized)
					guard payload.data.count <= VaultConstants.maxVaultSizeWarning else {
						return .failure(.dataTooLarge(payload.data.count))
					}
					try updateProjectPayloadThrowing(
						vaultId: vaultId,
						payload: payload,
						additionalMutations: mutations
					)
					warning = projectSizeWarning(payload.data.count)
				case .delete(let vaultId, let deletePayload):
					guard EnvValidation.isSafeVaultId(vaultId) else {
						return .failure(.accessDenied)
					}
					try removeProjectRecordsThrowing(
						vaultId: vaultId,
						deletePayload: deletePayload,
						additionalMutations: mutations
					)
					warning = nil
				case nil:
					try store.applyVaultTransaction(mutations)
					warning = nil
				}
				return warning.map(KeychainResult.successWithWarning) ?? .success
			}
		} catch let error as KeychainStoreError where error.statusCode == errSecDuplicateItem {
			return .failure(.duplicateItem)
		} catch let error as KeychainStoreError {
			return .failure(keychainError(from: error))
		} catch {
			return .failure(.encodingFailed)
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
	// MARK: - Data Save (shared)
	private func prepareProjectPayload(_ project: VaultProject) throws -> PreparedProjectPayload {
		guard EnvValidation.isSafeVaultId(project.id) else {
			throw KeychainStoreError.status(operation: "validate vault ID", code: errSecParam)
		}
		let environments = normalizedEnvironments(project.environments)
		guard EnvValidation.areValidEnvironments(environments) else {
			throw KeychainStoreError.status(operation: "validate environments", code: errSecDecode)
		}
		let payload = try prepareProjectPayload(environments: environments)
		guard payload.data.count <= VaultConstants.maxVaultSizeWarning else {
			throw KeychainStoreError.dataTooLarge(payload.data.count)
		}
		return payload
	}

	private func prepareProjectPayload(
		environments: [String: [String: String]]
	) throws -> PreparedProjectPayload {
		PreparedProjectPayload(
			data: try JSONEncoder().encode(EnvironmentsWrapper(environments: environments)),
			environmentSummaries: environmentSummaries(environments)
		)
	}

	private func projectSizeWarning(_ size: Int) -> String? {
		size > VaultConstants.maxVaultSizeWarning * 9 / 10
			? "Env project is approaching size limit (\(size) bytes)"
			: nil
	}

	private func saveData(
		vaultId: String,
		projectName: String,
		projectPath: String,
		payload: PreparedProjectPayload
	) -> KeychainResult {

		if payload.data.count > VaultConstants.maxVaultSizeWarning {
			return .failure(.dataTooLarge(payload.data.count))
		}

		let warning =
			payload.data.count > VaultConstants.maxVaultSizeWarning * 9 / 10
			? "Env project is approaching size limit (\(payload.data.count) bytes)"
			: nil

		do {
			return try VaultKeychainTransactionLock.withLock {
				try upsertProjectRecordsThrowing(
					vaultId: vaultId,
					projectName: projectName,
					projectPath: projectPath,
					payload: payload
				)

				return warning.map(KeychainResult.successWithWarning) ?? .success
			}
		} catch let error as KeychainStoreError {
			return .failure(keychainError(from: error))
		} catch {
			return .failure(.unexpectedStatus(errSecInternalComponent))
		}
	}

	/// Remove from sidebar only — keeps Keychain data intact.
	/// The project can be re-added by opening the same folder.
	func removeFromSidebar(vaultId: String) -> Bool {
		guard EnvValidation.isSafeVaultId(vaultId) else { return false }
		do {
			return try VaultKeychainTransactionLock.withLock {
				try removeProjectRecordsThrowing(vaultId: vaultId, deletePayload: false)
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
		if error == .projectDiscoveryCapacity { return .projectDiscoveryCapacity }
		if error == .transactionOutcomeIndeterminate {
			return .transactionOutcomeIndeterminate
		}
		if case .dataTooLarge(let byteCount) = error { return .dataTooLarge(byteCount) }
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

	// MARK: - Private: Project Discovery

	private func readProjectMetadataThrowing() throws -> [VaultProjectMetadata] {
		let state = try ensureProjectIndexThrowing()
		let shardAccounts = state.marker.activeShards.map {
			projectDiscoveryAccount(storageID: state.marker.storageId, shard: $0)
		}
		let shards = try store.map(accounts: shardAccounts) { account, data in
			guard let data else {
				throw KeychainStoreError.status(
					operation: "read project discovery shard", code: errSecItemNotFound)
			}
			return try decodeProjectDiscoveryShard(
				data,
				account: account,
				state: state
			)
		}
		var shardsByIdentifier: [String: Int] = [:]
		shardsByIdentifier.reserveCapacity(shards.reduce(0) { $0 + $1.envelope.ids.count })
		for shard in shards {
			for vaultID in shard.envelope.ids {
				guard shardsByIdentifier.updateValue(shard.envelope.shard, forKey: vaultID) == nil
				else {
					throw KeychainStoreError.status(
						operation: "validate project discovery", code: errSecDecode)
				}
			}
		}

		let identifiers = shardsByIdentifier.keys.sorted()
		let accounts = identifiers.map {
			projectMetadataAccount(storageID: state.marker.storageId, vaultId: $0)
		}
		return try store.map(accounts: accounts) { account, data in
			guard let data else {
				throw KeychainStoreError.status(
					operation: "read project metadata", code: errSecItemNotFound)
			}
			let record = try decodeProjectMetadataRecord(
				data,
				account: account,
				state: state
			)
			guard shardsByIdentifier[record.id] == record.discoveryShard else {
				throw KeychainStoreError.status(
					operation: "validate project metadata discovery", code: errSecDecode)
			}
			return record.metadata
		}
	}

	private func ensureProjectIndexThrowing() throws -> VaultProjectIndexState {
		if let data = try readItemThrowing(account: Self.projectIndexMarkerAccount) {
			return try decodeProjectIndexMarker(data)
		}
		let marker = VaultProjectIndexMarker(
			schemaVersion: Self.projectIndexSchemaVersion,
			storageId: UUID().uuidString.lowercased(),
			activeShards: [],
			writableShard: nil
		)
		let markerData = try JSONEncoder().encode(marker)
		do {
			try store.add(account: Self.projectIndexMarkerAccount, data: markerData)
			return VaultProjectIndexState(marker: marker, markerData: markerData)
		} catch let error as KeychainStoreError where error.statusCode == errSecDuplicateItem {
			guard let winner = try readItemThrowing(account: Self.projectIndexMarkerAccount) else {
				throw KeychainStoreError.concurrentModification
			}
			return try decodeProjectIndexMarker(winner)
		}
	}

	private func decodeProjectIndexMarker(_ data: Data) throws -> VaultProjectIndexState {
		let marker = try JSONDecoder().decode(VaultProjectIndexMarker.self, from: data)
		guard marker.schemaVersion == Self.projectIndexSchemaVersion,
			isValidProjectStorageID(marker.storageId),
			marker.activeShards.count <= Self.projectDiscoveryShardCount,
			marker.activeShards == marker.activeShards.sorted(),
			Set(marker.activeShards).count == marker.activeShards.count,
			marker.activeShards.allSatisfy({ 0..<Self.projectDiscoveryShardCount ~= $0 }),
			marker.writableShard.map(marker.activeShards.contains) ?? true
		else {
			throw KeychainStoreError.status(
				operation: "decode project-index marker", code: errSecDecode)
		}
		return VaultProjectIndexState(marker: marker, markerData: data)
	}

	private func readProjectMetadataRecordThrowing(
		vaultId: String,
		state: VaultProjectIndexState
	) throws -> VaultProjectMetadataSnapshot? {
		let account = projectMetadataAccount(
			storageID: state.marker.storageId,
			vaultId: vaultId
		)
		guard let data = try readItemThrowing(account: account) else { return nil }
		return VaultProjectMetadataSnapshot(
			record: try decodeProjectMetadataRecord(data, account: account, state: state),
			data: data
		)
	}

	private func decodeProjectMetadataRecord(
		_ data: Data,
		account: String,
		state: VaultProjectIndexState
	) throws -> VaultProjectMetadataRecord {
		let record = try JSONDecoder().decode(VaultProjectMetadataRecord.self, from: data)
		guard record.schemaVersion == Self.projectIndexSchemaVersion,
			record.storageId == state.marker.storageId,
			EnvValidation.isSafeVaultId(record.id),
			0..<Self.projectDiscoveryShardCount ~= record.discoveryShard,
			isValidEnvironmentSummaries(record.environmentSummaries),
			account == projectMetadataAccount(
				storageID: state.marker.storageId,
				vaultId: record.id
			)
		else {
			throw KeychainStoreError.status(
				operation: "decode project metadata", code: errSecDecode)
		}
		return record
	}

	private func readProjectDiscoveryShardThrowing(
		shard: Int,
		state: VaultProjectIndexState
	) throws -> VaultProjectDiscoverySnapshot? {
		guard state.marker.activeShards.contains(shard) else { return nil }
		let account = projectDiscoveryAccount(
			storageID: state.marker.storageId,
			shard: shard
		)
		guard let data = try readItemThrowing(account: account) else {
			throw KeychainStoreError.status(
				operation: "read project discovery shard", code: errSecItemNotFound)
		}
		return try decodeProjectDiscoveryShard(data, account: account, state: state)
	}

	private func decodeProjectDiscoveryShard(
		_ data: Data,
		account: String,
		state: VaultProjectIndexState
	) throws -> VaultProjectDiscoverySnapshot {
		let envelope = try JSONDecoder().decode(VaultProjectDiscoveryShard.self, from: data)
		guard envelope.schemaVersion == Self.projectIndexSchemaVersion,
			envelope.storageId == state.marker.storageId,
			0..<Self.projectDiscoveryShardCount ~= envelope.shard,
			envelope.ids.count <= Self.maximumProjectDiscoveryShardSize,
			envelope.ids == envelope.ids.sorted(),
			Set(envelope.ids).count == envelope.ids.count,
			envelope.ids.allSatisfy(EnvValidation.isSafeVaultId),
			account == projectDiscoveryAccount(
				storageID: state.marker.storageId,
				shard: envelope.shard
			)
		else {
			throw KeychainStoreError.status(
				operation: "decode project discovery shard", code: errSecDecode)
		}
		return VaultProjectDiscoverySnapshot(envelope: envelope, data: data)
	}

	private func upsertProjectRecordsThrowing(
		vaultId: String,
		projectName: String,
		projectPath: String,
		payload: PreparedProjectPayload,
		additionalMutations: [VaultKeychainMutation] = []
	) throws {
		let state = try ensureProjectIndexThrowing()
		guard let metadata = try readProjectMetadataRecordThrowing(
			vaultId: vaultId,
			state: state
		) else {
			try createProjectRecordsThrowing(
				vaultId: vaultId,
				projectName: projectName,
				projectPath: projectPath,
				payload: payload,
				requirePayloadAbsent: false,
				state: state,
				additionalMutations: additionalMutations
			)
			return
		}

		guard try readItemThrowing(account: vaultId) != nil else {
			throw KeychainStoreError.status(
				operation: "read indexed vault data", code: errSecItemNotFound)
		}
		var updated = metadata.record
		updated.name = projectName
		updated.path = projectPath
		updated.environmentSummaries = payload.environmentSummaries
		if updated == metadata.record {
			try store.applyVaultTransaction(
				[.write(account: vaultId, preparedProjectPayload: payload)] + additionalMutations)
			return
		}

		let metadataAccount = projectMetadataAccount(
			storageID: state.marker.storageId,
			vaultId: vaultId
		)
		try store.applyVaultTransaction([
			.write(account: vaultId, preparedProjectPayload: payload),
			.write(account: metadataAccount, data: JSONEncoder().encode(updated)),
		] + additionalMutations)
	}

	private func updateProjectPayloadThrowing(
		vaultId: String,
		payload: PreparedProjectPayload,
		additionalMutations: [VaultKeychainMutation] = []
	) throws {
		let state = try ensureProjectIndexThrowing()
		guard let metadata = try readProjectMetadataRecordThrowing(
			vaultId: vaultId,
			state: state
		) else {
			throw KeychainStoreError.status(
				operation: "read project metadata", code: errSecItemNotFound)
		}
		guard try readItemThrowing(account: vaultId) != nil else {
			throw KeychainStoreError.status(
				operation: "read indexed vault data", code: errSecItemNotFound)
		}
		var updated = metadata.record
		updated.environmentSummaries = payload.environmentSummaries
		if updated == metadata.record {
			try store.applyVaultTransaction(
				[.write(account: vaultId, preparedProjectPayload: payload)] + additionalMutations)
			return
		}

		let metadataAccount = projectMetadataAccount(
			storageID: state.marker.storageId,
			vaultId: vaultId
		)
		try store.applyVaultTransaction([
			.write(account: vaultId, preparedProjectPayload: payload),
			.write(account: metadataAccount, data: JSONEncoder().encode(updated)),
		] + additionalMutations)
	}

	private func createProjectRecordsThrowing(
		vaultId: String,
		projectName: String,
		projectPath: String,
		payload: PreparedProjectPayload,
		requirePayloadAbsent: Bool,
		state providedState: VaultProjectIndexState? = nil,
		additionalMutations: [VaultKeychainMutation] = []
	) throws {
		var state = try providedState ?? ensureProjectIndexThrowing()
		let metadataAccount = projectMetadataAccount(
			storageID: state.marker.storageId,
			vaultId: vaultId
		)
		guard try readItemThrowing(account: metadataAccount) == nil else {
			throw KeychainStoreError.status(operation: "add project metadata", code: errSecDuplicateItem)
		}
		let previousPayload = try readItemThrowing(account: vaultId)
		if requirePayloadAbsent, previousPayload != nil {
			throw KeychainStoreError.status(operation: "add project payload", code: errSecDuplicateItem)
		}

		let selected = try selectProjectDiscoveryShard(vaultId: vaultId, state: state)
		var shard = selected.snapshot?.envelope ?? VaultProjectDiscoveryShard(
			schemaVersion: Self.projectIndexSchemaVersion,
			storageId: state.marker.storageId,
			shard: selected.shard,
			ids: []
		)
		guard !shard.ids.contains(vaultId) else {
			throw KeychainStoreError.status(
				operation: "validate project discovery", code: errSecDecode)
		}
		shard.ids.append(vaultId)
		shard.ids.sort()
		let shardAccount = projectDiscoveryAccount(
			storageID: state.marker.storageId,
			shard: selected.shard
		)
		let metadata = VaultProjectMetadataRecord(
			schemaVersion: Self.projectIndexSchemaVersion,
			storageId: state.marker.storageId,
			id: vaultId,
			name: projectName,
			path: projectPath,
			discoveryShard: selected.shard,
			environmentSummaries: payload.environmentSummaries
		)
		let activatesShard = selected.snapshot == nil
		if activatesShard {
			state.marker.activeShards.append(selected.shard)
			state.marker.activeShards.sort()
		}
		let previousWritableShard = state.marker.writableShard
		state.marker.writableShard =
			shard.ids.count < Self.maximumProjectDiscoveryShardSize ? selected.shard : nil

		var mutations: [VaultKeychainMutation] = [
			.write(account: vaultId, preparedProjectPayload: payload),
			.write(account: metadataAccount, data: try JSONEncoder().encode(metadata)),
			.write(account: shardAccount, data: try JSONEncoder().encode(shard)),
		]
		if activatesShard || state.marker.writableShard != previousWritableShard {
			mutations.append(.write(
				account: Self.projectIndexMarkerAccount,
				data: try JSONEncoder().encode(state.marker)
			))
		}
		try store.applyVaultTransaction(mutations + additionalMutations)
	}

	private func selectProjectDiscoveryShard(
		vaultId: String,
		state: VaultProjectIndexState
	) throws -> (shard: Int, snapshot: VaultProjectDiscoverySnapshot?) {
		if let writableShard = state.marker.writableShard {
			guard state.marker.activeShards.contains(writableShard),
				let snapshot = try readProjectDiscoveryShardThrowing(
					shard: writableShard,
					state: state
				), snapshot.envelope.ids.count < Self.maximumProjectDiscoveryShardSize
			else {
				throw KeychainStoreError.status(
					operation: "validate writable project discovery shard", code: errSecDecode)
			}
			return (writableShard, snapshot)
		}
		let activeShards = Set(state.marker.activeShards)
		let probe = projectDiscoveryProbe(for: vaultId)
		for attempt in 0..<Self.projectDiscoveryShardCount {
			let shard = projectDiscoveryShard(probe: probe, attempt: attempt)
			if !activeShards.contains(shard) {
				let account = projectDiscoveryAccount(
					storageID: state.marker.storageId,
					shard: shard
				)
				guard try readItemThrowing(account: account) == nil else {
					throw KeychainStoreError.status(
						operation: "validate inactive project discovery shard", code: errSecDecode)
				}
				return (shard, nil)
			}
		}
		throw KeychainStoreError.projectDiscoveryCapacity
	}

	private func removeProjectRecordsThrowing(
		vaultId: String,
		deletePayload: Bool,
		additionalMutations: [VaultKeychainMutation] = []
	) throws {
		var state = try ensureProjectIndexThrowing()
		guard let metadata = try readProjectMetadataRecordThrowing(
			vaultId: vaultId,
			state: state
		) else {
			var mutations = additionalMutations
			if deletePayload { mutations.insert(.delete(account: vaultId), at: 0) }
			if !mutations.isEmpty { try store.applyVaultTransaction(mutations) }
			return
		}
		guard let shardSnapshot = try readProjectDiscoveryShardThrowing(
			shard: metadata.record.discoveryShard,
			state: state
		), shardSnapshot.envelope.ids.filter({ $0 == vaultId }).count == 1
		else {
			throw KeychainStoreError.status(
				operation: "validate project discovery", code: errSecDecode)
		}

		let metadataAccount = projectMetadataAccount(
			storageID: state.marker.storageId,
			vaultId: vaultId
		)
		let shardAccount = projectDiscoveryAccount(
			storageID: state.marker.storageId,
			shard: metadata.record.discoveryShard
		)
		var updatedShard = shardSnapshot.envelope
		updatedShard.ids.removeAll { $0 == vaultId }
		let deactivatesShard = updatedShard.ids.isEmpty
		let previousWritableShard = state.marker.writableShard
		if deactivatesShard {
			state.marker.activeShards.removeAll { $0 == metadata.record.discoveryShard }
			if state.marker.writableShard == metadata.record.discoveryShard {
				state.marker.writableShard = nil
			}
		} else if shardSnapshot.envelope.ids.count == Self.maximumProjectDiscoveryShardSize,
			state.marker.writableShard == nil
		{
			state.marker.writableShard = metadata.record.discoveryShard
		}
		let markerChanged = deactivatesShard || state.marker.writableShard != previousWritableShard

		var mutations: [VaultKeychainMutation] = []
		if deletePayload { mutations.append(.delete(account: vaultId)) }
		mutations.append(.delete(account: metadataAccount))
		if deactivatesShard {
			mutations.append(.delete(account: shardAccount))
			mutations.append(.write(
				account: Self.projectIndexMarkerAccount,
				data: try JSONEncoder().encode(state.marker)
			))
		} else {
			mutations.append(.write(
				account: shardAccount,
				data: try JSONEncoder().encode(updatedShard)
			))
			if markerChanged {
				mutations.append(.write(
					account: Self.projectIndexMarkerAccount,
					data: try JSONEncoder().encode(state.marker)
				))
			}
		}
		try store.applyVaultTransaction(mutations + additionalMutations)
	}

	private func projectDiscoveryProbe(for vaultId: String) -> (start: Int, step: Int) {
		let digest = SHA256.hash(data: Data(vaultId.utf8))
		let bytes = digest.withUnsafeBytes { Array($0) }
		let start = (Int(bytes[0]) << 8 | Int(bytes[1]))
			% Self.projectDiscoveryShardCount
		let rawStep = (Int(bytes[2]) << 8 | Int(bytes[3]))
			% Self.projectDiscoveryShardCount
		let step = rawStep | 1
		return (start, step)
	}

	private func projectDiscoveryShard(
		probe: (start: Int, step: Int),
		attempt: Int
	) -> Int {
		(probe.start + attempt * probe.step) % Self.projectDiscoveryShardCount
	}

	private func projectMetadataAccount(storageID: String, vaultId: String) -> String {
		let encoded = Data(vaultId.utf8).base64EncodedString()
			.replacingOccurrences(of: "+", with: "-")
			.replacingOccurrences(of: "/", with: "_")
			.replacingOccurrences(of: "=", with: "")
		return "\(Self.projectMetadataPrefix)\(storageID):\(encoded)"
	}

	private func projectDiscoveryAccount(storageID: String, shard: Int) -> String {
		String(format: "\(Self.projectDiscoveryPrefix)\(storageID):%03x", shard)
	}

	private func isValidProjectStorageID(_ storageID: String) -> Bool {
		storageID.utf8.count == 36 && UUID(uuidString: storageID) != nil
	}

	private func environmentSummaries(
		_ environments: [String: [String: String]]
	) -> [VaultProjectEnvironmentSummary] {
		environments.map { name, secrets in
			VaultProjectEnvironmentSummary(name: name, keyCount: secrets.count)
		}.sorted { $0.name < $1.name }
	}

	private func isValidEnvironmentSummaries(
		_ summaries: [VaultProjectEnvironmentSummary]
	) -> Bool {
		!summaries.isEmpty
			&& summaries.map(\.name) == summaries.map(\.name).sorted()
			&& Set(summaries.map(\.name)).count == summaries.count
			&& summaries.allSatisfy {
				EnvValidation.isValidEnvironmentName($0.name) && $0.keyCount >= 0
			}
	}

	private func getEnvironmentsThrowing(vaultId: String) throws -> [String: [String: String]]? {
		guard let data = try readItemThrowing(account: vaultId) else { return nil }
		return try decodeEnvironments(data)
	}

	private func decodeEnvironments(_ data: Data) throws -> [String: [String: String]] {
		do {
			try StrictJSONKeyValidator.validate(data)
			guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
				Set(object.keys) == ["environments"]
			else {
				throw KeychainStoreError.status(
					operation: "decode vault data", code: errSecDecode)
			}
			let payload = try JSONDecoder().decode(EnvironmentsWrapper.self, from: data)
			let environments = normalizedEnvironments(payload.environments)
			guard EnvValidation.areValidEnvironments(environments) else {
				throw KeychainStoreError.status(
					operation: "validate vault data", code: errSecDecode)
			}
			return environments
		} catch {
			throw KeychainStoreError.status(operation: "decode vault data", code: errSecDecode)
		}
	}

	private func normalizedEnvironments(
		_ environments: [String: [String: String]]
	) -> [String: [String: String]] {
		environments.isEmpty ? ["default": [:]] : environments
	}
}
