import Darwin
import Foundation
import Testing

@testable import LPMVault

/// The shared credential store, kept in memory, keyed by service and account.
final class MemoryLPMHomeKeychain: LPMHomeKeychain, @unchecked Sendable {
	private let lock = NSLock()
	private var items: [String: [String: (data: Data, access: VaultCliAccess)]] = [:]
	private var listings = 0
	/// Accounts whose write fails, to stop a move part way.
	var failingWrites: Set<String> = []
	/// Services whose reads fail, as a read that checks a copy can.
	var failingReadServices: Set<String> = []
	/// Services whose deletes fail, to keep a move's copies.
	var failingDeleteServices: Set<String> = []
	/// What each write waits for before it writes, to hold a move part way.
	var writeGate: DispatchSemaphore?
	private var startedWrites = 0

	/// How many times a service's accounts were listed.
	var listingCount: Int { lock.withLock { listings } }
	/// How many writes started, including any `writeGate` holds.
	var writesStarted: Int { lock.withLock { startedWrites } }

	func accounts(service: String) throws -> [String: VaultCliAccess] {
		lock.withLock {
			listings += 1
			return (items[service] ?? [:]).mapValues(\.access)
		}
	}

	func read(service: String, account: String) throws -> Data? {
		try lock.withLock {
			if failingReadServices.contains(service) { throw KeychainStoreError.status(operation: "read", code: errSecIO) }
			return items[service]?[account]?.data
		}
	}

	func write(service: String, account: String, data: Data, access: VaultCliAccess) throws {
		let gate = lock.withLock {
			startedWrites += 1
			return writeGate
		}
		gate?.wait()
		try lock.withLock {
			if failingWrites.contains(account) { throw KeychainStoreError.status(operation: "write", code: errSecIO) }
			items[service, default: [:]][account] = (data, access)
		}
	}

	func delete(service: String, account: String) throws -> Bool {
		try lock.withLock {
			if failingDeleteServices.contains(service) { throw KeychainStoreError.status(operation: "delete", code: errSecIO) }
			return items[service]?.removeValue(forKey: account) != nil
		}
	}

