import Foundation

/// The LPM CLI as the person's shell finds it: where it is and its version.
enum LPMCLIStatus: Equatable, Sendable {
	case found(path: String, version: String?)
	/// The shell answered, and has no `lpm`.
	case notFound
	/// The shell didn't answer in time, or couldn't run.
	case unavailable
}

/// Finds the LPM CLI the way Terminal does, by asking the person's login
/// shell, since an app opened from the Finder doesn't get the PATH their
/// shell's startup files set, where installers such as npm, Homebrew and
/// LPM's own put it.
struct LPMCLILocator: Sendable {
	/// The shell to ask, from the person's account; zsh when it says none.
	var shell: String
	/// The command to look for.
	var program = "lpm"
	/// The longest the shell may take before the answer is unavailable.
	var timeout: Duration = .seconds(10)
	var environment: [String: String]

	init(
		shell: String? = ProcessInfo.processInfo.environment["SHELL"],
		program: String = "lpm",
		timeout: Duration = .seconds(10),
		environment: [String: String] = ProcessInfo.processInfo.environment
	) {
		self.shell = shell.flatMap { $0.hasPrefix("/") ? $0 : nil } ?? "/bin/zsh"
		self.program = program
		self.timeout = timeout
		self.environment = environment
	}

	static let pathMarker = "__LPM_VAULT_CLI_PATH__"
	static let versionMarker = "__LPM_VAULT_CLI_VERSION__"

	/// The script the shell runs, in syntax zsh, bash and fish all take.
	/// Markers find the answer among whatever the startup files print.
	var script: String {
		"printf '\\n%s\\n' \"\(Self.pathMarker)$(command -v \(program))\"; "
			+ "printf '%s\\n' \"\(Self.versionMarker)$(\(program) --version 2>/dev/null | head -n 1)\""
	}

	func locate() async -> LPMCLIStatus {
		guard let output = await run() else { return .unavailable }
		return Self.status(from: output) ?? .unavailable
	}

	/// What the shell said, or nil when it said nothing the script prints.
	static func status(from output: String) -> LPMCLIStatus? {
		var path: String?
		var versionLine: String?
		for line in output.split(whereSeparator: \.isNewline) {
			if let range = line.range(of: pathMarker) {
				path = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
			} else if let range = line.range(of: versionMarker) {
				versionLine = String(line[range.upperBound...])
			}
		}
		guard let path else { return nil }
		// An alias or a function prints its definition, not a path.
		guard path.hasPrefix("/") else { return .notFound }
		return .found(path: path, version: versionLine.flatMap(version(in:)))
	}

	/// The version in `lpm --version`'s first line, such as "lpm 0.84.0".
	static func version(in line: String) -> String? {
		line.split(whereSeparator: \.isWhitespace).lazy.map(String.init).first { word in
			let parts = word.split(separator: ".", maxSplits: 2)
			return parts.count == 3 && parts[0].allSatisfy(\.isNumber) && !parts[0].isEmpty
				&& parts[1].allSatisfy(\.isNumber) && !parts[1].isEmpty && parts[2].first?.isNumber == true
		}
	}

