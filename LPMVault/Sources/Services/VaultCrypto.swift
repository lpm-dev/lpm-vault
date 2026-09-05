import CryptoKit
import Foundation
import Security

/// E2E encryption for vault sync — 1:1 port of Rust crypto.rs.
///
/// Format is wire-compatible: data encrypted by the Rust CLI can be
/// decrypted by this Swift code, and vice versa.
///
/// ## Encryption format
/// - AES-256-GCM with 12-byte random IV
/// - Encoded as: `base64(iv):base64(ciphertext + auth_tag)`
///
/// ## Personal key wrapping
/// - Stable wrapping key = system Keychain item `dev.lpm.vault-key` / `wrapping-key`
/// - Per-vault AES key = random 32 bytes
enum VaultCrypto {
	static let currentCryptoVersion = 3
	private static let syncAADDomain = Data("lpm-vault-sync".utf8)
	private static let lowercaseHexAlphabet = Array("0123456789abcdef".utf8)

	enum SyncScope: Equatable {
		case personal
		case organization(slug: String)
	}

	/// Generate a random 256-bit AES key.
	static func generateAESKey() -> SymmetricKey {
		SymmetricKey(size: .bits256)
	}

	// MARK: - Encrypt / Decrypt

	/// Encrypt data with AES-256-GCM.
	/// Returns `base64(iv):base64(ciphertext+tag)` — matches Rust format.
	static func encrypt(key: SymmetricKey, plaintext: Data) throws -> String {
		try encrypt(key: key, plaintext: plaintext, associatedData: Data())
	}

	private static func encrypt(
		key: SymmetricKey,
		plaintext: Data,
		associatedData: Data
	) throws -> String {
		let nonce = AES.GCM.Nonce()
		let sealed = try AES.GCM.seal(
			plaintext,
			using: key,
			nonce: nonce,
			authenticating: associatedData
		)

		guard let combined = sealed.combined else {
			throw CryptoError.encryptionFailed
		}
		var encoded = combined.base64EncodedString()
		let nonceBoundary = encoded.index(encoded.startIndex, offsetBy: 16)
		encoded.insert(":", at: nonceBoundary)
		return encoded
	}

	/// Decrypt data produced by `encrypt()`.
	static func decrypt(key: SymmetricKey, encoded: String) throws -> Data {
		try decrypt(key: key, encoded: encoded, associatedData: Data())
	}

	private static func decrypt(
		key: SymmetricKey,
		encoded: String,
		associatedData: Data
	) throws -> Data {
		let parts = encoded.split(separator: ":", maxSplits: 1)
		guard parts.count == 2 else {
			throw CryptoError.invalidFormat
		}

		guard let ivData = Data(base64Encoded: String(parts[0])) else {
			throw CryptoError.invalidBase64
		}
		guard let ciphertextAndTag = Data(base64Encoded: String(parts[1])) else {
			throw CryptoError.invalidBase64
		}

		guard ivData.count == 12 else {
			throw CryptoError.invalidIVSize(ivData.count)
		}
		guard ciphertextAndTag.count >= 16 else {
			throw CryptoError.invalidFormat
		}

		let nonce = try AES.GCM.Nonce(data: ivData)
		let tagStart = ciphertextAndTag.index(
			ciphertextAndTag.endIndex,
			offsetBy: -16
		)
		let sealedBox = try AES.GCM.SealedBox(
			nonce: nonce,
			ciphertext: ciphertextAndTag[..<tagStart],
			tag: ciphertextAndTag[tagStart...]
		)

		return try AES.GCM.open(sealedBox, using: key, authenticating: associatedData)
	}

