import CryptoKit
import Darwin
import Foundation
import Testing

@testable import LPMVault

@Suite(
	"Round 4 performance benchmarks",
	.serialized,
	.enabled(if: ProcessInfo.processInfo.environment["ROUND4_BENCHMARKS"] == "1")
)
struct Round4BenchmarkTests {
	@Test("organization recipient validation handoff")
	func organizationRecipientValidationHandoff() throws {
		let members = try deterministicOrganizationMembers(count: 1_024)
		let prepared = try OrganizationMemberAuthorizationPolicy.prepare(
			members,
			trust: OrgKeyTrust()
		)
		#expect(prepared.validatedRecipients.count == members.count)
		#expect(try legacyOrganizationRecipientHandoff(members).count == members.count)
		#expect(organizationRecipientChecksum(prepared.validatedRecipients) > 0)

		var legacySamples: [Double] = []
		var validatedSamples: [Double] = []
		legacySamples.reserveCapacity(9)
		validatedSamples.reserveCapacity(9)
		for iteration in 0..<9 {
			let legacy = {
				try measureMilliseconds {
					let recipients = try legacyOrganizationRecipientHandoff(members)
					#expect(organizationRecipientChecksum(recipients) > 0)
				}
			}
			let validated = {
				measureMilliseconds {
					#expect(organizationRecipientChecksum(prepared.validatedRecipients) > 0)
				}
			}
			if iteration.isMultiple(of: 2) {
				legacySamples.append(try legacy())
				validatedSamples.append(validated())
			} else {
				validatedSamples.append(validated())
				legacySamples.append(try legacy())
			}
		}

		print(
			"ROUND4_BENCH organization_recipients=1024 "
				+ "legacy_handoff_ms=\(median(legacySamples)) "
				+ "validated_handoff_ms=\(median(validatedSamples)) "
				+ "peak_rss_bytes=\(peakRSSBytes())"
		)
	}

