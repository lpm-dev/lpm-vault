import AppKit

/// Quits the app and opens it again once it has quit, for a change that only
/// a fresh launch takes up, such as another LPM home.
enum AppRelaunch {
	@MainActor
	static func relaunch() {
		let waiter = Process()
		waiter.executableURL = URL(fileURLWithPath: "/bin/sh")
		// Waits for this process to end, so the new one never runs beside it.
		waiter.arguments = [
			"-c", "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.2; done; exec /usr/bin/open \"$2\"",
			"lpm-vault-relaunch", String(ProcessInfo.processInfo.processIdentifier), Bundle.main.bundleURL.path,
		]
		try? waiter.run()
		AppDelegate.requestTermination()
	}
}
