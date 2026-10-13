import Foundation
import Security

/// Data Protection Keychain items in the app's own access group, which the
/// LPM CLI can't read. Items stay on this Mac and never sync through iCloud.
struct AppKeychainBackend: KeychainStoreBackend {
	func read(service: String, account: String) throws -> Data? {
		var query = Self.query(service: service, account: account)
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

	func write(service: String, account: String, data: Data) throws {
		let query = Self.query(service: service, account: account)
		let attributes = [kSecValueData as String: data]
		let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
		if status == errSecSuccess { return }
		guard status == errSecItemNotFound else { throw KeychainStoreError.status(operation: "write", code: status) }
		do {
			try add(service: service, account: account, data: data)
		} catch KeychainStoreError.status(_, errSecDuplicateItem) {
			let retry = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
			guard retry == errSecSuccess else { throw KeychainStoreError.status(operation: "write", code: retry) }
		}
	}

	func add(service: String, account: String, data: Data) throws {
		var query = Self.query(service: service, account: account)
		query[kSecValueData as String] = data
		query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
		let status = SecItemAdd(query as CFDictionary, nil)
		guard status == errSecSuccess else { throw KeychainStoreError.status(operation: "add", code: status) }
	}

	@discardableResult
	func delete(service: String, account: String) throws -> Bool {
		let status = SecItemDelete(Self.query(service: service, account: account) as CFDictionary)
		if status == errSecItemNotFound { return false }
		guard status == errSecSuccess else { throw KeychainStoreError.status(operation: "delete", code: status) }
		return true
	}

	static func query(service: String, account: String) -> [String: Any] {
		[
			kSecClass as String: kSecClassGenericPassword,
			kSecAttrService as String: service,
			kSecAttrAccount as String: account,
			kSecAttrAccessGroup as String: VaultConstants.appKeychainAccessGroup,
			kSecAttrSynchronizable as String: false,
			kSecUseDataProtectionKeychain as String: true,
		]
	}
}
