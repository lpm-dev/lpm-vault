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
		allInstalledVersionsAreCompatible(
			executableCandidates().map { versionOutput(executable: $0) }
		)
	}

	static func allInstalledVersionsAreCompatible(
		_ versionOutputs: [String?]
	) -> Bool {
		!versionOutputs.isEmpty && versionOutputs.allSatisfy { output in
			guard let output else { return false }
			return isCompatible(versionOutput: output)
		}
	}

	private static func executableCandidates() -> [URL] {
		let home = FileManager.default.homeDirectoryForCurrentUser
		var paths = (ProcessInfo.processInfo.environment["PATH"] ?? "")
			.split(separator: ":", omittingEmptySubsequences: true)
			.map { URL(fileURLWithPath: String($0)).appendingPathComponent("lpm") }
		paths.append(contentsOf: [
			URL(fileURLWithPath: "/opt/homebrew/bin/lpm"),
			URL(fileURLWithPath: "/usr/local/bin/lpm"),
			home.appendingPathComponent(".local/bin/lpm"),
			home.appendingPathComponent(".n/bin/lpm"),
		])
		var seen: Set<String> = []
		return paths.compactMap { candidate in
			let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
			guard seen.insert(resolved.path).inserted,
				let values = try? resolved.resourceValues(
					forKeys: [.isRegularFileKey, .isExecutableKey]
				),
				values.isRegularFile == true,
				values.isExecutable == true
			else { return nil }
			return resolved
		}
	}

	private static func versionOutput(executable: URL) -> String? {
		let process = Process()
		let output = Pipe()
		process.executableURL = executable
		process.arguments = ["--version"]
		process.standardInput = FileHandle.nullDevice
		process.standardOutput = output
		process.standardError = FileHandle.nullDevice
		do {
			try process.run()
		} catch {
			return nil
		}
		let deadline = Date().addingTimeInterval(2)
		while process.isRunning, Date() < deadline {
			Thread.sleep(forTimeInterval: 0.02)
		}
		if process.isRunning {
			process.terminate()
			return nil
		}
		guard process.terminationStatus == 0 else { return nil }
		let data = output.fileHandleForReading.readDataToEndOfFile()
		guard data.count <= 4 * 1024 else { return nil }
		return String(data: data, encoding: .utf8)
	}
}
