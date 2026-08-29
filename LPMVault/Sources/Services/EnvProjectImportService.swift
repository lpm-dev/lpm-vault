import Foundation

struct RemoteEnvProjectPayload: Sendable {
	let vaultId: String
	let environments: [String: [String: String]]
	let version: Int
	let keyCount: Int
}

protocol EnvProjectImportServiceProtocol: Sendable {
	func loadPersonal(authToken: String, vaultId: String) async throws -> RemoteEnvProjectPayload
	func loadOrganization(
		authToken: String,
		orgSlug: String,
		vaultId: String
	) async throws -> RemoteEnvProjectPayload
}

final class EnvProjectImportService: EnvProjectImportServiceProtocol, @unchecked Sendable {
	private let syncService: SyncService

	init(baseURL: URL) {
		syncService = SyncService.shared(baseURL: baseURL)
	}

	func loadPersonal(authToken: String, vaultId: String) async throws -> RemoteEnvProjectPayload {
		try Task.checkCancellation()
		guard let result = await syncService.pull(authToken: authToken, vaultId: vaultId) else {
			try Task.checkCancellation()
			throw EnvProjectImportError.noResponse
		}
		try Task.checkCancellation()
		guard let blob = result.encryptedBlob, let wrapped = result.wrappedKey else {
			throw EnvProjectImportError.noData(
				result.displayError ?? "No env project data is available in the cloud."
			)
		}
		guard let version = result.version, version > 0 else {
			throw EnvProjectImportError.invalidPayload("The cloud response has an invalid version.")
		}
		guard result.vaultId == vaultId else {
			throw EnvProjectImportError.invalidPayload("The cloud response is for a different env project.")
		}

		do {
			let decrypted = try VaultCrypto.decryptStableSyncData(
				authToken: authToken,
				encryptedBlob: blob,
				wrappedKey: wrapped,
				vaultId: vaultId,
				cryptoVersion: result.cryptoVersion ?? 1
			)
			try Task.checkCancellation()
			let merge = try EnvValidation.mergeRemotePayload(decrypted.plaintext, into: [:])
			return RemoteEnvProjectPayload(
				vaultId: vaultId,
				environments: merge.environments,
				version: version,
				keyCount: merge.keyCount
			)
		} catch is CancellationError {
			throw CancellationError()
		} catch let error as EnvProjectImportError {
			throw error
		} catch {
			throw EnvProjectImportError.invalidPayload(
				"Could not decrypt or validate this env project: \(error.localizedDescription)"
			)
		}
	}

	func loadOrganization(
		authToken: String,
		orgSlug: String,
		vaultId: String
	) async throws -> RemoteEnvProjectPayload {
		do {
			try Task.checkCancellation()
			let (privateKey, publicKey) = try VaultCrypto.getOrCreateX25519Keypair()
			let publicKeyBase64 = publicKey.base64EncodedString()
			guard let serverKey = await syncService.getMyPublicKey(authToken: authToken),
				let registeredKey = serverKey.publicKey
			else {
				try Task.checkCancellation()
				throw EnvProjectImportError.invalidSharingKey(
					"Your sharing key is not registered. Run `lpm env share --org \(orgSlug)` once, then retry."
				)
			}
			try Task.checkCancellation()
			guard registeredKey == publicKeyBase64 else {
				throw EnvProjectImportError.invalidSharingKey(
					"This device does not hold the sharing key registered for your account."
				)
			}

			guard let result = await syncService.pullOrg(
				authToken: authToken,
				orgSlug: orgSlug,
				vaultId: vaultId
			) else {
				try Task.checkCancellation()
				throw EnvProjectImportError.noResponse
			}
			try Task.checkCancellation()
			guard let blob = result.encryptedBlob else {
				throw EnvProjectImportError.noData(
					result.displayError ?? "No env project data is available in this organization."
				)
			}
			guard let wrapped = result.wrappedKey else {
				throw EnvProjectImportError.invalidSharingKey(
					"Your sharing key does not have access to this env project yet. Ask an organization admin to share it again."
				)
			}
			guard result.vaultId == vaultId,
				let version = result.version,
				version > 0,
				let contentKeyVersion = result.contentKeyVersion,
				contentKeyVersion > 0,
				let recipientKeyVersion = result.recipientPublicKeyVersion,
				recipientKeyVersion > 0,
				result.recipientPublicKeyFingerprint == VaultCrypto.publicKeyFingerprint(publicKey)
			else {
				throw EnvProjectImportError.invalidSharingKey(
					"The organization response has an invalid sharing-key binding."
				)
			}

			let aesKey = try VaultCrypto.unwrapKeyFromSender(
				wrapped: wrapped,
				privateKey: privateKey
			)
			let data = try VaultCrypto.decryptPayload(
				key: aesKey,
				encoded: blob,
				scope: .organization(slug: orgSlug),
				vaultId: vaultId,
				cryptoVersion: result.cryptoVersion ?? 1
			)
			try Task.checkCancellation()
			let merge = try EnvValidation.mergeRemotePayload(data, into: [:])
			return RemoteEnvProjectPayload(
				vaultId: vaultId,
				environments: merge.environments,
				version: version,
				keyCount: merge.keyCount
			)
		} catch is CancellationError {
			throw CancellationError()
		} catch let error as EnvProjectImportError {
			throw error
		} catch {
			throw EnvProjectImportError.invalidPayload(
				"Could not decrypt or validate this organization env project: \(error.localizedDescription)"
			)
		}
	}
}
