import Darwin
import Foundation
import Testing

@testable import LPMVault

@Suite("Export staging protection")
@MainActor
struct ExportStagingValidationTests {
	nonisolated private static func git(_ arguments: [String], in directory: URL) throws -> (status: Int32, output: String) {
		let process = Process()
		process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
		process.arguments = ["-C", directory.path] + arguments
		process.environment = ["PATH": "/usr/bin:/bin", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"]
		let output = Pipe()
		process.standardOutput = output
		process.standardError = FileHandle.nullDevice
		try process.run()
		let data = output.fileHandleForReading.readDataToEndOfFile()
		process.waitUntilExit()
		return (process.terminationStatus, String(decoding: data, as: UTF8.self))
	}

	nonisolated private static func stagingContainsOnlyIgnoreRule(_ directory: URL) throws -> Bool {
		guard try FileManager.default.contentsOfDirectory(atPath: directory.path) == [".gitignore"] else { return false }
		return try String(contentsOf: directory.appendingPathComponent(".gitignore"), encoding: .utf8) == "*\n"
	}

	@Test("Git exclusion protects the plaintext staging file before replacement")
	func stagingFileIsIgnored() async throws {
		let folder = FileManager.default.temporaryDirectory.appendingPathComponent("export-staging-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: folder) }
		#expect(try Self.git(["init", "-q"], in: folder).status == 0)
		#expect(try Self.git(["config", "core.excludesFile", "/dev/null"], in: folder).status == 0)
		let destination = folder.appendingPathComponent(".env")
		let service = EnvFileExportService(worker: { secrets, destination, stagingDirectory, directoryDescriptor, authorization in
			try SecureFileWriter.write(
				EnvFileCodec.formatData(secrets),
				to: destination,
				stagingDirectory: stagingDirectory,
				authorization: authorization,
				beforeWrite: { temporaryURL in
					let temporary = temporaryURL.path.replacingOccurrences(of: folder.path + "/", with: "")
					#expect(try Data(contentsOf: temporaryURL).isEmpty)
					let ignored = try Self.git(["check-ignore", "--no-index", "--", temporary], in: folder)
					let staged = try Self.git(["add", "--dry-run", "--all"], in: folder)
					print("EXPORT_STAGING_PROBE ignored=\(ignored.status == 0) eligible=\(staged.output.contains(temporary))")
					#expect(ignored.status == 0)
					#expect(!staged.output.contains(temporary))
				},
				beforeReplacement: {
					let temporary = try #require(FileManager.default.contentsOfDirectory(atPath: stagingDirectory.path)
						.first { $0.hasPrefix(".lpm-vault-") && $0.hasSuffix(".tmp") })
					let temporaryURL = stagingDirectory.appendingPathComponent(temporary)
					#expect(try String(contentsOf: temporaryURL, encoding: .utf8).contains("DEMO-STAGING-ONLY"))
					#expect(try Self.git(["add", "--all"], in: folder).status == 0)
					let indexed = try Self.git(["grep", "--cached", "--fixed-strings", "--quiet", "--", "DEMO-STAGING-ONLY"], in: folder)
					print("EXPORT_INDEX_PROBE contains_dummy=\(indexed.status == 0)")
					#expect(indexed.status == 1)
				},
				directoryDescriptor: directoryDescriptor
			)
		})
		_ = try await service.export(secrets: ["TOKEN": "DEMO-STAGING-ONLY"], to: destination, projectFolder: folder.path)
		#expect(try Self.git(["check-ignore", "--no-index", "--", ".env"], in: folder).status == 0)
		#expect(try Self.git(["grep", "--cached", "--fixed-strings", "--quiet", "--", "DEMO-STAGING-ONLY"], in: folder).status == 1)
		#expect(try Self.stagingContainsOnlyIgnoreRule(EnvFileExportService.stagingDirectory(for: destination)))
	}

	@Test("Concurrent exports share one protected staging directory")
	func concurrentExportsUseProtectedStagingDirectory() async throws {
		let folder = FileManager.default.temporaryDirectory.appendingPathComponent("export-staging-concurrent-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: folder) }
		#expect(try Self.git(["init", "-q"], in: folder).status == 0)
		#expect(try Self.git(["config", "core.excludesFile", "/dev/null"], in: folder).status == 0)
		let firstDestination = folder.appendingPathComponent(".env.first")
		let secondDestination = folder.appendingPathComponent(".env.second")
		let service = EnvFileExportService()

		async let first = service.export(secrets: ["TOKEN": "FIRST-DEMO"], to: firstDestination, projectFolder: folder.path)
		async let second = service.export(secrets: ["TOKEN": "SECOND-DEMO"], to: secondDestination, projectFolder: folder.path)
		_ = try await (first, second)

		#expect(try String(contentsOf: firstDestination, encoding: .utf8).contains("FIRST-DEMO"))
		#expect(try String(contentsOf: secondDestination, encoding: .utf8).contains("SECOND-DEMO"))
		let stagingDirectory = EnvFileExportService.stagingDirectory(for: firstDestination)
		#expect(try Self.stagingContainsOnlyIgnoreRule(stagingDirectory))
		let attributes = try FileManager.default.attributesOfItem(atPath: stagingDirectory.path)
		#expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
		let ignoreLines = try String(contentsOf: folder.appendingPathComponent(".gitignore"), encoding: .utf8)
			.split(separator: "\n")
		#expect(ignoreLines.filter { $0 == "/\(EnvFileExportService.stagingDirectoryName)" }.count == 1)
		#expect(try Self.git(["add", "--all"], in: folder).status == 0)
		for marker in ["FIRST-DEMO", "SECOND-DEMO"] {
			#expect(try Self.git(["grep", "--cached", "--fixed-strings", "--quiet", "--", marker], in: folder).status == 1)
		}
	}

	@Test("A tracked staging candidate is never used or modified")
	func trackedStagingCandidateIsSkipped() async throws {
		let folder = FileManager.default.temporaryDirectory.appendingPathComponent("export-staging-tracked-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: folder) }
		#expect(try Self.git(["init", "-q"], in: folder).status == 0)
		#expect(try Self.git(["config", "core.excludesFile", "/dev/null"], in: folder).status == 0)
		let destination = folder.appendingPathComponent(".env")
		let stagingPath = EnvFileExportService.stagingDirectory(for: destination)
		try Data("tracked placeholder".utf8).write(to: stagingPath)
		#expect(try Self.git(["add", "-f", "--", stagingPath.lastPathComponent], in: folder).status == 0)

		try await EnvFileExportService().export(
			secrets: ["TOKEN": "ALTERNATE-STAGING-DEMO"],
			to: destination,
			projectFolder: folder.path
		)
		let actualStaging = EnvFileExportService.stagingDirectory(for: destination)
		#expect(actualStaging != stagingPath)
		#expect(try String(contentsOf: destination, encoding: .utf8).contains("ALTERNATE-STAGING-DEMO"))
		#expect(try String(contentsOf: stagingPath, encoding: .utf8) == "tracked placeholder")
		#expect(try Self.stagingContainsOnlyIgnoreRule(actualStaging))
	}

	@Test("A symbolic-link staging directory is never followed")
	func stagingDirectorySymlinkIsRefused() throws {
		let folder = FileManager.default.temporaryDirectory.appendingPathComponent("export-staging-link-\(UUID().uuidString)", isDirectory: true)
		let outside = FileManager.default.temporaryDirectory.appendingPathComponent("export-staging-link-target-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
		defer {
			try? FileManager.default.removeItem(at: folder)
			try? FileManager.default.removeItem(at: outside)
		}
		let destination = folder.appendingPathComponent(".env")
		let stagingDirectory = EnvFileExportService.stagingDirectory(for: destination)
		try FileManager.default.createSymbolicLink(at: stagingDirectory, withDestinationURL: outside)

		let error = #expect(throws: SecureFileWriter.WriteError.self) {
			try SecureFileWriter.write(
				Data("TOKEN=MUST-NOT-BE-WRITTEN\n".utf8),
				to: destination,
				stagingDirectory: stagingDirectory
			)
		}
		guard case .createFailed(let code)? = error else {
			Issue.record("Expected staging creation refusal, got \(String(describing: error))")
			return
		}
		#expect(code == ELOOP || code == ENOTDIR)
		#expect(!FileManager.default.fileExists(atPath: destination.path))
		#expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
	}

	@Test("A destination parent swap cannot redirect the final replacement")
	func destinationParentSwapIsRefused() throws {
		let container = FileManager.default.temporaryDirectory.appendingPathComponent("export-staging-parent-swap-\(UUID().uuidString)", isDirectory: true)
		let original = container.appendingPathComponent("original", isDirectory: true)
		let retained = container.appendingPathComponent("retained", isDirectory: true)
		let redirected = container.appendingPathComponent("redirected", isDirectory: true)
		try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
		try FileManager.default.createDirectory(at: redirected, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: container) }
		#expect(try Self.git(["init", "-q"], in: container).status == 0)
		#expect(try Self.git(["config", "core.excludesFile", "/dev/null"], in: container).status == 0)
		let destination = original.appendingPathComponent(".env")
		let stagingDirectory = EnvFileExportService.stagingDirectory(for: destination)

		let error = #expect(throws: SecureFileWriter.WriteError.self) {
			try SecureFileWriter.write(
				Data("TOKEN=MUST-NOT-BE-REDIRECTED\n".utf8),
				to: destination,
				stagingDirectory: stagingDirectory,
				beforeWrite: { _ in
					try FileManager.default.moveItem(at: original, to: retained)
					try FileManager.default.createSymbolicLink(at: original, withDestinationURL: redirected)
				}
			)
		}
		#expect(error == .replaceFailed(ESTALE))
		#expect(!FileManager.default.fileExists(atPath: redirected.appendingPathComponent(".env").path))
		#expect(!FileManager.default.fileExists(atPath: retained.appendingPathComponent(".env").path))
		#expect(try Self.stagingContainsOnlyIgnoreRule(retained.appendingPathComponent(EnvFileExportService.stagingDirectoryName)))
		#expect(try Self.git(["add", "--all"], in: container).status == 0)
		#expect(try Self.git(["grep", "--cached", "--fixed-strings", "--quiet", "--", "MUST-NOT-BE-REDIRECTED"], in: container).status == 1)
	}

	@Test("The prepared parent remains bound through writer entry")
	func preparedParentSwapIsRefused() async throws {
		let container = FileManager.default.temporaryDirectory.appendingPathComponent("export-prepared-parent-swap-\(UUID().uuidString)", isDirectory: true)
		let original = container.appendingPathComponent("original", isDirectory: true)
		let retained = container.appendingPathComponent("retained", isDirectory: true)
		let redirected = container.appendingPathComponent("redirected", isDirectory: true)
		try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
		try FileManager.default.createDirectory(at: redirected, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: container) }
		for repository in [original, redirected] {
			#expect(try Self.git(["init", "-q"], in: repository).status == 0)
			#expect(try Self.git(["config", "core.excludesFile", "/dev/null"], in: repository).status == 0)
		}
		let destination = original.appendingPathComponent(".env")
		let service = EnvFileExportService(preparer: { destination, stagingDirectory, project in
			let warnings = try EnvFileExportService.keepOutOfGit(destination, stagingDirectory, project)
			try FileManager.default.moveItem(at: original, to: retained)
			try FileManager.default.createSymbolicLink(at: original, withDestinationURL: redirected)
			return warnings
		})

		let error = await #expect(throws: EnvFileExportError.self) {
			try await service.export(
				secrets: ["TOKEN": "MUST-NOT-ENTER-REDIRECTED"],
				to: destination,
				projectFolder: original.path
			)
		}
		guard case .notKeptOutOfGit(let reason)? = error else {
			Issue.record("Expected changed-parent refusal, got \(String(describing: error))")
			return
		}
		#expect(reason.contains("export folder changed"))
		#expect(!FileManager.default.fileExists(atPath: redirected.appendingPathComponent(".env").path))
		#expect(!FileManager.default.fileExists(atPath: retained.appendingPathComponent(".env").path))
		#expect(try Self.git(["grep", "--cached", "--fixed-strings", "--quiet", "--", "MUST-NOT-ENTER-REDIRECTED"], in: redirected).status == 1)
	}

	@Test("A renamed staging directory keeps plaintext out of Git")
	func renamedStagingDirectoryRemainsIgnored() async throws {
		let folder = FileManager.default.temporaryDirectory.appendingPathComponent("export-renamed-staging-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: folder) }
		#expect(try Self.git(["init", "-q"], in: folder).status == 0)
		#expect(try Self.git(["config", "core.excludesFile", "/dev/null"], in: folder).status == 0)
		let destination = folder.appendingPathComponent(".env")
		let movedStagingDirectory = folder.appendingPathComponent("moved-staging", isDirectory: true)
		let service = EnvFileExportService(worker: { secrets, destination, stagingDirectory, directoryDescriptor, authorization in
			try SecureFileWriter.write(
				EnvFileCodec.formatData(secrets),
				to: destination,
				stagingDirectory: stagingDirectory,
				authorization: authorization,
				beforeWrite: { _ in
					try FileManager.default.moveItem(at: stagingDirectory, to: movedStagingDirectory)
				},
				beforeReplacement: {
					let temporary = try #require(FileManager.default.contentsOfDirectory(atPath: movedStagingDirectory.path)
						.first { $0.hasPrefix(".lpm-vault-") && $0.hasSuffix(".tmp") })
					let relative = "\(movedStagingDirectory.lastPathComponent)/\(temporary)"
					#expect(try Self.git(["check-ignore", "--no-index", "--", relative], in: folder).status == 0)
					#expect(try Self.git(["add", "--all"], in: folder).status == 0)
					#expect(try Self.git(["grep", "--cached", "--fixed-strings", "--quiet", "--", "RENAMED-STAGING-DEMO"], in: folder).status == 1)
				},
				directoryDescriptor: directoryDescriptor
			)
		})

		try await service.export(
			secrets: ["TOKEN": "RENAMED-STAGING-DEMO"],
			to: destination,
			projectFolder: folder.path
		)
		#expect(try String(contentsOf: destination, encoding: .utf8).contains("RENAMED-STAGING-DEMO"))
		#expect(try Self.stagingContainsOnlyIgnoreRule(movedStagingDirectory))
		#expect(try Self.git(["grep", "--cached", "--fixed-strings", "--quiet", "--", "RENAMED-STAGING-DEMO"], in: folder).status == 1)
	}

	@Test("The staging directory name remains a valid export filename")
	func stagingDirectoryNameCanBeExported() async throws {
		let folder = FileManager.default.temporaryDirectory.appendingPathComponent("export-staging-name-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: folder) }
		#expect(try Self.git(["init", "-q"], in: folder).status == 0)
		#expect(try Self.git(["config", "core.excludesFile", "/dev/null"], in: folder).status == 0)
		let widthVariant = try #require(EnvFileExportService.stagingDirectoryName.applyingTransform(.fullwidthToHalfwidth, reverse: true))
		for (index, fileName) in [
			EnvFileExportService.stagingDirectoryName,
			EnvFileExportService.stagingDirectoryName.uppercased(),
			widthVariant,
		].enumerated() {
			let destination = folder.appendingPathComponent(fileName)
			let stagingDirectory = EnvFileExportService.stagingDirectory(for: destination)
			#expect(stagingDirectory.lastPathComponent != fileName)
			let marker = "RESERVED-NAME-DEMO-\(index)"

			try await EnvFileExportService().export(
				secrets: ["TOKEN": marker],
				to: destination,
				projectFolder: folder.path
			)

			var isDirectory: ObjCBool = true
			#expect(FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDirectory))
			#expect(!isDirectory.boolValue)
			#expect(try String(contentsOf: destination, encoding: .utf8).contains(marker))
			#expect(try Self.stagingContainsOnlyIgnoreRule(stagingDirectory))
		}
		let reservedDestination = folder.appendingPathComponent(EnvFileExportService.stagingDirectoryName)
		let reservedContents = try Data(contentsOf: reservedDestination)
		let ordinaryDestination = folder.appendingPathComponent(".env")
		try await EnvFileExportService().export(
			secrets: ["TOKEN": "ORDINARY-AFTER-RESERVED"],
			to: ordinaryDestination,
			projectFolder: folder.path
		)
		#expect(try Data(contentsOf: reservedDestination) == reservedContents)
		#expect(try String(contentsOf: ordinaryDestination, encoding: .utf8).contains("ORDINARY-AFTER-RESERVED"))
		#expect(try Self.stagingContainsOnlyIgnoreRule(EnvFileExportService.stagingDirectory(for: ordinaryDestination)))
	}

	@Test("Staged replacement synchronizes both changed directories")
	func stagedReplacementSynchronizesBothDirectories() throws {
		let folder = FileManager.default.temporaryDirectory.appendingPathComponent("export-staging-sync-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: folder) }
		let destination = folder.appendingPathComponent(".env")
		let stagingDirectory = EnvFileExportService.stagingDirectory(for: destination)
		var synchronized: [URL] = []

		try SecureFileWriter.write(
			Data("TOKEN=SYNC-DEMO\n".utf8),
			to: destination,
			stagingDirectory: stagingDirectory,
			directorySynchronizer: { directory in
				synchronized.append(directory)
				return nil
			}
		)

		#expect(synchronized == [folder, stagingDirectory])
		#expect(try String(contentsOf: destination, encoding: .utf8) == "TOKEN=SYNC-DEMO\n")
		#expect(try Self.stagingContainsOnlyIgnoreRule(stagingDirectory))
	}
}
