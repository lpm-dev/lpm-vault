import Foundation
import Testing

@testable import LPMVault

@Suite("Project hover card")
@MainActor
struct VaultProjectHoverCardTests {
	@Test("the schema line says what the app has read of lpm.json, and how many keys fail it")
	func schemaLine() {
		typealias Card = VaultProjectHoverCard
		#expect(Card.schemaLine(state: nil, check: nil, hasFolder: false).text == "No project folder on this Mac")
		#expect(Card.schemaLine(state: nil, check: nil, hasFolder: true).text == "lpm.json not read yet")
		#expect(Card.schemaLine(state: .noFolder, check: nil, hasFolder: true).text == "No project folder on this Mac")
		#expect(Card.schemaLine(state: .unreadable(.init(location: "lpm.json", reason: "Not JSON")), check: nil, hasFolder: true).text == "lpm.json can’t be read")
		#expect(Card.failingLine(1).text == "1 key fails its rules" && Card.failingLine(3).text == "3 keys fail their rules")
		#expect(Card.failingLine(2).symbol == VaultSmartView.invalid.symbol, "Marked as failing keys are everywhere else")
	}

	@Test("counts say what they count: keys that differ, are missing, or fail their rules")
	func countsHaveUnits() {
		#expect(VaultSmartView.drift.summary(1) == "1 key differs")
		#expect(VaultSmartView.drift.summary(9) == "9 keys differ")
		#expect(VaultSmartView.missing.summary(1) == "1 key missing")
		#expect(VaultSmartView.missing.summary(3) == "3 keys missing")
		#expect(VaultSmartView.invalid.summary(0) == "0 keys invalid")
	}

	@Test("the last change reads as a time ago, and as just now within a minute")
	func relativeTime() {
		let now = Date(timeIntervalSinceReferenceDate: 815_000_000)
		#expect(VaultProjectHoverCard.relative(now.addingTimeInterval(-20), now: now) == "just now")
		#expect(VaultProjectHoverCard.relative(now.addingTimeInterval(-2 * 3600), now: now).contains("2 hours"))
	}
}
