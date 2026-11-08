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
	/// something the startup files started keeps the output open; the shell
	/// is stopped then, or once the timeout passes.
	private func run() async -> String? {
		let process = Process()
		process.executableURL = URL(fileURLWithPath: shell)
		process.arguments = ["-l", "-i", "-c", script]
		process.environment = environment
		process.standardInput = FileHandle.nullDevice
		process.standardError = FileHandle.nullDevice
		let output = Pipe()
		process.standardOutput = output
		let collector = Collector()
		output.fileHandleForReading.readabilityHandler = { handle in collector.append(handle.availableData) }
		process.terminationHandler = { _ in collector.ended() }
		do { try process.run() } catch {
			output.fileHandleForReading.readabilityHandler = nil
			return nil
		}
		let timer = Task {
			try? await Task.sleep(for: timeout)
			if !Task.isCancelled { collector.timedOut() }
		}
		let text = await collector.answer()
		timer.cancel()
		output.fileHandleForReading.readabilityHandler = nil
		if process.isRunning { process.terminate() }
		return text
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
