import Darwin
import Foundation

/// A credential store that an LPM home's items move through: each account of
/// a service, with its CLI access, which the copy keeps.
protocol LPMHomeKeychain: Sendable {
	func accounts(service: String) throws -> [String: VaultCliAccess]
	func read(service: String, account: String) throws -> Data?
	func write(service: String, account: String, data: Data, access: VaultCliAccess) throws
	@discardableResult
	func delete(service: String, account: String) throws -> Bool
}

/// The app's own Keychain group, which the CLI can't read, as a move takes its
/// items. Its items take no CLI access setting.
struct AppGroupKeychain: LPMHomeKeychain {
	func accounts(service: String) throws -> [String: VaultCliAccess] {
		Dictionary(try AppKeychainBackend(service: service).accounts().map { ($0, .automatic) }) { first, _ in first }
	}

	func read(service: String, account: String) throws -> Data? {
		try AppKeychainBackend(service: service).read(account: account)
	}

	func write(service: String, account: String, data: Data, access: VaultCliAccess) throws {
		guard access == .automatic else { throw KeychainStoreError.integrityValidationFailed }
		try AppKeychainBackend(service: service).write(account: account, data: data)
	}

	func delete(service: String, account: String) throws -> Bool {
		try AppKeychainBackend(service: service).delete(account: account)
		return true
	}
}

enum LPMHomeMoveError: LocalizedError, Equatable, Sendable {
	case sameHome
	case targetNotEmpty(String)
	case targetExposed(String)
	case unreadable(String)
	case copyFailed(String)
	case homeChanged(String)
	/// The move failed for `reason`, and copies stayed in the home it was moving
	/// to, some of them env projects' newer data when `includesNewerData`; the
	/// next unlock removes them.
	case copiesLeft(reason: String, home: String, includesNewerData: Bool)

	/// Whether the move left copies in the home it was moving to.
	var leftCopies: Bool {
		if case .copiesLeft = self { true } else { false }
	}

	var errorDescription: String? {
		switch self {
		case .sameHome:
			"That's the LPM home the app uses already."
		case .targetNotEmpty(let home):
			"\(home) already holds login or env data, so nothing was moved there."
		case .targetExposed(let explanation):
			"\(explanation) LPM Vault kept the LPM home it uses."
		case .unreadable(let what):
			"Couldn't read \(what), so nothing was moved."
		case .copyFailed(let what):
			"Couldn't copy \(what), so nothing was moved."
		case .homeChanged(let home):
			"\(home) was moved or replaced during the move, so nothing was moved."
		case .copiesLeft(let reason, let home, let includesNewerData):
			"\(reason) Some copies stayed in \(home)\(includesNewerData ? ", among them env projects’ newer data" : ""); LPM Vault removes them the next time it unlocks."
		}
	}
}

/// Moves the login and env state an LPM home holds into another, where the
/// CLI with `LPM_HOME` set to it finds them: every item of the credential-store
/// services the app and the CLI share and of the home's publishing records,
/// under the new home's names, and the login and key-checkpoint files. Items
/// and files only the CLI keeps, such as file-backed fallbacks, stay where
/// they are.
struct LPMHomeMove: Sendable {
	/// A service a move takes, by name, and the store it's in.
	struct MovedService: Sendable {
		let name: String
		let keychain: any LPMHomeKeychain
	}

	/// The credential-store services the app and the CLI share in an LPM home.
	static let sharedServices = [
		VaultConstants.keychainService,
		VaultCrypto.wrappingKeyService,
		PersonalProjectCrypto.rootService,
		VaultConstants.cliAuthService,
	]
	/// The app's own services that belong to a home's env projects.
	static let appServices = [VaultConstants.publishingKeychainService]
	static let servicesMoved = sharedServices + appServices
	/// The login and env state files an LPM home holds, by name and by prefix.
	static let stateFiles = [".credential-authority.json", ".token-expiry.json", "device-id"]
	static let stateFilePrefixes = [".env-project-key-floor-", ".org-recipient-set-"]
	private static let maximumFileBytes = 16 * 1024 * 1024

	/// What an LPM home holds that a move takes.
	struct Contents: Equatable, Sendable {
		/// The env projects its index lists.
		var projects = 0
		/// Its items in the services a move takes.
		var items = 0
		/// Whether it holds a login.
		var signedIn = false
		/// Its login and env state files.
		var files: [String] = []

		var isEmpty: Bool { items == 0 && files.isEmpty }
	}

	let services: [MovedService]

