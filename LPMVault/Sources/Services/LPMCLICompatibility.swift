import Darwin
import Foundation

enum LPMCLICompatibility {
	private static let minimumProtectedKeychainVersion = [0, 76, 0]

	static func isCompatible(versionOutput: String) -> Bool {
		let fields = versionOutput.split(whereSeparator: \Character.isWhitespace)
		guard fields.count >= 2, fields[0] == "lpm" else { return false }
		let version = String(fields[1])
		guard !version.contains("-"), !version.contains("+") else { return false }
		let components = version.split(separator: ".", omittingEmptySubsequences: false)
		let parsed = components.compactMap { Int($0) }
		guard components.count == 3, parsed.count == 3,
			parsed.allSatisfy({ $0 >= 0 }) else { return false }
		return parsed.lexicographicallyPrecedes(minimumProtectedKeychainVersion) == false
	}

	static func installedCLIIsCompatible() -> Bool {
		installedCLIIsCompatible(
			candidates: executableCandidates(),
			versionReader: { versionOutput(executable: $0) }
		)
	}

	static func installedCLIIsCompatible(
		candidates: [URL],
		versionReader: (URL) -> String?
	) -> Bool {
		guard !candidates.isEmpty else { return false }
		for candidate in candidates {
			guard let output = versionReader(candidate),
				isCompatible(versionOutput: output)
			else { return false }
		}
		return true
	}

	static func allInstalledVersionsAreCompatible(
		_ versionOutputs: [String?]
	) -> Bool {
		!versionOutputs.isEmpty && versionOutputs.allSatisfy { output in
			guard let output else { return false }
			return isCompatible(versionOutput: output)
		}
	}

	static func candidateLocations(home: URL) -> [URL] {
		[
			URL(fileURLWithPath: "/opt/homebrew/bin/lpm"),
			URL(fileURLWithPath: "/usr/local/bin/lpm"),
			home.appendingPathComponent(".local/bin/lpm"),
			home.appendingPathComponent(".n/bin/lpm"),
		]
	}

	private static func executableCandidates() -> [URL] {
		let paths = candidateLocations(home: FileManager.default.homeDirectoryForCurrentUser)
		var seen: Set<String> = []
		return paths.compactMap { candidate in
			let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
			var metadata = stat()
			let status = resolved.withUnsafeFileSystemRepresentation { path in
				guard let path else { return Int32(-1) }
				return Darwin.lstat(path, &metadata)
			}
			guard status == 0,
				seen.insert(resolved.path).inserted,
				(metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
				metadata.st_nlink == 1,
				metadata.st_uid == 0 || metadata.st_uid == Darwin.geteuid(),
				(metadata.st_mode & 0o022) == 0,
				Darwin.access(resolved.path, X_OK) == 0
			else { return nil }
			return resolved
		}
	}

	static func versionOutput(
		executable: URL,
		timeout: TimeInterval = 2,
		maximumBytes: Int = 4 * 1024
	) -> String? {
		var descriptors = [Int32](repeating: -1, count: 2)
		guard Darwin.pipe(&descriptors) == 0 else { return nil }
		let readDescriptor = descriptors[0]
		let writeDescriptor = descriptors[1]
		defer { _ = Darwin.close(readDescriptor) }

		var actions: posix_spawn_file_actions_t?
		guard posix_spawn_file_actions_init(&actions) == 0 else {
			_ = Darwin.close(writeDescriptor)
			return nil
		}
		defer { posix_spawn_file_actions_destroy(&actions) }
		guard posix_spawn_file_actions_adddup2(&actions, writeDescriptor, STDOUT_FILENO) == 0,
			posix_spawn_file_actions_addclose(&actions, readDescriptor) == 0,
			posix_spawn_file_actions_addclose(&actions, writeDescriptor) == 0,
			"/dev/null".withCString({ path in
				posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, path, O_RDONLY, 0)
			}) == 0,
			"/dev/null".withCString({ path in
				posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, path, O_WRONLY, 0)
			}) == 0
		else {
			_ = Darwin.close(writeDescriptor)
			return nil
		}

