import CryptoKit
import Foundation
import Testing

@testable import LPMVault

private let round4OrganizationID = "00000000-0000-4000-8000-000000000001"

extension VaultStoreTests {
	@Suite("Round 4 audit regressions")
	struct Round4AuditRegressionTests {
	@Test("single-environment snapshots reuse one sorted-key buffer")
	func singleEnvironmentSnapshotReusesSortedKeyBuffer() {
		let project = VaultProject(
			id: "project",
			name: "Project",
			path: "",
			environments: ["default": ["B": "2", "A": "1"]]
		)
		let snapshot = VaultWorkspaceSnapshot(project: project)
		let environmentKeys = snapshot.sortedKeys(for: "default")

		let allKeysBase = snapshot.allSecretKeys.withUnsafeBufferPointer(\.baseAddress)
		let environmentKeysBase = environmentKeys.withUnsafeBufferPointer(\.baseAddress)

		#expect(snapshot.allSecretKeys == ["A", "B"])
		#expect(allKeysBase == environmentKeysBase)
	}

	@Test("snapshot derives per-environment missing counts from cached key totals")
	func snapshotMissingKeyCountsAreExact() {
		let snapshot = VaultWorkspaceSnapshot(project: VaultProject(
			id: "project",
			name: "Project",
			path: "",
			environments: [
				"default": ["A": "1", "B": "2", "C": "3"],
				"empty": [:],
				"partial": ["A": "1"],
			]
		))

		#expect(snapshot.missingKeyCount(for: "default") == 0)
		#expect(snapshot.missingKeyCount(for: "empty") == 3)
		#expect(snapshot.missingKeyCount(for: "partial") == 2)
		#expect(snapshot.missingKeyCount(for: "absent") == 3)
	}

	@Test("unfiltered content derivation reuses snapshot key buffers")
	func unfilteredContentDerivationReusesSnapshotKeyBuffers() {
		let project = VaultProject(
			id: "project",
			name: "Project",
			path: "",
			environments: ["default": ["B": "2", "A": "1"]]
		)
		let snapshot = VaultWorkspaceSnapshot(project: project)
		let matrix = VaultContentDerivation(
			project: project,
			snapshot: snapshot,
			selectedEnvironment: "default",
			mode: .matrix,
			filter: .all,
			searchText: "",
			revealedKeys: []
		)
		let environment = VaultContentDerivation(
			project: project,
			snapshot: snapshot,
			selectedEnvironment: "default",
			mode: .environment("default"),
			filter: .all,
			searchText: "",
			revealedKeys: []
		)

		let allKeysBase = snapshot.allSecretKeys.withUnsafeBufferPointer(\.baseAddress)
		let matrixKeysBase = matrix.filteredKeys.withUnsafeBufferPointer(\.baseAddress)
		let snapshotEnvironmentKeys = snapshot.sortedKeys(for: "default")
		let snapshotEnvironmentBase = snapshotEnvironmentKeys.withUnsafeBufferPointer(\.baseAddress)
		let environmentKeysBase = environment.environmentKeys.withUnsafeBufferPointer(\.baseAddress)

		#expect(allKeysBase == matrixKeysBase)
		#expect(snapshotEnvironmentBase == environmentKeysBase)
	}

	@Test("incremental snapshots rebuild every project whose cached origin is stale")
	func incrementalSnapshotsRebuildStaleCachedOrigins() async throws {
		var first = VaultProject(
			id: "first",
			name: "First",
			path: "",
			environments: [
				"default": ["VALUE": "old-first"],
				"production": ["VALUE": "old-first"],
			]
		)
		var second = VaultProject(
			id: "second",
			name: "Second",
			path: "",
			environments: [
				"default": ["VALUE": "old-second"],
				"production": ["VALUE": "old-second"],
			]
		)
		let builder = VaultWorkspaceSnapshotBuilder()
		let staleSnapshots = try #require(await builder.buildAll([first, second]))

		first.environments["default"]?["VALUE"] = "new-first"
		second.environments["default"]?["VALUE"] = "new-second"
		let update = try #require(
			await builder.buildIncremental(
				currentProjects: [first, second],
				existingSnapshots: staleSnapshots
			)
		)

		#expect(update.buildCount == 2)
		#expect(update.snapshots["first"]?.hasDrift(for: "VALUE") == true)
		#expect(update.snapshots["second"]?.hasDrift(for: "VALUE") == true)
	}

