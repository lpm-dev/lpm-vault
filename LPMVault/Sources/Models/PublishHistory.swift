import CryptoKit
import Foundation

/// What this Mac last published to one destination. It stays on this Mac and
/// holds keyed fingerprints of values, never the values.
struct PublishHistory: Equatable, Sendable {
	struct Key: Equatable, Sendable {
		/// The value's fingerprint; see `PublishFingerprint`.
		let fingerprint: Data
		let publishedAt: Date
		/// The platform's ID for the variable the publish wrote.
		let remoteID: String?
		/// When the platform says that variable last changed, as of the publish.
		let remoteUpdatedAt: Date?
		/// Whether it was stored so its value can't be read back.
		let publishedAsSecret: Bool

		init(fingerprint: Data, publishedAt: Date, remoteID: String?, remoteUpdatedAt: Date?, publishedAsSecret: Bool) {
			self.fingerprint = fingerprint
			self.publishedAt = PublishTimestamp.normalized(publishedAt)
			self.remoteID = remoteID
			self.remoteUpdatedAt = remoteUpdatedAt.map(PublishTimestamp.normalized)
			self.publishedAsSecret = publishedAsSecret
		}
	}

	/// One key a publish wrote, as the platform reported it.
	struct Published: Equatable, Sendable {
		let key: String
		let fingerprint: Data
		let remoteID: String?
		let remoteUpdatedAt: Date?
		let publishedAsSecret: Bool
	}

	/// A platform record a publish moved forward by writing another part of
	/// it, such as a Netlify variable's value for another deploy context.
	/// A destination whose history last saw the record at `from` sees it at
	/// `to` now, with nothing of its own changed.
	struct Advance: Equatable, Sendable {
		let key: String
		let from: Date
		let to: Date
		/// The platform's IDs for the record's parts before the write, each
		/// with its ID after, which may be new even for a part left as it was.
		let remoteIDs: [String: String]

		init(key: String, from: Date, to: Date, remoteIDs: [String: String]) {
			self.key = key
			self.from = PublishTimestamp.normalized(from)
			self.to = PublishTimestamp.normalized(to)
			self.remoteIDs = remoteIDs
		}
	}

	/// When this Mac last published to the destination; nil before its first publish.
	var publishedAt: Date?
	/// The last publish of each key, by name.
	var keys: [String: Key]

	init(publishedAt: Date? = nil, keys: [String: Key] = [:]) {
		self.publishedAt = publishedAt.map(PublishTimestamp.normalized)
		self.keys = keys
	}

	static let maximumKeys = 4_096

	/// The history after a publish that wrote `published` at `date`. Keys
	/// the publish didn't write keep their earlier record unless they're in
	/// `forgotten`. Over the limit, the records published longest ago go
	/// first, and this publish's records only when it alone is too large.
	/// `publishedAt` always moves forward, so each publish's records carry a
	/// time of their own.
	func recording(_ published: [Published], forgetting forgotten: Set<String>, at date: Date) -> PublishHistory {
		let date = publishedAt.map { PublishTimestamp.next(after: $0, at: date) } ?? PublishTimestamp.normalized(date)
		let written = Set(published.lazy.map(\.key))
		var keys = self.keys.filter { !forgotten.contains($0.key) && !written.contains($0.key) }
		let room = Self.maximumKeys - min(written.count, Self.maximumKeys)
		if keys.count > room {
			let oldest = keys.sorted { lhs, rhs in
				lhs.value.publishedAt == rhs.value.publishedAt ? lhs.key < rhs.key : lhs.value.publishedAt < rhs.value.publishedAt
			}
			for (key, _) in oldest.prefix(keys.count - room) { keys.removeValue(forKey: key) }
		}
		for item in published.sorted(by: { $0.key < $1.key }).prefix(Self.maximumKeys) {
			keys[item.key] = Key(
				fingerprint: item.fingerprint,
				publishedAt: date,
				remoteID: item.remoteID,
				remoteUpdatedAt: item.remoteUpdatedAt,
				publishedAsSecret: item.publishedAsSecret
			)
		}
		return PublishHistory(publishedAt: date, keys: keys)
	}

	/// The history with each record that last saw its platform record at an
	/// advance's `from`, through a part the write kept, moved to its `to` and
	/// that part's ID now. A record that saw another time, or a part the
	/// write didn't keep, stays as it was, so a change someone else made still shows.
	func advancing(_ advances: [Advance]) -> PublishHistory {
		var history = self
		for advance in advances {
			guard let record = keys[advance.key], record.remoteUpdatedAt == advance.from,
				let seen = record.remoteID, let now = advance.remoteIDs[seen]
			else { continue }
			history.keys[advance.key] = Key(
				fingerprint: record.fingerprint, publishedAt: record.publishedAt, remoteID: now,
				remoteUpdatedAt: advance.to, publishedAsSecret: record.publishedAsSecret)
		}
		return history
	}

	/// The history without its `count` oldest records, for fitting a byte budget.
	func droppingOldest(_ count: Int) -> PublishHistory {
		guard count > 0 else { return self }
		let oldest = keys.sorted { lhs, rhs in
			lhs.value.publishedAt == rhs.value.publishedAt ? lhs.key < rhs.key : lhs.value.publishedAt < rhs.value.publishedAt
		}
		var history = self
		for (key, _) in oldest.prefix(count) { history.keys.removeValue(forKey: key) }
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
		withUnsafeBytes(of: destination.uuid) { authenticator.update(data: $0) }
		for var field in [key, value] {
			field.withUTF8 { bytes in
				withUnsafeBytes(of: UInt64(bytes.count).bigEndian) { authenticator.update(data: $0) }
				authenticator.update(data: UnsafeRawBufferPointer(bytes))
			}
		}
		return Data(authenticator.finalize())
	}
}
