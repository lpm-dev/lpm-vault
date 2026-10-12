import Darwin

/// Limits the app raises for itself at launch.
enum ProcessLimits {
	/// Open files the app asks for. The Schema page watches lpm.json's imports
	/// by descriptor while the engine reads them, and an app opened from the
	/// Finder starts with 256.
	static let openFiles: rlim_t = 4096

	/// Raises the soft limit on open files to `wanted`, or to the hard limit
	/// when that's lower, keeping a higher one. Returns the soft limit in effect.
	@discardableResult
	static func raiseOpenFiles(to wanted: rlim_t = openFiles) -> rlim_t {
		var limit = rlimit()
		guard getrlimit(RLIMIT_NOFILE, &limit) == 0 else { return 0 }
		let target = min(wanted, limit.rlim_max)
		guard limit.rlim_cur < target else { return limit.rlim_cur }
		let current = limit.rlim_cur
		limit.rlim_cur = target
		return setrlimit(RLIMIT_NOFILE, &limit) == 0 ? target : current
	}
}