	@Test("empty-local cloud imports preserve validated environments and key counts")
	func emptyLocalCloudImportPreservesValidatedPayload() throws {
		let result = try EnvValidation.mergeRemotePayload(
			Data(#"{"environments":{"production":{"A":"1","B":"2"}}}"#.utf8),
			into: [:]
		)

		#expect(result.environments == ["production": ["A": "1", "B": "2"]])
		#expect(result.keyCount == 2)
	}

	@Test("cloud merges still reject invalid durable environment names")
	func cloudMergeRejectsInvalidDurableEnvironmentNames() {
		#expect(throws: EnvValidation.PayloadError.invalidNames) {
			try EnvValidation.mergeRemotePayload(
				Data(#"{"environments":{"production":{"TOKEN":"remote"}}}"#.utf8),
				into: ["../invalid": ["LOCAL": "value"]]
			)
		}
	}

	@Test("organization recipient keys are decoded and fingerprinted once before wrapping")
	func organizationRecipientValidationIsReusedForWrapping() throws {
		let first = VaultCrypto.generateX25519Keypair().publicKey
		let second = VaultCrypto.generateX25519Keypair().publicKey
		let members = [first, second].enumerated().map { index, publicKey in
			SyncService.MemberPublicKey(
				userId: "member-\(index)",
				role: "member",
				publicKey: publicKey.base64EncodedString(),
				publicKeyVersion: 1,
				publicKeyFingerprint: VaultCrypto.publicKeyFingerprint(publicKey),
				hasPublicKey: true
			)
		}
		var decodeCount = 0
		var fingerprintCount = 0
		let prepared = try OrganizationMemberAuthorizationPolicy.prepare(
			members,
			trust: OrgKeyTrust(),
			decodePublicKey: { encoded in
				decodeCount += 1
				return Data(base64Encoded: encoded)
			},
			fingerprintPublicKey: { publicKey in
				fingerprintCount += 1
				return VaultCrypto.publicKeyFingerprint(publicKey)
			}
		)

		#expect(decodeCount == members.count)
		#expect(fingerprintCount == members.count)
		#expect(prepared.validatedRecipients.map(\.sharingKey.canonicalBase64) == members.map(\.publicKey))
		_ = try VaultStore.wrapContentKey(
			SymmetricKey(size: .bits256),
			for: prepared.validatedRecipients
		)
		#expect(decodeCount == members.count)
		#expect(fingerprintCount == members.count)
	}

	@Test("organization approval matching rejects duplicate entries")
	func organizationApprovalMatchingRejectsDuplicates() {
		let approval = PendingKeyApproval(
			memberId: "member",
			fingerprint: "fingerprint",
			isNewMember: true,
			oldFingerprint: nil
		)

		#expect(!PendingKeyApproval.exactlyMatches(
			[approval, approval],
			pending: [approval, approval]
		))
	}

	@Test("organization import rejects caller substitution before selecting a device key")
	func organizationImportRejectsCallerSubstitutionBeforeKeyLookup() async {
		let keyLookups = Round4Counter()
		let sync = MockOrgSyncService()
		sync.pullResult = SyncService.SyncStatus(
			vaultId: "organization-project",
			version: 1,
			cryptoVersion: VaultCrypto.currentCryptoVersion,
			contentKeyVersion: 1,
			recipientPublicKeyVersion: 1,
			recipientPublicKeyFingerprint: "unused",
			status: "ok",
			error: nil,
			code: nil,
			serverVersion: nil,
			hint: nil,
			encryptedBlob: "unused",
			wrappedKey: "unused",
			updatedAt: nil,
			principalId: round4OrganizationID,
			callerUserId: "account-b",
			organizationId: round4OrganizationID
		)
		let importer = EnvProjectImportService(
			personalSyncService: MockPersonalSyncService(),
			organizationSyncService: sync,
			sharingKeypairProvider: {
				keyLookups.increment()
				return VaultCrypto.generateX25519Keypair()
			}
		)

		await #expect(throws: EnvProjectImportError.invalidPayload(
			"The organization response is bound to a different account."
		)) {
			try await importer.loadOrganization(
				authToken: "session",
				orgSlug: "acme",
				vaultId: "organization-project",
				expectedCallerUserID: "account-a"
			)
		}
		#expect(keyLookups.value == 0)
	}

	@Test("organization key trust is isolated by registry and immutable organization ID")
	@MainActor
	func organizationKeyTrustIsFullyScoped() async throws {
		let coordinator = VaultPersistenceCoordinator(service: MockKeychainService())
		let trusted = OrgKeyTrust(trustedFingerprints: ["member": "fingerprint"])
		let firstScope = try #require(OrgTrustScope(
			registryURL: "https://registry-a.example",
			organizationID: "00000000-0000-4000-8000-000000000001",
			organizationSlug: "acme"
		))
		let otherRegistry = try #require(OrgTrustScope(
			registryURL: "https://registry-b.example",
			organizationID: "00000000-0000-4000-8000-000000000001",
			organizationSlug: "acme"
		))
		let recreatedOrganization = try #require(OrgTrustScope(
			registryURL: "https://registry-a.example",
			organizationID: "00000000-0000-4000-8000-000000000002",
			organizationSlug: "acme"
		))

		let saved = await coordinator.saveOrgTrust(trusted, scope: firstScope)
		#expect(saved)
		#expect(firstScope.storageAccount.hasPrefix("__org_keys__"))
		#expect(!firstScope.storageAccount.hasPrefix("__org_keys_v2__"))
		let crossRegistry = try await coordinator.loadOrgTrust(scope: otherRegistry).get()
		let recreated = try await coordinator.loadOrgTrust(scope: recreatedOrganization).get()

		#expect(crossRegistry.trustedFingerprints.isEmpty)
		#expect(recreated.trustedFingerprints.isEmpty)
	}

	@Test("project creation enforces the canonical project name contract")
	@MainActor
	func projectCreationValidatesAndNormalizesNames() async {
		let keychain = MockKeychainService()
		let store = VaultStore(
			keychainService: keychain,
			biometricService: MockBiometricService(),
			apiService: MockAPIService()
		)
		store.isUnlocked = true

		let acceptedBlankName = await store.createVault(name: "\n\t")
		let acceptedOverlongName = await store.createVault(
			name: String(repeating: "a", count: 121)
		)
		let acceptedEmbeddedControl = await store.createVault(name: "release\u{000A}secrets")
		let acceptedC1Control = await store.createVault(name: "release\u{0085}secrets")
		let emojiFamily = "👨‍👩‍👧‍👦"
		let acceptedOverlongUTF16Name = await store.createVault(
			name: String(repeating: emojiFamily, count: 19)
		)
		#expect(acceptedBlankName == .failed)
		#expect(acceptedOverlongName == .failed)
		#expect(acceptedEmbeddedControl == .failed)
		#expect(acceptedC1Control == .failed)
		#expect(acceptedOverlongUTF16Name == .failed)
		#expect(keychain.envStorage.isEmpty)

		let boundary = String(repeating: "b", count: 120)
		#expect(await store.createVault(name: " \(boundary)\n") == .completed)
		#expect(keychain.envStorage.values.first?.name == boundary)

		let exactUTF16Boundary = String(repeating: "😀", count: 100)
		#expect(await store.createVault(name: exactUTF16Boundary) == .completed)
	}

	@Test("authority invalidation during personal encryption prevents cloud dispatch")
	@MainActor
	func stalePersonalPushIsNotDispatched() async {
		let entered = DispatchSemaphore(value: 0)
		let release = DispatchSemaphore(value: 0)
		let sync = MockPersonalSyncService()
		let keychain = MockKeychainService()
		keychain.envStorage["project-a"] = (
			name: "A", path: "", environments: ["default": ["TOKEN": "a"]]
		)
		keychain.envStorage["project-b"] = (
			name: "B", path: "", environments: ["default": ["TOKEN": "b"]]
		)
		let store = VaultStore(
			keychainService: keychain,
			biometricService: MockBiometricService(),
			apiService: MockAPIService(),
			personalSyncServiceFactory: { _ in sync },
			stableSyncEncryptor: { _, _, _, _ in
				entered.signal()
				release.wait()
				return ("blob", "wrapped")
			},
			authTokenProvider: { _, _ in "session" }
		)
		store.projects = [
			VaultProject(
				id: "project-a", name: "A", path: "",
				environments: ["default": ["TOKEN": "a"]]
			),
			VaultProject(
				id: "project-b", name: "B", path: "",
				environments: ["default": ["TOKEN": "b"]]
			),
		]
		store.currentUser = round4User(id: "account-a", orgSlug: "acme")
		store.isUnlocked = true
		store.selectProject("project-a")

		let push = Task { await store.pushToCloud() }
		await waitForSemaphore(entered)
		store.selectProject("project-b")
		release.signal()
		await push.value

		#expect(sync.pushCallCount == 0)
		#expect(store.selectedProjectId == "project-b")
	}

	@Test("login cannot succeed with an identity from the previous session")
	@MainActor
	func loginRequiresCoherentIdentity() async {
		let oldUser = LPMUser(
			id: "old", username: "old", name: nil, email: nil,
			avatarUrl: nil, plan: nil, createdAt: nil, orgs: nil
		)
		let newUser = LPMUser(
			id: "new", username: "new", name: nil, email: nil,
			avatarUrl: nil, plan: nil, createdAt: nil, orgs: nil
		)
		let api = SequencedIdentityAPI(responses: [
			.success(newUser),
			.failure(.transport),
		])
		let store = VaultStore(
			keychainService: MockKeychainService(),
			biometricService: MockBiometricService(),
			apiService: api,
			authTokenProvider: { _, _ in "new-access" },
			loginProvider: { _, _ in round4Credentials() },
			authSessionWriter: { _, _ in },
			authSessionClearer: { _ in }
		)
		store.currentUser = oldUser

		let succeeded = await store.login()

		#expect(succeeded)
		#expect(store.currentUser?.id == newUser.id)
	}

	@Test("a queued duplicate for another project cannot change the current environment")
	@MainActor
	func staleEnvironmentMutationPreservesCurrentSelection() async {
		let keychain = MockKeychainService()
		keychain.envStorage["project-a"] = (
			name: "A", path: "", environments: ["default": ["TOKEN": "a"]]
		)
		keychain.envStorage["project-b"] = (
			name: "B", path: "", environments: ["default": ["TOKEN": "b"]]
		)
		let entered = DispatchSemaphore(value: 0)
		let release = DispatchSemaphore(value: 0)
		keychain.blockNextSaveEnvironments = {
			entered.signal()
			release.wait()
		}
		let store = VaultStore(
			keychainService: keychain,
			biometricService: MockBiometricService(),
			apiService: MockAPIService()
		)
		store.projects = [
			VaultProject(
				id: "project-a", name: "A", path: "",
				environments: ["default": ["TOKEN": "a"]]
			),
			VaultProject(
				id: "project-b", name: "B", path: "",
				environments: ["default": ["TOKEN": "b"]]
			),
		]
		store.isUnlocked = true
		store.selectProject("project-a")

		store.duplicateEnvironment(in: "project-a", from: "default", to: "staging")
		await waitForSemaphore(entered)
		store.selectProject("project-b")
		release.signal()
		await waitUntil {
			store.projects.first(where: { $0.id == "project-a" })?
				.environments["staging"] != nil
		}

		#expect(store.selectedProjectId == "project-b")
		#expect(store.selectedEnvironment == "default")
	}

	@Test("cache reset invalidates authentication attempts already in flight")
	func biometricResetRejectsLateCacheWrite() async {
		let gate = Round4AsyncGate()
		let calls = Round4Counter()
		let service = BiometricService(
			authentication: { _ in
				calls.increment()
				await gate.arriveAndWait()
				return true
			}
		)
		let first = Task { await service.authenticate(reason: "Unlock") }
		await gate.waitUntilArrived()
		service.resetCache()
		await gate.release()
		#expect(await first.value)

		#expect(await service.authenticate(reason: "Unlock again"))
		#expect(calls.value == 2)
	}

	@Test("bounded dotenv readers reject final-component symbolic links")
	func dotenvReadersRejectSymbolicLinks() async throws {
		let directory = FileManager.default.temporaryDirectory
			.appendingPathComponent("round4-dotenv-link-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: directory) }
		let target = directory.appendingPathComponent("target.env")
		let link = directory.appendingPathComponent("selected.env")
		try Data("OTHER_SECRET=exfiltrated\n".utf8).write(to: target)
		try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

		#expect(throws: EnvFileImportError.notRegularFile) {
			_ = try BoundedEnvFileReader.read(at: link, maximumBytes: 1_024)
		}
		await #expect(throws: EnvFileImportError.notRegularFile) {
			_ = try await EnvFileImportService(maximumConcurrentImports: 1).load(at: link)
		}
	}

	@Test("pull key counts represent keys received from the remote payload")
	func pullKeyCountUsesRemoteKeys() throws {
		let payload = Data(
			#"{"environments":{"default":{"REMOTE":"new"}}}"#.utf8
		)
		let result = try EnvValidation.mergeRemotePayload(
			payload,
			into: [
				"default": ["LOCAL": "kept"],
				"local-only": ["SECOND": "kept"],
			]
		)

		#expect(result.keyCount == 1)
		#expect(result.environments.values.reduce(0) { $0 + $1.count } == 3)
	}

	@Test("default cloud sessions enforce finite request and resource deadlines")
	func defaultCloudSessionsHaveFiniteDeadlines() throws {
		let apiSession = try #require(round4Session(from: LPMAPIService()))
		let syncSession = try #require(round4Session(from: SyncService()))

		#expect(apiSession.configuration.timeoutIntervalForRequest == 15)
		#expect(apiSession.configuration.timeoutIntervalForResource == 60)
		#expect(syncSession.configuration.timeoutIntervalForRequest == 30)
		#expect(syncSession.configuration.timeoutIntervalForResource == 120)
	}

	@Test("environment workspace mode follows the selected environment")
	func environmentWorkspaceModeSynchronizesSelection() {
		#expect(
			VaultWorkspaceMode.environment("old").synchronized(to: "new")
				== .environment("new")
		)
		#expect(VaultWorkspaceMode.matrix.synchronized(to: "new") == .matrix)
	}

	@Test("dotenv export work runs away from the main actor")
	@MainActor
	func dotenvExportDoesNotBlockMainActor() async throws {
		let observation = Round4ThreadObservation()
		let service = EnvFileExportService { _, _, _ in
			observation.recordMainThread(Thread.isMainThread)
		}

		try await service.export(
			secrets: ["TOKEN": "secret"],
			to: FileManager.default.temporaryDirectory.appendingPathComponent("unused.env")
		)

		#expect(!observation.wasMainThread)
	}

	@Test("cloud import cannot commit after its authentication authority changes")
	@MainActor
	func cloudImportRejectsStaleAuthority() async {
		let gate = Round4AsyncGate()
		let authorityIsCurrent = Round4MutableBool(true)
		let importService = Round4GatedImportService(gate: gate)
		let keychain = MockKeychainService()
		let api = MockAPIService()
		api.user = round4User(orgSlug: "acme")
		let store = VaultStore(
			keychainService: keychain,
			biometricService: MockBiometricService(),
			apiService: api,
			importServiceFactory: { _ in importService },
			authAuthorizationProvider: { _, _ in
				AuthSessionAuthorization(
					token: "account-a",
					authorityGeneration: round4AuthorityGeneration()
				)
			},
			authAuthorityValidator: { _ in authorityIsCurrent.value },
			authorizedImportCommitter: { _, operation in
				guard authorityIsCurrent.value else { return nil }
				return await operation()
			}
		)
		await store.loadAccount()

		let operation = Task {
			await store.importCloudProject(
				SyncService.RemoteProject(
					vaultId: "stale-cloud",
					name: "Stale",
					version: 1,
					updatedAt: nil,
					updatedBy: nil
				)
			)
		}
		await gate.waitUntilArrived()
		authorityIsCurrent.value = false
		await gate.release()

		#expect(await operation.value == .failure(.cancelled))
		#expect(keychain.envStorage["stale-cloud"] == nil)
		#expect(store.projects.isEmpty)
	}

	@Test("personal and organization discovery reject stale authentication results")
	@MainActor
	func cloudDiscoveryRejectsStaleAuthority() async {
		for orgSlug in [nil, "acme"] as [String?] {
			let gate = Round4AsyncGate()
			let authorityIsCurrent = Round4MutableBool(true)
			let listing = Round4GatedProjectListService(gate: gate)
			let api = MockAPIService()
			api.user = round4User(orgSlug: "acme")
			let store = VaultStore(
				keychainService: MockKeychainService(),
				biometricService: MockBiometricService(),
				apiService: api,
				projectListServiceFactory: { _ in listing },
				authAuthorizationProvider: { _, _ in
					AuthSessionAuthorization(
						token: "account-a",
						authorityGeneration: round4AuthorityGeneration()
					)
				},
				authAuthorityValidator: { _ in authorityIsCurrent.value }
			)
			await store.loadAccount()

			let operation = Task {
				if let orgSlug {
					return await store.listOrganizationCloudProjects(orgSlug: orgSlug)
				}
				return await store.listPersonalCloudProjects()
			}
			await gate.waitUntilArrived()
			authorityIsCurrent.value = false
			await gate.release()

			guard case .failure(.cancelled) = await operation.value else {
				Issue.record("A stale cloud listing was published.")
				continue
			}
		}
	}

	@Test("cloud discovery clears an identity replaced before listing begins")
	@MainActor
	func cloudDiscoveryRejectsPreexistingPeerRotation() async {
		let authorization = Round4MutableAuthorization(
			token: "account-a",
			generation: round4AuthorityGeneration(seed: 1)
		)
		let listing = Round4ProjectListRecorder()
		let api = MockAPIService()
		api.user = round4User(orgSlug: "acme")
		let store = VaultStore(
			keychainService: MockKeychainService(),
			biometricService: MockBiometricService(),
			apiService: api,
			projectListServiceFactory: { _ in listing },
			authAuthorizationProvider: { _, _ in authorization.current },
			authAuthorityValidator: { authorization.isCurrent($0) },
			authorizedRemoteMutationExecutor: { _, operation in operation() }
		)
		await store.loadAccount()
		authorization.replace(
			token: "account-b",
			generation: round4AuthorityGeneration(seed: 2)
		)

		let result = await store.listPersonalCloudProjects()

		guard case .failure(.sessionNotAuthorized) = result else {
			Issue.record("Cloud discovery accepted a peer account rotation.")
			return
		}
		#expect(listing.callCount == 0)
		#expect(store.currentUser == nil)
		#expect(store.selectedAccount == .personal)
	}

	@Test("account-bound mutations reject a preexisting peer account rotation")
	@MainActor
	func accountBoundMutationsRejectPreexistingPeerRotation() async {
		let authorization = Round4MutableAuthorization(
			token: "account-a",
			generation: round4AuthorityGeneration(seed: 1)
		)
		let api = MockAPIService()
		api.user = round4User(orgSlug: "acme")
		let personalToken = round4Token(id: "personal-a")
		var organizationToken = round4Token(id: "organization-a")
		organizationToken.orgSlug = "acme"
		api.personalTokens = [personalToken]
		api.orgTokensMap = ["acme": [organizationToken]]
		let sync = MockPersonalSyncService()
		let keychain = MockKeychainService()
		keychain.envStorage["account-a-project"] = (
			name: "Account A",
			path: "",
			environments: ["default": ["TOKEN": "account-a-secret"]]
		)
		let store = VaultStore(
			keychainService: keychain,
			biometricService: MockBiometricService(),
			apiService: api,
			personalSyncServiceFactory: { _ in sync },
			stableSyncEncryptor: { _, _, _, _ in ("blob", "wrapped") },
			authAuthorizationProvider: { _, _ in authorization.current },
			authAuthorityValidator: { authorization.isCurrent($0) }
		)
		store.projects = [VaultProject(
			id: "account-a-project",
			name: "Account A",
			path: "",
			environments: ["default": ["TOKEN": "account-a-secret"]]
		)]
		store.isUnlocked = true
		store.selectProject("account-a-project")
		await store.loadTokens()
		let stalePersonal = store.personalTokens[0]
		let staleOrganization = store.orgTokens["acme"]![0]

		authorization.replace(
			token: "account-b",
			generation: round4AuthorityGeneration(seed: 2)
		)
		await store.pushToCloud()
		await store.revokePersonalToken(stalePersonal)
		await store.revokeOrgToken(staleOrganization, orgSlug: "acme")

		#expect(sync.pushCallCount == 0)
		#expect(api.revokedTokenIds.isEmpty)
		#expect(store.currentUser == nil)
		#expect(store.personalTokens.isEmpty)
		#expect(store.orgTokens.isEmpty)
		#expect(store.selectedAccount == .personal)
	}

	@Test("direct import clears identity after a preexisting peer account rotation")
	@MainActor
	func directImportClearsPreexistingPeerRotation() async {
		let authorization = Round4MutableAuthorization(
			token: "account-a",
			generation: round4AuthorityGeneration(seed: 1)
		)
		let importService = Round4ImmediateImportService()
		let api = MockAPIService()
		api.user = round4User(orgSlug: "acme")
		let store = VaultStore(
			keychainService: MockKeychainService(),
			biometricService: MockBiometricService(),
			apiService: api,
			importServiceFactory: { _ in importService },
			authAuthorizationProvider: { _, _ in authorization.current },
			authAuthorityValidator: { authorization.isCurrent($0) }
		)
		await store.loadAccount()
		authorization.replace(
			token: "account-b",
			generation: round4AuthorityGeneration(seed: 2)
		)

		let result = await store.importCloudProject(round4RemoteProject())

		#expect(result == .failure(.cancelled))
		#expect(importService.callCount == 0)
		#expect(store.currentUser == nil)
		#expect(store.selectedAccount == .personal)
	}

	@Test("a committed import remains visible after a peer authority change")
	@MainActor
	func committedImportPublishesAfterAuthorityChange() async {
		let authorization = Round4MutableAuthorization(
			token: "account-a",
			generation: round4AuthorityGeneration(seed: 1)
		)
		let keychain = MockKeychainService()
		let api = MockAPIService()
		api.user = round4User(orgSlug: "acme")
		let store = VaultStore(
			keychainService: keychain,
			biometricService: MockBiometricService(),
			apiService: api,
			importServiceFactory: { _ in Round4ImmediateImportService() },
			authAuthorizationProvider: { _, _ in authorization.current },
			authAuthorityValidator: { authorization.isCurrent($0) },
			authorizedImportCommitter: { _, operation in
				let result = await operation()
				authorization.replace(
					token: "account-b",
					generation: round4AuthorityGeneration(seed: 2)
				)
				return result
			}
		)
		await store.loadAccount()

		let result = await store.importCloudProject(round4RemoteProject())

		guard case .success = result else {
			Issue.record("The durable import did not report success.")
			return
		}
		#expect(keychain.envStorage["remote"] != nil)
		#expect(store.projects.contains { $0.id == "remote" })
		#expect(store.syncMetadata["remote"]?.lastVersion == 1)
		#expect(store.currentUser == nil)
		#expect(store.error?.contains("session changed") == true)
	}

	@Test("logout invalidation wins before an import enters its commit operation")
	@MainActor
	func logoutPreventsWaitingImportCommit() async {
		let gate = Round4AsyncGate()
		let authorization = Round4MutableAuthorization(
			token: "account-a",
			generation: round4AuthorityGeneration(seed: 1)
		)
		let keychain = MockKeychainService()
		let api = MockAPIService()
		api.user = round4User(orgSlug: "acme")
		let store = VaultStore(
			keychainService: keychain,
			biometricService: MockBiometricService(),
			apiService: api,
			importServiceFactory: { _ in Round4ImmediateImportService() },
			authAuthorizationProvider: { _, _ in authorization.current },
			authAuthorityValidator: { authorization.isCurrent($0) },
			authorizedImportCommitter: { _, operation in
				await gate.arriveAndWait()
				return await operation()
			},
			authSessionClearer: { _ in }
		)
		await store.loadAccount()
		let operation = Task {
			await store.importCloudProject(round4RemoteProject())
		}
		await gate.waitUntilArrived()
		await store.logout()
		await gate.release()

		#expect(await operation.value == .failure(.cancelled))
		#expect(keychain.envStorage["remote"] == nil)
	}

	@Test("an account switch cancels a cloud import before its durable commit")
	@MainActor
	func accountSwitchPreventsWaitingImportCommit() async {
		let gate = Round4AsyncGate()
		let authority = round4AuthorityGeneration(seed: 3)
		let keychain = MockKeychainService()
		let api = MockAPIService()
		api.user = round4User(orgSlug: "acme")
		let store = VaultStore(
			keychainService: keychain,
			biometricService: MockBiometricService(),
			apiService: api,
			importServiceFactory: { _ in Round4ImmediateImportService() },
			authAuthorizationProvider: { _, _ in
				AuthSessionAuthorization(token: "account-a", authorityGeneration: authority)
			},
			authAuthorityValidator: { $0 == authority },
			authorizedImportCommitter: { _, operation in
				await gate.arriveAndWait()
				return await operation()
			}
		)
		await store.loadAccount()

		let operation = Task { await store.importCloudProject(round4RemoteProject()) }
		await gate.waitUntilArrived()
		store.selectAccount(.org("acme"))
		await gate.release()

		#expect(await operation.value == .failure(.cancelled))
		#expect(keychain.envStorage["remote"] == nil)
	}

	@Test("task cancellation stops a cloud import before its durable commit")
	@MainActor
	func cancellationPreventsWaitingImportCommit() async {
		let gate = Round4AsyncGate()
		let authority = round4AuthorityGeneration(seed: 4)
		let keychain = MockKeychainService()
		let api = MockAPIService()
		api.user = round4User(orgSlug: "acme")
		let store = VaultStore(
			keychainService: keychain,
			biometricService: MockBiometricService(),
			apiService: api,
			importServiceFactory: { _ in Round4ImmediateImportService() },
			authAuthorizationProvider: { _, _ in
				AuthSessionAuthorization(token: "account-a", authorityGeneration: authority)
			},
			authAuthorityValidator: { $0 == authority },
			authorizedImportCommitter: { _, operation in
				await gate.arriveAndWait()
				return await operation()
			}
		)
		await store.loadAccount()

		let operation = Task { await store.importCloudProject(round4RemoteProject()) }
		await gate.waitUntilArrived()
		operation.cancel()
		await gate.release()

		#expect(await operation.value == .failure(.cancelled))
		#expect(keychain.envStorage["remote"] == nil)
	}

	@Test("unauthorized identity response clears organization routing")
	@MainActor
	func unauthorizedIdentityClearsOrganizationRouting() async {
		let api = MockAPIService()
		let store = VaultStore(
			keychainService: MockKeychainService(),
			biometricService: MockBiometricService(),
			apiService: api,
			authTokenProvider: { _, _ in "expired-session" }
		)
		store.currentUser = round4User(orgSlug: "acme")
		store.projects = [VaultProject(
			id: "organization-project",
			name: "Organization",
			path: "",
			environments: ["default": ["TOKEN": "secret"]]
		)]
		store.vaultOrgAssociations = ["organization-project": "acme"]
		store.isUnlocked = true
		store.selectAccount(.org("acme"))
		store.selectProject("organization-project")
		store.lastSyncStatus = "Pulled from acme"

		await store.loadAccount()

		#expect(store.currentUser == nil)
		#expect(store.selectedAccount == .personal)
		#expect(store.selectedProjectId == nil)
		#expect(store.lastSyncStatus == nil)
	}

	@Test("organization pull serializes authority rotation with its durable commit")
	@MainActor
	func organizationPullCommitIsAuthorityBound() async throws {
		let slug = "acme"
		let projectID = "organization-project"
		let keypair = VaultCrypto.generateX25519Keypair()
		let contentKey = VaultCrypto.generateAESKey()
		let payload = try JSONEncoder().encode([
			"environments": ["default": ["TOKEN": "cloud"]]
		])
		let encrypted = try VaultCrypto.encryptPayload(
			key: contentKey,
			plaintext: payload,
			scope: .organization(slug: slug),
			principalId: "organization",
			vaultId: projectID,
			revision: 2
		)
		let wrapped = try VaultCrypto.wrapKeyForRecipient(
			aesKey: contentKey,
			recipientPublicKey: keypair.publicKey
		)
		let sync = MockOrgSyncService()
		sync.publicKeyRecord = SyncService.PublicKeyRecord(
			publicKey: keypair.publicKey.base64EncodedString(),
			publicKeyVersion: 1,
			publicKeyFingerprint: VaultCrypto.publicKeyFingerprint(keypair.publicKey)
		)
		sync.pullResult = round4SyncStatus(
			vaultId: projectID,
			version: 2,
			contentKeyVersion: 1,
			recipientPublicKeyVersion: 1,
			recipientPublicKeyFingerprint: VaultCrypto.publicKeyFingerprint(keypair.publicKey),
			encryptedBlob: encrypted,
			wrappedKey: wrapped
		)
		let authorization = Round4MutableAuthorization(
			token: "account-a",
			generation: round4AuthorityGeneration(seed: 1)
		)
		let serialiser = Round4AuthorizedPullSerialiser(authorization: authorization)
		let api = MockAPIService()
		api.user = round4User(orgSlug: slug)
		let keychain = MockKeychainService()
		keychain.envStorage[projectID] = (
			name: "Organization",
			path: "",
			environments: ["default": ["TOKEN": "local"]]
		)
		let entered = DispatchSemaphore(value: 0)
		let release = DispatchSemaphore(value: 0)
		keychain.blockNextSaveEnvironments = {
			entered.signal()
			release.wait()
		}
		let store = VaultStore(
			keychainService: keychain,
			biometricService: MockBiometricService(),
			apiService: api,
			orgSyncServiceFactory: { _ in sync },
			sharingKeypairProvider: { keypair },
			authAuthorizationProvider: { _, _ in authorization.current },
			authAuthorityValidator: { authorization.isCurrent($0) },
			authorizedPullCommitter: { generation, operation in
				await serialiser.withCurrent(generation, operation: operation)
			}
		)
		store.projects = [VaultProject(
			id: projectID,
			name: "Organization",
			path: "",
			environments: ["default": ["TOKEN": "local"]]
		)]
		store.vaultOrgAssociations = [projectID: slug]
		store.isUnlocked = true
		await store.loadAccount()
		store.selectAccount(.org(slug))
		store.selectProject(projectID)

		let pull = Task { await store.pullFromOrg(orgSlug: slug) }
		await waitForSemaphore(entered)
		let rotation = Task {
			await serialiser.rotate(
				token: "account-b",
				generation: round4AuthorityGeneration(seed: 2)
			)
		}
		for _ in 0..<100 { await Task.yield() }
		#expect(!serialiser.rotationCompleted)
		release.signal()
		_ = await pull.value
		await rotation.value

		#expect(serialiser.rotationCompleted)
		#expect(keychain.envStorage[projectID]?.environments["default"]?["TOKEN"] == "cloud")
	}

	@Test("cloud discovery reaches a stable signed-out state")
	@MainActor
	func cloudDiscoveryDoesNotLoopAfterDefinitiveAuthorizationLoss() async {
		let absentStore = VaultStore(
			keychainService: MockKeychainService(),
			biometricService: MockBiometricService(),
			apiService: MockAPIService(),
			authAuthorizationProvider: { _, _ in nil }
		)

		_ = await absentStore.listPersonalCloudProjects()
		let generationAfterFirstAttempt = absentStore.authContextGeneration
		_ = await absentStore.listPersonalCloudProjects()

		#expect(absentStore.authContextGeneration == generationAfterFirstAttempt)

		let listing = Round4ProjectListRecorder(result: .failure(.unauthorized))
		let api = MockAPIService()
		api.user = round4User(orgSlug: "acme")
		let unauthorizedStore = VaultStore(
			keychainService: MockKeychainService(),
			biometricService: MockBiometricService(),
			apiService: api,
			projectListServiceFactory: { _ in listing },
			authAuthorizationProvider: { _, _ in
				AuthSessionAuthorization(
					token: "rejected",
					authorityGeneration: round4AuthorityGeneration()
				)
			},
			authAuthorityValidator: { _ in true }
		)
		await unauthorizedStore.loadAccount()

		_ = await unauthorizedStore.listPersonalCloudProjects()
		_ = await unauthorizedStore.listPersonalCloudProjects()

		#expect(listing.callCount == 1)
	}

	@Test("definitive credential loss clears every manual account operation")
	@MainActor
	func manualAccountOperationsClearDefinitiveAuthorizationLoss() async {
		let personalImport = round4SignedInStoreWithMissingAuthority()
		_ = await personalImport.importCloudProject(round4RemoteProject())
		round4ExpectSignedOut(personalImport)

		let organizationImport = round4SignedInStoreWithMissingAuthority()
		_ = await organizationImport.importOrganizationProject(
			round4RemoteProject(),
			orgSlug: "acme"
		)
		round4ExpectSignedOut(organizationImport)

		let personalRevocation = round4SignedInStoreWithMissingAuthority()
		await personalRevocation.revokePersonalToken(round4Token(id: "personal"))
		round4ExpectSignedOut(personalRevocation)

		let organizationRevocation = round4SignedInStoreWithMissingAuthority()
		await organizationRevocation.revokeOrgToken(
			round4Token(id: "organization"),
			orgSlug: "acme"
		)
		round4ExpectSignedOut(organizationRevocation)

		let personalPush = round4SignedInStoreWithMissingAuthority()
		personalPush.vaultOrgAssociations = [:]
		personalPush.selectAccount(.personal)
		personalPush.selectProject("account-project")
		await personalPush.pushToCloud()
		round4ExpectSignedOut(personalPush)

		let personalPull = round4SignedInStoreWithMissingAuthority()
		personalPull.vaultOrgAssociations = [:]
		personalPull.selectAccount(.personal)
		personalPull.selectProject("account-project")
		await personalPull.pullFromCloud()
		round4ExpectSignedOut(personalPull)

		let organizationPush = round4SignedInStoreWithMissingAuthority()
		await organizationPush.pushToOrg(orgSlug: "acme")
		round4ExpectSignedOut(organizationPush)

		let organizationPull = round4SignedInStoreWithMissingAuthority()
		await organizationPull.pullFromOrg(orgSlug: "acme")
		round4ExpectSignedOut(organizationPull)
	}

	@Test("revocation clears identity after rotation or terminal rejection")
	@MainActor
	func revocationPostflightClearsInvalidatedIdentity() async {
		let authorization = Round4MutableAuthorization(
			token: "account-a",
			generation: round4AuthorityGeneration(seed: 1)
		)
		let gate = Round4AsyncGate()
		let api = MockAPIService()
		api.user = round4User(orgSlug: "acme")
		api.personalTokens = [round4Token(id: "personal")]
		api.blockNextPersonalRevoke = { await gate.arriveAndWait() }
		let store = VaultStore(
			keychainService: MockKeychainService(),
			biometricService: MockBiometricService(),
			apiService: api,
			authAuthorizationProvider: { _, _ in authorization.current },
			authAuthorityValidator: { authorization.isCurrent($0) },
			authorizedRemoteMutationExecutor: { _, operation in operation() }
		)
		await store.loadTokens()
		let token = store.personalTokens[0]

		let revocation = Task { await store.revokePersonalToken(token) }
		await gate.waitUntilArrived()
		authorization.replace(
			token: "account-b",
			generation: round4AuthorityGeneration(seed: 2)
		)
		await gate.release()
		await revocation.value

		round4ExpectSignedOut(store)

		let rejectedAPI = MockAPIService()
		rejectedAPI.user = round4User(orgSlug: "acme")
		rejectedAPI.personalTokens = [round4Token(id: "rejected")]
		rejectedAPI.personalRevokeError = .unauthorized
		let rejectedStore = VaultStore(
			keychainService: MockKeychainService(),
			biometricService: MockBiometricService(),
			apiService: rejectedAPI,
			authTokenProvider: { _, _ in "rejected-session" }
		)
		await rejectedStore.loadTokens()

		await rejectedStore.revokePersonalToken(rejectedStore.personalTokens[0])

		round4ExpectSignedOut(rejectedStore)
	}

	@Test("superseded personal pull cannot enter its durable commit")
	@MainActor
	func supersededPersonalPullCannotCommit() async throws {
		let gate = Round4AsyncGate()
		let sync = MockPersonalSyncService()
		sync.pullHandlers = [{
			SyncService.SyncStatus(
				vaultId: "project-a",
				version: 2,
				cryptoVersion: VaultCrypto.currentCryptoVersion,
				contentKeyVersion: nil,
				recipientPublicKeyVersion: nil,
				recipientPublicKeyFingerprint: nil,
				status: "ok",
				error: nil,
				code: nil,
				serverVersion: 2,
				hint: nil,
				encryptedBlob: "remote",
				wrappedKey: "wrapped",
				updatedAt: nil,
				principalId: "account-a"
			)
		}]
		let keychain = MockKeychainService()
		for projectID in ["project-a", "project-b"] {
			keychain.envStorage[projectID] = (
				name: projectID,
				path: "",
				environments: ["default": ["TOKEN": projectID]]
			)
		}
		let generation = round4AuthorityGeneration()
		let api = MockAPIService()
		api.user = round4User(id: "account-a", orgSlug: "acme")
		let store = VaultStore(
			keychainService: keychain,
			biometricService: MockBiometricService(),
			apiService: api,
			personalSyncServiceFactory: { _ in sync },
			stableSyncDecryptor: { _, _, _, _, _, _ in
				try JSONEncoder().encode([
					"environments": ["default": ["TOKEN": "cloud"]]
				])
			},
			authAuthorizationProvider: { _, _ in
				AuthSessionAuthorization(token: "session", authorityGeneration: generation)
			},
			authAuthorityValidator: { $0 == generation },
			authorizedPullCommitter: { _, operation in
				await gate.arriveAndWait()
				return await operation()
			}
		)
		store.projects = ["project-a", "project-b"].map {
			VaultProject(
				id: $0,
				name: $0,
				path: "",
				environments: ["default": ["TOKEN": $0]]
			)
		}
		store.isUnlocked = true
		await store.loadAccount()
		store.selectProject("project-a")

		let pull = Task { await store.pullFromCloud() }
		await gate.waitUntilArrived()
		store.selectProject("project-b")
		await gate.release()
		_ = await pull.value

		#expect(keychain.envStorage["project-a"]?.environments["default"]?["TOKEN"] == "project-a")
		#expect(keychain.dataStorage["__sync_metadata__"] == nil)
	}

	@Test("superseded organization pull cannot enter its durable commit")
	@MainActor
	func supersededOrganizationPullCannotCommit() async throws {
		let slug = "acme"
		let gate = Round4AsyncGate()
		let keypair = VaultCrypto.generateX25519Keypair()
		let contentKey = VaultCrypto.generateAESKey()
		let payload = try JSONEncoder().encode([
			"environments": ["default": ["TOKEN": "cloud"]]
		])
		let encrypted = try VaultCrypto.encryptPayload(
			key: contentKey,
			plaintext: payload,
			scope: .organization(slug: slug),
			principalId: "organization",
			vaultId: "project-a",
			revision: 2
		)
		let wrapped = try VaultCrypto.wrapKeyForRecipient(
			aesKey: contentKey,
			recipientPublicKey: keypair.publicKey
		)
		let sync = MockOrgSyncService()
		sync.publicKeyRecord = SyncService.PublicKeyRecord(
			publicKey: keypair.publicKey.base64EncodedString(),
			publicKeyVersion: 1,
			publicKeyFingerprint: VaultCrypto.publicKeyFingerprint(keypair.publicKey)
		)
		sync.pullResult = round4SyncStatus(
			vaultId: "project-a",
			version: 2,
			contentKeyVersion: 1,
			recipientPublicKeyVersion: 1,
			recipientPublicKeyFingerprint: VaultCrypto.publicKeyFingerprint(keypair.publicKey),
			encryptedBlob: encrypted,
			wrappedKey: wrapped
		)
		let keychain = MockKeychainService()
		for projectID in ["project-a", "project-b"] {
			keychain.envStorage[projectID] = (
				name: projectID,
				path: "",
				environments: ["default": ["TOKEN": projectID]]
			)
		}
		let generation = round4AuthorityGeneration()
		let api = MockAPIService()
		api.user = round4User(orgSlug: slug)
		let store = VaultStore(
			keychainService: keychain,
			biometricService: MockBiometricService(),
			apiService: api,
			orgSyncServiceFactory: { _ in sync },
			sharingKeypairProvider: { keypair },
			authAuthorizationProvider: { _, _ in
				AuthSessionAuthorization(token: "session", authorityGeneration: generation)
			},
			authAuthorityValidator: { $0 == generation },
			authorizedPullCommitter: { _, operation in
				await gate.arriveAndWait()
				return await operation()
			}
		)
		store.projects = ["project-a", "project-b"].map {
			VaultProject(
				id: $0,
				name: $0,
				path: "",
				environments: ["default": ["TOKEN": $0]]
			)
		}
		store.vaultOrgAssociations = ["project-a": slug, "project-b": slug]
		store.isUnlocked = true
		await store.loadAccount()
		store.selectAccount(.org(slug))
		store.selectProject("project-a")

		let pull = Task { await store.pullFromOrg(orgSlug: slug) }
		await gate.waitUntilArrived()
		store.selectProject("project-b")
		await gate.release()
		await pull.value

		#expect(keychain.envStorage["project-a"]?.environments["default"]?["TOKEN"] == "project-a")
		#expect(keychain.dataStorage["__sync_metadata__"] == nil)
	}

	@Test("non-force personal pushes use the durable checkpoint without a preflight")
	@MainActor
	func nonForcePersonalPushSkipsVersionPreflight() async throws {
		for localVersion in [Int?.none, Int?.some(7)] {
			let projectID = "non-force-\(localVersion ?? 0)"
			let sync = MockPersonalSyncService()
			sync.pushHandlers = [{
				SyncService.SyncStatus(
					vaultId: projectID,
					version: (localVersion ?? 0) + 1,
					cryptoVersion: VaultCrypto.currentCryptoVersion,
					contentKeyVersion: nil,
					recipientPublicKeyVersion: nil,
					recipientPublicKeyFingerprint: nil,
					status: "ok",
					error: nil,
					code: nil,
					serverVersion: (localVersion ?? 0) + 1,
					hint: nil,
					encryptedBlob: nil,
					wrappedKey: nil,
					updatedAt: nil,
					principalId: "account-a"
				)
			}]
			let keychain = MockKeychainService()
			keychain.envStorage[projectID] = (
				name: "Personal",
				path: "",
				environments: ["default": ["TOKEN": "local"]]
			)
			var metadata: SyncMetadata?
			if let localVersion {
				metadata = SyncMetadata(
					lastSyncedAt: Date(timeIntervalSince1970: 1),
					lastAction: "pull",
					lastVersion: localVersion,
					isDirty: true,
					binding: SyncPrincipalBinding(
						registryURL: "https://lpm.dev",
						principalID: "account-a",
						scope: "personal"
					)
				)
				let persistedMetadata = try #require(metadata)
				#expect(keychain.seedSyncMetadata([projectID: persistedMetadata]))
			}
			let store = VaultStore(
				keychainService: keychain,
				biometricService: MockBiometricService(),
				apiService: MockAPIService(),
				personalSyncServiceFactory: { _ in sync },
				stableSyncEncryptor: { _, _, _, revision in
					("ciphertext-\(revision)", "wrapped-\(revision)")
				},
				authTokenProvider: { _, _ in "session" }
			)
			store.appEnvironment = .production
			store.currentUser = round4User(id: "account-a", orgSlug: "acme")
			store.projects = [VaultProject(
				id: projectID,
				name: "Personal",
				path: "",
				environments: ["default": ["TOKEN": "local"]]
			)]
			if let metadata { store.syncMetadata = [projectID: metadata] }
			store.isUnlocked = true
			store.selectProject(projectID)
			let binding = SyncPrincipalBinding(
				registryURL: "https://lpm.dev",
				principalID: "account-a",
				scope: "personal"
			)
			let durableSnapshot = await VaultPersistenceCoordinator(service: keychain)
				.syncSnapshot(vaultId: projectID, binding: binding)
			#expect(durableSnapshot?.metadata?.version(boundTo: binding) == localVersion)

			await store.pushToCloud()

			#expect(sync.versionPreflightCallCount == 0)
			#expect(sync.pushCallCount == 1)
			#expect(sync.pushedExpectedVersions == [localVersion])
		}
	}

	@Test("organization push validates its device key from the member inventory")
	@MainActor
	func organizationPushUsesOneKeyInventoryRequest() async {
		let slug = "acme"
		let projectID = "organization-inventory"
		let keypair = VaultCrypto.generateX25519Keypair()
		let fingerprint = VaultCrypto.publicKeyFingerprint(keypair.publicKey)
		let sync = MockOrgSyncService()
		sync.publicKeyRecord = SyncService.PublicKeyRecord(
			publicKey: keypair.publicKey.base64EncodedString(),
			publicKeyVersion: 1,
			publicKeyFingerprint: fingerprint
		)
		sync.memberKeyAccess = SyncService.MemberKeyAccess(
			organizationID: round4OrganizationID,
			callerUserID: "account-a",
			members: [SyncService.MemberPublicKey(
				userId: "account-a",
				role: "admin",
				publicKey: keypair.publicKey.base64EncodedString(),
				publicKeyVersion: 1,
				publicKeyFingerprint: fingerprint,
				hasPublicKey: true
			)],
			canReplaceWrappedKeys: true
		)
		let keychain = MockKeychainService()
		keychain.envStorage[projectID] = (
			name: "Organization",
			path: "",
			environments: ["default": ["TOKEN": "local"]]
		)
		let store = VaultStore(
			keychainService: keychain,
			biometricService: MockBiometricService(),
			apiService: MockAPIService(),
			orgSyncServiceFactory: { _ in sync },
			sharingKeypairProvider: { keypair },
			authTokenProvider: { _, _ in "session" }
		)
		store.currentUser = round4User(
			orgSlug: slug,
			organizationID: round4OrganizationID
		)
		store.projects = [VaultProject(
			id: projectID,
			name: "Organization",
			path: "",
			environments: ["default": ["TOKEN": "local"]]
		)]
		store.vaultOrgAssociations = [projectID: slug]
		store.isUnlocked = true
		store.selectAccount(.org(slug))
		store.selectProject(projectID)

		await store.pushToOrg(orgSlug: slug)

		#expect(sync.memberKeyAccessCallCount == 1)
		#expect(sync.publicKeyCallCount == 0)
	}

	@Test(
		"organization push rejects invalid current-member key bindings",
		arguments: [
			"caller mismatch",
			"missing current member",
			"duplicate current member",
			"null key fields",
			"local key mismatch",
			"invalid key version",
			"fingerprint mismatch",
		]
	)
	@MainActor
	func organizationPushRejectsInvalidCurrentMemberBinding(scenario: String) async {
		let slug = "acme"
		let projectID = "organization-current-member-\(scenario)"
		let localKeypair = VaultCrypto.generateX25519Keypair()
		let otherKeypair = VaultCrypto.generateX25519Keypair()
		let localKey = localKeypair.publicKey.base64EncodedString()
		let localFingerprint = VaultCrypto.publicKeyFingerprint(localKeypair.publicKey)
		let otherKey = otherKeypair.publicKey.base64EncodedString()
		let otherFingerprint = VaultCrypto.publicKeyFingerprint(otherKeypair.publicKey)
		let validCurrentMember = SyncService.MemberPublicKey(
			userId: "account-a",
			role: "admin",
			publicKey: localKey,
			publicKeyVersion: 1,
			publicKeyFingerprint: localFingerprint,
			hasPublicKey: true
		)
		let members: [SyncService.MemberPublicKey]
		let callerUserID: String
		let expectedError: String
		switch scenario {
		case "caller mismatch":
			members = [validCurrentMember]
			callerUserID = "other-account"
			expectedError = "The authenticated account changed while organization access was loading."
		case "missing current member":
			members = [SyncService.MemberPublicKey(
				userId: "other-member",
				role: "member",
				publicKey: otherKey,
				publicKeyVersion: 1,
				publicKeyFingerprint: otherFingerprint,
				hasPublicKey: true
			)]
			callerUserID = "account-a"
			expectedError = "Your sharing key is not registered yet. Run `lpm env share --org` once to complete secure step-up registration, then retry."
		case "duplicate current member":
			members = [validCurrentMember, validCurrentMember]
			callerUserID = "account-a"
			expectedError = "The organization member inventory is invalid."
		case "null key fields":
			members = [SyncService.MemberPublicKey(
				userId: "account-a",
				role: "admin",
				publicKey: nil,
				publicKeyVersion: nil,
				publicKeyFingerprint: nil,
				hasPublicKey: true
			)]
			callerUserID = "account-a"
			expectedError = "The organization member key inventory is invalid."
		case "local key mismatch":
			members = [SyncService.MemberPublicKey(
				userId: "account-a",
				role: "admin",
				publicKey: otherKey,
				publicKeyVersion: 1,
				publicKeyFingerprint: otherFingerprint,
				hasPublicKey: true
			)]
			callerUserID = "account-a"
			expectedError = "This device's sharing-key binding differs from the organization member record. Run `lpm env rotate-sharing-key` or restore the matching key before sharing."
		case "invalid key version":
			members = [SyncService.MemberPublicKey(
				userId: "account-a",
				role: "admin",
				publicKey: localKey,
				publicKeyVersion: 0,
				publicKeyFingerprint: localFingerprint,
				hasPublicKey: true
			)]
			callerUserID = "account-a"
			expectedError = "The organization member key inventory is invalid."
		case "fingerprint mismatch":
			members = [SyncService.MemberPublicKey(
				userId: "account-a",
				role: "admin",
				publicKey: localKey,
				publicKeyVersion: 1,
				publicKeyFingerprint: otherFingerprint,
				hasPublicKey: true
			)]
			callerUserID = "account-a"
			expectedError = "The organization member key inventory is invalid."
		default:
			Issue.record("Unknown current-member binding scenario")
			return
		}

		let sync = MockOrgSyncService()
		sync.memberKeyAccess = SyncService.MemberKeyAccess(
			organizationID: round4OrganizationID,
			callerUserID: callerUserID,
			members: members,
			canReplaceWrappedKeys: true
		)
		let keychain = MockKeychainService()
		keychain.envStorage[projectID] = (
			name: "Organization",
			path: "",
			environments: ["default": ["TOKEN": "local"]]
		)
		let store = VaultStore(
			keychainService: keychain,
			biometricService: MockBiometricService(),
			apiService: MockAPIService(),
			orgSyncServiceFactory: { _ in sync },
			sharingKeypairProvider: { localKeypair },
			authTokenProvider: { _, _ in "session" }
		)
		store.appEnvironment = .production
		store.currentUser = round4User(
			orgSlug: slug,
			organizationID: round4OrganizationID
		)
		store.projects = [VaultProject(
			id: projectID,
			name: "Organization",
			path: "",
			environments: ["default": ["TOKEN": "local"]]
		)]
		store.vaultOrgAssociations = [projectID: slug]
		store.isUnlocked = true
		store.selectAccount(.org(slug))
		store.selectProject(projectID)

		await store.pushToOrg(orgSlug: slug)

		#expect(sync.memberKeyAccessCallCount == 1)
		#expect(sync.publicKeyCallCount == 0)
		#expect(sync.pushCallCount == 0)
		#expect(store.pendingOrgPush == nil)
		#expect(store.lastSyncStatus == "failed")
		#expect(store.error == expectedError)
	}

	@Test("organization conflict recovery retries its organization pull without force push")
	@MainActor
	func organizationConflictRecoveryUsesOrganizationSync() async {
		let slug = "acme"
		let projectID = "organization-conflict"
		let keypair = VaultCrypto.generateX25519Keypair()
		let organizationSync = MockOrgSyncService()
		organizationSync.publicKeyRecord = SyncService.PublicKeyRecord(
			publicKey: keypair.publicKey.base64EncodedString(),
			publicKeyVersion: 1,
			publicKeyFingerprint: VaultCrypto.publicKeyFingerprint(keypair.publicKey)
		)
		let personalSync = MockPersonalSyncService()
		let keychain = MockKeychainService()
		keychain.envStorage[projectID] = (
			name: "Organization",
			path: "",
			environments: ["default": ["TOKEN": "local"]]
		)
		let store = VaultStore(
			keychainService: keychain,
			biometricService: MockBiometricService(),
			apiService: MockAPIService(),
			orgSyncServiceFactory: { _ in organizationSync },
			personalSyncServiceFactory: { _ in personalSync },
			sharingKeypairProvider: { keypair },
			authTokenProvider: { _, _ in "session" }
		)
		store.currentUser = round4User(orgSlug: slug)
		store.projects = [VaultProject(
			id: projectID,
			name: "Organization",
			path: "",
			environments: ["default": ["TOKEN": "local"]]
		)]
		store.vaultOrgAssociations = [projectID: slug]
		store.isUnlocked = true
		store.selectAccount(.org(slug))
		store.selectProject(projectID)
		let target = VaultSyncTarget(projectId: projectID, account: .org(slug))

		await store.recoverFromConflict(.pullAndMerge, target: target)

		#expect(organizationSync.pullCallCount == 1)
		#expect(personalSync.pullCallCount == 0)
		#expect(!VaultConflictRecoveryPolicy.allowsForcePush(for: target.account))
	}

	@Test("personal conflict recovery does not push after a failed pull")
	@MainActor
	func personalConflictRecoveryStopsAfterFailedPull() async {
		let projectID = "failed-pull-recovery"
		let sync = MockPersonalSyncService()
		sync.pullHandlers = [{ nil }]
		let keychain = MockKeychainService()
		keychain.envStorage[projectID] = (
			name: "Personal",
			path: "",
			environments: ["default": ["TOKEN": "local"]]
		)
		let store = VaultStore(
			keychainService: keychain,
			biometricService: MockBiometricService(),
			apiService: MockAPIService(),
			personalSyncServiceFactory: { _ in sync },
			stableSyncEncryptor: { _, _, _, _ in ("ciphertext", "wrapped") },
			authTokenProvider: { _, _ in "session-token" }
		)
		store.projects = [VaultProject(
			id: projectID,
			name: "Personal",
			path: "",
			environments: ["default": ["TOKEN": "local"]]
		)]
		store.currentUser = round4User(id: "account-a", orgSlug: "acme")
		store.isUnlocked = true
		store.selectProject(projectID)

		await store.recoverFromConflict(
			.pullAndMerge,
			target: VaultSyncTarget(projectId: projectID, account: .personal)
		)

		#expect(sync.pullCallCount == 1)
		#expect(sync.pushCallCount == 0)
	}

	@Test("personal conflict recovery pushes after a durable pull")
	@MainActor
	func personalConflictRecoveryPushesAfterDurablePull() async {
		let projectID = "successful-pull-recovery"
		let sync = MockPersonalSyncService()
		sync.pullHandlers = [{
			SyncService.SyncStatus(
				vaultId: projectID,
				version: 2,
				cryptoVersion: VaultCrypto.currentCryptoVersion,
				contentKeyVersion: nil,
				recipientPublicKeyVersion: nil,
				recipientPublicKeyFingerprint: nil,
				status: "ok",
				error: nil,
				code: nil,
				serverVersion: 2,
				hint: nil,
				encryptedBlob: "ciphertext",
				wrappedKey: "wrapped",
				updatedAt: nil,
				principalId: "account-a"
			)
		}]
		sync.pushHandlers = [{
			SyncService.SyncStatus(
				vaultId: projectID,
				version: 3,
				cryptoVersion: VaultCrypto.currentCryptoVersion,
				contentKeyVersion: nil,
				recipientPublicKeyVersion: nil,
				recipientPublicKeyFingerprint: nil,
				status: "ok",
				error: nil,
				code: nil,
				serverVersion: 3,
				hint: nil,
				encryptedBlob: nil,
				wrappedKey: nil,
				updatedAt: nil,
				principalId: "account-a"
			)
		}]
		let keychain = MockKeychainService()
		keychain.envStorage[projectID] = (
			name: "Personal",
			path: "",
			environments: ["default": ["TOKEN": "local"]]
		)
		let store = VaultStore(
			keychainService: keychain,
			biometricService: MockBiometricService(),
			apiService: MockAPIService(),
			personalSyncServiceFactory: { _ in sync },
			stableSyncEncryptor: { _, _, _, revision in
				("ciphertext-\(revision)", "wrapped-\(revision)")
			},
			stableSyncDecryptor: { _, _, _, _, _, _ in
				Data(#"{"environments":{"default":{"TOKEN":"cloud"}}}"#.utf8)
			},
			authTokenProvider: { _, _ in "session-token" }
		)
		store.projects = [VaultProject(
			id: projectID,
			name: "Personal",
			path: "",
			environments: ["default": ["TOKEN": "local"]]
		)]
		store.currentUser = round4User(id: "account-a", orgSlug: "acme")
		store.isUnlocked = true
		store.selectProject(projectID)

		await store.recoverFromConflict(
			.pullAndMerge,
			target: VaultSyncTarget(projectId: projectID, account: .personal)
		)

		#expect(sync.pullCallCount == 1)
		#expect(sync.pushCallCount == 1)
		#expect(store.syncMetadata[projectID]?.lastVersion == 3)
	}

	@Test("login admits only one browser flow at a time")
	@MainActor
	func loginAdmissionIsSingleFlight() async {
		let gate = Round4AsyncGate()
		let providerCalls = Round4Counter()
		let secondStarted = Round4Counter()
		let api = MockAPIService()
		api.user = round4User(id: "account-a", orgSlug: "acme")
		let store = VaultStore(
			keychainService: MockKeychainService(),
			biometricService: MockBiometricService(),
			apiService: api,
			authTokenProvider: { _, _ in "new-access" },
			loginProvider: { _, _ in
				providerCalls.increment()
				await gate.arriveAndWait()
				return round4Credentials()
			},
			authSessionWriter: { _, _ in },
			authSessionClearer: { _ in }
		)

		let first = Task { await store.login() }
		await gate.waitUntilArrived()
		let second = Task {
			secondStarted.increment()
			return await store.login()
		}
		await waitUntil { secondStarted.value == 1 }

		#expect(providerCalls.value == 1)
		await gate.release()
		#expect(await first.value)
		#expect(!(await second.value))
		#expect(!store.isLoggingIn)
	}

	@Test("failed login ownership is released for retry")
	@MainActor
	func failedLoginReleasesAdmissionForRetry() async {
		let gate = Round4AsyncGate()
		let providerCalls = Round4Counter()
		let secondStarted = Round4Counter()
		let api = MockAPIService()
		api.user = round4User(id: "account-a", orgSlug: "acme")
		let store = VaultStore(
			keychainService: MockKeychainService(),
			biometricService: MockBiometricService(),
			apiService: api,
			authTokenProvider: { _, _ in "new-access" },
			loginProvider: { _, _ in
				providerCalls.increment()
				if providerCalls.value == 1 {
					await gate.arriveAndWait()
					throw Round5TestError.failed
				}
				return round4Credentials()
			},
			authSessionWriter: { _, _ in },
			authSessionClearer: { _ in }
		)

		let first = Task { await store.login() }
		await gate.waitUntilArrived()
		let second = Task {
			secondStarted.increment()
			return await store.login()
		}
		await waitUntil { secondStarted.value == 1 }

		#expect(providerCalls.value == 1)
		await gate.release()
		#expect(!(await first.value))
		#expect(!(await second.value))
		#expect(!store.isLoggingIn)
		#expect(await store.login())
		#expect(providerCalls.value == 2)
	}

	@Test("stale biometric completion cannot clear a newer unlock")
	@MainActor
	func staleBiometricCompletionKeepsCurrentUnlockOwned() async {
		let firstGate = Round4AsyncGate()
		let secondGate = Round4AsyncGate()
		let biometric = MockBiometricService()
		biometric.authenticateHandlers = [
			{
				await firstGate.arriveAndWait()
				return false
			},
			{
				await secondGate.arriveAndWait()
				return true
			},
		]
		let store = VaultStore(
			keychainService: MockKeychainService(),
			biometricService: biometric,
			apiService: MockAPIService()
		)

		let first = Task { await store.unlock() }
		await firstGate.waitUntilArrived()
		store.lock()
		let second = Task { await store.unlock() }
		await secondGate.waitUntilArrived()
		await firstGate.release()
		await first.value

		#expect(store.isUnlocking)
		await secondGate.release()
		await second.value
		#expect(store.isUnlocked)
		#expect(biometric.authenticateCallCount == 2)
	}

	@Test("stale project load cannot clear a newer unlock")
	@MainActor
	func staleProjectLoadCompletionKeepsCurrentUnlockOwned() async {
		let listEntered = DispatchSemaphore(value: 0)
		let listRelease = DispatchSemaphore(value: 0)
		let secondGate = Round4AsyncGate()
		let biometric = MockBiometricService()
		biometric.authenticateHandlers = [
			{ true },
			{
				await secondGate.arriveAndWait()
				return true
			},
		]
		let keychain = MockKeychainService()
		keychain.blockNextListProjectMetadata = {
			listEntered.signal()
			listRelease.wait()
		}
		let store = VaultStore(
			keychainService: keychain,
			biometricService: biometric,
			apiService: MockAPIService()
		)

		let first = Task { await store.unlock() }
		await waitForSemaphore(listEntered)
		store.lock()
		let second = Task { await store.unlock() }
		await secondGate.waitUntilArrived()
		listRelease.signal()
		await first.value

		#expect(store.isUnlocking)
		await secondGate.release()
		await second.value
		#expect(store.isUnlocked)
		#expect(biometric.authenticateCallCount == 2)
	}

	@Test("unlock waits for every admitted pre-lock project mutation")
	@MainActor
	func unlockIncludesQueuedPreLockProjectMutations() async {
		let projectID = "queued-pre-lock-mutations"
		let firstMutationEntered = DispatchSemaphore(value: 0)
		let firstMutationRelease = DispatchSemaphore(value: 0)
		let keychain = MockKeychainService()
		keychain.envStorage[projectID] = (
			name: "Project",
			path: "",
			environments: [
				"default": [
					"FIRST": "old-first",
					"SECOND": "old-second",
				]
			]
		)
		keychain.blockNextSaveEnvironments = {
			firstMutationEntered.signal()
			firstMutationRelease.wait()
		}
		let store = VaultStore(
			keychainService: keychain,
			biometricService: MockBiometricService(),
			apiService: MockAPIService()
		)
		store.projects = [VaultProject(
			id: projectID,
			name: "Project",
			path: "",
			environments: keychain.envStorage[projectID]!.environments
		)]
		store.isUnlocked = true
		store.selectProject(projectID)

		store.updateSecret(
			in: projectID,
			environment: "default",
			key: "FIRST",
			newValue: "new-first"
		)
		await waitForSemaphore(firstMutationEntered)
		store.updateSecret(
			in: projectID,
			environment: "default",
			key: "SECOND",
			newValue: "new-second"
		)
		store.lock()
		let unlock = Task { await store.unlock() }
		await waitUntil { store.isUnlocking }
		firstMutationRelease.signal()
		await unlock.value
		await waitUntil {
			keychain.envStorage[projectID]?.environments["default"]?["SECOND"]
				== "new-second"
		}
		await waitUntil {
			store.projects.first?.environments
				== keychain.envStorage[projectID]?.environments
		}

		#expect(store.isUnlocked)
		#expect(
			store.projects.first?.environments
				== keychain.envStorage[projectID]?.environments
		)
	}

	@Test("remote mutation cannot start after authority invalidation")
	@MainActor
	func remoteMutationDispatchIsAuthorityBound() async {
		let validator = Round4InvalidatingAuthorityValidator()
		let api = MockAPIService()
		api.user = round4User(orgSlug: "acme")
		api.personalTokens = [round4Token(id: "personal")]
		let store = VaultStore(
			keychainService: MockKeychainService(),
			biometricService: MockBiometricService(),
			apiService: api,
			authAuthorizationProvider: { _, _ in
				AuthSessionAuthorization(
					token: "account-a",
					authorityGeneration: round4AuthorityGeneration()
				)
			},
			authAuthorityValidator: { validator.validate($0) },
			authorizedRemoteMutationExecutor: { generation, operation in
				guard validator.isCurrent(generation) else { return nil }
				return operation()
			}
		)
		await store.loadTokens()
		validator.invalidateAfterNextSuccessfulCheck()

		await store.revokePersonalToken(store.personalTokens[0])

		#expect(api.revokedTokenIds.isEmpty)
	}

	@Test("superseded revocation executor failures do not overwrite the current context")
	@MainActor
	func supersededRevocationExecutorFailuresStaySilent() async {
		for organizationSlug in [nil, "acme"] as [String?] {
			let authority = round4AuthorityGeneration(seed: organizationSlug == nil ? 101 : 102)
			let gate = Round4AsyncGate()
			let api = MockAPIService()
			api.user = round4User(orgSlug: "acme")
			let token = round4Token(id: organizationSlug == nil ? "personal" : "organization")
			let store = VaultStore(
				keychainService: MockKeychainService(),
				biometricService: MockBiometricService(),
				apiService: api,
				authAuthorizationProvider: { _, _ in
					AuthSessionAuthorization(
						token: "account-a",
						authorityGeneration: authority
					)
				},
				authAuthorityValidator: { $0 == authority },
				authorizedRemoteMutationExecutor: { _, _ in
					await gate.arriveAndWait()
					throw Round5TestError.failed
				},
				authSessionClearer: { _ in }
			)
			await store.loadAccount()
			let revocation = Task {
				if let organizationSlug {
					await store.revokeOrgToken(token, orgSlug: organizationSlug)
				} else {
					await store.revokePersonalToken(token)
				}
			}
			await gate.waitUntilArrived()
			await store.logout()
			await gate.release()
			await revocation.value

			#expect(store.currentUser == nil)
			#expect(store.selectedAccount == .personal)
			#expect(store.error == nil)
			#expect(api.revokedTokenIds.isEmpty)
		}
	}

	@Test("durable organization pull remains visible after authority rotation")
	@MainActor
	func committedPullPublishesAfterAuthorityChange() async throws {
		let slug = "acme"
		let projectID = "post-commit-pull"
		let keypair = VaultCrypto.generateX25519Keypair()
		let contentKey = VaultCrypto.generateAESKey()
		let payload = try JSONEncoder().encode([
			"environments": ["default": ["TOKEN": "cloud"]]
		])
		let encrypted = try VaultCrypto.encryptPayload(
			key: contentKey,
			plaintext: payload,
			scope: .organization(slug: slug),
			principalId: "organization",
			vaultId: projectID,
			revision: 2
		)
		let wrapped = try VaultCrypto.wrapKeyForRecipient(
			aesKey: contentKey,
			recipientPublicKey: keypair.publicKey
		)
		let sync = MockOrgSyncService()
		sync.publicKeyRecord = SyncService.PublicKeyRecord(
			publicKey: keypair.publicKey.base64EncodedString(),
			publicKeyVersion: 1,
			publicKeyFingerprint: VaultCrypto.publicKeyFingerprint(keypair.publicKey)
		)
		sync.pullResult = round4SyncStatus(
			vaultId: projectID,
			version: 2,
			contentKeyVersion: 1,
			recipientPublicKeyVersion: 1,
			recipientPublicKeyFingerprint: VaultCrypto.publicKeyFingerprint(keypair.publicKey),
			encryptedBlob: encrypted,
			wrappedKey: wrapped
		)
		let authorization = Round4MutableAuthorization(
			token: "account-a",
			generation: round4AuthorityGeneration(seed: 1)
		)
		let api = MockAPIService()
		api.user = round4User(orgSlug: slug)
		let keychain = MockKeychainService()
		keychain.envStorage[projectID] = (
			name: "Organization",
			path: "",
			environments: ["default": ["TOKEN": "local"]]
		)
		let store = VaultStore(
			keychainService: keychain,
			biometricService: MockBiometricService(),
			apiService: api,
			orgSyncServiceFactory: { _ in sync },
			sharingKeypairProvider: { keypair },
			authAuthorizationProvider: { _, _ in authorization.current },
			authAuthorityValidator: { authorization.isCurrent($0) },
			authorizedPullCommitter: { _, operation in
				let result = await operation()
				authorization.replace(
					token: "account-b",
					generation: round4AuthorityGeneration(seed: 2)
				)
				return result
			}
		)
		store.projects = [VaultProject(
			id: projectID,
			name: "Organization",
			path: "",
			environments: ["default": ["TOKEN": "local"]]
		)]
		store.vaultOrgAssociations = [projectID: slug]
		store.isUnlocked = true
		await store.loadAccount()
		store.selectAccount(.org(slug))
		store.selectProject(projectID)

		await store.pullFromOrg(orgSlug: slug)

		#expect(keychain.envStorage[projectID]?.environments["default"]?["TOKEN"] == "cloud")
		#expect(store.projects[0].environments["default"]?["TOKEN"] == "cloud")
		#expect(store.syncMetadata[projectID]?.lastVersion == 2)
		#expect(store.currentUser == nil)
		#expect(store.error?.contains("session changed") == true)
		#expect(store.lastSyncStatus == nil)
	}

	@Test("dotenv exports use bounded background admission")
	func dotenvExportAdmissionIsBounded() async {
		let tracker = Round4ExportTracker()
		let service = EnvFileExportService { _, destination, _ in
			tracker.enter(index: Int(destination.lastPathComponent) ?? -1)
			defer { tracker.leave() }
			tracker.waitForRelease()
		}
		let tasks = (0..<12).map { index in
			Task {
				try? await service.export(
					secrets: ["TOKEN": "secret"],
					to: URL(fileURLWithPath: "/tmp/\(index)")
				)
			}
		}

		await tracker.waitUntilStarted(2)
		#expect(tracker.maximumActive <= 2)
		tracker.release(12)
		for task in tasks { await task.value }
		#expect(tracker.maximumActive <= 2)
	}

	@Test("cancelled export waiters unlink before the owner releases")
	func cancelledExportWaitersUnlinkImmediately() async throws {
		let admission = EnvFileExportAdmission(limit: 1)
		try await admission.acquire()
		let waiters = (0..<2_048).map { _ in
			Task {
				try await admission.acquire()
				await admission.release()
			}
		}
		await waitUntilAsync { await admission.queuedNodeCount == waiters.count }

		waiters.forEach { $0.cancel() }
		for waiter in waiters {
			await #expect(throws: CancellationError.self) { try await waiter.value }
		}

		#expect(await admission.queuedNodeCount == 0)
		let next = Task {
			try await admission.acquire()
			await admission.release()
		}
		await waitUntilAsync { await admission.queuedNodeCount == 1 }
		await admission.release()
		try await next.value
		#expect(await admission.queuedNodeCount == 0)
	}

	@Test("cancelled process-lock waiters unlink before the owner releases")
	func cancelledProcessLockWaitersUnlinkImmediately() async throws {
		let gate = ProcessExclusiveGate()
		let path = "/tmp/round4-process-gate-\(UUID().uuidString)"
		let owner = UUID()
		try await gate.acquire(
			path: path,
			id: owner,
			cancellation: LockAcquisitionCancellation()
		)
		let ids = (0..<2_048).map { _ in UUID() }
		let waiters = ids.map { id in
			let cancellation = LockAcquisitionCancellation()
			return Task {
				try await withTaskCancellationHandler {
					try await gate.acquire(path: path, id: id, cancellation: cancellation)
				} onCancel: {
					cancellation.cancel()
					Task { await gate.cancel(id: id) }
				}
				await gate.release(path: path, id: id)
			}
		}
		await waitUntilAsync { await gate.queuedNodeCount(path: path) == waiters.count }

		waiters.forEach { $0.cancel() }
		for waiter in waiters {
			await #expect(throws: CancellationError.self) { try await waiter.value }
		}

		#expect(await gate.queuedNodeCount(path: path) == 0)
		let nextID = UUID()
		let next = Task {
			try await gate.acquire(
				path: path,
				id: nextID,
				cancellation: LockAcquisitionCancellation()
			)
			await gate.release(path: path, id: nextID)
		}
		await waitUntilAsync { await gate.queuedNodeCount(path: path) == 1 }
		await gate.release(path: path, id: owner)
		try await next.value
		#expect(await gate.queuedNodeCount(path: path) == 0)
	}

	@Test("cancelling an admitted export prevents its final plaintext write")
	func cancelledDotenvExportDoesNotCommit() async throws {
		let directory = FileManager.default.temporaryDirectory
			.appendingPathComponent("round4-cancelled-export-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: directory) }
		let destination = directory.appendingPathComponent("export.env")
		let entered = DispatchSemaphore(value: 0)
		let release = DispatchSemaphore(value: 0)
		let service = EnvFileExportService { secrets, destination, authorization in
			entered.signal()
			release.wait()
			let content = EnvFileCodec.format(secrets)
			try SecureFileWriter.write(
				Data(content.utf8),
				to: destination,
				authorization: authorization
			)
		}
		let operation = Task {
			try await service.export(secrets: ["TOKEN": "secret"], to: destination)
		}
		await waitForSemaphore(entered)
		operation.cancel()
		release.signal()

		await #expect(throws: CancellationError.self) { try await operation.value }
		#expect(!FileManager.default.fileExists(atPath: destination.path))
	}

	@Test("secure replacement synchronizes the parent directory after rename")
	func secureReplacementSynchronizesParentAfterRename() throws {
		let directory = FileManager.default.temporaryDirectory
			.appendingPathComponent("round4-directory-sync-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: directory) }
		let destination = directory.appendingPathComponent("export.env")
		let payload = Data("TOKEN=secret\n".utf8)
		var synchronizedDirectory: URL?

		try SecureFileWriter.write(
			payload,
			to: destination,
			directorySynchronizer: { parent in
				#expect(FileManager.default.fileExists(atPath: destination.path))
				synchronizedDirectory = parent
				return nil
			}
		)

		#expect(synchronizedDirectory == directory)
		#expect(try Data(contentsOf: destination) == payload)
	}

	@Test("parent directory sync failure reports a committed but indeterminate replacement")
	func directorySyncFailureIsIndeterminate() throws {
		let directory = FileManager.default.temporaryDirectory
			.appendingPathComponent("round4-directory-sync-failure-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: directory) }
		let destination = directory.appendingPathComponent("export.env")
		let payload = Data("TOKEN=secret\n".utf8)

		#expect(throws: SecureFileWriter.WriteError.directorySyncFailed(EIO)) {
			try SecureFileWriter.write(
				payload,
				to: destination,
				directorySynchronizer: { _ in EIO }
			)
		}

		#expect(try Data(contentsOf: destination) == payload)
	}

	@Test("locking the vault cancels an admitted plaintext export")
	@MainActor
	func vaultLockCancelsDotenvExport() async throws {
		let directory = FileManager.default.temporaryDirectory
			.appendingPathComponent("round4-locked-export-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: directory) }
		let destination = directory.appendingPathComponent("export.env")
		let entered = DispatchSemaphore(value: 0)
		let release = DispatchSemaphore(value: 0)
		let service = EnvFileExportService { secrets, destination, authorization in
			entered.signal()
			release.wait()
			try SecureFileWriter.write(
				Data(EnvFileCodec.format(secrets).utf8),
				to: destination,
				authorization: authorization
			)
		}
		let store = VaultStore(
			keychainService: MockKeychainService(),
			biometricService: MockBiometricService(),
			apiService: MockAPIService(),
			envFileExportService: service
		)
		store.projects = [VaultProject(
			id: "project",
			name: "Project",
			path: "",
			environments: ["default": ["TOKEN": "secret"]]
		)]
		store.isUnlocked = true
		store.selectProject("project")

		let operation = Task {
			try await store.exportEnvironment(
				projectId: "project",
				environment: "default",
				to: destination
			)
		}
		await waitForSemaphore(entered)
		store.lock()
		release.signal()

		await #expect(throws: CancellationError.self) { try await operation.value }
		#expect(!FileManager.default.fileExists(atPath: destination.path))
	}

	@Test("programmatic environment changes cancel an admitted plaintext export")
	@MainActor
	func programmaticEnvironmentChangeCancelsDotenvExport() async throws {
		let directory = FileManager.default.temporaryDirectory
			.appendingPathComponent("round4-environment-export-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: directory) }
		let destination = directory.appendingPathComponent("export.env")
		let entered = DispatchSemaphore(value: 0)
		let release = DispatchSemaphore(value: 0)
		let service = EnvFileExportService { secrets, destination, authorization in
			entered.signal()
			release.wait()
			try SecureFileWriter.write(
				Data(EnvFileCodec.format(secrets).utf8),
				to: destination,
				authorization: authorization
			)
		}
		let store = VaultStore(
			keychainService: MockKeychainService(),
			biometricService: MockBiometricService(),
			apiService: MockAPIService(),
			envFileExportService: service
		)
		store.projects = [VaultProject(
			id: "project",
			name: "Project",
			path: "",
			environments: [
				"default": ["TOKEN": "secret"],
				"staging": ["TOKEN": "staging"],
			]
		)]
		store.isUnlocked = true
		store.selectProject("project")

		let operation = Task {
			try await store.exportEnvironment(
				projectId: "project",
				environment: "default",
				to: destination
			)
		}
		await waitForSemaphore(entered)
		store.selectedEnvironment = "staging"
		release.signal()

		await #expect(throws: CancellationError.self) { try await operation.value }
		#expect(!FileManager.default.fileExists(atPath: destination.path))
	}

	@Test("direct project changes cancel an admitted plaintext export")
	@MainActor
	func directProjectChangeCancelsDotenvExport() async throws {
		try await verifyProjectTransitionCancelsExport { store, _ in
			store.selectedProjectId = "project-b"
		}
	}

	@Test("sidebar removal fallback cancels an admitted plaintext export")
	@MainActor
	func sidebarRemovalFallbackCancelsDotenvExport() async throws {
		try await verifyProjectTransitionCancelsExport { store, project in
			store.removeFromSidebar(project)
			await waitUntil { store.selectedProjectId == "project-b" }
		}
	}

	@Test("local vault deletion fallback cancels an admitted plaintext export")
	@MainActor
	func localVaultDeletionFallbackCancelsDotenvExport() async throws {
		try await verifyProjectTransitionCancelsExport { store, project in
			_ = await store.deleteLocalVault(project)
		}
	}

	@MainActor
	private func verifyProjectTransitionCancelsExport(
		_ transition: @MainActor (VaultStore, VaultProject) async -> Void
	) async throws {
		let directory = FileManager.default.temporaryDirectory
			.appendingPathComponent("round4-project-export-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: directory) }
		let destination = directory.appendingPathComponent("export.env")
		let entered = DispatchSemaphore(value: 0)
		let release = DispatchSemaphore(value: 0)
		let service = EnvFileExportService { secrets, destination, authorization in
			entered.signal()
			release.wait()
			try SecureFileWriter.write(
				Data(EnvFileCodec.format(secrets).utf8),
				to: destination,
				authorization: authorization
			)
		}
		let projectA = VaultProject(
			id: "project-a",
			name: "Project A",
			path: "",
			environments: ["default": ["TOKEN": "secret-a"]]
		)
		let projectB = VaultProject(
			id: "project-b",
			name: "Project B",
			path: "",
			environments: ["default": ["TOKEN": "secret-b"]]
		)
		let keychain = MockKeychainService()
		keychain.envStorage[projectA.id] = (
			name: projectA.name,
			path: projectA.path,
			environments: projectA.environments
		)
		keychain.envStorage[projectB.id] = (
			name: projectB.name,
			path: projectB.path,
			environments: projectB.environments
		)
		let store = VaultStore(
			keychainService: keychain,
			biometricService: MockBiometricService(),
			apiService: MockAPIService(),
			envFileExportService: service
		)
		store.projects = [projectA, projectB]
		store.isUnlocked = true
		store.selectProject(projectA.id)

		let operation = Task {
			try await store.exportEnvironment(
				projectId: projectA.id,
				environment: "default",
				to: destination
			)
		}
		await waitForSemaphore(entered)
		await transition(store, projectA)
		release.signal()

		await #expect(throws: CancellationError.self) { try await operation.value }
		#expect(!FileManager.default.fileExists(atPath: destination.path))
	}

	@Test("an older account operation cannot clear a newly logged-in identity")
	@MainActor
	func staleAccountOperationPreservesNewLogin() async {
		let oldAuthority = round4AuthorityGeneration(seed: 1)
		let newAuthority = round4AuthorityGeneration(seed: 2)
		let authorization = Round4MutableAuthorization(
			token: "account-a",
			generation: oldAuthority
		)
		let loginGate = Round4AsyncGate()
		let revocationGate = Round4AsyncGate()
		let api = MockAPIService()
		api.user = round4User(id: "account-a", orgSlug: "acme")
		api.blockNextPersonalRevoke = { await revocationGate.arriveAndWait() }
		api.personalRevokeError = .unauthorized
		let store = VaultStore(
			keychainService: MockKeychainService(),
			biometricService: MockBiometricService(),
			apiService: api,
			authAuthorizationProvider: { _, _ in authorization.current },
			authAuthorityValidator: { authorization.isCurrent($0) },
			authorizedRemoteMutationExecutor: { _, operation in operation() },
			loginProvider: { _, _ in
				await loginGate.arriveAndWait()
				return round4Credentials()
			},
			authSessionWriter: { credentials, _ in
				authorization.replace(
					token: credentials.token,
					generation: newAuthority
				)
			},
			authSessionClearer: { _ in }
		)
		await store.loadAccount()
		store.personalTokens = [round4Token(id: "old-token")]

		let login = Task { await store.login() }
		await loginGate.waitUntilArrived()
		let revocation = Task {
			await store.revokePersonalToken(round4Token(id: "old-token"))
		}
		await revocationGate.waitUntilArrived()
		api.user = round4User(id: "account-b", orgSlug: "acme")
		await loginGate.release()
		#expect(await login.value)
		#expect(store.currentUser?.id == "account-b")

		await revocationGate.release()
		await revocation.value

		#expect(store.currentUser?.id == "account-b")
		#expect(!store.isLoggingIn)
	}

	@Test("superseded sync still clears definitive credential loss")
	@MainActor
	func supersededSyncClearsMissingCredentials() async {
		let authGate = Round4AsyncGate()
		let provider = Round4TokenProvider(token: "account-a")
		let api = MockAPIService()
		api.user = round4User(orgSlug: "acme")
		let store = VaultStore(
			keychainService: MockKeychainService(),
			biometricService: MockBiometricService(),
			apiService: api,
			authTokenProvider: { _, _ in await provider.resolve() }
		)
		store.projects = [
			VaultProject(
				id: "project-a",
				name: "Alpha",
				path: "",
				environments: ["default": ["A": "one"]]
			),
			VaultProject(
				id: "project-b",
				name: "Bravo",
				path: "",
				environments: ["default": ["B": "two"]]
			),
		]
		store.isUnlocked = true
		store.selectProject("project-a")
		await store.loadAccount()
		await provider.set(token: nil, gate: authGate)

		let push = Task { await store.pushToCloud() }
		await authGate.waitUntilArrived()
		store.selectProject("project-b")
		await authGate.release()
		await push.value

		round4ExpectSignedOut(store)
	}

	@Test("terminal rejection cannot be undone by an older identity load")
	@MainActor
	func terminalAuthClearInvalidatesIdentityLoad() async {
		let inventoryGate = Round4AsyncGate()
		let api = MockAPIService()
		api.user = round4User(orgSlug: "acme")
		api.personalTokens = [round4Token(id: "loaded-token")]
		let store = VaultStore(
			keychainService: MockKeychainService(),
			biometricService: MockBiometricService(),
			apiService: api,
			authTokenProvider: { _, _ in "account-a" }
		)
		await store.loadAccount()
		store.personalTokens = [round4Token(id: "revoked-token")]
		api.blockNextPersonalTokenFetch = { await inventoryGate.arriveAndWait() }

		let inventory = Task { await store.loadTokens() }
		await inventoryGate.waitUntilArrived()
		api.personalRevokeError = .unauthorized
		await store.revokePersonalToken(round4Token(id: "revoked-token"))
		round4ExpectSignedOut(store)

		await inventoryGate.release()
		await inventory.value

		round4ExpectSignedOut(store)
	}

	@Test("a stale sync authorization cannot clear a newer login")
	@MainActor
	func staleSyncAuthorizationPreservesNewLogin() async {
		let oldAuthority = round4AuthorityGeneration(seed: 31)
		let newAuthority = round4AuthorityGeneration(seed: 32)
		let authorization = Round5GatedAuthorization(
			token: "account-a",
			generation: oldAuthority
		)
		let gate = Round4AsyncGate()
		let api = MockAPIService()
		api.user = round4User(id: "account-a", orgSlug: "acme")
		let sync = MockPersonalSyncService()
		let keychain = MockKeychainService()
		keychain.envStorage["project"] = (
			name: "Project",
			path: "",
			environments: ["default": ["TOKEN": "local"]]
		)
		let store = VaultStore(
			keychainService: keychain,
			biometricService: MockBiometricService(),
			apiService: api,
			personalSyncServiceFactory: { _ in sync },
			stableSyncEncryptor: { _, _, _, _ in ("blob", "wrapped") },
			authAuthorizationProvider: { _, _ in await authorization.resolve() },
			authAuthorityValidator: { authorization.isCurrent($0) },
			loginProvider: { _, _ in round4Credentials() },
			authSessionWriter: { credentials, _ in
				authorization.replace(
					token: credentials.token,
					generation: newAuthority
				)
			},
			authSessionClearer: { _ in }
		)
		store.projects = [VaultProject(
			id: "project",
			name: "Project",
			path: "",
			environments: ["default": ["TOKEN": "local"]]
		)]
		store.isUnlocked = true
		store.selectProject("project")
		await store.loadAccount()
		authorization.gateNextResolution(on: gate)

		let push = Task { await store.pushToCloud() }
		await gate.waitUntilArrived()
		api.user = round4User(id: "account-b", orgSlug: "acme")
		#expect(await store.login())
		#expect(store.currentUser?.id == "account-b")

		await gate.release()
		await push.value

		#expect(store.currentUser?.id == "account-b")
		#expect(sync.pushCallCount == 0)
	}

	@Test("a stale absent import authorization cannot clear a newer login")
	@MainActor
	func staleAbsentImportAuthorizationPreservesNewLogin() async {
		let oldAuthority = round4AuthorityGeneration(seed: 33)
		let newAuthority = round4AuthorityGeneration(seed: 34)
		let authorization = Round6GatedOptionalAuthorization(
			token: "account-a",
			generation: oldAuthority
		)
		let gate = Round4AsyncGate()
		let api = MockAPIService()
		api.user = round4User(id: "account-a", orgSlug: "acme")
		let importService = Round4ImmediateImportService()
		let store = VaultStore(
			keychainService: MockKeychainService(),
			biometricService: MockBiometricService(),
			apiService: api,
			importServiceFactory: { _ in importService },
			authAuthorizationProvider: { _, _ in await authorization.resolve() },
			authAuthorityValidator: { authorization.isCurrent($0) },
			loginProvider: { _, _ in round4Credentials() },
			authSessionWriter: { credentials, _ in
				authorization.replace(
					token: credentials.token,
					generation: newAuthority
				)
			},
			authSessionClearer: { _ in }
		)
		store.isUnlocked = true
		await store.loadAccount()
		authorization.gateNextResolution(returning: nil, on: gate)

		let importTask = Task { await store.importCloudProject(round4RemoteProject()) }
		await gate.waitUntilArrived()
		api.user = round4User(id: "account-b", orgSlug: "acme")
		#expect(await store.login())
		#expect(store.currentUser?.id == "account-b")

		await gate.release()
		let result = await importTask.value
		guard case .failure(.cancelled) = result else {
			Issue.record("The stale import did not cancel after the account changed.")
			return
		}

		#expect(store.currentUser?.id == "account-b")
		#expect(importService.callCount == 0)
	}

	@Test("login invalidates an older identity load before rotating authorization")
	@MainActor
	func loginInvalidatesOlderIdentityLoad() async {
		let oldAuthority = round4AuthorityGeneration(seed: 35)
		let newAuthority = round4AuthorityGeneration(seed: 36)
		let authorization = Round4MutableAuthorization(
			token: "account-a",
			generation: oldAuthority
		)
		let identityGate = Round4AsyncGate()
		let writerGate = Round4AsyncGate()
		let api = MockAPIService()
		api.user = round4User(id: "account-a", orgSlug: "acme")
		let store = VaultStore(
			keychainService: MockKeychainService(),
			biometricService: MockBiometricService(),
			apiService: api,
			authAuthorizationProvider: { _, _ in authorization.current },
			authAuthorityValidator: { authorization.isCurrent($0) },
			loginProvider: { _, _ in round4Credentials() },
			authSessionWriter: { credentials, _ in
				authorization.replace(
					token: credentials.token,
					generation: newAuthority
				)
				await writerGate.arriveAndWait()
			},
			authSessionClearer: { _ in }
		)
		await store.loadAccount()
		#expect(store.currentUser?.id == "account-a")
		api.blockNextCurrentUserFetch = { await identityGate.arriveAndWait() }

		let identityLoad = Task { await store.loadAccount() }
		await identityGate.waitUntilArrived()
		api.user = round4User(id: "account-b", orgSlug: "acme")
		let login = Task { await store.login() }
		await writerGate.waitUntilArrived()

		await identityGate.release()
		await identityLoad.value
		await writerGate.release()

		#expect(await login.value)
		#expect(store.currentUser?.id == "account-b")
	}

	@Test("durable sync metadata never regresses to an older pushed version")
	func olderPushCannotRegressDurableVersion() async throws {
		let keychain = MockKeychainService()
		let binding = SyncPrincipalBinding(
			registryURL: "https://lpm.dev",
			principalID: "user-1",
			scope: "personal"
		)
		let project = VaultProject(
			id: "versioned",
			name: "Versioned",
			path: "",
			environments: ["default": ["TOKEN": "local"]]
		)
		keychain.envStorage[project.id] = (
			name: project.name,
			path: project.path,
			environments: project.environments
		)
		#expect(keychain.seedSyncMetadata([
			project.id: SyncMetadata(
				lastSyncedAt: Date(),
				lastAction: "pull",
				lastVersion: 5,
				isDirty: false,
				binding: binding
			)
		]))
		let coordinator = VaultPersistenceCoordinator(service: keychain)

		let commit = await coordinator.finishPush(
			pushedProject: project,
			action: "push",
			version: 4,
			binding: binding
		)

		#expect(commit == nil)
		#expect(keychain.storedSyncMetadata(vaultId: project.id)?.lastVersion == 5)
	}

	@Test("an older pull cannot overwrite a newer durable sync")
	func olderPullCannotOverwriteNewerDurableSync() async throws {
		let keychain = MockKeychainService()
		let binding = SyncPrincipalBinding(
			registryURL: "https://lpm.dev",
			principalID: "user-1",
			scope: "personal"
		)
		let project = VaultProject(
			id: "versioned",
			name: "Versioned",
			path: "",
			environments: ["default": ["TOKEN": "newer"]]
		)
		keychain.envStorage[project.id] = (
			name: project.name,
			path: project.path,
			environments: project.environments
		)
		#expect(keychain.seedSyncMetadata([
			project.id: SyncMetadata(
				lastSyncedAt: Date(),
				lastAction: "pull",
				lastVersion: 5,
				isDirty: false,
				binding: binding
			)
		]))
		let coordinator = VaultPersistenceCoordinator(service: keychain)
		let remote = try JSONEncoder().encode([
			"environments": ["default": ["TOKEN": "older"]]
		])

		_ = await coordinator.commitPull(
			baseline: project,
			remotePayload: remote,
			action: "pull",
			version: 4,
			binding: binding
		)

		#expect(keychain.envStorage[project.id]?.environments == project.environments)
		#expect(keychain.storedSyncMetadata(vaultId: project.id)?.lastVersion == 5)
	}

	@Test("a cancelled committed import cannot override newer navigation")
	@MainActor
	func cancelledCommittedImportPreservesNewerNavigation() async {
		let authority = round4AuthorityGeneration(seed: 41)
		let gate = Round4AsyncGate()
		let keychain = MockKeychainService()
		keychain.envStorage["project-b"] = (
			name: "Project B",
			path: "",
			environments: ["default": ["TOKEN": "b"]]
		)
		let api = MockAPIService()
		api.user = round4User(orgSlug: "acme")
		let store = VaultStore(
			keychainService: keychain,
			biometricService: MockBiometricService(),
			apiService: api,
			importServiceFactory: { _ in Round4ImmediateImportService() },
			authAuthorizationProvider: { _, _ in
				AuthSessionAuthorization(token: "account-a", authorityGeneration: authority)
			},
			authAuthorityValidator: { $0 == authority },
			authorizedImportCommitter: { _, operation in
				let result = await operation()
				await gate.arriveAndWait()
				return result
			}
		)
		store.projects = [VaultProject(
			id: "project-b",
			name: "Project B",
			path: "",
			environments: ["default": ["TOKEN": "b"]]
		)]
		store.isUnlocked = true
		store.selectProject("project-b")
		await store.loadAccount()

		let operation = Task { await store.importCloudProject(round4RemoteProject()) }
		await gate.waitUntilArrived()
		#expect(keychain.envStorage["remote"] != nil)
		operation.cancel()
		store.selectProject("project-b")
		await gate.release()
		guard case .success = await operation.value else {
			Issue.record("The committed import did not report durable success.")
			return
		}

		#expect(store.projects.contains { $0.id == "remote" })
		#expect(store.selectedProjectId == "project-b")
	}

	@Test("a partially failed login cannot retain an invalidated identity")
	@MainActor
	func partialLoginFailureClearsInvalidatedIdentity() async {
		let oldAuthority = round4AuthorityGeneration(seed: 51)
		let newAuthority = round4AuthorityGeneration(seed: 52)
		let authorization = Round4MutableAuthorization(
			token: "account-a",
			generation: oldAuthority
		)
		let api = MockAPIService()
		api.user = round4User(id: "account-a", orgSlug: "acme")
		let store = VaultStore(
			keychainService: MockKeychainService(),
			biometricService: MockBiometricService(),
			apiService: api,
			authAuthorizationProvider: { _, _ in authorization.current },
			authAuthorityValidator: { authorization.isCurrent($0) },
			loginProvider: { _, _ in round4Credentials() },
			authSessionWriter: { credentials, _ in
				authorization.replace(
					token: credentials.token,
					generation: newAuthority
				)
				throw Round5TestError.failed
			},
			authSessionClearer: { _ in }
		)
		await store.loadAccount()
		#expect(store.currentUser?.id == "account-a")
		api.user = round4User(id: "account-b", orgSlug: "acme")

		#expect(!(await store.login()))

		#expect(store.currentUser == nil)
		#expect(store.personalTokens.isEmpty)
		#expect(store.orgTokens.isEmpty)
	}

	@Test("identity loads and revocations reuse an authority generation postflight")
	@MainActor
	func authorityGenerationAvoidsRepeatedCredentialCaptures() async {
		let authority = round4AuthorityGeneration(seed: 61)
		let captures = Round4Counter()
		let api = MockAPIService()
		api.user = round4User(orgSlug: "acme")
		let store = VaultStore(
			keychainService: MockKeychainService(),
			biometricService: MockBiometricService(),
			apiService: api,
			authAuthorizationProvider: { _, _ in
				captures.increment()
				return AuthSessionAuthorization(
					token: "account-a",
					authorityGeneration: authority
				)
			},
			authAuthorityValidator: { $0 == authority },
			authorizedRemoteMutationExecutor: { _, operation in operation() }
		)

		await store.loadAccount()
		#expect(captures.value == 1)

		captures.reset()
		store.personalTokens = [round4Token(id: "personal")]
		await store.revokePersonalToken(round4Token(id: "personal"))
		#expect(captures.value == 1)

		captures.reset()
		var orgToken = round4Token(id: "organization")
		orgToken.orgSlug = "acme"
		store.orgTokens = ["acme": [orgToken]]
		await store.revokeOrgToken(orgToken, orgSlug: "acme")
		#expect(captures.value == 1)
	}

	@Test("authorization providers without generations retain postflight recapture")
	@MainActor
	func generationlessProviderStillRecapturesAuthorization() async {
		let captures = Round4Counter()
		let api = MockAPIService()
		api.user = round4User(orgSlug: "acme")
		let store = VaultStore(
			keychainService: MockKeychainService(),
			biometricService: MockBiometricService(),
			apiService: api,
			authTokenProvider: { _, _ in
				captures.increment()
				return "account-a"
			}
		)

		await store.loadAccount()

		#expect(captures.value == 2)

		captures.reset()
		store.personalTokens = [round4Token(id: "generationless")]
		await store.revokePersonalToken(round4Token(id: "generationless"))
		#expect(captures.value == 2)
	}

	@Test("personal push preparation occurs before credential-lock admission")
	@MainActor
	func pushPreparationOccursBeforeCredentialLockStart() async {
		let authority = round4AuthorityGeneration(seed: 71)
		let insideCredentialLock = Round4MutableBool(false)
		let sync = Round5StartObservingPersonalSyncService(
			insideCredentialLock: insideCredentialLock
		)
		let keychain = MockKeychainService()
		keychain.envStorage["project"] = (
			name: "Project",
			path: "",
			environments: ["default": ["TOKEN": "local"]]
		)
		let api = MockAPIService()
		api.user = round4User(orgSlug: "acme")
		let store = VaultStore(
			keychainService: keychain,
			biometricService: MockBiometricService(),
			apiService: api,
			personalSyncServiceFactory: { _ in sync },
			stableSyncEncryptor: { _, _, _, _ in ("blob", "wrapped") },
			authAuthorizationProvider: { _, _ in
				AuthSessionAuthorization(token: "account-a", authorityGeneration: authority)
			},
			authAuthorityValidator: { $0 == authority },
			authorizedRemoteMutationExecutor: { _, operation in
				insideCredentialLock.value = true
				defer { insideCredentialLock.value = false }
				return operation()
			}
		)
		store.projects = [VaultProject(
			id: "project",
			name: "Project",
			path: "",
			environments: ["default": ["TOKEN": "local"]]
		)]
		store.isUnlocked = true
		store.selectProject("project")
		await store.loadAccount()

		await store.pushToCloud()

		#expect(sync.prepareCallCount == 1)
		#expect(!sync.observedPreparationInsideCredentialLock)
		#expect(sync.pushCallCount == 1)
	}

	@Test("gated push preparation does not block independent authorization admission")
	@MainActor
	func gatedPushPreparationStaysOutsideCredentialLock() async {
		let oldAuthority = round4AuthorityGeneration(seed: 81)
		let newAuthority = round4AuthorityGeneration(seed: 82)
		let authorization = Round4MutableAuthorization(
			token: "account-a",
			generation: oldAuthority
		)
		let preparationGate = Round4AsyncGate()
		let executorCalls = Round4Counter()
		let sync = Round5GatedPreparationPersonalSyncService(gate: preparationGate)
		let keychain = MockKeychainService()
		keychain.envStorage["project"] = (
			name: "Project",
			path: "",
			environments: ["default": ["TOKEN": "local"]]
		)
		let api = MockAPIService()
		api.user = round4User(orgSlug: "acme")
		let token = round4Token(id: "independent")
		let store = VaultStore(
			keychainService: keychain,
			biometricService: MockBiometricService(),
			apiService: api,
			personalSyncServiceFactory: { _ in sync },
			stableSyncEncryptor: { _, _, _, _ in ("blob", "wrapped") },
			authAuthorizationProvider: { _, _ in authorization.current },
			authAuthorityValidator: { authorization.isCurrent($0) },
			authorizedRemoteMutationExecutor: { _, operation in
				executorCalls.increment()
				return operation()
			}
		)
		store.projects = [VaultProject(
			id: "project",
			name: "Project",
			path: "",
			environments: ["default": ["TOKEN": "local"]]
		)]
		store.isUnlocked = true
		store.selectProject("project")
		await store.loadAccount()
		store.personalTokens = [token]

		let push = Task { await store.pushToCloud() }
		await preparationGate.waitUntilArrived()
		#expect(executorCalls.value == 0)

		await store.revokePersonalToken(token)
		#expect(executorCalls.value == 1)
		#expect(api.revokedTokenIds == [token.id])

		authorization.replace(token: "account-b", generation: newAuthority)
		await preparationGate.release()
		await push.value

		#expect(sync.preparedStartCallCount == 0)
		#expect(executorCalls.value == 1)
	}

	@Test("locking during explicit project creation never republishes plaintext")
	@MainActor
	func lockDuringExplicitProjectCreationKeepsMemoryScrubbed() async {
		let entered = DispatchSemaphore(value: 0)
		let release = DispatchSemaphore(value: 0)
		let keychain = MockKeychainService()
		keychain.blockNextSaveEnvironments = {
			entered.signal()
			release.wait()
		}
		let store = VaultStore(
			keychainService: keychain,
			biometricService: MockBiometricService(),
			apiService: MockAPIService()
		)
		store.isUnlocked = true

		let creation = Task {
			await store.addProjectWithVaultId(
				vaultId: "locked-create",
				name: "Locked Create",
				path: "",
				environments: ["default": ["TOKEN": "secret"]]
			)
		}
		await waitForSemaphore(entered)
		store.lock()
		release.signal()

		#expect(await creation.value)
		#expect(keychain.envStorage["locked-create"]?.environments["default"]?["TOKEN"] == "secret")
		#expect(!store.isUnlocked)
		#expect(!store.projects.contains { $0.id == "locked-create" })
	}

	@Test("personal push failures reject a rotated external authority")
	@MainActor
	func personalPushFailureRejectsRotatedAuthority() async {
		let oldAuthority = round4AuthorityGeneration(seed: 91)
		let newAuthority = round4AuthorityGeneration(seed: 92)
		let authorization = Round4MutableAuthorization(
			token: "account-a",
			generation: oldAuthority
		)
		let entered = DispatchSemaphore(value: 0)
		let release = DispatchSemaphore(value: 0)
		let keychain = MockKeychainService()
		keychain.envStorage["project"] = (
			name: "Project",
			path: "",
			environments: ["default": ["TOKEN": "local"]]
		)
		let api = MockAPIService()
		api.user = round4User(orgSlug: "acme")
		let sync = MockPersonalSyncService()
		let store = VaultStore(
			keychainService: keychain,
			biometricService: MockBiometricService(),
			apiService: api,
			personalSyncServiceFactory: { _ in sync },
			stableSyncEncryptor: { _, _, _, _ in
				entered.signal()
				release.wait()
				throw Round5TestError.failed
			},
			authAuthorizationProvider: { _, _ in authorization.current },
			authAuthorityValidator: { authorization.isCurrent($0) }
		)
		store.projects = [VaultProject(
			id: "project",
			name: "Project",
			path: "",
			environments: ["default": ["TOKEN": "local"]]
		)]
		store.isUnlocked = true
		store.selectProject("project")
		await store.loadAccount()

		let push = Task { await store.pushToCloud() }
		await waitForSemaphore(entered)
		authorization.replace(token: "account-b", generation: newAuthority)
		release.signal()
		await push.value

		round4ExpectSignedOut(store)
		#expect(store.lastSyncStatus == nil)
	}

	@Test("organization sharing rejects an excessive member inventory")
	@MainActor
	func organizationSharingRejectsExcessiveMemberInventory() async {
		let slug = "acme"
		let projectID = "organization-project"
		let localKeypair = VaultCrypto.generateX25519Keypair()
		let memberKeypair = VaultCrypto.generateX25519Keypair()
		let encodedKey = memberKeypair.publicKey.base64EncodedString()
		let fingerprint = VaultCrypto.publicKeyFingerprint(memberKeypair.publicKey)
    let members = (0..<10_001).map { index in
			SyncService.MemberPublicKey(
				userId: "member-\(index)",
				role: "member",
				publicKey: encodedKey,
				publicKeyVersion: 1,
				publicKeyFingerprint: fingerprint,
				hasPublicKey: true
			)
		}
		let sync = MockOrgSyncService()
		sync.publicKeyRecord = SyncService.PublicKeyRecord(
			publicKey: localKeypair.publicKey.base64EncodedString(),
			publicKeyVersion: 1,
			publicKeyFingerprint: VaultCrypto.publicKeyFingerprint(localKeypair.publicKey)
		)
		sync.memberKeyAccess = SyncService.MemberKeyAccess(
			organizationID: round4OrganizationID,
			callerUserID: "account-a",
			members: members,
			canReplaceWrappedKeys: true
		)
		let keychain = MockKeychainService()
		keychain.envStorage[projectID] = (
			name: "Organization",
			path: "",
			environments: ["default": ["TOKEN": "secret"]]
		)
		let store = VaultStore(
			keychainService: keychain,
			biometricService: MockBiometricService(),
			apiService: MockAPIService(),
			orgSyncServiceFactory: { _ in sync },
			sharingKeypairProvider: { localKeypair },
			authTokenProvider: { _, _ in "session-token" }
		)
		store.currentUser = round4User(orgSlug: slug)
		store.projects = [VaultProject(
			id: projectID,
			name: "Organization",
			path: "",
			environments: ["default": ["TOKEN": "secret"]]
		)]
		store.vaultOrgAssociations = [projectID: slug]
		store.isUnlocked = true
		store.selectAccount(.org(slug))
		store.selectProject(projectID)

		await store.pushToOrg(orgSlug: slug)

		#expect(store.pendingOrgPush == nil)
		#expect(!store.showKeyApprovalSheet)
		#expect(sync.pushCallCount == 0)
		#expect(store.lastSyncStatus == "failed")
	}

	@Test(
		"organization sharing rejects non-contributory member keys before approval",
		arguments: [Data(repeating: 0, count: 32), Data([1] + Array(repeating: 0, count: 31))]
	)
	@MainActor
	func organizationSharingRejectsNonContributoryMemberKeys(publicKey: Data) async {
		let slug = "acme"
		let projectID = "organization-project"
		let localKeypair = VaultCrypto.generateX25519Keypair()
		let sync = MockOrgSyncService()
		sync.publicKeyRecord = SyncService.PublicKeyRecord(
			publicKey: localKeypair.publicKey.base64EncodedString(),
			publicKeyVersion: 1,
			publicKeyFingerprint: VaultCrypto.publicKeyFingerprint(localKeypair.publicKey)
		)
		sync.memberKeyAccess = SyncService.MemberKeyAccess(
			organizationID: round4OrganizationID,
			callerUserID: "account-a",
			members: [SyncService.MemberPublicKey(
				userId: "member",
				role: "member",
				publicKey: publicKey.base64EncodedString(),
				publicKeyVersion: 1,
				publicKeyFingerprint: VaultCrypto.publicKeyFingerprint(publicKey),
				hasPublicKey: true
			)],
			canReplaceWrappedKeys: true
		)
		let keychain = MockKeychainService()
		keychain.envStorage[projectID] = (
			name: "Organization",
			path: "",
			environments: ["default": ["TOKEN": "secret"]]
		)
		let store = VaultStore(
			keychainService: keychain,
			biometricService: MockBiometricService(),
			apiService: MockAPIService(),
			orgSyncServiceFactory: { _ in sync },
			sharingKeypairProvider: { localKeypair },
			authTokenProvider: { _, _ in "session-token" }
		)
		store.currentUser = round4User(orgSlug: slug)
		store.projects = [VaultProject(
			id: projectID,
			name: "Organization",
			path: "",
			environments: ["default": ["TOKEN": "secret"]]
		)]
		store.vaultOrgAssociations = [projectID: slug]
		store.isUnlocked = true
		store.selectAccount(.org(slug))
		store.selectProject(projectID)

		await store.pushToOrg(orgSlug: slug)

		#expect(store.pendingOrgPush == nil)
		#expect(!store.showKeyApprovalSheet)
		#expect(keychain.dataStorage["__org_keys__\(slug)"] == nil)
		#expect(sync.pushCallCount == 0)
		#expect(store.lastSyncStatus == "failed")
	}

	@Test("personal pull rejects revision replay")
	@MainActor
	func personalPullRejectsReplayAtomically() async throws {
		let projectID = "personal-replay"
		let payload = try JSONEncoder().encode([
			"environments": ["default": ["TOKEN": "stale"]]
		])
		let wrappingKey = VaultCrypto.generateAESKey()
		let replay = try VaultCrypto.encryptForStableSync(
			plaintext: payload,
			principalId: "account-a",
			vaultId: projectID,
			revision: 1,
			wrappingKey: wrappingKey
		)

		for cryptoVersion in [VaultCrypto.currentCryptoVersion] {
			let sync = MockPersonalSyncService()
			let response = SyncService.SyncStatus(
				vaultId: projectID,
				version: 2,
				cryptoVersion: cryptoVersion,
				contentKeyVersion: nil,
				recipientPublicKeyVersion: nil,
				recipientPublicKeyFingerprint: nil,
				status: "ok",
				error: nil,
				code: nil,
				serverVersion: nil,
				hint: nil,
				encryptedBlob: replay.encryptedBlob,
				wrappedKey: replay.wrappedKey,
				updatedAt: nil,
				principalId: "account-a"
			)
			sync.pullHandlers = [{ response }]
			let keychain = MockKeychainService()
			keychain.envStorage[projectID] = (
				name: "Personal",
				path: "",
				environments: ["default": ["TOKEN": "current"]]
			)
			let metadata = mockCurrentSyncMetadata(
				version: 1,
				principalID: "account-a",
				scope: "personal",
				action: "push"
			)
			#expect(keychain.seedSyncMetadata([projectID: metadata]))
			let metadataData = try #require(
				keychain.dataStorage[mockSyncMetadataAccount(vaultId: projectID)]
			)
			let store = VaultStore(
				keychainService: keychain,
				biometricService: MockBiometricService(),
				apiService: MockAPIService(),
				personalSyncServiceFactory: { _ in sync },
				stableSyncDecryptor: { blob, wrapped, principalID, vaultID, revision, version in
					Data(try VaultCrypto.decryptStableSync(
						encryptedBlob: blob,
						wrappedKey: wrapped,
						principalId: principalID,
						vaultId: vaultID,
						revision: revision,
						cryptoVersion: version,
						wrappingKey: wrappingKey
					).utf8)
				},
				authTokenProvider: { _, _ in "session-token" }
			)
			store.projects = [VaultProject(
				id: projectID,
				name: "Personal",
				path: "",
				environments: ["default": ["TOKEN": "current"]]
			)]
			store.syncMetadata = [projectID: metadata]
			store.currentUser = round4User(id: "account-a", orgSlug: "acme")
			store.isUnlocked = true
			store.selectProject(projectID)

			await store.pullFromCloud()

			#expect(keychain.envStorage[projectID]?.environments["default"]?["TOKEN"] == "current")
			#expect(
				keychain.dataStorage[mockSyncMetadataAccount(vaultId: projectID)] == metadataData
			)
			#expect(store.projects[0].secrets(for: "default")["TOKEN"] == "current")
			#expect(store.syncMetadata[projectID]?.lastVersion == 1)
			#expect(store.syncMetadata[projectID]?.isDirty == true)
			#expect(store.lastSyncStatus == "failed")
		}
	}

	@Test("personal push reports an existing remote without an authority checkpoint")
	@MainActor
	func personalPushRejectsExistingRemoteWithoutAuthorityCheckpoint() async {
		let projectID = "personal-existing-without-floor"
		let sync = MockPersonalSyncService()
		sync.pushHandlers = [{
			SyncService.SyncStatus(
				vaultId: nil,
				version: nil,
				cryptoVersion: nil,
				contentKeyVersion: nil,
				recipientPublicKeyVersion: nil,
				recipientPublicKeyFingerprint: nil,
				status: nil,
				error: "Vault exists on the server. Pull first then push with the synced version, or pass --force to overwrite.",
				code: "vault_expected_version_required",
				serverVersion: 12,
				hint: "Pull the env project before pushing.",
				encryptedBlob: nil,
				wrappedKey: nil,
				updatedAt: nil
			)
		}]
		let encryptionCalls = Round4MutableInt()
		encryptionCalls.value = 0
		let keychain = MockKeychainService()
		keychain.envStorage[projectID] = (
			name: "Personal",
			path: "",
			environments: ["default": ["TOKEN": "local"]]
		)
		let store = VaultStore(
			keychainService: keychain,
			biometricService: MockBiometricService(),
			apiService: MockAPIService(),
			personalSyncServiceFactory: { _ in sync },
			stableSyncEncryptor: { _, _, _, _ in
				encryptionCalls.value = (encryptionCalls.value ?? 0) + 1
				return ("ciphertext", "wrapped-key")
			},
			authTokenProvider: { _, _ in "session-token" }
		)
		store.appEnvironment = .production
		store.projects = [VaultProject(
			id: projectID,
			name: "Personal",
			path: "",
			environments: ["default": ["TOKEN": "local"]]
		)]
		store.currentUser = round4User(id: "account-a", orgSlug: "acme")
		store.isUnlocked = true
		store.selectProject(projectID)

		await store.pushToCloud()

		#expect(sync.versionPreflightCallCount == 0)
		#expect(sync.pushCallCount == 1)
		#expect(sync.pushedExpectedVersions == [nil])
		#expect(encryptionCalls.value == 1)
		#expect(store.syncMetadata[projectID] == nil)
		#expect(store.lastSyncStatus == "conflict")
		#expect(store.error == "This cloud env project already exists. Pull it before pushing.")
	}

	@Test("personal push reports a stale authority checkpoint")
	@MainActor
	func personalPushReportsStaleAuthorityCheckpoint() async throws {
		let projectID = "personal-stale-floor"
		let conflict = SyncService.SyncStatus(
			vaultId: nil,
			version: nil,
			cryptoVersion: nil,
			contentKeyVersion: nil,
			recipientPublicKeyVersion: nil,
			recipientPublicKeyFingerprint: nil,
			status: nil,
			error: "Version conflict",
			code: "vault_version_conflict",
			serverVersion: 6,
			hint: "Pull the latest env project before pushing.",
			encryptedBlob: nil,
			wrappedKey: nil,
			updatedAt: nil
		)
		let fixture = try round4PersonalConflictFixture(
			projectID: projectID,
			localVersion: 5,
			response: conflict
		)

		await fixture.store.pushToCloud()

		#expect(fixture.sync.versionPreflightCallCount == 0)
		#expect(fixture.sync.pushCallCount == 1)
		#expect(fixture.sync.pushedExpectedVersions == [5])
		#expect(fixture.encryptionCalls.value == 1)
		#expect(fixture.store.syncMetadata[projectID]?.lastVersion == 5)
		#expect(fixture.store.lastSyncStatus == "conflict")
		#expect(fixture.store.error == "The cloud env project changed. Pull the latest version before pushing.")
	}

	@Test("personal push reports a remotely deleted known vault")
	@MainActor
	func personalPushReportsRemotelyDeletedKnownVault() async throws {
		let projectID = "personal-deleted-remote"
		let conflict = SyncService.SyncStatus(
			vaultId: nil,
			version: nil,
			cryptoVersion: nil,
			contentKeyVersion: nil,
			recipientPublicKeyVersion: nil,
			recipientPublicKeyFingerprint: nil,
			status: nil,
			error: "Ciphertext revision does not match the next server version",
			code: "vault_ciphertext_revision_mismatch",
			serverVersion: 0,
			hint: "Use --force to recreate the env project.",
			encryptedBlob: nil,
			wrappedKey: nil,
			updatedAt: nil
		)
		let fixture = try round4PersonalConflictFixture(
			projectID: projectID,
			localVersion: 5,
			response: conflict
		)

		await fixture.store.pushToCloud()

		#expect(fixture.sync.versionPreflightCallCount == 0)
		#expect(fixture.sync.pushCallCount == 1)
		#expect(fixture.sync.pushedExpectedVersions == [5])
		#expect(fixture.encryptionCalls.value == 1)
		#expect(fixture.store.syncMetadata[projectID]?.lastVersion == 5)
		#expect(fixture.store.lastSyncStatus == "conflict")
		#expect(fixture.store.error == "This cloud env project was deleted. Use Force Push to recreate it.")
	}

	@Test("sync rollback floors survive principal and Registry switches")
	func syncRollbackFloorsRetainEveryAuthority() async throws {
		let projectID = "multi-authority-floor"
		let project = VaultProject(
			id: projectID,
			name: "Shared checkout",
			path: "",
			environments: ["default": ["TOKEN": "local"]]
		)
		let keychain = MockKeychainService()
		keychain.envStorage[projectID] = (
			name: project.name,
			path: project.path,
			environments: project.environments
		)
		let persistence = VaultPersistenceCoordinator(service: keychain)
		let accountA = SyncPrincipalBinding(
			registryURL: "https://registry-a.example",
			principalID: "account-a",
			scope: "personal"
		)
		let accountB = SyncPrincipalBinding(
			registryURL: "https://registry-a.example",
			principalID: "account-b",
			scope: "personal"
		)
		let accountAOtherRegistry = SyncPrincipalBinding(
			registryURL: "https://registry-b.example",
			principalID: "account-a",
			scope: "personal"
		)

		#expect(await persistence.finishPush(
			pushedProject: project,
			action: "pull",
			version: 12,
			binding: accountA
		) != nil)
		let metadataAccount = mockSyncMetadataAccount(vaultId: projectID)
		let beforePrincipalSubstitution = try #require(keychain.dataStorage[metadataAccount])
		#expect(await persistence.finishPush(
			pushedProject: project,
			action: "pull",
			version: 2,
			binding: accountB
		) == nil)
		#expect(keychain.dataStorage[metadataAccount] == beforePrincipalSubstitution)
		#expect(await persistence.finishPush(
			pushedProject: project,
			action: "pull",
			version: 4,
			binding: accountAOtherRegistry
		) != nil)
		let beforeRollback = try #require(keychain.dataStorage[metadataAccount])

		#expect(await persistence.finishPush(
			pushedProject: project,
			action: "pull",
			version: 11,
			binding: accountA
		) == nil)

		#expect(keychain.dataStorage[metadataAccount] == beforeRollback)
		let metadata = try #require(keychain.storedSyncMetadata(vaultId: projectID))
		#expect(metadata.version(boundTo: accountA) == 12)
		#expect(metadata.version(boundTo: accountB) == nil)
		#expect(metadata.version(boundTo: accountAOtherRegistry) == 4)
	}

	@Test("Registry detours cannot replace a retained sync principal")
	func syncCheckpointRegistryDetoursCannotReplacePrincipal() throws {
		for scope in ["personal", "organization"] {
			let registryABinding = SyncPrincipalBinding(
				registryURL: "https://registry-a.example",
				principalID: "principal-a",
				scope: scope
			)
			var metadata = SyncMetadata()
			try metadata.record(
				binding: registryABinding,
				version: 10,
				action: "pull",
				date: Date(timeIntervalSince1970: 1),
				isDirty: false
			)
			try metadata.record(
				binding: SyncPrincipalBinding(
					registryURL: "https://registry-b.example",
					principalID: "principal-b",
					scope: scope
				),
				version: 2,
				action: "pull",
				date: Date(timeIntervalSince1970: 2),
				isDirty: false
			)
			let substitute = SyncPrincipalBinding(
				registryURL: registryABinding.registryURL,
				principalID: "principal-substitute",
				scope: scope
			)

			#expect(metadata.conflicts(with: substitute))
			do {
				try metadata.record(
					binding: substitute,
					version: 11,
					action: "pull",
					date: Date(timeIntervalSince1970: 3),
					isDirty: false
				)
				Issue.record("A Registry detour replaced the retained \(scope) principal")
			} catch SyncCheckpointError.principalConflict {
			} catch {
				Issue.record("Unexpected checkpoint error for \(scope): \(error)")
			}
			#expect(metadata.version(boundTo: registryABinding) == 10)
			#expect(metadata.version(boundTo: substitute) == nil)
		}
	}

	@Test("personal pull rejects a different active principal before network or decryption")
	@MainActor
	func personalPullRejectsResponseSelectedPrincipalNamespace() async throws {
		let projectID = "principal-substitution"
		let binding = SyncPrincipalBinding(
			registryURL: AppEnvironment.production.registryURL,
			principalID: "account-a",
			scope: "personal"
		)
		let metadata = SyncMetadata(
			lastSyncedAt: Date(timeIntervalSince1970: 1),
			lastAction: "pull",
			lastVersion: 10,
			isDirty: false,
			binding: binding
		)
		let keychain = MockKeychainService()
		keychain.envStorage[projectID] = (
			name: "Principal",
			path: "",
			environments: ["default": ["TOKEN": "current"]]
		)
		#expect(keychain.seedSyncMetadata([projectID: metadata]))
		let metadataBytes = try #require(
			keychain.dataStorage[mockSyncMetadataAccount(vaultId: projectID)]
		)
		let activeBinding = SyncPrincipalBinding(
			registryURL: AppEnvironment.production.registryURL,
			principalID: "account-b",
			scope: "personal"
		)
		#expect(metadata.conflicts(with: activeBinding))
		let snapshot = await VaultPersistenceCoordinator(service: keychain).syncSnapshot(
			vaultId: projectID,
			binding: activeBinding
		)
		#expect(snapshot?.bindingConflict == true)
		let sync = MockPersonalSyncService()
		sync.pullHandlers = [{
			SyncService.SyncStatus(
				vaultId: projectID,
				version: 9,
				cryptoVersion: VaultCrypto.currentCryptoVersion,
				contentKeyVersion: nil,
				recipientPublicKeyVersion: nil,
				recipientPublicKeyFingerprint: nil,
				status: "ok",
				error: nil,
				code: nil,
				serverVersion: nil,
				hint: nil,
				encryptedBlob: "genuine-revision-nine",
				wrappedKey: "wrapped",
				updatedAt: nil,
				principalId: "account-b"
			)
		}]
		let decryptions = Round4Counter()
		let store = VaultStore(
			keychainService: keychain,
			biometricService: MockBiometricService(),
			apiService: MockAPIService(),
			personalSyncServiceFactory: { _ in sync },
			stableSyncDecryptor: { _, _, _, _, _, _ in
				decryptions.increment()
				return try JSONEncoder().encode([
					"environments": ["default": ["TOKEN": "stale"]]
				])
			},
			authTokenProvider: { _, _ in "session-token" }
		)
		store.projects = [VaultProject(
			id: projectID,
			name: "Principal",
			path: "",
			environments: ["default": ["TOKEN": "current"]]
		)]
		store.appEnvironment = .production
		store.syncMetadata = [projectID: metadata]
		store.currentUser = round4User(id: "account-b", orgSlug: "acme")
		store.isUnlocked = true
		store.selectProject(projectID)

		await store.pullFromCloud()

		#expect(sync.pullCallCount == 0)
		#expect(decryptions.value == 0)
		#expect(keychain.envStorage[projectID]?.environments["default"]?["TOKEN"] == "current")
		#expect(
			keychain.dataStorage[mockSyncMetadataAccount(vaultId: projectID)] == metadataBytes
		)
		#expect(store.projects[0].secrets(for: "default")["TOKEN"] == "current")
		#expect(store.syncMetadata[projectID]?.lastVersion == 10)
		#expect(store.lastSyncStatus == "failed")
	}

	@Test("sync checkpoint capacity fails closed without evicting rollback floors")
	func syncCheckpointHistoryNeverEvictsRollbackFloors() async throws {
		let projectID = "bounded-authority-floor"
		let project = VaultProject(
			id: projectID,
			name: "Bounded history",
			path: "",
			environments: ["default": ["TOKEN": "local"]]
		)
		let keychain = MockKeychainService()
		keychain.envStorage[projectID] = (
			name: project.name,
			path: project.path,
			environments: project.environments
		)
		let firstBinding = SyncPrincipalBinding(
			registryURL: "https://registry-0.example",
			principalID: "account-0",
			scope: "personal"
		)
		#expect(keychain.seedSyncMetadata([
			projectID: mockCurrentSyncMetadata(
				version: 12,
				principalID: firstBinding.principalID,
				scope: firstBinding.scope,
				registryURL: firstBinding.registryURL
			)
		]))
		let persistence = VaultPersistenceCoordinator(service: keychain)
		#expect(await persistence.finishPush(
			pushedProject: project,
			action: "pull",
			version: 11,
			binding: firstBinding
		) == nil)
		#expect(keychain.storedSyncMetadata(vaultId: projectID)?.lastVersion == 12)
		#expect(await persistence.finishPush(
			pushedProject: project,
			action: "pull",
			version: 12,
			binding: firstBinding
		) != nil)

		for index in 1..<SyncMetadata.maximumCheckpoints {
			let binding = SyncPrincipalBinding(
				registryURL: "https://registry-\(index).example",
				principalID: "account-\(index)",
				scope: "personal"
			)
			#expect(await persistence.finishPush(
				pushedProject: project,
				action: "pull",
				version: 1,
				binding: binding
			) != nil)
		}
		let metadataAccount = mockSyncMetadataAccount(vaultId: projectID)
		let beforeCapacityFailure = try #require(keychain.dataStorage[metadataAccount])
		let extraBinding = SyncPrincipalBinding(
			registryURL: "https://registry-overflow.example",
			principalID: "account-overflow",
			scope: "personal"
		)

		#expect(await persistence.finishPush(
			pushedProject: project,
			action: "pull",
			version: 1,
			binding: extraBinding
		) == nil)
		#expect(keychain.dataStorage[metadataAccount] == beforeCapacityFailure)
		let metadata = try #require(keychain.storedSyncMetadata(vaultId: projectID))
		#expect(metadata.version(boundTo: firstBinding) == 12)
		#expect(metadata.version(boundTo: extraBinding) == nil)
	}

	@Test("personal force push authenticates the server revision before encryption")
	@MainActor
	func personalForcePushUsesAuthenticatedServerRevision() async throws {
		let projectID = "personal-force"
		let sync = MockPersonalSyncService()
		let preflight = SyncService.SyncStatus(
			vaultId: projectID,
			version: 9,
			cryptoVersion: VaultCrypto.currentCryptoVersion,
			contentKeyVersion: nil,
			recipientPublicKeyVersion: nil,
			recipientPublicKeyFingerprint: nil,
			status: "ok",
			error: nil,
			code: nil,
			serverVersion: 9,
			hint: nil,
			encryptedBlob: nil,
			wrappedKey: nil,
			updatedAt: nil,
			principalId: "account-a"
		)
		let committed = SyncService.SyncStatus(
			vaultId: projectID,
			version: 10,
			cryptoVersion: VaultCrypto.currentCryptoVersion,
			contentKeyVersion: nil,
			recipientPublicKeyVersion: nil,
			recipientPublicKeyFingerprint: nil,
			status: "ok",
			error: nil,
			code: nil,
			serverVersion: 10,
			hint: nil,
			encryptedBlob: nil,
			wrappedKey: nil,
			updatedAt: nil,
			principalId: "account-a"
		)
		sync.versionPreflightHandlers = [{ .response(.found(preflight)) }]
		sync.pushHandlers = [{ committed }]
		let encryptedRevision = Round4MutableInt()
		let keychain = MockKeychainService()
		keychain.envStorage[projectID] = (
			name: "Personal",
			path: "",
			environments: ["default": ["TOKEN": "local"]]
		)
		let metadata = mockCurrentSyncMetadata(
			version: 7,
			principalID: "account-a",
			scope: "personal"
		)
		#expect(keychain.seedSyncMetadata([projectID: metadata]))
		let store = VaultStore(
			keychainService: keychain,
			biometricService: MockBiometricService(),
			apiService: MockAPIService(),
			personalSyncServiceFactory: { _ in sync },
			stableSyncEncryptor: { _, _, _, revision in
				encryptedRevision.value = revision
				return ("local-ciphertext", "local-wrapped-key")
			},
			authTokenProvider: { _, _ in "session-token" }
		)
		store.projects = [VaultProject(
			id: projectID,
			name: "Personal",
			path: "",
			environments: ["default": ["TOKEN": "local"]]
		)]
		store.syncMetadata = [projectID: metadata]
		store.currentUser = round4User(id: "account-a", orgSlug: "acme")
		store.isUnlocked = true
		store.selectProject(projectID)

		await store.pushToCloud(force: true)

		#expect(sync.versionPreflightCallCount == 1)
		#expect(sync.pullCallCount == 0)
		#expect(encryptedRevision.value == 10)
		#expect(sync.pushedExpectedVersions == [9])
		#expect(sync.pushedForceValues == [true])
		#expect(store.syncMetadata[projectID]?.lastVersion == 10)
		#expect(store.lastSyncStatus == "Pushed (v10)")
	}

	@Test("personal force push recreates a remotely deleted vault above its authenticated floor")
	@MainActor
	func personalForcePushRecreatesMissingVault() async throws {
		let projectID = "personal-force-recreate"
		let sync = MockPersonalSyncService()
		sync.versionPreflightHandlers = [
			{ .response(.notFound) },
			{ .response(.notFound) },
		]
		sync.pushHandlers = [
			{
				SyncService.SyncStatus(
					vaultId: nil,
					version: nil,
					cryptoVersion: nil,
					contentKeyVersion: nil,
					recipientPublicKeyVersion: nil,
					recipientPublicKeyFingerprint: nil,
					status: nil,
					error:
						"This env project was deleted and must be recreated above its last server revision",
					code: "vault_recreation_intent_required",
					serverVersion: 8,
					hint: nil,
					encryptedBlob: nil,
					wrappedKey: nil,
					updatedAt: nil
				)
			},
			{
			SyncService.SyncStatus(
				vaultId: projectID,
				version: 9,
				cryptoVersion: VaultCrypto.currentCryptoVersion,
				contentKeyVersion: nil,
				recipientPublicKeyVersion: nil,
				recipientPublicKeyFingerprint: nil,
				status: "ok",
				error: nil,
				code: nil,
				serverVersion: 9,
				hint: nil,
				encryptedBlob: nil,
				wrappedKey: nil,
				updatedAt: nil,
				principalId: "account-a"
			)
			},
		]
		let encryptedRevisions = Round4IntRecorder()
		let keychain = MockKeychainService()
		keychain.envStorage[projectID] = (
			name: "Personal",
			path: "",
			environments: ["default": ["TOKEN": "local"]]
		)
		let metadata = SyncMetadata(
			lastSyncedAt: Date(timeIntervalSince1970: 1),
			lastAction: "pull",
			lastVersion: 5,
			isDirty: true,
			binding: SyncPrincipalBinding(
				registryURL: "https://lpm.dev",
				principalID: "account-a",
				scope: "personal"
			)
		)
		#expect(keychain.seedSyncMetadata([projectID: metadata]))
		let store = VaultStore(
			keychainService: keychain,
			biometricService: MockBiometricService(),
			apiService: MockAPIService(),
			personalSyncServiceFactory: { _ in sync },
			stableSyncEncryptor: { _, _, _, revision in
				encryptedRevisions.append(revision)
				return ("local-ciphertext", "local-wrapped-key")
			},
			authTokenProvider: { _, _ in "session-token" }
		)
		store.appEnvironment = .production
		store.projects = [VaultProject(
			id: projectID,
			name: "Personal",
			path: "",
			environments: ["default": ["TOKEN": "local"]]
		)]
		store.syncMetadata = [projectID: metadata]
		store.currentUser = round4User(id: "account-a", orgSlug: "acme")
		store.isUnlocked = true
		store.selectProject(projectID)

		await store.pushToCloud(force: true)

		#expect(sync.versionPreflightCallCount == 2)
		#expect(sync.pullCallCount == 0)
		#expect(encryptedRevisions.values == [6, 9])
		#expect(sync.pushedExpectedVersions == [5, 8])
		#expect(sync.pushedForceValues == [true, true])
		#expect(sync.pushedRecreateMissingValues == [true, true])
		#expect(store.syncMetadata[projectID]?.lastVersion == 9)
		#expect(store.lastSyncStatus == "Pushed (v9)")
	}

	@Test("personal force push rejects a remote revision below its durable checkpoint")
	@MainActor
	func personalForcePushRejectsRemoteRollback() async throws {
		let projectID = "personal-force-rollback"
		let sync = MockPersonalSyncService()
		sync.versionPreflightHandlers = [{
			.response(.found(SyncService.SyncStatus(
				vaultId: projectID,
				version: 4,
				cryptoVersion: VaultCrypto.currentCryptoVersion,
				contentKeyVersion: nil,
				recipientPublicKeyVersion: nil,
				recipientPublicKeyFingerprint: nil,
				status: "ok",
				error: nil,
				code: nil,
				serverVersion: 4,
				hint: nil,
				encryptedBlob: nil,
				wrappedKey: nil,
				updatedAt: nil,
				principalId: "account-a"
			)))
		}]
		let encryptionCalls = Round4MutableInt()
		encryptionCalls.value = 0
		let keychain = MockKeychainService()
		keychain.envStorage[projectID] = (
			name: "Personal",
			path: "",
			environments: ["default": ["TOKEN": "local"]]
		)
		let metadata = SyncMetadata(
			lastSyncedAt: Date(timeIntervalSince1970: 1),
			lastAction: "pull",
			lastVersion: 5,
			isDirty: true,
			binding: SyncPrincipalBinding(
				registryURL: "https://lpm.dev",
				principalID: "account-a",
				scope: "personal"
			)
		)
		#expect(keychain.seedSyncMetadata([projectID: metadata]))
		let store = VaultStore(
			keychainService: keychain,
			biometricService: MockBiometricService(),
			apiService: MockAPIService(),
			personalSyncServiceFactory: { _ in sync },
			stableSyncEncryptor: { _, _, _, _ in
				encryptionCalls.value = (encryptionCalls.value ?? 0) + 1
				return ("ciphertext", "wrapped-key")
			},
			authTokenProvider: { _, _ in "session-token" }
		)
		store.appEnvironment = .production
		store.projects = [VaultProject(
			id: projectID,
			name: "Personal",
			path: "",
			environments: ["default": ["TOKEN": "local"]]
		)]
		store.syncMetadata = [projectID: metadata]
		store.currentUser = round4User(id: "account-a", orgSlug: "acme")
		store.isUnlocked = true
		store.selectProject(projectID)

		await store.pushToCloud(force: true)

		#expect(sync.versionPreflightCallCount == 1)
		#expect(sync.pushCallCount == 0)
		#expect(encryptionCalls.value == 0)
		#expect(store.syncMetadata[projectID]?.lastVersion == 5)
		#expect(store.lastSyncStatus == "failed")
		#expect(store.error == "The cloud env project revision is older than this checkout's authenticated checkpoint.")
	}

	@Test("personal force push re-encrypts after a preflight-to-write race")
	@MainActor
	func personalForcePushRetriesWithTheNewRevision() async {
		let projectID = "personal-force-race"
		let sync = MockPersonalSyncService()
		let firstPreflight = SyncService.SyncStatus(
			vaultId: projectID,
			version: 5,
			cryptoVersion: VaultCrypto.currentCryptoVersion,
			contentKeyVersion: nil,
			recipientPublicKeyVersion: nil,
			recipientPublicKeyFingerprint: nil,
			status: "ok",
			error: nil,
			code: nil,
			serverVersion: 5,
			hint: nil,
			encryptedBlob: nil,
			wrappedKey: nil,
			updatedAt: nil,
			principalId: "account-a"
		)
		let secondPreflight = SyncService.SyncStatus(
			vaultId: projectID,
			version: 6,
			cryptoVersion: VaultCrypto.currentCryptoVersion,
			contentKeyVersion: nil,
			recipientPublicKeyVersion: nil,
			recipientPublicKeyFingerprint: nil,
			status: "ok",
			error: nil,
			code: nil,
			serverVersion: 6,
			hint: nil,
			encryptedBlob: nil,
			wrappedKey: nil,
			updatedAt: nil,
			principalId: "account-a"
		)
		sync.versionPreflightHandlers = [
			{ .response(.found(firstPreflight)) },
			{ .response(.found(secondPreflight)) },
		]
		sync.pushHandlers = [
			{
				SyncService.SyncStatus(
					vaultId: nil,
					version: nil,
					cryptoVersion: nil,
					contentKeyVersion: nil,
					recipientPublicKeyVersion: nil,
					recipientPublicKeyFingerprint: nil,
					status: nil,
					error: "Version conflict",
					code: "vault_version_conflict",
					serverVersion: 6,
					hint: nil,
					encryptedBlob: nil,
					wrappedKey: nil,
					updatedAt: nil
				)
			},
			{
				SyncService.SyncStatus(
					vaultId: projectID,
					version: 7,
					cryptoVersion: VaultCrypto.currentCryptoVersion,
					contentKeyVersion: nil,
					recipientPublicKeyVersion: nil,
					recipientPublicKeyFingerprint: nil,
					status: "ok",
					error: nil,
					code: nil,
					serverVersion: 7,
					hint: nil,
					encryptedBlob: nil,
					wrappedKey: nil,
					updatedAt: nil,
					principalId: "account-a"
				)
			},
		]
		let encryptedRevisions = Round4IntRecorder()
		let keychain = MockKeychainService()
		keychain.envStorage[projectID] = (
			name: "Personal",
			path: "",
			environments: ["default": ["TOKEN": "local"]]
		)
		let store = VaultStore(
			keychainService: keychain,
			biometricService: MockBiometricService(),
			apiService: MockAPIService(),
			personalSyncServiceFactory: { _ in sync },
			stableSyncEncryptor: { _, _, _, revision in
				encryptedRevisions.append(revision)
				return ("ciphertext-\(revision)", "wrapped-\(revision)")
			},
			authTokenProvider: { _, _ in "session-token" }
		)
		store.projects = [VaultProject(
			id: projectID,
			name: "Personal",
			path: "",
			environments: ["default": ["TOKEN": "local"]]
		)]
		store.currentUser = round4User(id: "account-a", orgSlug: "acme")
		store.isUnlocked = true
		store.selectProject(projectID)

		await store.pushToCloud(force: true)

		#expect(sync.versionPreflightCallCount == 2)
		#expect(sync.pushCallCount == 2)
		#expect(sync.pushedExpectedVersions == [5, 6])
		#expect(encryptedRevisions.values == [6, 7])
		#expect(store.syncMetadata[projectID]?.lastVersion == 7)
		#expect(store.lastSyncStatus == "Pushed (v7)")
	}

	@Test("personal force push stops before encryption when version preflight fails")
	@MainActor
	func personalForcePushStopsOnPreflightFailure() async {
		let projectID = "personal-force-failure"
		let sync = MockPersonalSyncService()
		sync.versionPreflightHandlers = [{ .response(nil) }]
		let encryptionCalls = Round4MutableInt()
		encryptionCalls.value = 0
		let keychain = MockKeychainService()
		keychain.envStorage[projectID] = (
			name: "Personal",
			path: "",
			environments: ["default": ["TOKEN": "local"]]
		)
		let store = VaultStore(
			keychainService: keychain,
			biometricService: MockBiometricService(),
			apiService: MockAPIService(),
			personalSyncServiceFactory: { _ in sync },
			stableSyncEncryptor: { _, _, _, _ in
				encryptionCalls.value = (encryptionCalls.value ?? 0) + 1
				return ("local-ciphertext", "local-wrapped-key")
			},
			authTokenProvider: { _, _ in "session-token" }
		)
		store.projects = [VaultProject(
			id: projectID,
			name: "Personal",
			path: "",
			environments: ["default": ["TOKEN": "local"]]
		)]
		store.currentUser = round4User(id: "account-a", orgSlug: "acme")
		store.isUnlocked = true
		store.selectProject(projectID)

		await store.pushToCloud(force: true)

		#expect(sync.versionPreflightCallCount == 1)
		#expect(encryptionCalls.value == 0)
		#expect(sync.pushCallCount == 0)
		#expect(store.lastSyncStatus == "failed")
	}

	@Test("organization pull rejects revision replay")
	@MainActor
	func organizationPullRejectsReplayAtomically() async throws {
		let slug = "acme"
		let projectID = "organization-replay"
		let keypair = VaultCrypto.generateX25519Keypair()
		let contentKey = VaultCrypto.generateAESKey()
		let payload = try JSONEncoder().encode([
			"environments": ["default": ["TOKEN": "stale"]]
		])
		let replay = try VaultCrypto.encryptPayload(
			key: contentKey,
			plaintext: payload,
			scope: .organization(slug: slug),
			principalId: round4OrganizationID,
			vaultId: projectID,
			revision: 1
		)
		let wrapped = try VaultCrypto.wrapKeyForRecipient(
			aesKey: contentKey,
			recipientPublicKey: keypair.publicKey
		)

		for cryptoVersion in [VaultCrypto.currentCryptoVersion] {
			let sync = MockOrgSyncService()
			sync.publicKeyRecord = SyncService.PublicKeyRecord(
				publicKey: keypair.publicKey.base64EncodedString(),
				publicKeyVersion: 1,
				publicKeyFingerprint: VaultCrypto.publicKeyFingerprint(keypair.publicKey)
			)
			sync.pullResult = SyncService.SyncStatus(
				vaultId: projectID,
				version: 2,
				cryptoVersion: cryptoVersion,
				contentKeyVersion: 1,
				recipientPublicKeyVersion: 1,
				recipientPublicKeyFingerprint: VaultCrypto.publicKeyFingerprint(keypair.publicKey),
				status: "ok",
				error: nil,
				code: nil,
				serverVersion: nil,
				hint: nil,
				encryptedBlob: replay,
				wrappedKey: wrapped,
				updatedAt: nil,
				principalId: round4OrganizationID,
				callerUserId: "account-a",
				organizationId: round4OrganizationID
			)
			let keychain = MockKeychainService()
			keychain.envStorage[projectID] = (
				name: "Organization",
				path: "",
				environments: ["default": ["TOKEN": "current"]]
			)
			let metadata = mockCurrentSyncMetadata(
				version: 1,
				principalID: round4OrganizationID,
				scope: "organization",
				action: "push"
			)
			#expect(keychain.seedSyncMetadata([projectID: metadata]))
			let metadataData = try #require(
				keychain.dataStorage[mockSyncMetadataAccount(vaultId: projectID)]
			)
			let store = VaultStore(
				keychainService: keychain,
				biometricService: MockBiometricService(),
				apiService: MockAPIService(),
				orgSyncServiceFactory: { _ in sync },
				sharingKeypairProvider: { keypair },
				authTokenProvider: { _, _ in "session-token" }
			)
			store.currentUser = round4User(orgSlug: slug)
			store.projects = [VaultProject(
				id: projectID,
				name: "Organization",
				path: "",
				environments: ["default": ["TOKEN": "current"]]
			)]
			store.syncMetadata = [projectID: metadata]
			store.vaultOrgAssociations = [projectID: slug]
			store.isUnlocked = true
			store.selectAccount(.org(slug))
			store.selectProject(projectID)

			await store.pullFromOrg(orgSlug: slug)

			#expect(keychain.envStorage[projectID]?.environments["default"]?["TOKEN"] == "current")
			#expect(
				keychain.dataStorage[mockSyncMetadataAccount(vaultId: projectID)] == metadataData
			)
			#expect(store.projects[0].secrets(for: "default")["TOKEN"] == "current")
			#expect(store.syncMetadata[projectID]?.lastVersion == 1)
			#expect(store.syncMetadata[projectID]?.isDirty == true)
			#expect(store.lastSyncStatus == "failed")
		}
	}

	@Test("personal import rejects revision replay")
	@MainActor
	func personalImportRejectsReplayAtomically() async throws {
		let remoteID = "personal-import-replay"
		let existingID = "existing-personal"
		let payload = try JSONEncoder().encode([
			"environments": ["default": ["TOKEN": "stale"]]
		])
		let wrappingKey = VaultCrypto.generateAESKey()
		let replay = try VaultCrypto.encryptForStableSync(
			plaintext: payload,
			principalId: "account-a",
			vaultId: remoteID,
			revision: 1,
			wrappingKey: wrappingKey
		)

		for cryptoVersion in [VaultCrypto.currentCryptoVersion] {
			let personalSync = MockPersonalSyncService()
			let response = SyncService.SyncStatus(
				vaultId: remoteID,
				version: 2,
				cryptoVersion: cryptoVersion,
				contentKeyVersion: nil,
				recipientPublicKeyVersion: nil,
				recipientPublicKeyFingerprint: nil,
				status: "ok",
				error: nil,
				code: nil,
				serverVersion: nil,
				hint: nil,
				encryptedBlob: replay.encryptedBlob,
				wrappedKey: replay.wrappedKey,
				updatedAt: nil
			)
			personalSync.pullHandlers = [{ response }]
			let importService = EnvProjectImportService(
				personalSyncService: personalSync,
				organizationSyncService: MockOrgSyncService(),
				sharingKeypairProvider: VaultCrypto.generateX25519Keypair,
				personalDecryptor: { blob, wrapped, principalID, vaultID, revision, version in
					Data(try VaultCrypto.decryptStableSync(
						encryptedBlob: blob,
						wrappedKey: wrapped,
						principalId: principalID,
						vaultId: vaultID,
						revision: revision,
						cryptoVersion: version,
						wrappingKey: wrappingKey
					).utf8)
				}
			)
			let keychain = MockKeychainService()
			keychain.envStorage[existingID] = (
				name: "Existing",
				path: "",
				environments: ["default": ["TOKEN": "current"]]
			)
			let metadata = mockCurrentSyncMetadata(
				version: 4,
				principalID: "account-a",
				scope: "personal",
				action: "push"
			)
			#expect(keychain.seedSyncMetadata([existingID: metadata]))
			let metadataAccount = mockSyncMetadataAccount(vaultId: existingID)
			let metadataData = try #require(keychain.dataStorage[metadataAccount])
			let store = VaultStore(
				keychainService: keychain,
				biometricService: MockBiometricService(),
				apiService: MockAPIService(),
				importServiceFactory: { _ in importService },
				authTokenProvider: { _, _ in "session-token" }
			)
			store.projects = [VaultProject(
				id: existingID,
				name: "Existing",
				path: "",
				environments: ["default": ["TOKEN": "current"]]
			)]
			store.syncMetadata = [existingID: metadata]

			let result = await store.importCloudProject(SyncService.RemoteProject(
				vaultId: remoteID,
				name: "Remote",
				version: 2,
				updatedAt: nil,
				updatedBy: nil
			))

			guard case .failure(.invalidPayload) = result else {
				Issue.record("Accepted personal replay vector for crypto v\(cryptoVersion)")
				continue
			}
			#expect(keychain.envStorage[remoteID] == nil)
			#expect(keychain.envStorage[existingID]?.environments["default"]?["TOKEN"] == "current")
			#expect(keychain.dataStorage[metadataAccount] == metadataData)
			#expect(store.projects.map(\.id) == [existingID])
			#expect(store.syncMetadata[existingID]?.lastVersion == 4)
			#expect(store.syncMetadata[remoteID] == nil)
		}
	}

	@Test("organization import rejects revision replay")
	@MainActor
	func organizationImportRejectsReplayAtomically() async throws {
		let slug = "acme"
		let remoteID = "organization-import-replay"
		let existingID = "existing-organization"
		let keypair = VaultCrypto.generateX25519Keypair()
		let contentKey = VaultCrypto.generateAESKey()
		let payload = try JSONEncoder().encode([
			"environments": ["default": ["TOKEN": "stale"]]
		])
		let replay = try VaultCrypto.encryptPayload(
			key: contentKey,
			plaintext: payload,
			scope: .organization(slug: slug),
			principalId: "organization",
			vaultId: remoteID,
			revision: 1
		)
		let wrapped = try VaultCrypto.wrapKeyForRecipient(
			aesKey: contentKey,
			recipientPublicKey: keypair.publicKey
		)

		for cryptoVersion in [VaultCrypto.currentCryptoVersion] {
			let organizationSync = MockOrgSyncService()
			organizationSync.publicKeyRecord = SyncService.PublicKeyRecord(
				publicKey: keypair.publicKey.base64EncodedString(),
				publicKeyVersion: 1,
				publicKeyFingerprint: VaultCrypto.publicKeyFingerprint(keypair.publicKey)
			)
			organizationSync.pullResult = SyncService.SyncStatus(
				vaultId: remoteID,
				version: 2,
				cryptoVersion: cryptoVersion,
				contentKeyVersion: 1,
				recipientPublicKeyVersion: 1,
				recipientPublicKeyFingerprint: VaultCrypto.publicKeyFingerprint(keypair.publicKey),
				status: "ok",
				error: nil,
				code: nil,
				serverVersion: nil,
				hint: nil,
				encryptedBlob: replay,
				wrappedKey: wrapped,
				updatedAt: nil
			)
			let importService = EnvProjectImportService(
				personalSyncService: MockPersonalSyncService(),
				organizationSyncService: organizationSync,
				sharingKeypairProvider: { keypair }
			)
			let keychain = MockKeychainService()
			keychain.envStorage[existingID] = (
				name: "Existing",
				path: "",
				environments: ["default": ["TOKEN": "current"]]
			)
			let metadata = mockCurrentSyncMetadata(
				version: 4,
				principalID: round4OrganizationID,
				scope: "organization",
				action: "push"
			)
			#expect(keychain.seedSyncMetadata([existingID: metadata]))
			let metadataAccount = mockSyncMetadataAccount(vaultId: existingID)
			let metadataData = try #require(keychain.dataStorage[metadataAccount])
			let store = VaultStore(
				keychainService: keychain,
				biometricService: MockBiometricService(),
				apiService: MockAPIService(),
				importServiceFactory: { _ in importService },
				authTokenProvider: { _, _ in "session-token" }
			)
			store.currentUser = round4User(orgSlug: slug)
			store.projects = [VaultProject(
				id: existingID,
				name: "Existing",
				path: "",
				environments: ["default": ["TOKEN": "current"]]
			)]
			store.syncMetadata = [existingID: metadata]
			store.vaultOrgAssociations = [existingID: slug]

			let result = await store.importOrganizationProject(
				SyncService.RemoteProject(
					vaultId: remoteID,
					name: "Remote",
					version: 2,
					updatedAt: nil,
					updatedBy: nil
				),
				orgSlug: slug
			)

			guard case .failure(.invalidPayload) = result else {
				Issue.record("Accepted organization replay vector for crypto v\(cryptoVersion)")
				continue
			}
			#expect(keychain.envStorage[remoteID] == nil)
			#expect(keychain.envStorage[existingID]?.environments["default"]?["TOKEN"] == "current")
			#expect(keychain.dataStorage[metadataAccount] == metadataData)
			#expect(store.projects.map(\.id) == [existingID])
			#expect(store.syncMetadata[existingID]?.lastVersion == 4)
			#expect(store.syncMetadata[remoteID] == nil)
		}
		}
	}
}