	/// A move whose shared services are in `shared`, the group the CLI shares,
	/// and whose publishing records are in `app`, the app's own group.
	init(shared: any LPMHomeKeychain, app: any LPMHomeKeychain) {
		services = Self.sharedServices.map { MovedService(name: $0, keychain: shared) }
			+ Self.appServices.map { MovedService(name: $0, keychain: app) }
	}

	/// Whether any of `accounts`, in the vault service, holds an env project's
	/// newer data: a companion record or its marker.
	static func holdsNewerData(_ accounts: [String]) -> Bool {
		guard let described = try? CompanionEngine.describe(accounts) else { return false }
		return described.contains { if case .account = $0 { true } else { false } }
	}

	func contents(of home: LPMHome) throws -> Contents {
		var contents = Contents()
		for service in services {
			let accounts = try listing(service, in: home)
			contents.items += accounts.count
			if service.name == VaultConstants.keychainService {
				contents.projects = accounts.keys.count { $0.hasPrefix(VaultKeychainRecordContract.projectMetadataPrefix) }
			}
			if service.name == VaultConstants.cliAuthService, !accounts.isEmpty { contents.signedIn = true }
		}
		contents.files = try Self.stateFileNames(in: home.url)
		return contents
	}

	/// Copies what `source` holds into `target`, which must hold nothing,
	/// checks every copy, then runs `adopt`, which switches the app to
	/// `target`, and removes what `source` held. Holds both homes' transaction
	/// locks throughout, so the CLI changes neither meanwhile, and works in the
	/// two home folders it opened at the start, refusing to switch when either
	/// path has come to name another folder since. `prepareSource` runs under
	/// the locks before anything is copied. A failure before `adopt` removes
	/// the copies and leaves `source` as it was. Returns what couldn't be
	/// removed from `source` afterward.
	func move(
		from source: LPMHome, to target: LPMHome, prepareSource: () throws -> Void = {}, adopt: () throws -> Void
	) throws -> [String] {
		guard source.scope != target.scope else { throw LPMHomeMoveError.sameHome }
		let exposure: CLIFiles.HomeExposure?
		do { exposure = try CLIFiles.prepareHome(target) } catch { throw LPMHomeMoveError.copyFailed(error.message) }
		if let exposure { throw LPMHomeMoveError.targetExposed(exposure.explanation(of: "login and env secrets")) }

		let sourceLock = try VaultKeychainTransactionLock.openLockFile(home: source)
		defer { unlock(sourceLock) }
		let targetLock = try VaultKeychainTransactionLock.openLockFile(home: target)
		defer { unlock(targetLock) }
		let sourceFolder = try HomeFolder(source)
		let targetFolder = try HomeFolder(target)

		guard try contents(of: target).isEmpty else { throw LPMHomeMoveError.targetNotEmpty(target.displayPath) }
		try prepareSource()
		var copiedItems: [(service: MovedService, account: String)] = []
		var copiedFiles: [String] = []
		do {
			for service in services {
				let accounts = try listing(service, in: source)
				for (account, access) in accounts.sorted(by: { $0.key < $1.key }) {
					copiedItems.append((service, account))
					try copyItem(service: service, account: account, access: access, from: source, to: target)
				}
				let copied: [String: VaultCliAccess]
				do { copied = try service.keychain.accounts(service: target.service(service.name)) } catch {
					throw LPMHomeMoveError.copyFailed("the items of \(target.service(service.name))")
				}
				guard copied == accounts else { throw LPMHomeMoveError.copyFailed("the items of \(target.service(service.name))") }
			}
			for name in try sourceFolder.stateFileNames() {
				copiedFiles.append(name)
				try copyFile(named: name, from: sourceFolder, to: targetFolder)
			}
			try sourceFolder.verifyUnmoved()
			try targetFolder.verifyUnmoved()
			try adopt()
		} catch {
			var copiesLeft = false
			var accountsLeft: [String] = []
			for (service, account) in copiedItems {
				do { try service.keychain.delete(service: target.service(service.name), account: account) } catch {
					copiesLeft = true
					if service.name == VaultConstants.keychainService { accountsLeft.append(account) }
				}
			}
			for name in copiedFiles where unlinkat(targetFolder.descriptor, name, 0) != 0 && errno != ENOENT { copiesLeft = true }
			if copiesLeft {
				throw LPMHomeMoveError.copiesLeft(
					reason: error.localizedDescription, home: target.displayPath,
					includesNewerData: Self.holdsNewerData(accountsLeft))
			}
			throw error
		}

		var leftovers: [String] = []
		for (service, account) in copiedItems {
			do { try service.keychain.delete(service: source.service(service.name), account: account) }
			catch { leftovers.append("\(source.service(service.name)) \(account)") }
		}
		let sourceUnmoved = (try? sourceFolder.verifyUnmoved()) != nil
		for name in copiedFiles where !sourceUnmoved || (unlinkat(sourceFolder.descriptor, name, 0) != 0 && errno != ENOENT) {
			leftovers.append(source.url.appendingPathComponent(name).path)
		}
		return leftovers
	}

