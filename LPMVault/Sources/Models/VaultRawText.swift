import Foundation

/// An environment as Raw text shows it: a `KEY=value` line for each key, in
/// the order given, with each value masked unless it's shown. A shown value
/// is written as `EnvFileCodec.formatLine` writes it, so each key is exactly
/// one line, whatever its value holds.
struct VaultRawText: Equatable {
	struct Line: Equatable {
		let key: String
		/// The line's text in UTF-16 units, as AppKit counts, without its line break.
		let range: NSRange
		let isShown: Bool
	}

	static let mask = "••••••••••••"

	let string: String
	let lines: [Line]

	/// Keys without a `value` have no line.
	init(keys: [String], isShown: (String) -> Bool, value: (String) -> String?) {
		var string = ""
		var lines: [Line] = []
		lines.reserveCapacity(keys.count)
		var location = 0
		for key in keys {
			guard let stored = value(key) else { continue }
			let shown = isShown(key)
			let text = shown ? EnvFileCodec.formatLine(key: key, value: stored) : key + "=" + Self.mask
			if !lines.isEmpty {
				string.append("\n")
				location += 1
			}
			let length = text.utf16.count
			lines.append(Line(key: key, range: NSRange(location: location, length: length), isShown: shown))
			string.append(text)
			location += length
		}
		self.string = string
		self.lines = lines
	}

	/// The lines that any of `ranges` covers a character of, in order, each
	/// once. A range that covers only a line's break doesn't touch the line.
	func lines(touchedBy ranges: [NSRange]) -> [Line] {
		var touched = IndexSet()
		for range in ranges where range.length > 0 && range.location != NSNotFound {
			let end = NSMaxRange(range)
			var index = firstLine(endingAfter: range.location)
			while index < lines.count, lines[index].range.location < end {
				touched.insert(index)
				index += 1
			}
		}
		return touched.map { lines[$0] }
	}

	/// The first line whose text ends after `location`, by binary search.
	private func firstLine(endingAfter location: Int) -> Int {
		var low = 0
		var high = lines.count
		while low < high {
			let middle = (low + high) / 2
			if NSMaxRange(lines[middle].range) <= location {
				low = middle + 1
			} else {
				high = middle
			}
		}
		return low
	}
}
