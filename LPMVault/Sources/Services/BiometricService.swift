import Foundation
import LocalAuthentication

// MARK: - Protocol

enum BiometricType {
	case faceID
	case touchID
	case none
}

protocol BiometricServiceProtocol: Sendable {
	func authenticate(reason: String) async -> Bool
	func isBiometricAvailable() -> Bool
	func biometricType() -> BiometricType
	func resetCache()
}

// MARK: - Implementation

final class BiometricService: BiometricServiceProtocol, @unchecked Sendable {
	private let lock = NSLock()
	private var lastAuthTime: TimeInterval?
	private let cacheDuration: TimeInterval
	private let now: @Sendable () -> TimeInterval
	private let authentication: @Sendable (String) async -> Bool

	init(
		cacheDuration: TimeInterval = VaultConstants.biometricCacheDuration,
		now: @escaping @Sendable () -> TimeInterval = {
			ProcessInfo.processInfo.systemUptime
		},
		authentication: @escaping @Sendable (String) async -> Bool = { reason in
			let context = LAContext()
			context.localizedFallbackTitle = "Use Password"
			do {
				return try await context.evaluatePolicy(
					.deviceOwnerAuthentication,
					localizedReason: reason
				)
			} catch {
				return false
			}
		}
	) {
		self.cacheDuration = cacheDuration
		self.now = now
		self.authentication = authentication
	}

	func authenticate(reason: String) async -> Bool {
		// Check cache — avoid repeated prompts during edit sessions
		let cachedAuthTime = lock.withLock { lastAuthTime }
		let elapsed = cachedAuthTime.map { now() - $0 }
		if let elapsed, elapsed >= 0, elapsed < cacheDuration {
			return true
		}

		let success = await authentication(reason)
		if success {
			let authenticatedAt = now()
			lock.withLock { lastAuthTime = authenticatedAt }
		}
		return success
	}

	func isBiometricAvailable() -> Bool {
		let context = LAContext()
		var error: NSError?
		return context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
	}

	func biometricType() -> BiometricType {
		let context = LAContext()
		var error: NSError?
		guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
		else {
			return .none
		}

		switch context.biometryType {
		case .faceID:
			return .faceID
		case .touchID:
			return .touchID
		default:
			return .none
		}
	}

	/// Reset the auth cache (e.g., when user locks manually)
	func resetCache() {
		lock.withLock { lastAuthTime = nil }
	}
}
