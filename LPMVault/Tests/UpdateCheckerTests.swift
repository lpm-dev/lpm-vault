import AppKit
import SwiftUI
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
	var canCheckForUpdates = false {
		didSet { availabilityChanged?(canCheckForUpdates) }
	}
	var availableUpdateVersion: String? {
		didSet { updateChanged?(availableUpdateVersion) }
	}
	var availabilityChanged: ((Bool) -> Void)?
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
