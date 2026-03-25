import Foundation

enum VaultConstants {
	/// Keychain service name — shared with LPM CLI (Rust)
	static let keychainService = "dev.lpm.vault"

	/// Keychain service for CLI auth tokens
	static let cliAuthService = "lpm-cli"

	/// Maximum recommended vault size in bytes (90KB warning threshold)
	static let maxVaultSizeWarning = 90 * 1024

	/// Clipboard auto-clear delay in seconds
	static let clipboardClearDelay: TimeInterval = 30

	/// Biometric auth cache duration in seconds (5 minutes)
	static let biometricCacheDuration: TimeInterval = 5 * 60

	/// LPM API base URL
	static let apiBaseURL = URL(string: "https://lpm.dev")!

	/// LPM dev API base URL
	static let apiDevBaseURL = URL(string: "http://localhost:3000")!
}
