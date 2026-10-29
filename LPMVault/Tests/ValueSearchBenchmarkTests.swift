import Darwin
import Foundation
import Testing

@testable import LPMVault

/// Peak memory of a value search over many large projects. Run each mode in
/// its own process, so one mode's high-water mark doesn't hide the other's:
///
///     VALUE_SEARCH_BENCHMARKS=1 VALUE_SEARCH_BENCH_MODE=scan swift test --skip-build --filter ValueSearchBenchmarkTests
///     VALUE_SEARCH_BENCHMARKS=1 VALUE_SEARCH_BENCH_MODE=all swift test --skip-build --filter ValueSearchBenchmarkTests
///
/// `scan` runs the search as the app does, one project at a time; `all`
/// holds every project's values at once, as a search that loaded them all would.
@Suite(
	"Value search benchmarks",
	.serialized,
	.enabled(if: ProcessInfo.processInfo.environment["VALUE_SEARCH_BENCHMARKS"] == "1")
)
struct ValueSearchBenchmarkTests {
	private static let environment = ProcessInfo.processInfo.environment
	private static let projectCount = Int(environment["VALUE_SEARCH_BENCH_PROJECTS"] ?? "") ?? 200
	private static let environments = ["default", "development", "preview", "staging", "production"]
	private static let keysPerEnvironment = 200

	@Test("peak memory of a search over many large projects")
	func peakMemory() async throws {
		let mode = Self.environment["VALUE_SEARCH_BENCH_MODE"] ?? "scan"
		let source = GeneratedProjectsSource(environments: Self.environments, keysPerEnvironment: Self.keysPerEnvironment)
		let targets = (0..<Self.projectCount).map { index in
			ValueSearchTarget(id: "p\(index)", name: "Project \(index)",
				account: ValueSearchAccount(account: .personal, name: "Personal vault"), environments: Self.environments)
		}
		let payloadBytes = source.payload(of: "p0").count
		let residentBefore = residentBytes()
		let clock = ContinuousClock()
		let started = clock.now
		var groups = 0
		var hits = 0
		switch mode {
		case "all":
			var all: [VaultProject] = []
			for target in targets {
				if case .success(let project?) = await source.withValues(of: target.id, { $0 }) { all.append(project) }
			}
			var seen: [ExactText: Int] = [:]
			for project in all {
				for values in project.environments.values {
					for value in values.values { seen[ExactText(value), default: 0] += 1 }
				}
			}
			groups = seen.values.lazy.filter { $0 > 1 }.count
			hits = all.count
		default:
			let reuse = try #require(await ValueSearchScan.reuse(in: targets, from: source, secrecy: { _ in .none }) { _ in true })
			groups = reuse.groups.count
			let matcher = try #require(ValueMatcher(term: GeneratedProjectsSource.sharedValue(key: 0), findsContainingValues: true))
			await ValueSearchScan.find(matcher, in: targets, from: source) { _, outcome in
				if case .searched(let found) = outcome { hits += found.count }
				return true
			}
		}
		let elapsed = started.duration(to: clock.now)
		let peak = peakRSSBytes()
		print("VALUE_SEARCH_BENCH mode=\(mode) projects=\(Self.projectCount) values=\(Self.projectCount * Self.environments.count * Self.keysPerEnvironment) "
			+ "payload_bytes_per_project=\(payloadBytes) resident_before=\(residentBefore) peak_rss=\(peak) "
			+ "peak_over_baseline=\(peak - residentBefore) groups=\(groups) hits=\(hits) elapsed=\(elapsed)")
	}
}

/// Projects whose values are made as each is read, then decoded from JSON,
/// as a Keychain read decodes a payload: nothing is held between reads.
private struct GeneratedProjectsSource: ValueSearchSource {
	let environments: [String]
	let keysPerEnvironment: Int

	/// A value every project stores under one key in each environment, as a
	/// credential reused everywhere would be.
	static func sharedValue(key: Int) -> String {
		"sk_live_shared_\(key)_ZQ8vK2mN9pL4xR7tW1yB6cF3hJ5nD0sA"
	}

	func payload(of projectID: String) -> Data {
		var generator = SeededGenerator(seed: projectID.utf8.reduce(0xCBF2_9CE4_8422_2325) { ($0 ^ UInt64($1)) &* 0x100_0000_01B3 })
		var environmentsJSON: [String: [String: String]] = [:]
		for environment in environments {
			var values: [String: String] = [:]
			for key in 0..<keysPerEnvironment {
				values["APP_SETTING_\(key)"] = key.isMultiple(of: 10)
					? Self.sharedValue(key: key)
					: SecretValueGenerator.generate(.alphanumeric, length: 64, using: &generator)
			}
			environmentsJSON[environment] = values
		}
		return (try? JSONSerialization.data(withJSONObject: ["environments": environmentsJSON])) ?? Data()
	}

	func withValues<T>(of projectID: String, _ body: (VaultProject) -> T) async -> Result<T?, KeychainError> {
		guard let decoded = try? JSONDecoder().decode(Payload.self, from: payload(of: projectID)) else { return .failure(.encodingFailed) }
		return .success(body(VaultProject(id: projectID, name: projectID, path: "", environments: decoded.environments)))
	}
}

private struct Payload: Decodable {
	let environments: [String: [String: String]]
}

private struct SeededGenerator: RandomNumberGenerator {
	var state: UInt64

	init(seed: UInt64) {
		state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
	}

	mutating func next() -> UInt64 {
		state ^= state << 13
		state ^= state >> 7
		state ^= state << 17
		return state
	}
}

private func peakRSSBytes() -> Int64 {
	var usage = rusage()
	guard getrusage(RUSAGE_SELF, &usage) == 0 else { return -1 }
	return Int64(usage.ru_maxrss)
}

private func residentBytes() -> Int64 {
	var info = mach_task_basic_info()
	var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
	let status = withUnsafeMutablePointer(to: &info) {
		$0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
	}
	return status == KERN_SUCCESS ? Int64(info.resident_size) : -1
}
