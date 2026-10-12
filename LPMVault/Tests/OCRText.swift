import Foundation
import Testing

/// Vision text that tolerates glyph confusions which differ between local
/// machines and CI runners: `i`/`j`/`l`/`1`/`I`/`|`, `y`/`v`, underscores read
/// as spaces, periods dropped, curly apostrophes, widened gaps in monospaced
/// text, and Cyrillic or Greek letters that look like Latin ones, which CI's
/// CPU-only recognizer reads in short capitalized words such as "ОТР". Both
/// sides are normalized the same way, so whole words must still be present.
struct OCRText {
	private let normalized: String

	init(_ recognized: String) {
		normalized = Self.normalize(recognized)
	}

	func contains(_ expected: String) -> Bool {
		normalized.contains(Self.normalize(expected))
	}

	/// Where `label` is in a recognized line, tolerating the glyph confusions
	/// character for character, so the range is the line's own. Letter case
	/// counts unless `options` ignore it, as for an exact search.
	static func range(of label: String, in line: String, options: String.CompareOptions = []) -> Range<String.Index>? {
		if let exact = line.range(of: label, options: options) { return exact }
		let ignoresCase = options.contains(.caseInsensitive)
		let glyph = { (character: Character) -> Character in
			let folded = confusable(latin(character))
			return ignoresCase ? Character(folded.lowercased()) : folded
		}
		let text = Array(line), target = label.map(glyph)
		guard !target.isEmpty, text.count >= target.count else { return nil }
		let folded = text.map(glyph)
		for start in 0...(folded.count - target.count) where folded[start..<(start + target.count)].elementsEqual(target) {
			let lower = line.index(line.startIndex, offsetBy: start)
			return lower..<line.index(lower, offsetBy: target.count)
		}
		return nil
	}

	/// The Latin letter a Cyrillic or Greek one is drawn the same as; any other character as it is.
	private static func latin(_ character: Character) -> Character {
		lookalikes[character] ?? character
	}

	private static let lookalikes: [Character: Character] = [
		"А": "A", "В": "B", "Е": "E", "К": "K", "М": "M", "Н": "H", "О": "O", "Р": "P", "С": "C", "Т": "T", "Х": "X", "У": "Y",
		"Ѕ": "S", "І": "I", "Ј": "J", "а": "a", "е": "e", "о": "o", "р": "p", "с": "c", "х": "x", "у": "y", "ѕ": "s", "і": "i", "ј": "j",
		"Α": "A", "Β": "B", "Ε": "E", "Ζ": "Z", "Η": "H", "Ι": "I", "Κ": "K", "Μ": "M", "Ν": "N", "Ο": "O", "Ρ": "P", "Τ": "T",
		"Υ": "Y", "Χ": "X", "ο": "o", "ρ": "p",
	]

	/// A character with the glyphs runners confuse it with made one.
	private static func confusable(_ character: Character) -> Character {
		switch character {
		case "i", "j", "J", "1", "|", "I": "l"
		case "y": "v"
		case "Y": "V"
		case "f": "t"
		case "p": "o"
		case "_": " "
		case "’", "‘": "'"
		default: character
		}
	}

	private static func normalize(_ text: String) -> String {
		// Folded after lowercasing, so a letter folds the same in either case.
		// Look-alikes become Latin before lowercasing, which would turn some into other letters, such as Greek Τ into τ.
		let mapped = String(text.map(latin)).lowercased().compactMap { character -> Character? in character == "." || character == "," ? nil : confusable(character) }
		return String(mapped).replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
	}
}

@Suite("OCR text matching")
struct OCRTextTests {
	@Test("glyph confusions seen on CI runners still match the expected words")
	func toleratesRunnerGlyphConfusions() {
		let titleBar = OCRText("• • LPM Vault — proiect-sourcel • Connect ci ii v Locall • Lock *L")
		#expect(titleBar.contains("LPM Vault"))
		#expect(titleBar.contains("project-source"))
		#expect(OCRText("Connect to the Ipm CLI").contains("Connect to the LPM CLI"))
		#expect(OCRText("1pm  env   list").contains("lpm env list"))
		#expect(OCRText("UUID V4").contains("UUID v4"))
		#expect(OCRText("All variables CLI API URL PORT").contains("API_URL"))
		#expect(OCRText("unsaved edlts · smart vlews").contains("unsaved edits · smart views"))
		#expect(OCRText("2 declared kevs · enforced bv LPM CLII").contains("enforced by LPM CLI"))
		#expect(OCRText("8 The default doesn’t match the format").contains("The default doesn't match the format."))
		#expect(OCRText("STORED. NOT DECLARED . 1 in the Kevchain but not in lom.ison").contains("STORED, NOT DECLARED"))
		#expect(OCRText("Yours: detaut 2080. Theirs: detault 4000").contains("Theirs: default 4000"))
		#expect(OCRText("url(schemas/baselson url httos onlv").contains("https only"))
		#expect(!OCRText("Theirs: default 4000").contains("Theirs: default 400 0"))
		let line = "Cl storage  secret / variable"
		#expect(OCRText.range(of: "CI storage", in: line).map { String(line[$0]) } == "Cl storage", "A label is found in the line as read")
	}

	@Test("Cyrillic and Greek letters drawn like Latin ones match them, as CI's recognizer reads short words")
	func toleratesLookalikeScripts() {
		// "OTP" and "PORT" as CI's CPU-only recognizer read them, with Cyrillic О and Р.
		#expect(OCRText("Search keys\n\u{41E}T\u{420}\nPORT").contains("OTP"))
		#expect(OCRText("\u{420}\u{41E}RT").contains("PORT"))
		#expect(OCRText("\u{39F}\u{3A4}\u{3A1}").contains("OTP"), "Greek capitals too")
		let line = "\u{420}\u{41E}RT ×"
		#expect(OCRText.range(of: "PORT", in: line).map { String(line[$0]) } == "\u{420}\u{41E}RT", "A label is found in the line as read")
		#expect(!OCRText("\u{41E}T\u{420}").contains("OTA"))
	}

	@Test("different words do not match")
	func rejectsDifferentWords() {
		#expect(!OCRText("project-target").contains("project-source"))
		#expect(!OCRText("lpm dev").contains("lpm run"))
		#expect(!OCRText("API KEY").contains("API_URL"))
	}
}

@Suite("Native UI test placement")
struct NativeUITestPlacementTests {
	@Test("a test outside the UI suite that opens a test window or reads text fails")
	func uiOutsideTheSuiteFails() {
		withKnownIssue { RenderedText.requireUISuite() }
	}
}
