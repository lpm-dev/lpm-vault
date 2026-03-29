import Foundation

enum VaultConstants {
	/// Keychain service name — shared with LPM CLI (Rust)
	static let keychainService = "dev.lpm.vault"

	/// Keychain service for CLI auth tokens
	static let cliAuthService = "lpm-cli"

	/// Maximum recommended vault size in bytes (90KB warning threshold)
	static let maxVaultSizeWarning = 90 * 1024

	/// Clipboard auto-clear delay in seconds
	static let clipboardClearDelay: TimeInterval = 10

	/// Biometric auth cache duration in seconds (2 minutes)
	static let biometricCacheDuration: TimeInterval = 2 * 60

	/// LPM API base URL
	static let apiBaseURL = URL(string: "https://lpm.dev")!

	/// LPM dev API base URL
	static var apiDevBaseURL: URL {
		#if DEBUG
		return URL(string: "http://localhost:3000")!
		#else
		// Release builds must use HTTPS — prevent accidental HTTP in production
		return URL(string: "https://dev.lpm.dev")!
		#endif
	}
}
