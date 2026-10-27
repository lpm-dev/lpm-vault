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

		let invalidCommentURL = try temporaryFile(
			Data([0x23, 0x20, 0xFF, 0x0A]),
			name: "invalid-comment.env"
		)
		do {
			_ = try await service.load(at: invalidCommentURL)
			Issue.record("Invalid UTF-8 hidden in a comment was accepted")
		} catch let error as EnvFileImportError {
			#expect(error == .invalidUTF8)
		}
	}

	@Test("streaming worker preserves physical line numbers and CRLF multiline values")
	func streamingWorkerParserCompatibility() async throws {
		let compatible = Data(
			"# comment\r\nDOUBLE=\"first\r\nsecond\"\r\nPLAIN=value\r\n".utf8
		)
		let compatibleURL = try temporaryFile(compatible, name: "compatible.env")
		let service = EnvFileImportService()
		let imported = try await service.load(at: compatibleURL)
		#expect(imported.secrets["DOUBLE"] == "first\nsecond")
		#expect(imported.secrets["PLAIN"] == "value")

		let invalidURL = try temporaryFile(
			Data("# comment\n\nBAD-NAME=value\n".utf8),
			name: "invalid-line.env"
		)
		do {
			_ = try await service.load(at: invalidURL)
			Issue.record("The streaming worker accepted an invalid key")
		} catch let error as EnvFileImportError {
			#expect(error == .invalidVariableName(line: 3))
		}

		let collisionURL = try temporaryFile(
			Data("# comment\nUPPER=one\nUpper=two\n".utf8),
			name: "collision-line.env"
		)
		do {
			_ = try await service.load(at: collisionURL)
			Issue.record("The streaming worker accepted a case-only collision")
		} catch let error as EnvFileImportError {
			#expect(error == .caseInsensitiveCollision(
				line: 3,
				existingKey: "UPPER",
				incomingKey: "Upper"
			))
		}
	}

	@Test("streaming worker preserves comment blank and indented quoted continuations")
	func streamingWorkerPreservesQuotedContinuationLines() async throws {
		let content = Data(
			"KEY=\"first\n#\n\n  indented\nlast\"\nNEXT=value\n".utf8
		)
		let url = try temporaryFile(content, name: "multiline-continuations.env")

		let imported = try await EnvFileImportService().load(at: url)

		#expect(imported.secrets["KEY"] == "first\n#\n\n  indented\nlast")
		#expect(imported.secrets["NEXT"] == "value")
	}

	@Test("streaming worker enforces the exact input limit")
	func streamingWorkerInputLimit() async throws {
		let content = Data("KEY=value\n#padding".utf8)
		let limits = EnvFileImportLimits(
			maximumInputBytes: content.count,
			maximumAssignments: 10,
			maximumParsedBytes: 128
		)
		let service = EnvFileImportService(limits: limits)
		let exactURL = try temporaryFile(content, name: "stream-exact.env")
		let oversizedURL = try temporaryFile(content + Data("x".utf8), name: "stream-large.env")

		#expect(try await service.load(at: exactURL).secrets == ["KEY": "value"])
		do {
			_ = try await service.load(at: oversizedURL)
			Issue.record("The streaming worker accepted a file above its exact limit")
		} catch let error as EnvFileImportError {
			#expect(error == .tooLarge(limit: content.count))
		}
	}

	@Test("streaming oversized assignments report the configured parsed-data limit")
	func streamingWorkerReportsParsedDataLimit() async throws {
		let limits = EnvFileImportLimits(
			maximumInputBytes: 4_096,
			maximumAssignments: 10,
			maximumParsedBytes: 4
		)
		let url = try temporaryFile(
			Data(("KEY=" + String(repeating: "x", count: 2_000)).utf8),
			name: "stream-parsed-limit.env"
		)

		do {
			_ = try await EnvFileImportService(limits: limits).load(at: url)
			Issue.record("The streaming worker accepted an oversized parsed assignment")
		} catch let error as EnvFileImportError {
			#expect(error == .parsedDataTooLarge(limit: limits.maximumParsedBytes))
		}
	}

	@Test("streaming worker rejects an oversized quoted continuation")
	func streamingWorkerRejectsOversizedQuotedContinuation() async throws {
		let limits = EnvFileImportLimits(
			maximumInputBytes: 4_096,
			maximumAssignments: 10,
			maximumParsedBytes: 100
		)
		let content = "KEY=\"a\n" + String(repeating: "x", count: 1_300) + "\nb\"\n"
		let url = try temporaryFile(
			Data(content.utf8),
			name: "oversized-quoted-continuation.env"
		)

		do {
			_ = try await EnvFileImportService(limits: limits).load(at: url)
			Issue.record("The streaming worker discarded an oversized quoted continuation.")
		} catch let error as EnvFileImportError {
			#expect(error == .parsedDataTooLarge(limit: limits.maximumParsedBytes))
		}
	}

	@Test("oversized quoted continuations keep the parsed-size error after a late equals sign")
	func oversizedQuotedContinuationWithLateEquals() async throws {
		let limits = EnvFileImportLimits(
			maximumInputBytes: 4_096,
			maximumAssignments: 10,
			maximumParsedBytes: 100
		)
		let content = "KEY=\"a\n" + String(repeating: "x", count: 1_300) + "=tail\nb\"\n"
		let url = try temporaryFile(
			Data(content.utf8),
			name: "oversized-quoted-late-equals.env"
		)

		do {
			_ = try await EnvFileImportService(limits: limits).load(at: url)
			Issue.record("The streaming worker accepted an oversized quoted continuation.")
		} catch let error as EnvFileImportError {
			#expect(error == .parsedDataTooLarge(limit: limits.maximumParsedBytes))
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
			"MULTILINE": "first\nINJECTED=second\rthird",
			"CRLF": "before\r\nafter",
			"HASH": "value # not a comment",
		]
		let formatted = EnvFileCodec.format(source)
		let formattedData = EnvFileCodec.formatData(source)
		#expect(formatted.components(separatedBy: "\n").count == source.count + 1)
		#expect(!formatted.contains("\nINJECTED=second"))
		#expect(formatted.contains("\\nINJECTED=second\\rthird"))
		#expect(formatted.contains("CRLF=\"before\\r\\nafter\""))
		#expect(try EnvFileCodec.parse(formatted) == source)
		#expect(formattedData == Data(formatted.utf8))
	}

	private func read(_ input: EnvImportInput, with service: EnvFileImportService) async -> Result<ImportedEnvFile, EnvFileImportError> {
		do { return .success(try await service.load(input)) }
		catch let error as EnvFileImportError { return .failure(error) }
		catch { return .failure(.readFailed) }
	}

	@Test("pasted text reads as the same file does: values, line numbers, errors, skipped lines and size")
	func pastedTextMatchesFile() async throws {
		let service = EnvFileImportService()
		let samples = [
			"# comment\r\nDOUBLE=\"first\r\nsecond\"\r\nPLAIN=value\r\n",
			"KEY=\"first\n#\n\n  indented\nlast\"\nNEXT=value\n",
			"export TOKEN='single quoted'\nEMPTY=\nnot an assignment\n=no key\n\u{00A0}# a comment after a no-break space\nLAST=1",
			"# comment\n\nBAD-NAME=value\n",
			"# comment\nUPPER=one\nUpper=two\n",
			"# only comments\n\n",
			"KEY=caf\u{00E9} \u{1F510}\n",
		]
		for (index, sample) in samples.enumerated() {
			let file = try temporaryFile(Data(sample.utf8), name: "sample-\(index).env")
			let fromFile = await read(.file(file), with: service)
			let fromText = await read(.text(sample), with: service)
			#expect(fromText == fromFile, "Sample \(index) reads the same pasted as from a file")
		}
		let imported = try await service.load(.text(samples[2]))
		#expect(imported.secrets == ["TOKEN": "single quoted", "EMPTY": "", "LAST": "1"])
		#expect(imported.skippedLineCount == 3 && imported.firstSkippedLine == 3,
			"A # after a no-break space starts no comment: only spaces and tabs are blanks, as in the LPM CLI, so the line is skipped and said")
		#expect(imported.byteCount == samples[2].utf8.count)
		#expect(try await service.load(.text(samples[6])).byteCount == samples[6].utf8.count, "Size counts bytes, not characters")
	}

	@Test("a line too long to keep that isn't an assignment is skipped and said, not dropped quietly")
	func longNonAssignmentIsSkipped() async throws {
		let limits = EnvFileImportLimits(maximumInputBytes: 4_096, maximumAssignments: 10, maximumParsedBytes: 100)
		let content = "A=1\n" + String(repeating: "x", count: 1_300) + "\nB=2\n"
		let imported = try await EnvFileImportService(limits: limits).load(.text(content))
		#expect(imported.secrets == ["A": "1", "B": "2"])
		#expect(imported.skippedLineCount == 1 && imported.firstSkippedLine == 2)
		#expect(imported.skippedLinesDescription == "Line 2 isn't KEY=value, so it's left out.")
		let several = try await EnvFileImportService(limits: limits).load(.text("A=1\nfirst\nsecond\nthird"))
		#expect(several.skippedLinesDescription == "3 lines aren't KEY=value, so they're left out, starting at line 2.")
		#expect(try await EnvFileImportService(limits: limits).load(.text("A=1")).skippedLinesDescription == nil)
	}

	@Test("pasted text keeps to the file limits, and its problems name it as pasted text")
	func pastedTextLimits() async throws {
		let content = "KEY=value\n#padding"
		let limits = EnvFileImportLimits(maximumInputBytes: content.utf8.count, maximumAssignments: 1, maximumParsedBytes: 64)
		let service = EnvFileImportService(limits: limits)
		#expect(try await service.load(.text(content)).secrets == ["KEY": "value"])
		await #expect(throws: EnvFileImportError.tooLarge(limit: limits.maximumInputBytes)) {
			try await service.load(.text(content + "x"))
		}
		await #expect(throws: EnvFileImportError.tooManyAssignments(limit: 1)) {
			try await service.load(.text("A=1\nB=2"))
		}
		await #expect(throws: EnvFileImportError.noValidSecrets) {
			try await service.load(.text("# nothing here"))
		}
		#expect(EnvFileImportError.tooLarge(limit: 1_024).description(for: .pastedText) == "The pasted text exceeds the 1 KB limit.")
		#expect(EnvFileImportError.noValidSecrets.description(for: .pastedText) == "The pasted text has no KEY=value lines.")
		#expect(EnvFileImportError.noValidSecrets.description(for: .file(URL(fileURLWithPath: "/tmp/.env"))) == "The .env file does not contain any valid secrets.")
		#expect(EnvFileImportError.tooManyAssignments(limit: 2).description(for: .pastedText) == "The pasted text contains more than 2 assignments.")
		#expect(EnvFileImportError.parsedDataTooLarge(limit: 1_024).description(for: .pastedText) == "The pasted variables exceed the 1 KB import limit.")
	}

	@Test("text as large as the limit allows reads in one pass")
	func largestPastedText() async throws {
		let limit = EnvFileImportLimits.standard.maximumInputBytes
		let assignment = "KEY=value\n"
		let content = assignment + String(repeating: "#", count: limit - assignment.utf8.count)
		let imported = try await EnvFileImportService().load(.text(content))
		#expect(imported.secrets == ["KEY": "value"] && imported.byteCount == limit)
	}

	@Test("a failed or unfinished read never imports what an earlier one read")
	func failedReadImportsNothing() {
		let file = URL(fileURLWithPath: "/tmp/.env.staging")
		var state = EnvImportSourceState(file: file)
		#expect(state.isReading && state.imported == nil)
		state.finishReading(file, revision: state.fileRevision, .success(ImportedEnvFile(secrets: ["OLD": "secret"])))
		#expect(state.imported?.secrets == ["OLD": "secret"] && state.source == .file(file))

		state.choose(file)
		#expect(state.imported == nil, "Choosing the file again reads it again")
		state.finishReading(file, revision: state.fileRevision, .failure(.invalidUTF8))
		#expect(state.imported == nil && state.problem == "The .env file is not valid UTF-8.")

		state.mode = .text
		#expect(state.isEmpty && state.source == nil && state.imported == nil, "Only the shown mode's input is imported")
		state.setText("A=1")
		let first = state.textRevision
		state.finishReadingText(revision: first, .success(ImportedEnvFile(secrets: ["A": "1"])))
		#expect(state.imported?.secrets == ["A": "1"] && state.source == .pastedText)
		state.setText("A=1\nB=2")
		#expect(state.imported == nil, "Text that's changed since its read imports nothing until it's read again")
		#expect((try? state.shownRead?.get())?.secrets == ["A": "1"], "The last read stays shown meanwhile")
		state.finishReadingText(revision: first, .success(ImportedEnvFile(secrets: ["STALE": "x"])))
		#expect(state.imported == nil, "A read of older text never counts")
		state.finishReadingText(revision: state.textRevision, .failure(.cancelled))
		#expect(state.imported == nil && state.isReading)
		state.finishReadingText(revision: state.textRevision, .failure(.noValidSecrets))
		#expect(state.imported == nil && state.problem == "The pasted text has no KEY=value lines.")
		state.setText("  \n\t")
		#expect(state.isEmpty && !state.isReading && state.problem == nil, "Blank text holds nothing to read")
	}

	@Test("a drop holds one file, not several, a folder or a link")
	func dropHoldsOneFile() throws {
		let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: folder) }
		let file = try temporaryFile(Data("A=1".utf8), name: ".env.preview")
		#expect(EnvImportDrop.file(in: [file]) == .success(file))
		#expect(EnvImportDrop.file(in: [file, file]) == .failure(.several))
		#expect(EnvImportDrop.file(in: [folder]) == .failure(.folder))
		#expect(EnvImportDrop.file(in: [try #require(URL(string: "https://example.com/.env"))]) == .failure(.notAFile))
		#expect(EnvImportDrop.file(in: []) == .failure(.notAFile))

		var state = EnvImportSourceState(file: file)
		state.mode = .text
		let droppedFolder = state.drop([folder])
		#expect(!droppedFolder)
		#expect(state.mode == .file && state.file == file && state.problem == "Drop a file, not a folder.",
			"A drop that's turned down shows why, and keeps the chosen file")
		let droppedFile = state.drop([file])
		#expect(droppedFile && state.problem == nil)
	}

	@Test("a new environment's name follows the file it imports, none comes from pasted text, and a typed name stays")
	func environmentNameFollowsSource() {
		let local = URL(filePath: "/tmp/.env.local"), preview = URL(filePath: "/tmp/.env.preview")
		var draft = VaultEnvironmentNameDraft()
		draft.follow(.file(local))
		#expect(draft.name == "local")
		draft.follow(.file(preview))
		#expect(draft.name == "preview", "A suggestion that wasn't typed over follows the next file")
		draft.follow(.file(URL(filePath: "/tmp/.env")))
		#expect(draft.name == "default")
		draft.follow(.pastedText)
		#expect(draft.name.isEmpty, "Pasted text has no name to suggest")
		draft.follow(.file(local))
		#expect(draft.name == "local")

		draft.name = "qa"
		draft.follow(.file(preview))
		draft.follow(.pastedText)
		draft.follow(nil)
		#expect(draft.name == "qa", "A typed name stays")
		draft.name = " "
		draft.follow(.file(local))
		#expect(draft.name == "local", "A blank name is no name")
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
		let service = EnvFileImportService(maximumConcurrentImports: 2) { input, _ in
			guard case .file(let url) = input else { throw EnvFileImportError.readFailed }
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

	@Test("the worker reads the file off the cooperative pool, which blocking work must never hold")
	func workerIsOffCooperativePool() async throws {
		let pool = PoolObservation()
		let service = EnvFileImportService(maximumConcurrentImports: 1) { _, _ in
			pool.record()
			return ImportedEnvFile(secrets: ["KEY": "value"])
		}
		_ = try await service.load(at: URL(fileURLWithPath: "/tmp/off-pool"))
		#expect(pool.stayedOffPool)
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
