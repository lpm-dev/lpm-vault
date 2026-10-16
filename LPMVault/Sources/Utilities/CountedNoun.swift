extension Int {
	/// The count with its noun, plural unless the count is one: "1 key", "3 keys".
	func counted(_ noun: String) -> String {
		"\(self) \(noun)\(self == 1 ? "" : "s")"
	}
}
