import Darwin

/// Bytes the app owns and zeroes when it lets them go, for what holds many
/// secrets at once, such as a backup's payload. They're written once, as
/// they're made, and only lent out after, since a copy is one this can't zero.
final class SecretBytes: @unchecked Sendable {
	private let storage: UnsafeMutableRawBufferPointer

	var count: Int { storage.count }

	/// `count` bytes that `write` fills, all of them, before anything reads
	/// them; they start zeroed.
	init(count: Int, write: (UnsafeMutableRawBufferPointer) throws -> Void) rethrows {
		// Kept local until written: an initializer that throws once every
		// stored property is set still runs deinit, which would free it again.
		let storage = UnsafeMutableRawBufferPointer.allocate(byteCount: count, alignment: 1)
		storage.initializeMemory(as: UInt8.self, repeating: 0)
		do {
			try write(storage)
		} catch {
			Self.wipe(storage)
			storage.deallocate()
			throw error
		}
		self.storage = storage
	}

	/// A copy of `bytes`, for bytes that someone else is about to zero.
	convenience init(copying bytes: UnsafeRawBufferPointer) {
		self.init(count: bytes.count) { storage in
			storage.copyMemory(from: bytes)
		}
	}

	deinit {
		Self.wipe(storage)
		storage.deallocate()
	}

	func withUnsafeBytes<T>(_ body: (UnsafeRawBufferPointer) throws -> T) rethrows -> T {
		try body(UnsafeRawBufferPointer(storage))
	}

	private static func wipe(_ storage: UnsafeMutableRawBufferPointer) {
		guard let base = storage.baseAddress, !storage.isEmpty else { return }
		_ = memset_s(base, storage.count, 0, storage.count)
	}
}