@Suite("Versioned project discovery regressions", .serialized)
struct VersionedProjectDiscoveryRegressionTests {
	private let discoveryPrefix = "__vault_project_discovery__:"
	private struct InteroperabilityFixture: Decodable {
		struct Record: Decodable {
			let account: String
			let value: String
		}

		struct Project: Decodable {
			let id: String
			let name: String
			let path: String
			let environmentSummaries: [VaultProjectEnvironmentSummary]
		}

		let schemaVersion: Int
		let records: [Record]
		let project: Project
	}

	@Test("Swift accepts the checked-in Rust project-index fixture without rewriting it")
	func checkedInCrossLanguageFixtureIsAccepted() throws {
		let fixtureURL = URL(fileURLWithPath: #filePath)
			.deletingLastPathComponent()
			.appending(path: "Fixtures/project-index-v3.json")
		let fixture = try JSONDecoder().decode(
			InteroperabilityFixture.self,
			from: Data(contentsOf: fixtureURL)
		)
		#expect(fixture.schemaVersion == 1)
		let backend = Round4ProjectIndexBackend()
		for record in fixture.records {
			backend.seed(account: record.account, value: record.value)
		}
		let original = backend.snapshot
		let service = KeychainService(
			testingService: "project-index-checked-in-fixture",
			backend: backend
		)

		let metadata = try service.listProjectMetadataResult().get()
		let loadedResult = try service.getProjectResult(vaultId: fixture.project.id).get()
		let loaded = try #require(loadedResult)

		#expect(metadata == [VaultProjectMetadata(
			id: fixture.project.id,
			name: fixture.project.name,
			path: fixture.project.path,
			environmentSummaries: fixture.project.environmentSummaries
		)])
		#expect(loaded.name == fixture.project.name)
		#expect(loaded.path == fixture.project.path)
		#expect(loaded.environments == [
			"default": ["TOKEN": "secret"],
			"production": ["API_KEY": "one", "URL": "two"],
		])
		#expect(backend.snapshot == original)
	}

	@Test("metadata-only updates never touch project discovery")
	func existingProjectMutationDoesNotTouchDiscovery() throws {
		let backend = Round4ProjectIndexBackend()
		let service = KeychainService(
			testingService: "project-index-existing-mutation",
			backend: backend
		)
		guard case .success = service.createEnvironments(
			vaultId: "existing-project",
			projectName: "Original",
			projectPath: "/original",
			environments: ["default": ["TOKEN": "old"]]
		) else {
			Issue.record("Could not create the project mutation fixture")
			return
		}
		backend.resetOperationCounts()

		guard case .success = service.saveEnvironments(
			vaultId: "existing-project",
			projectName: "Renamed",
			projectPath: "/renamed",
			environments: [
				"default": ["TOKEN": "new", "URL": "https://example.com"],
				"production": ["TOKEN": "production"],
			]
		) else {
			Issue.record("Could not update the project mutation fixture")
			return
		}

		#expect(backend.operationCount(withPrefix: discoveryPrefix) == 0)
		#expect(backend.readCount(for: "__index__") == 0)
		#expect(backend.writeCount(for: "__index__") == 0)
		let metadata = try service.listProjectMetadataResult().get()
		#expect(metadata.first?.environmentSummaries == [
			VaultProjectEnvironmentSummary(name: "default", keyCount: 2),
			VaultProjectEnvironmentSummary(name: "production", keyCount: 1),
		])
	}

	@Test("project discovery keeps active shards densely packed")
	func projectDiscoveryUsesDenseShards() throws {
		let backend = Round4ProjectIndexBackend()
		let service = KeychainService(
			testingService: "project-index-dense-shards",
			backend: backend
		)
		for index in 0..<1_000 {
			guard case .success = service.createEnvironments(
				vaultId: "dense-\(index)",
				projectName: "Project \(index)",
				projectPath: "",
				environments: ["default": [:]]
			) else {
				Issue.record("Could not create dense-shard fixture \(index)")
				return
			}
		}
		let markerData = try #require(backend.data(for: "__vault_project_index_marker__"))
		let marker = try #require(
			JSONSerialization.jsonObject(with: markerData) as? [String: Any]
		)
		let activeShards = try #require(marker["activeShards"] as? [Int])

		#expect(activeShards.count == 8)
		backend.resetOperationCounts()
		#expect(try service.listProjectMetadataResult().get().count == 1_000)
		#expect(backend.operationCount(withPrefix: discoveryPrefix) == 8)
	}
}

