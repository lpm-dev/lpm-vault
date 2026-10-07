import AppKit
import SwiftUI
import Sparkle
import Testing
import Vision

@testable import LPMVault

@Suite("Signed application updates")
@MainActor
struct UpdateCheckerTests {
	@Test("release channels keep nightly updates opt in and include stable releases")
	func nativeChannels() {
		#expect(VaultReleaseChannel.stable.sparkleChannels.isEmpty)
		#expect(VaultReleaseChannel.nightly.sparkleChannels == ["nightly"])
	}

	@Test("a direct nightly installation keeps its channel when a newer stable build replaces it")
	func nightlyDefaultSurvivesStableReplacement() throws {
		let domain = "nightly-default-\(UUID().uuidString)"
		let defaults = try #require(UserDefaults(suiteName: domain))
		defer { defaults.removePersistentDomain(forName: domain) }
		let nightly = UpdateChecker(defaults: defaults, buildInfo: VaultBuildInfo(info: ["LPMReleaseChannel": "nightly"]))
		#expect(nightly.channel == .nightly)
		#expect(UpdateChecker(defaults: defaults, buildInfo: VaultBuildInfo(info: [:])).channel == .nightly)
	}

	@Test("the installed build supplies the initial channel but saved choices survive replacement")
	func channelPersistence() throws {
		let domain = "update-channel-\(UUID().uuidString)"
		let defaults = try #require(UserDefaults(suiteName: domain))
		defer { defaults.removePersistentDomain(forName: domain) }
		let nightly = VaultBuildInfo(info: ["CFBundleShortVersionString": "1.1.0", "CFBundleVersion": "6.0.1",
			"LPMReleaseChannel": "nightly", "LPMReleaseDate": "2026-10-07", "LPMReleaseCommit": "abcdef0123456789"])
		let driver = TestUpdateDriver()
		let checker = UpdateChecker(driver: driver, defaults: defaults, buildInfo: nightly)
		#expect(checker.channel == .nightly)
		#expect(driver.channels == [.nightly])
		#expect(nightly.displayVersion == "1.1.0 Nightly · 2026-10-07 · abcdef0")
		checker.start()
		driver.availableUpdateVersion = "Another nightly"
		checker.channel = .stable
		#expect(checker.availableUpdateVersion == nil)
		#expect(checker.buildInfo.channel == .nightly)
		#expect(checker.channelDescription.contains("until a newer stable"))
		#expect(driver.channels == [.nightly, .stable])
		#expect(driver.checks == 0)
		#expect(UpdateChecker(defaults: defaults, buildInfo: nightly).channel == .stable)
		defaults.set("unexpected", forKey: UpdateChecker.channelDefaultsKey)
		#expect(UpdateChecker(defaults: defaults, buildInfo: nightly).channel == .stable)
		defaults.removeObject(forKey: UpdateChecker.channelDefaultsKey)
		#expect(UpdateChecker(defaults: defaults, buildInfo: VaultBuildInfo(info: [:])).channel == .stable)
	}

	@Test("stable versions show the installed build and incomplete metadata has an honest fallback")
	func versionMetadata() {
		#expect(VaultBuildInfo(info: ["CFBundleShortVersionString": "1.0.1", "CFBundleVersion": "6"]).displayVersion == "1.0.1 (build 6)")
		#expect(VaultBuildInfo(info: [:]).displayVersion == "Development build")
	}

