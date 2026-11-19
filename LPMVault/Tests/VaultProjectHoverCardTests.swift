import AppKit
import Foundation
import SwiftUI
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

extension SheetInteractionTests {
	@Suite("Project hover card, rendered", .serialized)
	@MainActor
	struct VaultProjectHoverCardRenderingTests {
		@Test("a project with no folder recorded, whose folder Connect CLI chose, has a folder on this Mac")
		func folderChosenInConnectCLI() async throws {
			let domain = "hover-card-\(UUID().uuidString)"
			let defaults = try #require(UserDefaults(suiteName: domain))
			defer { defaults.removePersistentDomain(forName: domain) }
			let folder = try ProjectIconFixture.folder()
			defer { try? FileManager.default.removeItem(at: folder) }
			let store = VaultStore(keychainService: MockKeychainService(), biometricService: MockBiometricService(), apiService: MockAPIService(),
				preferences: defaults, authTokenProvider: { _, _ in nil })
			let project = VaultProject(id: "hover", name: "hover-app", path: "", environments: ["default": [:]])
			store.projects = [project]
			store.isUnlocked = true
			defer { store.lock() }
			let host = SheetTestHost(VaultProjectHoverCard(store: store, project: project), size: NSSize(width: 320, height: 320))
			defer { host.window.close() }
			#expect(try await host.waitForText("No project folder on this Mac"))
			store.chooseProjectFolder(folder.path, for: "hover")
			#expect(try await host.waitForText("lpm.json not read yet"))
			#expect(try await !host.text().contains("No project folder"))
		}
	}
}
