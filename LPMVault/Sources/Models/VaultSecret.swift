import Foundation

struct VaultSecret: Identifiable, Hashable {
	var id: String { key }
	let key: String
	var value: String
}
