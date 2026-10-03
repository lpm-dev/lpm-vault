import Foundation
import LocalAuthentication

// MARK: - Protocol

enum BiometricType {
	case faceID
	case touchID
	case none
}

enum AuthenticationFailure: Equatable, Sendable {
	case failed
}

protocol BiometricServiceProtocol: Sendable {
	var keychainAuthenticationContext: LAContext? { get }
	var lastAuthenticationFailure: AuthenticationFailure? { get }
	func authenticate(reason: String) async -> Bool
	func isBiometricAvailable() -> Bool
	func biometricType() -> BiometricType
	func resetCache()
}

extension BiometricServiceProtocol {
	var keychainAuthenticationContext: LAContext? { nil }
	var lastAuthenticationFailure: AuthenticationFailure? { nil }
}

// MARK: - Implementation

final class BiometricService: BiometricServiceProtocol, @unchecked Sendable {
	private let lock = NSLock()
	private var lastAuthTime: TimeInterval?
	private var cacheEpoch: UInt64 = 0
	private let cacheDuration: TimeInterval
	private let now: @Sendable () -> TimeInterval
	private let authentication: (@Sendable (String) async -> Bool)?
	private var authenticatedContext: LAContext?
	private var authenticationFailure: AuthenticationFailure?
	var lastAuthenticationFailure: AuthenticationFailure? { lock.withLock { authenticationFailure } }

	var keychainAuthenticationContext: LAContext? {
		lock.withLock { authenticatedContext }
	}

	init(
		cacheDuration: TimeInterval = VaultConstants.biometricCacheDuration,
		now: @escaping @Sendable () -> TimeInterval = {
			ProcessInfo.processInfo.systemUptime
		},
		authentication: (@Sendable (String) async -> Bool)? = nil
	) {
		self.cacheDuration = cacheDuration
		self.now = now
		self.authentication = authentication
	}

	func authenticate(reason: String) async -> Bool {
		let (cachedAuthTime, authenticationEpoch) = lock.withLock {
			authenticationFailure = nil
			return (lastAuthTime, cacheEpoch)
		}
		let elapsed = cachedAuthTime.map { now() - $0 }
		if let elapsed, elapsed >= 0, elapsed < cacheDuration {
			return true
		}

		let context: LAContext?
		let success: Bool
		if let authentication {
			context = nil
			success = await authentication(reason)
		} else {
			let nativeContext = LAContext()
			nativeContext.localizedFallbackTitle = "Use Password"
			context = nativeContext
			do {
				success = try await nativeContext.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
			} catch {
				success = false
				let failure = Self.failure(for: error)
				lock.withLock {
					if cacheEpoch == authenticationEpoch { authenticationFailure = failure }
				}
			}
		}
		if success {
			let authenticatedAt = now()
			lock.withLock {
				guard cacheEpoch == authenticationEpoch else { return }
				lastAuthTime = authenticatedAt
				authenticatedContext = context
			}
		}
		return success
	}

	static func failure(for error: Error) -> AuthenticationFailure? {
		if let error = error as? LAError {
			switch error.code {
			case .userCancel, .appCancel, .systemCancel, .userFallback: return nil
			default: break
			}
		}
		return .failed
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
		let context = lock.withLock {
			cacheEpoch &+= 1
			lastAuthTime = nil
			authenticationFailure = nil
			let context = authenticatedContext
			authenticatedContext = nil
			return context
		}
		context?.invalidate()
	}
}
