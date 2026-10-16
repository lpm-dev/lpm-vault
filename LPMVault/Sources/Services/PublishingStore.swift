import CryptoKit
import Foundation

enum PublishingStoreError: Error, Equatable, Sendable, CustomStringConvertible {
	case keychain(KeychainError)
	/// The stored record isn't one this version can read.
	case unreadable
	/// A newer LPM Vault wrote the record, so this version leaves it alone.
	case newerVersion
	case invalidVault
	case invalidDestination(PublishDestinationInvalidity)
	/// Another of the vault's destinations already publishes to the same place.
	case duplicateLocation(existing: UUID)
	case limitReached
	case tooLarge
	/// The destination was removed while the publish ran.
	case destinationRemoved
	/// The destination was pointed somewhere else while the publish ran.
	case destinationMoved
	/// The destination changed after it was read, as when another publish saved it first.
	case destinationChanged

	var description: String {
		switch self {
		case .keychain(let error): error.description
		case .unreadable: "The saved publish destinations can't be read."
		case .newerVersion: "A newer LPM Vault saved these publish destinations."
		case .invalidVault: "The env project's ID can't hold publish destinations."
		case .invalidDestination: "The publish destination isn't valid."
		case .duplicateLocation: "Another destination already publishes there."
		case .limitReached: "This env project has the most publish destinations it can hold."
		case .tooLarge: "The publish destinations are too large to save."
		case .destinationRemoved: "The publish destination was removed."
		case .destinationMoved: "The publish destination was changed."
		case .destinationChanged: "The publish destination changed meanwhile."
		}
	}
}

