import AppKit
import Testing

@testable import LPMVault

@Suite("App lifecycle security")
@MainActor
struct AppDelegateTests {
	@Test("activity mask includes active input and excludes passive movement")
	func activityEventClassification() {
		let mask = AppDelegate.userActivityEvents

		for event in [
			NSEvent.EventType.keyDown,
			.leftMouseDown,
			.rightMouseDown,
			.otherMouseDown,
			.scrollWheel,
			.gesture,
			.magnify,
			.rotate,
			.swipe,
		] {
			#expect(mask.contains(NSEvent.EventTypeMask(rawValue: 1 << event.rawValue)))
		}
		#expect(!mask.contains(.mouseMoved))
		#expect(!mask.contains(.keyUp))
	}

	@Test("security state changes lock synchronously")
	func securityStateChangeLocksSynchronously() {
		let delegate = AppDelegate()
		var lockCount = 0
		delegate.lockVault = { lockCount += 1 }

		delegate.handleSecurityStateChange()

		#expect(lockCount == 1)
	}

	@Test("security state changes before wiring are applied when the lock handler arrives")
	func earlySecurityStateChangeIsNotLost() {
		let delegate = AppDelegate()
		var lockCount = 0

		delegate.handleSecurityStateChange()
		#expect(lockCount == 0)

		delegate.lockVault = { lockCount += 1 }
		#expect(lockCount == 1)
	}
}
