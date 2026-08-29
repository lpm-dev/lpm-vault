import AppKit
import Foundation
import Testing

@testable import LPMVault

@Suite("End-to-end audit regressions", .serialized)
struct AuditRegressionTests {
	@Test("dotenv export remains literal when sourced and preserves edge tabs")
	func shellSafeLosslessDotenvExport() throws {
		let directory = FileManager.default.temporaryDirectory
			.appendingPathComponent(UUID().uuidString, isDirectory: true)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: directory) }
		let marker = directory.appendingPathComponent("expanded")
		let source = [
			"PAYLOAD": "$(touch \(marker.path))",
			"BACKTICK": "`touch \(marker.path)`",
			"VARIABLE": "$HOME",
			"TABS": "\tkeep\t",
		]
		let formatted = EnvFileCodec.format(source)
		#expect(try EnvFileCodec.parse(formatted) == source)

		let file = directory.appendingPathComponent("export.env")
		try Data(formatted.utf8).write(to: file)
		let process = Process()
		let output = Pipe()
		process.executableURL = URL(fileURLWithPath: "/bin/sh")
		process.arguments = [
			"-c",
			#". "$1"; printf '%s\n%s\n%s\n' "$PAYLOAD" "$BACKTICK" "$VARIABLE""#,
			"audit-shell",
			file.path,
		]
		process.standardOutput = output
		try process.run()
		process.waitUntilExit()
		let rendered = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
		#expect(process.terminationStatus == 0)
		#expect(rendered == "\(source["PAYLOAD"]!)\n\(source["BACKTICK"]!)\n\(source["VARIABLE"]!)\n")
		#expect(!FileManager.default.fileExists(atPath: marker.path))
	}

	@Test("token expiry accepts fractional RFC3339 and treats an elapsed instant as expired")
	func tokenExpiryParsingAndClassification() throws {
		let now = Date()
		let fractional = now.addingTimeInterval(3_600).formatted(
			Date.ISO8601FormatStyle(includingFractionalSeconds: true)
		)
		let future = LPMToken(
			id: "future", name: "future", scope: nil, expiresAt: fractional,
			lastUsedAt: nil, downloadCount: nil, createdAt: nil
		)
		#expect(future.expiresDate != nil)

		let justExpired = ISO8601DateFormatter().string(from: now.addingTimeInterval(-1))
		let expired = LPMToken(
			id: "expired", name: "expired", scope: nil, expiresAt: justExpired,
			lastUsedAt: nil, downloadCount: nil, createdAt: nil
		)
		#expect(expired.expiryStatus == .expired)
	}

	@Test("semantically equal release versions do not produce an update")
	@MainActor
	func numericReleaseComparison() async throws {
		#expect(UpdateChecker.isNewerVersion("1.10.0", than: "1.9.0"))
		#expect(!UpdateChecker.isNewerVersion("1.9.0", than: "1.10.0"))
		#expect(!UpdateChecker.isNewerVersion("2.0", than: "2.0.0"))

		struct Cache: Encodable {
			let version: String
			let checkedAt: Date
		}
		let defaults = UserDefaults.standard
		let key = "lpm-vault-update-check"
		let previous = defaults.data(forKey: key)
		defer {
			if let previous { defaults.set(previous, forKey: key) } else { defaults.removeObject(forKey: key) }
		}
		let checker = UpdateChecker()
		var equivalentFields = checker.currentVersion.split(separator: ".").map(String.init)
		#expect(equivalentFields.count == 3)
		equivalentFields[1] = "0" + equivalentFields[1]
		let equivalent = equivalentFields.joined(separator: ".")
		defaults.set(
			try JSONEncoder().encode(Cache(version: equivalent, checkedAt: Date())),
			forKey: key
		)
		await checker.checkForUpdate()
		#expect(checker.latestVersion == equivalent)
		#expect(!checker.updateAvailable)
	}

	@Test("a wholly empty cloud payload has a durable default environment")
	func emptyCloudPayloadNormalization() throws {
		let decoded = try EnvValidation.decodeRemoteEnvironments(
			Data(#"{"environments":{}}"#.utf8)
		)
		#expect(decoded == ["default": [:]])
	}

	@Test("a corrupt metadata snapshot does not replace the last coherent state")
	@MainActor
	func corruptMetadataFailsClosed() async {
		let keychain = MockKeychainService()
		keychain.envStorage["project"] = (
			name: "Project", path: "", environments: ["default": ["TOKEN": "secret"]]
		)
		keychain.dataStorage["__sync_metadata__"] = Data("not-json".utf8)
		let store = VaultStore(
			keychainService: keychain,
			biometricService: MockBiometricService(),
			apiService: MockAPIService()
		)
		store.projects = [
			VaultProject(
				id: "previous", name: "Previous", path: "",
				environments: ["default": ["OLD": "value"]]
			)
		]
		store.syncMetadata = ["previous": SyncMetadata(lastVersion: 9)]

		let loaded = await store.loadProjects()

		#expect(!loaded)
		#expect(store.projects.map(\.id) == ["previous"])
		#expect(store.syncMetadata["previous"]?.lastVersion == 9)
		#expect(store.error != nil)
	}

	@Test("a corrupt organization association does not reroute the last coherent state")
	@MainActor
	func corruptOrganizationAssociationFailsClosed() async {
		let keychain = MockKeychainService()
		keychain.envStorage["project"] = (
			name: "Project", path: "", environments: ["default": ["TOKEN": "secret"]]
		)
		keychain.dataStorage["__org_associations__"] = Data("not-json".utf8)
		let store = VaultStore(
			keychainService: keychain,
			biometricService: MockBiometricService(),
			apiService: MockAPIService()
		)
		store.projects = [VaultProject(
			id: "previous", name: "Previous", path: "",
			environments: ["default": ["OLD": "value"]]
		)]
		store.vaultOrgAssociations = ["previous": "trusted-org"]

		let loaded = await store.loadProjects()

		#expect(!loaded)
		#expect(store.projects.map(\.id) == ["previous"])
		#expect(store.vaultOrgAssociations == ["previous": "trusted-org"])
		#expect(store.error != nil)
	}

	@Test("a project read failure does not fabricate an empty vault")
	@MainActor
	func projectReadFailureFailsClosed() async {
		let keychain = MockKeychainService()
		keychain.failProjectReads = true
		keychain.failureError = .keychainLocked
		let store = VaultStore(
			keychainService: keychain,
			biometricService: MockBiometricService(),
			apiService: MockAPIService()
		)
		store.projects = [
			VaultProject(
				id: "coherent", name: "Coherent", path: "",
				environments: ["default": ["TOKEN": "retained"]]
			)
		]

		#expect(!(await store.loadProjects()))
		#expect(store.projects.first?.secrets["TOKEN"] == "retained")
		#expect(store.error?.contains("Keychain") == true)
	}

	@Test("single-project mutation reads only its target project")
	func directProjectPersistenceRead() async {
		let keychain = MockKeychainService()
		for index in 0..<100 {
			keychain.envStorage["project-\(index)"] = (
				name: "Project \(index)", path: "",
				environments: ["default": ["EXISTING": "value"]]
			)
		}
		let persistence = VaultPersistenceCoordinator(service: keychain)

		let result = await persistence.addSecret(
			projectId: "project-42",
			projectName: "Project 42",
			projectPath: "",
			environment: "default",
			key: "NEW",
			value: "value"
		)

		guard case .success = result else {
			Issue.record("The direct project mutation failed: \(result)")
			return
		}
		#expect(keychain.projectReadCount == 1)
		#expect(keychain.environmentReadCount == 0)
	}

	@Test("single-project writes propagate protected read failures without saving")
	func directProjectReadFailureDoesNotWrite() async {
		let keychain = MockKeychainService()
		keychain.envStorage["project"] = (
			name: "Project", path: "", environments: ["default": ["TOKEN": "original"]]
		)
		keychain.failProjectReads = true
		keychain.failureError = .keychainLocked
		let persistence = VaultPersistenceCoordinator(service: keychain)

		let addition = await persistence.addSecret(
			projectId: "project",
			projectName: "Project",
			projectPath: "",
			environment: "default",
			key: "NEW",
			value: "value"
		)
		guard case .failure(.keychainLocked) = addition else {
			Issue.record("Expected the protected read error, got \(addition)")
			return
		}

		let (_, mergedSave) = await persistence.save(
			vaultId: "project",
			name: "Project",
			path: "",
			environments: ["default": ["REPLACEMENT": "unsafe"]],
			mergeExisting: true
		)
		guard case .failure(.keychainLocked) = mergedSave else {
			Issue.record("Expected the merge read error, got \(mergedSave)")
			return
		}

		#expect(keychain.saveEnvironmentsCallCount == 0)
		#expect(keychain.envStorage["project"]?.environments["default"] == ["TOKEN": "original"])
	}

	@Test("wrapping-key file inspection distinguishes absence from unsafe existence")
	func wrappingKeyFileStates() throws {
		let directory = FileManager.default.temporaryDirectory
			.appendingPathComponent(UUID().uuidString, isDirectory: true)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: directory) }
		let file = directory.appendingPathComponent(".vault-key")
		#expect(VaultCrypto.inspectStableWrappingKeyFile(at: file) == .absent)

		let key = Data((0..<32).map(UInt8.init))
		let encoded = key.map { String(format: "%02x", $0) }.joined()
		try Data(encoded.utf8).write(to: file)
		try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
		#expect(VaultCrypto.inspectStableWrappingKeyFile(at: file) == .valid(key))

		try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
		#expect(VaultCrypto.inspectStableWrappingKeyFile(at: file) == .unsafe)

		try FileManager.default.removeItem(at: file)
		try FileManager.default.createSymbolicLink(
			at: file,
			withDestinationURL: directory.appendingPathComponent("missing")
		)
		#expect(VaultCrypto.inspectStableWrappingKeyFile(at: file) == .unsafe)
	}

	@Test("avatar URLs and decoded dimensions are bounded by an allowlist")
	func avatarPolicyAndDimensions() throws {
		#expect(AvatarURLPolicy.validatedURL("https://avatars.githubusercontent.com/u/1?v=4") != nil)
		#expect(AvatarURLPolicy.validatedURL("https://lpm.dev/avatar/user") != nil)
		for rejected in [
			"http://avatars.githubusercontent.com/u/1",
			"https://127.0.0.1/avatar",
			"https://localhost/avatar",
			"file:///etc/passwd",
			"https://lpm.dev:8443/avatar",
			"https://tracker.example/avatar",
		] {
			#expect(AvatarURLPolicy.validatedURL(rejected) == nil)
		}

		let smallBitmap = try #require(NSBitmapImageRep(
			bitmapDataPlanes: nil,
			pixelsWide: 1,
			pixelsHigh: 1,
			bitsPerSample: 8,
			samplesPerPixel: 4,
			hasAlpha: true,
			isPlanar: false,
			colorSpaceName: .deviceRGB,
			bytesPerRow: 0,
			bitsPerPixel: 0
		))
		let small = try #require(smallBitmap.representation(using: .png, properties: [:]))
		#expect(SecureAvatarLoader.isSafeImageData(small))

		let wideBitmap = try #require(NSBitmapImageRep(
			bitmapDataPlanes: nil,
			pixelsWide: SecureAvatarLoader.maximumPixelDimension + 1,
			pixelsHigh: 1,
			bitsPerSample: 8,
			samplesPerPixel: 4,
			hasAlpha: true,
			isPlanar: false,
			colorSpaceName: .deviceRGB,
			bytesPerRow: 0,
			bitsPerPixel: 0
		))
		let wide = try #require(wideBitmap.representation(using: .png, properties: [:]))
		#expect(!SecureAvatarLoader.isSafeImageData(wide))
		#expect(!SecureAvatarLoader.isSafeImageData(
			Data(repeating: 0, count: SecureAvatarLoader.maximumResponseBytes + 1)
		))
	}

	@Test("organization approval arrays must exactly match the displayed bindings")
	func exactOrganizationApprovals() {
		let first = PendingKeyApproval(
			memberId: "one", fingerprint: "fingerprint-one",
			isNewMember: true, oldFingerprint: nil
		)
		let second = PendingKeyApproval(
			memberId: "two", fingerprint: "fingerprint-two",
			isNewMember: false, oldFingerprint: "old"
		)
		let forged = PendingKeyApproval(
			memberId: "two", fingerprint: "attacker",
			isNewMember: false, oldFingerprint: "old"
		)

		#expect(PendingKeyApproval.exactlyMatches([second, first], pending: [first, second]))
		#expect(!PendingKeyApproval.exactlyMatches([first], pending: [first, second]))
		#expect(!PendingKeyApproval.exactlyMatches([first, forged], pending: [first, second]))
	}

	@Test("secret drafts refresh when clean and block stale saves after a conflict")
	func secretDraftConflictHandling() {
		var clean = VaultSecretEditDraft(value: "old")
		clean.receiveExternalValue("external")
		#expect(clean.draft == "external")
		#expect(!clean.isDirty)
		#expect(!clean.hasExternalConflict)

		var edited = VaultSecretEditDraft(value: "old")
		edited.draft = "local-edit"
		edited.receiveExternalValue("external")
		#expect(edited.draft == "local-edit")
		#expect(edited.hasExternalConflict)
		#expect(!edited.canSave)
		#expect(edited.canRevert)
		edited.revert()
		#expect(edited.draft == "external")
		#expect(!edited.hasExternalConflict)

		var pendingSave = VaultSecretEditDraft(value: "old")
		pendingSave.draft = "requested"
		#expect(pendingSave.canSave)
		pendingSave.receiveExternalValue("old")
		#expect(pendingSave.canSave)
		pendingSave.receiveExternalValue("requested")
		#expect(!pendingSave.isDirty)
		#expect(!pendingSave.hasExternalConflict)
	}

	@Test("personal push rejects missing, non-positive versions and mismatched vault identities")
	@MainActor
	func personalPushResponseBinding() async {
		func run(
			_ response: SyncService.SyncStatus,
			localVersion: Int? = nil
		) async -> VaultStore {
			let sync = MockPersonalSyncService()
			sync.pushHandlers = [{ response }]
			let keychain = MockKeychainService()
			keychain.envStorage["project"] = (
				name: "Project", path: "", environments: ["default": ["TOKEN": "secret"]]
			)
			if let localVersion {
				keychain.dataStorage["__sync_metadata__"] = try? JSONEncoder().encode([
					"project": SyncMetadata(lastVersion: localVersion)
				])
			}
			let store = VaultStore(
				keychainService: keychain,
				biometricService: MockBiometricService(),
				apiService: MockAPIService(),
				personalSyncServiceFactory: { _ in sync },
				stableSyncEncryptor: { _, _ in ("blob", "wrapped") },
				authTokenProvider: { _, _ in "session" }
			)
			store.projects = [
				VaultProject(
					id: "project", name: "Project", path: "",
					environments: ["default": ["TOKEN": "secret"]]
				)
			]
			store.isUnlocked = true
			store.selectProject("project")
			await store.pushToCloud()
			return store
		}

		for invalidVersion in [nil, 0, -1] as [Int?] {
			let invalid = await run(syncStatus(vaultId: "project", version: invalidVersion))
			#expect(invalid.lastSyncStatus == "failed")
			#expect(invalid.syncMetadata["project"] == nil)
			#expect(invalid.error?.contains("valid version") == true)
		}

		let wrongVault = await run(syncStatus(vaultId: "other", version: 2))
		#expect(wrongVault.lastSyncStatus == "failed")
		#expect(wrongVault.syncMetadata["project"] == nil)
		#expect(wrongVault.error?.contains("did not match") == true)

		let downgrade = await run(
			syncStatus(vaultId: "project", version: 4),
			localVersion: 5
		)
		#expect(downgrade.lastSyncStatus == "failed")
		#expect(downgrade.error?.contains("valid version") == true)
	}

	@Test("personal pull rejects invalid versions, identity mismatches, and downgrades")
	@MainActor
	func personalPullResponseBinding() async throws {
		func run(
			_ response: SyncService.SyncStatus,
			localVersion: Int? = nil
		) async throws -> VaultStore {
			let sync = MockPersonalSyncService()
			sync.pullHandlers = [{ response }]
			let keychain = MockKeychainService()
			keychain.envStorage["project"] = (
				name: "Project", path: "", environments: ["default": ["TOKEN": "local"]]
			)
			if let localVersion {
				keychain.dataStorage["__sync_metadata__"] = try JSONEncoder().encode([
					"project": SyncMetadata(lastVersion: localVersion)
				])
			}
			let store = VaultStore(
				keychainService: keychain,
				biometricService: MockBiometricService(),
				apiService: MockAPIService(),
				personalSyncServiceFactory: { _ in sync },
				authTokenProvider: { _, _ in "session" }
			)
			store.projects = [VaultProject(
				id: "project", name: "Project", path: "",
				environments: ["default": ["TOKEN": "local"]]
			)]
			store.isUnlocked = true
			store.selectProject("project")
			await store.pullFromCloud()
			return store
		}

		for invalidVersion in [nil, 0, -1] as [Int?] {
			let invalid = try await run(syncStatus(vaultId: "project", version: invalidVersion))
			#expect(invalid.lastSyncStatus == "failed")
			#expect(invalid.error?.contains("valid version") == true)
		}
		let mismatch = try await run(syncStatus(vaultId: "other", version: 2))
		#expect(mismatch.lastSyncStatus == "failed")
		#expect(mismatch.error?.contains("did not match") == true)

		let downgrade = try await run(
			syncStatus(
				vaultId: "project",
				version: 4,
				encryptedBlob: "unused",
				wrappedKey: "unused"
			),
			localVersion: 5
		)
		#expect(downgrade.lastSyncStatus == "failed")
		#expect(downgrade.error?.contains("downgrade") == true)
	}

	@Test("organization pull rejects invalid versions, identity mismatches, and downgrades")
	@MainActor
	func organizationPullResponseBinding() async throws {
		func run(
			_ makeResponse: (Data) -> SyncService.SyncStatus,
			localVersion: Int? = nil
		) async throws -> VaultStore {
			let slug = "audit-org"
			let keypair = VaultCrypto.generateX25519Keypair()
			let sync = MockOrgSyncService()
			sync.publicKeyRecord = SyncService.PublicKeyRecord(
				publicKey: keypair.publicKey.base64EncodedString(),
				publicKeyVersion: 1,
				publicKeyFingerprint: VaultCrypto.publicKeyFingerprint(keypair.publicKey)
			)
			sync.pullResult = makeResponse(keypair.publicKey)
			let keychain = MockKeychainService()
			keychain.envStorage["project"] = (
				name: "Project", path: "", environments: ["default": ["TOKEN": "local"]]
			)
			if let localVersion {
				keychain.dataStorage["__sync_metadata__"] = try JSONEncoder().encode([
					"project": SyncMetadata(lastVersion: localVersion)
				])
			}
			let store = VaultStore(
				keychainService: keychain,
				biometricService: MockBiometricService(),
				apiService: MockAPIService(),
				orgSyncServiceFactory: { _ in sync },
				sharingKeypairProvider: { keypair },
				authTokenProvider: { _, _ in "session" }
			)
			store.currentUser = LPMUser(
				id: "user", username: "user", name: nil, email: nil,
				avatarUrl: nil, plan: nil, createdAt: nil,
				orgs: [LPMOrg(
					id: "org", slug: slug, name: "Audit", avatarUrl: nil, role: "admin"
				)]
			)
			store.projects = [VaultProject(
				id: "project", name: "Project", path: "",
				environments: ["default": ["TOKEN": "local"]]
			)]
			store.vaultOrgAssociations["project"] = slug
			store.isUnlocked = true
			store.selectAccount(.org(slug))
			store.selectProject("project")
			await store.pullFromOrg(orgSlug: slug)
			return store
		}

		for invalidVersion in [nil, 0, -1] as [Int?] {
			let invalid = try await run { _ in
				syncStatus(vaultId: "project", version: invalidVersion)
			}
			#expect(invalid.lastSyncStatus == "failed")
			#expect(invalid.error?.contains("valid version") == true)
		}
		let mismatch = try await run { _ in
			syncStatus(vaultId: "other", version: 2)
		}
		#expect(mismatch.lastSyncStatus == "failed")
		#expect(mismatch.error?.contains("did not match") == true)

		let downgrade = try await run({ publicKey in
			syncStatus(
				vaultId: "project",
				version: 4,
				contentKeyVersion: 1,
				recipientPublicKeyVersion: 1,
				recipientPublicKeyFingerprint: VaultCrypto.publicKeyFingerprint(publicKey),
				encryptedBlob: "unused",
				wrappedKey: "unused"
			)
		}, localVersion: 5)
		#expect(downgrade.lastSyncStatus == "failed")
		#expect(downgrade.error?.contains("downgrade") == true)
	}

	@Test("sync services retain one connection pool per exact base URL")
	func retainedSyncServiceIdentity() {
		let firstURL = URL(string: "https://audit-one.invalid")!
		let secondURL = URL(string: "https://audit-two.invalid")!
		let first = SyncService.shared(baseURL: firstURL)

		#expect(first === SyncService.shared(baseURL: firstURL))
		#expect(first !== SyncService.shared(baseURL: secondURL))
	}

	@Test("shared personal and organization push validation rejects unbound versions")
	func sharedPushResponseValidation() {
		for invalid in [
			syncStatus(vaultId: "project", version: nil),
			syncStatus(vaultId: "project", version: 0),
			syncStatus(vaultId: "project", version: -1),
			syncStatus(vaultId: "other", version: 2),
		] {
			#expect(VaultStore.acceptedPushVersion(invalid, vaultId: "project") == nil)
		}
		let valid = syncStatus(vaultId: "project", version: 5)
		#expect(VaultStore.acceptedPushVersion(valid, vaultId: "project") == 5)
		#expect(VaultStore.acceptedPushVersion(valid, vaultId: "project", greaterThan: 5) == nil)
	}

	@Test("personal sync serialization and encryption execute away from the main thread")
	@MainActor
	func personalSyncCryptoIsBackground() async {
		let recorder = AuditThreadRecorder()
		let sync = MockPersonalSyncService()
		let successResponse = syncStatus(vaultId: "project", version: 2)
		sync.pushHandlers = [{ successResponse }]
		let keychain = MockKeychainService()
		keychain.envStorage["project"] = (
			name: "Project", path: "", environments: ["default": ["TOKEN": "secret"]]
		)
		let store = VaultStore(
			keychainService: keychain,
			biometricService: MockBiometricService(),
			apiService: MockAPIService(),
			personalSyncServiceFactory: { _ in sync },
			stableSyncEncryptor: { _, _ in
				recorder.captureCurrentThread()
				return ("blob", "wrapped")
			},
			authTokenProvider: { _, _ in "session" }
		)
		store.projects = [VaultProject(
			id: "project", name: "Project", path: "",
			environments: ["default": ["TOKEN": "secret"]]
		)]
		store.isUnlocked = true
		store.selectProject("project")

		await store.pushToCloud()

		#expect(recorder.usedMainThread == false)
		#expect(store.lastSyncStatus == "Pushed (v2)")
	}

	@Test("clipboard timeout never clears a newer pasteboard owner")
	@MainActor
	func clipboardOwnership() async throws {
		let pasteboard = NSPasteboard.general
		pasteboard.clearContents()
		let manager = ClipboardManager(clearDelay: 0.02)
		manager.copy("lpm-secret")
		pasteboard.clearContents()
		pasteboard.setString("newer-owner", forType: .string)

		try await Task.sleep(for: .milliseconds(80))

		#expect(pasteboard.string(forType: .string) == "newer-owner")
		manager.clearClipboard()
		#expect(pasteboard.string(forType: .string) == "newer-owner")
	}

	@Test("an immediate clear removes only a clipboard value owned by the vault")
	@MainActor
	func immediateClipboardOwnership() {
		let pasteboard = NSPasteboard.general
		pasteboard.clearContents()
		pasteboard.setString("unrelated", forType: .string)
		let manager = ClipboardManager(clearDelay: 60)

		manager.clearClipboard()
		#expect(pasteboard.string(forType: .string) == "unrelated")

		manager.copy("owned")
		manager.clearClipboard()
		#expect(pasteboard.string(forType: .string) == nil)
	}

	@Test("application termination synchronously locks and clears sensitive state")
	@MainActor
	func terminationLocksVault() {
		let delegate = AppDelegate()
		var lockCount = 0
		delegate.lockVault = { lockCount += 1 }

		delegate.applicationWillTerminate(
			Notification(name: NSApplication.willTerminateNotification)
		)

		#expect(lockCount == 1)
	}

	@Test("build script rejects undeclared build modes before signing")
	func buildScriptRejectsUnknownMode() throws {
		let script = URL(fileURLWithPath: #filePath)
			.deletingLastPathComponent()
			.deletingLastPathComponent()
			.appendingPathComponent("build-app.sh")
		let process = Process()
		let output = Pipe()
		process.executableURL = URL(fileURLWithPath: "/bin/bash")
		process.arguments = [script.path, "invalid-mode"]
		process.standardOutput = output
		process.standardError = output
		try process.run()
		process.waitUntilExit()
		let message = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
		#expect(process.terminationStatus != 0)
		#expect(message.contains("Usage:"))
		#expect(message.contains("release|debug"))
		#expect(!message.contains("Signing identity"))
	}

	private func syncStatus(
		vaultId: String?,
		version: Int?,
		contentKeyVersion: Int? = nil,
		recipientPublicKeyVersion: Int? = nil,
		recipientPublicKeyFingerprint: String? = nil,
		encryptedBlob: String? = nil,
		wrappedKey: String? = nil
	) -> SyncService.SyncStatus {
		SyncService.SyncStatus(
			vaultId: vaultId,
			version: version,
			cryptoVersion: 2,
			contentKeyVersion: contentKeyVersion,
			recipientPublicKeyVersion: recipientPublicKeyVersion,
			recipientPublicKeyFingerprint: recipientPublicKeyFingerprint,
			status: "ok",
			error: nil,
			code: nil,
			serverVersion: nil,
			hint: nil,
			encryptedBlob: encryptedBlob,
			wrappedKey: wrappedKey,
			updatedAt: nil
		)
	}
}

private final class AuditThreadRecorder: @unchecked Sendable {
	private let lock = NSLock()
	private var storage: Bool?

	var usedMainThread: Bool? { lock.withLock { storage } }

	func captureCurrentThread() {
		lock.withLock { storage = Thread.isMainThread }
	}
}
