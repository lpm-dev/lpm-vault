import Darwin
import Foundation
import Testing

@testable import LPMVault

@Suite("Project config watcher", .serialized)
struct ProjectConfigWatcherTests {
	@Test("the watcher reports lpm.json written in place or replaced, once per burst")
	func reportsChanges() async throws {
		let folder = try makeFolder()
		defer { try? FileManager.default.removeItem(atPath: folder) }
		try "{}".write(toFile: folder + "/lpm.json", atomically: false, encoding: .utf8)
		let changes = ChangeCounter()
		let watching = watch(folder, into: changes)
		defer { watching.cancel() }
		try await Task.sleep(for: .milliseconds(100))

		let handle = try #require(FileHandle(forWritingAtPath: folder + "/lpm.json"))
		handle.write(Data(#"{"a":1}"#.utf8))
		try handle.close()
		#expect(try await eventually { changes.count == 1 })

		for value in 0..<5 {
			try #"{"b":\#(value)}"#.write(toFile: folder + "/lpm.json", atomically: true, encoding: .utf8)
		}
		#expect(try await eventually { changes.count == 2 })
		try await Task.sleep(for: .milliseconds(300))
		#expect(changes.count == 2, "A burst of saves is one change")

		let replaced = try #require(FileHandle(forWritingAtPath: folder + "/lpm.json"))
		replaced.write(Data(#"{"c":1}"#.utf8))
		try replaced.close()
		#expect(try await eventually { changes.count == 3 }, "The watcher follows the replaced file")
	}

	@Test("other files changing in the folder aren't changes to lpm.json")
	func ignoresOtherFiles() async throws {
		let folder = try makeFolder()
		defer { try? FileManager.default.removeItem(atPath: folder) }
		try "{}".write(toFile: folder + "/lpm.json", atomically: true, encoding: .utf8)
		let changes = ChangeCounter()
		let watching = watch(folder, into: changes)
		defer { watching.cancel() }
		try await Task.sleep(for: .milliseconds(100))
		for value in 0..<5 {
			try "\(value)".write(toFile: folder + "/.eslintcache", atomically: true, encoding: .utf8)
			try await Task.sleep(for: .milliseconds(20))
		}
		try await Task.sleep(for: .milliseconds(400))
		#expect(changes.count == 0)
	}

	@Test("a change keeps arriving while another file churns, and lpm.json edits during churn arrive within a second")
	func boundedDelay() async throws {
		let folder = try makeFolder()
		defer { try? FileManager.default.removeItem(atPath: folder) }
		try "{}".write(toFile: folder + "/lpm.json", atomically: true, encoding: .utf8)
		let changes = ChangeCounter()
		let watching = watch(folder, into: changes)
		defer { watching.cancel() }
		try await Task.sleep(for: .milliseconds(100))
		let start = ContinuousClock.now
		var index = 0
		while ContinuousClock.now - start < .milliseconds(1800) {
			try #"{"n":\#(index)}"#.write(toFile: folder + "/lpm.json", atomically: true, encoding: .utf8)
			index += 1
			try await Task.sleep(for: .milliseconds(20))
		}
		#expect(changes.count >= 1, "Continuous writes still report within the maximum delay")
	}

	@Test("a folder that's missing at first, or deleted and made again, is watched once it's there")
	func followsTheFolder() async throws {
		let parent = try makeFolder()
		defer { try? FileManager.default.removeItem(atPath: parent) }
		let folder = parent + "/project"
		let changes = ChangeCounter()
		let watching = watch(folder, into: changes)
		defer { watching.cancel() }
		try await Task.sleep(for: .milliseconds(100))
		try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
		try "{}".write(toFile: folder + "/lpm.json", atomically: true, encoding: .utf8)
		#expect(try await eventually(seconds: 4) { changes.count >= 1 }, "A folder made after the watch started is watched")

		let seen = changes.count
		try FileManager.default.removeItem(atPath: folder)
		try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
		try #"{"again":true}"#.write(toFile: folder + "/lpm.json", atomically: true, encoding: .utf8)
		#expect(try await eventually(seconds: 4) { changes.count > seen }, "A folder made again is watched")
		let recreated = changes.count
		try #"{"edited":true}"#.write(toFile: folder + "/lpm.json", atomically: true, encoding: .utf8)
		#expect(try await eventually(seconds: 4) { changes.count > recreated })
	}

	@Test("lpm.json that's a pipe or a link isn't opened, and the watch still ends and follows a real file", arguments: [false, true])
	func unsafeFiles(throughLink: Bool) async throws {
		let folder = try makeFolder()
		let outside = try makeFolder()
		defer {
			try? FileManager.default.removeItem(atPath: folder)
			try? FileManager.default.removeItem(atPath: outside)
		}
		let pipe = (throughLink ? outside : folder) + "/lpm.json"
		try #require(mkfifo(pipe, 0o600) == 0)
		if throughLink { try FileManager.default.createSymbolicLink(atPath: folder + "/lpm.json", withDestinationPath: pipe) }
		let descriptors = openDescriptors()
		for _ in 0..<10 {
			let changes = ChangeCounter()
			let watching = watch(folder, into: changes)
			try await Task.sleep(for: .milliseconds(30))
			watching.cancel()
		}
		#expect(try await eventually { openDescriptors() <= descriptors }, "Every watch closes what it opened")

		let changes = ChangeCounter()
		let watching = watch(folder, into: changes)
		defer { watching.cancel() }
		try await Task.sleep(for: .milliseconds(100))
		try FileManager.default.removeItem(atPath: folder + "/lpm.json")
		try "{}".write(toFile: folder + "/lpm.json", atomically: true, encoding: .utf8)
		#expect(try await eventually { changes.count >= 1 }, "The watch isn't stuck on the pipe")
	}

	@Test("a file lpm.json links to outside the project isn't watched")
	func ignoresLinkedFiles() async throws {
		let folder = try makeFolder()
		let outside = try makeFolder()
		defer {
			try? FileManager.default.removeItem(atPath: folder)
			try? FileManager.default.removeItem(atPath: outside)
		}
		try "{}".write(toFile: outside + "/target.json", atomically: false, encoding: .utf8)
		try FileManager.default.createSymbolicLink(atPath: folder + "/lpm.json", withDestinationPath: outside + "/target.json")
		let changes = ChangeCounter()
		let watching = watch(folder, into: changes)
		defer { watching.cancel() }
		try await Task.sleep(for: .milliseconds(100))
		for value in 0..<3 {
			let handle = try #require(FileHandle(forWritingAtPath: outside + "/target.json"))
			handle.write(Data(#"{"v":\#(value)}"#.utf8))
			try handle.close()
			try await Task.sleep(for: .milliseconds(50))
		}
		try await Task.sleep(for: .milliseconds(400))
		#expect(changes.count == 0)
	}

	private func makeFolder() throws -> String {
		let folder = FileManager.default.temporaryDirectory.appending(path: "config-watch-\(UUID().uuidString)").path
		try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
		return folder
	}

	private func watch(_ folder: String, into changes: ChangeCounter) -> Task<Void, Never> {
		Task {
			for await _ in ProjectConfigWatcher.changes(inFolder: folder, settling: .milliseconds(100), maximumDelay: .milliseconds(600), retryingEvery: .milliseconds(200)) {
				changes.increment()
			}
		}
	}

	private func openDescriptors() -> Int {
		(try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? 0
	}

	private func eventually(seconds: Double = 3, _ condition: () -> Bool) async throws -> Bool {
		let deadline = ContinuousClock.now + .seconds(seconds)
		while ContinuousClock.now < deadline {
			if condition() { return true }
			try await Task.sleep(for: .milliseconds(10))
		}
		return condition()
	}
}

private final class ChangeCounter: @unchecked Sendable {
	private let lock = NSLock()
	private var value = 0
	var count: Int { lock.withLock { value } }
	func increment() { lock.withLock { value += 1 } }
}

@Suite("Opening lpm.json")
struct ProjectConfigOpenerTests {
	@Test("only a regular file is opened; a link, a pipe, or a folder is shown in Finder instead")
	func opensOnlyRegularFiles() throws {
		let folder = FileManager.default.temporaryDirectory.appending(path: "config-open-\(UUID().uuidString)").path
		try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(atPath: folder) }
		try "{}".write(toFile: folder + "/regular.json", atomically: true, encoding: .utf8)
		try "#!/bin/sh\n".write(toFile: folder + "/payload.command", atomically: true, encoding: .utf8)
		try FileManager.default.createSymbolicLink(atPath: folder + "/lpm.json", withDestinationPath: folder + "/payload.command")
		#expect(mkfifo(folder + "/pipe.json", 0o600) == 0)
		try FileManager.default.createDirectory(atPath: folder + "/dir.json", withIntermediateDirectories: true)
		#expect(ProjectConfigOpener.opensInEditor(URL(fileURLWithPath: folder + "/regular.json")))
		for name in ["lpm.json", "pipe.json", "dir.json", "missing.json"] {
			#expect(!ProjectConfigOpener.opensInEditor(URL(fileURLWithPath: folder + "/" + name)), "\(name) is shown in Finder")
		}
	}
}

@Suite("Opening imported schemas")
struct ProjectConfigOpenerImportTests {
	@Test("only a JSON file inside the project opens, not another type or one reached through a link out of the folder")
	func opensOnlyProjectJSON() throws {
		let folder = FileManager.default.temporaryDirectory.appending(path: "import-open-\(UUID().uuidString)").path
		let outside = FileManager.default.temporaryDirectory.appending(path: "import-outside-\(UUID().uuidString)").path
		try FileManager.default.createDirectory(atPath: folder + "/schemas", withIntermediateDirectories: true)
		try FileManager.default.createDirectory(atPath: outside, withIntermediateDirectories: true)
		defer {
			try? FileManager.default.removeItem(atPath: folder)
			try? FileManager.default.removeItem(atPath: outside)
		}
		try "{}".write(toFile: folder + "/schemas/base.json", atomically: true, encoding: .utf8)
		try "{}".write(toFile: folder + "/schemas/page.html", atomically: true, encoding: .utf8)
		try "{}".write(toFile: outside + "/shared.json", atomically: true, encoding: .utf8)
		try FileManager.default.createSymbolicLink(atPath: folder + "/linked", withDestinationPath: outside)
		let root = URL(filePath: folder, directoryHint: .isDirectory)
		#expect(ProjectConfigOpener.opensInEditor(root.appending(path: "schemas/base.json"), within: root))
		#expect(!ProjectConfigOpener.opensInEditor(root.appending(path: "schemas/page.html"), within: root), "Another type could open in an app that runs it")
		#expect(!ProjectConfigOpener.opensInEditor(root.appending(path: "linked/shared.json"), within: root), "A linked folder leads outside the project")
	}
}

@Suite("Secure file writes")
struct SecureFileWriteErrorTests {
	@Test("write errors name the file operation, not an export, since lpm.json is written the same way")
	func wording() {
		#expect(SecureFileWriter.WriteError.createFailed(EACCES).localizedDescription == "Could not create the file: Permission denied")
		#expect(SecureFileWriter.WriteError.syncFailed(EIO).localizedDescription == "Could not save the file to disk: Input/output error")
	}
}