	static func syncAssociatedData(
		scope: SyncScope,
		principalId: String,
		vaultId: String,
		revision: Int,
		cryptoVersion: Int
	) throws -> Data {
		guard cryptoVersion == currentCryptoVersion else {
			throw CryptoError.unsupportedCryptoVersion(cryptoVersion)
		}
		guard let revision = UInt64(exactly: revision), revision > 0 else {
			throw CryptoError.invalidRevision
		}
		guard !principalId.isEmpty else { throw CryptoError.invalidFormat }
		let principalIdData = Data(principalId.utf8)
		let vaultIdData = Data(vaultId.utf8)
		let scopeByte: UInt8
		let orgSlugData: Data
		switch scope {
		case .personal:
			scopeByte = 1
			orgSlugData = Data()
		case .organization(let slug):
			scopeByte = 2
			orgSlugData = Data(slug.utf8)
		}
		guard let principalIdLength = UInt32(exactly: principalIdData.count),
			let vaultIdLength = UInt32(exactly: vaultIdData.count),
			let orgSlugLength = UInt32(exactly: orgSlugData.count)
		else {
			throw CryptoError.contextTooLarge
		}

		var aad = syncAADDomain
		aad.append(0)
		appendUInt32(UInt32(cryptoVersion), to: &aad)
		aad.append(scopeByte)
		appendUInt32(principalIdLength, to: &aad)
		aad.append(principalIdData)
		appendUInt32(vaultIdLength, to: &aad)
		aad.append(vaultIdData)
		appendUInt32(orgSlugLength, to: &aad)
		aad.append(orgSlugData)
		appendUInt64(revision, to: &aad)
		return aad
	}

	private static func appendUInt32(_ value: UInt32, to data: inout Data) {
		var bigEndian = value.bigEndian
		Swift.withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
	}

	private static func appendUInt64(_ value: UInt64, to data: inout Data) {
		var bigEndian = value.bigEndian
		Swift.withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
	}

	static func encryptPayload(
		key: SymmetricKey,
		plaintext: Data,
		scope: SyncScope,
		principalId: String,
		vaultId: String,
		revision: Int
	) throws -> String {
		let aad = try syncAssociatedData(
			scope: scope,
			principalId: principalId,
			vaultId: vaultId,
			revision: revision,
			cryptoVersion: currentCryptoVersion
		)
		return try encrypt(key: key, plaintext: plaintext, associatedData: aad)
	}

	static func decryptPayload(
		key: SymmetricKey,
		encoded: String,
		scope: SyncScope,
		principalId: String,
		vaultId: String,
		revision: Int,
		cryptoVersion: Int
	) throws -> Data {
		let aad = try syncAssociatedData(
			scope: scope,
			principalId: principalId,
			vaultId: vaultId,
			revision: revision,
			cryptoVersion: cryptoVersion
		)
		return try decrypt(key: key, encoded: encoded, associatedData: aad)
	}

	// MARK: - Key Wrapping

	/// Wrap an AES key with a wrapping key.
	static func wrapKey(wrappingKey: SymmetricKey, aesKey: SymmetricKey) throws -> String {
		let keyData = aesKey.withUnsafeBytes { Data($0) }
		return try encrypt(key: wrappingKey, plaintext: keyData)
	}

	/// Unwrap an AES key.
	static func unwrapKey(wrappingKey: SymmetricKey, wrapped: String) throws -> SymmetricKey {
		let keyData = try decrypt(key: wrappingKey, encoded: wrapped)
		guard keyData.count == 32 else {
			throw CryptoError.invalidKeySize(keyData.count)
		}
		return SymmetricKey(data: keyData)
	}

	/// Encrypt personal sync data with the stable wrapping key shared with the Rust client.
	static func encryptForStableSync(
		secretsJSON: String,
		principalId: String,
		vaultId: String,
		revision: Int
	) throws -> (encryptedBlob: String, wrappedKey: String) {
		try encryptForStableSync(
			plaintext: Data(secretsJSON.utf8),
			principalId: principalId,
			vaultId: vaultId,
			revision: revision,
			wrappingKey: stableWrappingKey()
		)
	}

