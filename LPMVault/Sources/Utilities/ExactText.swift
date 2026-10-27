import Foundation

/// Text compared byte for byte. Swift's `==` compares strings by canonical
/// equivalence, under which a value can equal one holding other characters,
/// such as U+2000 and U+2002, so a check, a save or a conflict test of one
/// would stand for the other.
struct ExactText: Hashable, Sendable {
	var text: String

	init(_ text: String) {
		self.text = text
	}

	static func == (lhs: Self, rhs: Self) -> Bool {
		let left = lhs.text.utf8, right = rhs.text.utf8
		guard left.count == right.count else { return false }
		guard !left.isEmpty else { return true }
		let contiguous = left.withContiguousStorageIfAvailable { left in
			right.withContiguousStorageIfAvailable { right in memcmp(left.baseAddress!, right.baseAddress!, left.count) == 0 }
		}
		if case .some(.some(let same)) = contiguous { return same }
		return left.elementsEqual(right)
	}

	func hash(into hasher: inout Hasher) {
		let bytes = text.utf8
		hasher.combine(bytes.count)
		let hashed: Void? = bytes.withContiguousStorageIfAvailable { hasher.combine(bytes: UnsafeRawBufferPointer($0)) }
		if hashed == nil {
			for byte in bytes { hasher.combine(byte) }
		}
	}
}

extension Dictionary where Key == String {
	/// Whether both hold the same keys, byte for byte, with values that `same` matches.
	func isExactly(_ other: Self, by same: (Value, Value) -> Bool) -> Bool {
		count == other.count && allSatisfy { key, value in
			guard let index = other.index(forKey: key) else { return false }
			let (otherKey, otherValue) = other[index]
			return ExactText(key) == ExactText(otherKey) && same(value, otherValue)
		}
	}
}

extension Dictionary where Key == String, Value == String {
	/// Whether both hold the same keys and values, byte for byte.
	func isExactly(_ other: Self) -> Bool {
		isExactly(other) { ExactText($0) == ExactText($1) }
	}
}

extension Dictionary where Key == String, Value == [String: String] {
	/// Whether both hold the same environments, keys and values, byte for byte.
	func isExactly(_ other: Self) -> Bool {
		isExactly(other) { $0.isExactly($1) }
	}
}
