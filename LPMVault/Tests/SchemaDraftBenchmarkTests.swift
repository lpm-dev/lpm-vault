import Foundation
import Testing

@testable import LPMVault

/// Timings of schema drafts on the largest schemas the LPM CLI accepts, in
/// a debug build, where they're several times slower than in the app.
/// Run with SCHEMA_DRAFT_BENCHMARKS=1; they're timing-sensitive, so not in CI.
@Suite(
	"Schema draft benchmarks",
	.serialized,
	.enabled(if: ProcessInfo.processInfo.environment["SCHEMA_DRAFT_BENCHMARKS"] == "1")
)
struct SchemaDraftBenchmarkTests {
	typealias Draft = ProjectEnvSchemaDraft

	/// 4096 rules, the most the LPM CLI accepts, with long names.
	private func schema(_ prefix: String) -> LPMConfigJSON {
		.object([.init(key: "vars", value: .object((0..<4096).map { index in
			.init(key: "\(prefix)_\(String(repeating: "N", count: 200))_\(index)", value: .object([
				.init(key: "format", value: .string("url")),
				.init(key: "pattern", value: .string("^https://[a-z]+\\.example\\.com/\(index)$")),
			]))
		}))])
	}

	@Test("merging a draft onto a file whose 4096 rules all changed")
	func rebaseOfReplacedSchema() {
		let old = schema("OLD")
		let new = schema("NEW")
		var draft = Draft(schema: old)
		draft.set(.declared(.object([])), for: .key("ADDED"))
		let milliseconds = median { var copy = draft; copy.rebase(onto: new) }
		print("rebase 4096→4096 disjoint: \(milliseconds) ms")
		#expect(milliseconds < 40)
		let empty = median { var copy = Draft(schema: old); copy.rebase(onto: new) }
		print("rebase of an empty draft: \(empty) ms")
		#expect(empty < 5)
	}

	@Test("reading every row's declaration of a 4096-rule schema")
	func declarationsOfEveryRow() {
		let base = schema("ROW")
		let draft = Draft(schema: base)
		let items: [Draft.Item] = Draft.items(in: base).map(\.item)
		let milliseconds = median { for item in items { _ = draft.declaration(of: item) } }
		print("declaration(of:) × 4096: \(milliseconds) ms")
		#expect(milliseconds < 5)
	}

	@Test("diffing a 150,000-value enum with two values removed")
	func diffOfHugeEnum() {
		let values = (0..<150_000).map { LPMConfigJSON.string("v\($0)") }
		var draft = Draft(schema: .object([.init(key: "vars", value: .object([.init(key: "MODE", value: .object([.init(key: "enum", value: .array(values))]))]))]))
		draft.set(.declared(.object([.init(key: "enum", value: .array(Array(values.dropFirst().dropLast())))])), for: .key("MODE"))
		var lines = 0
		let milliseconds = median { lines = draft.diff(for: .key("MODE"))?.lines.count ?? 0 }
		print("diff of a 150k enum: \(milliseconds) ms, \(lines) lines")
		#expect(lines < 30)
		#expect(milliseconds < 700)
	}

	@Test("diffing 500 changed non-ASCII lines")
	func diffOfNonASCIILines() {
		let old = (0..<500).map { "\"\(String(repeating: "é", count: 2000))\($0)\"," }
		let new = (0..<500).map { "\"\(String(repeating: "é", count: 2000))\($0 + 1000)\"," }
		let milliseconds = median { _ = Draft.lineDiff(from: ["{"] + old + ["}"], to: ["{"] + new + ["}"]) }
		print("diff of 500×500 non-ASCII lines: \(milliseconds) ms")
		#expect(milliseconds < 400)
	}

	@Test("comparing 4096 rules member by member in another order")
	func equivalenceOfReorderedRules() {
		let rules = (0..<4096).map { index -> LPMConfigJSON in
			.object([.init(key: "format", value: .string("url")), .init(key: "default", value: .string("https://\(index)")), .init(key: "required", value: .bool(true))])
		}
		let reordered = rules.map { rule -> LPMConfigJSON in
			guard case .object(let members) = rule else { return rule }
			return .object(members.reversed())
		}
		let milliseconds = median { for (a, b) in zip(rules, reordered) { _ = a.isEquivalent(to: b) } }
		print("isEquivalent × 4096 reordered: \(milliseconds) ms")
		#expect(milliseconds < 25)
	}

	private func median(_ operation: () -> Void) -> Double {
		var samples: [Double] = []
		for _ in 0..<7 {
			let start = ContinuousClock.now
			operation()
			let elapsed = start.duration(to: .now)
			samples.append(Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15)
		}
		return samples.sorted()[samples.count / 2]
	}
}
