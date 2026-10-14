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
	/// Asks every time, even right after an approval `authenticate` would reuse.
	func confirm(reason: String) async -> AuthenticationOutcome
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
	private let makeContext: @Sendable () -> LAContext
	private var authenticatedContext: LAContext?
	/// Contexts whose prompt is showing, which resetting the cache takes down.
	private var evaluatingContexts: [ObjectIdentifier: LAContext] = [:]

	var keychainAuthenticationContext: LAContext? {
		lock.withLock { authenticatedContext }
	}

	init(
		cacheDuration: TimeInterval = VaultConstants.biometricCacheDuration,
		now: @escaping @Sendable () -> TimeInterval = {
			ProcessInfo.processInfo.systemUptime
		},
		authentication: (@Sendable (String) async -> AuthenticationOutcome)? = nil,
		makeContext: @escaping @Sendable () -> LAContext = { LAContext() }
	) {
		self.cacheDuration = cacheDuration
		self.now = now
		self.authentication = authentication
		self.makeContext = makeContext
	}

	func authenticate(reason: String) async -> AuthenticationOutcome {
		await authenticate(reason: reason, reusingRecent: true)
	}

	func confirm(reason: String) async -> AuthenticationOutcome {
		await authenticate(reason: reason, reusingRecent: false)
	}

	private func authenticate(reason: String, reusingRecent: Bool) async -> AuthenticationOutcome {
		let (cachedAuthTime, authenticationEpoch) = lock.withLock {
			(lastAuthTime, cacheEpoch)
		}
		let elapsed = cachedAuthTime.map { now() - $0 }
		if reusingRecent, let elapsed, elapsed >= 0, elapsed < cacheDuration {
			return .authenticated
		}

		let context: LAContext?
		let outcome: AuthenticationOutcome
		if let authentication {
			context = nil
			outcome = await authentication(reason)
		} else {
			let nativeContext = makeContext()
			nativeContext.localizedFallbackTitle = "Use Password"
			context = nativeContext
			let identifier = ObjectIdentifier(nativeContext)
			// A prompt asked for before the cache was reset, as when the vault locked, never shows.
			let isCurrent = lock.withLock {
				guard cacheEpoch == authenticationEpoch else { return false }
				evaluatingContexts[identifier] = nativeContext
				return true
			}
			guard isCurrent else { return .cancelled }
			do {
				outcome = try await nativeContext.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
					? .authenticated : .failed
			} catch {
				outcome = Self.outcome(for: error)
			}
			lock.withLock { _ = evaluatingContexts.removeValue(forKey: identifier) }
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

	/// Forgets the last approval and takes down any prompt still showing,
	/// which then reads as cancelled, as when the vault locks.
	func resetCache() {
		let contexts = lock.withLock {
			cacheEpoch &+= 1
			lastAuthTime = nil
			let contexts = Array(evaluatingContexts.values) + [authenticatedContext].compactMap { $0 }
			authenticatedContext = nil
			evaluatingContexts = [:]
			return contexts
		}
		for context in contexts { context.invalidate() }
	}
}