	/// Removes the copies an interrupted move left: from `from`, when the move
	/// switched to `to`, what `to` holds the same of; else from `to`, what
	/// `from` holds the same of. An item or file either home changed since
	/// differs, and stays. Returns what couldn't be removed.
	func removeCopies(between from: LPMHome, and to: LPMHome, switched: Bool) throws -> [String] {
		guard from.scope != to.scope else { return [] }
		let (kept, copies) = switched ? (to, from) : (from, to)
		let fromLock = try VaultKeychainTransactionLock.openLockFile(home: from)
		defer { unlock(fromLock) }
		let toLock = try VaultKeychainTransactionLock.openLockFile(home: to)
		defer { unlock(toLock) }
		let keptFolder = try HomeFolder(kept)
		let copiesFolder = try HomeFolder(copies)
		var left: [String] = []
		for service in services {
			for account in try listing(service, in: copies).keys.sorted() {
				guard let copy = try? service.keychain.read(service: copies.service(service.name), account: account),
					let original = try? service.keychain.read(service: kept.service(service.name), account: account),
					copy == original
				else { continue }
				do { try service.keychain.delete(service: copies.service(service.name), account: account) }
				catch { left.append("\(copies.service(service.name)) \(account)") }
			}
		}
		for name in try copiesFolder.stateFileNames() {
			guard let copy = try? Self.readStateFile(named: name, in: copiesFolder.descriptor),
				let original = try? Self.readStateFile(named: name, in: keptFolder.descriptor),
				copy == original
			else { continue }
			if unlinkat(copiesFolder.descriptor, name, 0) != 0, errno != ENOENT {
				left.append(copies.url.appendingPathComponent(name).path)
			}
		}
		return left
	}

	private func listing(_ service: MovedService, in home: LPMHome) throws -> [String: VaultCliAccess] {
		do { return try service.keychain.accounts(service: home.service(service.name)) } catch {
			throw LPMHomeMoveError.unreadable("the Keychain items of \(home.displayPath)")
		}
	}

	private func copyItem(service: MovedService, account: String, access: VaultCliAccess, from source: LPMHome, to target: LPMHome) throws {
		let what = "\(account) in \(source.service(service.name))"
		let data: Data
		do {
			guard let stored = try service.keychain.read(service: source.service(service.name), account: account) else {
				throw LPMHomeMoveError.unreadable(what)
			}
			data = stored
		} catch let error as LPMHomeMoveError { throw error } catch { throw LPMHomeMoveError.unreadable(what) }
		do {
			try service.keychain.write(service: target.service(service.name), account: account, data: data, access: access)
			guard try service.keychain.read(service: target.service(service.name), account: account) == data else {
				throw LPMHomeMoveError.copyFailed(what)
			}
		} catch let error as LPMHomeMoveError { throw error } catch { throw LPMHomeMoveError.copyFailed(what) }
	}

	/// Whether `name` is one of the login and env state files a home holds.
	static func isStateFile(_ name: String) -> Bool {
		stateFiles.contains(name) || stateFilePrefixes.contains { name.hasPrefix($0) }
	}

