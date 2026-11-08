import Foundation
import Testing

@testable import LPMVault

@Suite("Finding the LPM CLI")
struct LPMCLILocatorTests {
	@Test("the answer is read from among what the shell's startup files print")
	func parsesAmongNoise() {
		let output = "\u{1B}]7;file://mac/Users/me\u{07}Welcome back\n\n\(LPMCLILocator.pathMarker)/Users/me/.n/bin/lpm\n"
			+ "\(LPMCLILocator.versionMarker)lpm 0.84.0\n"
		#expect(LPMCLILocator.status(from: output) == .found(path: "/Users/me/.n/bin/lpm", version: "0.84.0"))
	}

	@Test("no lpm, an alias, or an unreadable version each say so")
	func missingAliasAndVersionless() {
		#expect(LPMCLILocator.status(from: "\(LPMCLILocator.pathMarker)\n\(LPMCLILocator.versionMarker)\n") == .notFound)
		#expect(LPMCLILocator.status(from: "\(LPMCLILocator.pathMarker)alias lpm='npx lpm'\n") == .notFound)
		#expect(LPMCLILocator.status(from: "\(LPMCLILocator.pathMarker)/opt/homebrew/bin/lpm\n\(LPMCLILocator.versionMarker)oops\n")
			== .found(path: "/opt/homebrew/bin/lpm", version: nil))
		#expect(LPMCLILocator.status(from: "zsh: something went wrong\n") == nil, "No answer at all isn't an answer that lpm is missing")
	}

	@Test("a version is the first dotted number, prerelease and all")
	func versions() {
		#expect(LPMCLILocator.version(in: "lpm 1.4.2") == "1.4.2")
		#expect(LPMCLILocator.version(in: "lpm 0.85.0-nightly.3 (abc)") == "0.85.0-nightly.3")
		#expect(LPMCLILocator.version(in: "lpm version unknown") == nil)
		#expect(LPMCLILocator.version(in: "lpm 1.2") == nil)
	}

	@Test("the login shell finds the program on the PATH it's given, and its version")
	func findsThroughTheShell() async throws {
		let folder = FileManager.default.temporaryDirectory.appendingPathComponent("lpm-cli-\(UUID().uuidString)", isDirectory: true)
		let bin = folder.appendingPathComponent("bin", isDirectory: true)
		try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: folder) }
		let program = "lpm-vault-test-\(UUID().uuidString.prefix(8).lowercased())"
		let script = bin.appendingPathComponent(program)
		try "#!/bin/sh\necho 'lpm 9.8.7'\necho '  Update available: 9.8.7 -> 9.9.0'\n".write(to: script, atomically: true, encoding: .utf8)
		try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
		let environment = ["HOME": folder.path, "PATH": "\(bin.path):/usr/bin:/bin", "TERM": "dumb"]

		let found = await LPMCLILocator(shell: "/bin/zsh", program: program, environment: environment).locate()
		#expect(found == .found(path: script.path, version: "9.8.7"))

		let missing = await LPMCLILocator(shell: "/bin/zsh", program: program + "-missing", environment: environment).locate()
		#expect(missing == .notFound)
	}

	@Test("a shell that doesn't run, or doesn't answer in time, leaves the answer unavailable")
	func unavailableShell() async throws {
		let folder = FileManager.default.temporaryDirectory.appendingPathComponent("lpm-cli-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: folder) }
		let silent = folder.appendingPathComponent("silent-shell")
		try "#!/bin/sh\nexec sleep 100000\n".write(to: silent, atomically: true, encoding: .utf8)
		try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: silent.path)

		#expect(await LPMCLILocator(shell: folder.appendingPathComponent("absent").path, environment: [:]).locate() == .unavailable)
		#expect(await LPMCLILocator(shell: silent.path, timeout: .milliseconds(200), environment: [:]).locate() == .unavailable)
	}

	@Test("a lookup that times out stops the shell and everything it started, even what ignores being asked to stop")
	func stopsEverythingItStarted() async throws {
		let folder = FileManager.default.temporaryDirectory.appendingPathComponent("lpm-cli-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: folder) }
		let shell = folder.appendingPathComponent("stubborn-shell")
		let childFile = folder.appendingPathComponent("child.pid"), shellFile = folder.appendingPathComponent("shell.pid")
		try "#!/bin/sh\ntrap '' TERM\nsleep 100000 &\necho $! > \"$LPM_TEST_CHILD\"\necho $$ > \"$LPM_TEST_SHELL\"\nwait\n"
			.write(to: shell, atomically: true, encoding: .utf8)
		try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shell.path)

		let status = await LPMCLILocator(shell: shell.path, timeout: .milliseconds(500), environment: [
			"PATH": "/bin:/usr/bin", "LPM_TEST_CHILD": childFile.path, "LPM_TEST_SHELL": shellFile.path,
		]).locate()
		#expect(status == .unavailable)
		let pids = try [childFile, shellFile].map { file in
			try #require(pid_t(String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
		}
		let ended = try await waitUntil { pids.allSatisfy { kill($0, 0) != 0 } }
		// Only when they outlived it: once they're gone, their process IDs can be another process's.
		if !ended { for pid in pids { kill(pid, SIGKILL) } }
		#expect(ended, "Neither the shell nor what it started outlives the lookup")
	}

	@Test("a cancelled lookup ends at once, with the shell stopped, rather than at the timeout")
	func cancelled() async throws {
		let folder = FileManager.default.temporaryDirectory.appendingPathComponent("lpm-cli-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: folder) }
		let silent = folder.appendingPathComponent("silent-shell")
		try "#!/bin/sh\nexec sleep 100000\n".write(to: silent, atomically: true, encoding: .utf8)
		try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: silent.path)

		let locator = LPMCLILocator(shell: silent.path, timeout: .seconds(3600), environment: [:])
		let lookup = Task { await locator.locate() }
		try await letStartedWorkGetAhead()
		lookup.cancel()
		let answer = LockedCLIStatus(.found(path: "", version: nil))
		let ended = LockedCount()
		Task {
			answer.value = await lookup.value
			ended.add()
		}
		#expect(try await waitUntil { ended.value == 1 }, "An hour's timeout would hold it far past the test's limit")
		#expect(ended.value == 0 || answer.value == .unavailable)
	}
}