	@Test("strict JSON validation allocation profile")
	func strictJSONValidation() throws {
		let value = String(repeating: "payload-", count: 750_000)
		let data = Data(#"{"root":{"value":"\#(value)"},"items":["\#(value)"]}"#.utf8)
		let profile = try StrictJSONKeyValidator.validationProfile(data)
		#expect(profile.materializedStringCount == 3)
		#expect(profile.copiedInputByteCount == 0)

		let measurements = try synchronousSamples(count: 7) {
			try StrictJSONKeyValidator.validate(data)
		}
		print(
			"ROUND4_BENCH strict_json_bytes=\(data.count) "
				+ "median_ms=\(median(measurements)) "
				+ "materialized_strings=\(profile.materializedStringCount) "
				+ "copied_input_bytes=\(profile.copiedInputByteCount) "
				+ "peak_rss_bytes=\(peakRSSBytes())"
		)
	}

	@Test("organization approval matching scaling")
	func organizationApprovalMatching() {
		func approvals(count: Int) -> [PendingKeyApproval] {
			(0..<count).map { index in
				PendingKeyApproval(
					memberId: "member-\(index)",
					fingerprint: String(format: "%064x", index),
					isNewMember: index.isMultiple(of: 2),
					oldFingerprint: index.isMultiple(of: 3) ? nil : "old-\(index)"
				)
			}
		}
		let small = approvals(count: 4_000)
		let large = approvals(count: 8_000)
		#expect(PendingKeyApproval.exactlyMatches(small.reversed(), pending: small))
		#expect(PendingKeyApproval.exactlyMatches(large.reversed(), pending: large))

		var smallSamples: [Double] = []
		var largeSamples: [Double] = []
		for iteration in 0..<9 {
			let measureSmall = {
				measureMilliseconds {
					#expect(PendingKeyApproval.exactlyMatches(
						small.reversed(), pending: small))
				}
			}
			let measureLarge = {
				measureMilliseconds {
					#expect(PendingKeyApproval.exactlyMatches(
						large.reversed(), pending: large))
				}
			}
			if iteration.isMultiple(of: 2) {
				smallSamples.append(measureSmall())
				largeSamples.append(measureLarge())
			} else {
				largeSamples.append(measureLarge())
				smallSamples.append(measureSmall())
			}
		}
		print(
			"ROUND4_BENCH approval_small_count=4000 "
				+ "approval_small_ms=\(median(smallSamples)) "
				+ "approval_large_count=8000 "
				+ "approval_large_ms=\(median(largeSamples)) "
				+ "peak_rss_bytes=\(peakRSSBytes())"
		)
	}

	@Test("outer-lock recovery admission")
	func outerLockRecoveryAdmission() throws {
		let backend = Round4BenchmarkKeychainBackend()
		let store = SharedKeychainStore(service: "round4-recovery", backend: backend)
		let accounts = (0..<20_000).map { "account-\($0)" }
		let elapsed = try measureMilliseconds {
			try VaultKeychainTransactionLock.withLock {
				for account in accounts {
					_ = try store.read(account: account)
				}
			}
		}
		#expect(backend.readCount(account: "__vault_transaction_v3__") == 1)
		print(
			"ROUND4_BENCH outer_lock_reads=\(accounts.count) "
				+ "recovery_marker_reads=1 elapsed_ms=\(elapsed) "
				+ "peak_rss_bytes=\(peakRSSBytes())"
		)
	}

	@Test("prepared project transaction profile")
	func preparedProjectTransaction() {
		let environments = [
			"default": Dictionary(uniqueKeysWithValues: (0..<500).map {
				("KEY_\($0)", "value-\($0)")
			})
		]
		var samples: [Double] = []
		for iteration in 0..<7 {
			let backend = Round4BenchmarkKeychainBackend()
			let counters = VaultKeychainPerformanceCounters()
			let service = KeychainService(
				testingService: "round4-prepared-\(iteration)",
				backend: backend,
				performanceCounters: counters
			)
			let elapsed = measureMilliseconds {
				let result = service.createEnvironments(
					vaultId: "00000000-0000-4000-8000-\(String(format: "%012d", iteration))",
					projectName: "Benchmark",
					projectPath: "",
					environments: environments
				)
				guard case .success = result else {
					Issue.record("Prepared project transaction failed: \(result)")
					return
				}
			}
			let snapshot = counters.snapshot
			#expect(snapshot.projectPayloadParseCount == 0)
			#expect(snapshot.projectPayloadHashCount == 1)
			#expect(snapshot.livePayloadReuseCount == 4)
			samples.append(elapsed)
		}
		print(
			"ROUND4_BENCH prepared_project_keys=500 "
				+ "median_ms=\(median(samples)) live_parses=0 payload_hashes=1 "
				+ "live_payload_reuses=4 peak_rss_bytes=\(peakRSSBytes())"
		)
	}

	@Test("multiline dotenv scaling")
	func multilineDotenvScaling() async throws {
		let directory = FileManager.default.temporaryDirectory
			.appendingPathComponent("round4-multiline-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: directory) }
		let service = EnvFileImportService(maximumConcurrentImports: 1)
		let small = directory.appendingPathComponent("small.env")
		let large = directory.appendingPathComponent("large.env")
		try multilineFixture(lineCount: 6_000).write(to: small)
		try multilineFixture(lineCount: 12_000).write(to: large)
		_ = try await service.load(at: directory.appendingPathComponent("warm.env").writing(
			multilineFixture(lineCount: 32)
		))

		let smallSamples = try await samples(count: 3) {
			_ = try await service.load(at: small)
		}
		let largeSamples = try await samples(count: 3) {
			_ = try await service.load(at: large)
		}
		print(
			"ROUND4_BENCH multiline_small_ms=\(median(smallSamples)) "
				+ "multiline_large_ms=\(median(largeSamples)) "
				+ "peak_rss_bytes=\(peakRSSBytes())"
		)
	}

	@Test("AES-GCM decrypt time and peak RSS")
	func aesDecrypt() throws {
		let key = SymmetricKey(size: .bits256)
		let plaintext = Data(repeating: 0x61, count: 7_500_000)
		let encoded = try VaultCrypto.encrypt(key: key, plaintext: plaintext)
		#expect(try VaultCrypto.decrypt(key: key, encoded: encoded) == plaintext)

		let decryptSamples = try synchronousSamples(count: 7) {
			let decrypted = try VaultCrypto.decrypt(key: key, encoded: encoded)
			#expect(decrypted.count == plaintext.count)
		}
		print(
			"ROUND4_BENCH aes_decrypt_ms=\(median(decryptSamples)) "
				+ "peak_rss_bytes=\(peakRSSBytes())"
		)
	}

	@Test("project pagination cumulative budget")
	func projectPagination() async throws {
		let name = String(repeating: "p", count: 5_300_000)
		let first = try JSONSerialization.data(withJSONObject: [
			"vaults": [["vaultId": "one", "name": name]],
			"nextCursor": "second",
		])
		let second = try JSONSerialization.data(withJSONObject: [
			"vaults": [["vaultId": "two", "name": name]],
			"nextCursor": NSNull(),
		])
		let service = round4SyncService { request in
			request.url?.query == "cursor=second" ? second : first
		}

		let start = ContinuousClock.now
		let result = await service.listPersonalProjects(authToken: "session")
		print(
			"ROUND4_BENCH project_pagination_ms=\(milliseconds(start.duration(to: .now))) "
				+ "result=\(result.round4Label) peak_rss_bytes=\(peakRSSBytes())"
		)
	}

	@Test("token pagination cumulative budget")
	func tokenPagination() async throws {
		let name = String(repeating: "t", count: 1_100_000)
		let first = try JSONEncoder().encode([round4Token(id: "one", name: name)])
		let second = try JSONEncoder().encode([round4Token(id: "two", name: name)])
		let service = round4APIService { request in
			let cursor = request.url.flatMap {
				URLComponents(url: $0, resolvingAgainstBaseURL: false)?
					.queryItems?.first { $0.name == "cursor" }?.value
			}
			return Round4BenchmarkResponse(
				body: cursor == nil ? first : second,
				nextCursor: cursor == nil ? "second" : nil
			)
		}

		let start = ContinuousClock.now
		let result = await service.fetchPersonalTokens(authToken: "session")
		print(
			"ROUND4_BENCH token_pagination_ms=\(milliseconds(start.duration(to: .now))) "
				+ "result=\(result.round4Label) peak_rss_bytes=\(peakRSSBytes())"
		)
	}

	@Test("dotenv export main-actor gap")
	@MainActor
	func asynchronousExport() async throws {
		let directory = FileManager.default.temporaryDirectory
			.appendingPathComponent("round4-export-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: directory) }
		let secrets = ["VALUE": String(repeating: "x", count: 32 * 1024 * 1024)]
		_ = EnvFileCodec.format(["WARM": "value"])
		let heartbeat = Round4BenchmarkHeartbeat()
		let task = Task { @MainActor in
			while !heartbeat.finished {
				let tick = ContinuousClock.now
				try? await Task.sleep(for: .milliseconds(1))
				heartbeat.maximumGap = max(
					heartbeat.maximumGap,
					milliseconds(tick.duration(to: .now))
				)
			}
		}
		await Task.yield()
		let start = ContinuousClock.now
		try await EnvFileExportService.shared.export(
			secrets: secrets,
			to: directory.appendingPathComponent("export.env")
		)
		heartbeat.finished = true
		await task.value
		print(
			"ROUND4_BENCH export_ms=\(milliseconds(start.duration(to: .now))) "
				+ "main_actor_gap_ms=\(heartbeat.maximumGap) "
				+ "peak_rss_bytes=\(peakRSSBytes())"
		)
	}

	@Test("workspace snapshot allocation profile")
	func workspaceSnapshotAllocations() {
		let project = largeWorkspaceProject(environmentCount: 32, keyCount: 6_000)
		_ = VaultWorkspaceSnapshot(project: project)
		let samples = (0..<7).map { _ in
			let start = ContinuousClock.now
			let snapshot = VaultWorkspaceSnapshot(project: project)
			#expect(snapshot.allSecretKeys.count == 6_000)
			return milliseconds(start.duration(to: .now))
		}
		print(
			"ROUND5_BENCH workspace_snapshot_ms=\(median(samples)) "
				+ "peak_rss_bytes=\(peakRSSBytes())"
		)
	}

	@Test("workspace snapshot incremental reconciliation")
	func workspaceSnapshotReconciliation() async throws {
		let previousProjects = largeWorkspaceProjects(projectCount: 100, keyCount: 6_000)
		let builder = VaultWorkspaceSnapshotBuilder()
		let existingSnapshots = try #require(await builder.buildAll(previousProjects))
		var currentProjects = previousProjects
		currentProjects[99].environments["default"]?["KEY_05999"] = "changed"

		let warm = try #require(
			await builder.buildIncremental(
				currentProjects: currentProjects,
				existingSnapshots: existingSnapshots
			)
		)
		#expect(warm.buildCount == 1)

		var legacySamples: [Double] = []
		var optimizedSamples: [Double] = []
		legacySamples.reserveCapacity(7)
		optimizedSamples.reserveCapacity(7)
		for iteration in 0..<7 {
			let legacy = {
				measureMilliseconds {
					let update = legacyWorkspaceSnapshotReconciliation(
						previousProjects: previousProjects,
						currentProjects: currentProjects,
						existingSnapshots: existingSnapshots
					)
					#expect(update.buildCount == 1)
				}
			}
			let optimized = {
				let start = ContinuousClock.now
				let update = await builder.buildIncremental(
					currentProjects: currentProjects,
					existingSnapshots: existingSnapshots
				)
				#expect(update?.buildCount == 1)
				return milliseconds(start.duration(to: .now))
			}
			if iteration.isMultiple(of: 2) {
				legacySamples.append(legacy())
				optimizedSamples.append(await optimized())
			} else {
				optimizedSamples.append(await optimized())
				legacySamples.append(legacy())
			}
		}

		print(
			"ROUND4_BENCH workspace_reconcile_projects=100 keys_per_project=6000 "
				+ "legacy_ms=\(median(legacySamples)) "
				+ "optimized_ms=\(median(optimizedSamples)) "
				+ "peak_rss_bytes=\(peakRSSBytes())"
		)
	}

	@Test("dotenv formatter and file-data profile")
	func dotenvFormatter() {
		let value = String(repeating: "\\\"$`\n\r\tpayload", count: 500_000)
		let secrets = ["VALUE": value]
		if let variant = ProcessInfo.processInfo.environment["ROUND4_DOTENV_VARIANT"] {
			let samples = (0..<8).compactMap { iteration -> Double? in
				let measurement = measureMilliseconds {
					switch variant {
					case "legacy-string":
						#expect(legacyEnvFileFormat(secrets).utf8.count > value.utf8.count)
					case "optimized-string":
						#expect(EnvFileCodec.format(secrets).utf8.count > value.utf8.count)
					case "legacy-data":
						#expect(Data(legacyEnvFileFormat(secrets).utf8).count > value.utf8.count)
					case "optimized-data":
						#expect(EnvFileCodec.formatData(secrets).count > value.utf8.count)
					default:
						Issue.record("Unknown ROUND4_DOTENV_VARIANT: \(variant)")
					}
				}
				return iteration == 0 ? nil : measurement
			}
			print(
				"ROUND4_BENCH dotenv_variant=\(variant) input_bytes=\(value.utf8.count) "
					+ "median_ms=\(median(samples)) peak_rss_bytes=\(peakRSSBytes())"
			)
			return
		}
		#expect(legacyEnvFileFormat(secrets) == EnvFileCodec.format(secrets))
		#expect(Data(legacyEnvFileFormat(secrets).utf8) == EnvFileCodec.formatData(secrets))

		var legacyStringSamples: [Double] = []
		var optimizedStringSamples: [Double] = []
		var legacyDataSamples: [Double] = []
		var optimizedDataSamples: [Double] = []
		for iteration in 0..<7 {
			let legacyString = {
				measureMilliseconds {
					#expect(legacyEnvFileFormat(secrets).utf8.count > value.utf8.count)
				}
			}
			let optimizedString = {
				measureMilliseconds {
					#expect(EnvFileCodec.format(secrets).utf8.count > value.utf8.count)
				}
			}
			let legacyData = {
				measureMilliseconds {
					#expect(Data(legacyEnvFileFormat(secrets).utf8).count > value.utf8.count)
				}
			}
			let optimizedData = {
				measureMilliseconds {
					#expect(EnvFileCodec.formatData(secrets).count > value.utf8.count)
				}
			}
			if iteration.isMultiple(of: 2) {
				legacyStringSamples.append(legacyString())
				optimizedStringSamples.append(optimizedString())
				legacyDataSamples.append(legacyData())
				optimizedDataSamples.append(optimizedData())
			} else {
				optimizedDataSamples.append(optimizedData())
				legacyDataSamples.append(legacyData())
				optimizedStringSamples.append(optimizedString())
				legacyStringSamples.append(legacyString())
			}
		}

		print(
			"ROUND4_BENCH dotenv_input_bytes=\(value.utf8.count) "
				+ "legacy_string_ms=\(median(legacyStringSamples)) "
				+ "optimized_string_ms=\(median(optimizedStringSamples)) "
				+ "legacy_data_ms=\(median(legacyDataSamples)) "
				+ "optimized_data_ms=\(median(optimizedDataSamples)) "
				+ "peak_rss_bytes=\(peakRSSBytes())"
		)
	}

	@Test("content derivation identity and search profile")
	func contentDerivationAllocations() {
		let project = largeWorkspaceProject(environmentCount: 1, keyCount: 6_000)
		let snapshot = VaultWorkspaceSnapshot(project: project)
		let inputs: [(VaultWorkspaceMode, String)] = [
			(.matrix, ""),
			(.environment("environment-0"), ""),
			(.matrix, "key_599"),
			(.environment("environment-0"), "key_599"),
		]
		for (mode, query) in inputs {
			_ = VaultContentDerivation(
				project: project,
				snapshot: snapshot,
				selectedEnvironment: "environment-0",
				mode: mode,
				filter: .all,
				searchText: query,
				revealedKeys: []
			)
		}
		let samples = (0..<9).map { _ in
			let start = ContinuousClock.now
			var checksum = 0
			for _ in 0..<100 {
				for (mode, query) in inputs {
					let derivation = VaultContentDerivation(
						project: project,
						snapshot: snapshot,
						selectedEnvironment: "environment-0",
						mode: mode,
						filter: .all,
						searchText: query,
						revealedKeys: []
					)
					checksum &+= derivation.filteredKeys.count
					checksum &+= derivation.environmentKeys.count
				}
			}
			#expect(checksum > 0)
			return milliseconds(start.duration(to: .now))
		}
		print(
			"ROUND5_BENCH content_derivation_ms=\(median(samples)) "
				+ "peak_rss_bytes=\(peakRSSBytes())"
		)
	}

	@Test("empty-local remote import profile")
	func emptyLocalRemoteImportAllocations() throws {
		let project = largeWorkspaceProject(environmentCount: 32, keyCount: 2_000)
		let payload = try JSONEncoder().encode(["environments": project.environments])
		_ = try EnvValidation.mergeRemotePayload(payload, into: [:])
		let samples = try synchronousSamples(count: 7) {
			let result = try EnvValidation.mergeRemotePayload(payload, into: [:])
			#expect(result.keyCount == 64_000)
		}
		print(
			"ROUND5_BENCH empty_local_import_ms=\(median(samples)) "
				+ "peak_rss_bytes=\(peakRSSBytes())"
		)
	}

	@Test("add environment authoritative serialization profile")
	@MainActor
	func addEnvironmentSerialization() async {
		var samples: [Double] = []
		samples.reserveCapacity(9)
		for iteration in 0..<10 {
			let keychain = MockKeychainService()
			keychain.envStorage["project"] = (
				name: "Project",
				path: "",
				environments: [
					"default": [
						"VALUE": String(
							repeating: "x",
							count: VaultConstants.maxVaultSizeWarning * 8 / 10
						)
					],
				]
			)
			let store = VaultStore(
				keychainService: keychain,
				biometricService: MockBiometricService(),
				apiService: MockAPIService(),
				authSessionClearer: { _ in }
			)
			store.projects = [VaultProject(
				id: "project",
				name: "Project",
				path: "",
				environments: keychain.envStorage["project"]!.environments
			)]
			store.isUnlocked = true
			store.selectProject("project")
			let start = ContinuousClock.now
			#expect(await store.addEnvironment(to: "project", name: "staging"))
			if iteration > 0 {
				samples.append(milliseconds(start.duration(to: .now)))
			}
		}
		print(
			"ROUND5_BENCH add_environment_ms=\(median(samples)) "
				+ "peak_rss_bytes=\(peakRSSBytes())"
		)
	}

	@Test("selected project lookup avoids active-list materialization")
	@MainActor
	func selectedProjectLookup() {
		let store = VaultStore(
			keychainService: MockKeychainService(),
			biometricService: MockBiometricService(),
			apiService: MockAPIService(),
			authSessionClearer: { _ in }
		)
		store.projects = (0..<10_000).map { index in
			VaultProject(
				id: "project-\(index)",
				name: "Project \(index)",
				path: "",
				environments: [:]
			)
		}
		store.vaultOrgAssociations = Dictionary(
			uniqueKeysWithValues: stride(from: 1, to: 10_000, by: 2).map {
				("project-\($0)", "acme")
			}
		)
		store.selectedProjectId = "project-9998"
		#expect(store.selectedProject?.id == "project-9998")

		var legacySamples: [Double] = []
		var optimizedSamples: [Double] = []
		for iteration in 0..<9 {
			let legacy = {
				measureMilliseconds {
					var checksum = 0
					for _ in 0..<200 {
						let active = store.projects.filter {
							store.vaultOrgAssociations[$0.id] == nil
						}
						checksum &+= active.first { $0.id == store.selectedProjectId }?.id.count ?? 0
					}
					#expect(checksum > 0)
				}
			}
			let optimized = {
				measureMilliseconds {
					var checksum = 0
					for _ in 0..<200 {
						checksum &+= store.selectedProject?.id.count ?? 0
					}
					#expect(checksum > 0)
				}
			}
			if iteration.isMultiple(of: 2) {
				legacySamples.append(legacy())
				optimizedSamples.append(optimized())
			} else {
				optimizedSamples.append(optimized())
				legacySamples.append(legacy())
			}
		}

		print(
			"ROUND5_BENCH selected_project_count=10000 lookups=200 "
				+ "legacy_ms=\(median(legacySamples)) "
				+ "optimized_ms=\(median(optimizedSamples)) "
				+ "peak_rss_bytes=\(peakRSSBytes())"
		)
	}
}

