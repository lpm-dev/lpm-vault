import Darwin
import Foundation

struct ImportedEnvFile: Sendable, Equatable {
	let secrets: [String: String]
	/// The bytes read: the file's size, or the pasted text's length in UTF-8.
	var byteCount = 0
	/// Lines holding something other than an assignment, a comment or blank
	/// space, which an import leaves out, and the first of them.
	var skippedLineCount = 0
	var firstSkippedLine: Int?

	var count: Int { secrets.count }

	static func == (lhs: Self, rhs: Self) -> Bool {
		lhs.secrets.isExactly(rhs.secrets) && lhs.byteCount == rhs.byteCount
			&& lhs.skippedLineCount == rhs.skippedLineCount && lhs.firstSkippedLine == rhs.firstSkippedLine
	}
}

/// What an import reads its variables from.
enum EnvImportInput: Sendable {
	case file(URL)
	case text(String)
}

/// Where imported variables came from, as a review names it.
enum EnvImportSource: Sendable, Equatable {
	case file(URL)
	case pastedText

	var name: String {
		switch self {
		case .file(let url): url.lastPathComponent
		case .pastedText: "Pasted text"
		}
	}
}

struct EnvFileImportLimits: Sendable {
	static let standard = EnvFileImportLimits(
		maximumInputBytes: 16 * 1024 * 1024,
		maximumAssignments: 16_384,
		maximumParsedBytes: VaultConstants.maxVaultSizeWarning
	)

	let maximumInputBytes: Int
	let maximumAssignments: Int
	let maximumParsedBytes: Int
}

enum EnvFileImportError: LocalizedError, Sendable, Equatable {
	case cancelled
	case fileNotFound
	case notRegularFile
	case tooLarge(limit: Int)
	case invalidUTF8
	case readFailed
	case invalidVariableName(line: Int)
	case caseInsensitiveCollision(line: Int, existingKey: String, incomingKey: String)
	case tooManyAssignments(limit: Int)
	case parsedDataTooLarge(limit: Int)
	case noValidSecrets
	case vaultLocked
	case targetUnavailable
	case reviewChanged
	/// A new environment's name was taken first, as by the LPM CLI.
	case environmentExists(String)
	case caseInsensitiveCollisionWithExisting
	case persistence(String)

	var errorDescription: String? { description(pasted: false) }

	/// What went wrong, naming pasted text as such rather than as a file.
	func description(for source: EnvImportSource) -> String {
		description(pasted: source == .pastedText)
	}

	private func description(pasted: Bool) -> String {
		let subject = pasted ? "The pasted text" : "The .env file"
		return switch self {
		case .cancelled:
			"Import cancelled."
		case .fileNotFound:
			"The selected .env file no longer exists."
		case .notRegularFile:
			"Select a regular .env file."
		case .tooLarge(let limit):
			"\(subject) exceeds the \(Self.byteCount(limit)) limit."
		case .invalidUTF8:
			"\(subject) is not valid UTF-8."
		case .readFailed:
			"The .env file could not be read."
		case .invalidVariableName(let line):
			"Line \(line) has a variable name that does not match [A-Za-z_][A-Za-z0-9_]*."
		case .caseInsensitiveCollision(let line, let existingKey, let incomingKey):
			"Line \(line) defines \(incomingKey), which differs from \(existingKey) only by letter case. Rename one key for Windows compatibility."
		case .tooManyAssignments(let limit):
			"\(subject) contains more than \(limit) assignments."
		case .parsedDataTooLarge(let limit):
			pasted
				? "The pasted variables exceed the \(Self.byteCount(limit)) import limit."
				: "The parsed .env data exceeds the \(Self.byteCount(limit)) import limit."
		case .noValidSecrets:
			pasted ? "The pasted text has no KEY=value lines." : "The .env file does not contain any valid secrets."
		case .vaultLocked:
			"Unlock LPM Vault before importing secrets."
		case .targetUnavailable:
			"The target env project or environment changed before the import completed."
		case .reviewChanged:
			"The environment changed after this review. Review it again before importing."
		case .environmentExists(let environment):
			"\(VaultProject.displayName(for: environment)) was created meanwhile, as by the LPM CLI. Choose another name for this one."
		case .caseInsensitiveCollisionWithExisting:
			"An imported key differs only by letter case from an existing key. Rename one key for Windows compatibility."
		case .persistence(let message):
			"Import failed. \(message)"
		}
	}

	private static func byteCount(_ count: Int) -> String {
		ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .binary)
	}
}

protocol EnvFileImportServiceProtocol: Sendable {
	func load(_ input: EnvImportInput) async throws -> ImportedEnvFile
}

extension EnvFileImportServiceProtocol {
	func load(at url: URL) async throws -> ImportedEnvFile {
		try await load(.file(url))
	}
}

/// Bounds all local dotenv work behind one shared admission pool. File reads
/// and parsing run off the cooperative pool; callers only publish the result.
final class EnvFileImportService: EnvFileImportServiceProtocol, @unchecked Sendable {
	typealias Worker = @Sendable (EnvImportInput, EnvFileImportLimits) throws -> ImportedEnvFile
	static let shared = EnvFileImportService()

