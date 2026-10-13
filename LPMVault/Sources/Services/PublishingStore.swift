import CryptoKit
import Foundation

enum PublishingStoreError: Error, Equatable, Sendable {
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
}

/// A vault's publish destinations and this Mac's history of publishing to
/// them, kept in the app's own Keychain group. One actor serializes every
/// read-modify-write, so concurrent edits can't lose each other's changes.
actor PublishingStore {
	private let service: any KeychainServiceProtocol

	init(service: any KeychainServiceProtocol) {
		self.service = service
	}

	// MARK: - Destinations

	func destinations(of vaultID: String) -> Result<[PublishDestination], PublishingStoreError> {
		Result { try readDestinations(of: vaultID) }.mapError(Self.storeError)
	}

	/// Adds `destination`, or replaces the one with its ID.
	func save(_ destination: PublishDestination, to vaultID: String) -> Result<[PublishDestination], PublishingStoreError> {
		Result {
			if let invalidity = destination.invalidity { throw PublishingStoreError.invalidDestination(invalidity) }
			var destinations = try readDestinations(of: vaultID)
			if let other = destinations.first(where: { $0.id != destination.id && $0.target.location == destination.target.location }) {
				throw PublishingStoreError.duplicateLocation(existing: other.id)
			}
			if let index = destinations.firstIndex(where: { $0.id == destination.id }) {
				destinations[index] = destination
			} else {
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
			guard destinations.contains(where: { $0.id == id }) else { return destinations }
			destinations.removeAll { $0.id == id }
			try writeDestinations(destinations, of: vaultID)
			// The destination is gone either way; a history this version can't
			// rewrite keeps the entry until the next publish prunes it.
			if var history = try? readHistory(of: vaultID), history.entries.removeValue(forKey: id) != nil {
				try? writeHistory(history, of: vaultID)
			}
			return destinations
		}.mapError(Self.storeError)
	}

	// MARK: - History

	func history(of vaultID: String) -> Result<PublishHistory, PublishingStoreError> {
		Result { try readHistory(of: vaultID) }.mapError(Self.storeError)
	}

	/// Records a publish to `destination`: the keys the platform accepted, and
	/// the destination with the person's choices from the review.
	func recordPublish(
		_ published: [PublishHistory.Published],
		to destination: PublishDestination,
		of vaultID: String,
		at date: Date
	) -> Result<Void, PublishingStoreError> {
		Result {
			// The platform already has the values, so the history records them
			// even when the destination itself can't be saved.
			let saved = save(destination, to: vaultID)
			var history = try readHistory(of: vaultID).recording(published, to: destination.id, at: date)
			if case .success(let destinations) = saved {
				let current = Set(destinations.map(\.id))
				history.entries = history.entries.filter { current.contains($0.key) }
			}
			try writeHistory(history, of: vaultID)
			_ = try saved.get()
		}.mapError(Self.storeError)
	}

	/// The key fingerprints are made with, created the first time it's needed.
	func fingerprintKey() -> Result<SymmetricKey, PublishingStoreError> {
		Result {
			if let data = try service.readPublishingData(account: Self.fingerprintKeyAccount).get(),
				data.count == SymmetricKeySize.bits256.bitCount / 8
			{
				return SymmetricKey(data: data)
			}
			// A missing or damaged key is replaced; earlier fingerprints then read as changed values.
			let key = SymmetricKey(size: .bits256)
			try service.writePublishingData(
				account: Self.fingerprintKeyAccount,
				data: key.withUnsafeBytes { Data($0) }
			).get()
			return key
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

	/// Carries a renamed key's exclusions to its new name.
	func renameKey(_ old: String, to new: String, in vaultID: String) -> Result<Void, PublishingStoreError> {
		updateDestinations(of: vaultID) { destination in
			let wasExcluded = destination.excludedKeys.contains(old)
			guard wasExcluded || destination.excludedKeys.contains(new) else { return false }
			destination.excludedKeys.remove(old)
			if wasExcluded { destination.excludedKeys.insert(new) } else { destination.excludedKeys.remove(new) }
			return true
		}
	}

	/// Deletes the vault's destinations and history, as when its local copy is deleted.
	func deleteRecords(of vaultID: String) -> Result<Void, PublishingStoreError> {
		Result {
			let destinations = service.deletePublishingData(account: try Self.destinationsAccount(vaultID))
			let history = service.deletePublishingData(account: try Self.historyAccount(vaultID))
			try destinations.get()
			try history.get()
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
			let now = PublishTimestamp.normalized(Date())
			for index in destinations.indices where update(&destinations[index]) {
				destinations[index].updatedAt = max(destinations[index].updatedAt, now)
				changed = true
			}
			if changed { try writeDestinations(destinations, of: vaultID) }
		}.mapError(Self.storeError)
	}

	private func readDestinations(of vaultID: String) throws -> [PublishDestination] {
		guard let data = try service.readPublishingData(account: Self.destinationsAccount(vaultID)).get() else { return [] }
		return try PublishingRecords.decodeDestinations(data, vaultID: vaultID).get()
	}

	private func writeDestinations(_ destinations: [PublishDestination], of vaultID: String) throws {
		let account = try Self.destinationsAccount(vaultID)
		guard !destinations.isEmpty else {
			try service.deletePublishingData(account: account).get()
			return
		}
		guard let data = PublishingRecords.encode(destinations, vaultID: vaultID) else { throw PublishingStoreError.tooLarge }
		try service.writePublishingData(account: account, data: data).get()
	}

	private func readHistory(of vaultID: String) throws -> PublishHistory {
		guard let data = try service.readPublishingData(account: Self.historyAccount(vaultID)).get() else { return PublishHistory() }
		return try PublishingRecords.decodeHistory(data, vaultID: vaultID).get()
	}

	private func writeHistory(_ history: PublishHistory, of vaultID: String) throws {
		let account = try Self.historyAccount(vaultID)
		guard !history.entries.isEmpty else {
			try service.deletePublishingData(account: account).get()
			return
		}
		guard let data = PublishingRecords.encode(history, vaultID: vaultID) else { throw PublishingStoreError.tooLarge }
		try service.writePublishingData(account: account, data: data).get()
	}

	private static let fingerprintKeyAccount = "fingerprint-key"

	private static func destinationsAccount(_ vaultID: String) throws -> String {
		guard EnvValidation.isSafeVaultId(vaultID) else { throw PublishingStoreError.invalidVault }
		return "destinations.\(vaultID)"
	}

	private static func historyAccount(_ vaultID: String) throws -> String {
		guard EnvValidation.isSafeVaultId(vaultID) else { throw PublishingStoreError.invalidVault }
		return "history.\(vaultID)"
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
