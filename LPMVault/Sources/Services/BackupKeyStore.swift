import Darwin
import Foundation

/// The sync keys a backup carries, each as its credential store keeps it and
/// under its store account's digest, so another Mac installs it under the
/// name the LPM CLI and LPM Vault look for. Their text stays in bytes the app
/// zeroes.
struct BackupKeys: Sendable {
	/// A personal root key: its account's digest, and its 64 hex digits.
	struct PersonalRoot: Sendable {
		let account: String
		let key: SecretBytes
	}

	/// A sharing keypair's private key under its scope's digest, live,
	/// pending while a rotation uploads, or both, each as standard base64.
	struct SharingKey: Sendable {
		let account: String
		let live: SecretBytes?
		let pending: SecretBytes?
	}

	/// A personal key floor: its file name's digest and the version it holds.
	struct Floor: Equatable, Sendable {
		let digest: String
		let version: Int
	}

	/// The most entries each kind holds, as the format allows.
	static let maximumEntries = 64

	var personalRoots: [PersonalRoot] = []
	var sharingKeys: [SharingKey] = []
	/// The legacy wrapping key, as 64 hex digits.
	var wrappingKey: SecretBytes?
	var floors: [Floor] = []

	/// The keys, counting a sharing key's live and pending halves apart.
	var keyCount: Int {
		personalRoots.count + sharingKeys.reduce(0) { $0 + ($1.live == nil ? 0 : 1) + ($1.pending == nil ? 0 : 1) }
			+ (wrappingKey == nil ? 0 : 1)
	}

	var isEmpty: Bool { keyCount == 0 && floors.isEmpty }

	/// Whether `text` is an account or floor digest: 64 lowercase hex digits.
	static func isDigest(_ text: String) -> Bool {
		text.utf8.count == 64 && text.utf8.allSatisfy(isLowercaseHexDigit)
	}

	static func isLowercaseHexDigit(_ byte: UInt8) -> Bool {
		(0x30...0x39).contains(byte) || (0x61...0x66).contains(byte)
	}
}

/// The credential stores and files that hold sync keys: read for a backup,
/// and written by a restore where this Mac has none.
struct BackupKeyStore: Sendable {
	enum Failure: Error, Equatable, Sendable {
		/// The store couldn't be read, or holds a key not in the form it keeps keys.
		case unreadable(store: String)
		/// More keys of one kind than a backup can carry.
		case tooMany(store: String)
		/// A key couldn't be saved in the store.
		case unwritable(store: String)

		var message: String {
			switch self {
			case .unreadable(let store):
				"This Mac’s \(store) couldn’t be read, so nothing was exported. Try again, or export without lpm.dev sync keys."
			case .tooMany(let store):
				"This Mac holds more \(store) than a backup can carry. Export without lpm.dev sync keys."
			case .unwritable(let store):
				"This Mac’s \(store) couldn’t be saved. Restore the backup again to add them."
			}
		}
	}

	let roots: SharedKeychainStore
	let sharing: SharedKeychainStore
	let wrapping: SharedKeychainStore
	let home: LPMHome

	/// The stores of `home`, shared with the LPM CLI.
	static func live(home: LPMHome = .current) -> BackupKeyStore {
		BackupKeyStore(
			roots: SharedKeychainStore(service: home.service(PersonalProjectCrypto.rootService)),
			sharing: SharedKeychainStore(service: home.service(VaultConstants.keychainService)),
			wrapping: SharedKeychainStore(service: home.service(VaultCrypto.wrappingKeyService)),
			home: home)
	}

	private static let pendingSuffix = ".pending"

	/// What restoring keys does here, key by key.
	struct Review: Equatable, Sendable {
		/// Keys this Mac doesn't have, which a restore adds.
		var added = 0
		/// Keys this Mac already has, the same.
		var alreadyHere = 0
		/// Keys this Mac has differently, which it keeps.
		var differing = 0
		/// Floors lower here than in the backup, which a restore raises.
		var floorsRaised = 0
		/// The personal root accounts this Mac holds a different key for.
		var differingRoots = Set<String>()
		/// The sharing key digests this Mac holds a different live key for.
		var differingLiveSharingKeys = Set<String>()
	}

	/// The keys this Mac holds, by account, read from accounts alone.
	struct Present: Equatable, Sendable {
		var roots = Set<String>()
		var liveSharingKeys = Set<String>()

