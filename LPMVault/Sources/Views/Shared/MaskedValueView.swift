import SwiftUI

struct MaskedValueView: View {
	let value: String
	let isRevealed: Bool
	let maskLength: Int

	init(value: String, isRevealed: Bool, maskLength: Int = 12) {
		self.value = value
		self.isRevealed = isRevealed
		self.maskLength = maskLength
	}

	var body: some View {
		if isRevealed {
			Text(value)
				.font(.system(.body, design: .monospaced))
		} else {
			Text(String(repeating: "\u{2022}", count: maskLength))
				.font(.system(.body, design: .monospaced))
				.foregroundStyle(.secondary)
		}
	}
}
