import Foundation
import Security

/// The app's own Keychain stores, one service each.
enum AppKeychainStore: CaseIterable, Sendable {
	/// Publish destinations, publish history and the fingerprint key.
	case publishing
	/// Platform connections and their access tokens.
	case platformConnections
	/// Tokens of retired platform connections still being revoked, and notes of those that couldn't be.
	case platformCleanup

	var service: String {
		switch self {
		case .publishing: VaultConstants.publishingKeychainService
		case .platformConnections: VaultConstants.platformConnectionsKeychainService
		case .platformCleanup: VaultConstants.platformCleanupKeychainService
		}
	}
}

/// The items of one Keychain service.
protocol AppKeychainItemBackend: Sendable {
	func read(account: String) throws -> Data?
	func write(account: String, data: Data) throws
	/// Adds the item; false when one already exists, which is left as it is.
	func insert(account: String, data: Data) throws -> Bool
	func delete(account: String) throws
	/// Every account the service holds.
	func accounts() throws -> [String]
}

/// Data Protection Keychain items in the app's own access group, which the
/// LPM CLI can't read. Items stay on this Mac and never sync through iCloud.
struct AppKeychainBackend: AppKeychainItemBackend {
	let service: String

	func read(account: String) throws -> Data? {
		var query = query(account: account)
		query[kSecReturnData as String] = true
		query[kSecMatchLimit as String] = kSecMatchLimitOne
		var result: AnyObject?
		let status = SecItemCopyMatching(query as CFDictionary, &result)
		if status == errSecItemNotFound { return nil }
		guard status == errSecSuccess else { throw KeychainStoreError.status(operation: "read", code: status) }
		guard let data = result as? Data else {
			throw KeychainStoreError.status(operation: "read", code: errSecInternalComponent)
		}
		return data
	}

	func write(account: String, data: Data) throws {
		let query = query(account: account)
		let attributes = [kSecValueData as String: data]
		let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
		if status == errSecSuccess { return }
		guard status == errSecItemNotFound else { throw KeychainStoreError.status(operation: "write", code: status) }
		if try insert(account: account, data: data) { return }
		let retry = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
		guard retry == errSecSuccess else { throw KeychainStoreError.status(operation: "write", code: retry) }
	}

	func insert(account: String, data: Data) throws -> Bool {
		var query = query(account: account)
		query[kSecValueData as String] = data
		query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
		let status = SecItemAdd(query as CFDictionary, nil)
		if status == errSecDuplicateItem { return false }
		guard status == errSecSuccess else { throw KeychainStoreError.status(operation: "add", code: status) }
		return true
	}

	func delete(account: String) throws {
		let status = SecItemDelete(query(account: account) as CFDictionary)
		guard status == errSecSuccess || status == errSecItemNotFound else {
			throw KeychainStoreError.status(operation: "delete", code: status)
		}
	}

	func accounts() throws -> [String] {
		var query = Self.serviceQuery(service)
		query[kSecReturnAttributes as String] = true
		query[kSecMatchLimit as String] = kSecMatchLimitAll
		var result: AnyObject?
		let status = SecItemCopyMatching(query as CFDictionary, &result)
		if status == errSecItemNotFound { return [] }
		guard status == errSecSuccess, let items = result as? [[String: Any]] else {
			throw KeychainStoreError.status(operation: "list", code: status == errSecSuccess ? errSecInternalComponent : status)
		}
		return items.compactMap { $0[kSecAttrAccount as String] as? String }
	}

	func query(account: String) -> [String: Any] {
		var query = Self.serviceQuery(service)
		query[kSecAttrAccount as String] = account
		return query
	}

	static func serviceQuery(_ service: String) -> [String: Any] {
		[
			kSecClass as String: kSecClassGenericPassword,
			kSecAttrService as String: service,
			kSecAttrAccessGroup as String: VaultConstants.appKeychainAccessGroup,
			kSecAttrSynchronizable as String: false,
			kSecUseDataProtectionKeychain as String: true,
		]
	}
}