private func legacyWorkspaceSnapshotReconciliation(
	previousProjects: [VaultProject],
	currentProjects: [VaultProject],
	existingSnapshots: [String: VaultWorkspaceSnapshot]
) -> VaultWorkspaceSnapshotUpdate {
	let currentIDs = Set(currentProjects.map(\.id))
	let previous = Dictionary(uniqueKeysWithValues: previousProjects.map { ($0.id, $0) })
	var snapshots = existingSnapshots.filter { currentIDs.contains($0.key) }
	snapshots.reserveCapacity(currentProjects.count)
	var buildCount = 0
	for project in currentProjects where previous[project.id] != project {
		snapshots[project.id] = VaultWorkspaceSnapshot(project: project)
		buildCount += 1
	}
	return VaultWorkspaceSnapshotUpdate(snapshots: snapshots, buildCount: buildCount)
}

private func largeWorkspaceProject(environmentCount: Int, keyCount: Int) -> VaultProject {
	let keys = (0..<keyCount).map { String(format: "KEY_%05d", $0) }
	let environments = Dictionary(uniqueKeysWithValues: (0..<environmentCount).map { environment in
		(
			"environment-\(environment)",
			Dictionary(uniqueKeysWithValues: keys.map { key in (key, "value-\(key)") })
		)
	})
	return VaultProject(
		id: "benchmark",
		name: "Benchmark",
		path: "",
		environments: environments
	)
}