		/// These keys and the ones `keys` adds.
		func adding(_ keys: BackupKeys) -> Present {
			Present(
				roots: roots.union(keys.personalRoots.lazy.map(\.account)),
				liveSharingKeys: liveSharingKeys.union(keys.sharingKeys.lazy.filter { $0.live != nil }.map(\.account)))
		}
	}

	/// Which synced projects from a backup have the key lpm.dev's copy needs on
	/// this Mac, and none different from the backup's.
	struct Coverage: Equatable, Sendable {
		/// The personal root accounts held here and not differently than in the backup.
		var roots = Set<String>()
		/// Whether organization projects have their sharing key. A backup's
		/// project doesn't name the person who synced it, so every live sharing
		/// key the backup carries must be here as the backup has it; when it
		/// carries none, this Mac's own must exist.
		var organizations = false

		init() {}

		init(present: Present, review: Review, backup: BackupKeys) {
			roots = present.roots.subtracting(review.differingRoots)
			let carried = Set(backup.sharingKeys.lazy.filter { $0.live != nil }.map(\.account))
			organizations =
				carried.isEmpty
				? !present.liveSharingKeys.isEmpty
				: carried.isSubset(of: present.liveSharingKeys) && carried.isDisjoint(with: review.differingLiveSharingKeys)
		}

		/// Whether a project that syncs as `sync` has its key: its account's
		/// root key for a personal project, a sharing key for an organization's.
		func hasKey(for sync: BackupPayload.Sync) -> Bool {
			switch sync.scope {
			case .personal:
				guard let origin = try? PersonalProjectCrypto.registryOrigin(sync.registry),
					let account = try? PersonalProjectCrypto.rootAccount(origin: origin, principalID: sync.principalId)
				else { return false }
				return roots.contains(account)
			case .organization:
				return organizations
			}
		}
	}

	/// How restoring `keys` would go here; nothing is written.
	func review(_ keys: BackupKeys) throws(Failure) -> Review {
		try locked { () throws(Failure) -> Review in try visit(keys, install: false) }
	}

	/// Adds every key in `keys` this Mac doesn't have, never replacing one it
	/// has, and raises floors that are lower here, all under the lock the LPM
	/// CLI and LPM Vault take to create keys.
	func install(_ keys: BackupKeys) throws(Failure) -> Review {
		try locked { () throws(Failure) -> Review in try visit(keys, install: true) }
	}

	/// The keys this Mac holds, read from their accounts alone.
	func presentKeys() throws(Failure) -> Present {
		try locked { () throws(Failure) -> Present in
			let roots = Set(try accounts(of: roots, store: "personal root keys").filter(BackupKeys.isDigest))
			let live = try accounts(of: sharing, store: "sharing keys").compactMap { account in
				sharingDigest(of: account).flatMap { $0.pending ? nil : $0.digest }
			}
			return Present(roots: roots, liveSharingKeys: Set(live))
		}
	}

