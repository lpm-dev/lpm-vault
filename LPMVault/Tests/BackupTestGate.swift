import Foundation

@testable import LPMVault

final class BackupTestGate: @unchecked Sendable {
	private let condition = NSCondition()
	private var entered = false
	private var released = false

	var isWaiting: Bool { condition.withLock { entered && !released } }

	func pause() {
		condition.lock()
		entered = true
		while !released { condition.wait() }
		condition.unlock()
	}

	func release() {
		condition.lock()
		released = true
		condition.broadcast()
		condition.unlock()
	}
}

final class GatedBackupKeyBackend: KeychainStoreBackend, @unchecked Sendable {
	let base = InMemoryKeychainBackend()
	let gate = BackupTestGate()
	private let lock = NSLock()
	private var armed = false

	func arm() { lock.withLock { armed = true } }

	func read(service: String, account: String) throws -> Data? { try base.read(service: service, account: account) }
	func write(service: String, account: String, data: Data) throws { try base.write(service: service, account: account, data: data) }
	func write(service: String, account: String, data: Data, access: VaultCliAccess) throws {
		try base.write(service: service, account: account, data: data, access: access)
	}
	func cliAccess(service: String, account: String) throws -> VaultCliAccess { try base.cliAccess(service: service, account: account) }
	func setCliAccess(service: String, account: String, access: VaultCliAccess) throws -> VaultCliAccess {
		try base.setCliAccess(service: service, account: account, access: access)
	}
	func add(service: String, account: String, data: Data) throws {
		let pause = lock.withLock {
			let pause = armed
			armed = false
			return pause
		}
		if pause { gate.pause() }
		try base.add(service: service, account: account, data: data)
	}
	func delete(service: String, account: String) throws -> Bool { try base.delete(service: service, account: account) }
	func accounts(service: String) throws -> [String: VaultCliAccess] { try base.accounts(service: service) }
}