	static func encryptForStableSync(
		plaintext: Data,
		principalId: String,
		vaultId: String,
		revision: Int
	) throws -> (encryptedBlob: String, wrappedKey: String) {
		try encryptForStableSync(
			plaintext: plaintext,
			principalId: principalId,
			vaultId: vaultId,
			revision: revision,
			wrappingKey: stableWrappingKey()
		)
	}

	static func encryptForStableSync(
		secretsJSON: String,
		principalId: String,
		vaultId: String,
		revision: Int,
		wrappingKey: SymmetricKey
	) throws -> (encryptedBlob: String, wrappedKey: String) {
		try encryptForStableSync(
			plaintext: Data(secretsJSON.utf8),
			principalId: principalId,
			vaultId: vaultId,
			revision: revision,
			wrappingKey: wrappingKey
		)
	}

	static func encryptForStableSync(
		plaintext: Data,
		principalId: String,
		vaultId: String,
		revision: Int,
		wrappingKey: SymmetricKey
	) throws -> (encryptedBlob: String, wrappedKey: String) {
		let aesKey = generateAESKey()
		return (
			try encryptPayload(
				key: aesKey,
				plaintext: plaintext,
				scope: .personal,
				principalId: principalId,
				vaultId: vaultId,
				revision: revision
			),
			try wrapKey(wrappingKey: wrappingKey, aesKey: aesKey)
		)
	}

	static func decryptStableSyncData(
		encryptedBlob: String,
		wrappedKey: String,
		principalId: String,
		vaultId: String,
		revision: Int,
		cryptoVersion: Int
	) throws -> Data {
		try decryptStableSyncData(
			encryptedBlob: encryptedBlob,
			wrappedKey: wrappedKey,
			principalId: principalId,
			vaultId: vaultId,
			revision: revision,
			cryptoVersion: cryptoVersion,
			stableWrappingKey: stableWrappingKey()
		)
	}

	static func decryptStableSyncData(
		encryptedBlob: String,
		wrappedKey: String,
		principalId: String,
		vaultId: String,
		revision: Int,
		cryptoVersion: Int,
		stableWrappingKey: SymmetricKey
	) throws -> Data {
		guard cryptoVersion == currentCryptoVersion else {
			throw CryptoError.unsupportedCryptoVersion(cryptoVersion)
		}
		let aesKey = try unwrapKey(wrappingKey: stableWrappingKey, wrapped: wrappedKey)
		return try decryptPayload(
			key: aesKey,
			encoded: encryptedBlob,
			scope: .personal,
			principalId: principalId,
			vaultId: vaultId,
			revision: revision,
			cryptoVersion: cryptoVersion
		)
	}

	static func decryptStableSync(
		encryptedBlob: String,
		wrappedKey: String,
		principalId: String,
		vaultId: String,
		revision: Int,
		cryptoVersion: Int,
		wrappingKey: SymmetricKey
	) throws -> String {
		let aesKey = try unwrapKey(wrappingKey: wrappingKey, wrapped: wrappedKey)
		let plaintext = try decryptPayload(
			key: aesKey,
			encoded: encryptedBlob,
			scope: .personal,
			principalId: principalId,
			vaultId: vaultId,
			revision: revision,
			cryptoVersion: cryptoVersion
		)
		guard let json = String(data: plaintext, encoding: .utf8) else {
			throw CryptoError.invalidUTF8
		}
		return json
	}

	static func publicKeyFingerprint(_ publicKey: Data) -> String {
		let digest = SHA256.hash(data: publicKey)
		var encoded = [UInt8](repeating: 0, count: SHA256.Digest.byteCount * 2)
		for (index, byte) in digest.enumerated() {
			encoded[index * 2] = lowercaseHexAlphabet[Int(byte >> 4)]
			encoded[index * 2 + 1] = lowercaseHexAlphabet[Int(byte & 0x0F)]
		}
		return String(decoding: encoded, as: UTF8.self)
	}

	// MARK: - X25519 Org Sync (ECIES-like)

