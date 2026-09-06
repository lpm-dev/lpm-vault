import Darwin
import Foundation

struct ImportedEnvFile: Sendable, Equatable {
	let secrets: [String: String]

	var count: Int { secrets.count }
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
	case caseInsensitiveCollisionWithExisting
	case persistence(String)

	var errorDescription: String? {
		switch self {
		case .cancelled:
			"Import cancelled."
		case .fileNotFound:
			"The selected .env file no longer exists."
		case .notRegularFile:
			"Select a regular .env file."
		case .tooLarge(let limit):
			"The .env file exceeds the \(Self.byteCount(limit)) limit."
		case .invalidUTF8:
			"The .env file is not valid UTF-8."
		case .readFailed:
			"The .env file could not be read."
		case .invalidVariableName(let line):
			"Line \(line) has a variable name that does not match [A-Za-z_][A-Za-z0-9_]*."
		case .caseInsensitiveCollision(let line, let existingKey, let incomingKey):
			"Line \(line) defines \(incomingKey), which differs from \(existingKey) only by letter case. Rename one key for Windows compatibility."
		case .tooManyAssignments(let limit):
			"The .env file contains more than \(limit) assignments."
		case .parsedDataTooLarge(let limit):
			"The parsed .env data exceeds the \(Self.byteCount(limit)) import limit."
		case .noValidSecrets:
			"The .env file does not contain any valid secrets."
		case .vaultLocked:
			"Unlock LPM Vault before importing secrets."
		case .targetUnavailable:
			"The target env project or environment changed before the import completed."
		case .caseInsensitiveCollisionWithExisting:
			"A key in this file differs only by letter case from an existing key. Rename one key for Windows compatibility."
		case .persistence(let message):
			"Import failed. \(message)"
		}
	}

	private static func byteCount(_ count: Int) -> String {
		ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .binary)
	}
}

protocol EnvFileImportServiceProtocol: Sendable {
	func load(at url: URL) async throws -> ImportedEnvFile
}

/// Bounds all local dotenv work behind one shared admission pool. File reads
/// and parsing run on background executors; callers only publish the result.
final class EnvFileImportService: EnvFileImportServiceProtocol, @unchecked Sendable {
	typealias Worker = @Sendable (URL, EnvFileImportLimits) throws -> ImportedEnvFile
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

