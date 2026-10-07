import Foundation
import Sparkle

enum VaultReleaseChannel: String, CaseIterable, Identifiable {
	case stable, nightly
	var id: String { rawValue }
	var title: String { self == .stable ? "Stable" : "Nightly" }
	var sparkleChannels: Set<String> { self == .nightly ? ["nightly"] : [] }
}

struct VaultBuildInfo {
	let version: String
	let build: String
	let channel: VaultReleaseChannel
	let date: String
	let commit: String

	init(info: [String: Any] = Bundle.main.infoDictionary ?? [:]) {
		version = info["CFBundleShortVersionString"] as? String ?? "Development build"
		build = info["CFBundleVersion"] as? String ?? ""
		channel = (info["LPMReleaseChannel"] as? String).flatMap(VaultReleaseChannel.init(rawValue:)) ?? .stable
		date = info["LPMReleaseDate"] as? String ?? ""
		commit = info["LPMReleaseCommit"] as? String ?? ""
	}

	var displayVersion: String {
		if channel == .nightly {
			return [version + " Nightly", date, String(commit.prefix(7))].filter { !$0.isEmpty }.joined(separator: " · ")
		}
		return build.isEmpty ? version : "\(version) (build \(build))"
	}
}

@MainActor
protocol VaultUpdateDriver: AnyObject {
	var canCheckForUpdates: Bool { get }
	var availableUpdateVersion: String? { get }
	var availabilityChanged: ((Bool) -> Void)? { get set }
	var updateChanged: ((String?) -> Void)? { get set }
	func start()
	func checkForUpdates()
	func setChannel(_ channel: VaultReleaseChannel)
}

@Observable
@MainActor
final class UpdateChecker {
	static let channelDefaultsKey = "lpm-vault-update-channel"
	let buildInfo: VaultBuildInfo
	var channel: VaultReleaseChannel {
		didSet {
			guard channel != oldValue else { return }
			defaults.set(channel.rawValue, forKey: Self.channelDefaultsKey)
			availableUpdateVersion = nil
			driver?.setChannel(channel)
		}
	}
	var channelDescription: String {
		if channel == .nightly { return "Nightly includes changes still being tested. Newer stable releases are also offered." }
		if buildInfo.channel == .nightly { return "Nightly updates are off. This nightly stays installed until a newer stable release is available." }
		return "Receive stable releases. Changing channels keeps your installed version until you install an update."
	}
	private(set) var canCheckForUpdates = false
	private(set) var availableUpdateVersion: String?
	@ObservationIgnored private let driver: (any VaultUpdateDriver)?
	@ObservationIgnored private var started = false
	@ObservationIgnored private let defaults: UserDefaults

	init(driver: (any VaultUpdateDriver)? = nil, defaults: UserDefaults = .standard, buildInfo: VaultBuildInfo = VaultBuildInfo()) {
		self.defaults = defaults
		self.buildInfo = buildInfo
		if let saved = defaults.string(forKey: Self.channelDefaultsKey) {
			channel = VaultReleaseChannel(rawValue: saved) ?? .stable
		} else {
			channel = buildInfo.channel
			if buildInfo.channel == .nightly { defaults.set(buildInfo.channel.rawValue, forKey: Self.channelDefaultsKey) }
		}
		if let driver {
			self.driver = driver
		} else {
			#if DEBUG
			self.driver = nil
			#else
			self.driver = Bundle.main.bundleURL.pathExtension == "app" ? SparkleUpdateDriver() : nil
			#endif
		}
		self.driver?.setChannel(channel)
	}

	func start() {
		guard !started, let driver else { return }
		started = true
		driver.availabilityChanged = { [weak self] available in
			self?.canCheckForUpdates = available
		}
		driver.updateChanged = { [weak self] version in
			self?.availableUpdateVersion = version
		}
		driver.start()
		canCheckForUpdates = driver.canCheckForUpdates
		availableUpdateVersion = driver.availableUpdateVersion
	}

	func checkForUpdates() {
		guard started, let driver, driver.canCheckForUpdates else { return }
		driver.checkForUpdates()
	}
}

@MainActor
private final class SparkleUpdateDriver: NSObject, VaultUpdateDriver, @preconcurrency SPUStandardUserDriverDelegate, SPUUpdaterDelegate {
	var availabilityChanged: ((Bool) -> Void)?
	var updateChanged: ((String?) -> Void)?
	private(set) var availableUpdateVersion: String? {
		didSet { updateChanged?(availableUpdateVersion) }
	}
	private lazy var controller = SPUStandardUpdaterController(
		startingUpdater: false, updaterDelegate: self, userDriverDelegate: self
	)
	private var observation: NSKeyValueObservation?
	private var channel: VaultReleaseChannel = .stable
	private var pendingChannel: VaultReleaseChannel = .stable
	private var started = false

	func setChannel(_ channel: VaultReleaseChannel) {
		pendingChannel = channel
		if !started { self.channel = channel }
		else if canCheckForUpdates { applyPendingChannel() }
	}

	private func applyPendingChannel() {
		guard channel != pendingChannel else { return }
		channel = pendingChannel
		availableUpdateVersion = nil
		controller.updater.resetUpdateCycleAfterShortDelay()
	}

	func allowedChannels(for updater: SPUUpdater) -> Set<String> { channel.sparkleChannels }

	var canCheckForUpdates: Bool { controller.updater.canCheckForUpdates }

	func start() {
		started = true
		observation = controller.updater.observe(\.canCheckForUpdates, options: [.new]) {
			[weak self] _, change in
			let available = change.newValue ?? false
			Task { @MainActor [weak self] in
				if available { self?.applyPendingChannel() }
				self?.availabilityChanged?(available)
			}
		}
		controller.startUpdater()
	}

	func checkForUpdates() {
		controller.checkForUpdates(nil)
	}

	var supportsGentleScheduledUpdateReminders: Bool { true }

	func standardUserDriverWillHandleShowingUpdate(
		_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
	) {
		availableUpdateVersion = update.displayVersionString
	}

	func standardUserDriverWillFinishUpdateSession() {
		availableUpdateVersion = nil
	}
}