	private func visit(_ keys: BackupKeys, install: Bool) throws(Failure) -> Review {
		var review = Review()
		func place(
			_ text: SecretBytes, as account: String, in store: SharedKeychainStore, named name: String,
			normalized: (Data) -> SecretBytes?, onDiffering: () -> Void = {}
		) throws(Failure) {
			func compare(_ stored: Data) {
				if let local = normalized(stored), Self.equal(local, text) {
					review.alreadyHere += 1
				} else {
					review.differing += 1
					onDiffering()
				}
			}
			if let stored = try read(account, of: store, store: name) {
				compare(stored)
				return
			}
			guard install else {
				review.added += 1
				return
			}
			do {
				try text.withUnsafeBytes { bytes in
					guard let base = bytes.baseAddress else { throw KeychainStoreError.concurrentModification }
					try store.add(account: account, data: Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: base), count: bytes.count, deallocator: .none))
				}
				review.added += 1
			} catch let error as KeychainStoreError where error.statusCode == errSecDuplicateItem {
				guard let stored = try read(account, of: store, store: name) else { throw .unwritable(store: name) }
				compare(stored)
			} catch {
				throw .unwritable(store: name)
			}
		}
		for root in keys.personalRoots {
			try place(root.key, as: root.account, in: roots, named: "personal root keys", normalized: Self.hexKey) {
				review.differingRoots.insert(root.account)
			}
		}
		for key in keys.sharingKeys {
			let account = VaultCrypto.scopedX25519AccountPrefix + key.account
			if let live = key.live {
				try place(live, as: account, in: sharing, named: "sharing keys", normalized: Self.base64Key) {
					review.differingLiveSharingKeys.insert(key.account)
				}
			}
			if let pending = key.pending {
				try place(pending, as: account + Self.pendingSuffix, in: sharing, named: "sharing keys", normalized: Self.base64Key)
			}
		}
		if let wrappingKey = keys.wrappingKey {
			try place(wrappingKey, as: VaultCrypto.wrappingKeyAccount, in: wrapping, named: "legacy wrapping key", normalized: Self.hexKey)
		}
		for floor in keys.floors {
			do {
				let local = try PersonalProjectCrypto.floor(digest: floor.digest, home: home, lockHeld: true)
				guard floor.version > local else { continue }
				if install {
					_ = try PersonalProjectCrypto.floor(digest: floor.digest, advanceTo: floor.version, home: home, lockHeld: true)
				}
				review.floorsRaised += 1
			} catch {
				throw install ? .unwritable(store: "personal key floors") : .unreadable(store: "personal key floors")
			}
		}
		return review
	}

	/// Whether two keys' text is the same, compared in constant time.
	private static func equal(_ first: SecretBytes, _ second: SecretBytes) -> Bool {
		first.count == second.count
			&& first.withUnsafeBytes { a in
				second.withUnsafeBytes { b in
					guard let left = a.baseAddress, let right = b.baseAddress else { return a.count == 0 }
					return timingsafe_bcmp(left, right, a.count) == 0
				}
			}
	}

	/// How many keys this Mac holds, counted from their accounts alone.
	func count() throws(Failure) -> Int {
		try locked { () throws(Failure) -> Int in
			let rootAccounts = try accounts(of: roots, store: "personal root keys").filter(BackupKeys.isDigest)
			let sharingAccounts = try accounts(of: sharing, store: "sharing keys").filter { sharingDigest(of: $0) != nil }
			let wrappingKey = try read(VaultCrypto.wrappingKeyAccount, of: wrapping, store: "legacy wrapping key") != nil
			return rootAccounts.count + sharingAccounts.count + (wrappingKey ? 1 : 0)
		}
	}

	/// Every sync key and floor this Mac holds, read under the lock the LPM
	/// CLI and LPM Vault take to create keys, so none is read half-made. A key
	/// that isn't in the form its store keeps keys fails it all.
	func read() throws(Failure) -> BackupKeys {
		try locked { () throws(Failure) -> BackupKeys in
			var keys = BackupKeys()
			for account in try accounts(of: roots, store: "personal root keys").sorted() where BackupKeys.isDigest(account) {
				guard let stored = try read(account, of: roots, store: "personal root keys"),
					let key = Self.hexKey(stored)
				else { throw Failure.unreadable(store: "personal root keys") }
				keys.personalRoots.append(.init(account: account, key: key))
			}

			var halves: [String: (live: SecretBytes?, pending: SecretBytes?)] = [:]
			for account in try accounts(of: sharing, store: "sharing keys") {
				guard let (digest, pending) = sharingDigest(of: account) else { continue }
				guard let stored = try read(account, of: sharing, store: "sharing keys"),
					let key = Self.base64Key(stored)
				else { throw Failure.unreadable(store: "sharing keys") }
				if pending { halves[digest, default: (nil, nil)].pending = key } else { halves[digest, default: (nil, nil)].live = key }
			}
			keys.sharingKeys = halves.keys.sorted().map { digest in
				BackupKeys.SharingKey(account: digest, live: halves[digest]?.live, pending: halves[digest]?.pending)
			}

			if let stored = try read(VaultCrypto.wrappingKeyAccount, of: wrapping, store: "legacy wrapping key") {
				guard let key = Self.hexKey(stored) else { throw Failure.unreadable(store: "legacy wrapping key") }
				keys.wrappingKey = key
			}

			do {
				for digest in try PersonalProjectCrypto.floorDigests(home: home) {
					let version = try PersonalProjectCrypto.floor(digest: digest, home: home, lockHeld: true)
					if version > 0 { keys.floors.append(.init(digest: digest, version: version)) }
				}
			} catch {
				throw Failure.unreadable(store: "personal key floors")
			}

			for (count, store) in [
				(keys.personalRoots.count, "personal root keys"), (keys.sharingKeys.count, "sharing keys"),
				(keys.floors.count, "personal key floors"),
			] where count > BackupKeys.maximumEntries {
				throw Failure.tooMany(store: store)
			}
			return keys
		}
	}

	/// The digest of a sharing key's account, and whether it's the pending half.
	private func sharingDigest(of account: String) -> (digest: String, pending: Bool)? {
		guard account.hasPrefix(VaultCrypto.scopedX25519AccountPrefix) else { return nil }
		var rest = account.dropFirst(VaultCrypto.scopedX25519AccountPrefix.count)
		let pending = rest.hasSuffix(Self.pendingSuffix)
		if pending { rest = rest.dropLast(Self.pendingSuffix.count) }
		let digest = String(rest)
		return BackupKeys.isDigest(digest) ? (digest, pending) : nil
	}

	private func accounts(of store: SharedKeychainStore, store name: String) throws(Failure) -> [String] {
		do { return Array(try store.accounts().keys) } catch { throw .unreadable(store: name) }
	}

	private func read(_ account: String, of store: SharedKeychainStore, store name: String) throws(Failure) -> Data? {
		do { return try store.read(account: account) } catch { throw .unreadable(store: name) }
	}

	/// Runs `operation` holding `home`'s key-creation lock.
	func locked<T>(_ operation: () throws(Failure) -> T) throws(Failure) -> T {
		do {
			if home == .current {
				return try VaultKeychainTransactionLock.withLock { try operation() }
			}
			let lock = try VaultKeychainTransactionLock.openLockFile(home: home)
			defer {
				_ = flock(lock, LOCK_UN)
				_ = Darwin.close(lock)
			}
			return try operation()
		} catch let failure as Failure {
			throw failure
		} catch {
			throw .unreadable(store: "credential stores")
		}
	}

	// MARK: - Key text

	private static let hexDigits = Array("0123456789abcdef".utf8)
	private static let base64Digits = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8)

	/// A 32-byte key stored as hex, surrounding whitespace allowed, as 64
	/// lowercase hex digits.
	static func hexKey(_ stored: Data) -> SecretBytes? {
		var key = [UInt8](repeating: 0, count: 32)
		defer { _ = memset_s(&key, key.count, 0, key.count) }
		let trimmed = stored.drop { isSpace($0) }.reversed().drop { isSpace($0) }.reversed()
		guard trimmed.count == 64 else { return nil }
		var high: UInt8?
		var index = 0
		for byte in trimmed {
			guard let nibble = hexValue(byte) else { return nil }
			if let first = high {
				key[index] = first << 4 | nibble
				index += 1
				high = nil
			} else {
				high = nibble
			}
		}
		return SecretBytes(count: 64) { output in
			for (position, byte) in key.enumerated() {
				output[position * 2] = hexDigits[Int(byte >> 4)]
				output[position * 2 + 1] = hexDigits[Int(byte & 0x0F)]
			}
		}
	}

	/// A 32-byte key stored as standard base64 as its canonical 44 digits.
	static func base64Key(_ stored: Data) -> SecretBytes? {
		guard var key = Data(base64Encoded: stored), key.count == 32 else { return nil }
		defer { key.resetBytes(in: 0..<key.count) }
		return SecretBytes(count: 44) { output in
			var position = 0
			key.withUnsafeBytes { bytes in
				for chunk in stride(from: 0, to: 30, by: 3) {
					let value = UInt32(bytes[chunk]) << 16 | UInt32(bytes[chunk + 1]) << 8 | UInt32(bytes[chunk + 2])
					for shift in [18, 12, 6, 0] {
						output[position] = base64Digits[Int(value >> UInt32(shift) & 0x3F)]
						position += 1
					}
				}
				let last = UInt32(bytes[30]) << 16 | UInt32(bytes[31]) << 8
				for shift in [18, 12, 6] {
					output[position] = base64Digits[Int(last >> UInt32(shift) & 0x3F)]
					position += 1
				}
			}
			output[position] = UInt8(ascii: "=")
		}
	}

	private static func isSpace(_ byte: UInt8) -> Bool {
		byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
	}

	private static func hexValue(_ byte: UInt8) -> UInt8? {
		switch byte {
		case 0x30...0x39: byte - 0x30
		case 0x61...0x66: byte - 0x61 + 10
		case 0x41...0x46: byte - 0x41 + 10
		default: nil
		}
	}
}