	private let limits: EnvFileImportLimits
	private let admission: EnvFileImportAdmission
	private let worker: Worker

	init(
		maximumConcurrentImports: Int = 2,
		limits: EnvFileImportLimits = .standard,
		worker: @escaping Worker = EnvFileImportWorker.load
	) {
		self.limits = limits
		self.admission = EnvFileImportAdmission(limit: maximumConcurrentImports)
		self.worker = worker
	}

	func load(_ input: EnvImportInput) async throws -> ImportedEnvFile {
		do {
			try await admission.acquire()
		} catch is CancellationError {
			throw EnvFileImportError.cancelled
		}

		do {
			let imported = try await BlockingWork.run { [limits, worker] in
				try Task.checkCancellation()
				return try worker(input, limits)
			}
			await admission.release()
			return imported
		} catch is CancellationError {
			await admission.release()
			throw EnvFileImportError.cancelled
		} catch {
			await admission.release()
			throw error
		}
	}
}

private actor EnvFileImportAdmission {
	private final class Waiter {
		let id: UUID
		let continuation: CheckedContinuation<Bool, Never>
		weak var previous: Waiter?
		var next: Waiter?

		init(id: UUID, continuation: CheckedContinuation<Bool, Never>) {
			self.id = id
			self.continuation = continuation
		}
	}

	private let limit: Int
	private var active = 0
	private var firstWaiter: Waiter?
	private var lastWaiter: Waiter?
	private var waitersByID: [UUID: Waiter] = [:]

	init(limit: Int) {
		self.limit = max(1, limit)
	}

	func acquire() async throws {
		try Task.checkCancellation()
		if active < limit {
			active += 1
			return
		}

		let id = UUID()
		let admitted = await withTaskCancellationHandler {
			await withCheckedContinuation { continuation in
				if Task.isCancelled {
					continuation.resume(returning: false)
				} else {
					appendWaiter(Waiter(id: id, continuation: continuation))
				}
			}
		} onCancel: {
			Task { await self.cancelWaiter(id: id) }
		}

		guard admitted else { throw CancellationError() }
		if Task.isCancelled {
			release()
			throw CancellationError()
		}
	}

	func release() {
		if let waiter = popFirstWaiter() {
			waiter.continuation.resume(returning: true)
			return
		}
		active = max(0, active - 1)
	}

	private func cancelWaiter(id: UUID) {
		guard let waiter = waitersByID[id] else { return }
		removeWaiter(waiter)
		waiter.continuation.resume(returning: false)
	}

	private func appendWaiter(_ waiter: Waiter) {
		waiter.previous = lastWaiter
		lastWaiter?.next = waiter
		if firstWaiter == nil { firstWaiter = waiter }
		lastWaiter = waiter
		waitersByID[waiter.id] = waiter
	}

	private func popFirstWaiter() -> Waiter? {
		guard let waiter = firstWaiter else { return nil }
		removeWaiter(waiter)
		return waiter
	}

	private func removeWaiter(_ waiter: Waiter) {
		let previous = waiter.previous
		let next = waiter.next
		previous?.next = next
		next?.previous = previous
		if firstWaiter === waiter { firstWaiter = next }
		if lastWaiter === waiter { lastWaiter = previous }
		waiter.previous = nil
		waiter.next = nil
		waitersByID.removeValue(forKey: waiter.id)
	}
}

enum EnvFileImportWorker {
	static func load(_ input: EnvImportInput, limits: EnvFileImportLimits) throws -> ImportedEnvFile {
		var parser = StreamingEnvFileParser(limits: limits)
		let maximumRetainedLineBytes = min(limits.maximumInputBytes, limits.maximumParsedBytes * 2 + 1_024)
		let byteCount = switch input {
		case .file(let url):
			try BoundedEnvFileReader.forEachLine(
				at: url,
				maximumBytes: limits.maximumInputBytes,
				parsedDataLimit: limits.maximumParsedBytes,
				maximumRetainedLineBytes: maximumRetainedLineBytes,
				preservePhysicalLine: { parser.hasPendingQuotedAssignment },
				skipped: { parser.skip(line: $0) }
			) { line, lineNumber in
				try parser.consume(line, lineNumber: lineNumber)
			}
		case .text(let text):
			try BoundedEnvFileReader.forEachLine(
				in: text,
				maximumBytes: limits.maximumInputBytes,
				parsedDataLimit: limits.maximumParsedBytes,
				maximumRetainedLineBytes: maximumRetainedLineBytes,
				preservePhysicalLine: { parser.hasPendingQuotedAssignment },
				skipped: { parser.skip(line: $0) }
			) { line, lineNumber in
				try parser.consume(line, lineNumber: lineNumber)
			}
		}
		let secrets = try parser.finish()
		guard !secrets.isEmpty else { throw EnvFileImportError.noValidSecrets }
		return ImportedEnvFile(
			secrets: secrets, byteCount: byteCount,
			skippedLineCount: parser.skippedLineCount, firstSkippedLine: parser.firstSkippedLine)
	}
}