		var attributes: posix_spawnattr_t?
		guard posix_spawnattr_init(&attributes) == 0 else {
			_ = Darwin.close(writeDescriptor)
			return nil
		}
		defer { posix_spawnattr_destroy(&attributes) }
		let spawnFlags = Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)
		guard posix_spawnattr_setflags(&attributes, spawnFlags) == 0,
			posix_spawnattr_setpgroup(&attributes, 0) == 0
		else {
			_ = Darwin.close(writeDescriptor)
			return nil
		}

		let argumentStrings = [executable.path, "--version"]
		var arguments: [UnsafeMutablePointer<CChar>?] = argumentStrings.map { strdup($0) }
		arguments.append(nil)
		defer {
			for case let argument? in arguments {
				Darwin.free(UnsafeMutableRawPointer(argument))
			}
		}
		var identifier = pid_t()
		let spawnStatus = executable.path.withCString { path in
			arguments.withUnsafeBufferPointer { buffer in
				posix_spawn(
					&identifier,
					path,
					&actions,
					&attributes,
					buffer.baseAddress,
					environ
				)
			}
		}
		_ = Darwin.close(writeDescriptor)
		guard spawnStatus == 0 else { return nil }

		let descriptor = readDescriptor
		let flags = Darwin.fcntl(descriptor, F_GETFL)
		guard flags >= 0, Darwin.fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
			terminate(identifier)
			return nil
		}

		var data = Data()
		var reachedEOF = false
		func drainAvailableOutput() -> Bool {
			var buffer = [UInt8](repeating: 0, count: 512)
			while true {
				let count = buffer.withUnsafeMutableBytes { bytes in
					Darwin.read(descriptor, bytes.baseAddress, bytes.count)
				}
				if count > 0 {
					guard data.count + count <= maximumBytes else { return false }
					data.append(buffer, count: count)
					continue
				}
				if count == 0 {
					reachedEOF = true
					return true
				}
				if errno == EINTR { continue }
				if errno == EAGAIN || errno == EWOULDBLOCK { return true }
				return false
			}
		}

		var waitStatus = Int32()
		var didReap = false
		let deadline = ProcessInfo.processInfo.systemUptime + max(0, timeout)
		while ProcessInfo.processInfo.systemUptime < deadline {
			guard drainAvailableOutput() else {
				terminate(identifier)
				return nil
			}
			let waitResult = Darwin.waitpid(identifier, &waitStatus, WNOHANG)
			if waitResult == identifier {
				didReap = true
				terminateDescendants(identifier)
				Thread.sleep(forTimeInterval: 0.01)
				guard drainAvailableOutput(), (waitStatus & 0x7f) == 0,
					((waitStatus >> 8) & 0xff) == 0
				else { return nil }
				guard reachedEOF || !data.isEmpty else { return nil }
				return String(data: data, encoding: .utf8)
			}
			guard waitResult == 0 else { return nil }
			Thread.sleep(forTimeInterval: 0.01)
		}
		if !didReap { terminate(identifier) }
		return nil
	}

	private static func terminate(_ identifier: pid_t) {
		_ = Darwin.kill(-identifier, SIGTERM)
		var status = Int32()
		let deadline = ProcessInfo.processInfo.systemUptime + 0.1
		while ProcessInfo.processInfo.systemUptime < deadline {
			let result = Darwin.waitpid(identifier, &status, WNOHANG)
			if result == identifier || result == -1 { break }
			Thread.sleep(forTimeInterval: 0.005)
		}
		_ = Darwin.kill(-identifier, SIGKILL)
		while Darwin.waitpid(identifier, &status, 0) == -1, errno == EINTR {}
	}

	private static func terminateDescendants(_ identifier: pid_t) {
		_ = Darwin.kill(-identifier, SIGTERM)
		Thread.sleep(forTimeInterval: 0.01)
		_ = Darwin.kill(-identifier, SIGKILL)
	}
}
