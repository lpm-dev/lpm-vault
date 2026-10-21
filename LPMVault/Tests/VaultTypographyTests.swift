import Foundation
import Testing

@Suite("Vault typography")
struct VaultTypographyTests {
	/// The views that may set text in the code font, and how many times:
	/// revealed secret values and the fields that edit them, such as the box
	/// pasted variables are edited in, Raw text's lines, and Connect CLI's
	/// commands and lpm.json. Everything else uses the system font.
	private static let codeFontUses: [String: Int] = [
		"VaultDesignSystem.swift": 1,
		"VaultRawTextView.swift": 2,
		"VaultRawTextReviewSheet.swift": 1,
		"AddVariableSheet.swift": 1,
		"VaultInspectorView.swift": 1,
		"EnvFileImportReviewSheet.swift": 1,
		"EnvImportSource.swift": 2,
		"ConnectCLISheet.swift": 4,
	]

	@Test("monospaced type appears only for revealed secret values, Raw text and Connect CLI's code")
	func monospacedOnlyWhereAllowed() throws {
		let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appending(path: "Sources")
		let enumerator = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
		let files = enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
		#expect(files.count > 50, "Read the app's sources from \(sources.path)")
		var uses: [String: Int] = [:]
		var monospacedFonts: [String] = []
		for file in files {
			let text = try String(contentsOf: file, encoding: .utf8)
			let name = file.lastPathComponent
			uses[name] = ["VaultTypography.code(", "VaultTypography.codeNSFont("].reduce(0) { $0 + text.components(separatedBy: $1).count - 1 }
			for pattern in ["design: .monospaced", ".monospaced()", "monospacedSystemFont", "VaultTypography.mono("] {
				let count = text.components(separatedBy: pattern).count - 1
				// The code font's own definitions, for SwiftUI and for AppKit, are the monospaced fonts the app makes.
				let allowed = name == "VaultDesignSystem.swift" && ["design: .monospaced", "monospacedSystemFont"].contains(pattern) ? 1 : 0
				if count != allowed { monospacedFonts.append("\(name): \(pattern) ×\(count)") }
			}
		}
		#expect(monospacedFonts.isEmpty, "\(monospacedFonts)")
		#expect(uses.filter { $0.value > 0 } == Self.codeFontUses)
	}
}