	@Test("settings expose a working channel picker before and after sign-in", arguments: [false, true])
	func settingsChannelPicker(signedIn: Bool) async throws {
		let domain = "update-settings-\(UUID().uuidString)"
		let defaults = try #require(UserDefaults(suiteName: domain))
		defer { defaults.removePersistentDomain(forName: domain) }
		let driver = TestUpdateDriver()
		let checker = UpdateChecker(driver: driver, defaults: defaults,
			buildInfo: VaultBuildInfo(info: ["CFBundleShortVersionString": "1.0.1", "CFBundleVersion": "6"]))
		checker.start()
		let store = VaultStore(keychainService: MockKeychainService(), biometricService: MockBiometricService(),
			apiService: MockAPIService(), authTokenProvider: { _, _ in nil })
		if signedIn {
			store.currentUser = LPMUser(id: "updates-test", username: "demo", name: nil, email: nil,
				avatarUrl: nil, plan: "free", createdAt: nil, orgs: nil)
		}
		let host = NSHostingView(rootView: AuthStatusView(store: store).environment(checker)
			.environment(VaultAppearanceSettings(defaults: defaults)).environment(\.colorScheme, .light))
		let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 700),
			styleMask: [.titled], backing: .buffered, defer: false)
		window.isReleasedWhenClosed = false
		window.contentView = host
		window.orderBack(nil)
		defer { window.close() }
		func channelPicker(_ view: NSView) -> NSSegmentedControl? {
			if let picker = view as? NSSegmentedControl, picker.segmentCount == 2 { return picker }
			return view.subviews.lazy.compactMap { channelPicker($0) }.first
		}
		for _ in 0..<100 {
			host.layoutSubtreeIfNeeded()
			if channelPicker(host) != nil { break }
			try await Task.sleep(for: .milliseconds(10))
		}
		let picker = try #require(channelPicker(host))
		#expect(picker.label(forSegment: 0) == "Stable")
		#expect(picker.label(forSegment: 1) == "Nightly")
		picker.selectedSegment = 1
		#expect(picker.sendAction(picker.action, to: picker.target))
		#expect(checker.channel == .nightly)
		#expect(UpdateChecker(defaults: defaults).channel == .nightly)
		#expect(driver.checks == 0)
		let bitmap = try renderTitleBar(host)
		let data = try #require(bitmap.representation(using: .png, properties: [:]))
		Attachment.record(data, named: "updates-settings-\(signedIn).png")
		try data.write(to: URL(fileURLWithPath: "/tmp/vault-nightly-settings-\(signedIn).png"))
		if !signedIn {
			let image = try #require(bitmap.cgImage)
			let lines = try await RenderedText.lines(in: image, level: .accurate)
			let explanation = try #require(lines.first { $0.text.contains("Sign in to sync personal") })
			let signIn = try #require(lines.first { $0.text.contains("Sign in with browser") })
			let server = try #require(lines.first { $0.text == "SERVER" })
			#expect(explanation.bounds.minY > signIn.bounds.maxY)
			#expect(signIn.bounds.minY > server.bounds.maxY)
		}
		driver.availableUpdateVersion = "A newer nightly"
		driver.sessionInProgress = true
		try await Task.sleep(for: .milliseconds(20))
		#expect(checker.canCheckForUpdates)
		#expect(!picker.isEnabled)
		checker.channel = .stable
		#expect(checker.channel == .nightly)
		#expect(checker.availableUpdateVersion == "A newer nightly")
		#expect(defaults.string(forKey: UpdateChecker.channelDefaultsKey) == "nightly")
		checker.checkForUpdates()
		#expect(driver.checks == 1)
		driver.sessionInProgress = false
		driver.hasPendingUpdate = true
		try await Task.sleep(for: .milliseconds(20))
		#expect(!picker.isEnabled)
		#expect(checker.canCheckForUpdates)
		driver.hasPendingUpdate = false
		try await Task.sleep(for: .milliseconds(20))
		#expect(picker.isEnabled)
		checker.channel = .stable
		checker.checkForUpdates()
		#expect(driver.channels.last == .stable)
		#expect(driver.checks == 2)
		driver.canCheckForUpdates = false
		try await Task.sleep(for: .milliseconds(20))
		#expect(!picker.isEnabled)
	}
	@Test("starting the updater more than once starts only one scheduler")
	func startsOnce() {
		let driver = TestUpdateDriver()
		let checker = UpdateChecker(driver: driver)
		checker.start()
		checker.start()
		#expect(driver.starts == 1)
		#expect(checker.canCheckForUpdates)
	}

	@Test("a deferred download keeps its channel until the pending update is resolved")
	func deferredDownloadKeepsChannel() throws {
		let domain = "deferred-channel-\(UUID().uuidString)"
		let defaults = try #require(UserDefaults(suiteName: domain))
		defer { defaults.removePersistentDomain(forName: domain) }
		let driver = TestUpdateDriver()
		let checker = UpdateChecker(driver: driver, defaults: defaults,
			buildInfo: VaultBuildInfo(info: ["LPMReleaseChannel": "nightly"]))
		checker.start()
		driver.hasPendingUpdate = true
		#expect(!driver.sessionInProgress)
		#expect(checker.canCheckForUpdates)
		checker.channel = .stable
		#expect(checker.channel == .nightly)
		#expect(driver.channels == [.nightly])
		checker.checkForUpdates()
		#expect(driver.checks == 1)
		driver.hasPendingUpdate = false
		checker.channel = .stable
		#expect(checker.channel == .stable)
	}

	@Test("a prepared installer keeps its channel locked across app processes")
	func pendingInstallerSurvivesRelaunch() throws {
		let domain = "pending-installer-\(UUID().uuidString)"
		let defaults = try #require(UserDefaults(suiteName: domain))
		defer { defaults.removePersistentDomain(forName: domain) }
		let build = VaultBuildInfo(info: ["CFBundleVersion": "6"])
		let driver = SparkleUpdateDriver(defaults: defaults, buildInfo: build)
		let item = try appcastItem(build: "6.0.1")
		driver.standardUserDriverWillHandleShowingUpdate(true, forUpdate: item, state: try updateState(stage: .installing))
		#expect(driver.hasPendingUpdate)
		let restarted = SparkleUpdateDriver(defaults: defaults, buildInfo: build)
		#expect(restarted.hasPendingUpdate)
		for installedBuild in ["6.0.1", "6.0.2"] {
			driver.standardUserDriverWillHandleShowingUpdate(true, forUpdate: item, state: try updateState(stage: .installing))
			let installed = SparkleUpdateDriver(defaults: defaults, buildInfo: VaultBuildInfo(info: ["CFBundleVersion": installedBuild]))
			#expect(!installed.hasPendingUpdate)
			#expect(!SparkleUpdateDriver(defaults: defaults, buildInfo: build).hasPendingUpdate)
		}
	}

	@Test("native Sparkle callbacks retain deferred downloads and release skipped updates")
	func nativeDeferredDownloadLifecycle() throws {
		let domain = "native-deferred-\(UUID().uuidString)"
		let defaults = try #require(UserDefaults(suiteName: domain))
		defer { defaults.removePersistentDomain(forName: domain) }
		let driver = SparkleUpdateDriver(defaults: defaults)
		let native = inertUpdater()
		let item = try appcastItem(build: "6.0.1")
		let downloaded = try updateState(stage: .downloaded)
		#expect(driver.responds(to: NSSelectorFromString("updater:userDidMakeChoice:forUpdate:state:")))
		driver.updater(native, didDownloadUpdate: item)
		#expect(driver.hasPendingUpdate)
		driver.updater(native, userDidMake: .dismiss, forUpdate: item, state: downloaded)
		driver.standardUserDriverWillFinishUpdateSession()
		#expect(driver.hasPendingUpdate)
		#expect(driver.availableUpdateVersion == nil)
		driver.updater(native, didAbortWithError: NSError(domain: SUSparkleErrorDomain,
			code: Int(SUError.installationAuthorizeLaterError.rawValue)))
		#expect(driver.hasPendingUpdate)
		driver.updater(native, userDidMake: .skip, forUpdate: item, state: downloaded)
		#expect(!driver.hasPendingUpdate)
		driver.standardUserDriverWillHandleShowingUpdate(true, forUpdate: item, state: downloaded)
		#expect(driver.hasPendingUpdate)
		driver.updater(native, didAbortWithError: NSError(domain: SUSparkleErrorDomain, code: Int(SUError.installationCanceledError.rawValue)))
		#expect(!driver.hasPendingUpdate)
	}

	@Test("automatic install on quit remains pending until skipped or a terminal failure")
	func automaticInstallerLifecycle() throws {
		let domain = "automatic-installer-\(UUID().uuidString)"
		let defaults = try #require(UserDefaults(suiteName: domain))
		defer { defaults.removePersistentDomain(forName: domain) }
		let build = VaultBuildInfo(info: ["CFBundleVersion": "6"])
		let driver = SparkleUpdateDriver(defaults: defaults, buildInfo: build)
		let native = inertUpdater()
		let item = try appcastItem(build: "6.0.1")
		var installedImmediately = false
		#expect(!driver.updater(native, willInstallUpdateOnQuit: item, immediateInstallationBlock: { installedImmediately = true }))
		#expect(!installedImmediately)
		#expect(SparkleUpdateDriver(defaults: defaults, buildInfo: build).hasPendingUpdate)
		driver.standardUserDriverWillFinishUpdateSession()
		#expect(driver.hasPendingUpdate)
		driver.updater(native, userDidMake: .skip, forUpdate: item, state: try updateState(stage: .installing))
		#expect(!SparkleUpdateDriver(defaults: defaults, buildInfo: build).hasPendingUpdate)
		driver.updater(native, didExtractUpdate: item)
		#expect(SparkleUpdateDriver(defaults: defaults, buildInfo: build).hasPendingUpdate)
		driver.updater(native, didAbortWithError: NSError(domain: SUSparkleErrorDomain, code: Int(SUError.noUpdateError.rawValue)))
		#expect(!SparkleUpdateDriver(defaults: defaults, buildInfo: build).hasPendingUpdate)
	}

	@Test("a stale check cannot resolve an installer prepared by another app instance", arguments: ["abort", "fresh", "skip"])
	func staleCyclePreservesAnotherInstaller(callback: String) throws {
		let domain = "installer-owner-\(UUID().uuidString)"
		let defaults = try #require(UserDefaults(suiteName: domain))
		defer { defaults.removePersistentDomain(forName: domain) }
		let build = VaultBuildInfo(info: ["CFBundleVersion": "6"])
		let stale = SparkleUpdateDriver(defaults: defaults, buildInfo: build)
		let preparing = SparkleUpdateDriver(defaults: defaults, buildInfo: build)
		let native = inertUpdater()
		let item = try appcastItem(build: "6.0.1")
		preparing.standardUserDriverWillHandleShowingUpdate(true, forUpdate: item, state: try updateState(stage: .installing))
		#expect(stale.hasPendingUpdate)
		if callback == "abort" {
			stale.updater(native, didAbortWithError: NSError(domain: SUSparkleErrorDomain, code: Int(SUError.noUpdateError.rawValue)))
		} else {
			let fresh = try updateState(stage: .notDownloaded)
			stale.standardUserDriverWillHandleShowingUpdate(true, forUpdate: item, state: fresh)
			if callback == "skip" { stale.updater(native, userDidMake: .skip, forUpdate: item, state: fresh) }
		}
		#expect(preparing.hasPendingUpdate)
		#expect(SparkleUpdateDriver(defaults: defaults, buildInfo: build).hasPendingUpdate)
	}

	@Test("resolving an older generation cannot clear or reopen the same target's new preparation")
	func preparationGenerationsRemainIndependent() throws {
		let domain = "installer-generation-\(UUID().uuidString)"
		let defaults = try #require(UserDefaults(suiteName: domain))
		defer { defaults.removePersistentDomain(forName: domain) }
		let build = VaultBuildInfo(info: ["CFBundleVersion": "6"])
		let preparing = SparkleUpdateDriver(defaults: defaults, buildInfo: build)
		let native = inertUpdater()
		let item = try appcastItem(build: "6.0.1")
		preparing.updater(native, didExtractUpdate: item)
		let stale = SparkleUpdateDriver(defaults: defaults, buildInfo: build)
		preparing.updater(native, didExtractUpdate: item)
		let noUpdate = NSError(domain: SUSparkleErrorDomain, code: Int(SUError.noUpdateError.rawValue))
		stale.updater(native, didAbortWithError: noUpdate)
		#expect(SparkleUpdateDriver(defaults: defaults, buildInfo: build).hasPendingUpdate)
		preparing.updater(native, userDidMake: .skip, forUpdate: item, state: try updateState(stage: .installing))
		#expect(!preparing.hasPendingUpdate)
		stale.updater(native, didAbortWithError: noUpdate)
		#expect(!SparkleUpdateDriver(defaults: defaults, buildInfo: build).hasPendingUpdate)
	}

	private func inertUpdater() -> SPUUpdater {
		SPUUpdater(hostBundle: Bundle.main, applicationBundle: Bundle.main,
			userDriver: SPUStandardUserDriver(hostBundle: Bundle.main, delegate: nil), delegate: nil)
	}

	private func appcastItem(build: String) throws -> SUAppcastItem {
		let archiver = NSKeyedArchiver(requiringSecureCoding: true)
		archiver.encode(build, forKey: "versionString")
		archiver.encode(build, forKey: "displayVersionString")
		archiver.encode(URL(string: "https://vault.lpm.dev/releases/test.dmg"), forKey: "fileURL")
		archiver.encode("application", forKey: "SUAppcastItemInstallationType")
		archiver.encode([String: String](), forKey: "propertiesDictionary")
		archiver.finishEncoding()
		let decoder = try NSKeyedUnarchiver(forReadingFrom: archiver.encodedData)
		decoder.requiresSecureCoding = true
		decoder.decodingFailurePolicy = .setErrorAndReturn
		return try #require(SUAppcastItem(coder: decoder))
	}

	private func updateState(stage: SPUUserUpdateStage) throws -> SPUUserUpdateState {
		let archiver = NSKeyedArchiver(requiringSecureCoding: true)
		archiver.encode(stage.rawValue, forKey: "SPUUserUpdateStateStage")
		archiver.encode(true, forKey: "SPUUserUpdateStateUserInitiated")
		archiver.finishEncoding()
		let decoder = try NSKeyedUnarchiver(forReadingFrom: archiver.encodedData)
		return try #require(SPUUserUpdateState(coder: decoder))
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

	@Test("starting automatic checks does not announce an update")
	func noReminderUntilUpdateIsOffered() {
		let driver = TestUpdateDriver()
		let checker = UpdateChecker(driver: driver)
		#expect(checker.availableUpdateVersion == nil)
		checker.start()
		#expect(checker.canCheckForUpdates)
		#expect(checker.availableUpdateVersion == nil)
	}

	@Test("the reminder follows the offered update until its session ends")
	func reminderTracksUpdateSession() {
		let driver = TestUpdateDriver()
		let checker = UpdateChecker(driver: driver)
		checker.start()
		driver.availableUpdateVersion = "1.1.0"
		#expect(checker.availableUpdateVersion == "1.1.0")

		checker.checkForUpdates()
		#expect(driver.checks == 1)
		#expect(checker.availableUpdateVersion == "1.1.0")

		driver.canCheckForUpdates = false
		checker.checkForUpdates()
		#expect(driver.checks == 1)
		#expect(checker.availableUpdateVersion == "1.1.0")

		driver.availableUpdateVersion = nil
		#expect(checker.availableUpdateVersion == nil)
		driver.availableUpdateVersion = "1.2.0"
		#expect(checker.availableUpdateVersion == "1.2.0")
	}

	@Test("startup preserves an update that the driver already offers")
	func existingUpdateIsVisibleAfterStartup() {
		let driver = TestUpdateDriver()
		driver.availableUpdateVersion = "1.1.0"
		let checker = UpdateChecker(driver: driver)
		checker.start()
		#expect(checker.availableUpdateVersion == "1.1.0")
	}

	@Test("the title bar shows an update reminder beside Lock only while an update is offered", arguments: [1040.0, 1200.0])
	func titleBarUpdateReminder(width: Double) async throws {
		let driver = TestUpdateDriver()
		let checker = UpdateChecker(driver: driver)
		checker.start()
		let store = VaultStore(
			keychainService: MockKeychainService(), biometricService: MockBiometricService(),
			apiService: MockAPIService(), authTokenProvider: { _, _ in nil }
		)
		let project = VaultProject(
			id: "update-reminder-test", name: "project-with-a-long-name-to-exercise-title-bar-layout",
			path: "/tmp/update-reminder", environments: ["default": [:]]
		)
		store.projects = [project]
		store.selectedProjectId = project.id
		let view = NSHostingView(rootView: VaultTitleBarView(
			store: store, mode: .matrix, onConnectCLI: {}, onPull: {}, onPush: {}
		).environment(checker).environment(\.colorScheme, .light))
		let window = NSWindow(
			contentRect: NSRect(x: 0, y: 0, width: width, height: VaultMetrics.titleBar),
			styleMask: [.borderless], backing: .buffered, defer: false
		)
		window.isReleasedWhenClosed = false
		window.contentView = view
		window.orderBack(nil)
		defer { window.close() }

		let states: [(String?, Bool)] = [(nil, true), ("1.1.0", true), ("1.1.0", false), (nil, true)]
		for (version, canCheck) in states {
			driver.availableUpdateVersion = version
			driver.canCheckForUpdates = canCheck
			let deadline = ContinuousClock.now.advanced(by: .seconds(2))
			var bitmap: NSBitmapImageRep
			var updateBounds: CGRect?
			repeat {
				try await Task.sleep(for: .milliseconds(10))
				bitmap = try renderTitleBar(view)
				updateBounds = try await bounds(of: "Update available", in: bitmap)
				if (updateBounds != nil) == (version != nil) { break }
			} while ContinuousClock.now < deadline
			let data = try #require(bitmap.representation(using: .png, properties: [:]))
			Attachment.record(data, named: "update-reminder-\(Int(width))-\(version ?? "none")-\(canCheck).png")
			#expect((updateBounds != nil) == (version != nil))
			let lockBounds = try #require(try await bounds(of: "Lock", in: bitmap))
			if version != nil {
				let updateBounds = try #require(updateBounds)
				#expect(updateBounds.maxX < lockBounds.minX)
				let location = view.convert(NSPoint(
					x: updateBounds.midX * view.bounds.width,
					y: (view.isFlipped ? 1 - updateBounds.midY : updateBounds.midY) * view.bounds.height
				), to: nil)
				let previousChecks = driver.checks
				try NativeTestClick.send(to: window, at: location)
				#expect(driver.checks == previousChecks + (canCheck ? 1 : 0))
			}
		}
	}

	private func renderTitleBar(_ view: NSView) throws -> NSBitmapImageRep {
		view.layoutSubtreeIfNeeded()
		let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
		view.cacheDisplay(in: view.bounds, to: bitmap)
		return bitmap
	}

	/// Recognition runs off the main thread: Vision can wait on work that needs it.
	private func bounds(of text: String, in bitmap: NSBitmapImageRep) async throws -> CGRect? {
		let image = try #require(bitmap.cgImage)
		return try await RenderedText.lines(in: image, level: .accurate, label: text).lazy.compactMap(\.labelBounds).first
	}

	@Test("development builds cannot replace themselves with public releases")
	func developmentUpdatesAreDisabled() {
		#if DEBUG
		let checker = UpdateChecker()
		checker.start()
		#expect(!checker.canCheckForUpdates)
		#expect(checker.availableUpdateVersion == nil)
		#endif
	}
}

@MainActor
private final class TestUpdateDriver: VaultUpdateDriver {
	var hasPendingUpdate = false {
		didSet { stateChanged?() }
	}
	var sessionInProgress = false {
		didSet { stateChanged?() }
	}
	var canCheckForUpdates = false {
		didSet { stateChanged?() }
	}
	var availableUpdateVersion: String? {
		didSet { updateChanged?(availableUpdateVersion) }
	}
	var stateChanged: (() -> Void)?
	var updateChanged: ((String?) -> Void)?
	var starts = 0
	var checks = 0
	var channels: [VaultReleaseChannel] = []
	func setChannel(_ channel: VaultReleaseChannel) { channels.append(channel) }
	func start() {
		starts += 1
		canCheckForUpdates = true
	}
	func checkForUpdates() { checks += 1 }
}
