import Foundation
import Testing

@testable import LPMVault

@Suite("Raw text lines")
struct RawTextTests {
	private static let values = [
		"", "plain", "postgres://app:s3cr3t-pw@db.internal:5432/demo", "https://api.example.com/v1?a=1&b=2", "two words",
		" padded ", "a#b", "#comment", "\"quoted\"", "'single'", "back\\slash", "$HOME", "${HOME}", "`date`", "line\nbreak",
		"cr\rhere", "tab\there", "naïve ✓ 🔑", "=leading", "trailing=", "~/path", "a;b", "*", "!bang", "a\\nb", "export",
	]

	@Test("a line reads back as its exact value, and is one line whatever the value holds", arguments: values)
	func lineRoundTrips(value: String) throws {
		let line = EnvFileCodec.formatLine(key: "KEY", value: value)
		#expect(!line.contains("\n") && !line.contains("\r"))
		#expect(try EnvFileCodec.parse(line) == ["KEY": value])
	}

	@Test("a value stays bare only when every character means itself, and is quoted otherwise")
	func lineQuotesOnlyWhatNeedsIt() {
		#expect(EnvFileCodec.formatLine(key: "URL", value: "postgres://app:pw@db:5432/demo") == "URL=postgres://app:pw@db:5432/demo")
		#expect(EnvFileCodec.formatLine(key: "EMPTY", value: "") == "EMPTY=")
		#expect(EnvFileCodec.formatLine(key: "QUERY", value: "https://x.dev/?a=1&b=2") == #"QUERY="https://x.dev/?a=1&b=2""#)
		#expect(EnvFileCodec.formatLine(key: "TILDE", value: "~/x") == #"TILDE="~/x""#)
		#expect(EnvFileCodec.formatLine(key: "LINES", value: "a\nb") == #"LINES="a\nb""#)
		#expect(EnvFileCodec.formatLine(key: "DOLLAR", value: "$PATH") == #"DOLLAR="\$PATH""#)
	}

	@Test("a POSIX shell sourcing the lines reads every value literally")
	func shellReadsLinesLiterally() throws {
		// Escapes of line breaks and tabs are this parser's; a shell's double
		// quotes have none, so values holding them aren't shell-literal.
		let values = Self.values.filter { !$0.contains(where: { "\n\r\t".contains($0) }) }
		let keys = values.indices.map { "VALUE_\($0)" }
		var script = ""
		for (key, value) in zip(keys, values) { script += EnvFileCodec.formatLine(key: key, value: value) + "\n" }
		for key in keys { script += "printf '%s\\0' \"$\(key)\"\n" }
		let process = Process()
		process.executableURL = URL(fileURLWithPath: "/bin/sh")
		process.arguments = ["-c", script]
		process.environment = ["HOME": "/home-should-not-expand", "PATH": "/usr/bin:/bin"]
		let output = Pipe()
		process.standardOutput = output
		try process.run()
		let data = output.fileHandleForReading.readDataToEndOfFile()
		process.waitUntilExit()
		#expect(process.terminationStatus == 0)
		let read = String(decoding: data, as: UTF8.self).split(separator: "\0", omittingEmptySubsequences: false).dropLast().map(String.init)
		#expect(read == values)
	}

	@Test("each stored key is one line, masked unless shown, with ranges in AppKit's units")
	func lines() {
		let values = ["A": "1", "EMOJI": "🔑 key", "BREAK": "two\nlines"]
		let text = VaultRawText(keys: ["A", "EMOJI", "BREAK", "UNSTORED"], isShown: { $0 != "A" }, value: { values[$0] })
		#expect(text.string == "A=\(VaultRawText.mask)\nEMOJI=\"🔑 key\"\nBREAK=\"two\\nlines\"")
		#expect(text.lines.map(\.key) == ["A", "EMOJI", "BREAK"])
		#expect(text.lines.map(\.isShown) == [false, true, true])
		let string = text.string as NSString
		#expect(text.lines.map { string.substring(with: $0.range) } == text.string.components(separatedBy: "\n"))
	}

	@Test("a selection touches each line it covers a character of, once and in order, but not one whose break it ends at")
	func touchedLines() {
		// "A=v\nB=v\nC=v": A is 0..<3, its break 3, B 4..<7, its break 7, C 8..<11.
		let text = VaultRawText(keys: ["A", "B", "C"], isShown: { _ in true }, value: { _ in "v" })
		func keys(_ ranges: NSRange...) -> [String] { text.lines(touchedBy: ranges).map(\.key) }
		#expect(keys(NSRange(location: 2, length: 3)) == ["A", "B"])
		#expect(keys(NSRange(location: 0, length: 4)) == ["A"])
		#expect(keys(NSRange(location: 3, length: 1)) == [])
		#expect(keys(NSRange(location: 3, length: 2)) == ["B"])
		#expect(keys(NSRange(location: 5, length: 0)) == [])
		#expect(keys(NSRange(location: 8, length: 3), NSRange(location: 0, length: 1)) == ["A", "C"])
		#expect(keys(NSRange(location: 0, length: 11), NSRange(location: 4, length: 2)) == ["A", "B", "C"])
	}
}