	/// Runs the script in an interactive login shell, so every startup file
	/// that sets PATH is read, with nothing to read from and its errors
	/// dropped. The answer is complete once its last line arrives, even while
	/// something the startup files started keeps the output open. Then, once
	/// the timeout passes, or once the task is cancelled, the shell and all
	/// it started are stopped.
	private func run() async -> String? {
		var ends: [Int32] = [-1, -1]
		guard pipe(&ends) == 0 else { return nil }
		let output = FileHandle(fileDescriptor: ends[0], closeOnDealloc: true)
		let started = spawn(writingTo: ends[1])
		close(ends[1])
		guard let pid = started else { return nil }
		let collector = Collector()
		output.readabilityHandler = { handle in collector.append(handle.availableData) }
		// Waits for the shell to exit without reaping it: until it's reaped,
		// its process ID, which names its process group, can't be reused.
		Thread.detachNewThread {
			var info = siginfo_t()
			_ = waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT)
			collector.ended()
		}
		let timer = Task {
			try? await Task.sleep(for: timeout)
			if !Task.isCancelled { collector.timedOut() }
		}
		let text = await withTaskCancellationHandler {
			await collector.answer()
		} onCancel: {
			collector.timedOut()
		}
		timer.cancel()
		output.readabilityHandler = nil
		Self.stop(pid)
		return text
	}

	/// Starts the shell in a session of its own. With no terminal it runs no
	/// job control, so all it starts stays in its process group, which
	/// `stop(_:)` ends together.
	private func spawn(writingTo output: Int32) -> pid_t? {
		var actions: posix_spawn_file_actions_t?
		posix_spawn_file_actions_init(&actions)
		defer { posix_spawn_file_actions_destroy(&actions) }
		posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
		posix_spawn_file_actions_adddup2(&actions, output, STDOUT_FILENO)
		posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)
		var attributes: posix_spawnattr_t?
		posix_spawnattr_init(&attributes)
		defer { posix_spawnattr_destroy(&attributes) }
		// Closes every other descriptor in the shell, LPM Vault's own included.
		posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))
		var pid: pid_t = 0
		let status = Self.withCStrings([shell, "-l", "-i", "-c", script]) { arguments in
			Self.withCStrings(environment.map { "\($0.key)=\($0.value)" }) { variables in
				posix_spawn(&pid, shell, &actions, &attributes, arguments, variables)
			}
		}
		return status == 0 ? pid : nil
	}

	/// Asks the shell's process group to stop, then, a second later, stops
	/// whatever ignored that, and reaps the shell once nothing in its group
	/// can be named by its process ID any more.
	private static func stop(_ pid: pid_t) {
		kill(-pid, SIGTERM)
		Thread.detachNewThread {
			Thread.sleep(forTimeInterval: 1)
			kill(-pid, SIGKILL)
			var status: Int32 = 0
			while waitpid(pid, &status, 0) == -1, errno == EINTR {}
		}
	}

	private static func withCStrings<Result>(_ strings: [String],
		_ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) -> Result) -> Result
	{
		let pointers = strings.map { strdup($0) } + [nil]
		defer { for pointer in pointers { free(pointer) } }
		return pointers.withUnsafeBufferPointer { body($0.baseAddress!) }
	}

	/// The shell's output as it arrives, answered once: when the version line
	/// ends, when the output closes after the shell exits, or at the timeout.
	private final class Collector: @unchecked Sendable {
		private let lock = NSLock()
		private var data = Data()
		private var closed = false
		private var exited = false
		private var finished = false
		private var continuation: CheckedContinuation<String?, Never>?
		private static let limit = 64 * 1024
		private static let versionMarker = Data(LPMCLILocator.versionMarker.utf8)

		func answer() async -> String? {
			await withCheckedContinuation { continuation in
				let ready: String?? = lock.withLock {
					if finished { return .some(text) }
					self.continuation = continuation
					return nil
				}
				if let ready { continuation.resume(returning: ready) }
			}
		}

		func append(_ chunk: Data) {
			finish { () -> Bool in
				if chunk.isEmpty {
					closed = true
					return exited
				}
				if data.count < Self.limit { data.append(chunk.prefix(Self.limit - data.count)) }
				guard let marker = data.range(of: Self.versionMarker) else { return false }
				return data[marker.upperBound...].contains(UInt8(ascii: "\n"))
			}
		}

		func ended() {
			finish { () -> Bool in
				exited = true
				return closed
			}
		}

		func timedOut() {
			finish { true }
		}

		private var text: String? { data.isEmpty ? nil : String(decoding: data, as: UTF8.self) }

		/// Answers once `isDone`, run under the lock, says the output is complete.
		private func finish(_ isDone: () -> Bool) {
			let resume: (CheckedContinuation<String?, Never>, String?)? = lock.withLock {
				guard !finished, isDone() else { return nil }
				finished = true
				defer { continuation = nil }
				return continuation.map { ($0, text) }
			}
			if let resume { resume.0.resume(returning: resume.1) }
		}
	}
}