private struct StreamingEnvFileParser {
	let limits: EnvFileImportLimits
	private var result: [String: String] = [:]
	private var keysByFoldedName: [String: String] = [:]
	private var parsedBytes = 0
	private var assignmentCount = 0
	private var pendingQuotedAssignment: String?
	private var pendingQuotedAssignmentBytes = 0
	private var pendingAssignmentLine: Int?
	private var pendingQuote: Character?
	private(set) var skippedLineCount = 0
	private(set) var firstSkippedLine: Int?

	init(limits: EnvFileImportLimits) {
		self.limits = limits
	}

	var hasPendingQuotedAssignment: Bool {
		pendingQuotedAssignment != nil
	}

	mutating func skip(line: Int) {
		skippedLineCount += 1
		if firstSkippedLine == nil { firstSkippedLine = line }
	}

	mutating func consume(_ line: String, lineNumber: Int) throws {
		try Task.checkCancellation()
		if pendingQuotedAssignment != nil {
			let lineBytes = line.utf8.count
			let (withNewline, newlineOverflow) =
				pendingQuotedAssignmentBytes.addingReportingOverflow(1)
			let (retainedBytes, lineOverflow) = withNewline.addingReportingOverflow(lineBytes)
			guard !newlineOverflow, !lineOverflow,
				retainedBytes <= limits.maximumParsedBytes
			else {
				throw EnvFileImportError.parsedDataTooLarge(limit: limits.maximumParsedBytes)
			}
			pendingQuotedAssignmentBytes = retainedBytes
			pendingQuotedAssignment?.append("\n")
			pendingQuotedAssignment?.append(line)
			guard let quote = pendingQuote,
				EnvFileCodec.containsClosingQuote(in: line, quote: quote),
				let pendingQuotedAssignment
			else {
				return
			}
			let sourceLine = pendingAssignmentLine ?? lineNumber
			self.pendingQuotedAssignment = nil
			pendingQuotedAssignmentBytes = 0
			pendingAssignmentLine = nil
			pendingQuote = nil
			try merge(pendingQuotedAssignment, sourceLine: sourceLine)
			return
		}

		if let quote = EnvFileCodec.unterminatedQuote(in: line) {
			let lineBytes = line.utf8.count
			guard lineBytes <= limits.maximumParsedBytes else {
				throw EnvFileImportError.parsedDataTooLarge(limit: limits.maximumParsedBytes)
			}
			pendingQuotedAssignment = line
			pendingQuotedAssignmentBytes = lineBytes
			pendingAssignmentLine = lineNumber
			pendingQuote = quote
			return
		}
		try merge(line, sourceLine: lineNumber)
	}

	mutating func finish() throws -> [String: String] {
		if let pendingQuotedAssignment {
			let sourceLine = pendingAssignmentLine ?? 1
			self.pendingQuotedAssignment = nil
			pendingAssignmentLine = nil
			pendingQuote = nil
			try merge(pendingQuotedAssignment, sourceLine: sourceLine)
		}
		return result
	}

	private mutating func merge(_ assignment: String, sourceLine: Int) throws {
		let singleLineLimits = EnvFileImportLimits(
			maximumInputBytes: limits.maximumInputBytes,
			maximumAssignments: 1,
			maximumParsedBytes: limits.maximumParsedBytes
		)
		let parsed: [String: String]
		do {
			parsed = try EnvFileCodec.parse(assignment, limits: singleLineLimits)
		} catch EnvFileImportError.invalidVariableName(let relativeLine) {
			throw EnvFileImportError.invalidVariableName(
				line: sourceLine + max(0, relativeLine - 1)
			)
		} catch EnvFileImportError.caseInsensitiveCollision(
			let relativeLine, let existingKey, let incomingKey
		) {
			throw EnvFileImportError.caseInsensitiveCollision(
				line: sourceLine + max(0, relativeLine - 1),
				existingKey: existingKey,
				incomingKey: incomingKey
			)
		}
		guard let (key, value) = parsed.first else {
			if !EnvFileCodec.isBlankOrComment(assignment) { skip(line: sourceLine) }
			return
		}
		assignmentCount += 1
		guard assignmentCount <= limits.maximumAssignments else {
			throw EnvFileImportError.tooManyAssignments(limit: limits.maximumAssignments)
		}
		let foldedKey = key.lowercased()
		if let existingKey = keysByFoldedName[foldedKey], existingKey != key {
			throw EnvFileImportError.caseInsensitiveCollision(
				line: sourceLine,
				existingKey: existingKey,
				incomingKey: key
			)
		}
		keysByFoldedName[foldedKey] = key
		let oldBytes = result[key].map { key.utf8.count + $0.utf8.count } ?? 0
		parsedBytes = parsedBytes - oldBytes + key.utf8.count + value.utf8.count
		guard parsedBytes <= limits.maximumParsedBytes else {
			throw EnvFileImportError.parsedDataTooLarge(limit: limits.maximumParsedBytes)
		}
		result[key] = value
	}
}

enum BoundedEnvFileReader {
	private static let chunkSize = 64 * 1024

	/// Opens once, validates metadata from that descriptor, and reads at most
	/// `maximumBytes + 1`, so a file that grows after fstat remains bounded.
	static func read(at url: URL, maximumBytes: Int) throws -> Data {
		try read(at: url, maximumBytes: maximumBytes, afterMetadata: {})
	}