private final class Round4ProjectIndexBackend: KeychainStoreBackend {
	private let lock = NSRecursiveLock()
	private var storage: [String: Data] = [:]
	private var reads: [String: Int] = [:]
	private var writes: [String: Int] = [:]
	private var deletes: [String: Int] = [:]
	private var failingWriteAccounts: [String: Int] = [:]
	private var failingWritePrefixes: [String: Int] = [:]
	private var failingDeleteAccounts: [String: Int] = [:]

	var snapshot: [String: Data] { lock.withLock { storage } }
	var totalReadCount: Int { lock.withLock { reads.values.reduce(0, +) } }

	func data(for account: String) -> Data? {
		lock.withLock { storage[account] }
	}

	func readCount(for account: String) -> Int {
		lock.withLock { reads[account, default: 0] }
	}

	func writeCount(for account: String) -> Int {
		lock.withLock { writes[account, default: 0] }
	}

	func operationCount(withPrefix prefix: String) -> Int {
		lock.withLock {
			reads.filter { $0.key.hasPrefix(prefix) }.values.reduce(0, +)
				+ writes.filter { $0.key.hasPrefix(prefix) }.values.reduce(0, +)
				+ deletes.filter { $0.key.hasPrefix(prefix) }.values.reduce(0, +)
		}
	}

