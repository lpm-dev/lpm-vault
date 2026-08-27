import Foundation

enum VaultConstants {
	/// Keychain service name — shared with LPM CLI (Rust)
	static let keychainService = "dev.lpm.vault"

	/// Team-ID-scoped Data Protection Keychain group shared with the signed CLI.
	static let keychainAccessGroup = "823S8YKMRW.dev.lpm.vault.shared"

	/// Keychain service for CLI auth tokens
	static let cliAuthService = "lpm-cli"

	/// Maximum recommended vault size in bytes (90KB warning threshold)
	static let maxVaultSizeWarning = 90 * 1024

	/// Clipboard auto-clear delay in seconds
	static let clipboardClearDelay: TimeInterval = 10

	/// Biometric auth cache duration in seconds (2 minutes)
	static let biometricCacheDuration: TimeInterval = 2 * 60

	/// Idle time before an unlocked vault locks itself (2 minutes)
	static let vaultAutoLockDuration: TimeInterval = 2 * 60

	/// LPM API base URL
	static let apiBaseURL = URL(string: "https://lpm.dev")!

	#if DEBUG
	/// Local API base URL used only by debug builds.
	static let localAPIBaseURL = URL(string: "http://localhost:3000")!
	#endif
}