private func largeWorkspaceProjects(projectCount: Int, keyCount: Int) -> [VaultProject] {
	let secrets = Dictionary(uniqueKeysWithValues: (0..<keyCount).map { index in
		(String(format: "KEY_%05d", index), "value-\(index)")
	})
	return (0..<projectCount).map { index in
		VaultProject(
			id: "benchmark-\(index)",
			name: "Benchmark \(index)",
			path: "",
			environments: ["default": secrets]
		)
	}
}

private func legacyEnvFileFormat(_ secrets: [String: String]) -> String {
	secrets.sorted { $0.key < $1.key }
		.map { key, value in
			let escaped = value
				.replacingOccurrences(of: "\\", with: "\\\\")
				.replacingOccurrences(of: "\"", with: "\\\"")
				.replacingOccurrences(of: "$", with: "\\$")
				.replacingOccurrences(of: "`", with: "\\`")
				.replacingOccurrences(of: "\n", with: "\\n")
				.replacingOccurrences(of: "\r", with: "\\r")
				.replacingOccurrences(of: "\t", with: "\\t")
			return "\(key)=\"\(escaped)\""
		}
		.joined(separator: "\n") + "\n"
}

private func deterministicOrganizationMembers(
	count: Int
) throws -> [SyncService.MemberPublicKey] {
	try (0..<count).map { index in
		let seed = Data(SHA256.hash(data: Data("member-\(index)".utf8)))
		let publicKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: seed)
			.publicKey.rawRepresentation
		return SyncService.MemberPublicKey(
			userId: "member-\(index)",
			role: "member",
			publicKey: publicKey.base64EncodedString(),
			publicKeyVersion: 1,
			publicKeyFingerprint: VaultCrypto.publicKeyFingerprint(publicKey),
			hasPublicKey: true
		)
	}
}

