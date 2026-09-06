import Foundation
import Testing

@testable import LPMVault

@Suite(
	"Round 2 performance benchmarks",
	.serialized,
	.enabled(if: ProcessInfo.processInfo.environment["ROUND2_BENCHMARKS"] == "1")
)
struct Round2BenchmarkTests {
	@Test("workspace snapshot invalidation benchmark")
	@MainActor
	func workspaceInvalidation() {
		let store = VaultStore(
			keychainService: MockKeychainService(),
			biometricService: MockBiometricService(),
			apiService: MockAPIService()
		)
		store.projects = makeProjects(projectCount: 100, keysPerProject: 500)
		store.projects[0].environments["default"]?["K0"] = "warm"

		let samples = (0..<9).map { sample -> Double in
			let start = ContinuousClock.now
			store.projects[42].environments["default"]?["K0"] = "sample-\(sample)"
			return milliseconds(start.duration(to: .now))
		}
		print("ROUND2_BENCH workspace_invalidation_ms median=\(median(samples)) samples=\(samples)")
	}

	@Test("lock plaintext clearing benchmark")
	@MainActor
	func lockClearing() {
		let samples = (0..<7).map { _ -> Double in
			let store = VaultStore(
				keychainService: MockKeychainService(),
				biometricService: MockBiometricService(),
				apiService: MockAPIService()
			)
			store.projects = makeProjects(projectCount: 100, keysPerProject: 500)
			store.isUnlocked = true
			let start = ContinuousClock.now
			store.lock()
			return milliseconds(start.duration(to: .now))
		}
		print("ROUND2_BENCH lock_ms median=\(median(samples)) samples=\(samples)")
	}

	@Test("sidebar search benchmark")
	@MainActor
	func sidebarSearch() {
		let store = VaultStore(
			keychainService: MockKeychainService(),
			biometricService: MockBiometricService(),
			apiService: MockAPIService()
		)
		store.projects = makeProjects(projectCount: 100, keysPerProject: 1_000)
		store.searchQuery = "absent-query"
		_ = store.filteredVaults

		let samples = (0..<15).map { _ -> Double in
			let start = ContinuousClock.now
			_ = store.filteredVaults
			return milliseconds(start.duration(to: .now))
		}
		print("ROUND2_BENCH search_ms median=\(median(samples)) samples=\(samples)")
	}

	@Test("mode derivation benchmark")
	func modeDerivation() {
		let project = makeProjects(projectCount: 1, keysPerProject: 6_000)[0]
		let snapshot = VaultWorkspaceSnapshot(project: project)
		_ = VaultContentDerivation(
			project: project,
			snapshot: snapshot,
			selectedEnvironment: "default",
			mode: .matrix,
			filter: .all,
			searchText: "",
			revealedKeys: []
		)
		let samples = (0..<15).map { _ -> Double in
			let start = ContinuousClock.now
			_ = VaultContentDerivation(
				project: project,
				snapshot: snapshot,
				selectedEnvironment: "default",
				mode: .matrix,
				filter: .all,
				searchText: "",
				revealedKeys: []
			)
			return milliseconds(start.duration(to: .now))
		}
		print("ROUND2_BENCH derivation_ms median=\(median(samples)) samples=\(samples)")
	}