	func load(at url: URL) async throws -> ImportedEnvFile {
		do {
			try await admission.acquire()
		} catch is CancellationError {
			throw EnvFileImportError.cancelled
		}

		let backgroundTask = Task.detached(priority: .userInitiated) { [limits, worker] in
			try Task.checkCancellation()
			return try worker(url, limits)
		}

		do {
			let imported = try await withTaskCancellationHandler {
				try await backgroundTask.value
			} onCancel: {
				backgroundTask.cancel()
			}
			await admission.release()
			return imported
		} catch is CancellationError {
			backgroundTask.cancel()
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
	static func load(at url: URL, limits: EnvFileImportLimits) throws -> ImportedEnvFile {
		var parser = StreamingEnvFileParser(limits: limits)
		try BoundedEnvFileReader.forEachLine(
			at: url,
			maximumBytes: limits.maximumInputBytes,
			parsedDataLimit: limits.maximumParsedBytes,
			maximumRetainedLineBytes: min(
				limits.maximumInputBytes,
				limits.maximumParsedBytes * 2 + 1_024
			),
			preservePhysicalLine: { parser.hasPendingQuotedAssignment }
		) { line, lineNumber in
			try parser.consume(line, lineNumber: lineNumber)
		}
		let secrets = try parser.finish()
		guard !secrets.isEmpty else { throw EnvFileImportError.noValidSecrets }
		return ImportedEnvFile(secrets: secrets)
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

	init(limits: EnvFileImportLimits) {
		self.limits = limits
	}

	var hasPendingQuotedAssignment: Bool {
		pendingQuotedAssignment != nil
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
		guard let (key, value) = parsed.first else { return }
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

	static func forEachLine(
		at url: URL,
		maximumBytes: Int,
		parsedDataLimit: Int? = nil,
		maximumRetainedLineBytes: Int? = nil,
		preservePhysicalLine: () -> Bool = { false },
		_ body: (String, Int) throws -> Void
	) throws {
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

		let retainedLimit = max(0, min(maximumRetainedLineBytes ?? maximumBytes, maximumBytes))
		let reportedParsedDataLimit = parsedDataLimit ?? retainedLimit
		var totalBytes = 0
		var lineNumber = 0
		var line = Data()
		line.reserveCapacity(min(256, retainedLimit))
		var buffer = [UInt8](repeating: 0, count: chunkSize)
		var validator = StreamingUTF8Validator()
		var classification = ASCIILineClassification.undecided
		var hasPhysicalBytes = false
		var lineWasTruncated = false
		var sawEquals = false
		var preservesCurrentLine = preservePhysicalLine()

		func finishLine(terminatedByNewline: Bool) throws {
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
				// A newline-free non-assignment is ignored by the dotenv grammar.
				// It does not need a second full-size Data/String representation.
				guard !sawEquals, !preservesCurrentLine else {
					throw EnvFileImportError.parsedDataTooLarge(
						limit: reportedParsedDataLimit
					)
				}
				return
			}
			if terminatedByNewline, line.last == 0x0D { line.removeLast() }
			guard let decoded = String(data: line, encoding: .utf8) else {
				throw EnvFileImportError.invalidUTF8
			}
			try body(decoded, lineNumber)
		}

		func consume(_ byte: UInt8) throws {
			guard validator.consume(byte) else { throw EnvFileImportError.invalidUTF8 }
			if byte == 0x0A {
				try finishLine(terminatedByNewline: true)
				return
			}
			hasPhysicalBytes = true
			switch classification {
			case .undecided:
				if preservesCurrentLine {
					classification = .significant
				} else if isASCIIWhitespace(byte) {
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
			totalBytes += count
			guard totalBytes <= maximumBytes else {
				throw EnvFileImportError.tooLarge(limit: maximumBytes)
			}

			for byte in buffer.prefix(count) { try consume(byte) }
		}
		guard validator.isComplete else { throw EnvFileImportError.invalidUTF8 }
		if hasPhysicalBytes { try finishLine(terminatedByNewline: false) }
	}

	private enum ASCIILineClassification {
		case undecided
		case ignored
		case significant
	}

	private static func isASCIIWhitespace(_ byte: UInt8) -> Bool {
		switch byte {
		case 0x20, 0x09, 0x0B, 0x0C, 0x0D: true
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
		let trimmed = line.trimmingCharacters(in: .whitespaces)
		if trimmed.isEmpty || trimmed.hasPrefix("#") { return nil }
		let assignment = trimmed.hasPrefix("export ")
			? String(trimmed.dropFirst("export ".count))
			: trimmed
		guard let equals = assignment.firstIndex(of: "=") else { return nil }
		let value = String(assignment[assignment.index(after: equals)...])
			.trimmingLeadingWhitespace()
		guard let quote = value.first, quote == "\"" || quote == "'" else { return nil }
		return closingQuote(in: String(value.dropFirst()), quote: quote) == nil ? quote : nil
	}

	static func containsClosingQuote(in value: String, quote: Character) -> Bool {
		closingQuote(in: value, quote: quote) != nil
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
			let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
			if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

			let assignment = trimmed.hasPrefix("export ")
				? String(trimmed.dropFirst("export ".count))
				: trimmed
			guard let equalsIndex = assignment.firstIndex(of: "=") else { continue }
			let key = assignment[..<equalsIndex]
				.trimmingCharacters(in: .whitespaces)
			guard !key.isEmpty else { continue }

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

			let valueStart = assignment.index(after: equalsIndex)
			let oldBytes = result[key].map { key.utf8.count + $0.utf8.count } ?? 0
			let remainingValueBytes = max(
				0,
				limits.maximumParsedBytes - parsedBytes + oldBytes - key.utf8.count
			)
			let value = try parseValue(
				String(assignment[valueStart...]).trimmingLeadingWhitespace(),
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
		_ value: String,
		lines: inout EnvLineIterator,
		maximumBytes: Int,
		parsedLimit: Int
	) throws -> String {
		guard let quote = value.first, quote == "\"" || quote == "'" else {
			let unquoted = value.trimmingCharacters(in: .whitespaces)
			guard unquoted.utf8.count <= maximumBytes else {
				throw EnvFileImportError.parsedDataTooLarge(limit: parsedLimit)
			}
			return unquoted
		}

		var collected = ""
		var fragment = String(value.dropFirst())
		while true {
			try Task.checkCancellation()
			if let closing = closingQuote(in: fragment, quote: quote) {
				collected.append(contentsOf: fragment[..<closing])
				let parsed = quote == "\"" ? unescapeDoubleQuoted(collected) : collected
				guard parsed.utf8.count <= maximumBytes else {
					throw EnvFileImportError.parsedDataTooLarge(limit: parsedLimit)
				}
				return parsed
			}
			collected.append(fragment)
			guard collected.utf8.count <= maximumBytes else {
				throw EnvFileImportError.parsedDataTooLarge(limit: parsedLimit)
			}
			guard let next = lines.next() else {
				return quote == "\"" ? unescapeDoubleQuoted(collected) : collected
			}
			collected.append("\n")
			fragment = String(next)
		}
	}

	private static func closingQuote(in value: String, quote: Character) -> String.Index? {
		if quote == "'" { return value.firstIndex(of: quote) }
		var escaped = false
		for index in value.indices {
			let character = value[index]
			if escaped {
				escaped = false
			} else if character == "\\" {
				escaped = true
			} else if character == quote {
				return index
			}
		}
		return nil
	}

	private static func unescapeDoubleQuoted(_ value: String) -> String {
		var result = ""
		var iterator = value.makeIterator()
		while let character = iterator.next() {
			guard character == "\\" else {
				result.append(character)
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
			case "\"": result.append("\"")
			case "\\": result.append("\\")
			case "$": result.append("$")
			case "`": result.append("`")
			default:
				result.append("\\")
				result.append(escaped)
			}
		}
		return result
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
		if let newline = content[nextIndex...].firstIndex(of: "\n") {
			var line = content[nextIndex..<newline]
			nextIndex = content.index(after: newline)
			if line.last == "\r" { line = line.dropLast() }
			return String(line)
		}
		let line = String(content[nextIndex...])
		nextIndex = content.endIndex
		return line
	}
}

private extension String {
	func trimmingLeadingWhitespace() -> String {
		let index = firstIndex { !$0.isWhitespace } ?? endIndex
		return String(self[index...])
	}
}
