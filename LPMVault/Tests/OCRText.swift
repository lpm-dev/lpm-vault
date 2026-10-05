import Foundation
import Testing

/// Vision text that tolerates glyph confusions which differ between local
/// machines and CI runners: `i`/`j`/`l`/`1`/`I`/`|`, underscores read as
/// spaces, and widened gaps in monospaced text. Both sides are normalized the
/// same way, so whole words must still be present.
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
			case "i", "j", "J", "1", "|", "I": "l"
			case "_": " "
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
		#expect(OCRText("Connect to the Ipm CLI").contains("Connect to the LPM CLI"))
		#expect(OCRText("1pm  env   list").contains("lpm env list"))
		#expect(OCRText("UUID V4").contains("UUID v4"))
		#expect(OCRText("All variables CLI API URL PORT").contains("API_URL"))
		#expect(OCRText("unsaved edlts · smart vlews").contains("unsaved edits · smart views"))
	}

	@Test("different words do not match")
	func rejectsDifferentWords() {
		#expect(!OCRText("project-target").contains("project-source"))
		#expect(!OCRText("lpm dev").contains("lpm run"))
		#expect(!OCRText("API KEY").contains("API_URL"))
	}
}
