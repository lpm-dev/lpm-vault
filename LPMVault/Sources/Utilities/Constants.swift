import Foundation

enum VaultConstants {
	/// Keychain service name — shared with LPM CLI (Rust)
	static let keychainService = "dev.lpm.vault"

	/// Team-ID-scoped Data Protection Keychain group shared with the signed CLI.
	static let keychainAccessGroup = "823S8YKMRW.dev.lpm.vault.shared"

	/// Keychain service for CLI auth tokens
	static let cliAuthService = "lpm-cli"

	/// The app's own Keychain group, named by its application identifier. The
	/// signed CLI has a different identifier, so it can't read these items.
	static let appKeychainAccessGroup = "823S8YKMRW.dev.lpm.vault"

	/// Keychain service for publish destinations, publish history and the
	/// fingerprint key, kept in `appKeychainAccessGroup`.
	static let publishingKeychainService = "dev.lpm.vault.publishing"

	/// Keychain service for platform connections and their access tokens,
	/// kept in `appKeychainAccessGroup`.
	static let platformConnectionsKeychainService = "dev.lpm.vault.platforms"

	/// LPM Vault's Netlify OAuth app. A client ID is public: the ticket flow
	/// needs no client secret, so none ships in the app or on a server.
	static let netlifyOAuthClientID = "NETLIFY_CLIENT_ID_PENDING"

	/// Maximum recommended vault size in bytes (90KB warning threshold)
	static let maxVaultSizeWarning = 90 * 1024

	/// Clipboard auto-clear delay in seconds
	static let clipboardClearDelay: TimeInterval = 10

	/// Biometric auth cache duration in seconds (2 minutes)
	static let biometricCacheDuration: TimeInterval = 2 * 60

	/// Idle time before an unlocked vault locks itself (2 minutes)
	static let vaultAutoLockDuration: TimeInterval = 2 * 60
	static let vaultAutoLockCountdownDuration: TimeInterval = 30

	/// LPM API base URL
	static let apiBaseURL = URL(string: "https://lpm.dev")!

	#if DEBUG
	/// Local API base URL used only by debug builds.
	static let localAPIBaseURL = URL(string: "http://localhost:3000")!
	#endif
}
