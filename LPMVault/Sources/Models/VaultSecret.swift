import Foundation

struct VaultSecret: Identifiable, Hashable, Sendable {
	var id: String { key }
	let key: String
	var value: String
}
