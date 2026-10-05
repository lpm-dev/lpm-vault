import Foundation

/// A JSON document that keeps object members in file order, parsed and rendered
/// the way the LPM CLI's serde_json does, so the app's edits to `lpm.json` read
/// like the CLI's own.
indirect enum LPMConfigJSON: Equatable, Sendable {
	case object([Member])
	case array([LPMConfigJSON])
	case string(String)
	/// The number exactly as written in the file.
	case number(String)
	case bool(Bool)
	case null

	struct Member: Equatable, Sendable {
		var key: String
		var value: LPMConfigJSON

		static func == (lhs: Self, rhs: Self) -> Bool {
			lhs.key.utf8.elementsEqual(rhs.key.utf8) && lhs.value == rhs.value
		}
	}

	static func == (lhs: Self, rhs: Self) -> Bool {
		switch (lhs, rhs) {
		case (.object(let a), .object(let b)): a == b
		case (.array(let a), .array(let b)): a == b
		case (.string(let a), .string(let b)): a.utf8.elementsEqual(b.utf8)
		case (.number(let a), .number(let b)): a == b
		case (.bool(let a), .bool(let b)): a == b
		case (.null, .null): true
		default: false
		}
	}

	enum ParseError: Error, Equatable, Sendable {
		case invalid(offset: Int)
		/// Nesting beyond serde_json's recursion limit.
		case tooDeep
	}

	/// serde_json's default recursion limit.
	private static let maximumDepth = 128

	init(parsing data: Data, rejectDuplicateKeys: Bool = false) throws(ParseError) {
		var parser = Parser(bytes: [UInt8](data), rejectDuplicateKeys: rejectDuplicateKeys)
		self = try parser.document()
	}

	/// The document as `serde_json::to_string_pretty` renders it, without a trailing newline.
	func rendered() -> String {
		var output = Output(maximumBytes: .max)
		try! render(into: &output, level: 0)
		return output.text
	}

	enum RenderError: Error, Equatable { case tooLarge }

	/// UTF-8 JSON with a trailing newline, stopping before output exceeds the limit.
	func renderedData(maximumBytes: Int) throws(RenderError) -> Data {
		var output = Output(maximumBytes: maximumBytes)
		try render(into: &output, level: 0)
		try output.append("\n")
		return Data(output.text.utf8)
	}

	private struct Output {
		var text = ""
		var byteCount = 0
		let maximumBytes: Int

		mutating func append(_ value: String) throws(RenderError) {
			let count = value.utf8.count
			guard count <= maximumBytes, byteCount <= maximumBytes - count else { throw .tooLarge }
			byteCount += count
			text += value
		}

		mutating func append(_ scalar: Unicode.Scalar) throws(RenderError) {
			let count = scalar.value <= 0x7F ? 1 : scalar.value <= 0x7FF ? 2 : scalar.value <= 0xFFFF ? 3 : 4
			guard count <= maximumBytes, byteCount <= maximumBytes - count else { throw .tooLarge }
			byteCount += count
			text.unicodeScalars.append(scalar)
		}
	}

	subscript(key: String) -> LPMConfigJSON? {
		guard case .object(let members) = self else { return nil }
		return members.first { $0.key.utf8.elementsEqual(key.utf8) }?.value
	}

	/// Sets a member of an object, in place when the key exists and last otherwise.
	mutating func set(_ value: LPMConfigJSON, forKey key: String) {
		guard case .object(var members) = self else { return }
		if let index = members.firstIndex(where: { $0.key.utf8.elementsEqual(key.utf8) }) {
			members[index].value = value
		} else {
			members.append(Member(key: key, value: value))
		}
		self = .object(members)
	}

	@discardableResult
	mutating func removeValue(forKey key: String) -> LPMConfigJSON? {
		guard case .object(var members) = self, let index = members.firstIndex(where: { $0.key.utf8.elementsEqual(key.utf8) }) else { return nil }
		let removed = members.remove(at: index).value
		self = .object(members)
		return removed
	}

	/// Renames an object member in place, keeping its position.
	mutating func renameKey(_ key: String, to newKey: String) {
		guard case .object(var members) = self, let index = members.firstIndex(where: { $0.key.utf8.elementsEqual(key.utf8) }) else { return }
		members[index].key = newKey
		self = .object(members)
	}

	var isEmptyObject: Bool {
		if case .object(let members) = self { return members.isEmpty }
		return false
	}

	// MARK: - Rendering

	private func render(into output: inout Output, level: Int) throws(RenderError) {
		switch self {
		case .object(let members):
			guard !members.isEmpty else {
				try output.append("{}")
				return
			}
			try output.append("{\n")
			for (index, member) in members.enumerated() {
				try Self.indent(&output, level + 1)
				try Self.appendQuoted(member.key, to: &output)
				try output.append(": ")
				try member.value.render(into: &output, level: level + 1)
				try output.append(index == members.count - 1 ? "\n" : ",\n")
			}
			try Self.indent(&output, level)
			try output.append("}")
		case .array(let elements):
			guard !elements.isEmpty else {
				try output.append("[]")
				return
			}
			try output.append("[\n")
			for (index, element) in elements.enumerated() {
				try Self.indent(&output, level + 1)
				try element.render(into: &output, level: level + 1)
				try output.append(index == elements.count - 1 ? "\n" : ",\n")
			}
			try Self.indent(&output, level)
			try output.append("]")
		case .string(let value): try Self.appendQuoted(value, to: &output)
		case .number(let raw): try output.append(raw)
		case .bool(let value): try output.append(value ? "true" : "false")
		case .null: try output.append("null")
		}
	}

	private static func indent(_ output: inout Output, _ level: Int) throws(RenderError) {
		try output.append(String(repeating: "  ", count: level))
	}

	/// Escapes exactly what serde_json escapes: quotes, backslashes, and control characters.
	private static func appendQuoted(_ value: String, to output: inout Output) throws(RenderError) {
		try output.append("\"")
		for scalar in value.unicodeScalars {
			switch scalar {
			case "\"": try output.append("\\\"")
			case "\\": try output.append("\\\\")
			case "\u{08}": try output.append("\\b")
			case "\u{0C}": try output.append("\\f")
			case "\n": try output.append("\\n")
			case "\r": try output.append("\\r")
			case "\t": try output.append("\\t")
			case "\u{00}"..."\u{1F}":
				let hex = String(scalar.value, radix: 16)
				try output.append("\\u" + String(repeating: "0", count: 4 - hex.count) + hex)
			default: try output.append(scalar)
			}
		}
		try output.append("\"")
	}
	// MARK: - Parsing

	private struct Parser {
		let bytes: [UInt8]
		let rejectDuplicateKeys: Bool
		var index = 0
		var depth = 0

		init(bytes: [UInt8], rejectDuplicateKeys: Bool) {
			self.bytes = bytes
			self.rejectDuplicateKeys = rejectDuplicateKeys
			if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { index = 3 }
		}

		mutating func document() throws(ParseError) -> LPMConfigJSON {
			let value = try self.value()
			skipWhitespace()
			guard index == bytes.count else { throw .invalid(offset: index) }
			return value
		}

		private mutating func value() throws(ParseError) -> LPMConfigJSON {
			skipWhitespace()
			guard index < bytes.count else { throw .invalid(offset: index) }
			switch bytes[index] {
			case UInt8(ascii: "{"): return try object()
			case UInt8(ascii: "["): return try array()
			case UInt8(ascii: "\""): return .string(try string())
			case UInt8(ascii: "t"): try literal("true"); return .bool(true)
			case UInt8(ascii: "f"): try literal("false"); return .bool(false)
			case UInt8(ascii: "n"): try literal("null"); return .null
			default: return .number(try number())
			}
		}

		private mutating func object() throws(ParseError) -> LPMConfigJSON {
			try enter()
			defer { depth -= 1 }
			index += 1
			var members: [Member] = []
			var positions: [Data: Int] = [:]
			skipWhitespace()
			if peek(UInt8(ascii: "}")) {
				index += 1
				return .object(members)
			}
			while true {
				skipWhitespace()
				guard peek(UInt8(ascii: "\"")) else { throw .invalid(offset: index) }
				let key = try string()
				skipWhitespace()
				try expect(UInt8(ascii: ":"))
				let value = try self.value()
				// Like serde_json's ordered map, a repeated key keeps its first position and its last value.
				let identity = Data(key.utf8)
				if let position = positions[identity] {
					if rejectDuplicateKeys { throw .invalid(offset: index) }
					members[position].value = value
				} else {
					positions[identity] = members.count
					members.append(Member(key: key, value: value))
				}
				skipWhitespace()
				if peek(UInt8(ascii: ",")) {
					index += 1
					continue
				}
				try expect(UInt8(ascii: "}"))
				return .object(members)
			}
		}

		private mutating func array() throws(ParseError) -> LPMConfigJSON {
			try enter()
			defer { depth -= 1 }
			index += 1
			var elements: [LPMConfigJSON] = []
			skipWhitespace()
			if peek(UInt8(ascii: "]")) {
				index += 1
				return .array(elements)
			}
			while true {
				elements.append(try value())
				skipWhitespace()
				if peek(UInt8(ascii: ",")) {
					index += 1
					continue
				}
				try expect(UInt8(ascii: "]"))
				return .array(elements)
			}
		}

		private mutating func string() throws(ParseError) -> String {
			index += 1
			var result = String.UnicodeScalarView()
			var runStart = index
			while index < bytes.count {
				let byte = bytes[index]
				switch byte {
				case UInt8(ascii: "\""):
					try append(runStart..<index, to: &result)
					index += 1
					return String(result)
				case UInt8(ascii: "\\"):
					try append(runStart..<index, to: &result)
					index += 1
					result.append(try escape())
					runStart = index
				case 0x00..<0x20:
					throw .invalid(offset: index)
				default:
					index += 1
				}
			}
			throw .invalid(offset: index)
		}

		/// Appends unescaped string bytes, which must be valid UTF-8.
		private func append(_ range: Range<Int>, to result: inout String.UnicodeScalarView) throws(ParseError) {
			guard !range.isEmpty else { return }
			guard let run = String(bytes: bytes[range], encoding: .utf8) else { throw .invalid(offset: range.lowerBound) }
			result.append(contentsOf: run.unicodeScalars)
		}

		private mutating func escape() throws(ParseError) -> Unicode.Scalar {
			guard index < bytes.count else { throw .invalid(offset: index) }
			let byte = bytes[index]
			index += 1
			switch byte {
			case UInt8(ascii: "\""): return "\""
			case UInt8(ascii: "\\"): return "\\"
			case UInt8(ascii: "/"): return "/"
			case UInt8(ascii: "b"): return "\u{08}"
			case UInt8(ascii: "f"): return "\u{0C}"
			case UInt8(ascii: "n"): return "\n"
			case UInt8(ascii: "r"): return "\r"
			case UInt8(ascii: "t"): return "\t"
			case UInt8(ascii: "u"):
				let unit = try hexUnit()
				switch unit {
				case 0xD800...0xDBFF:
					guard bytes[index...].starts(with: [UInt8(ascii: "\\"), UInt8(ascii: "u")]) else {
						throw .invalid(offset: index)
					}
					index += 2
					let low = try hexUnit()
					guard (0xDC00...0xDFFF).contains(low),
						let scalar = Unicode.Scalar(0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00))
					else { throw .invalid(offset: index) }
					return scalar
				case 0xDC00...0xDFFF:
					throw .invalid(offset: index)
				default:
					guard let scalar = Unicode.Scalar(unit) else { throw .invalid(offset: index) }
					return scalar
				}
			default:
				throw .invalid(offset: index - 1)
			}
		}

		private mutating func hexUnit() throws(ParseError) -> UInt32 {
			guard index + 4 <= bytes.count else { throw .invalid(offset: index) }
			var unit: UInt32 = 0
			for byte in bytes[index..<index + 4] {
				let digit: UInt8
				switch byte {
				case UInt8(ascii: "0")...UInt8(ascii: "9"): digit = byte - UInt8(ascii: "0")
				case UInt8(ascii: "a")...UInt8(ascii: "f"): digit = byte - UInt8(ascii: "a") + 10
				case UInt8(ascii: "A")...UInt8(ascii: "F"): digit = byte - UInt8(ascii: "A") + 10
				default: throw .invalid(offset: index)
				}
				unit = unit << 4 | UInt32(digit)
			}
			index += 4
			return unit
		}

		private mutating func number() throws(ParseError) -> String {
			let start = index
			if peek(UInt8(ascii: "-")) { index += 1 }
			if peek(UInt8(ascii: "0")) {
				index += 1
			} else {
				guard digits() > 0 else { throw .invalid(offset: start) }
			}
			if peek(UInt8(ascii: ".")) {
				index += 1
				guard digits() > 0 else { throw .invalid(offset: index) }
			}
			if peek(UInt8(ascii: "e")) || peek(UInt8(ascii: "E")) {
				index += 1
				if peek(UInt8(ascii: "+")) || peek(UInt8(ascii: "-")) { index += 1 }
				guard digits() > 0 else { throw .invalid(offset: index) }
			}
			return String(decoding: bytes[start..<index], as: UTF8.self)
		}

		private mutating func digits() -> Int {
			let start = index
			while index < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[index]) { index += 1 }
			return index - start
		}

		private mutating func literal(_ word: String) throws(ParseError) {
			let expected = Array(word.utf8)
			guard bytes[index...].starts(with: expected) else { throw .invalid(offset: index) }
			index += expected.count
		}

		private mutating func enter() throws(ParseError) {
			depth += 1
			guard depth <= LPMConfigJSON.maximumDepth else { throw .tooDeep }
		}

		private mutating func expect(_ byte: UInt8) throws(ParseError) {
			guard peek(byte) else { throw .invalid(offset: index) }
			index += 1
		}

		private func peek(_ byte: UInt8) -> Bool {
			index < bytes.count && bytes[index] == byte
		}

		private mutating func skipWhitespace() {
			while index < bytes.count {
				switch bytes[index] {
				case 0x20, 0x09, 0x0A, 0x0D: index += 1
				default: return
				}
			}
		}
	}
}
