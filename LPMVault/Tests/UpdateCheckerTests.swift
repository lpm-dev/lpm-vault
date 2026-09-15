import AppKit
import SwiftUI
import Testing
import Vision

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
			store: store, mode: .matrix, onShowVaultID: {}, onPull: {}, onPush: {}
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
			var rendered: (bitmap: NSBitmapImageRep, text: [VNRecognizedTextObservation])
			var updateBounds: CGRect?
			repeat {
				try await Task.sleep(for: .milliseconds(10))
				rendered = try renderTitleBar(view)
				updateBounds = try bounds(of: "Update available", in: rendered.text)
				if (updateBounds != nil) == (version != nil) { break }
			} while ContinuousClock.now < deadline
			let data = try #require(rendered.bitmap.representation(using: .png, properties: [:]))
			Attachment.record(data, named: "update-reminder-\(Int(width))-\(version ?? "none")-\(canCheck).png")
			#expect((updateBounds != nil) == (version != nil))
			let lockBounds = try #require(try bounds(of: "Lock", in: rendered.text))
			if version != nil {
				let updateBounds = try #require(updateBounds)
				#expect(updateBounds.maxX < lockBounds.minX)
				let location = view.convert(NSPoint(
					x: updateBounds.midX * view.bounds.width,
					y: (view.isFlipped ? 1 - updateBounds.midY : updateBounds.midY) * view.bounds.height
				), to: nil)
				let previousChecks = driver.checks
				for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
					let event = try #require(NSEvent.mouseEvent(
						with: type, location: location, modifierFlags: [],
						timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
						context: nil, eventNumber: 0, clickCount: 1, pressure: 1
					))
					window.sendEvent(event)
				}
				#expect(driver.checks == previousChecks + (canCheck ? 1 : 0))
			}
		}
	}

	private func renderTitleBar(_ view: NSView) throws -> (bitmap: NSBitmapImageRep, text: [VNRecognizedTextObservation]) {
		view.layoutSubtreeIfNeeded()
		let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
		view.cacheDisplay(in: view.bounds, to: bitmap)
		let image = try #require(bitmap.cgImage)
		let request = VNRecognizeTextRequest()
		request.recognitionLevel = .accurate
		try VNImageRequestHandler(cgImage: image).perform([request])
		return (bitmap, request.results ?? [])
	}

	private func bounds(of text: String, in observations: [VNRecognizedTextObservation]) throws -> CGRect? {
		for observation in observations {
			guard let candidate = observation.topCandidates(1).first,
				let range = candidate.string.range(of: text) else { continue }
			return try candidate.boundingBox(for: range)?.boundingBox
		}
		return nil
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
	func start() {
		starts += 1
		canCheckForUpdates = true
	}
	func checkForUpdates() { checks += 1 }
}
