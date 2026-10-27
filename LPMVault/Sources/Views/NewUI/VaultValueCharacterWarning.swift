import SwiftUI

/// How a warning about characters that are hard to see reads, on screen and
/// to VoiceOver. The engine decides which characters they are; this only
/// words what it found.
enum ValueCharacterWording {
	/// The character's name as a sentence reads it, such as "zero width space".
	static func name(_ character: ValueCharacters.Character) -> String {
		character.name.lowercased()
	}

	/// Where the character is: "at character 9", "at characters 2–3, 7",
	/// "at the start" or "at the end". Spoken, a range reads "2 to 3".
	static func place(_ character: ValueCharacters.Character, spoken: Bool = false) -> String {
		switch character.kind {
		case .leadingWhitespace: return "at the start"
		case .trailingWhitespace: return "at the end"
		default:
			let listed = character.runs.reduce(0) { $0 + $1.count }
			let positions = character.runs.map { run in
				run.count == 1 ? "\(run.position)" : "\(run.position)\(spoken ? " to " : "–")\(run.position + run.count - 1)"
			}
			var text = (character.count == 1 ? "at character " : "at characters ") + positions.joined(separator: ", ")
			if listed < character.count { text += spoken ? ", and more" : ", …" }
			return text
		}
	}

	/// Such as "\u{200b} zero width space at character 9", "\u{20} space ×2
	/// at the end" or "tag characters ×3 at characters 3–5".
	static func line(_ character: ValueCharacters.Character) -> String {
		let escape = character.escape.map { "\($0) " } ?? ""
		let times = character.count > 1 ? " ×\(character.count)" : ""
		return escape + name(character) + times + " " + place(character)
	}

	/// In words, without the escape: "zero width space at character 9", or
	/// "space, 2 times, at the end".
	static func spoken(_ character: ValueCharacters.Character) -> String {
		let times = character.count > 1 ? ", \(character.count) times," : ""
		return name(character) + times + " " + place(character, spoken: true)
	}

	/// What else the engine found and didn't list, such as "2 more kinds of character".
	static func more(_ found: ValueCharacters) -> String? {
		guard found.more > 0 else { return nil }
		return found.more == 1 ? "1 more kind of character" : "\(found.more) more kinds of character"
	}

	/// Every listed character in words, then what wasn't listed.
	static func spokenList(_ found: ValueCharacters) -> String {
		(found.characters.map(spoken) + [more(found)].compactMap { $0 }).joined(separator: "; ")
	}

	/// The whole warning in words, for VoiceOver, such as "Warning: the value
	/// in production has hidden characters: zero width space at character 9."
	static func sentence(_ found: ValueCharacters, subject: String) -> String {
		"Warning: \(subject) has hidden characters: \(spokenList(found))."
	}
}

/// A warning that a value holds characters that are hard to see: which ones
/// and where, the value with them made visible while it's shown, and the
/// fixes a person can choose. It never keeps the value from being saved.
struct VaultValueCharacterWarning: View {
	let found: ValueCharacters
	/// Whose value it is, as VoiceOver reads the warning, such as "the value in production".
	var subject = "this value"
	/// The value with its hidden characters written as escapes; nil while the value is hidden.
	var shown: ShownValueCharacters?
	var onRemoveHiddenCharacters: (() -> Void)?
	var onTrimEnds: (() -> Void)?
	var disabled = false

	var body: some View {
		VStack(alignment: .leading, spacing: 4) {
			VStack(alignment: .leading, spacing: 3) {
				HStack(alignment: .firstTextBaseline, spacing: 5) {
					Image(systemName: "exclamationmark.triangle")
						.font(.system(size: 10, weight: .semibold))
					Text("Hidden characters")
						.font(.system(size: 11.5, weight: .semibold))
				}
				ForEach(Array(found.characters.enumerated()), id: \.offset) { _, character in
					characterLine(character)
				}
				if let more = ValueCharacterWording.more(found) {
					Text("and \(more)")
						.font(.system(size: 11))
				}
			}
			.foregroundStyle(VaultPalette.orangeTintText)
			.fixedSize(horizontal: false, vertical: true)
			.accessibilityElement(children: .ignore)
			.accessibilityLabel(ValueCharacterWording.sentence(found, subject: subject))
			if let shown { preview(shown) }
			if fixesShown {
				HStack(spacing: 14) {
					if found.removable, let onRemoveHiddenCharacters {
						fixButton("Remove hidden characters", action: onRemoveHiddenCharacters)
					}
					if found.trimmable, let onTrimEnds {
						fixButton("Trim the ends", action: onTrimEnds)
					}
				}
			}
		}
	}

	private var fixesShown: Bool {
		(found.removable && onRemoveHiddenCharacters != nil) || (found.trimmable && onTrimEnds != nil)
	}

	private func characterLine(_ character: ValueCharacters.Character) -> some View {
		let rest = (character.escape == nil ? "" : " ") + ValueCharacterWording.name(character)
			+ (character.count > 1 ? " ×\(character.count)" : "") + " " + ValueCharacterWording.place(character)
		return (Text(character.escape ?? "").font(.system(size: 11, weight: .semibold))
			+ Text(rest).font(.system(size: 11)))
			.lineLimit(2)
	}

	/// The value as it is, with each escape tinted, so a person sees where each one sits.
	private func preview(_ shown: ShownValueCharacters) -> some View {
		var text = AttributedString()
		var copied = shown.text.startIndex
		for mark in shown.marks {
			guard let range = Range(mark, in: shown.text) else { continue }
			text += AttributedString(shown.text[copied..<range.lowerBound])
			var escape = AttributedString(shown.text[range])
			escape.foregroundColor = VaultPalette.orangeTintText
			escape.backgroundColor = VaultPalette.orangeTint
			text += escape
			copied = range.upperBound
		}
		text += AttributedString(shown.text[copied...])
		return Text(text)
			.font(VaultTypography.code(11))
			.foregroundStyle(VaultPalette.textSecondary)
			.lineLimit(3)
			.truncationMode(.middle)
			.padding(.horizontal, 6)
			.padding(.vertical, 3)
			.background(RoundedRectangle(cornerRadius: 5).fill(VaultPalette.neutralTint))
			.accessibilityLabel("\(subject.prefix(1).uppercased() + subject.dropFirst()) with its hidden characters shown, revealed visually")
	}

	private func fixButton(_ title: String, action: @escaping () -> Void) -> some View {
		Button(title, action: action)
			.buttonStyle(.plain)
			.font(.system(size: 11, weight: .semibold))
			.foregroundStyle(disabled ? VaultPalette.textFaint : VaultPalette.accentForeground)
			.disabled(disabled)
			.fixedSize()
			.vaultPointingHand()
	}
}
