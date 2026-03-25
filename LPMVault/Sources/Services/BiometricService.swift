import Foundation
import LocalAuthentication

// MARK: - Protocol

enum BiometricType {
	case faceID
	case touchID
	case none
}

protocol BiometricServiceProtocol {
	func authenticate(reason: String) async -> Bool
	func isBiometricAvailable() -> Bool
	func biometricType() -> BiometricType
}

// MARK: - Implementation

final class BiometricService: BiometricServiceProtocol {
	private var lastAuthTime: Date?
	private let cacheDuration: TimeInterval

	init(cacheDuration: TimeInterval = VaultConstants.biometricCacheDuration) {
		self.cacheDuration = cacheDuration
	}

	func authenticate(reason: String) async -> Bool {
		// Check cache — avoid repeated prompts during edit sessions
		if let lastAuth = lastAuthTime,
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
				lastAuthTime = Date()
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
		lastAuthTime = nil
	}
}