	static func read(
		at url: URL,
		maximumBytes: Int,
		afterMetadata: () throws -> Void
	) throws -> Data {
		guard url.isFileURL, maximumBytes >= 0, maximumBytes < Int.max else {
			throw EnvFileImportError.readFailed
		}
		try Task.checkCancellation()

		let descriptor = url.withUnsafeFileSystemRepresentation { path in
			guard let path else { return Int32(-1) }
			return Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NONBLOCK | O_NOFOLLOW)
		}
		guard descriptor >= 0 else {
			if errno == ENOENT { throw EnvFileImportError.fileNotFound }
			if errno == ELOOP { throw EnvFileImportError.notRegularFile }
			throw EnvFileImportError.readFailed
		}
		defer { Darwin.close(descriptor) }

		var metadata = stat()
		guard Darwin.fstat(descriptor, &metadata) == 0 else {
			throw EnvFileImportError.readFailed
		}
		guard (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
			throw EnvFileImportError.notRegularFile
		}
		guard metadata.st_size <= Int64(maximumBytes) else {
			throw EnvFileImportError.tooLarge(limit: maximumBytes)
		}
		try afterMetadata()
		try Task.checkCancellation()

		let authoritativeLimit = maximumBytes + 1
		var data = Data()
		data.reserveCapacity(min(max(0, Int(metadata.st_size)), 8 * 1024))
		var buffer = [UInt8](repeating: 0, count: min(chunkSize, authoritativeLimit))

		while data.count < authoritativeLimit {
			try Task.checkCancellation()
			let requested = min(buffer.count, authoritativeLimit - data.count)
			let count = buffer.withUnsafeMutableBytes { bytes in
				Darwin.read(descriptor, bytes.baseAddress, requested)
			}
			if count == 0 { break }
			if count < 0 {
				if errno == EINTR { continue }
				throw EnvFileImportError.readFailed
			}
			data.append(contentsOf: buffer.prefix(count))
		}