	@Test("newline-free dotenv import benchmark")
	func newlineFreeImport() async throws {
		let directory = FileManager.default.temporaryDirectory
			.appendingPathComponent("round2-import-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: directory) }
		let url = directory.appendingPathComponent("large.env")
		try Data(repeating: 0x41, count: 16 * 1024 * 1024).write(to: url)
		let service = EnvFileImportService(maximumConcurrentImports: 1)
		do {
			_ = try await service.load(at: url)
		} catch EnvFileImportError.noValidSecrets {
			// Deterministic warm gate before the measured samples.
		}

		let samples = try await (0..<5).asyncMap { _ -> Double in
			let start = ContinuousClock.now
			do {
				_ = try await service.load(at: url)
			} catch EnvFileImportError.noValidSecrets {
				// Expected: the line contains no assignment.
			}
			return milliseconds(start.duration(to: .now))
		}
		print("ROUND2_BENCH import_ms median=\(median(samples)) samples=\(samples)")
	}

	@Test("batched project unlock benchmark")
	func projectUnlock() {
		let service = KeychainService(
			testingService: "dev.lpm.vault.round2-bench.\(UUID().uuidString)"
		)
		let projectIDs = (0..<40).map { "bench-project-\($0)" }
		defer {
			for projectID in projectIDs {
				_ = service.applyVaultTransaction(
					project: .delete(vaultId: projectID, deletePayload: true),
					data: []
				)
			}
		}
		let value = String(repeating: "x", count: 75_000)
		for projectID in projectIDs {
			let result = service.saveEnvironments(
				vaultId: projectID,
				projectName: projectID,
				projectPath: "",
				environments: ["default": ["PAYLOAD": value]]
			)
			if case .failure = result {
				Issue.record("Could not create project-unlock fixture")
				return
			}
		}
		_ = service.listProjectsResult()

		let samples = (0..<5).map { _ -> Double in
			let start = ContinuousClock.now
			let result = service.listProjectsResult()
			guard case .success(let projects) = result, projects.count == projectIDs.count else {
				Issue.record("Could not decode project-unlock fixture")
				return .infinity
			}
			return milliseconds(start.duration(to: .now))
		}
		print("ROUND2_BENCH project_unlock_ms median=\(median(samples)) samples=\(samples)")
	}

	@Test("generated project unlock peak-RSS benchmark")
	func generatedProjectUnlockRSS() {
		let projectCount = 500
		let service = KeychainService(
			testingService: "dev.lpm.vault.round2-generated-bench",
			backend: GeneratedProjectKeychainBackend(
				projectCount: projectCount,
				valueBytes: 75_000
			)
		)
		guard case .success(let warmProjects) = service.listProjectsResult(),
			warmProjects.count == projectCount
		else {
			Issue.record("Could not warm the generated project-unlock fixture")
			return
		}

		let samples = (0..<5).map { _ -> Double in
			let start = ContinuousClock.now
			let result = service.listProjectsResult()
			guard case .success(let projects) = result, projects.count == projectCount else {
				Issue.record("Could not decode the generated project-unlock fixture")
				return .infinity
			}
			return milliseconds(start.duration(to: .now))
		}
		print(
			"ROUND2_BENCH generated_project_unlock_ms median=\(median(samples)) samples=\(samples)"
		)
	}

	private func makeProjects(projectCount: Int, keysPerProject: Int) -> [VaultProject] {
		(0..<projectCount).map { project in
			let secrets = Dictionary(uniqueKeysWithValues: (0..<keysPerProject).map { key in
				("K\(key)", "value-\(project)-\(key)")
			})
			return VaultProject(
				id: "project-\(project)",
				name: "Project \(project)",
				path: "",
				environments: ["default": secrets]
			)
		}
	}

	private func milliseconds(_ duration: Duration) -> Double {
		let components = duration.components
		return Double(components.seconds) * 1_000
			+ Double(components.attoseconds) / 1_000_000_000_000_000
	}

	private func median(_ values: [Double]) -> Double {
		values.sorted()[values.count / 2]
	}
}

private struct GeneratedProjectKeychainBackend: KeychainStoreBackend {
	private let indexData: Data
	private let payloadData: Data

	init(projectCount: Int, valueBytes: Int) {
		let index = (0..<projectCount).map { project in
			[
				"id": "generated-project-\(project)",
				"name": "Generated Project \(project)",
				"path": "",
			]
		}
		indexData = try! JSONSerialization.data(withJSONObject: index)
		payloadData = try! JSONSerialization.data(withJSONObject: [
			"environments": [
				"default": ["PAYLOAD": String(repeating: "x", count: valueBytes)]
			]
		])
	}

	func read(
		service: String,
		account: String
	) throws -> Data? {
		let source = account == "__index__" ? indexData : payloadData
		return source.withUnsafeBytes { Data(bytes: $0.baseAddress!, count: $0.count) }
	}

	func write(
		service: String,
		account: String,
		data: Data
	) throws {}

	func add(
		service: String,
		account: String,
		data: Data
	) throws {}

	func delete(
		service: String,
		account: String
	) throws -> Bool { false }
}

private extension Sequence {
	func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
		var result: [T] = []
		result.reserveCapacity(underestimatedCount)
		for element in self { result.append(try await transform(element)) }
		return result
	}
}