	/// The login and env state files in the home at `url`: none where it
	/// doesn't exist, an error where it can't be listed.
	static func stateFileNames(in url: URL) throws -> [String] {
		let descriptor = url.withUnsafeFileSystemRepresentation { path in
			path.map { Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC) } ?? -1
		}
		guard descriptor >= 0 else {
			if errno == ENOENT { return [] }
			throw LPMHomeMoveError.unreadable(url.path)
		}
		defer { _ = Darwin.close(descriptor) }
		return try stateFileNames(in: descriptor, shown: url.path)
	}

	fileprivate static func stateFileNames(in directory: Int32, shown: String) throws -> [String] {
		let listed = dup(directory)
		guard listed >= 0, let stream = fdopendir(listed) else {
			if listed >= 0 { _ = Darwin.close(listed) }
			throw LPMHomeMoveError.unreadable(shown)
		}
		defer { closedir(stream) }
		rewinddir(stream)
		var names: [String] = []
		while true {
			errno = 0
			guard let entry = readdir(stream) else {
				guard errno == 0 else { throw LPMHomeMoveError.unreadable(shown) }
				break
			}
			let name = withUnsafeBytes(of: entry.pointee.d_name) { bytes in
				String(decoding: bytes.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self)
			}
			if isStateFile(name) { names.append(name) }
		}
		return names.sorted()
	}

	/// Copies the regular file `name` from one home folder to the other
	/// owner-only, without the access entries the target inherits, never over
	/// a file, and checks the copy.
	private func copyFile(named name: String, from source: HomeFolder, to target: HomeFolder) throws {
		let data = try Self.readStateFile(named: name, in: source.descriptor)
		let directory = target.descriptor
		let temporary = ".\(name).move.\(UUID().uuidString)"
		let file = Darwin.openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
		guard file >= 0 else { throw LPMHomeMoveError.copyFailed(name) }
		var keepTemporary = false
		defer { if !keepTemporary { _ = Darwin.unlinkat(directory, temporary, 0) } }
		do {
			defer { _ = Darwin.close(file) }
			guard SecureFileWriter.removeExtendedACL(from: file) == nil, Darwin.fchmod(file, 0o600) == 0 else {
				throw LPMHomeMoveError.copyFailed(name)
			}
			try data.withUnsafeBytes { buffer in
				var offset = 0
				while offset < buffer.count {
					let written = Darwin.write(file, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
					if written < 0, errno == EINTR { continue }
					guard written > 0 else { throw LPMHomeMoveError.copyFailed(name) }
					offset += written
				}
			}
			guard Darwin.fsync(file) == 0 else { throw LPMHomeMoveError.copyFailed(name) }
		}
		guard Darwin.renameatx_np(directory, temporary, directory, name, UInt32(RENAME_EXCL)) == 0 else {
			throw LPMHomeMoveError.copyFailed(name)
		}
		keepTemporary = true
		guard Darwin.fsync(directory) == 0, (try? Self.readStateFile(named: name, in: directory)) == data else {
			throw LPMHomeMoveError.copyFailed(name)
		}
	}

	/// The bytes of the regular file `name` in the open folder `directory`,
	/// which its owner alone can read: never a link, a hard-linked file or one
	/// past 16 MiB.
	static func readStateFile(named name: String, in directory: Int32) throws -> Data {
		let descriptor = Darwin.openat(directory, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
		guard descriptor >= 0 else { throw LPMHomeMoveError.unreadable(name) }
		defer { _ = Darwin.close(descriptor) }
		var metadata = stat()
		guard Darwin.fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
			metadata.st_uid == Darwin.geteuid(), metadata.st_nlink == 1,
			metadata.st_size >= 0, metadata.st_size <= maximumFileBytes
		else { throw LPMHomeMoveError.unreadable(name) }
		var data = Data(count: Int(metadata.st_size))
		let count = data.withUnsafeMutableBytes { buffer -> Int in
			var offset = 0
			while offset < buffer.count {
				let read = Darwin.read(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
				if read < 0, errno == EINTR { continue }
				guard read > 0 else { break }
				offset += read
			}
			return offset
		}
		guard count == data.count else { throw LPMHomeMoveError.unreadable(name) }
		return data
	}

	private func unlock(_ descriptor: Int32) {
		_ = flock(descriptor, LOCK_UN)
		_ = Darwin.close(descriptor)
	}
}

/// An LPM home's folder, open for the whole of a move, so renaming or
/// replacing it meanwhile can't send the move's file work elsewhere.
private final class HomeFolder {
	let descriptor: Int32
	private let home: LPMHome
	private let device: dev_t
	private let inode: ino_t

	init(_ home: LPMHome) throws {
		let descriptor = home.url.withUnsafeFileSystemRepresentation { path in
			path.map { Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW) } ?? -1
		}
		guard descriptor >= 0 else { throw LPMHomeMoveError.unreadable(home.displayPath) }
		var metadata = stat()
		guard Darwin.fstat(descriptor, &metadata) == 0 else {
			_ = Darwin.close(descriptor)
			throw LPMHomeMoveError.unreadable(home.displayPath)
		}
		self.descriptor = descriptor
		self.home = home
		device = metadata.st_dev
		inode = metadata.st_ino
	}

	deinit { _ = Darwin.close(descriptor) }

	func stateFileNames() throws -> [String] {
		try LPMHomeMove.stateFileNames(in: descriptor, shown: home.displayPath)
	}

	/// Fails when the home's path no longer names the folder open here.
	func verifyUnmoved() throws {
		var metadata = stat()
		let status = home.url.withUnsafeFileSystemRepresentation { path in
			path.map { Darwin.lstat($0, &metadata) } ?? -1
		}
		guard status == 0, metadata.st_dev == device, metadata.st_ino == inode else {
			throw LPMHomeMoveError.homeChanged(home.displayPath)
		}
	}
}