private struct LegacyOrganizationRecipient {
	let userId: String
	let publicKey: Data
	let publicKeyVersion: Int
	let publicKeyFingerprint: String
}

private func legacyOrganizationRecipientHandoff(
	_ members: [SyncService.MemberPublicKey]
) throws -> [LegacyOrganizationRecipient] {
	try members.map { member in
		guard let encodedKey = member.publicKey,
			let publicKey = Data(base64Encoded: encodedKey),
			publicKey.count == 32,
			let publicKeyVersion = member.publicKeyVersion,
			publicKeyVersion > 0,
			let fingerprint = member.publicKeyFingerprint,
			fingerprint == VaultCrypto.publicKeyFingerprint(publicKey)
		else {
			throw VaultSyncError("Invalid benchmark recipient.")
		}
		return LegacyOrganizationRecipient(
			userId: member.userId,
			publicKey: publicKey,
			publicKeyVersion: publicKeyVersion,
			publicKeyFingerprint: fingerprint
		)
	}
}

@inline(never)
private func organizationRecipientChecksum(
	_ recipients: [LegacyOrganizationRecipient]
) -> Int {
	recipients.reduce(into: 0) { checksum, recipient in
		checksum &+= recipient.userId.utf8.count
		checksum &+= recipient.publicKey.count
		checksum &+= recipient.publicKeyVersion
		checksum &+= recipient.publicKeyFingerprint.utf8.count
	}
}

