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
	var sessionInProgress: Bool { get }
	var hasPendingUpdate: Bool { get }
	var availableUpdateVersion: String? { get }
	var stateChanged: (() -> Void)? { get set }
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
	private var selectedChannel: VaultReleaseChannel
	var channel: VaultReleaseChannel {
		get { selectedChannel }
		set {
			guard newValue != selectedChannel else { return }
			if started {
				guard let driver, driver.canCheckForUpdates, !driver.sessionInProgress, !driver.hasPendingUpdate else { return }
			}
			selectedChannel = newValue
			defaults.set(newValue.rawValue, forKey: Self.channelDefaultsKey)
			availableUpdateVersion = nil
			driver?.setChannel(newValue)
		}
	}
	var channelDescription: String {
		if channel == .nightly { return "Nightly includes changes still being tested. Newer stable releases are also offered." }
		if buildInfo.channel == .nightly { return "Nightly updates are off. This nightly stays installed until a newer stable release is available." }
		return "Receive stable releases. Changing channels keeps your installed version until you install an update."
	}
	private(set) var canCheckForUpdates = false
	private(set) var canChangeChannel = false
	private(set) var hasPendingUpdate = false
	private(set) var availableUpdateVersion: String?
	@ObservationIgnored private let driver: (any VaultUpdateDriver)?
	@ObservationIgnored private var started = false
	@ObservationIgnored private let defaults: UserDefaults

	init(driver: (any VaultUpdateDriver)? = nil, defaults: UserDefaults = .standard, buildInfo: VaultBuildInfo = VaultBuildInfo()) {
		self.defaults = defaults
		self.buildInfo = buildInfo
		if let saved = defaults.string(forKey: Self.channelDefaultsKey) {
			selectedChannel = VaultReleaseChannel(rawValue: saved) ?? .stable
		} else {
			selectedChannel = buildInfo.channel
			if buildInfo.channel == .nightly { defaults.set(buildInfo.channel.rawValue, forKey: Self.channelDefaultsKey) }
		}
		if let driver {
			self.driver = driver
		} else {
			#if DEBUG
			self.driver = nil
			#else
			self.driver = Bundle.main.bundleURL.pathExtension == "app" ? SparkleUpdateDriver(defaults: defaults, buildInfo: buildInfo) : nil
			#endif
		}
		self.driver?.setChannel(channel)
	}

	func start() {
		guard !started, let driver else { return }
		started = true
		driver.stateChanged = { [weak self] in
			self?.refreshState()
		}
		driver.updateChanged = { [weak self] version in
			self?.availableUpdateVersion = version
		}
		driver.start()
		refreshState()
		availableUpdateVersion = driver.availableUpdateVersion
	}

	private func refreshState() {
		guard let driver else { return }
		canCheckForUpdates = driver.canCheckForUpdates
		hasPendingUpdate = driver.hasPendingUpdate
		canChangeChannel = canCheckForUpdates && !driver.sessionInProgress && !hasPendingUpdate
	}

	func checkForUpdates() {
		guard started, let driver, driver.canCheckForUpdates else { return }
		driver.checkForUpdates()
	}
}

@MainActor
final class SparkleUpdateDriver: NSObject, VaultUpdateDriver, @preconcurrency SPUStandardUserDriverDelegate, SPUUpdaterDelegate {
	static let pendingInstallerDefaultsKey = "lpm-vault-pending-update-installer"
	private static let resolvedInstallerPrefix = "lpm-vault-resolved-update-"
	private struct PendingInstaller {
		let build: String
		let generation: String
	}
	private let defaults: UserDefaults
	private var cycleInstaller: PendingInstaller?

	init(defaults: UserDefaults = .standard, buildInfo: VaultBuildInfo = VaultBuildInfo()) {
		self.defaults = defaults
		super.init()
		cycleInstaller = pendingInstaller
		if let pending = cycleInstaller,
			SUStandardVersionComparator.default.compareVersion(buildInfo.build, toVersion: pending.build) != .orderedAscending {
			resolve(pending)
		}
	}

	var stateChanged: (() -> Void)?
	var updateChanged: ((String?) -> Void)?
	private var retainedDownload = false {
		didSet { stateChanged?() }
	}
	var hasPendingUpdate: Bool {
		retainedDownload || pendingInstaller.map { !isResolved($0) } == true
	}

	private var pendingInstaller: PendingInstaller? {
		guard let value = defaults.dictionary(forKey: Self.pendingInstallerDefaultsKey),
			let build = value["build"] as? String, let generation = value["generation"] as? String else { return nil }
		return PendingInstaller(build: build, generation: generation)
	}

