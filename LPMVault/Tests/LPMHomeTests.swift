import Darwin
import Foundation
import Testing

@testable import LPMVault

/// The shared credential store, kept in memory, keyed by service and account.
final class MemoryLPMHomeKeychain: LPMHomeKeychain, @unchecked Sendable {
	private let lock = NSLock()
	private var items: [String: [String: (data: Data, access: VaultCliAccess)]] = [:]
	/// Accounts whose write fails, to stop a move part way.
	var failingWrites: Set<String> = []

	func accounts(service: String) throws -> [String: VaultCliAccess] {
		lock.withLock { (items[service] ?? [:]).mapValues(\.access) }
	}

	func read(service: String, account: String) throws -> Data? {
		lock.withLock { items[service]?[account]?.data }
	}

	func write(service: String, account: String, data: Data, access: VaultCliAccess) throws {
		try lock.withLock {
			if failingWrites.contains(account) { throw KeychainStoreError.status(operation: "write", code: errSecIO) }
			items[service, default: [:]][account] = (data, access)
		}
	}

	func delete(service: String, account: String) throws -> Bool {
		lock.withLock { items[service]?.removeValue(forKey: account) != nil }
	}

	func store(_ value: String, service: String, account: String, access: VaultCliAccess = .automatic) {
		lock.withLock { items[service, default: [:]][account] = (Data(value.utf8), access) }
	}

	var services: [String] { lock.withLock { items.filter { !$0.value.isEmpty }.keys.sorted() } }
}

@Suite("LPM home")
struct LPMHomeTests {
	private func temporaryFolder() throws -> URL {
		let folder = FileManager.default.temporaryDirectory
			.appendingPathComponent("lpm-home-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		return URL(fileURLWithPath: try #require(realpath(folder.path, nil).map { String(cString: $0) }), isDirectory: true)
	}

	@Test("another home's service names take the CLI's suffix, and the default home's stay bare")
	func serviceNamesFollowTheCLI() throws {
		let user = try temporaryFolder()
		defer { try? FileManager.default.removeItem(at: user) }

		let standard = try #require(LPMHome.at(user.appendingPathComponent(".lpm"), userHome: user))
		#expect(standard == LPMHome(defaultIn: user))
		#expect(standard.isDefault)
		#expect(standard.service("dev.lpm.vault") == "dev.lpm.vault")

		let custom = try #require(LPMHome.at(user.appendingPathComponent("tools/lpm"), userHome: user))
		let scope = try #require(custom.scope)
		#expect(scope.count == 16 && scope.allSatisfy(\.isHexDigit))
		#expect(custom.service("lpm-cli") == "lpm-cli:\(scope)")
		#expect(LPMHome.at(user.appendingPathComponent("tools/lpm"), userHome: user)?.scope == scope)
		#expect(LPMHome.at(user.appendingPathComponent("tools/other"), userHome: user)?.scope != scope)
	}

	@Test("the chosen home is the one the preference names, or ~/.lpm when it names none it can use")
	func chosenHomeComesFromThePreference() throws {
		let user = try temporaryFolder()
		defer { try? FileManager.default.removeItem(at: user) }
		let domain = "lpm-home-\(UUID().uuidString)"
		let defaults = try #require(UserDefaults(suiteName: domain))
		defer { defaults.removePersistentDomain(forName: domain) }

		#expect(LPMHome.chosen(in: defaults, userHome: user) == LPMHome(defaultIn: user))
		let custom = try #require(LPMHome.at(user.appendingPathComponent("lpm-home"), userHome: user))
		LPMHome.choose(custom, in: defaults)
		#expect(LPMHome.chosen(in: defaults, userHome: user) == custom)
		LPMHome.choose(LPMHome(defaultIn: user), in: defaults)
		#expect(defaults.string(forKey: LPMHome.preferenceKey) == nil)
		defaults.set("relative/lpm", forKey: LPMHome.preferenceKey)
		#expect(LPMHome.chosen(in: defaults, userHome: user) == LPMHome(defaultIn: user))
	}

	@Test("a move takes every shared item and state file to the new home's names, and leaves the old home empty")
	func moveTakesEverything() throws {
		let user = try temporaryFolder()
		defer { try? FileManager.default.removeItem(at: user) }
		let source = LPMHome(defaultIn: user)
		let target = try #require(LPMHome.at(user.appendingPathComponent("relocated"), userHome: user))
		let keychain = MemoryLPMHomeKeychain()
		keychain.store("{}", service: "dev.lpm.vault", account: "vault-a", access: .requireApproval)
		keychain.store("meta", service: "dev.lpm.vault", account: VaultKeychainRecordContract.projectMetadataPrefix + "vault-a")
		keychain.store("wrapping", service: "dev.lpm.vault-key", account: "wrapping-key")
		keychain.store("root", service: "dev.lpm.env-personal-root-v2", account: "account")
		keychain.store("token", service: "lpm-cli", account: "auth-token:abc")
		keychain.store("unrelated", service: "dev.lpm.vault.publishing", account: "destinations")
		try FileManager.default.createDirectory(at: source.url, withIntermediateDirectories: true)
		for name in [".credential-authority.json", "device-id", ".env-project-key-floor-abc", "store-notes"] {
			try Data("\(name) contents".utf8).write(to: source.url.appendingPathComponent(name))
			chmod(source.url.appendingPathComponent(name).path, 0o600)
		}
		let move = LPMHomeMove(keychain: keychain)
		let held = try move.contents(of: source)
		#expect(held.projects == 1 && held.signedIn && held.items == 5)
		#expect(held.files == [".credential-authority.json", ".env-project-key-floor-abc", "device-id"])
		var adopted = false

		let leftovers = try move.move(from: source, to: target) { adopted = true }

		#expect(adopted)
		#expect(leftovers.isEmpty)
		#expect(try keychain.read(service: target.service("dev.lpm.vault"), account: "vault-a") == Data("{}".utf8))
		#expect(try keychain.accounts(service: target.service("dev.lpm.vault"))["vault-a"] == .requireApproval)
		#expect(try keychain.read(service: target.service("lpm-cli"), account: "auth-token:abc") == Data("token".utf8))
		#expect(try move.contents(of: source).isEmpty)
		#expect(try keychain.read(service: "dev.lpm.vault.publishing", account: "destinations") != nil, "The app's own items stay")
		for name in [".credential-authority.json", "device-id", ".env-project-key-floor-abc"] {
			let moved = target.url.appendingPathComponent(name)
			#expect(try String(contentsOf: moved, encoding: .utf8) == "\(name) contents")
			#expect((try FileManager.default.attributesOfItem(atPath: moved.path)[.posixPermissions] as? Int) == 0o600)
		}
		#expect(FileManager.default.fileExists(atPath: source.url.appendingPathComponent("store-notes").path))
		#expect(try String(contentsOf: target.url.appendingPathComponent(".gitignore"), encoding: .utf8)
			== "# LPM's machine-local state. Nothing here belongs in git.\n*\n")
	}