	func accountNames(service: String) -> [String] {
		lock.withLock { (items[service] ?? [:]).keys.sorted() }
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
		keychain.store("unrelated", service: "dev.lpm.vault.platforms", account: "connection")
		try FileManager.default.createDirectory(at: source.url, withIntermediateDirectories: true)
		for name in [".credential-authority.json", "device-id", ".env-project-key-floor-abc", "store-notes"] {
			try Data("\(name) contents".utf8).write(to: source.url.appendingPathComponent(name))
			chmod(source.url.appendingPathComponent(name).path, 0o600)
		}
		let move = LPMHomeMove(shared: keychain, app: keychain)
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
		#expect(try keychain.read(service: "dev.lpm.vault.platforms", account: "connection") != nil, "Items no home owns stay")
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
			_ = try LPMHomeMove(shared: keychain, app: keychain).move(from: source, to: target) { adopted = true }
		}
		#expect(throws: LPMHomeMoveError.sameHome) {
			_ = try LPMHomeMove(shared: keychain, app: keychain).move(from: source, to: source) { adopted = true }
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
			_ = try LPMHomeMove(shared: keychain, app: keychain).move(from: source, to: target) { adopted = true }
		}
		#expect(!adopted)
		#expect(keychain.services == ["dev.lpm.vault", "lpm-cli"])
	}

	@Test("a move lists each service a fixed number of times, however many items it holds")
	func moveListsEachServiceOnce() throws {
		let user = try temporaryFolder()
		defer { try? FileManager.default.removeItem(at: user) }
		let source = LPMHome(defaultIn: user)
		let target = try #require(LPMHome.at(user.appendingPathComponent("relocated"), userHome: user))
		let keychain = MemoryLPMHomeKeychain()
		for index in 0..<2_000 { keychain.store("\(index)", service: "dev.lpm.vault", account: "vault-\(index)") }
		let move = LPMHomeMove(shared: keychain, app: keychain)
		let before = keychain.listingCount

		_ = try move.move(from: source, to: target) {}

		#expect(keychain.listingCount - before <= 4 * LPMHomeMove.servicesMoved.count, "\(keychain.listingCount - before) listings")
		#expect(try keychain.accounts(service: target.service("dev.lpm.vault")).count == 2_000)
	}

	@Test("a copy that can't be checked is removed with the rest, and the old home keeps everything")
	func uncheckedCopyIsRolledBack() throws {
		let user = try temporaryFolder()
		defer { try? FileManager.default.removeItem(at: user) }
		let source = LPMHome(defaultIn: user)
		let target = try #require(LPMHome.at(user.appendingPathComponent("relocated"), userHome: user))
		let keychain = MemoryLPMHomeKeychain()
		keychain.store("{}", service: "dev.lpm.vault", account: "vault-a")
		keychain.failingReadServices = [target.service("dev.lpm.vault")]
		var adopted = false

		#expect(throws: LPMHomeMoveError.self) {
			_ = try LPMHomeMove(shared: keychain, app: keychain).move(from: source, to: target) { adopted = true }
		}
		#expect(!adopted)
		#expect(keychain.services == ["dev.lpm.vault"])
	}

	@Test("a home whose files can't be listed is never read as holding none")
	func unlistableHomeIsAnError() throws {
		let user = try temporaryFolder()
		defer {
			chmod(user.appendingPathComponent("locked").path, 0o700)
			try? FileManager.default.removeItem(at: user)
		}
		let locked = user.appendingPathComponent("locked", isDirectory: true)
		try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
		try Data("{}".utf8).write(to: locked.appendingPathComponent("device-id"))
		chmod(locked.path, 0o300)

		#expect(throws: LPMHomeMoveError.self) { _ = try LPMHomeMove.stateFileNames(in: locked) }
		#expect(try LPMHomeMove.stateFileNames(in: user.appendingPathComponent("missing")).isEmpty)
	}

	@Test("a home folder swapped for another during a move stops it before the switch")
	func swappedHomeStopsTheMove() throws {
		let user = try temporaryFolder()
		defer { try? FileManager.default.removeItem(at: user) }
		let source = LPMHome(defaultIn: user)
		let target = try #require(LPMHome.at(user.appendingPathComponent("relocated"), userHome: user))
		let keychain = MemoryLPMHomeKeychain()
		keychain.store("{}", service: "dev.lpm.vault", account: "vault-a")
		try FileManager.default.createDirectory(at: source.url, withIntermediateDirectories: true)
		try Data("id".utf8).write(to: source.url.appendingPathComponent("device-id"))
		chmod(source.url.appendingPathComponent("device-id").path, 0o600)
		var adopted = false

		#expect(throws: LPMHomeMoveError.self) {
			_ = try LPMHomeMove(shared: keychain, app: keychain).move(from: source, to: target, prepareSource: {
				try FileManager.default.moveItem(at: source.url, to: user.appendingPathComponent(".lpm.saved"))
				try FileManager.default.createDirectory(at: source.url, withIntermediateDirectories: true)
			}) { adopted = true }
		}
		#expect(!adopted)
		#expect(keychain.services == ["dev.lpm.vault"])
		#expect(FileManager.default.fileExists(atPath: user.appendingPathComponent(".lpm.saved/device-id").path))
	}

	@Test("a move takes the home's publishing records, which belong to its env projects")
	func moveTakesPublishingRecords() throws {
		let user = try temporaryFolder()
		defer { try? FileManager.default.removeItem(at: user) }
		let source = LPMHome(defaultIn: user)
		let target = try #require(LPMHome.at(user.appendingPathComponent("relocated"), userHome: user))
		let shared = MemoryLPMHomeKeychain()
		let app = MemoryLPMHomeKeychain()
		shared.store("{}", service: "dev.lpm.vault", account: "vault-a")
		app.store("destinations", service: "dev.lpm.vault.publishing", account: "destinations:vault-a")
		app.store("token", service: "dev.lpm.vault.platforms", account: "connection")

		_ = try LPMHomeMove(shared: shared, app: app).move(from: source, to: target) {}

		#expect(app.services == ["dev.lpm.vault.platforms", target.service("dev.lpm.vault.publishing")].sorted())
		#expect(AppKeychainStore.publishing.service(in: target) == target.service("dev.lpm.vault.publishing"))
		#expect(AppKeychainStore.publishing.service(in: source) == "dev.lpm.vault.publishing")
		#expect(AppKeychainStore.platformConnections.service(in: target) == "dev.lpm.vault.platforms",
			"Platform connections belong to the account, not a home")
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
			_ = try LPMHomeMove(shared: keychain, app: keychain).move(from: LPMHome(defaultIn: user), to: target) {}
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
		store.lpmHomeMove = { _ in LPMHomeMove(shared: keychain, app: keychain) }
		store.lpmHomeCredentials = { _ in NoCredentials() }
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
		#expect(LPMHome.unfinishedMove(in: defaults) == nil)
		#expect(throws: KeychainStoreError.homeRetired, "Nothing in this launch writes into the home it left") {
			try VaultKeychainTransactionLock.openLockFile(home: LPMHome(defaultIn: user))
		}
		#expect(LPMHome.chosen(in: defaults, userHome: user) == target)
		#expect(relaunches == 1)
		#expect(!store.isUnlocked)
		#expect(biometrics.confirmationReasons.last?.contains("move your env projects and sign-in to") == true)
	}

	@MainActor
	private func movingStore(user: URL, defaults: UserDefaults, keychain: MemoryLPMHomeKeychain) -> VaultStore {
		let store = VaultStore(
			keychainService: MockKeychainService(), biometricService: MockBiometricService(),
			apiService: MockAPIService(), preferences: defaults)
		store.isUnlocked = true
		store.lpmHome = LPMHome(defaultIn: user)
		store.lpmHomeMove = { _ in LPMHomeMove(shared: keychain, app: keychain) }
		store.lpmHomeCredentials = { _ in NoCredentials() }
		store.relaunch = {}
		return store
	}

	@Test("a transaction waiting for a home's lock when a move retires the home never writes there")
	func retiredHomeRefusesWaiters() async throws {
		let user = try temporaryFolder()
		defer { try? FileManager.default.removeItem(at: user) }
		let home = try #require(LPMHome.at(user.appendingPathComponent("left"), userHome: user))
		let move = try VaultKeychainTransactionLock.openLockFile(home: home)
		let returned = Flag()
		let waiter = Task {
			defer { returned.set() }
			let lock = try await BlockingWork.run { try VaultKeychainTransactionLock.openLockFile(home: home) }
			_ = Darwin.close(lock)
		}
		try await quietPeriod()
		#expect(!returned.isSet, "The waiter waits for the move's lock")

		VaultKeychainTransactionLock.retire(home)
		_ = flock(move, LOCK_UN)
		_ = Darwin.close(move)

		await #expect(throws: KeychainStoreError.homeRetired) { try await waiter.value }
		#expect(throws: KeychainStoreError.homeRetired) { try VaultKeychainTransactionLock.openLockFile(home: home) }
	}

	@Test("a move waits for a refresh holding a session lock in the home it leaves")
	@MainActor
	func moveWaitsForARefresh() async throws {
		let user = try temporaryFolder()
		defer { try? FileManager.default.removeItem(at: user) }
		let domain = "lpm-home-\(UUID().uuidString)"
		let defaults = try #require(UserDefaults(suiteName: domain))
		defer { defaults.removePersistentDomain(forName: domain) }
		let keychain = MemoryLPMHomeKeychain()
		keychain.store("{}", service: "dev.lpm.vault", account: "vault-a")
		let store = movingStore(user: user, defaults: defaults, keychain: keychain)
		let target = try #require(LPMHome.at(user.appendingPathComponent("relocated"), userHome: user))
		let sessionLock = AuthSessionCoordinator(
			home: store.lpmHome, credentialBackend: NoCredentials(),
			refreshOperation: { _, _, _ in throw AuthSessionRefreshError.invalidResponse }
		).sessionLockURL(registryURL: "https://lpm.dev")
		let refreshing = DispatchSemaphore(value: 0)
		let release = DispatchSemaphore(value: 0)
		let refresh = Task.detached {
			try await CrossProcessFileLock.withExclusive(at: sessionLock) {
				refreshing.signal()
				await BlockingWork.run { release.wait() }
			}
		}
		await BlockingWork.run { refreshing.wait() }

		let change = Task { try await store.changeLPMHome(to: target, moving: true) }
		try #require(try await waitUntil { await CrossProcessFileLock.waitingTasks(at: sessionLock) == 1 })
		#expect(keychain.writesStarted == 0, "Nothing is copied while the refresh may still write the old home")

		release.signal()
		try await refresh.value
		try await change.value
		#expect(keychain.services == [target.service("dev.lpm.vault")])
	}

	@Test("a move upgrades the logins an older LPM version kept in the login keychain, so the new home has them")
	@MainActor
	func moveTakesLegacyLogins() async throws {
		let user = try temporaryFolder()
		defer { try? FileManager.default.removeItem(at: user) }
		let domain = "lpm-home-\(UUID().uuidString)"
		let defaults = try #require(UserDefaults(suiteName: domain))
		defer { defaults.removePersistentDomain(forName: domain) }
		let keychain = MemoryLPMHomeKeychain()
		let store = movingStore(user: user, defaults: defaults, keychain: keychain)
		let source = store.lpmHome
		let target = try #require(LPMHome.at(user.appendingPathComponent("relocated"), userHome: user))
		let legacy = MemoryAuthCredentialBackend()
		try await seedLegacyLogin(
			AuthSessionCredentials(token: "access", refreshToken: "refresh", expiresIn: 3_600,
				expiresAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(3_600))),
			registryURL: "https://lpm.dev",
			coordinator: AuthSessionCoordinator(
				home: source, credentialBackend: legacy,
				refreshOperation: { _, _, _ in throw AuthSessionRefreshError.invalidResponse }),
			backend: legacy, authority: source.url.appendingPathComponent(".credential-authority.json"))
		store.lpmHomeCredentials = { home in
			HomeLoginCredentials(keychain: keychain, service: home.service("lpm-cli"), legacy: legacy)
		}

		try await store.changeLPMHome(to: target, moving: true)

		let accounts = [AuthSessionCoordinator.accessAccount(registryURL: "https://lpm.dev"), AuthSessionCoordinator.refreshAccount(registryURL: "https://lpm.dev")]
		#expect(accounts.map { try? keychain.read(service: target.service("lpm-cli"), account: $0) } == [Data("access".utf8), Data("refresh".utf8)])
		#expect(try legacy.legacyAccounts().isEmpty)
		let authority = try String(contentsOf: target.url.appendingPathComponent(".credential-authority.json"), encoding: .utf8)
		#expect(authority.contains("shared_keychain") && !authority.contains("\"keychain\""))
	}

	@Test("quitting waits for a move to finish")
	@MainActor
	func quitWaitsForAMove() async throws {
		let user = try temporaryFolder()
		defer { try? FileManager.default.removeItem(at: user) }
		let domain = "lpm-home-\(UUID().uuidString)"
		let defaults = try #require(UserDefaults(suiteName: domain))
		defer { defaults.removePersistentDomain(forName: domain) }
		let keychain = MemoryLPMHomeKeychain()
		keychain.store("{}", service: "dev.lpm.vault", account: "vault-a")
		let gate = DispatchSemaphore(value: 0)
		keychain.writeGate = gate
		let store = movingStore(user: user, defaults: defaults, keychain: keychain)
		let target = try #require(LPMHome.at(user.appendingPathComponent("relocated"), userHome: user))

		let change = Task { try await store.changeLPMHome(to: target, moving: true) }
		try #require(try await waitUntil { keychain.writesStarted == 1 })
		#expect(store.isWriting)
		#expect(LPMHome.unfinishedMove(in: defaults) != nil, "A quit that doesn't wait leaves a record of the move")

		gate.signal()
		try await change.value
		#expect(!store.isWriting)
		#expect(LPMHome.unfinishedMove(in: defaults) == nil)
	}

	@Test("an unlock after a move stopped part way removes the copies it left, and keeps what changed since")
	@MainActor
	func unlockRemovesCopiesOfAStoppedMove() async throws {
		let user = try temporaryFolder()
		defer { try? FileManager.default.removeItem(at: user) }
		let domain = "lpm-home-\(UUID().uuidString)"
		let defaults = try #require(UserDefaults(suiteName: domain))
		defer { defaults.removePersistentDomain(forName: domain) }
		let keychain = MemoryLPMHomeKeychain()
		let store = movingStore(user: user, defaults: defaults, keychain: keychain)
		store.isUnlocked = false
		let source = store.lpmHome
		let target = try #require(LPMHome.at(user.appendingPathComponent("relocated"), userHome: user))
		keychain.store("{}", service: "dev.lpm.vault", account: "vault-a")
		keychain.store("{\"v\":1}", service: "dev.lpm.vault", account: "vault-b")
		keychain.store("{}", service: target.service("dev.lpm.vault"), account: "vault-a")
		keychain.store("{\"v\":2}", service: target.service("dev.lpm.vault"), account: "vault-b")
		keychain.store("{}", service: target.service("dev.lpm.vault"), account: "vault-c")
		LPMHome.beginMove(from: source, to: target, in: defaults)

		await store.unlock()

		#expect(try await waitUntil { LPMHome.unfinishedMove(in: defaults) == nil })
		#expect(keychain.accountNames(service: target.service("dev.lpm.vault")) == ["vault-b", "vault-c"])
		#expect(keychain.accountNames(service: "dev.lpm.vault") == ["vault-a", "vault-b"])
		#expect(LPMHome.leftovers(in: defaults) == nil)
	}

	@Test("after a move switched homes, the copies it left in the old home go, files included")
	@MainActor
	func switchedMoveRemovesTheOldCopies() async throws {
		let user = try temporaryFolder()
		defer { try? FileManager.default.removeItem(at: user) }
		let domain = "lpm-home-\(UUID().uuidString)"
		let defaults = try #require(UserDefaults(suiteName: domain))
		defer { defaults.removePersistentDomain(forName: domain) }
		let keychain = MemoryLPMHomeKeychain()
		let store = movingStore(user: user, defaults: defaults, keychain: keychain)
		let source = store.lpmHome
		let target = try #require(LPMHome.at(user.appendingPathComponent("relocated"), userHome: user))
		store.lpmHome = target
		keychain.store("{}", service: "dev.lpm.vault", account: "vault-a")
		keychain.store("{}", service: target.service("dev.lpm.vault"), account: "vault-a")
		for home in [source, target] {
			_ = try CLIFiles.prepareHome(home)
			try write("device", to: home.url.appendingPathComponent("device-id"))
			try write(home == source ? "older" : "newer", to: home.url.appendingPathComponent(".token-expiry.json"))
		}
		LPMHome.beginMove(from: source, to: target, in: defaults)

		try await store.finishUnfinishedLPMHomeMove()

		#expect(keychain.services == [target.service("dev.lpm.vault")])
		#expect(try LPMHomeMove.stateFileNames(in: source.url) == [".token-expiry.json"])
		#expect(try LPMHomeMove.stateFileNames(in: target.url) == [".token-expiry.json", "device-id"])
		#expect(LPMHome.unfinishedMove(in: defaults) == nil)
	}

	@Test("a move that couldn't remove its copies stays recorded until they're removed")
	@MainActor
	func copiesLeftStayRecorded() async throws {
		let user = try temporaryFolder()
		defer { try? FileManager.default.removeItem(at: user) }
		let domain = "lpm-home-\(UUID().uuidString)"
		let defaults = try #require(UserDefaults(suiteName: domain))
		defer { defaults.removePersistentDomain(forName: domain) }
		let keychain = MemoryLPMHomeKeychain()
		var relaunches = 0
		let store = movingStore(user: user, defaults: defaults, keychain: keychain)
		store.relaunch = { relaunches += 1 }
		let target = try #require(LPMHome.at(user.appendingPathComponent("relocated"), userHome: user))
		keychain.store("{}", service: "dev.lpm.vault", account: "vault-a")
		keychain.store("{}", service: "dev.lpm.vault", account: "vault-b")
		keychain.failingWrites = ["vault-b"]
		keychain.failingDeleteServices = [target.service("dev.lpm.vault")]

		await #expect(throws: LPMHomeMoveError.self) { try await store.changeLPMHome(to: target, moving: true) }
		#expect(relaunches == 0 && defaults.string(forKey: LPMHome.preferenceKey) == nil)
		#expect(keychain.accountNames(service: target.service("dev.lpm.vault")) == ["vault-a"])
		#expect(LPMHome.unfinishedMove(in: defaults) != nil)

		keychain.failingDeleteServices = []
		try await store.finishUnfinishedLPMHomeMove()
		#expect(keychain.services == ["dev.lpm.vault"])
		#expect(keychain.accountNames(service: "dev.lpm.vault") == ["vault-a", "vault-b"])
		#expect(LPMHome.unfinishedMove(in: defaults) == nil)
	}

	@Test("a folder chosen as the LPM home is placed off the main thread")
	@MainActor
	func chosenHomeIsPlacedOffMain() async throws {
		let user = try temporaryFolder()
		defer { try? FileManager.default.removeItem(at: user) }
		let domain = "lpm-home-\(UUID().uuidString)"
		let defaults = try #require(UserDefaults(suiteName: domain))
		defer { defaults.removePersistentDomain(forName: domain) }
		let store = movingStore(user: user, defaults: defaults, keychain: MemoryLPMHomeKeychain())
		let placed = PoolObservation()
		store.lpmHomeResolver = { url, userHome in
			placed.record()
			return LPMHome.at(url, userHome: userHome)
		}

		let home = await store.lpmHome(at: user.appendingPathComponent("tools/lpm"))

		#expect(home == LPMHome.at(user.appendingPathComponent("tools/lpm"), userHome: user))
		#expect(placed.stayedOffMainAndPool)
	}

	private func write(_ text: String, to url: URL) throws {
		try Data(text.utf8).write(to: url)
		chmod(url.path, 0o600)
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

	@Test("a home reached through a linked folder is used where it is, as the CLI opens it")
	func homeThroughLinkedFolder() throws {
		let user = try temporaryFolder()
		defer { try? FileManager.default.removeItem(at: user) }
		let real = user.appendingPathComponent("real", isDirectory: true)
		try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
		try FileManager.default.createSymbolicLink(at: user.appendingPathComponent("alias"), withDestinationURL: real)

		let home = try #require(LPMHome.at(user.appendingPathComponent("alias/lpm-home"), userHome: user))
		#expect(home.url.path == real.appendingPathComponent("lpm-home").path)
		#expect(home.scope == LPMHome.at(real.appendingPathComponent("lpm-home"), userHome: user)?.scope)

		let lock = try VaultKeychainTransactionLock.openLockFile(home: home)
		_ = flock(lock, LOCK_UN)
		_ = Darwin.close(lock)
		#expect(FileManager.default.fileExists(atPath: real.appendingPathComponent("lpm-home/.vault-keychain.lock").path))
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

private final class Flag: @unchecked Sendable {
	private let lock = NSLock()
	private var value = false

	var isSet: Bool { lock.withLock { value } }

	func set() { lock.withLock { value = true } }
}

/// Login credentials kept as the Keychain keeps them for a home: in its
/// login service in `keychain`, with older ones in `legacy`'s login keychain.
private struct HomeLoginCredentials: AuthCredentialBackend {
	let keychain: MemoryLPMHomeKeychain
	let service: String
	let legacy: MemoryAuthCredentialBackend

	func read(account: String) throws -> String? {
		try keychain.read(service: service, account: account).map { String(decoding: $0, as: UTF8.self) }
	}

	func write(_ credential: String, account: String) throws {
		try keychain.write(service: service, account: account, data: Data(credential.utf8), access: .automatic)
	}

	func delete(account: String) throws {
		_ = try keychain.delete(service: service, account: account)
	}

	func readLegacy(account: String) throws -> String? { try legacy.readLegacy(account: account) }
	func legacyAccounts() throws -> [String] { try legacy.legacyAccounts() }
	func deleteLegacy(account: String) throws { try legacy.deleteLegacy(account: account) }
}

private struct NoCredentials: AuthCredentialBackend {
	func read(account: String) throws -> String? { nil }
	func readLegacy(account: String) throws -> String? { nil }
	func legacyAccounts() throws -> [String] { [] }
	func deleteLegacy(account: String) throws {}
	func write(_ credential: String, account: String) throws {}
	func delete(account: String) throws {}
}