	/// Generate an X25519 keypair. Returns (privateKeyData, publicKeyData) — 32 bytes each.
	static func generateX25519Keypair() -> (privateKey: Data, publicKey: Data) {
		let privateKey = Curve25519.KeyAgreement.PrivateKey()
		return (privateKey.rawRepresentation, privateKey.publicKey.rawRepresentation)
	}

	/// Derive public key from private key bytes.
	static func x25519PublicFromPrivate(_ privateKeyData: Data) throws -> Data {
		let privateKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKeyData)
		return privateKey.publicKey.rawRepresentation
	}

	static func validateContributoryX25519PublicKey(_ publicKey: Data) throws {
		guard publicKey.count == 32 else {
			throw CryptoError.invalidKeySize(publicKey.count)
		}
		let validationPrivateKey = try Curve25519.KeyAgreement.PrivateKey(
			rawRepresentation: Data(repeating: 0x42, count: 32)
		)
		let candidate = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: publicKey)
		do {
			_ = try validationPrivateKey.sharedSecretFromKeyAgreement(with: candidate)
		} catch {
			throw CryptoError.nonContributoryPublicKey
		}
	}

	/// Wrap an AES-256 key for a recipient using ECIES-like X25519 + HKDF + AES-GCM.
	///
	/// Format: `base64(ephemeralPublic):base64(iv):base64(ciphertext+tag)`
	/// Wire-compatible with Rust `wrap_key_for_recipient`.
	static func wrapKeyForRecipient(
		aesKey: SymmetricKey,
		recipientPublicKey: Data
	) throws -> String {
		let recipientPK = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: recipientPublicKey)
		let ephemeral = Curve25519.KeyAgreement.PrivateKey()

		// ECDH → shared secret → HKDF
		let sharedSecret = try ephemeral.sharedSecretFromKeyAgreement(with: recipientPK)
		let derivedKey = sharedSecret.hkdfDerivedSymmetricKey(
			using: SHA256.self,
			salt: Data(),
			sharedInfo: Data("lpm-vault-org".utf8),
			outputByteCount: 32
		)

		// AES-GCM encrypt the AES key
		let aesKeyData = aesKey.withUnsafeBytes { Data($0) }
		let wrapped = try encrypt(key: derivedKey, plaintext: aesKeyData)

		// Prepend ephemeral public key
		let ephPubBase64 = ephemeral.publicKey.rawRepresentation.base64EncodedString()
		return "\(ephPubBase64):\(wrapped)"
	}

	/// Unwrap an AES-256 key using the recipient's X25519 private key.
	///
	/// Input format: `base64(ephemeralPublic):base64(iv):base64(ciphertext+tag)`
	static func unwrapKeyFromSender(
		wrapped: String,
		privateKey: Data
	) throws -> SymmetricKey {
		// Split: ephemeralPublic : iv : ciphertext+tag
		let parts = wrapped.split(separator: ":", maxSplits: 1)
		guard parts.count == 2 else { throw CryptoError.invalidFormat }

		guard let ephPubData = Data(base64Encoded: String(parts[0])) else {
			throw CryptoError.invalidBase64
		}
		guard ephPubData.count == 32 else {
			throw CryptoError.invalidKeySize(ephPubData.count)
		}

		let ephPK = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: ephPubData)
		let myPrivateKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKey)

		// ECDH → shared secret → HKDF
		let sharedSecret = try myPrivateKey.sharedSecretFromKeyAgreement(with: ephPK)
		let derivedKey = sharedSecret.hkdfDerivedSymmetricKey(
			using: SHA256.self,
			salt: Data(),
			sharedInfo: Data("lpm-vault-org".utf8),
			outputByteCount: 32
		)

		// Decrypt the AES key
		let aesEncrypted = String(parts[1])
		let aesKeyData = try decrypt(key: derivedKey, encoded: aesEncrypted)
		guard aesKeyData.count == 32 else {
			throw CryptoError.invalidKeySize(aesKeyData.count)
		}

		return SymmetricKey(data: aesKeyData)
	}

	// MARK: - X25519 Key Storage (Keychain via Security.framework)

	private static let scopedX25519AccountPrefix = "__x25519_private_key__."
	private static let x25519Service = VaultConstants.keychainService
	private static let wrappingKeyService = "dev.lpm.vault-key"
	private static let wrappingKeyAccount = "wrapping-key"
	private static let x25519KeyStore = SharedKeychainStore(service: x25519Service)
	private static let wrappingKeyStore = SharedKeychainStore(service: wrappingKeyService)

	private static func stableWrappingKey() throws -> SymmetricKey {
		try VaultKeychainTransactionLock.withLock {
			try stableWrappingKeyUnlocked()
		}
	}

	private static func stableWrappingKeyUnlocked() throws -> SymmetricKey {
		if let key = try readStableWrappingKeyFromKeychain() {
			return SymmetricKey(data: key)
		}

		var bytes = [UInt8](repeating: 0, count: 32)
		guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
			throw CryptoError.encryptionFailed
		}
		let key = Data(bytes)
		let stored = try addOrReadStableWrappingKey(key)
		return SymmetricKey(data: stored)
	}

	private static func readStableWrappingKeyFromKeychain() throws -> Data? {
		guard let encoded = try wrappingKeyStore.read(account: wrappingKeyAccount) else { return nil }
		guard let hex = String(data: encoded, encoding: .utf8),
			let key = decodeWrappingKey(hex.trimmingCharacters(in: .whitespacesAndNewlines))
		else {
			throw CryptoError.invalidStoredKey("The vault wrapping key is invalid.")
		}
		return key
	}

	private static func addOrReadStableWrappingKey(_ candidate: Data) throws -> Data {
			guard candidate.count == 32 else { throw CryptoError.invalidKeySize(candidate.count) }
			let hex = candidate.map { String(format: "%02x", $0) }.joined()
			do {
				try wrappingKeyStore.add(account: wrappingKeyAccount, data: Data(hex.utf8))
				return candidate
			} catch let error as KeychainStoreError where error.statusCode == errSecDuplicateItem {
				guard let stored = try readStableWrappingKeyFromKeychain() else {
					throw KeychainStoreError.concurrentModification
				}
				return stored
			}
		}

	private static func decodeWrappingKey(_ hex: String) -> Data? {
		guard hex.count == 64 else { return nil }
		var bytes = [UInt8]()
		bytes.reserveCapacity(32)
		var index = hex.startIndex
		for _ in 0..<32 {
			let next = hex.index(index, offsetBy: 2)
			guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
			bytes.append(byte)
			index = next
		}
			return Data(bytes)
		}

	static func x25519KeychainAccount(
		registryURL: String,
		callerUserID: String
	) throws -> String {
		guard !callerUserID.isEmpty,
			callerUserID.utf8.count <= 256,
			!callerUserID.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
		else {
			throw CryptoError.invalidStoredKey("The authenticated caller identity is invalid.")
		}
		let canonicalRegistryURL = try canonicalRegistryURL(registryURL)
		var hasher = SHA256()
		for component in [canonicalRegistryURL, callerUserID] {
			var length = UInt64(component.utf8.count).bigEndian
			Swift.withUnsafeBytes(of: &length) { hasher.update(bufferPointer: $0) }
			if component.utf8.withContiguousStorageIfAvailable({ bytes in
				hasher.update(bufferPointer: UnsafeRawBufferPointer(bytes))
			}) == nil {
				hasher.update(data: Data(component.utf8))
			}
		}
		let digest = hasher.finalize()
			.map { String(format: "%02x", $0) }
			.joined()
		return scopedX25519AccountPrefix + digest
	}

	private static func canonicalRegistryURL(_ value: String) throws -> String {
		guard var components = URLComponents(string: value),
			let scheme = components.scheme?.lowercased(),
			let host = components.host?.lowercased(),
			["http", "https"].contains(scheme),
			!host.isEmpty,
			components.user == nil,
			components.password == nil,
			components.query == nil,
			components.fragment == nil
		else {
			throw CryptoError.invalidStoredKey("The Registry URL for the sharing key is invalid.")
		}
		components.scheme = scheme
		components.host = host
		if (scheme == "https" && components.port == 443)
			|| (scheme == "http" && components.port == 80)
		{
			components.port = nil
		}
		var path = components.percentEncodedPath
		while path.last == "/" { path.removeLast() }
		components.percentEncodedPath = path
		guard let canonical = components.url?.absoluteString else {
			throw CryptoError.invalidStoredKey("The Registry URL for the sharing key is invalid.")
		}
		return canonical
	}

	private static func readX25519PrivateKey(account: String) throws -> Data? {
		guard let encoded = try x25519KeyStore.read(account: account) else { return nil }
		guard let base64 = String(data: encoded, encoding: .utf8),
			let key = Data(base64Encoded: base64)
		else {
			throw CryptoError.invalidStoredKey("The X25519 private key is not valid base64.")
		}
		guard key.count == 32 else { throw CryptoError.invalidKeySize(key.count) }
		return key
	}

	static func getOrCreateX25519Keypair(
		registryURL: String,
		callerUserID: String
	) throws -> (privateKey: Data, publicKey: Data) {
		let account = try x25519KeychainAccount(
			registryURL: registryURL,
			callerUserID: callerUserID
		)
		if let existing = try readX25519PrivateKey(account: account) {
			return (existing, try x25519PublicFromPrivate(existing))
		}
		return try getOrCreateX25519Keypair(account: account)
	}

	private static func getOrCreateX25519Keypair(
		account: String
	) throws -> (privateKey: Data, publicKey: Data) {
		if let existing = try readX25519PrivateKey(account: account) {
			return (existing, try x25519PublicFromPrivate(existing))
		}
		return try addOrReadX25519Keypair(generateX25519Keypair().privateKey, account: account)
	}

	private static func addOrReadX25519Keypair(
		_ candidate: Data,
		account: String
	) throws -> (privateKey: Data, publicKey: Data) {
		let encoded = Data(candidate.base64EncodedString().utf8)
		do {
			try x25519KeyStore.add(account: account, data: encoded)
			return (candidate, try x25519PublicFromPrivate(candidate))
		} catch let error as KeychainStoreError where error.statusCode == errSecDuplicateItem {
			guard let winner = try readX25519PrivateKey(account: account) else {
				throw KeychainStoreError.concurrentModification
			}
			return (winner, try x25519PublicFromPrivate(winner))
		}
	}

	// MARK: - Errors

	enum CryptoError: LocalizedError {
		case encryptionFailed
		case invalidFormat
		case invalidBase64
		case invalidIVSize(Int)
		case invalidKeySize(Int)
		case invalidUTF8
		case unsupportedCryptoVersion(Int)
		case invalidRevision
		case contextTooLarge
		case nonContributoryPublicKey
		case invalidStoredKey(String)

		var errorDescription: String? {
			switch self {
			case .encryptionFailed:
				"Encryption failed"
			case .invalidFormat:
				"Invalid encrypted format (expected iv:ciphertext)"
			case .invalidBase64:
				"Invalid base64 encoding"
			case .invalidIVSize(let n):
				"Invalid IV size: \(n) bytes (expected 12)"
			case .invalidKeySize(let n):
				"Invalid key size: \(n) bytes (expected 32)"
			case .invalidUTF8:
				"Decrypted data is not valid UTF-8"
			case .unsupportedCryptoVersion(let version):
				"Unsupported vault crypto version: \(version)"
			case .invalidRevision:
				"Vault revision must be positive"
			case .contextTooLarge:
				"Vault encryption context is too large"
			case .nonContributoryPublicKey:
				"X25519 public key is non-contributory"
			case .invalidStoredKey(let message):
				message
			}
		}
	}
}