		guard data.count <= maximumBytes else {
			throw EnvFileImportError.tooLarge(limit: maximumBytes)
		}
		return data
	}

	/// Calls `body` with each line that isn't blank or a comment, and its
	/// number, and `skipped` with the number of each line too long to keep that
	/// holds no assignment. Returns the bytes read.
	@discardableResult
	static func forEachLine(
		at url: URL,
		maximumBytes: Int,
		parsedDataLimit: Int? = nil,
		maximumRetainedLineBytes: Int? = nil,
		preservePhysicalLine: () -> Bool = { false },
		skipped: (Int) -> Void = { _ in },
		_ body: (String, Int) throws -> Void
	) throws -> Int {
		guard url.isFileURL, maximumBytes >= 0, maximumBytes < Int.max else {
			throw EnvFileImportError.readFailed
		}
		try Task.checkCancellation()
		let descriptor = url.withUnsafeFileSystemRepresentation { path in
			guard let path else { return Int32(-1) }
			return Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NONBLOCK | O_NOFOLLOW)
		}
		guard descriptor >= 0 else {
			if errno == ENOENT { throw EnvFileImportError.fileNotFound }
			if errno == ELOOP { throw EnvFileImportError.notRegularFile }
			throw EnvFileImportError.readFailed
		}
		defer { _ = Darwin.close(descriptor) }

		var metadata = stat()
		guard Darwin.fstat(descriptor, &metadata) == 0 else {
			throw EnvFileImportError.readFailed
		}
		guard (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
			throw EnvFileImportError.notRegularFile
		}
		guard metadata.st_size >= 0, metadata.st_size <= Int64(maximumBytes) else {
			throw EnvFileImportError.tooLarge(limit: maximumBytes)
		}

		var scanner = LineScanner(
			maximumBytes: maximumBytes, parsedDataLimit: parsedDataLimit,
			maximumRetainedLineBytes: maximumRetainedLineBytes, preservesFirstLine: preservePhysicalLine())
		var buffer = [UInt8](repeating: 0, count: chunkSize)
		while true {
			try Task.checkCancellation()
			let count = buffer.withUnsafeMutableBytes { bytes in
				Darwin.read(descriptor, bytes.baseAddress, bytes.count)
			}
			if count == 0 { break }
			if count < 0 {
				if errno == EINTR { continue }
				throw EnvFileImportError.readFailed
			}
			try buffer.withUnsafeBufferPointer { bytes in
				try scanner.scan(
					UnsafeBufferPointer(rebasing: bytes.prefix(count)),
					preservePhysicalLine: preservePhysicalLine, skipped: skipped, body)
			}
		}
		return try scanner.finish(preservePhysicalLine: preservePhysicalLine, skipped: skipped, body)
	}

	/// Reads pasted text as `forEachLine(at:)` reads a file, under the same limits.
	@discardableResult
	static func forEachLine(
		in text: String,
		maximumBytes: Int,
		parsedDataLimit: Int? = nil,
		maximumRetainedLineBytes: Int? = nil,
		preservePhysicalLine: () -> Bool = { false },
		skipped: (Int) -> Void = { _ in },
		_ body: (String, Int) throws -> Void
	) throws -> Int {
		guard maximumBytes >= 0, maximumBytes < Int.max else { throw EnvFileImportError.readFailed }
		guard text.utf8.count <= maximumBytes else { throw EnvFileImportError.tooLarge(limit: maximumBytes) }
		var text = text
		text.makeContiguousUTF8()
		var scanner = LineScanner(
			maximumBytes: maximumBytes, parsedDataLimit: parsedDataLimit,
			maximumRetainedLineBytes: maximumRetainedLineBytes, preservesFirstLine: preservePhysicalLine())
		func scan(_ bytes: UnsafeBufferPointer<UInt8>) throws {
			var start = 0
			while start < bytes.count {
				try Task.checkCancellation()
				let end = min(start + chunkSize, bytes.count)
				try scanner.scan(
					UnsafeBufferPointer(rebasing: bytes[start..<end]),
					preservePhysicalLine: preservePhysicalLine, skipped: skipped, body)
				start = end
			}
		}
		if try text.utf8.withContiguousStorageIfAvailable(scan) == nil {
			try Array(text.utf8).withUnsafeBufferPointer(scan)
		}
		return try scanner.finish(preservePhysicalLine: preservePhysicalLine, skipped: skipped, body)
	}

	/// Splits bytes into lines, as both front ends hand them over, keeping
	/// what it has seen of the line it's in.
	private struct LineScanner {
		private let maximumBytes: Int
		private let retainedLimit: Int
		private let reportedParsedDataLimit: Int
		private var totalBytes = 0
		private var lineNumber = 0
		private var line = Data()
		private var validator = StreamingUTF8Validator()
		private var classification = ASCIILineClassification.undecided
		private var hasPhysicalBytes = false
		private var lineWasTruncated = false
		private var sawEquals = false
		private var preservesCurrentLine: Bool
		/// Blanks came before the first line's first kept byte, so a byte
		/// order mark there isn't at the start of the file.
		private var skippedBeforeFirstByte = false

		init(maximumBytes: Int, parsedDataLimit: Int?, maximumRetainedLineBytes: Int?, preservesFirstLine: Bool) {
			self.maximumBytes = maximumBytes
			retainedLimit = max(0, min(maximumRetainedLineBytes ?? maximumBytes, maximumBytes))
			reportedParsedDataLimit = parsedDataLimit ?? retainedLimit
			line.reserveCapacity(min(256, retainedLimit))
			preservesCurrentLine = preservesFirstLine
		}

		mutating func scan(
			_ chunk: UnsafeBufferPointer<UInt8>,
			preservePhysicalLine: () -> Bool,
			skipped: (Int) -> Void,
			_ body: (String, Int) throws -> Void
		) throws {
			totalBytes += chunk.count
			guard totalBytes <= maximumBytes else {
				throw EnvFileImportError.tooLarge(limit: maximumBytes)
			}
			for byte in chunk {
				try consume(byte, preservePhysicalLine: preservePhysicalLine, skipped: skipped, body)
			}
		}

		/// Ends the last line and returns the bytes read.
		mutating func finish(
			preservePhysicalLine: () -> Bool,
			skipped: (Int) -> Void,
			_ body: (String, Int) throws -> Void
		) throws -> Int {
			guard validator.isComplete else { throw EnvFileImportError.invalidUTF8 }
			if hasPhysicalBytes {
				try finishLine(terminatedByNewline: false, preservePhysicalLine: preservePhysicalLine, skipped: skipped, body)
			}
			return totalBytes
		}

		private mutating func finishLine(
			terminatedByNewline: Bool,
			preservePhysicalLine: () -> Bool,
			skipped: (Int) -> Void,
			_ body: (String, Int) throws -> Void
		) throws {
			lineNumber += 1
			defer {
				line.removeAll(keepingCapacity: true)
				classification = .undecided
				hasPhysicalBytes = false
				lineWasTruncated = false
				sawEquals = false
				preservesCurrentLine = preservePhysicalLine()
			}
			guard classification == .significant || preservesCurrentLine else { return }
			if lineWasTruncated {
				// A line too long to keep that holds no assignment is skipped,
				// without a second full-size Data/String representation.
				guard !sawEquals, !preservesCurrentLine else {
					throw EnvFileImportError.parsedDataTooLarge(
						limit: reportedParsedDataLimit
					)
				}
				skipped(lineNumber)
				return
			}
			if lineNumber == 1, !skippedBeforeFirstByte, line.starts(with: [0xEF, 0xBB, 0xBF]) { line.removeFirst(3) }
			if terminatedByNewline, line.last == 0x0D { line.removeLast() }
			// The validator has already checked these bytes are whole UTF-8.
			// Foundation's decoding would drop a byte order mark that starts
			// any line, even inside a value; only the file's first one goes.
			try body(String(decoding: line, as: UTF8.self), lineNumber)
		}

		private mutating func consume(
			_ byte: UInt8,
			preservePhysicalLine: () -> Bool,
			skipped: (Int) -> Void,
			_ body: (String, Int) throws -> Void
		) throws {
			guard validator.consume(byte) else { throw EnvFileImportError.invalidUTF8 }
			if byte == 0x0A {
				try finishLine(terminatedByNewline: true, preservePhysicalLine: preservePhysicalLine, skipped: skipped, body)
				return
			}
			hasPhysicalBytes = true
			switch classification {
			case .undecided:
				if preservesCurrentLine {
					classification = .significant
				} else if isASCIIWhitespace(byte) {
					if lineNumber == 0 { skippedBeforeFirstByte = true }
					return
				} else if byte == 0x23 {
					classification = .ignored
					return
				} else {
					classification = .significant
				}
			case .ignored:
				return
			case .significant:
				break
			}

			if byte == 0x3D {
				sawEquals = true
				if lineWasTruncated {
					if preservesCurrentLine {
						throw EnvFileImportError.parsedDataTooLarge(
							limit: reportedParsedDataLimit
						)
					}
					throw EnvFileImportError.invalidVariableName(line: lineNumber + 1)
				}
			}
			guard line.count < retainedLimit else {
				lineWasTruncated = true
				if sawEquals {
					throw EnvFileImportError.parsedDataTooLarge(
						limit: reportedParsedDataLimit
					)
				}
				return
			}
			line.append(byte)
		}
	}

	private enum ASCIILineClassification {
		case undecided
		case ignored
		case significant
	}

	/// A space or a tab, the blanks of dotenv syntax, which a line can start
	/// with before what it holds. Any other byte belongs to the line.
	private static func isASCIIWhitespace(_ byte: UInt8) -> Bool {
		switch byte {
		case 0x20, 0x09: true
		default: false
		}
	}

	private struct StreamingUTF8Validator {
		private var remaining = 0
		private var nextMinimum: UInt8 = 0x80
		private var nextMaximum: UInt8 = 0xBF

		var isComplete: Bool { remaining == 0 }

		mutating func consume(_ byte: UInt8) -> Bool {
			if remaining > 0 {
				guard byte >= nextMinimum, byte <= nextMaximum else { return false }
				remaining -= 1
				nextMinimum = 0x80
				nextMaximum = 0xBF
				return true
			}
			switch byte {
			case 0x00...0x7F:
				return true
			case 0xC2...0xDF:
				remaining = 1
			case 0xE0:
				remaining = 2
				nextMinimum = 0xA0
			case 0xE1...0xEC, 0xEE...0xEF:
				remaining = 2
			case 0xED:
				remaining = 2
				nextMaximum = 0x9F
			case 0xF0:
				remaining = 3
				nextMinimum = 0x90
			case 0xF1...0xF3:
				remaining = 3
			case 0xF4:
				remaining = 3
				nextMaximum = 0x8F
			default:
				return false
			}
			return true
		}
	}
}

