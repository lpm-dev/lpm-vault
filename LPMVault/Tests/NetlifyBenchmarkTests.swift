import CryptoKit
import Darwin
import Foundation
import Testing

@testable import LPMVault

@Suite(
	"Netlify publishing benchmarks",
	.serialized,
	.enabled(if: ProcessInfo.processInfo.environment["NETLIFY_BENCHMARKS"] == "1")
)
struct NetlifyBenchmarkTests {
	@Test("recording a Netlify publish beside 100 unrelated vaults with large destination records")
	func recordBesideUnrelatedVaults() async throws {
		let keychain = MockKeychainService()
		let store = PublishingStore(service: keychain)
		let excluded = Set((0..<8_192).map { "EXCLUDED_KEY_\($0)" })
		for _ in 0..<100 {
			_ = try await store.save(vercelDestination(excluded: excluded), to: UUID().uuidString.lowercased()).get()
		}
		let production = netlifyDestination(.production)
		let previews = netlifyDestination(.deployPreview, source: "preview")
		for destination in [production, previews] { _ = try await store.save(destination, to: publishTestVault).get() }
		let fingerprint = Data(repeating: 7, count: PublishFingerprint.byteCount)
		let rssBefore = peakRSSBytes()
		var samples: [Double] = []
		for run in 0..<9 {
			let from = Date(timeIntervalSince1970: 1_760_000_000 + Double(run * 10))
			let to = from.addingTimeInterval(5)
			_ = try await store.recordPublish(
				[PublishHistory.Published(key: "SHARED", fingerprint: fingerprint, remoteID: "preview-\(run)", remoteUpdatedAt: from, publishedAsSecret: true)],
				to: previews.id, at: previews.target.location, choices: .init(leftOut: [], chosen: []), of: publishTestVault, at: from).get()
			let advance = PublishHistory.Advance(key: "SHARED", from: from, to: to, remoteIDs: ["preview-\(run)": "preview-\(run)"])
			let started = ContinuousClock.now
			_ = try await store.recordPublish(
				[PublishHistory.Published(key: "SHARED", fingerprint: fingerprint, remoteID: "production-\(run)", remoteUpdatedAt: to, publishedAsSecret: true)],
				to: production.id, at: production.target.location, choices: .init(leftOut: [], chosen: []), advancing: [advance],
				of: publishTestVault, at: to).get()
			samples.append(milliseconds(ContinuousClock.now - started))
			#expect(try await store.history(of: previews.id, in: publishTestVault).get().keys["SHARED"]?.remoteUpdatedAt == to)
		}
		samples.sort()
		print("NETLIFY_BENCH unrelated_vaults=100 excluded_keys=8192 record_ms_median=\(samples[samples.count / 2]) "
			+ "rss_before_bytes=\(rssBefore) peak_rss_bytes=\(peakRSSBytes())")
	}

	private func milliseconds(_ duration: Duration) -> Double {
		let components = duration.components
		return Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1_000_000_000_000_000
	}

	private func peakRSSBytes() -> Int64 {
		var usage = rusage()
		guard getrusage(RUSAGE_SELF, &usage) == 0 else { return -1 }
		return Int64(usage.ru_maxrss)
	}
}
