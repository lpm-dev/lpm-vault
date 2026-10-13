import CryptoKit
import Foundation

/// What this Mac last published to each of a vault's destinations. It stays
/// on this Mac and holds keyed fingerprints of values, never the values.
struct PublishHistory: Equatable, Sendable {
	struct Entry: Equatable, Sendable {
		/// When this Mac last published to the destination.
		var publishedAt: Date
		/// The last publish of each key, by name.
		var keys: [String: Key]
	}

	struct Key: Equatable, Sendable {
		/// The value's fingerprint; see `PublishFingerprint`.
		let fingerprint: Data
		let publishedAt: Date
		/// The platform's ID for the variable the publish wrote.
		let remoteID: String?
		/// When the platform says that variable last changed, as of the publish.
		let remoteUpdatedAt: Date?

		init(fingerprint: Data, publishedAt: Date, remoteID: String?, remoteUpdatedAt: Date?) {
			self.fingerprint = fingerprint
			self.publishedAt = PublishTimestamp.normalized(publishedAt)
			self.remoteID = remoteID
			self.remoteUpdatedAt = remoteUpdatedAt.map(PublishTimestamp.normalized)
		}
	}

	/// One key a publish wrote, as the platform reported it.
	struct Published: Equatable, Sendable {
		let key: String
		let fingerprint: Data
		let remoteID: String?
		let remoteUpdatedAt: Date?
	}

	var entries: [UUID: Entry]

	init(entries: [UUID: Entry] = [:]) {
		self.entries = entries
	}

	static let maximumKeysPerEntry = 4_096

	/// The history after a publish to `destination` wrote `published` at
	/// `date`. Keys the publish didn't write keep their earlier record; when
	/// an entry would outgrow its limit, the records published longest ago go.
	func recording(_ published: [Published], to destination: UUID, at date: Date) -> PublishHistory {
		let date = PublishTimestamp.normalized(date)
		var entry = entries[destination] ?? Entry(publishedAt: date, keys: [:])
		entry.publishedAt = date
		for item in published {
			entry.keys[item.key] = Key(
				fingerprint: item.fingerprint,
				publishedAt: date,
				remoteID: item.remoteID,
				remoteUpdatedAt: item.remoteUpdatedAt
			)
		}
		let excess = entry.keys.count - Self.maximumKeysPerEntry
		if excess > 0 {
			let oldest = entry.keys.sorted { lhs, rhs in
				lhs.value.publishedAt == rhs.value.publishedAt ? lhs.key < rhs.key : lhs.value.publishedAt < rhs.value.publishedAt
			}
			for (key, _) in oldest.prefix(excess) { entry.keys.removeValue(forKey: key) }
		}
		var history = self
		history.entries[destination] = entry
		return history
	}
}

/// A keyed fingerprint of a published value, so a later review can tell
/// whether the value changed without storing it. The key never leaves this
/// Mac, and each fingerprint is bound to its destination and key name, so
/// equal values elsewhere don't share a fingerprint.
enum PublishFingerprint {
	static let byteCount = SHA256.byteCount
	private static let domain = Data("lpm-vault:publish-fingerprint:v1\0".utf8)

	static func of(value: String, key: String, destination: UUID, using secret: SymmetricKey) -> Data {
		var authenticator = HMAC<SHA256>(key: secret)
		authenticator.update(data: domain)
		authenticator.update(data: withUnsafeBytes(of: destination.uuid) { Data($0) })
		for field in [key, value] {
			let bytes = Data(field.utf8)
			authenticator.update(data: withUnsafeBytes(of: UInt64(bytes.count).bigEndian) { Data($0) })
			authenticator.update(data: bytes)
		}
		return Data(authenticator.finalize())
	}
}