@inline(never)
private func organizationRecipientChecksum(
	_ recipients: [ValidatedOrganizationRecipient]
) -> Int {
	recipients.reduce(into: 0) { checksum, recipient in
		checksum &+= recipient.userId.utf8.count
		checksum &+= recipient.publicKey.count
		checksum &+= recipient.publicKeyVersion
		checksum &+= recipient.publicKeyFingerprint.utf8.count
	}
}

private func measureMilliseconds(_ operation: () throws -> Void) rethrows -> Double {
	let start = ContinuousClock.now
	try operation()
	return milliseconds(start.duration(to: .now))
}

private func multilineFixture(lineCount: Int) -> Data {
	Data(("VALUE=\"start\n" + String(repeating: "x\n", count: lineCount) + "end\"\n").utf8)
}

private func samples(
	count: Int,
	operation: () async throws -> Void
) async throws -> [Double] {
	var values: [Double] = []
	values.reserveCapacity(count)
	for _ in 0..<count {
		let start = ContinuousClock.now
		try await operation()
		values.append(milliseconds(start.duration(to: .now)))
	}
	return values
}

private func synchronousSamples(
	count: Int,
	operation: () throws -> Void
) throws -> [Double] {
	try (0..<count).map { _ in
		let start = ContinuousClock.now
		try operation()
		return milliseconds(start.duration(to: .now))
	}
}

