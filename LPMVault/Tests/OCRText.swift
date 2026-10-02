import Foundation
import Testing

/// Vision text that tolerates glyph confusions which differ between local
/// machines and CI runners: `j`/`i`, `l`/`1`/`I`/`|`, and widened gaps in
/// monospaced text. Both sides are normalized the same way, so whole words
/// must still be present.
struct OCRText {
	private let normalized: String

	init(_ recognized: String) {
		normalized = Self.normalize(recognized)
	}

	func contains(_ expected: String) -> Bool {
		normalized.contains(Self.normalize(expected))
	}

	private static func normalize(_ text: String) -> String {
		let mapped = text.map { character -> Character in
			switch character {
			case "j", "J": "i"
			case "1", "|", "I": "l"
			default: character
			}
		}
		return String(mapped).lowercased().replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
	}
}

@Suite("OCR text matching")
struct OCRTextTests {
	@Test("glyph confusions seen on CI runners still match the expected words")
	func toleratesRunnerGlyphConfusions() {
		let titleBar = OCRText("• • LPM Vault — proiect-sourcel • Connect ci ii v Locall • Lock *L")
		#expect(titleBar.contains("LPM Vault"))
		#expect(titleBar.contains("project-source"))
		#expect(OCRText("Connect to the Ipm CLI").contains("Connect to the lpm CLI"))
		#expect(OCRText("1pm  env   list").contains("lpm env list"))
		#expect(OCRText("UUID V4").contains("UUID v4"))
	}

	@Test("different words do not match")
	func rejectsDifferentWords() {
		#expect(!OCRText("project-target").contains("project-source"))
		#expect(!OCRText("lpm dev").contains("lpm run"))
	}
}
