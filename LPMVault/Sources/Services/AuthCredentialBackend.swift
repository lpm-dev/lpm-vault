import Foundation
import Security

protocol AuthCredentialBackend: Sendable {
	func read(account: String) throws -> String?
	func readLegacy(account: String) throws -> String?
	func deleteLegacy(account: String) throws
	func write(_ credential: String, account: String) throws
	func delete(account: String) throws
}

struct KeychainAuthCredentialBackend: AuthCredentialBackend {
	static let accessibility = kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String

	let service: String

	func read(account: String) throws -> String? {
		try read(account: account, legacy: false)
	}

	func readLegacy(account: String) throws -> String? {
		try read(account: account, legacy: true)
	}

	private func read(account: String, legacy: Bool) throws -> String? {
		var query = baseQuery(account: account, legacy: legacy)
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
			kSecAttrAccessible as String: Self.accessibility,
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
		add[kSecAttrAccessible as String] = Self.accessibility
		let addStatus = SecItemAdd(add as CFDictionary, nil)
		guard addStatus == errSecSuccess else {
			throw AuthSessionCoordinatorError.credentialStorage(
				"Keychain write returned status \(addStatus)."
			)
		}
	}

	func delete(account: String) throws {
		var failures: [String] = []
		for legacy in [false, true] {
			do { try delete(account: account, legacy: legacy) }
			catch { failures.append(error.localizedDescription) }
		}
		if !failures.isEmpty {
			throw AuthSessionCoordinatorError.credentialStorage(failures.joined(separator: "; "))
		}
	}

	func deleteLegacy(account: String) throws {
		try delete(account: account, legacy: true)
	}

	private func delete(account: String, legacy: Bool) throws {
		let status = SecItemDelete(baseQuery(account: account, legacy: legacy) as CFDictionary)
		if status == errSecSuccess || status == errSecItemNotFound { return }
		throw AuthSessionCoordinatorError.credentialStorage(
			"Keychain delete returned status \(status)."
		)
	}

	func baseQuery(account: String, legacy: Bool = false) -> [String: Any] {
		var query: [String: Any] = [
			kSecClass as String: kSecClassGenericPassword,
			kSecAttrService as String: service,
			kSecAttrAccount as String: account,
			kSecUseDataProtectionKeychain as String: !legacy,
		]
		if !legacy {
			query[kSecAttrAccessGroup as String] = VaultConstants.keychainAccessGroup
			query[kSecAttrSynchronizable as String] = false
		}
		return query
	}

}