private func median(_ values: [Double]) -> Double {
	let sorted = values.sorted()
	return sorted[sorted.count / 2]
}

private func milliseconds(_ duration: Duration) -> Double {
	let components = duration.components
	return Double(components.seconds) * 1_000
		+ Double(components.attoseconds) / 1_000_000_000_000_000
}

private func peakRSSBytes() -> Int64 {
	var usage = rusage()
	guard getrusage(RUSAGE_SELF, &usage) == 0 else { return -1 }
	return Int64(usage.ru_maxrss)
}

private func round4Token(id: String, name: String) -> LPMToken {
	LPMToken(
		id: id,
		name: name,
		scope: nil,
		expiresAt: nil,
		lastUsedAt: nil,
		downloadCount: nil,
		createdAt: nil,
		orgSlug: nil
	)
}

private func round4SyncService(
	handler: @escaping @Sendable (URLRequest) throws -> Data
) -> SyncService {
	let host = "\(UUID().uuidString.lowercased()).example"
	Round4BenchmarkRoutes.shared.register(host: host) { request in
		Round4BenchmarkResponse(body: try handler(request), nextCursor: nil)
	}
	return SyncService(
		baseURL: URL(string: "https://\(host)")!,
		session: round4BenchmarkSession()
	)
}

private func round4APIService(
	handler: @escaping @Sendable (URLRequest) throws -> Round4BenchmarkResponse
) -> LPMAPIService {
	let host = "\(UUID().uuidString.lowercased()).example"
	Round4BenchmarkRoutes.shared.register(host: host, handler: handler)
	return LPMAPIService(
		baseURL: URL(string: "https://\(host)")!,
		session: round4BenchmarkSession()
	)
}

