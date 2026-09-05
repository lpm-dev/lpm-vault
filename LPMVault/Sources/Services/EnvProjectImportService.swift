import Foundation

struct RemoteEnvProjectPayload: Sendable {
	let vaultId: String
	let environments: [String: [String: String]]
	let version: Int
	let keyCount: Int
	let principalID: String?

	init(
		vaultId: String,
		environments: [String: [String: String]],
		version: Int,
		keyCount: Int,
		principalID: String? = nil
	) {
		self.vaultId = vaultId
		self.environments = environments
		self.version = version
		self.keyCount = keyCount
		self.principalID = principalID
	}
}

protocol EnvProjectImportServiceProtocol: Sendable {
	func loadPersonal(authToken: String, vaultId: String) async throws -> RemoteEnvProjectPayload
	func loadOrganization(
		authToken: String,
		orgSlug: String,
		vaultId: String,
		expectedCallerUserID: String
	) async throws -> RemoteEnvProjectPayload
}

final class EnvProjectImportService: EnvProjectImportServiceProtocol, @unchecked Sendable {
	private let personalSyncService: any PersonalSyncServiceProtocol
	private let organizationSyncService: any OrgSyncServiceProtocol
	private let registryURL: String
	private let sharingKeypairProvider:
		@Sendable (
			_ registryURL: String,
			_ callerUserID: String,
			_ expectedPublicKey: String?,
			_ expectedFingerprint: String?
		) throws -> (privateKey: Data, publicKey: Data)
	private let personalDecryptor:
		@Sendable (
			_ encryptedBlob: String,
			_ wrappedKey: String,
			_ principalId: String,
			_ vaultId: String,
			_ revision: Int,
			_ cryptoVersion: Int
		) throws -> Data

	init(baseURL: URL) {
		let syncService = SyncService.shared(baseURL: baseURL)
		personalSyncService = syncService
		organizationSyncService = syncService
		registryURL = AuthSessionStore.registryURL(for: baseURL)
		sharingKeypairProvider = { registryURL, callerUserID, _, _ in
			try VaultCrypto.getOrCreateX25519Keypair(
				registryURL: registryURL,
				callerUserID: callerUserID
			)
		}
		personalDecryptor = {
			try VaultCrypto.decryptStableSyncData(
				encryptedBlob: $0,
				wrappedKey: $1,
				principalId: $2,
				vaultId: $3,
				revision: $4,
				cryptoVersion: $5
			)
		}
	}

	init(
		personalSyncService: any PersonalSyncServiceProtocol,
		organizationSyncService: any OrgSyncServiceProtocol,
		registryURL: String = "https://lpm.dev",
		sharingKeypairProvider: @escaping @Sendable () throws -> (
			privateKey: Data, publicKey: Data
		),
		personalDecryptor:
			@escaping @Sendable (
				_ encryptedBlob: String,
				_ wrappedKey: String,
				_ principalId: String,
				_ vaultId: String,
				_ revision: Int,
				_ cryptoVersion: Int
			) throws -> Data = {
				try VaultCrypto.decryptStableSyncData(
					encryptedBlob: $0,
					wrappedKey: $1,
					principalId: $2,
					vaultId: $3,
					revision: $4,
					cryptoVersion: $5
				)
			}
	) {
		self.personalSyncService = personalSyncService
		self.organizationSyncService = organizationSyncService
		self.registryURL = registryURL
		self.sharingKeypairProvider = { _, _, _, _ in try sharingKeypairProvider() }
		self.personalDecryptor = personalDecryptor
	}

