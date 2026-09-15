import Foundation
import Sparkle

@MainActor
protocol VaultUpdateDriver: AnyObject {
	var canCheckForUpdates: Bool { get }
	var availabilityChanged: ((Bool) -> Void)? { get set }
	func start()
	func checkForUpdates()
}

@Observable
@MainActor
final class UpdateChecker {
	private(set) var canCheckForUpdates = false
	@ObservationIgnored private let driver: (any VaultUpdateDriver)?
	@ObservationIgnored private var started = false

	init(driver: (any VaultUpdateDriver)? = nil) {
		if let driver {
			self.driver = driver
		} else {
			#if DEBUG
			self.driver = nil
			#else
			self.driver = Bundle.main.bundleURL.pathExtension == "app" ? SparkleUpdateDriver() : nil
			#endif
		}
	}

	func start() {
		guard !started, let driver else { return }
		started = true
		driver.availabilityChanged = { [weak self] available in
			self?.canCheckForUpdates = available
		}
		driver.start()
		canCheckForUpdates = driver.canCheckForUpdates
	}

	func checkForUpdates() {
		guard started, let driver, driver.canCheckForUpdates else { return }
		driver.checkForUpdates()
	}
}

@MainActor
private final class SparkleUpdateDriver: VaultUpdateDriver {
	var availabilityChanged: ((Bool) -> Void)?
	private let controller = SPUStandardUpdaterController(
		startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil
	)
	private var observation: NSKeyValueObservation?

	var canCheckForUpdates: Bool { controller.updater.canCheckForUpdates }

	func start() {
		observation = controller.updater.observe(\.canCheckForUpdates, options: [.new]) {
			[weak self] _, change in
			let available = change.newValue ?? false
			Task { @MainActor [weak self] in
				self?.availabilityChanged?(available)
			}
		}
		controller.startUpdater()
	}

	func checkForUpdates() {
		controller.checkForUpdates(nil)
	}
}
