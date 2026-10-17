import Darwin
import Foundation
import Testing

@testable import LPMVault

@Suite("Project config watcher", .serialized)
struct ProjectConfigWatcherTests {
	@Test("the watcher begins with a report, then reports lpm.json written in place, replaced, and written in place again")
	func reportsChanges() async throws {
		let folder = try makeFolder()
		defer { try? FileManager.default.removeItem(atPath: folder) }
		try "{}".write(toFile: folder + "/lpm.json", atomically: false, encoding: .utf8)
		let watch = try await startWatching(folder)
		defer { watch.cancel() }
		try writeInPlace(#"{"a":1}"#, to: folder + "/lpm.json")
		#expect(try await waitUntil { watch.changes == 1 }, "Written in place")
		try #"{"b":1}"#.write(toFile: folder + "/lpm.json", atomically: true, encoding: .utf8)
		#expect(try await waitUntil { watch.changes == 2 }, "Replaced, as editors save it")
		try writeInPlace(#"{"c":1}"#, to: folder + "/lpm.json")
		#expect(try await waitUntil { watch.changes == 3 }, "The watcher follows the replaced file")
	}

	@Test("a burst of saves is reported")
	func reportsBursts() async throws {
		let folder = try makeFolder()
		defer { try? FileManager.default.removeItem(atPath: folder) }
		try "{}".write(toFile: folder + "/lpm.json", atomically: false, encoding: .utf8)
		let watch = try await startWatching(folder)
		defer { watch.cancel() }
		for value in 0..<5 {
			try #"{"b":\#(value)}"#.write(toFile: folder + "/lpm.json", atomically: true, encoding: .utf8)
		}
		#expect(try await waitUntil { watch.changes >= 1 })
	}

	@Test("a schema lpm.json imports, written in place or replaced, is a change too")
	func reportsImportChanges() async throws {
		let folder = try makeFolder()
		defer { try? FileManager.default.removeItem(atPath: folder) }
		try FileManager.default.createDirectory(atPath: folder + "/schemas", withIntermediateDirectories: true)
		try "{}".write(toFile: folder + "/lpm.json", atomically: false, encoding: .utf8)
		try "{}".write(toFile: folder + "/schemas/base.json", atomically: false, encoding: .utf8)
		let watch = try await startWatching(folder, imports: ["schemas/base.json"])
		defer { watch.cancel() }
		try writeInPlace(#"{"vars":{"A":{"secret":true}}}"#, to: folder + "/schemas/base.json")
		#expect(try await waitUntil { watch.changes == 1 }, "An import written in place")
		try "{}".write(toFile: folder + "/schemas/other.json", atomically: true, encoding: .utf8)
		try await quietPeriod()
		#expect(watch.changes == 1, "A file lpm.json doesn't import isn't a change")
		try #"{"vars":{"A":{}}}"#.write(toFile: folder + "/schemas/base.json", atomically: true, encoding: .utf8)
		#expect(try await waitUntil { watch.changes == 2 }, "An import replaced, as git does")
	}

	@Test("other files changing in the folder aren't changes to lpm.json")
	func ignoresOtherFiles() async throws {
		let folder = try makeFolder()
		defer { try? FileManager.default.removeItem(atPath: folder) }
		try "{}".write(toFile: folder + "/lpm.json", atomically: true, encoding: .utf8)
		let watch = try await startWatching(folder)
		defer { watch.cancel() }
		for value in 0..<5 {
			try "\(value)".write(toFile: folder + "/.eslintcache", atomically: true, encoding: .utf8)
		}
		try await quietPeriod()
		#expect(watch.changes == 0)
	}

	@Test("lpm.json that keeps changing is still reported, though it never settles")
	func boundedDelay() async throws {
		let folder = try makeFolder()
		defer { try? FileManager.default.removeItem(atPath: folder) }
		try "{}".write(toFile: folder + "/lpm.json", atomically: true, encoding: .utf8)
		let watch = try await startWatching(folder)
		defer { watch.cancel() }
		var index = 0
		// Each save comes well within the watcher's settling time of the last.
		let reported = try await waitUntil {
			try #"{"n":\#(index)}"#.write(toFile: folder + "/lpm.json", atomically: true, encoding: .utf8)
			index += 1
			return watch.changes >= 1
		}
		#expect(reported, "Saves every few milliseconds are still reported within the maximum delay")
	}

	@Test("a folder that's missing at first, or replaced, is watched once it's there")
	func followsTheFolder() async throws {
		let parent = try makeFolder()
		defer { try? FileManager.default.removeItem(atPath: parent) }
		let folder = parent + "/project"
		let watch = try await startWatching(folder)
		defer { watch.cancel() }
		try FileManager.default.createDirectory(atPath: folder + "-new", withIntermediateDirectories: true)
		try "{}".write(toFile: folder + "-new/lpm.json", atomically: true, encoding: .utf8)
		try FileManager.default.moveItem(atPath: folder + "-new", toPath: folder)
		#expect(try await waitUntil { watch.changes == 1 }, "A folder made after the watch began is watched")

		try FileManager.default.createDirectory(atPath: folder + "-new", withIntermediateDirectories: true)
		try #"{"again":true}"#.write(toFile: folder + "-new/lpm.json", atomically: true, encoding: .utf8)
		#expect(renamex_np(folder + "-new", folder, UInt32(RENAME_SWAP)) == 0)
		#expect(try await waitUntil { watch.changes == 2 }, "A folder replaced at its path is watched")
		try writeInPlace(#"{"edited":true}"#, to: folder + "/lpm.json")
		#expect(try await waitUntil { watch.changes == 3 }, "The replacing folder's lpm.json is the one watched")
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
		for _ in 0..<10 {
			try await startWatching(folder).cancel()
		}
		#expect(try await waitUntil { openDescriptors(at: folder) + openDescriptors(at: outside) == 0 }, "Every watch closes what it opened")

		let watch = try await startWatching(folder)
		defer { watch.cancel() }
		try FileManager.default.removeItem(atPath: folder + "/lpm.json")
		try "{}".write(toFile: folder + "/lpm.json", atomically: true, encoding: .utf8)
		#expect(try await waitUntil { watch.changes == 1 }, "The watch isn't stuck on the pipe")
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
		let watch = try await startWatching(folder)
		defer { watch.cancel() }
		#expect(openDescriptors(at: outside) == 0, "Nothing outside the project is open, so its writes can't be reported")
		#expect(openDescriptors(at: folder) == 1, "Only the project folder is open")
	}

	@Test("imports in one folder share its descriptor: one for each folder and one for each file")
	func sharesFolderDescriptors() async throws {
		let folder = try makeFolder()
		defer { try? FileManager.default.removeItem(atPath: folder) }
		try "{}".write(toFile: folder + "/lpm.json", atomically: false, encoding: .utf8)
		var imports: [String] = []
		for subfolder in ["schemas", "shared"] {
			try FileManager.default.createDirectory(atPath: folder + "/" + subfolder, withIntermediateDirectories: true)
			for index in 0..<20 {
				let path = "\(subfolder)/schema-\(index).json"
				try "{}".write(toFile: folder + "/" + path, atomically: false, encoding: .utf8)
				imports.append(path)
			}
		}
		let watch = try await startWatching(folder, imports: imports)
		let files = imports.count + 1
		#expect(openDescriptors(at: folder) == files + 3, "\(openDescriptors(at: folder)) descriptors for \(files) files in 3 folders")
		watch.cancel()
		#expect(try await waitUntil { openDescriptors(at: folder) == 0 })
	}

	@Test("an import stays watched when a folder above it is moved aside and made again", arguments: [
		(import: "a/b/schema.json", replaced: "a"), (import: "a/b/c/schema.json", replaced: "a/b"),
	])
	func followsReplacedFolders(import path: String, replaced: String) async throws {
		let folder = try makeFolder()
		defer { try? FileManager.default.removeItem(atPath: folder) }
		let file = folder + "/" + path
		let parent = (file as NSString).deletingLastPathComponent
		try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
		try "{}".write(toFile: folder + "/lpm.json", atomically: false, encoding: .utf8)
		try "{}".write(toFile: file, atomically: false, encoding: .utf8)
		let watch = try await startWatching(folder, imports: [path])
		defer { watch.cancel() }
		let aside = folder + "/" + replaced + "-old"
		try FileManager.default.moveItem(atPath: folder + "/" + replaced, toPath: aside)
		#expect(try await waitUntil { watch.changes == 1 }, "The import left with its folder")
		try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
		try #"{"vars":{}}"#.write(toFile: file, atomically: true, encoding: .utf8)
		#expect(try await waitUntil { watch.changes == 2 }, "The import made again at its path")
		try writeInPlace(#"{"vars":{"A":{}}}"#, to: file)
		#expect(try await waitUntil { watch.changes == 3 }, "The new file is the one watched")
		let watched = path.split(separator: "/").count + 2
		#expect(try await waitUntil { openDescriptors(at: aside) == 0 }, "Nothing that moved aside is watched, so its writes can't be reported")
		#expect(openDescriptors(at: folder) == watched, "One for each folder on the import's path and one for each file")
		watch.cancel()
		#expect(try await waitUntil { openDescriptors(at: folder) == 0 })
	}

	@Test("an import whose folder is a link out of the project isn't watched")
	func ignoresLinkedFolders() async throws {
		let folder = try makeFolder()
		let outside = try makeFolder()
		defer {
			try? FileManager.default.removeItem(atPath: folder)
			try? FileManager.default.removeItem(atPath: outside)
		}
		try "{}".write(toFile: folder + "/lpm.json", atomically: false, encoding: .utf8)
		try "{}".write(toFile: outside + "/base.json", atomically: false, encoding: .utf8)
		try FileManager.default.createSymbolicLink(atPath: folder + "/schemas", withDestinationPath: outside)
		let watch = try await startWatching(folder, imports: ["schemas/base.json"])
		defer { watch.cancel() }
		#expect(openDescriptors(at: outside) == 0, "Nothing outside the project is open, so its writes can't be reported")
		#expect(openDescriptors(at: folder) == 2, "Only the project folder and lpm.json are open")
	}

	/// A watch a test began, and the changes reported since.
	private struct Watch {
		let reports: ChangeCounter
		let task: Task<Void, Never>

		/// The reports after the first, which says watching has begun.
		var changes: Int { reports.count - 1 }

		func cancel() { task.cancel() }
	}

	/// Watches `folder`, returning once the watcher has begun.
	private func startWatching(_ folder: String, imports: [String] = []) async throws -> Watch {
		let reports = ChangeCounter()
		let task = Task {
			for await _ in ProjectConfigWatcher.changes(inFolder: folder, imports: imports, settling: .milliseconds(100),
				maximumDelay: .milliseconds(600), retryingEvery: .milliseconds(200)) {
				reports.increment()
			}
		}
		try #require(try await waitUntil { reports.count >= 1 }, "The watcher reports once it has begun")
		return Watch(reports: reports, task: task)
	}

	/// Writes the file without replacing it.
	private func writeInPlace(_ text: String, to path: String) throws {
		let handle = try #require(FileHandle(forWritingAtPath: path))
		handle.write(Data(text.utf8))
		try handle.close()
	}

	private func makeFolder() throws -> String {
		let folder = FileManager.default.temporaryDirectory.appending(path: "config-watch-\(UUID().uuidString)").path
		try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
		return folder
	}

}

@Suite("Settling changes")
struct ChangeSettlingTests {
	private func at(_ milliseconds: UInt64) -> DispatchTime {
		DispatchTime(uptimeNanoseconds: 1_000_000_000 + milliseconds * 1_000_000)
	}

	@Test("changes in quick succession are reported once, when the last has settled")
	func settles() {
		var bursts = ChangeSettling(settling: .milliseconds(100), maximumDelay: .milliseconds(600))
		#expect(bursts.reportTime(forChangeAt: at(0)) == at(100))
		#expect(bursts.reportTime(forChangeAt: at(50)) == at(150), "A change before the report moves it")
		#expect(bursts.reportTime(forChangeAt: at(149)) == at(249))
		bursts.reported()
		#expect(bursts.reportTime(forChangeAt: at(400)) == at(500), "A change after the report begins another burst")
	}

	@Test("changes that never settle are reported once they've gone on for the maximum delay")
	func boundsTheDelay() {
		var bursts = ChangeSettling(settling: .milliseconds(100), maximumDelay: .milliseconds(600))
		var due: DispatchTime?
		for time in stride(from: UInt64(0), through: 580, by: 20) {
			due = bursts.reportTime(forChangeAt: at(time))
		}
		#expect(due == at(600), "A change every 20 ms is reported 600 ms after the first")
		bursts.reported()
		#expect(bursts.reportTime(forChangeAt: at(600)) == at(700), "The next burst has its own maximum delay")
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

@Suite("Process limits")
struct ProcessLimitTests {
	@Test("the open-file limit rises to what the app asks for, up to the hard limit, and a higher one stays")
	func raisesOpenFiles() {
		var limit = rlimit()
		getrlimit(RLIMIT_NOFILE, &limit)
		let wanted = min(limit.rlim_cur + 64, limit.rlim_max)
		#expect(ProcessLimits.raiseOpenFiles(to: wanted) == wanted)
		getrlimit(RLIMIT_NOFILE, &limit)
		#expect(limit.rlim_cur == wanted)
		#expect(ProcessLimits.raiseOpenFiles(to: wanted - 32) == wanted, "A lower request leaves the limit as it is")
	}
}
