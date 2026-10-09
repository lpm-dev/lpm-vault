import Darwin
import Foundation

/// Reports changes to a project folder's lpm.json, whether it's written in
/// place or replaced, as editors and the LPM CLI save it. Changes in quick
/// succession arrive as one.
enum ProjectConfigWatcher {
	static func changes(inFolder folder: String, settling: DispatchTimeInterval = .milliseconds(250)) -> AsyncStream<Void> {
		AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
			let watcher = Watcher(folder: folder, settling: settling) { continuation.yield() }
			watcher.start()
			continuation.onTermination = { _ in watcher.stop() }
		}
	}
}

/// Watches the folder for lpm.json being replaced and the file for writes.
/// All state lives on `queue`.
private final class Watcher: @unchecked Sendable {
	private let folder: String
	private let settling: DispatchTimeInterval
	private let onChange: @Sendable () -> Void
	private let queue = DispatchQueue(label: "dev.lpm.vault.lpm-json-watch")
	private var folderSource: DispatchSourceFileSystemObject?
	private var fileSource: DispatchSourceFileSystemObject?
	private var pending: DispatchWorkItem?
	private var stopped = false

	init(folder: String, settling: DispatchTimeInterval, onChange: @escaping @Sendable () -> Void) {
		self.folder = folder
		self.settling = settling
		self.onChange = onChange
	}

	func start() {
		queue.async { [self] in
			folderSource = source(for: folder, events: [.write, .rename, .delete, .link]) { [weak self] in
				self?.watchFile()
				self?.changed()
			}
			watchFile()
		}
	}

	func stop() {
		queue.async { [self] in
			stopped = true
			pending?.cancel()
			folderSource?.cancel()
			fileSource?.cancel()
			folderSource = nil
			fileSource = nil
		}
	}

	/// Follows lpm.json to the file now at its path, since a save that
	/// replaces it leaves the old descriptor on the old file.
	private func watchFile() {
		fileSource?.cancel()
		fileSource = source(for: folder + "/lpm.json", events: [.write, .extend, .delete, .rename, .revoke]) { [weak self] in
			self?.changed()
		}
	}

	private func changed() {
		guard !stopped else { return }
		pending?.cancel()
		let work = DispatchWorkItem { [weak self] in
			guard let self, !stopped else { return }
			onChange()
		}
		pending = work
		queue.asyncAfter(deadline: .now() + settling, execute: work)
	}

	private func source(for path: String, events: DispatchSource.FileSystemEvent, handler: @escaping () -> Void) -> DispatchSourceFileSystemObject? {
		let descriptor = open(path, O_EVTONLY | O_CLOEXEC)
		guard descriptor >= 0 else { return nil }
		let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: events, queue: queue)
		source.setEventHandler(handler: handler)
		source.setCancelHandler { close(descriptor) }
		source.resume()
		return source
	}
}
