import Darwin
import Foundation
import Testing

@testable import LPMVault

@Suite("Bounded dotenv imports")
struct EnvFileImportTests {
	private func temporaryFile(_ data: Data, name: String = ".env") throws -> URL {
		let directory = FileManager.default.temporaryDirectory
			.appendingPathComponent(UUID().uuidString, isDirectory: true)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		let url = directory.appendingPathComponent(name)
		try data.write(to: url)
		return url
	}

	@Test("reader accepts the exact Rust limit and rejects one byte more")
	func boundedReaderLimit() throws {
		let limit = 16 * 1024 * 1024
		let exactURL = try temporaryFile(Data(repeating: 65, count: limit), name: "exact.env")
		let oversizedURL = try temporaryFile(Data(repeating: 65, count: limit + 1), name: "large.env")

		#expect(try BoundedEnvFileReader.read(at: exactURL, maximumBytes: limit).count == limit)
		#expect(throws: EnvFileImportError.tooLarge(limit: limit)) {
			try BoundedEnvFileReader.read(at: oversizedURL, maximumBytes: limit)
		}
	}

	@Test("reader rejects non-regular files and invalid UTF-8")
	func invalidFileInputs() async throws {
		let directory = FileManager.default.temporaryDirectory
			.appendingPathComponent(UUID().uuidString, isDirectory: true)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		#expect(throws: EnvFileImportError.notRegularFile) {
			try BoundedEnvFileReader.read(at: directory, maximumBytes: 128)
		}
		#expect(throws: EnvFileImportError.fileNotFound) {
			try BoundedEnvFileReader.read(
				at: directory.appendingPathComponent("missing.env"),
				maximumBytes: 128
			)
		}

		let invalidURL = try temporaryFile(Data([0xFF, 0xFE]))
		let service = EnvFileImportService()
		do {
			_ = try await service.load(at: invalidURL)
			Issue.record("Invalid UTF-8 was accepted")
		} catch let error as EnvFileImportError {
			#expect(error == .invalidUTF8)
		}
	}

	@Test("FIFOs are rejected without occupying the import pool")
	func fifoDoesNotBlockImportPool() async throws {
		let directory = FileManager.default.temporaryDirectory
			.appendingPathComponent(UUID().uuidString, isDirectory: true)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: directory) }

		let fifoURLs = (0..<2).map { directory.appendingPathComponent("fifo-\($0)") }
		for fifoURL in fifoURLs {
			let status = fifoURL.withUnsafeFileSystemRepresentation { path in
				guard let path else { return Int32(-1) }
				return Darwin.mkfifo(path, 0o600)
			}
			#expect(status == 0)
		}

		let regularURL = directory.appendingPathComponent("regular.env")
		try Data("KEY=value".utf8).write(to: regularURL)
		let service = EnvFileImportService(maximumConcurrentImports: 2)
		let fifoTasks = fifoURLs.map { fifoURL in
			Task { () -> EnvFileImportError? in
				do {
					_ = try await service.load(at: fifoURL)
					return nil
				} catch let error as EnvFileImportError {
					return error
				} catch {
					return .readFailed
				}
			}
		}

		for _ in 0..<100 { await Task.yield() }
		let imported = try await service.load(at: regularURL)

		#expect(imported.secrets == ["KEY": "value"])
		for task in fifoTasks {
			#expect(await task.value == .notRegularFile)
		}
	}

	@Test("authoritative read rejects a file that grows after metadata inspection")
	func fileGrowthIsBounded() throws {
		let url = try temporaryFile(Data("A=1".utf8), name: "growing.env")
		#expect(throws: EnvFileImportError.tooLarge(limit: 4)) {
			try BoundedEnvFileReader.read(at: url, maximumBytes: 4) {
				let handle = try FileHandle(forWritingTo: url)
				try handle.seekToEnd()
				try handle.write(contentsOf: Data("EXTRA".utf8))
				try handle.close()
			}
		}
	}

	@Test("parser matches Rust vault dotenv behavior")
	func parserContract() throws {
		let parsed = try EnvFileCodec.parse(
			"""
			# comment
			export HOST = localhost
			URL=postgres://host/db?ssl=true
			EMPTY=
			SINGLE='literal \\n value' ignored
			DOUBLE="line one
			line two \\"quoted\\" \\\\ path\\nend" ignored
			HASH=value # preserved
			DUP=old
			DUP=new
			"""
		)

		#expect(parsed["HOST"] == "localhost")
		#expect(parsed["URL"] == "postgres://host/db?ssl=true")
		#expect(parsed["EMPTY"] == "")
		#expect(parsed["SINGLE"] == "literal \\n value")
		#expect(parsed["DOUBLE"] == "line one\nline two \"quoted\" \\ path\nend")
		#expect(parsed["HASH"] == "value # preserved")
		#expect(parsed["DUP"] == "new")
	}

	@Test("parser preserves multiline literals, unterminated quotes, and unknown escapes")
	func quotedEdgeCases() throws {
		let parsed = try EnvFileCodec.parse(
			"SINGLE='first\nsecond' ignored\nUNKNOWN=\"keep\\q\"\nEOF=\"unterminated\nvalue"
		)

		#expect(parsed["SINGLE"] == "first\nsecond")
		#expect(parsed["UNKNOWN"] == "keep\\q")
		#expect(parsed["EOF"] == "unterminated\nvalue")
	}

	@Test("invalid keys reject the whole parse")
	func invalidKeyIsAtomic() {
		#expect(throws: EnvFileImportError.invalidVariableName(line: 2)) {
			try EnvFileCodec.parse("VALID=one\nBAD-NAME=two\nANOTHER=three")
		}
		#expect(throws: EnvFileImportError.invalidVariableName(line: 1)) {
			try EnvFileCodec.parse("\u{FEFF}FIRST=value")
		}
	}

	@Test("case-only key collisions reject the whole parse")
	func caseOnlyCollisionIsAtomic() {
		#expect(throws: EnvFileImportError.caseInsensitiveCollision(
			line: 2,
			existingKey: "HEY",
			incomingKey: "Hey"
		)) {
			try EnvFileCodec.parse("HEY=upper\nHey=mixed")
		}
	}

	@Test("maximum-size unique key sets parse without collision scan amplification")
	func maximumAssignmentSetParses() throws {
		let assignmentCount = 16_384
		let content = (0..<assignmentCount)
			.map { "K\(String($0, radix: 36).uppercased())=" }
			.joined(separator: "\n")
		let parsed = try EnvFileCodec.parse(content)

		#expect(parsed.count == assignmentCount)
		#expect(parsed["KCN3"] == "")
	}

	@Test("assignment and parsed-output amplification are bounded")
	func parserBounds() {
		let assignments = EnvFileImportLimits(
			maximumInputBytes: 128,
			maximumAssignments: 1,
			maximumParsedBytes: 128
		)
		#expect(throws: EnvFileImportError.tooManyAssignments(limit: 1)) {
			try EnvFileCodec.parse("A=1\nB=2", limits: assignments)
		}

		let output = EnvFileImportLimits(
			maximumInputBytes: 128,
			maximumAssignments: 10,
			maximumParsedBytes: 4
		)
		#expect(throws: EnvFileImportError.parsedDataTooLarge(limit: 4)) {
			try EnvFileCodec.parse("KEY=value", limits: output)
		}
	}

	@Test("Swift export round-trips Rust-compatible escapes")
	func exportRoundTrip() throws {
		let source = [
			"PLAIN": "value",
			"ESCAPED": "literal \\n and \\\\ path with \\\"quote\\\"",
		]
		#expect(try EnvFileCodec.parse(EnvFileCodec.format(source)) == source)
	}

	@Test("a failed replacement preview clears previously imported secrets")
	func failedReplacementPreviewClearsSecrets() {
		var secrets = EnvFilePreviewPresentation.replacementSecrets(
			for: .success(ImportedEnvFile(secrets: ["OLD": "secret"]))
		)
		#expect(secrets == ["OLD": "secret"])

		secrets = EnvFilePreviewPresentation.replacementSecrets(for: .failure(.invalidUTF8))
		#expect(secrets.isEmpty)
	}

	@Test("global admission never exceeds two workers")
	func concurrencyIsBounded() async {
		let tracker = ImportWorkerTracker()
		let service = EnvFileImportService(maximumConcurrentImports: 2) { _, _ in
			tracker.enter()
			defer { tracker.leave() }
			tracker.waitForRelease()
			return ImportedEnvFile(secrets: ["KEY": "value"])
		}
		let tasks = (0..<12).map { index in
			Task { try? await service.load(at: URL(fileURLWithPath: "/tmp/\(index)")) }
		}

		await tracker.waitUntilStarted(2)
		#expect(tracker.maximumActive == 2)
		tracker.release(12)
		for task in tasks { _ = await task.value }

		#expect(tracker.maximumActive == 2)
		#expect(tracker.started == 12)
	}

	@Test("cancelled queued imports are never admitted")
	func queuedCancellation() async {
		let tracker = ImportWorkerTracker()
		let service = EnvFileImportService(maximumConcurrentImports: 2) { url, _ in
			tracker.enter(index: Int(url.lastPathComponent) ?? -1)
			defer { tracker.leave() }
			tracker.waitForRelease()
			return ImportedEnvFile(secrets: ["KEY": "value"])
		}
		let tasks = (0..<20).map { index in
			Task { try? await service.load(at: URL(fileURLWithPath: "/tmp/\(index)")) }
		}

		await tracker.waitUntilStarted(2)
		let activeIndexes = tracker.startedIndexes
		for (index, task) in tasks.enumerated() where !activeIndexes.contains(index) { task.cancel() }
		for _ in 0..<100 { await Task.yield() }
		tracker.release(2)
		for task in tasks { _ = await task.value }

		#expect(tracker.started == 2)
		#expect(tracker.maximumActive == 2)
	}

	@Test("worker executes away from the main thread")
	@MainActor
	func workerIsBackground() async throws {
		let tracker = ImportWorkerTracker()
		let service = EnvFileImportService(maximumConcurrentImports: 1) { _, _ in
			tracker.recordWorkerThread()
			return ImportedEnvFile(secrets: ["KEY": "value"])
		}

		_ = try await service.load(at: URL(fileURLWithPath: "/tmp/background"))
		#expect(!tracker.workerUsedMainThread)
	}
}

