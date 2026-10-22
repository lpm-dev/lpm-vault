import Foundation
import Testing

@testable import LPMVault

@Suite("Export keeps the file out of git")
@MainActor
struct EnvFileExportGitTests {
	private func repository() throws -> URL {
		let folder = FileManager.default.temporaryDirectory
			.appendingPathComponent("lpm-vault-export-git-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		for arguments in [["init", "-q"], ["config", "core.excludesFile", "/dev/null"]] {
			try git(arguments, in: folder)
		}
		return folder
	}

	private func git(_ arguments: [String], in folder: URL) throws {
		let process = Process()
		process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
		process.arguments = ["git", "-C", folder.path] + arguments
		process.standardOutput = FileHandle.nullDevice
		process.standardError = FileHandle.nullDevice
		try process.run()
		process.waitUntilExit()
		try #require(process.terminationStatus == 0, "git \(arguments)")
	}

	private func store(projectPath: String = "", preferences: UserDefaults = .standard) -> VaultStore {
		let store = VaultStore(
			keychainService: MockKeychainService(),
			biometricService: MockBiometricService(),
			apiService: MockAPIService(),
			preferences: preferences
		)
		store.projects = [VaultProject(
			id: "project", name: "Project", path: projectPath,
			environments: ["default": ["TOKEN": "secret"]]
		)]
		store.isUnlocked = true
		store.openProject(id: "project")
		return store
	}

	@Test("an export into a repository is ignored by git before its secrets are written")
	func exportAddsIgnoreRuleFirst() async throws {
		let project = try repository()
		defer { try? FileManager.default.removeItem(at: project) }
		let destination = project.appendingPathComponent(".env")

		let warnings = try await store(projectPath: project.path)
			.exportEnvironment(projectId: "project", environment: "default", to: destination)

		#expect(warnings.isEmpty)
		#expect(try String(contentsOf: destination, encoding: .utf8) == "TOKEN=\"secret\"\n")
		#expect(try String(contentsOf: project.appendingPathComponent(".gitignore"), encoding: .utf8)
			.contains("/.env"))
	}

	@Test("an export over a file git tracks is refused, and the file keeps what it had")
	func exportRefusesTrackedFile() async throws {
		let project = try repository()
		defer { try? FileManager.default.removeItem(at: project) }
		let destination = project.appendingPathComponent(".env.production")
		try Data("TOKEN=\n".utf8).write(to: destination)
		try git(["add", "-f", ".env.production"], in: project)

		let error = await #expect(throws: EnvFileExportError.self) {
			try await store(projectPath: project.path)
				.exportEnvironment(projectId: "project", environment: "default", to: destination)
		}
		guard case .trackedByGit(let file, let untrack)? = error else {
			Issue.record("Expected a tracked-file refusal, got \(String(describing: error))")
			return
		}
		#expect(file == ".env.production")
		#expect(untrack.contains("rm --cached -- .env.production"))
		#expect(error?.localizedDescription.hasPrefix("Git tracks .env.production, so the secrets exported there would be committed.") == true)
		#expect(try String(contentsOf: destination, encoding: .utf8) == "TOKEN=\n")
	}

	@Test("an export inside the linked project takes the rule in the project's .gitignore")
	func exportUsesLinkedProjectFolder() async throws {
		let project = try repository()
		defer { try? FileManager.default.removeItem(at: project) }
		let domain = "lpm-export-git-\(UUID().uuidString)"
		let defaults = try #require(UserDefaults(suiteName: domain))
		defer { defaults.removePersistentDomain(forName: domain) }
		ProjectCLILink.rememberFolder(project.path, vaultId: "project", defaults: defaults)
		let config = project.appendingPathComponent("config", isDirectory: true)
		try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)

		try await store(preferences: defaults)
			.exportEnvironment(projectId: "project", environment: "default", to: config.appendingPathComponent(".env"))

		#expect(try String(contentsOf: project.appendingPathComponent(".gitignore"), encoding: .utf8)
			.contains("/config/.env"))
		#expect(!FileManager.default.fileExists(atPath: config.appendingPathComponent(".gitignore").path))
	}

	@Test("a refused destination never reaches the writer, and warnings come back from a write")
	func preparerGatesTheWriter() async throws {
		let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		let wrote = Recorded(false)
		let refusing = EnvFileExportService(worker: { _, _, _ in wrote.value = true }, preparer: { _, _ in
			throw EnvFileExportError.notKeptOutOfGit(reason: "could not keep it out of git: no")
		})
		await #expect(throws: EnvFileExportError.notKeptOutOfGit(reason: "could not keep it out of git: no")) {
			try await refusing.export(secrets: ["TOKEN": "secret"], to: folder.appendingPathComponent(".env"))
		}
		#expect(!wrote.value)
		#expect(EnvFileExportError.notKeptOutOfGit(reason: "could not keep it out of git: no").localizedDescription
			== "Could not keep it out of git: no. Nothing was exported.")

		let projects = Recorded([String]())
		let warning = EnvFileExportService(worker: { _, _, _ in wrote.value = true }, preparer: { _, project in
			projects.value.append(project.path)
			return ["git could not be run"]
		})
		let warnings = try await warning.export(secrets: [:], to: folder.appendingPathComponent(".env"), projectFolder: "/no/such/folder")
		#expect(warnings == ["git could not be run"])
		#expect(wrote.value)
		#expect(projects.value == [folder.path], "A missing project folder falls back to the destination's own")
	}
}

private final class Recorded<Value: Sendable>: @unchecked Sendable {
	private let lock = NSLock()
	private var storage: Value

	init(_ value: Value) { storage = value }

	var value: Value {
		get { lock.withLock { storage } }
		set { lock.withLock { storage = newValue } }
	}
}
