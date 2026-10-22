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

enum LPMHomeMoveError: LocalizedError, Equatable, Sendable {
	case sameHome
	case targetNotEmpty(String)
	case targetExposed(String)
	case unreadable(String)
	case copyFailed(String)

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
		}
	}
}

/// Moves the login and env state an LPM home holds into another, where the
/// CLI with `LPM_HOME` set to it finds them: every item of the credential-store
/// services the app and the CLI share, under the new home's names, and the
/// login and key-checkpoint files. Items and files only the CLI keeps, such
/// as file-backed fallbacks, stay where they are.
struct LPMHomeMove: Sendable {
	/// The credential-store services the app and the CLI share in an LPM home.
	static let services = [
		VaultConstants.keychainService,
		VaultCrypto.wrappingKeyService,
		PersonalProjectCrypto.rootService,
		VaultConstants.cliAuthService,
	]
	/// The login and env state files an LPM home holds, by name and by prefix.
	static let stateFiles = [".credential-authority.json", ".token-expiry.json", "device-id"]
	static let stateFilePrefixes = [".env-project-key-floor-", ".org-recipient-set-"]
	private static let maximumFileBytes = 16 * 1024 * 1024

	/// What an LPM home holds that a move takes.
	struct Contents: Equatable, Sendable {
		/// The env projects its index lists.
		var projects = 0
		/// Its items in the shared credential-store services.
		var items = 0
		/// Whether it holds a login.
		var signedIn = false
		/// Its login and env state files.
		var files: [String] = []

		var isEmpty: Bool { items == 0 && files.isEmpty }
	}

	let keychain: any LPMHomeKeychain

	func contents(of home: LPMHome) throws -> Contents {
		var contents = Contents()
		for service in Self.services {
			let accounts: [String: VaultCliAccess]
			do { accounts = try keychain.accounts(service: home.service(service)) } catch {
				throw LPMHomeMoveError.unreadable("the Keychain items of \(home.displayPath)")
			}
			contents.items += accounts.count
			if service == VaultConstants.keychainService {
				contents.projects = accounts.keys.count { $0.hasPrefix(VaultKeychainRecordContract.projectMetadataPrefix) }
			}
			if service == VaultConstants.cliAuthService, !accounts.isEmpty { contents.signedIn = true }
		}
		contents.files = Self.stateFileNames(in: home.url)
		return contents
	}

	/// Copies what `source` holds into `target`, which must hold nothing,
	/// checks every copy, then runs `adopt`, which switches the app to
	/// `target`, and removes what `source` held. Holds both homes' transaction
	/// locks throughout, so the CLI changes neither meanwhile. A failure before
	/// `adopt` removes the copies and leaves `source` as it was. Returns what
	/// couldn't be removed from `source` afterward.
	func move(from source: LPMHome, to target: LPMHome, adopt: () throws -> Void) throws -> [String] {
		guard source.scope != target.scope else { throw LPMHomeMoveError.sameHome }
		let exposure: CLIFiles.HomeExposure?
		do { exposure = try CLIFiles.prepareHome(target) } catch { throw LPMHomeMoveError.copyFailed(error.message) }
		if let exposure { throw LPMHomeMoveError.targetExposed(exposure.explanation(of: "login and env secrets")) }

		let sourceLock = try VaultKeychainTransactionLock.openLockFile(home: source)
		defer { unlock(sourceLock) }
		let targetLock = try VaultKeychainTransactionLock.openLockFile(home: target)
		defer { unlock(targetLock) }

		guard try contents(of: target).isEmpty else { throw LPMHomeMoveError.targetNotEmpty(target.displayPath) }
		var copiedItems: [(service: String, account: String)] = []
		var copiedFiles: [String] = []
		do {
			for service in Self.services {
				let accounts: [String: VaultCliAccess]
				do { accounts = try keychain.accounts(service: source.service(service)) } catch {
					throw LPMHomeMoveError.unreadable("the Keychain items of \(source.displayPath)")
				}
				for (account, access) in accounts.sorted(by: { $0.key < $1.key }) {
					try copyItem(service: service, account: account, access: access, from: source, to: target)
					copiedItems.append((service, account))
				}
			}
			for name in Self.stateFileNames(in: source.url) {
				try copyFile(named: name, from: source.url, to: target.url)
				copiedFiles.append(name)
			}
			try adopt()
		} catch {
			for (service, account) in copiedItems { _ = try? keychain.delete(service: target.service(service), account: account) }
			for name in copiedFiles { _ = Darwin.unlink(target.url.appendingPathComponent(name).path) }
			throw error
		}

		var leftovers: [String] = []
		for (service, account) in copiedItems {
			do { try keychain.delete(service: source.service(service), account: account) }
			catch { leftovers.append("\(source.service(service)) \(account)") }
		}
		for name in copiedFiles where Darwin.unlink(source.url.appendingPathComponent(name).path) != 0 && errno != ENOENT {
			leftovers.append(source.url.appendingPathComponent(name).path)
		}
		return leftovers
	}

	private func copyItem(service: String, account: String, access: VaultCliAccess, from source: LPMHome, to target: LPMHome) throws {
		let what = "\(account) in \(source.service(service))"
		let data: Data
		do {
			guard let stored = try keychain.read(service: source.service(service), account: account) else {
				throw LPMHomeMoveError.unreadable(what)
			}
			data = stored
		} catch let error as LPMHomeMoveError { throw error } catch { throw LPMHomeMoveError.unreadable(what) }
		do {
			try keychain.write(service: target.service(service), account: account, data: data, access: access)
			guard try keychain.read(service: target.service(service), account: account) == data,
				try keychain.accounts(service: target.service(service))[account] == access
			else { throw LPMHomeMoveError.copyFailed(what) }
		} catch let error as LPMHomeMoveError { throw error } catch { throw LPMHomeMoveError.copyFailed(what) }
	}

	/// The login and env state files in the home at `url`.
	static func stateFileNames(in url: URL) -> [String] {
		let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
		return names.filter { name in
			stateFiles.contains(name) || stateFilePrefixes.contains { name.hasPrefix($0) && !name.contains("/") }
		}.sorted()
	}

	/// Copies the regular file `name` from one home to the other owner-only,
	/// without the access entries the target inherits, never over a file, and
	/// checks the copy.
	private func copyFile(named name: String, from source: URL, to target: URL) throws {
		let data = try Self.readStateFile(named: name, in: source)
		let directory = target.withUnsafeFileSystemRepresentation { path in
			path.map { Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW) } ?? -1
		}
		guard directory >= 0 else { throw LPMHomeMoveError.copyFailed(name) }
		defer { _ = Darwin.close(directory) }
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
		guard Darwin.fsync(directory) == 0, (try? Self.readStateFile(named: name, in: target)) == data else {
			throw LPMHomeMoveError.copyFailed(name)
		}
	}

	/// The bytes of the regular file `name` in `directory`, which its owner
	/// alone can read: never a link, a hard-linked file or one past 16 MiB.
	static func readStateFile(named name: String, in directory: URL) throws -> Data {
		let descriptor = directory.appendingPathComponent(name).withUnsafeFileSystemRepresentation { path in
			path.map { Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK) } ?? -1
		}
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
