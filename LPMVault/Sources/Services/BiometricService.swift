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
	private var lastAuthTime: Date?
	private let cacheDuration: TimeInterval

	init(cacheDuration: TimeInterval = VaultConstants.biometricCacheDuration) {
		self.cacheDuration = cacheDuration
	}

	func authenticate(reason: String) async -> Bool {
		// Check cache — avoid repeated prompts during edit sessions
		let cachedAuthTime = lock.withLock { lastAuthTime }
		if let lastAuth = cachedAuthTime,
			Date().timeIntervalSince(lastAuth) < cacheDuration
		{
			return true
		}

		let context = LAContext()
		context.localizedFallbackTitle = "Use Password"

		do {
			let success = try await context.evaluatePolicy(
				.deviceOwnerAuthentication,  // Biometric + password fallback
				localizedReason: reason
			)
			if success {
				lock.withLock { lastAuthTime = Date() }
			}
			return success
		} catch {
			return false
		}
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