private final class ImportWorkerTracker: @unchecked Sendable {
	private let lock = NSLock()
	private let gate = DispatchSemaphore(value: 0)
	private var active = 0
	private var _started = 0
	private var _maximumActive = 0
	private var _workerUsedMainThread = false
	private var _startedIndexes: Set<Int> = []

	var started: Int { lock.withLock { _started } }
	var maximumActive: Int { lock.withLock { _maximumActive } }
	var workerUsedMainThread: Bool { lock.withLock { _workerUsedMainThread } }
	var startedIndexes: Set<Int> { lock.withLock { _startedIndexes } }

	func enter() {
		lock.withLock {
			active += 1
			_started += 1
			_maximumActive = max(_maximumActive, active)
		}
	}

	func enter(index: Int) {
		lock.withLock {
			active += 1
			_started += 1
			_startedIndexes.insert(index)
			_maximumActive = max(_maximumActive, active)
		}
	}

	func leave() {
		lock.withLock { active -= 1 }
	}

	func waitForRelease() {
		gate.wait()
	}

	func release(_ count: Int) {
		for _ in 0..<count { gate.signal() }
	}

	func waitUntilStarted(_ expected: Int) async {
		while started < expected { await Task.yield() }
	}

	func recordWorkerThread() {
		lock.withLock { _workerUsedMainThread = Thread.isMainThread }
	}
}
