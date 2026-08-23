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
	private struct Waiter {
		let id: UUID
		let continuation: CheckedContinuation<Bool, Never>
	}

	private let limit: Int
	private var active = 0
	private var waiters: [Waiter] = []

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
					waiters.append(Waiter(id: id, continuation: continuation))
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
		while !waiters.isEmpty {
			let waiter = waiters.removeFirst()
			waiter.continuation.resume(returning: true)
			return
		}
		active = max(0, active - 1)
	}

	private func cancelWaiter(id: UUID) {
		guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
		let waiter = waiters.remove(at: index)
		waiter.continuation.resume(returning: false)
	}
}

enum EnvFileImportWorker {
	static func load(at url: URL, limits: EnvFileImportLimits) throws -> ImportedEnvFile {
		let data = try BoundedEnvFileReader.read(
			at: url,
			maximumBytes: limits.maximumInputBytes
		)
		try Task.checkCancellation()
		guard let content = String(data: data, encoding: .utf8) else {
			throw EnvFileImportError.invalidUTF8
		}
		let secrets = try EnvFileCodec.parse(content, limits: limits)
		guard !secrets.isEmpty else { throw EnvFileImportError.noValidSecrets }
		return ImportedEnvFile(secrets: secrets)
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
			return Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NONBLOCK)
		}
		guard descriptor >= 0 else {
			if errno == ENOENT { throw EnvFileImportError.fileNotFound }
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
}

enum EnvFileCodec {
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

	/// Matches the Rust vault exporter. Backslashes must be escaped before
	/// quotes so the Rust-compatible importer preserves literal escape text.
	static func format(_ secrets: [String: String]) -> String {
		secrets.sorted { $0.key < $1.key }
			.map { key, value in
				if value.contains(" ") || value.contains("\"") || value.contains("'")
					|| value.contains("#") || value.contains("\n") || value.contains("\r")
				{
					let escaped = value
						.replacingOccurrences(of: "\\", with: "\\\\")
						.replacingOccurrences(of: "\"", with: "\\\"")
						.replacingOccurrences(of: "\n", with: "\\n")
						.replacingOccurrences(of: "\r", with: "\\r")
					return "\(key)=\"\(escaped)\""
				}
				return "\(key)=\(value)"
			}
			.joined(separator: "\n") + "\n"
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