enum EnvFileCodec {
	static func hasUnterminatedQuotedValue(_ line: String) -> Bool {
		unterminatedQuote(in: line) != nil
	}

	static func unterminatedQuote(in line: String) -> Character? {
		guard let (_, value) = assignment(in: line[...]), let quote = value.first, quote == "\"" || quote == "'" else { return nil }
		return closingQuote(in: value.dropFirst(), quote: quote) == nil ? Character(quote) : nil
	}

	static func isBlankOrComment(_ line: String) -> Bool {
		let scalars = line.unicodeScalars[...].trimmingLeadingDotenvBlanks()
		return scalars.isEmpty || scalars.first == "#"
	}

	static func containsClosingQuote(in value: String, quote: Character) -> Bool {
		guard let quote = quote.unicodeScalars.first else { return false }
		return closingQuote(in: value.unicodeScalars[...], quote: quote) != nil
	}

	/// The key of a dotenv line, and what follows its `=` without the blanks
	/// it starts with; nil for a blank line, a comment or a line without `=`.
	/// Syntax is read by scalar, as the LPM CLI reads it by char: a hidden
	/// character next to a quote or a blank would otherwise join it into one
	/// Character, and the quote would go unseen. Only a line's start loses
	/// its blanks; an unquoted value loses those at its end later, and a
	/// quoted one keeps them.
	static func assignment(in line: Substring) -> (key: String, value: Substring.UnicodeScalarView)? {
		var scalars = line.unicodeScalars.trimmingLeadingDotenvBlanks()
		guard let first = scalars.first, first != "#" else { return nil }
		if scalars.starts(with: "export ".unicodeScalars) { scalars = scalars.dropFirst("export ".unicodeScalars.count) }
		guard let equals = scalars.firstIndex(of: "=") else { return nil }
		return (String(scalars[..<equals].trimmingDotenvBlanks()), scalars[scalars.index(after: equals)...].trimmingLeadingDotenvBlanks())
	}