	private func isResolved(_ installer: PendingInstaller) -> Bool {
		defaults.bool(forKey: Self.resolvedInstallerPrefix + installer.generation)
	}

	private func resolve(_ installer: PendingInstaller) {
		// A separate resolution key cannot overwrite another process's newer installer record.
		defaults.set(true, forKey: Self.resolvedInstallerPrefix + installer.generation)
	}

	private func recordPendingInstaller(_ item: SUAppcastItem, newGeneration: Bool = false) {
		if !newGeneration, let pending = pendingInstaller, pending.build == item.versionString, !isResolved(pending) {
			cycleInstaller = pending
		} else {
			let pending = PendingInstaller(build: item.versionString, generation: UUID().uuidString)
			defaults.set(["build": pending.build, "generation": pending.generation], forKey: Self.pendingInstallerDefaultsKey)
			cycleInstaller = pending
		}
		stateChanged?()
	}

	private func clearPendingUpdate() {
		retainedDownload = false
		if let cycleInstaller { resolve(cycleInstaller) }
		stateChanged?()
	}
	private(set) var availableUpdateVersion: String? {
		didSet { updateChanged?(availableUpdateVersion) }
	}
	private lazy var controller = SPUStandardUpdaterController(
		startingUpdater: false, updaterDelegate: self, userDriverDelegate: self
	)
	private var availabilityObservation: NSKeyValueObservation?
	private var sessionObservation: NSKeyValueObservation?
	private var channel: VaultReleaseChannel = .stable
	private var started = false

	func setChannel(_ channel: VaultReleaseChannel) {
		guard self.channel != channel else { return }
		guard !started || (canCheckForUpdates && !sessionInProgress && !hasPendingUpdate) else { return }
		self.channel = channel
		availableUpdateVersion = nil
		if started { controller.updater.resetUpdateCycleAfterShortDelay() }
	}

	func allowedChannels(for updater: SPUUpdater) -> Set<String> { channel.sparkleChannels }

	var canCheckForUpdates: Bool { controller.updater.canCheckForUpdates }
	var sessionInProgress: Bool { controller.updater.sessionInProgress }

	func start() {
		started = true
		availabilityObservation = controller.updater.observe(\.canCheckForUpdates, options: [.new]) {
			[weak self] _, _ in
			Task { @MainActor [weak self] in self?.stateChanged?() }
		}
		sessionObservation = controller.updater.observe(\.sessionInProgress, options: [.new]) {
			[weak self] _, change in
			MainActor.assumeIsolated {
				if change.newValue == true { self?.cycleInstaller = self?.pendingInstaller }
				self?.stateChanged?()
			}
		}
		controller.startUpdater()
		NotificationCenter.default.addObserver(self, selector: #selector(defaultsChanged), name: UserDefaults.didChangeNotification, object: defaults)
	}

	@objc nonisolated private func defaultsChanged() {
		Task { @MainActor [weak self] in self?.stateChanged?() }
	}

	func checkForUpdates() {
		if !sessionInProgress { cycleInstaller = pendingInstaller }
		controller.checkForUpdates(nil)
	}

	var supportsGentleScheduledUpdateReminders: Bool { true }

	func standardUserDriverWillHandleShowingUpdate(
		_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
	) {
		switch state.stage {
		case .installing: recordPendingInstaller(update)
		case .downloaded: retainedDownload = true
		case .notDownloaded: clearPendingUpdate()
		@unknown default: retainedDownload = true
		}
		availableUpdateVersion = update.displayVersionString
	}

	func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) {
		retainedDownload = true
	}

	func updater(_ updater: SPUUpdater, didExtractUpdate item: SUAppcastItem) {
		recordPendingInstaller(item, newGeneration: true)
	}

	func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock: @escaping () -> Void) -> Bool {
		recordPendingInstaller(item)
		return false
	}

	func updater(_ updater: SPUUpdater, userDidMake choice: SPUUserUpdateChoice, forUpdate item: SUAppcastItem, state: SPUUserUpdateState) {
		if choice == .skip { clearPendingUpdate() }
	}

	func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
		let nativeError = error as NSError
		guard nativeError.domain != SUSparkleErrorDomain || nativeError.code != SUError.installationAuthorizeLaterError.rawValue else { return }
		clearPendingUpdate()
	}

	func standardUserDriverWillFinishUpdateSession() {
		availableUpdateVersion = nil
	}
}
