import Foundation
import Testing

@testable import LPMVault

@Suite("Signed application updates")
@MainActor
struct UpdateCheckerTests {
	@Test("starting the updater more than once starts only one scheduler")
	func startsOnce() {
		let driver = TestUpdateDriver()
		let checker = UpdateChecker(driver: driver)
		checker.start()
		checker.start()
		#expect(driver.starts == 1)
		#expect(checker.canCheckForUpdates)
	}

	@Test("manual checks wait for startup and updater availability")
	func checksRespectAvailability() {
		let driver = TestUpdateDriver()
		let checker = UpdateChecker(driver: driver)
		checker.checkForUpdates()
		#expect(driver.checks == 0)
		checker.start()
		checker.checkForUpdates()
		#expect(driver.checks == 1)
		driver.canCheckForUpdates = false
		checker.checkForUpdates()
		#expect(driver.checks == 1)
		#expect(!checker.canCheckForUpdates)
		driver.canCheckForUpdates = true
		#expect(checker.canCheckForUpdates)
	}

	@Test("development builds cannot replace themselves with public releases")
	func developmentUpdatesAreDisabled() {
		#if DEBUG
		let checker = UpdateChecker()
		checker.start()
		#expect(!checker.canCheckForUpdates)
		#endif
	}
}

@MainActor
private final class TestUpdateDriver: VaultUpdateDriver {
	var canCheckForUpdates = false {
		didSet { availabilityChanged?(canCheckForUpdates) }
	}
	var availabilityChanged: ((Bool) -> Void)?
	var starts = 0
	var checks = 0
	func start() {
		starts += 1
		canCheckForUpdates = true
	}
	func checkForUpdates() { checks += 1 }
}