	static func parse(
		_ content: String,
		limits: EnvFileImportLimits = .standard
	) throws -> [String: String] {
		var lines = EnvLineIterator(content)
		var result: [String: String] = [:]
		var keysByFoldedName: [String: String] = [:]
		var parsedBytes = 0
		var assignmentCount = 0

		while let rawLine = lines.next() {
			try Task.checkCancellation()
			guard let (key, assignedValue) = assignment(in: rawLine[...]), !key.isEmpty else { continue }

			assignmentCount += 1
			guard assignmentCount <= limits.maximumAssignments else {
				throw EnvFileImportError.tooManyAssignments(limit: limits.maximumAssignments)
			}
			guard EnvValidation.isValidVariableName(key) else {
				throw EnvFileImportError.invalidVariableName(line: lines.lineNumber)
			}
			let foldedKey = key.lowercased()
			if let existingKey = keysByFoldedName[foldedKey], existingKey != key {
				throw EnvFileImportError.caseInsensitiveCollision(
					line: lines.lineNumber,
					existingKey: existingKey,
					incomingKey: key
				)
			}
			keysByFoldedName[foldedKey] = key

			let oldBytes = result[key].map { key.utf8.count + $0.utf8.count } ?? 0
			let remainingValueBytes = max(
				0,
				limits.maximumParsedBytes - parsedBytes + oldBytes - key.utf8.count
			)
			let value = try parseValue(
				assignedValue,
				lines: &lines,
				maximumBytes: remainingValueBytes,
				parsedLimit: limits.maximumParsedBytes
			)
			parsedBytes = parsedBytes - oldBytes + key.utf8.count + value.utf8.count
			guard parsedBytes <= limits.maximumParsedBytes else {
				throw EnvFileImportError.parsedDataTooLarge(limit: limits.maximumParsedBytes)
			}
			result[key] = value
		}

		return result
	}

	/// Produces a lossless dotenv file whose values remain literal when sourced
	/// by a POSIX shell. Double-quoted shell expansion characters are escaped.
	static func format(_ secrets: [String: String]) -> String {
		let entries = secrets.sorted { $0.key < $1.key }
		var output = ""
		output.reserveCapacity(formattedCapacity(entries))
		for (key, value) in entries {
			output.append(key)
			output.append("=\"")
			appendEscaped(value, to: &output)
			output.append("\"\n")
		}
		return output
	}

	/// One variable as a line that reads back as the same value: bare when
	/// every character means only itself, here and when a POSIX shell sources
	/// it, and otherwise double-quoted as `format` writes it. Either way it's
	/// a single line, as newlines are escaped.
	static func formatLine(key: String, value: String) -> String {
		guard value.unicodeScalars.allSatisfy(isBareValueScalar) else {
			var line = key + "=\""
			appendEscaped(value, to: &line)
			line.append("\"")
			return line
		}
		return key + "=" + value
	}

	/// Letters, digits, and the punctuation of URLs, paths and tokens that
	/// neither this parser nor a shell assignment reads specially.
	private static func isBareValueScalar(_ scalar: Unicode.Scalar) -> Bool {
		switch scalar {
		case "0"..."9", "A"..."Z", "a"..."z", "%", "+", ",", "-", ".", "/", ":", "=", "@", "_": true
		default: false
		}
	}

	static func formatData(_ secrets: [String: String]) -> Data {
		let entries = secrets.sorted { $0.key < $1.key }
		var output = Data(count: formattedDataCapacity(entries))
		output.withUnsafeMutableBytes { rawOutput in
			let outputBytes = rawOutput.bindMemory(to: UInt8.self)
			var offset = 0
			for (key, value) in entries {
				for byte in key.utf8 {
					outputBytes[offset] = byte
					offset += 1
				}
				outputBytes[offset] = 0x3D
				outputBytes[offset + 1] = 0x22
				offset += 2
				for byte in value.utf8 {
					if let escaped = escapedByte(for: byte) {
						outputBytes[offset] = 0x5C
						outputBytes[offset + 1] = escaped
						offset += 2
					} else {
						outputBytes[offset] = byte
						offset += 1
					}
				}
				outputBytes[offset] = 0x22
				outputBytes[offset + 1] = 0x0A
				offset += 2
			}
			precondition(offset == outputBytes.count)
		}
		return output
	}

	private static func formattedCapacity(
		_ entries: [(key: String, value: String)]
	) -> Int {
		formattedDataCapacity(entries)
	}

	private static func formattedDataCapacity(
		_ entries: [(key: String, value: String)]
	) -> Int {
		entries.reduce(into: 0) { size, entry in
			size += entry.key.utf8.count + entry.value.utf8.count + 4
			for byte in entry.value.utf8 where escapedByte(for: byte) != nil {
				size += 1
			}
		}
	}

	private static func appendEscaped(_ value: String, to output: inout String) {
		let scalars = value.unicodeScalars
		var start = scalars.startIndex
		for index in scalars.indices {
			guard let escaped = escapedScalar(for: scalars[index]) else { continue }
			output.unicodeScalars.append(contentsOf: scalars[start..<index])
			output.append("\\")
			output.unicodeScalars.append(escaped)
			start = scalars.index(after: index)
		}
		output.unicodeScalars.append(contentsOf: scalars[start...])
	}

	private static func escapedScalar(for scalar: Unicode.Scalar) -> Unicode.Scalar? {
		switch scalar.value {
		case 0x5C: "\\"
		case 0x22: "\""
		case 0x24: "$"
		case 0x60: "`"
		case 0x0A: "n"
		case 0x0D: "r"
		case 0x09: "t"
		default: nil
		}
	}