	func resetOperationCounts() {
		lock.withLock {
			reads = [:]
			writes = [:]
			deletes = [:]
		}
	}

	func seed(account: String, value: String) {
		lock.withLock { storage[account] = Data(value.utf8) }
	}

	func read(
		service: String,
		account: String
	) throws -> Data? {
		lock.withLock {
			reads[account, default: 0] += 1
			return storage[account]
		}
	}

	func write(
		service: String,
		account: String,
		data: Data
	) throws {
		try lock.withLock {
			writes[account, default: 0] += 1
			if consumeFailure(for: account, in: &failingWriteAccounts)
				|| consumePrefixFailure(for: account)
			{
				throw KeychainStoreError.status(operation: "write", code: errSecNotAvailable)
			}
			storage[account] = data
		}
	}

	func add(
		service: String,
		account: String,
		data: Data
	) throws {
		try lock.withLock {
			guard storage[account] == nil else {
				throw KeychainStoreError.status(operation: "add", code: errSecDuplicateItem)
			}
			try write(service: service, account: account, data: data)
		}
	}

	func delete(
		service: String,
		account: String
	) throws -> Bool {
		try lock.withLock {
			deletes[account, default: 0] += 1
			if consumeFailure(for: account, in: &failingDeleteAccounts) {
				throw KeychainStoreError.status(operation: "delete", code: errSecNotAvailable)
			}
			return storage.removeValue(forKey: account) != nil
		}
	}

