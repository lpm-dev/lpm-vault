import Foundation
import Security

// MARK: - Protocol

protocol KeychainServiceProtocol {
	func listProjects() -> [VaultProject]
	func getEnvironments(vaultId: String) -> [String: [String: String]]?
	func saveEnvironments(
		vaultId: String,
		projectName: String,
		projectPath: String,
		environments: [String: [String: String]]
	) -> KeychainResult
	func deleteProject(vaultId: String) -> Bool
	func removeFromSidebar(vaultId: String) -> Bool

	// Legacy compatibility
	func getSecrets(vaultId: String) -> [String: String]?
	func saveSecrets(
		vaultId: String,
		projectName: String,
		projectPath: String,
		secrets: [String: String]
	) -> KeychainResult
}

enum KeychainResult {
	case success
	case successWithWarning(String)
	case failure(KeychainError)
}

enum KeychainError: Error, CustomStringConvertible {
	case encodingFailed
	case itemNotFound
	case accessDenied
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
		case .duplicateItem:
			return "Keychain item already exists"
		case .unexpectedStatus(let status):
			return "Keychain error: \(status)"
		case .dataTooLarge(let size):
			return "Vault data too large: \(size) bytes (Keychain limit ~100KB)"
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
final class KeychainService: KeychainServiceProtocol {
	private let service: String
	private let indexAccount = "__index__"

	init(service: String = VaultConstants.keychainService) {
		self.service = service
	}

	// MARK: - Public API

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
		let wrapper = EnvironmentsWrapper(environments: environments)
		guard let data = try? JSONEncoder().encode(wrapper) else {
			return .failure(.encodingFailed)
		}
		return saveData(vaultId: vaultId, projectName: projectName, projectPath: projectPath, data: data)
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
		var environments = getEnvironments(vaultId: vaultId) ?? [:]
		environments["default"] = secrets
		return saveEnvironments(vaultId: vaultId, projectName: projectName, projectPath: projectPath, environments: environments)
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
			? "Vault is approaching size limit (\(data.count) bytes)"
			: nil

		// Save secrets data
		let dataResult = writeItem(account: vaultId, data: data)
		guard dataResult else {
			return .failure(.unexpectedStatus(-1))
		}

		// Update index
		var index = readIndex()
		if let i = index.firstIndex(where: { $0.id == vaultId }) {
			index[i].name = projectName
			index[i].path = projectPath
		} else {
			index.append(VaultIndexEntry(id: vaultId, name: projectName, path: projectPath))
		}
		writeIndex(index)

		if let warning {
			return .successWithWarning(warning)
		}
		return .success
	}

	func deleteProject(vaultId: String) -> Bool {
		deleteItem(account: vaultId)

		// Update index
		var index = readIndex()
		index.removeAll { $0.id == vaultId }
		writeIndex(index)

		return true
	}

	/// Remove from sidebar only — keeps Keychain data intact.
	/// The project can be re-added by opening the same folder.
	func removeFromSidebar(vaultId: String) -> Bool {
		var index = readIndex()
		index.removeAll { $0.id == vaultId }
		writeIndex(index)
		return true
	}

	// MARK: - Private: Low-level Keychain Operations
	//
	// Uses Security framework with kSecAttrAccessible = kSecAttrAccessibleWhenUnlocked
	// which avoids per-application ACL prompts entirely. Items are accessible to any
	// process while the keychain is unlocked (which it always is when the user is logged in).

	private func readItem(account: String) -> Data? {
		let query: [String: Any] = [
			kSecClass as String: kSecClassGenericPassword,
			kSecAttrService as String: service,
			kSecAttrAccount as String: account,
			kSecReturnData as String: true,
			kSecMatchLimit as String: kSecMatchLimitOne,
		]

		var result: AnyObject?
		let status = SecItemCopyMatching(query as CFDictionary, &result)

		guard status == errSecSuccess, let data = result as? Data else {
			return nil
		}
		return data
	}

	private func writeItem(account: String, data: Data) -> Bool {
		// Try update first
		let searchQuery: [String: Any] = [
			kSecClass as String: kSecClassGenericPassword,
			kSecAttrService as String: service,
			kSecAttrAccount as String: account,
		]

		let updateAttrs: [String: Any] = [
			kSecValueData as String: data,
		]

		let updateStatus = SecItemUpdate(searchQuery as CFDictionary, updateAttrs as CFDictionary)
		if updateStatus == errSecSuccess {
			return true
		}

		// Item doesn't exist — add new with permissive access
		if updateStatus == errSecItemNotFound {
			var addQuery: [String: Any] = [
				kSecClass as String: kSecClassGenericPassword,
				kSecAttrService as String: service,
				kSecAttrAccount as String: account,
				kSecValueData as String: data,
				kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
			]

			// Create permissive access — allow any application
			if let access = SecAccessCreateWithOwnerAndACL(0, 0, SecAccessOwnerType(kSecUseOnlyUID), nil, nil) {
				addQuery[kSecAttrAccess as String] = access
			}

			let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
			return addStatus == errSecSuccess
		}

		return false
	}

	private func deleteItem(account: String) {
		let query: [String: Any] = [
			kSecClass as String: kSecClassGenericPassword,
			kSecAttrService as String: service,
			kSecAttrAccount as String: account,
		]
		SecItemDelete(query as CFDictionary)
	}

	// MARK: - Private: Index Management

	private func readIndex() -> [VaultIndexEntry] {
		guard let data = readItem(account: indexAccount),
			let entries = try? JSONDecoder().decode([VaultIndexEntry].self, from: data)
		else {
			return []
		}
		return entries
	}

	private func writeIndex(_ entries: [VaultIndexEntry]) {
		guard let data = try? JSONEncoder().encode(entries) else { return }
		_ = writeItem(account: indexAccount, data: data)
	}
}
