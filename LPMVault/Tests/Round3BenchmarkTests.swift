import Darwin
import Foundation
import Testing

@testable import LPMVault

@Suite(
	"Round 3 performance benchmarks",
	.serialized,
	.enabled(if: ProcessInfo.processInfo.environment["ROUND3_BENCHMARKS"] == "1")
)
struct Round3BenchmarkTests {
	@Test("large schema push peak-RSS benchmark")
	@MainActor
	func largeSchemaPush() async throws {
		let directory = FileManager.default.temporaryDirectory
			.appendingPathComponent("round3-schema-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: directory) }
		let payloadBytes = 15 * 1024 * 1024
		let config = #"{"envSchema":{"vars":{"BIG":""#
			+ String(repeating: "x", count: payloadBytes)
			+ #""}}}"#
		try Data(config.utf8).write(to: directory.appendingPathComponent("lpm.json"))

		let service = makeService { _ in
			Round3Response(statusCode: 500, body: Data("{}".utf8), headers: [:])
		}
		let keychain = MockKeychainService()
		keychain.envStorage["schema-project"] = (
			name: "Schema",
			path: directory.path,
			environments: ["default": ["TOKEN": "secret"]]
		)
		let store = VaultStore(
			keychainService: keychain,
			biometricService: MockBiometricService(),
			apiService: MockAPIService(),
			personalSyncServiceFactory: { _ in service },
			stableSyncEncryptor: { _, _, _, _ in ("ciphertext", "wrapped") },
			authTokenProvider: { _, _ in "session-token" },
			authSessionClearer: { _ in }
		)
		store.projects = [VaultProject(
			id: "schema-project",
			name: "Schema",
			path: directory.path,
			environments: ["default": ["TOKEN": "secret"]]
		)]
		store.isUnlocked = true
		store.selectProject("schema-project")

		let start = ContinuousClock.now
		await store.pushToCloud()
		print(
			"ROUND3_BENCH schema_push_ms=\(milliseconds(start.duration(to: .now))) "
				+ "peak_rss_bytes=\(peakRSSBytes())"
		)
	}

	@Test("initial workspace derivation benchmark")
	@MainActor
	func initialWorkspaceDerivation() async {
		let keychain = MockKeychainService()
		for project in 0..<100 {
			keychain.envStorage["project-\(project)"] = (
				name: "Project \(project)",
				path: "",
				environments: ["default": Dictionary(uniqueKeysWithValues: (0..<500).map {
					("KEY_\($0)", "value-\(project)-\($0)")
				})]
			)
		}
		let store = VaultStore(
			keychainService: keychain,
			biometricService: MockBiometricService(),
			apiService: MockAPIService(),
			authSessionClearer: { _ in }
		)

		let heartbeatState = Round3HeartbeatState()
		let heartbeat = Task { @MainActor in
			while !heartbeatState.finished {
				let tick = ContinuousClock.now
				try? await Task.sleep(for: .milliseconds(2))
				heartbeatState.maximumGap = max(
					heartbeatState.maximumGap,
					milliseconds(tick.duration(to: .now))
				)
			}
		}
		let start = ContinuousClock.now
		#expect(await store.loadProjects())
		heartbeatState.finished = true
		await heartbeat.value
		print(
			"ROUND3_BENCH initial_workspace_ms=\(milliseconds(start.duration(to: .now))) "
				+ "main_actor_gap_ms=\(heartbeatState.maximumGap) "
				+ "peak_rss_bytes=\(peakRSSBytes())"
		)
	}

	private func makeService(
		handler: @escaping @Sendable (URLRequest) throws -> Round3Response
	) -> SyncService {
		let host = "\(UUID().uuidString.lowercased()).example"
		Round3Routes.shared.register(host: host, handler: handler)
		let configuration = URLSessionConfiguration.ephemeral
		configuration.protocolClasses = [Round3URLProtocol.self]
		return SyncService(
			baseURL: URL(string: "https://\(host)")!,
			session: URLSession(
				configuration: configuration,
				delegate: BoundedHTTPResponseDelegate(),
				delegateQueue: nil
			)
		)
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
}

@MainActor
private final class Round3HeartbeatState {
	var finished = false
	var maximumGap = 0.0
}

private struct Round3Response: Sendable {
	let statusCode: Int
	let body: Data
	let headers: [String: String]
}

private final class Round3Routes: @unchecked Sendable {
	static let shared = Round3Routes()
	private let lock = NSLock()
	private var handlers: [String: @Sendable (URLRequest) throws -> Round3Response] = [:]

	func register(
		host: String,
		handler: @escaping @Sendable (URLRequest) throws -> Round3Response
	) {
		lock.withLock { handlers[host] = handler }
	}

	func response(for request: URLRequest) throws -> Round3Response {
		let host = request.url?.host ?? ""
		let handler = lock.withLock { handlers[host] }
		return try handler?(request) ?? Round3Response(statusCode: 500, body: Data(), headers: [:])
	}
}

private final class Round3URLProtocol: URLProtocol {
	override class func canInit(with request: URLRequest) -> Bool { true }
	override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
	override func startLoading() {
		do {
			let response = try Round3Routes.shared.response(for: request)
			let http = HTTPURLResponse(
				url: request.url!,
				statusCode: response.statusCode,
				httpVersion: "HTTP/1.1",
				headerFields: response.headers
			)!
			client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
			client?.urlProtocol(self, didLoad: response.body)
			client?.urlProtocolDidFinishLoading(self)
		} catch {
			client?.urlProtocol(self, didFailWithError: error)
		}
	}
	override func stopLoading() {}
}