	private func consumePrefixFailure(for account: String) -> Bool {
		for prefix in failingWritePrefixes.keys.sorted() where account.hasPrefix(prefix) {
			if consumeFailure(for: prefix, in: &failingWritePrefixes) { return true }
		}
		return false
	}

	private func consumeFailure(for key: String, in failures: inout [String: Int]) -> Bool {
		guard let remaining = failures[key], remaining > 0 else { return false }
		if remaining == 1 {
			failures.removeValue(forKey: key)
		} else {
			failures[key] = remaining - 1
		}
		return true
	}
}

@Suite("Lazy local project loading regressions", .serialized)
struct LazyLocalProjectLoadingRegressionTests {
	@Test("unlock loads project metadata without decrypting every payload")
	@MainActor
	func unlockLoadsOnlyProjectMetadata() async {
		let keychain = MockKeychainService()
		for index in 0..<500 {
			keychain.envStorage["project-\(index)"] = (
				name: "Project \(index)",
				path: "/project/\(index)",
				environments: ["default": ["TOKEN": String(repeating: "x", count: 4_096)]]
			)
		}
		let store = VaultStore(
			keychainService: keychain,
			biometricService: MockBiometricService(),
			apiService: MockAPIService()
		)

		#expect(await store.loadProjects())

		#expect(store.projects.count == 500)
		#expect(keychain.projectMetadataReadCount == 500)
		#expect(keychain.projectReadCount == 0)
		#expect(keychain.environmentReadCount == 0)
		#expect(store.projects.allSatisfy { !$0.hasLoadedEnvironments })
		#expect(store.projects.allSatisfy { $0.secretCount == 1 })
		#expect(store.workspaceSnapshots.isEmpty)
	}