	@Test("a move into a home that holds anything already, or onto the same home, changes nothing")
	func moveRefusesAnOccupiedHome() throws {
		let user = try temporaryFolder()
		defer { try? FileManager.default.removeItem(at: user) }
		let source = LPMHome(defaultIn: user)
		let target = try #require(LPMHome.at(user.appendingPathComponent("relocated"), userHome: user))
		let keychain = MemoryLPMHomeKeychain()
		keychain.store("{}", service: "dev.lpm.vault", account: "vault-a")
		keychain.store("cli", service: target.service("dev.lpm.vault"), account: "vault-b")
		var adopted = false

		#expect(throws: LPMHomeMoveError.targetNotEmpty(target.displayPath)) {
			_ = try LPMHomeMove(keychain: keychain).move(from: source, to: target) { adopted = true }
		}
		#expect(throws: LPMHomeMoveError.sameHome) {
			_ = try LPMHomeMove(keychain: keychain).move(from: source, to: source) { adopted = true }
		}
		#expect(!adopted)
		#expect(try keychain.read(service: "dev.lpm.vault", account: "vault-a") != nil)
		#expect(try keychain.accounts(service: target.service("dev.lpm.vault")).keys.sorted() == ["vault-b"])
	}

	@Test("a move that fails part way removes its copies and leaves the old home as it was")
	func failedMoveRollsBack() throws {
		let user = try temporaryFolder()
		defer { try? FileManager.default.removeItem(at: user) }
		let source = LPMHome(defaultIn: user)
		let target = try #require(LPMHome.at(user.appendingPathComponent("relocated"), userHome: user))
		let keychain = MemoryLPMHomeKeychain()
		keychain.store("{}", service: "dev.lpm.vault", account: "vault-a")
		keychain.store("token", service: "lpm-cli", account: "auth-token:abc")
		keychain.failingWrites = ["auth-token:abc"]
		var adopted = false

		#expect(throws: LPMHomeMoveError.copyFailed("auth-token:abc in lpm-cli")) {
			_ = try LPMHomeMove(keychain: keychain).move(from: source, to: target) { adopted = true }
		}
		#expect(!adopted)
		#expect(keychain.services == ["dev.lpm.vault", "lpm-cli"])
	}

	@Test("nothing moves into a home git could commit")
	func moveRefusesAnExposedHome() throws {
		let user = try temporaryFolder()
		defer { try? FileManager.default.removeItem(at: user) }
		let keychain = MemoryLPMHomeKeychain()
		keychain.store("{}", service: "dev.lpm.vault", account: "vault-a")
		let repository = user.appendingPathComponent("dotfiles", isDirectory: true)
		try FileManager.default.createDirectory(at: repository.appendingPathComponent(".git"), withIntermediateDirectories: true)
		let target = try #require(LPMHome.at(repository, userHome: user))

		#expect {
			_ = try LPMHomeMove(keychain: keychain).move(from: LPMHome(defaultIn: user), to: target) {}
		} throws: { error in
			guard case LPMHomeMoveError.targetExposed(let explanation) = error else { return false }
			return explanation.contains("Use an LPM home outside the repository.")
		}
		#expect(keychain.services == ["dev.lpm.vault"])
	}

	@Test("changing the LPM home moves what it holds only after the user confirms, then relaunches into it")
	@MainActor
	func storeMovesAfterConfirmation() async throws {
		let user = try temporaryFolder()
		defer { try? FileManager.default.removeItem(at: user) }
		let domain = "lpm-home-\(UUID().uuidString)"
		let defaults = try #require(UserDefaults(suiteName: domain))
		defer { defaults.removePersistentDomain(forName: domain) }
		let biometrics = MockBiometricService()
		let store = VaultStore(
			keychainService: MockKeychainService(), biometricService: biometrics,
			apiService: MockAPIService(), preferences: defaults)
		store.isUnlocked = true
		store.lpmHome = LPMHome(defaultIn: user)
		let keychain = MemoryLPMHomeKeychain()
		keychain.store("{}", service: "dev.lpm.vault", account: "vault-a")
		store.lpmHomeKeychain = { _ in keychain }
		var relaunches = 0
		store.relaunch = { relaunches += 1 }
		let target = try #require(LPMHome.at(user.appendingPathComponent("relocated"), userHome: user))

		biometrics.shouldSucceed = false
		await #expect(throws: CancellationError.self) { try await store.changeLPMHome(to: target, moving: true) }
		#expect(keychain.services == ["dev.lpm.vault"])
		#expect(defaults.string(forKey: LPMHome.preferenceKey) == nil)
		#expect(relaunches == 0 && store.isUnlocked)

		biometrics.shouldSucceed = true
		try await store.changeLPMHome(to: target, moving: true)
		#expect(keychain.services == [target.service("dev.lpm.vault")])
		#expect(defaults.string(forKey: LPMHome.preferenceKey) == target.url.path)
		#expect(LPMHome.chosen(in: defaults, userHome: user) == target)
		#expect(relaunches == 1)
		#expect(!store.isUnlocked)
		#expect(biometrics.confirmationReasons.last?.contains("move your env projects and sign-in to") == true)
	}

	@Test("the app never changes to an LPM home git could commit, moving or not")
	@MainActor
	func storeRefusesAnExposedHome() async throws {
		let user = try temporaryFolder()
		defer { try? FileManager.default.removeItem(at: user) }
		let domain = "lpm-home-\(UUID().uuidString)"
		let defaults = try #require(UserDefaults(suiteName: domain))
		defer { defaults.removePersistentDomain(forName: domain) }
		let store = VaultStore(
			keychainService: MockKeychainService(), biometricService: MockBiometricService(),
			apiService: MockAPIService(), preferences: defaults)
		store.isUnlocked = true
		store.lpmHome = LPMHome(defaultIn: user)
		var relaunches = 0
		store.relaunch = { relaunches += 1 }
		let repository = user.appendingPathComponent("dotfiles", isDirectory: true)
		try FileManager.default.createDirectory(at: repository.appendingPathComponent(".git"), withIntermediateDirectories: true)
		let target = try #require(LPMHome.at(repository, userHome: user))

		for moving in [false, true] {
			await #expect(throws: LPMHomeMoveError.self) { try await store.changeLPMHome(to: target, moving: moving) }
		}
		#expect(relaunches == 0)
		#expect(defaults.string(forKey: LPMHome.preferenceKey) == nil)
		#expect(!FileManager.default.fileExists(atPath: repository.appendingPathComponent("locks").path))
	}

	@Test("the transaction lock and login files live in a home of any name")
	func lockAndLoginFollowTheHome() async throws {
		let user = try temporaryFolder()
		defer { try? FileManager.default.removeItem(at: user) }
		let home = try #require(LPMHome.at(user.appendingPathComponent("tools/lpm-home"), userHome: user))

		let lock = try VaultKeychainTransactionLock.openLockFile(home: home)
		_ = flock(lock, LOCK_UN)
		_ = Darwin.close(lock)
		#expect(FileManager.default.fileExists(atPath: home.url.appendingPathComponent(".vault-keychain.lock").path))

		let coordinator = AuthSessionCoordinator(
			home: home, credentialBackend: NoCredentials(),
			refreshOperation: { _, _, _ in throw AuthSessionRefreshError.invalidResponse })
		_ = try coordinator.deviceFingerprint()
		#expect(FileManager.default.fileExists(atPath: home.url.appendingPathComponent("device-id").path))
		#expect(!FileManager.default.fileExists(atPath: user.appendingPathComponent(".lpm").path))
	}
}

private struct NoCredentials: AuthCredentialBackend {
	func read(account: String) throws -> String? { nil }
	func readLegacy(account: String) throws -> String? { nil }
	func deleteLegacy(account: String) throws {}
	func write(_ credential: String, account: String) throws {}
	func delete(account: String) throws {}
}