	private static func escapedByte(for byte: UInt8) -> UInt8? {
		switch byte {
		case 0x5C, 0x22, 0x24, 0x60: byte
		case 0x0A: 0x6E
		case 0x0D: 0x72
		case 0x09: 0x74
		default: nil
		}
	}

	private static func parseValue(
		_ value: Substring.UnicodeScalarView,
		lines: inout EnvLineIterator,
		maximumBytes: Int,
		parsedLimit: Int
	) throws -> String {
		guard let quote = value.first, quote == "\"" || quote == "'" else {
			let unquoted = String(value.trimmingDotenvBlanks())
			guard unquoted.utf8.count <= maximumBytes else {
				throw EnvFileImportError.parsedDataTooLarge(limit: parsedLimit)
			}
			return unquoted
		}

		var collected = ""
		var fragment = value.dropFirst()
		while true {
			try Task.checkCancellation()
			if let closing = closingQuote(in: fragment, quote: quote) {
				collected.unicodeScalars.append(contentsOf: fragment[..<closing])
				let parsed = quote == "\"" ? unescapeDoubleQuoted(collected) : collected
				guard parsed.utf8.count <= maximumBytes else {
					throw EnvFileImportError.parsedDataTooLarge(limit: parsedLimit)
				}
				return parsed
			}
			collected.unicodeScalars.append(contentsOf: fragment)
			guard collected.utf8.count <= maximumBytes else {
				throw EnvFileImportError.parsedDataTooLarge(limit: parsedLimit)
			}
			guard let next = lines.next() else {
				return quote == "\"" ? unescapeDoubleQuoted(collected) : collected
			}
			collected.append("\n")
			fragment = next.unicodeScalars[...]
		}
	}

	private static func closingQuote(in value: Substring.UnicodeScalarView, quote: Unicode.Scalar) -> Substring.UnicodeScalarView.Index? {
		if quote == "'" { return value.firstIndex(of: quote) }
		var escaped = false
		for index in value.indices {
			let scalar = value[index]
			if escaped {
				escaped = false
			} else if scalar == "\\" {
				escaped = true
			} else if scalar == quote {
				return index
			}
		}
		return nil
	}

	private static func unescapeDoubleQuoted(_ value: String) -> String {
		var result = String.UnicodeScalarView()
		var iterator = value.unicodeScalars.makeIterator()
		while let scalar = iterator.next() {
			guard scalar == "\\" else {
				result.append(scalar)
				continue
			}
			guard let escaped = iterator.next() else {
				result.append("\\")
				break
			}
			switch escaped {
			case "n": result.append("\n")
			case "r": result.append("\r")
			case "t": result.append("\t")
			case "\"", "\\", "$", "`": result.append(escaped)
			default:
				result.append("\\")
				result.append(escaped)
			}
		}
		return String(result)
	}
}

private struct EnvLineIterator {
	private let content: String
	private var nextIndex: String.Index
	private(set) var lineNumber = 0

	init(_ content: String) {
		self.content = content
		self.nextIndex = content.startIndex
	}

	mutating func next() -> String? {
		guard nextIndex < content.endIndex else { return nil }
		lineNumber += 1
		// By scalars: as a Character, "\r\n" is one grapheme, which "\n" never matches.
		let scalars = content.unicodeScalars
		if let newline = scalars[nextIndex...].firstIndex(of: "\n") {
			var line = scalars[nextIndex..<newline]
			nextIndex = scalars.index(after: newline)
			if line.last == "\r" { line = line.dropLast() }
			return String(line)
		}
		let line = String(scalars[nextIndex...])
		nextIndex = content.endIndex
		return line
	}
}

extension Substring.UnicodeScalarView {
	/// The scalars without the spaces and tabs at either end, the blanks of
	/// dotenv syntax. Every other character, even one that looks blank such
	/// as a no-break space, belongs to the value, where the warnings about
	/// hidden characters find it. The LPM CLI's parsers keep the same rule.
	func trimmingDotenvBlanks() -> Substring.UnicodeScalarView {
		guard let first = firstIndex(where: { !$0.isDotenvBlank }), let last = lastIndex(where: { !$0.isDotenvBlank }) else {
			return self[endIndex...]
		}
		return self[first...last]
	}

	/// The scalars without the spaces and tabs they start with.
	func trimmingLeadingDotenvBlanks() -> Substring.UnicodeScalarView {
		self[(firstIndex { !$0.isDotenvBlank } ?? endIndex)...]
	}
}

extension StringProtocol {
	/// The text without the spaces and tabs at either end, read by scalar.
	func trimmingDotenvBlanks() -> String {
		String(Substring(self).unicodeScalars.trimmingDotenvBlanks())
	}
}

extension String {
	/// The text without the byte order mark an editor can put at the start of a file.
	func droppingByteOrderMark() -> String {
		unicodeScalars.first == "\u{FEFF}" ? String(unicodeScalars.dropFirst()) : self
	}
}

extension Unicode.Scalar {
	/// A space or a tab, the blanks of dotenv syntax.
	var isDotenvBlank: Bool { self == " " || self == "\t" }
}