private func round4BenchmarkSession() -> URLSession {
	let configuration = URLSessionConfiguration.ephemeral
	configuration.protocolClasses = [Round4BenchmarkURLProtocol.self]
	return URLSession(
		configuration: configuration,
		delegate: BoundedHTTPResponseDelegate(),
		delegateQueue: nil
	)
}

private struct Round4BenchmarkResponse: Sendable {
	let body: Data
	let nextCursor: String?
}

private final class Round4BenchmarkRoutes: @unchecked Sendable {
	static let shared = Round4BenchmarkRoutes()
	private let lock = NSLock()
	private var handlers: [String: @Sendable (URLRequest) throws -> Round4BenchmarkResponse] = [:]

	func register(
		host: String,
		handler: @escaping @Sendable (URLRequest) throws -> Round4BenchmarkResponse
	) {
		lock.withLock { handlers[host] = handler }
	}

	func response(for request: URLRequest) throws -> Round4BenchmarkResponse {
		guard let host = request.url?.host,
			let handler = lock.withLock({ handlers[host] })
		else { throw URLError(.badURL) }
		return try handler(request)
	}
}

private final class Round4BenchmarkURLProtocol: URLProtocol {
	override class func canInit(with request: URLRequest) -> Bool { true }
	override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

	override func startLoading() {
		do {
			let result = try Round4BenchmarkRoutes.shared.response(for: request)
			var headers = ["Content-Type": "application/json"]
			if let nextCursor = result.nextCursor {
				headers["X-LPM-Next-Cursor"] = nextCursor
			}
			let response = HTTPURLResponse(
				url: request.url!,
				statusCode: 200,
				httpVersion: "HTTP/1.1",
				headerFields: headers
			)!
			client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
			client?.urlProtocol(self, didLoad: result.body)
			client?.urlProtocolDidFinishLoading(self)
		} catch {
			client?.urlProtocol(self, didFailWithError: error)
		}
	}

	override func stopLoading() {}
}

private final class Round4BenchmarkKeychainBackend: KeychainStoreBackend {
	private var values: [String: Data] = [:]
	private var readCounts: [String: Int] = [:]

	func read(service: String, account: String) throws -> Data? {
		readCounts[account, default: 0] += 1
		return values[account]
	}

	func write(service: String, account: String, data: Data) throws {
		values[account] = data
	}

	func add(service: String, account: String, data: Data) throws {
		guard values[account] == nil else {
			throw KeychainStoreError.status(operation: "add", code: errSecDuplicateItem)
		}
		values[account] = data
	}

	func delete(service: String, account: String) throws -> Bool {
		values.removeValue(forKey: account) != nil
	}

	func readCount(account: String) -> Int {
		readCounts[account, default: 0]
	}
}

@MainActor
private final class Round4BenchmarkHeartbeat {
	var finished = false
	var maximumGap = 0.0
}

private extension URL {
	func writing(_ data: Data) throws -> URL {
		try data.write(to: self)
		return self
	}
}

private extension Result {
	var round4Label: String {
		switch self {
		case .success: "success"
		case .failure: "failure"
		}
	}
}