	@Test("selecting a project loads exactly that payload")
	@MainActor
	func selectedProjectLoadsOnDemand() async {
		let keychain = MockKeychainService()
		keychain.envStorage["first"] = (
			name: "First",
			path: "",
			environments: ["default": ["TOKEN": "first-secret"]]
		)
		keychain.envStorage["second"] = (
			name: "Second",
			path: "",
			environments: ["default": ["TOKEN": "second-secret"]]
		)
		let store = VaultStore(
			keychainService: keychain,
			biometricService: MockBiometricService(),
			apiService: MockAPIService()
		)
		#expect(await store.loadProjects())
		store.isUnlocked = true
		keychain.projectReadCount = 0

		store.selectProject("second")
		await waitUntil {
			store.selectedProject?.secrets(for: "default")["TOKEN"] == "second-secret"
		}

		#expect(keychain.projectReadCount == 1)
		#expect(store.selectedProject?.hasLoadedEnvironments == true)
		#expect(store.projects.first(where: { $0.id == "first" })?.hasLoadedEnvironments == false)
	}

	@Test("the plaintext project cache stays bounded to the current selection")
	@MainActor
	func navigationEvictsThePreviousPlaintext() async {
		let keychain = MockKeychainService()
		keychain.envStorage["first"] = (
			name: "First",
			path: "",
			environments: ["default": ["TOKEN": "first-secret"]]
		)
		keychain.envStorage["second"] = (
			name: "Second",
			path: "",
			environments: ["default": ["TOKEN": "second-secret"]]
		)
		let store = VaultStore(
			keychainService: keychain,
			biometricService: MockBiometricService(),
			apiService: MockAPIService()
		)
		#expect(await store.loadProjects())
		store.isUnlocked = true

		store.selectProject("first")
		await waitUntil {
			store.selectedProject?.secrets(for: "default")["TOKEN"] == "first-secret"
		}
		store.selectProject("second")
		await waitUntil {
			store.selectedProject?.secrets(for: "default")["TOKEN"] == "second-secret"
		}

		#expect(store.projects.filter(\.hasLoadedEnvironments).map(\.id) == ["second"])
		#expect(store.projects.first(where: { $0.id == "first" })?.environments.isEmpty == true)
		#expect(Set(store.workspaceSnapshots.keys).isSubset(of: Set(["second"])))
	}

	@Test("a stale selected-project load cannot publish after navigation")
	@MainActor
	func navigationRejectsAStaleProjectLoad() async {
		let keychain = MockKeychainService()
		keychain.envStorage["first"] = (
			name: "First",
			path: "",
			environments: ["default": ["TOKEN": "first-secret"]]
		)
		keychain.envStorage["second"] = (
			name: "Second",
			path: "",
			environments: ["default": ["TOKEN": "second-secret"]]
		)
		let store = VaultStore(
			keychainService: keychain,
			biometricService: MockBiometricService(),
			apiService: MockAPIService()
		)
		#expect(await store.loadProjects())
		store.isUnlocked = true
		let firstLoadStarted = DispatchSemaphore(value: 0)
		let releaseFirstLoad = DispatchSemaphore(value: 0)
		keychain.blockNextListProjects = {
			firstLoadStarted.signal()
			releaseFirstLoad.wait()
		}

		store.selectProject("first")
		await waitForSemaphore(firstLoadStarted)
		store.selectProject("second")
		releaseFirstLoad.signal()
		await waitUntil {
			store.selectedProject?.secrets(for: "default")["TOKEN"] == "second-secret"
		}

		#expect(store.selectedProjectId == "second")
		#expect(store.projects.filter(\.hasLoadedEnvironments).map(\.id) == ["second"])
		#expect(store.projects.first(where: { $0.id == "first" })?.environments.isEmpty == true)
	}

	@Test("locking clears payloads and all derived plaintext snapshots")
	@MainActor
	func lockClearsEveryLoadedPlaintextArtifact() async {
		let keychain = MockKeychainService()
		keychain.envStorage["project"] = (
			name: "Project",
			path: "",
			environments: ["default": ["TOKEN": "secret"]]
		)
		let store = VaultStore(
			keychainService: keychain,
			biometricService: MockBiometricService(),
			apiService: MockAPIService()
		)
		#expect(await store.loadProjects())
		store.isUnlocked = true
		store.selectProject("project")
		await waitUntil {
			store.selectedProject?.secrets(for: "default")["TOKEN"] == "secret"
		}

		store.lock()

		#expect(store.projects.allSatisfy { !$0.hasLoadedEnvironments })
		#expect(store.projects.allSatisfy { $0.environments.isEmpty })
		#expect(store.workspaceSnapshots.isEmpty)
	}
}

@MainActor
private func waitUntil(
	maximumYields: Int = 100_000,
	_ condition: @MainActor () -> Bool
) async {
	for _ in 0..<maximumYields {
		if condition() { return }
		await Task.yield()
	}
	Issue.record("Timed out while waiting for an asynchronous test condition.")
}

private func waitUntilAsync(
	maximumYields: Int = 100_000,
	_ condition: @Sendable () async -> Bool
) async {
	for _ in 0..<maximumYields {
		if await condition() { return }
		await Task.yield()
	}
	Issue.record("Timed out while waiting for an asynchronous test condition.")
}

private func waitForSemaphore(_ semaphore: DispatchSemaphore) async {
	await withCheckedContinuation { continuation in
		DispatchQueue.global().async {
			semaphore.wait()
			continuation.resume()
		}
	}
}

