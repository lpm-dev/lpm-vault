import LPMEnv

/// The engine ABI this app's requests and answers follow, which is
/// `LPM_ENV_ABI_VERSION` of the bundled engine's `lpm_env.h`.
enum EnvEngineABI {
	static let version: UInt32 = 2

	/// Whether the linked engine speaks this ABI.
	static var matches: Bool { lpm_env_abi_version() == version }

	/// The `abiVersion` each JSON answer of this ABI carries.
	static let answerVersion = LPMConfigJSON.number(String(version))
}
