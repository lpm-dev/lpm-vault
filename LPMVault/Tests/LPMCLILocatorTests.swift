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
}