@MainActor
private func round4SignedInStoreWithMissingAuthority() -> VaultStore {
	let store = VaultStore(
		keychainService: MockKeychainService(),
		biometricService: MockBiometricService(),
		apiService: MockAPIService(),
		authAuthorizationProvider: { _, _ in nil }
	)
	store.currentUser = round4User(orgSlug: "acme")
	store.personalTokens = [round4Token(id: "personal")]
	store.orgTokens = ["acme": [round4Token(id: "organization")]]
	store.projects = [VaultProject(
		id: "account-project",
		name: "Account",
		path: "",
		environments: ["default": ["TOKEN": "secret"]]
	)]
	store.vaultOrgAssociations = ["account-project": "acme"]
	store.isUnlocked = true
	store.selectAccount(.org("acme"))
	store.selectProject("account-project")
	store.lastSyncStatus = "previous"
	return store
}

@MainActor
private func round4ExpectSignedOut(_ store: VaultStore) {
	#expect(store.currentUser == nil)
	#expect(store.personalTokens.isEmpty)
	#expect(store.orgTokens.isEmpty)
	#expect(store.selectedAccount == .personal)
	#expect(store.lastSyncStatus == nil)
}

private func round4Credentials() -> AuthSessionCredentials {
	AuthSessionCredentials(
		token: "new-access",
		refreshToken: "new-refresh",
		expiresIn: 3_600,
		expiresAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(3_600))
	)
}

private final class SequencedIdentityAPI: LPMAPIServiceProtocol, @unchecked Sendable {
	private let lock = NSLock()
	private var responses: [LPMAPIResult<LPMUser>]

	init(responses: [LPMAPIResult<LPMUser>]) {
		self.responses = responses
	}

	func fetchCurrentUser(authToken: String) async -> LPMAPIResult<LPMUser> {
		_ = authToken
		return lock.withLock { responses.removeFirst() }
	}

	func fetchPersonalTokens(authToken: String) async -> LPMAPIResult<[LPMToken]> {
		_ = authToken
		return .success([])
	}

	func revokePersonalToken(id: String, authToken: String) async -> LPMAPIResult<Void> {
		_ = id
		_ = authToken
		return .success(())
	}

	func fetchOrgTokens(orgSlug: String, authToken: String) async -> LPMAPIResult<[LPMToken]> {
		_ = orgSlug
		_ = authToken
		return .success([])
	}

	func revokeOrgToken(
		orgSlug: String,
		id: String,
		authToken: String
	) async -> LPMAPIResult<Void> {
		_ = orgSlug
		_ = id
		_ = authToken
		return .success(())
	}
}

private final class Round4Counter: @unchecked Sendable {
	private let lock = NSLock()
	private var storage = 0

	var value: Int { lock.withLock { storage } }

	func increment() {
		lock.withLock { storage += 1 }
	}

	func reset() {
		lock.withLock { storage = 0 }
	}
}

private final class Round4ThreadObservation: @unchecked Sendable {
	private let lock = NSLock()
	private var storage = false

	var wasMainThread: Bool { lock.withLock { storage } }

	func recordMainThread(_ value: Bool) {
		lock.withLock { storage = value }
	}
}

private final class Round4MutableBool: @unchecked Sendable {
	private let lock = NSLock()
	private var storage: Bool

	init(_ value: Bool) {
		storage = value
	}

	var value: Bool {
		get { lock.withLock { storage } }
		set { lock.withLock { storage = newValue } }
	}
}

private final class Round4MutableInt: @unchecked Sendable {
	private let lock = NSLock()
	private var storage: Int?

	var value: Int? {
		get { lock.withLock { storage } }
		set { lock.withLock { storage = newValue } }
	}
}

private final class Round4IntRecorder: @unchecked Sendable {
	private let lock = NSLock()
	private var storage: [Int] = []

	var values: [Int] { lock.withLock { storage } }

	func append(_ value: Int) {
		lock.withLock { storage.append(value) }
	}
}

private final class Round4MutableAuthorization: @unchecked Sendable {
	private let lock = NSLock()
	private var token: String
	private var generation: AuthSessionAuthorityGeneration

	init(token: String, generation: AuthSessionAuthorityGeneration) {
		self.token = token
		self.generation = generation
	}

	var current: AuthSessionAuthorization {
		lock.withLock {
			AuthSessionAuthorization(token: token, authorityGeneration: generation)
		}
	}

	func isCurrent(_ value: AuthSessionAuthorityGeneration) -> Bool {
		lock.withLock { generation == value }
	}

	func replace(token: String, generation: AuthSessionAuthorityGeneration) {
		lock.withLock {
			self.token = token
			self.generation = generation
		}
	}
}

private enum Round5TestError: Error {
	case failed
}

private final class Round5GatedAuthorization: @unchecked Sendable {
	private let lock = NSLock()
	private var authorization: AuthSessionAuthorization
	private var nextGate: Round4AsyncGate?

	init(token: String, generation: AuthSessionAuthorityGeneration) {
		authorization = AuthSessionAuthorization(
			token: token,
			authorityGeneration: generation
		)
	}

	func gateNextResolution(on gate: Round4AsyncGate) {
		lock.withLock { nextGate = gate }
	}

	func resolve() async -> AuthSessionAuthorization {
		let snapshot = lock.withLock { () -> (AuthSessionAuthorization, Round4AsyncGate?) in
			let gate = nextGate
			nextGate = nil
			return (authorization, gate)
		}
		await snapshot.1?.arriveAndWait()
		return snapshot.0
	}

	func isCurrent(_ generation: AuthSessionAuthorityGeneration) -> Bool {
		lock.withLock { authorization.authorityGeneration == generation }
	}

	func replace(token: String, generation: AuthSessionAuthorityGeneration) {
		lock.withLock {
			authorization = AuthSessionAuthorization(
				token: token,
				authorityGeneration: generation
			)
		}
	}
}

private final class Round6GatedOptionalAuthorization: @unchecked Sendable {
	private let lock = NSLock()
	private var authorization: AuthSessionAuthorization?
	private var nextResolution: (AuthSessionAuthorization?, Round4AsyncGate)?

	init(token: String, generation: AuthSessionAuthorityGeneration) {
		authorization = AuthSessionAuthorization(
			token: token,
			authorityGeneration: generation
		)
	}

	func gateNextResolution(
		returning resolution: AuthSessionAuthorization?,
		on gate: Round4AsyncGate
	) {
		lock.withLock { nextResolution = (resolution, gate) }
	}

	func resolve() async -> AuthSessionAuthorization? {
		let snapshot = lock.withLock {
			() -> (AuthSessionAuthorization?, Round4AsyncGate?) in
			guard let nextResolution else { return (authorization, nil) }
			self.nextResolution = nil
			return nextResolution
		}
		await snapshot.1?.arriveAndWait()
		return snapshot.0
	}

	func isCurrent(_ generation: AuthSessionAuthorityGeneration) -> Bool {
		lock.withLock { authorization?.authorityGeneration == generation }
	}

	func replace(token: String, generation: AuthSessionAuthorityGeneration) {
		lock.withLock {
			authorization = AuthSessionAuthorization(
				token: token,
				authorityGeneration: generation
			)
		}
	}
}

private final class Round5StartObservingPersonalSyncService:
	PersonalSyncServiceProtocol, @unchecked Sendable
{
	private let lock = NSLock()
	private let insideCredentialLock: Round4MutableBool
	private var preparations = 0
	private var pushes = 0
	private var preparationInsideCredentialLock = false

	init(insideCredentialLock: Round4MutableBool) {
		self.insideCredentialLock = insideCredentialLock
	}

	var prepareCallCount: Int { lock.withLock { preparations } }
	var pushCallCount: Int { lock.withLock { pushes } }
	var observedPreparationInsideCredentialLock: Bool {
		lock.withLock { preparationInsideCredentialLock }
	}

	func pull(authToken: String, vaultId: String) async -> SyncService.SyncStatus? {
		_ = authToken
		_ = vaultId
		return nil
	}

	func versionPreflightAuthenticated(
		authToken: String,
		vaultId: String
	) async -> SyncService.AuthenticatedResponse<SyncService.VersionPreflight> {
		_ = authToken
		_ = vaultId
		return .response(.notFound)
	}

	func push(
		authToken: String,
		expectedPrincipalId: String,
		vaultId: String,
		encryptedBlob: String,
		wrappedKey: String,
		expectedVersion: Int?,
		force: Bool,
		recreateMissing: Bool,
		name: String?,
		schema: LPMJSONValue?
	) async -> SyncService.SyncStatus? {
		_ = authToken
		_ = expectedPrincipalId
		_ = encryptedBlob
		_ = wrappedKey
		_ = expectedVersion
		_ = force
		_ = recreateMissing
		_ = name
		_ = schema
		lock.withLock { pushes += 1 }
		return SyncService.SyncStatus(
			vaultId: vaultId,
			version: 1,
			cryptoVersion: VaultCrypto.currentCryptoVersion,
			contentKeyVersion: nil,
			recipientPublicKeyVersion: nil,
			recipientPublicKeyFingerprint: nil,
			status: "ok",
			error: nil,
			code: nil,
			serverVersion: nil,
			hint: nil,
			encryptedBlob: nil,
			wrappedKey: nil,
			updatedAt: nil
		)
	}

	func preparePushAuthenticated(
		authToken: String,
		expectedPrincipalId: String,
		vaultId: String,
		encryptedBlob: String,
		wrappedKey: String,
		expectedVersion: Int?,
		force: Bool,
		recreateMissing: Bool,
		name: String?,
		schema: LPMJSONValue?
	) async -> PreparedRemoteOperation<SyncService.AuthenticatedResponse<SyncService.SyncStatus>> {
		lock.withLock {
			preparations += 1
			preparationInsideCredentialLock = insideCredentialLock.value
		}
		return PreparedRemoteOperation {
			.run { [self] in
				.response(await push(
					authToken: authToken,
					expectedPrincipalId: expectedPrincipalId,
					vaultId: vaultId,
					encryptedBlob: encryptedBlob,
					wrappedKey: wrappedKey,
					expectedVersion: expectedVersion,
					force: force,
					recreateMissing: recreateMissing,
					name: name,
					schema: schema
				))
			}
		}
	}
}

private final class Round5GatedPreparationPersonalSyncService:
	PersonalSyncServiceProtocol, @unchecked Sendable
{
	private let lock = NSLock()
	private let gate: Round4AsyncGate
	private var preparedStarts = 0

	init(gate: Round4AsyncGate) {
		self.gate = gate
	}

	var preparedStartCallCount: Int { lock.withLock { preparedStarts } }

	func pull(authToken: String, vaultId: String) async -> SyncService.SyncStatus? {
		_ = authToken
		_ = vaultId
		return nil
	}

	func versionPreflightAuthenticated(
		authToken: String,
		vaultId: String
	) async -> SyncService.AuthenticatedResponse<SyncService.VersionPreflight> {
		_ = authToken
		_ = vaultId
		return .response(.notFound)
	}

	func push(
		authToken: String,
		expectedPrincipalId: String,
		vaultId: String,
		encryptedBlob: String,
		wrappedKey: String,
		expectedVersion: Int?,
		force: Bool,
		recreateMissing: Bool,
		name: String?,
		schema: LPMJSONValue?
	) async -> SyncService.SyncStatus? {
		_ = authToken
		_ = expectedPrincipalId
		_ = vaultId
		_ = encryptedBlob
		_ = wrappedKey
		_ = expectedVersion
		_ = force
		_ = recreateMissing
		_ = name
		_ = schema
		return nil
	}

	func preparePushAuthenticated(
		authToken: String,
		expectedPrincipalId: String,
		vaultId: String,
		encryptedBlob: String,
		wrappedKey: String,
		expectedVersion: Int?,
		force: Bool,
		recreateMissing: Bool,
		name: String?,
		schema: LPMJSONValue?
	) async -> PreparedRemoteOperation<
		SyncService.AuthenticatedResponse<SyncService.SyncStatus>
	> {
		_ = authToken
		_ = expectedPrincipalId
		_ = vaultId
		_ = encryptedBlob
		_ = wrappedKey
		_ = expectedVersion
		_ = force
		_ = recreateMissing
		_ = name
		_ = schema
		await gate.arriveAndWait()
		return PreparedRemoteOperation { [self] in
			lock.withLock { preparedStarts += 1 }
			return .completed(.response(nil))
		}
	}
}

private final class Round4InvalidatingAuthorityValidator: @unchecked Sendable {
	private let lock = NSLock()
	private var isCurrent = true
	private var invalidateOnNextCheck = false

	func validate(_ generation: AuthSessionAuthorityGeneration) -> Bool {
		_ = generation
		return lock.withLock {
			guard isCurrent else { return false }
			if invalidateOnNextCheck {
				invalidateOnNextCheck = false
				isCurrent = false
			}
			return true
		}
	}

	func invalidateAfterNextSuccessfulCheck() {
		lock.withLock { invalidateOnNextCheck = true }
	}

	func isCurrent(_ generation: AuthSessionAuthorityGeneration) -> Bool {
		_ = generation
		return lock.withLock { isCurrent }
	}
}

private final class Round4GatedImportService: EnvProjectImportServiceProtocol, @unchecked Sendable {
	private let gate: Round4AsyncGate

	init(gate: Round4AsyncGate) {
		self.gate = gate
	}

	func loadPersonal(authToken: String, vaultId: String) async throws -> RemoteEnvProjectPayload {
		_ = authToken
		await gate.arriveAndWait()
		return RemoteEnvProjectPayload(
			vaultId: vaultId,
			environments: ["default": ["TOKEN": "account-a-secret"]],
			version: 1,
			keyCount: 1,
			principalID: "account-a"
		)
	}

	func loadOrganization(
		authToken: String,
		orgSlug: String,
		vaultId: String,
		expectedCallerUserID: String
	) async throws -> RemoteEnvProjectPayload {
		_ = authToken
		_ = orgSlug
		_ = expectedCallerUserID
		await gate.arriveAndWait()
		return RemoteEnvProjectPayload(
			vaultId: vaultId,
			environments: ["default": ["TOKEN": "account-a-secret"]],
			version: 1,
			keyCount: 1,
			principalID: "organization"
		)
	}
}

private final class Round4ImmediateImportService: EnvProjectImportServiceProtocol, @unchecked Sendable {
	private let lock = NSLock()
	private var calls = 0

	var callCount: Int { lock.withLock { calls } }

	func loadPersonal(authToken: String, vaultId: String) async throws -> RemoteEnvProjectPayload {
		_ = authToken
		lock.withLock { calls += 1 }
		return RemoteEnvProjectPayload(
			vaultId: vaultId,
			environments: ["default": ["TOKEN": "cloud"]],
			version: 1,
			keyCount: 1,
			principalID: "account-a"
		)
	}

	func loadOrganization(
		authToken: String,
		orgSlug: String,
		vaultId: String,
		expectedCallerUserID: String
	) async throws -> RemoteEnvProjectPayload {
		_ = authToken
		_ = orgSlug
		_ = expectedCallerUserID
		lock.withLock { calls += 1 }
		return RemoteEnvProjectPayload(
			vaultId: vaultId,
			environments: ["default": ["TOKEN": "cloud"]],
			version: 1,
			keyCount: 1,
			principalID: "organization"
		)
	}
}

private final class Round4GatedProjectListService: ProjectListServiceProtocol, @unchecked Sendable {
	private let gate: Round4AsyncGate

	init(gate: Round4AsyncGate) {
		self.gate = gate
	}

	func listPersonalProjects(
		authToken: String
	) async -> Result<[SyncService.RemoteProject], SyncService.ProjectListError> {
		_ = authToken
		await gate.arriveAndWait()
		return .success([round4RemoteProject()])
	}

	func listOrgProjects(
		authToken: String,
		orgSlug: String
	) async -> Result<[SyncService.RemoteProject], SyncService.ProjectListError> {
		_ = orgSlug
		return await listPersonalProjects(authToken: authToken)
	}
}

private final class Round4ProjectListRecorder: ProjectListServiceProtocol, @unchecked Sendable {
	private let lock = NSLock()
	private let result: Result<[SyncService.RemoteProject], SyncService.ProjectListError>
	private var calls = 0

	init(
		result: Result<[SyncService.RemoteProject], SyncService.ProjectListError> =
			.success([round4RemoteProject()])
	) {
		self.result = result
	}

	var callCount: Int { lock.withLock { calls } }

	func listPersonalProjects(
		authToken: String
	) async -> Result<[SyncService.RemoteProject], SyncService.ProjectListError> {
		_ = authToken
		lock.withLock { calls += 1 }
		return result
	}

	func listOrgProjects(
		authToken: String,
		orgSlug: String
	) async -> Result<[SyncService.RemoteProject], SyncService.ProjectListError> {
		_ = orgSlug
		return await listPersonalProjects(authToken: authToken)
	}
}

private final class Round4ExportTracker: @unchecked Sendable {
	private let lock = NSLock()
	private let releaseGate = DispatchSemaphore(value: 0)
	private var active = 0
	private var started = 0
	private var maximum = 0

	var maximumActive: Int { lock.withLock { maximum } }

	func enter(index: Int) {
		_ = index
		lock.withLock {
			active += 1
			started += 1
			maximum = max(maximum, active)
		}
	}

	func leave() {
		lock.withLock { active -= 1 }
	}

	func waitForRelease() {
		releaseGate.wait()
	}

	func release(_ count: Int) {
		for _ in 0..<count { releaseGate.signal() }
	}

	func waitUntilStarted(_ count: Int) async {
		for _ in 0..<100_000 {
			if lock.withLock({ started >= count }) { return }
			await Task.yield()
		}
		Issue.record("Timed out waiting for export workers.")
	}
}

private actor Round4AsyncGate {
	private var arrived = false
	private var released = false
	private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []
	private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

	func waitUntilArrived() async {
		guard !arrived else { return }
		await withCheckedContinuation { arrivalWaiters.append($0) }
	}

	func arriveAndWait() async {
		arrived = true
		arrivalWaiters.forEach { $0.resume() }
		arrivalWaiters.removeAll()
		guard !released else { return }
		await withCheckedContinuation { releaseWaiters.append($0) }
	}

	func release() {
		released = true
		releaseWaiters.forEach { $0.resume() }
		releaseWaiters.removeAll()
	}
}

private actor Round4TokenProvider {
	private var token: String?
	private var gate: Round4AsyncGate?

	init(token: String?) {
		self.token = token
	}

	func set(token: String?, gate: Round4AsyncGate?) {
		self.token = token
		self.gate = gate
	}

	func resolve() async -> String? {
		let resolved = token
		let currentGate = gate
		await currentGate?.arriveAndWait()
		return resolved
	}
}

private actor Round4AsyncLock {
	private var held = false
	private var waiters: [CheckedContinuation<Void, Never>] = []

	func acquire() async {
		guard held else {
			held = true
			return
		}
		await withCheckedContinuation { waiters.append($0) }
	}

	func release() {
		guard !waiters.isEmpty else {
			held = false
			return
		}
		waiters.removeFirst().resume()
	}
}

private final class Round4AuthorizedPullSerialiser: @unchecked Sendable {
	private let lock = Round4AsyncLock()
	private let authorization: Round4MutableAuthorization
	private let stateLock = NSLock()
	private var didRotate = false

	init(authorization: Round4MutableAuthorization) {
		self.authorization = authorization
	}

	var rotationCompleted: Bool { stateLock.withLock { didRotate } }

	func withCurrent(
		_ generation: AuthSessionAuthorityGeneration,
		operation: @escaping @Sendable () async -> PullPersistenceResult
	) async -> PullPersistenceResult? {
		await lock.acquire()
		guard authorization.isCurrent(generation) else {
			await lock.release()
			return nil
		}
		let result = await operation()
		await lock.release()
		return result
	}

	func rotate(token: String, generation: AuthSessionAuthorityGeneration) async {
		await lock.acquire()
		authorization.replace(token: token, generation: generation)
		stateLock.withLock { didRotate = true }
		await lock.release()
	}
}

private func round4AuthorityGeneration(seed: UInt64 = 1) -> AuthSessionAuthorityGeneration {
	AuthSessionAuthorityGeneration(
		device: seed,
		inode: seed,
		size: 1,
		modifiedSeconds: 1,
		modifiedNanoseconds: 1,
		changedSeconds: 1,
		changedNanoseconds: 1
	)
}

private func round4Session(from service: Any) -> URLSession? {
	Mirror(reflecting: service).children.first { $0.label == "session" }?.value as? URLSession
}

private func round4RemoteProject() -> SyncService.RemoteProject {
	SyncService.RemoteProject(
		vaultId: "remote",
		name: "Remote",
		version: 1,
		updatedAt: nil,
		updatedBy: nil
	)
}

private func round4Token(id: String) -> LPMToken {
	LPMToken(
		id: id,
		name: id,
		scope: nil,
		expiresAt: nil,
		lastUsedAt: nil,
		downloadCount: nil,
		createdAt: nil,
		orgSlug: nil
	)
}

private func round4SyncStatus(
	vaultId: String,
	version: Int,
	contentKeyVersion: Int,
	recipientPublicKeyVersion: Int,
	recipientPublicKeyFingerprint: String,
	encryptedBlob: String,
	wrappedKey: String
) -> SyncService.SyncStatus {
	SyncService.SyncStatus(
		vaultId: vaultId,
		version: version,
		cryptoVersion: VaultCrypto.currentCryptoVersion,
		contentKeyVersion: contentKeyVersion,
		recipientPublicKeyVersion: recipientPublicKeyVersion,
		recipientPublicKeyFingerprint: recipientPublicKeyFingerprint,
		status: "ok",
		error: nil,
		code: nil,
		serverVersion: version,
		hint: nil,
		encryptedBlob: encryptedBlob,
		wrappedKey: wrappedKey,
		updatedAt: nil,
		principalId: "organization",
		callerUserId: "account-a",
		organizationId: "organization"
	)
}

@MainActor
private func round4PersonalConflictFixture(
	projectID: String,
	localVersion: Int,
	response: SyncService.SyncStatus
) throws -> (
	store: VaultStore,
	sync: MockPersonalSyncService,
	encryptionCalls: Round4MutableInt
) {
	let binding = SyncPrincipalBinding(
		registryURL: "https://lpm.dev",
		principalID: "account-a",
		scope: "personal"
	)
	let metadata = SyncMetadata(
		lastSyncedAt: Date(timeIntervalSince1970: 1),
		lastAction: "pull",
		lastVersion: localVersion,
		isDirty: true,
		binding: binding
	)
	let sync = MockPersonalSyncService()
	sync.pushHandlers = [{ response }]
	let encryptionCalls = Round4MutableInt()
	encryptionCalls.value = 0
	let keychain = MockKeychainService()
	keychain.envStorage[projectID] = (
		name: "Personal",
		path: "",
		environments: ["default": ["TOKEN": "local"]]
	)
	#expect(keychain.seedSyncMetadata([projectID: metadata]))
	let store = VaultStore(
		keychainService: keychain,
		biometricService: MockBiometricService(),
		apiService: MockAPIService(),
		personalSyncServiceFactory: { _ in sync },
		stableSyncEncryptor: { _, _, _, _ in
			encryptionCalls.value = (encryptionCalls.value ?? 0) + 1
			return ("ciphertext", "wrapped-key")
		},
		authTokenProvider: { _, _ in "session-token" }
	)
	store.appEnvironment = .production
	store.projects = [VaultProject(
		id: projectID,
		name: "Personal",
		path: "",
		environments: ["default": ["TOKEN": "local"]]
	)]
	store.syncMetadata = [projectID: metadata]
	store.currentUser = round4User(id: "account-a", orgSlug: "acme")
	store.isUnlocked = true
	store.selectProject(projectID)
	return (store, sync, encryptionCalls)
}

private func round4User(
	id: String = "account-a",
	orgSlug: String,
	organizationID: String = "organization"
) -> LPMUser {
	LPMUser(
		id: id,
		username: id,
		name: nil,
		email: nil,
		avatarUrl: nil,
		plan: nil,
		createdAt: nil,
		orgs: [LPMOrg(
			id: organizationID,
			slug: orgSlug,
			name: "Organization",
			avatarUrl: nil,
			role: "admin"
		)]
	)
}