/// A vault's publish destinations, and this Mac's history of publishing to
/// each, kept in the app's own Keychain group: one item for the vault's
/// destinations and one per destination's history. One actor serializes
/// every read-modify-write, so concurrent edits can't lose each other's changes.
actor PublishingStore {
	private let service: any KeychainServiceProtocol
	/// Keychain calls block until the security daemon answers, so the store
	/// runs on a queue of its own: blocking on the cooperative pool would hold
	/// up every other task waiting for a thread.
	private let queue = DispatchSerialQueue(label: "dev.lpm.vault.publishing", qos: .userInitiated)

	nonisolated var unownedExecutor: UnownedSerialExecutor {
		queue.asUnownedSerialExecutor()
	}

	init(service: any KeychainServiceProtocol) {
		self.service = service
	}

	// MARK: - Destinations

	func destinations(of vaultID: String) -> Result<[PublishDestination], PublishingStoreError> {
		Result { try readDestinations(of: vaultID) }.mapError(Self.storeError)
	}

	/// Adds `destination`, or replaces the one with its ID, moving its
	/// `updatedAt` past the stored one's. Pointing a destination somewhere
	/// else drops its history, which described the old place, before the new
	/// place is saved, so a failure leaves neither.
	///
	/// With `expected`, the destination as it was read, nothing is saved when
	/// the stored one has changed or gone since.
	func save(
		_ destination: PublishDestination,
		to vaultID: String,
		replacing expected: PublishDestination? = nil
	) -> Result<[PublishDestination], PublishingStoreError> {
		Result {
			if let invalidity = destination.invalidity { throw PublishingStoreError.invalidDestination(invalidity) }
			var destinations = try readDestinations(of: vaultID)
			if let other = destinations.first(where: { $0.id != destination.id && $0.target.location == destination.target.location }) {
				throw PublishingStoreError.duplicateLocation(existing: other.id)
			}
			if let index = destinations.firstIndex(where: { $0.id == destination.id }) {
				let stored = destinations[index]
				if let expected, stored != expected { throw PublishingStoreError.destinationChanged }
				guard destination != stored else { return destinations }
				if stored.target.location != destination.target.location {
					try service.deleteAppItem(.publishing, account: Self.historyAccount(vaultID, destination.id)).get()
				}
				var replacement = destination
				replacement.updatedAt = PublishTimestamp.next(after: stored.updatedAt, at: destination.updatedAt)
				destinations[index] = replacement
			} else {
				guard expected == nil else { throw PublishingStoreError.destinationRemoved }
				guard destinations.count < PublishingRecords.maximumDestinations else { throw PublishingStoreError.limitReached }
				destinations.append(destination)
			}
			try writeDestinations(destinations, of: vaultID)
			return destinations
		}.mapError(Self.storeError)
	}

	/// Removes the destination and this Mac's history of it.
	func remove(_ id: UUID, from vaultID: String) -> Result<[PublishDestination], PublishingStoreError> {
		Result {
			var destinations = try readDestinations(of: vaultID)
			if destinations.contains(where: { $0.id == id }) {
				destinations.removeAll { $0.id == id }
				try writeDestinations(destinations, of: vaultID)
			}
			try service.deleteAppItem(.publishing, account: Self.historyAccount(vaultID, id)).get()
			return destinations
		}.mapError(Self.storeError)
	}

	// MARK: - History

	/// This Mac's history of publishing to the destination. A damaged
	/// history reads as none, since it's only a record of past publishes.
	func history(of destination: UUID, in vaultID: String) -> Result<PublishHistory, PublishingStoreError> {
		Result { try readHistory(of: destination, in: vaultID) }.mapError(Self.storeError)
	}

	/// Records a publish to the destination and history as they're stored
	/// now: the person's choices from the review, and the keys the platform
	/// accepted. Fails, recording nothing, when the destination was removed
	/// or pointed elsewhere while the publish ran.
	///
	/// `advances` move forward the histories of this Mac's other
	/// destinations, in any vault, whose places share the platform's records
	/// with this one, so this publish doesn't read there as someone else's change.
	func recordPublish(
		_ published: [PublishHistory.Published],
		to destination: UUID,
		at location: PublishTarget.Location,
		choices: PublishPlan.Choices,
		advancing advances: [PublishHistory.Advance] = [],
		of vaultID: String,
		at date: Date
	) -> Result<PublishDestination, PublishingStoreError> {
		Result {
			var destinations = try readDestinations(of: vaultID)
			guard let index = destinations.firstIndex(where: { $0.id == destination }) else {
				throw PublishingStoreError.destinationRemoved
			}
			guard destinations[index].target.location == location else { throw PublishingStoreError.destinationMoved }
			let updated = choices.applied(to: destinations[index], at: date)
			if updated != destinations[index] {
				if let invalidity = updated.invalidity { throw PublishingStoreError.invalidDestination(invalidity) }
				destinations[index] = updated
				try writeDestinations(destinations, of: vaultID)
			}
			let history = try readHistory(of: destination, in: vaultID)
			let recorded = history.recording(published, forgetting: choices.forgottenRecords(in: history), at: date)
			try writeHistory(recorded, of: destination, in: vaultID)
			if !advances.isEmpty, let shared = location.sharedRecords {
				advanceHistories(sharing: shared, except: destination, in: vaultID, destinations: destinations, by: advances)
			}
			return updated
		}.mapError(Self.storeError)
	}

	/// Moves forward the histories of every destination on this Mac whose
	/// place shares `shared` records, but `destination`. Another vault's
	/// destinations are decoded only when their record mentions what holds the
	/// records, one vault at a time. It's best effort: a history left behind
	/// reads as changed on the platform, which only costs a review.
	private func advanceHistories(
		sharing shared: PublishTarget.SharedRecords,
		except destination: UUID,
		in vaultID: String,
		destinations: [PublishDestination],
		by advances: [PublishHistory.Advance]
	) {
		advance(destinations, of: vaultID, sharing: shared, except: destination, by: advances)
		let mention = Data("\"\(shared.ownerID)\"".utf8)
		for account in (try? service.appItemAccounts(.publishing).get()) ?? [] where account.hasPrefix(Self.destinationsPrefix) {
			guard let other = Self.vault(ofAccount: account), other != vaultID,
				let data = try? service.readAppItem(.publishing, account: account).get(), data.range(of: mention) != nil,
				case .success(let stored) = PublishingRecords.decodeDestinations(data, vaultID: other)
			else { continue }
			advance(stored, of: other, sharing: shared, except: destination, by: advances)
		}
	}

	private func advance(
		_ destinations: [PublishDestination],
		of vaultID: String,
		sharing shared: PublishTarget.SharedRecords,
		except destination: UUID,
		by advances: [PublishHistory.Advance]
	) {
		for other in destinations where other.id != destination && other.target.location.sharedRecords == shared {
			guard let earlier = try? readHistory(of: other.id, in: vaultID) else { continue }
			let advanced = earlier.advancing(advances)
			if advanced != earlier { try? writeHistory(advanced, of: other.id, in: vaultID) }
		}
	}

	/// The key fingerprints are made with, created the first time it's needed.
	/// The item under this account is always the raw 32-byte key; another
	/// format would use another account, so a damaged item can be replaced.
	func fingerprintKey() -> Result<SymmetricKey, PublishingStoreError> {
		Result {
			let byteCount = SymmetricKeySize.bits256.bitCount / 8
			if let data = try service.readAppItem(.publishing, account: Self.fingerprintKeyAccount).get() {
				if data.count == byteCount { return SymmetricKey(data: data) }
				// Damaged: earlier fingerprints then read as changed values, which only costs a review.
				let key = SymmetricKey(size: .bits256)
				try service.writeAppItem(.publishing, account: Self.fingerprintKeyAccount, data: key.withUnsafeBytes { Data($0) }).get()
				return key
			}
			let key = SymmetricKey(size: .bits256)
			if try service.insertAppItem(.publishing, account: Self.fingerprintKeyAccount, data: key.withUnsafeBytes { Data($0) }).get() {
				return key
			}
			// Another process added one first; use it.
			guard let data = try service.readAppItem(.publishing, account: Self.fingerprintKeyAccount).get(), data.count == byteCount else {
				throw PublishingStoreError.unreadable
			}
			return SymmetricKey(data: data)
		}.mapError(Self.storeError)
	}

	// MARK: - Following the vault

	/// Points the vault's destinations from `old` at the environment's new name.
	func renameEnvironment(_ old: String, to new: String, in vaultID: String) -> Result<Void, PublishingStoreError> {
		updateDestinations(of: vaultID) { destination in
			guard destination.sourceEnvironment == old else { return false }
			destination.sourceEnvironment = new
			return true
		}
	}

	/// Carries a renamed key's exclusion to its new name, in the destinations
	/// that publish from `environments`, the ones that had the key.
	func renameKey(_ old: String, to new: String, sourcedFrom environments: Set<String>, in vaultID: String) -> Result<Void, PublishingStoreError> {
		guard !environments.isEmpty else { return .success(()) }
		return updateDestinations(of: vaultID) { destination in
			guard environments.contains(destination.sourceEnvironment) else { return false }
			let wasExcluded = destination.excludedKeys.contains(old)
			guard wasExcluded || destination.excludedKeys.contains(new) else { return false }
			destination.excludedKeys.remove(old)
			if wasExcluded { destination.excludedKeys.insert(new) } else { destination.excludedKeys.remove(new) }
			return true
		}
	}

	/// Removes the destinations that publish from a deleted environment, so
	/// a later environment with its name doesn't inherit them.
	func removeDestinations(sourcedFrom environment: String, in vaultID: String) -> Result<Void, PublishingStoreError> {
		Result {
			let destinations = try readDestinations(of: vaultID)
			let removed = destinations.filter { $0.sourceEnvironment == environment }
			guard !removed.isEmpty else { return }
			try writeDestinations(destinations.filter { $0.sourceEnvironment != environment }, of: vaultID)
			for destination in removed {
				try service.deleteAppItem(.publishing, account: Self.historyAccount(vaultID, destination.id)).get()
			}
		}.mapError(Self.storeError)
	}

	/// Deletes the records, whatever version wrote them, of every vault
	/// whose local copy is gone, or only of `candidates` when given. Listing,
	/// checking and deleting are one step of this actor, so nothing saved
	/// for a vault recreated meanwhile can be deleted: its save waits for
	/// the step to end.
	func deleteOrphanedRecords(among candidates: Set<String>? = nil) -> Result<Void, PublishingStoreError> {
		Result {
			var accountsByVault: [String: [String]] = [:]
			for account in try service.appItemAccounts(.publishing).get() {
				guard let vault = Self.vault(ofAccount: account), candidates?.contains(vault) ?? true else { continue }
				accountsByVault[vault, default: []].append(account)
			}
			guard !accountsByVault.isEmpty else { return }
			let existing = try service.existingVaultPayloads(vaultIds: accountsByVault.keys.sorted()).get()
			var failure: Error?
			for (vault, accounts) in accountsByVault where !existing.contains(vault) {
				for account in accounts {
					do { try service.deleteAppItem(.publishing, account: account).get() } catch { failure = failure ?? error }
				}
			}
			if let failure { throw failure }
		}.mapError(Self.storeError)
	}

	// MARK: - Records

	private func updateDestinations(
		of vaultID: String,
		_ update: (inout PublishDestination) -> Bool
	) -> Result<Void, PublishingStoreError> {
		Result {
			var destinations = try readDestinations(of: vaultID)
			var changed = false
			let now = Date()
			for index in destinations.indices {
				let previous = destinations[index].updatedAt
				guard update(&destinations[index]) else { continue }
				destinations[index].updatedAt = PublishTimestamp.next(after: previous, at: now)
				changed = true
			}
			if changed { try writeDestinations(destinations, of: vaultID) }
		}.mapError(Self.storeError)
	}

	private func readDestinations(of vaultID: String) throws -> [PublishDestination] {
		guard let data = try service.readAppItem(.publishing, account: Self.destinationsAccount(vaultID)).get() else { return [] }
		return try PublishingRecords.decodeDestinations(data, vaultID: vaultID).get()
	}

	private func writeDestinations(_ destinations: [PublishDestination], of vaultID: String) throws {
		let account = try Self.destinationsAccount(vaultID)
		guard !destinations.isEmpty else {
			try service.deleteAppItem(.publishing, account: account).get()
			return
		}
		guard let data = PublishingRecords.encode(destinations, vaultID: vaultID) else { throw PublishingStoreError.tooLarge }
		try service.writeAppItem(.publishing, account: account, data: data).get()
	}

	private func readHistory(of destination: UUID, in vaultID: String) throws -> PublishHistory {
		guard let data = try service.readAppItem(.publishing, account: Self.historyAccount(vaultID, destination)).get() else {
			return PublishHistory()
		}
		switch PublishingRecords.decodeHistory(data, destination: destination, vaultID: vaultID) {
		case .success(let history): return history
		case .failure(.newerVersion): throw PublishingStoreError.newerVersion
		case .failure(.unreadable): return PublishHistory()
		}
	}

	private func writeHistory(_ history: PublishHistory, of destination: UUID, in vaultID: String) throws {
		guard let encoded = PublishingRecords.encodeFitting(history, destination: destination, vaultID: vaultID) else {
			throw PublishingStoreError.tooLarge
		}
		try service.writeAppItem(.publishing, account: Self.historyAccount(vaultID, destination), data: encoded.data).get()
	}

	private static let fingerprintKeyAccount = "fingerprint-key.v1"
	private static let destinationsPrefix = "destinations."
	private static let historyPrefix = "history."

	/// The vault whose record `account` holds, or nil when it isn't a
	/// destinations or history account. Destination IDs have no dots, so a
	/// history account's vault is everything before its last dot.
	private static func vault(ofAccount account: String) -> String? {
		let vault: Substring
		if account.hasPrefix(destinationsPrefix) {
			vault = account.dropFirst(destinationsPrefix.count)
		} else if account.hasPrefix(historyPrefix) {
			let rest = account.dropFirst(historyPrefix.count)
			guard let separator = rest.lastIndex(of: "."), UUID(uuidString: String(rest[rest.index(after: separator)...])) != nil
			else { return nil }
			vault = rest[..<separator]
		} else {
			return nil
		}
		let vaultID = String(vault)
		return EnvValidation.isSafeVaultId(vaultID) ? vaultID : nil
	}

	private static func destinationsAccount(_ vaultID: String) throws -> String {
		guard EnvValidation.isSafeVaultId(vaultID) else { throw PublishingStoreError.invalidVault }
		return "\(destinationsPrefix)\(vaultID)"
	}

	private static func historyAccount(_ vaultID: String, _ destination: UUID) throws -> String {
		guard EnvValidation.isSafeVaultId(vaultID) else { throw PublishingStoreError.invalidVault }
		return "\(historyPrefix)\(vaultID).\(destination.uuidString.lowercased())"
	}

	private static func storeError(_ error: Error) -> PublishingStoreError {
		switch error {
		case let error as PublishingStoreError: error
		case let error as KeychainError: .keychain(error)
		case PublishingRecords.DecodingError.newerVersion: .newerVersion
		default: .unreadable
		}
	}
}