	func loadPersonal(authToken: String, vaultId: String) async throws -> RemoteEnvProjectPayload {
		try Task.checkCancellation()
		let response = await personalSyncService.pullAuthenticated(
			authToken: authToken,
			vaultId: vaultId
		)
		guard case .response(let value) = response else {
			throw EnvProjectImportError.unauthorized
		}
		guard let result = value else {
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
		guard let principalID = result.principalId,
			!principalID.isEmpty,
			let cryptoVersion = result.cryptoVersion,
			cryptoVersion == VaultCrypto.currentCryptoVersion
		else {
			throw EnvProjectImportError.invalidPayload(
				"The cloud response uses an unsupported encryption version."
			)
		}

		do {
			let decrypted = try personalDecryptor(
				blob,
				wrapped,
				principalID,
				vaultId,
				version,
				cryptoVersion
			)
			try Task.checkCancellation()
			let merge = try EnvValidation.mergeRemotePayload(decrypted, into: [:])
			return RemoteEnvProjectPayload(
				vaultId: vaultId,
				environments: merge.environments,
				version: version,
				keyCount: merge.keyCount,
				principalID: principalID
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
		vaultId: String,
		expectedCallerUserID: String
	) async throws -> RemoteEnvProjectPayload {
		do {
			try Task.checkCancellation()
			guard case .response(let pullResponse) = await organizationSyncService.pullOrgAuthenticated(
				authToken: authToken,
				orgSlug: orgSlug,
				vaultId: vaultId
			) else { throw EnvProjectImportError.unauthorized }
			guard let result = pullResponse else {
				try Task.checkCancellation()
				throw EnvProjectImportError.noResponse
			}
			try Task.checkCancellation()
			guard result.callerUserId == expectedCallerUserID else {
				throw EnvProjectImportError.invalidPayload(
					"The organization response is bound to a different account."
				)
			}
			if result.code == "vault_member_needs_rewrap" {
				guard let callerUserID = result.callerUserId,
					result.organizationId.flatMap(UUID.init(uuidString:)) != nil
				else {
					throw EnvProjectImportError.invalidSharingKey(
						"The organization access response has an invalid authenticated identity."
					)
				}
				guard case .response(let serverKeyResponse) = await organizationSyncService
					.getMyPublicKeyAuthenticated(
						authToken: authToken,
						expectedPrincipalId: callerUserID
					)
				else { throw EnvProjectImportError.unauthorized }
				try Task.checkCancellation()
				guard serverKeyResponse?.principalId == callerUserID,
					let registeredKey = serverKeyResponse?.publicKey
				else {
					throw EnvProjectImportError.invalidSharingKey(
						"Your sharing key is not registered. Run `lpm env share --org \(orgSlug)` once, then retry."
					)
				}
				let (_, publicKey) = try sharingKeypairProvider(
					registryURL,
					callerUserID,
					registeredKey,
					serverKeyResponse?.publicKeyFingerprint
				)
				guard registeredKey == publicKey.base64EncodedString() else {
					throw EnvProjectImportError.invalidSharingKey(
						"This device does not hold the sharing key registered for your account."
					)
				}
				throw EnvProjectImportError.invalidSharingKey(
					"Your registered sharing key does not have access to this env project yet. Ask an organization admin to share it again."
				)
			}
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
				version > 0
			else {
				throw EnvProjectImportError.invalidPayload(
					"The organization response has an invalid env project binding."
				)
			}
			guard let principalID = result.principalId,
				!principalID.isEmpty,
				let callerUserID = result.callerUserId,
				let cryptoVersion = result.cryptoVersion,
				cryptoVersion == VaultCrypto.currentCryptoVersion
			else {
				throw EnvProjectImportError.invalidPayload(
					"The organization response uses an unsupported encryption version."
				)
			}
			guard
				let contentKeyVersion = result.contentKeyVersion,
				contentKeyVersion > 0,
				let recipientKeyVersion = result.recipientPublicKeyVersion,
				recipientKeyVersion > 0,
				let expectedFingerprint = result.recipientPublicKeyFingerprint
			else {
				throw EnvProjectImportError.invalidSharingKey(
					"The organization response has an invalid sharing-key binding."
				)
			}
			let (privateKey, publicKey) = try sharingKeypairProvider(
				registryURL,
				callerUserID,
				nil,
				expectedFingerprint
			)
			guard VaultCrypto.publicKeyFingerprint(publicKey) == expectedFingerprint else {
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
				principalId: principalID,
				vaultId: vaultId,
				revision: version,
				cryptoVersion: cryptoVersion
			)
			try Task.checkCancellation()
			let merge = try EnvValidation.mergeRemotePayload(data, into: [:])
			return RemoteEnvProjectPayload(
				vaultId: vaultId,
				environments: merge.environments,
				version: version,
				keyCount: merge.keyCount,
				principalID: principalID
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
