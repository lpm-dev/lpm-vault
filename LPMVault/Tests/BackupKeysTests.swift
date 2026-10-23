import Foundation
import Testing

@testable import LPMVault

@Suite("Backup keys", .serialized)
struct BackupKeysTests {
	static let rootAccount = String(repeating: "0123456789abcdef", count: 4)
	static let rootKey = String(repeating: "a1", count: 32)
	static let sharingAccount = String(repeating: "fedcba9876543210", count: 4)
	static let pendingOnlyAccount = String(repeating: "1", count: 64)
	static let liveKey = String(repeating: "A", count: 43) + "="
	static let pendingKey = String(repeating: "/", count: 42) + "8="
	static let wrappingKey = String(repeating: "b2", count: 32)
	static let floor = String(repeating: "2", count: 64)
	static let otherFloor = String(repeating: "3", count: 64)

	/// A temporary folder, removed by `body`'s end.
	static func inFolder<T>(_ body: (URL) throws -> T) throws -> T {
		let folder = FileManager.default.temporaryDirectory.appending(path: "lpm-backup-keys-\(UUID().uuidString)", directoryHint: .isDirectory)
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: folder) }
		return try body(folder)
	}

	/// One of each kind of key, written as older writers could have.
	static func seed(_ backend: InMemoryKeychainBackend, floorsIn home: LPMHome) throws {
		let sharing = VaultCrypto.scopedX25519AccountPrefix
		try backend.add(service: BackupKeyStore.testRootService, account: rootAccount, data: Data((rootKey.uppercased() + "\n").utf8))
		try backend.add(service: BackupKeyStore.testRootService, account: "not-a-digest", data: Data("x".utf8))
		try backend.add(service: BackupKeyStore.testSharingService, account: sharing + sharingAccount, data: Data(liveKey.utf8))
		try backend.add(service: BackupKeyStore.testSharingService, account: sharing + sharingAccount + ".pending", data: Data(pendingKey.utf8))
		try backend.add(service: BackupKeyStore.testSharingService, account: sharing + pendingOnlyAccount + ".pending", data: Data(liveKey.utf8))
		try backend.add(service: BackupKeyStore.testSharingService, account: "vault-a", data: Data("{\"environments\":{}}".utf8))
		try backend.add(service: BackupKeyStore.testWrappingService, account: VaultCrypto.wrappingKeyAccount, data: Data(("  " + wrappingKey + "\n").utf8))
		_ = try PersonalProjectCrypto.floor(digest: floor, advanceTo: 3, home: home)
		_ = try PersonalProjectCrypto.floor(digest: otherFloor, advanceTo: 7, home: home)
	}

	static func text(_ bytes: SecretBytes?) -> String? {
		bytes?.withUnsafeBytes { String(decoding: $0, as: UTF8.self) }
	}

	@Test("the key store reads every kind of key and floor, in the form a backup carries them")
	func readsEveryKind() throws {
		try Self.inFolder { folder in
			let home = try testLPMHome(in: folder)
			let backend = InMemoryKeychainBackend()
			try Self.seed(backend, floorsIn: home)
			let store = BackupKeyStore.inMemory(backend, home: home)

			let keys = try store.read()
			#expect(keys.personalRoots.map(\.account) == [Self.rootAccount])
			#expect(Self.text(keys.personalRoots.first?.key) == Self.rootKey)
			#expect(keys.sharingKeys.map(\.account) == [Self.pendingOnlyAccount, Self.sharingAccount])
			#expect(Self.text(keys.sharingKeys[0].live) == nil)
			#expect(Self.text(keys.sharingKeys[0].pending) == Self.liveKey)
			#expect(Self.text(keys.sharingKeys[1].live) == Self.liveKey)
			#expect(Self.text(keys.sharingKeys[1].pending) == Self.pendingKey)
			#expect(Self.text(keys.wrappingKey) == Self.wrappingKey)
			#expect(keys.floors == [.init(digest: Self.floor, version: 3), .init(digest: Self.otherFloor, version: 7)])
			#expect(keys.keyCount == 5)
			#expect(try store.count() == 5)
		}
	}

	@Test("a key not in the form its store keeps keys fails the read, naming the store")
	func malformedKeys() throws {
		try Self.inFolder { folder in
			let home = try testLPMHome(in: folder)
			let root = InMemoryKeychainBackend()
			try root.add(service: BackupKeyStore.testRootService, account: Self.rootAccount, data: Data(String(repeating: "z", count: 64).utf8))
			#expect(throws: BackupKeyStore.Failure.unreadable(store: "personal root keys")) {
				try BackupKeyStore.inMemory(root, home: home).read()
			}
			let sharing = InMemoryKeychainBackend()
			try sharing.add(
				service: BackupKeyStore.testSharingService, account: VaultCrypto.scopedX25519AccountPrefix + Self.sharingAccount,
				data: Data(Data(count: 31).base64EncodedString().utf8))
			#expect(throws: BackupKeyStore.Failure.unreadable(store: "sharing keys")) {
				try BackupKeyStore.inMemory(sharing, home: home).read()
			}
		}
	}

	@Test("a Mac without keys counts none and reads an empty set")
	func noKeys() throws {
		try Self.inFolder { folder in
			let store = BackupKeyStore.inMemory(InMemoryKeychainBackend(), home: try testLPMHome(in: folder))
			#expect(try store.count() == 0)
			#expect(try store.read().isEmpty)
		}
	}
}
