import Foundation
import LocalAuthentication

// MARK: - Protocol

enum BiometricType {
	case faceID
	case touchID
	case none
}

enum AuthenticationOutcome: Equatable, Sendable {
	case authenticated
	/// The person dismissed the prompt, chose another method, or the system withdrew it.
	case cancelled
	case failed
}

protocol BiometricServiceProtocol: Sendable {
	var keychainAuthenticationContext: LAContext? { get }
	func authenticate(reason: String) async -> AuthenticationOutcome
	func isBiometricAvailable() -> Bool
	func biometricType() -> BiometricType
	func resetCache()
}

extension BiometricServiceProtocol {
	var keychainAuthenticationContext: LAContext? { nil }
}

// MARK: - Implementation

final class BiometricService: BiometricServiceProtocol, @unchecked Sendable {
	private let lock = NSLock()
	private var lastAuthTime: TimeInterval?
	private var cacheEpoch: UInt64 = 0
	private let cacheDuration: TimeInterval
	private let now: @Sendable () -> TimeInterval
	private let authentication: (@Sendable (String) async -> AuthenticationOutcome)?
	private var authenticatedContext: LAContext?

	var keychainAuthenticationContext: LAContext? {
		lock.withLock { authenticatedContext }
	}

	init(
		cacheDuration: TimeInterval = VaultConstants.biometricCacheDuration,
		now: @escaping @Sendable () -> TimeInterval = {
			ProcessInfo.processInfo.systemUptime
		},
		authentication: (@Sendable (String) async -> AuthenticationOutcome)? = nil
	) {
		self.cacheDuration = cacheDuration
		self.now = now
		self.authentication = authentication
	}

	func authenticate(reason: String) async -> AuthenticationOutcome {
		let (cachedAuthTime, authenticationEpoch) = lock.withLock {
			(lastAuthTime, cacheEpoch)
		}
		let elapsed = cachedAuthTime.map { now() - $0 }
		if let elapsed, elapsed >= 0, elapsed < cacheDuration {
			return .authenticated
		}

		let context: LAContext?
		let outcome: AuthenticationOutcome
		if let authentication {
			context = nil
			outcome = await authentication(reason)
		} else {
			let nativeContext = LAContext()
			nativeContext.localizedFallbackTitle = "Use Password"
			context = nativeContext
			do {
				outcome = try await nativeContext.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
					? .authenticated : .failed
			} catch {
				outcome = Self.outcome(for: error)
			}
		}
		if outcome == .authenticated {
			let authenticatedAt = now()
			lock.withLock {
				guard cacheEpoch == authenticationEpoch else { return }
				lastAuthTime = authenticatedAt
				authenticatedContext = context
			}
		}
		return outcome
	}

	static func outcome(for error: Error) -> AuthenticationOutcome {
		if let error = error as? LAError {
			switch error.code {
			case .userCancel, .appCancel, .systemCancel, .userFallback: return .cancelled
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
			let context = authenticatedContext
			authenticatedContext = nil
			return context
		}
		context?.invalidate()
	}
}
