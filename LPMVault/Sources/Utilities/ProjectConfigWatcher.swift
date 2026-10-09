import Darwin
import Foundation

/// Reports changes to a project folder's lpm.json, whether it's written in
/// place or replaced, as editors and the LPM CLI save it. Changes in quick
/// succession arrive as one, and at least every `maximumDelay` while they
/// continue. A folder that's missing, or deleted and made again, is watched
/// once it's at its path.
enum ProjectConfigWatcher {
	static func changes(
		inFolder folder: String, settling: DispatchTimeInterval = .milliseconds(250), maximumDelay: DispatchTimeInterval = .seconds(1),
		retryingEvery retry: DispatchTimeInterval = .seconds(1)
	) -> AsyncStream<Void> {
		AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
			let watcher = Watcher(folder: folder, settling: settling, maximumDelay: maximumDelay, retry: retry) { continuation.yield() }
			watcher.start()
			continuation.onTermination = { _ in watcher.stop() }
		}
	}
}

/// Watches the folder for lpm.json being added, replaced, or removed, and the
/// file for writes. lpm.json comes from the project, so only a regular file is
/// opened, never followed through a link: opening a pipe or a device could
/// block the queue `stop()` runs on, or reach a device's driver. All state
/// lives on `queue`, which nothing blocks.
private final class Watcher: @unchecked Sendable {
	private let folder: String
	private let file: String
	private let settling: DispatchTimeInterval
	private let maximumDelay: DispatchTimeInterval
	private let retry: DispatchTimeInterval
	private let onChange: @Sendable () -> Void
	private let queue = DispatchQueue(label: "dev.lpm.vault.lpm-json-watch")
	private var folderSource: DispatchSourceFileSystemObject?
	private var fileSource: DispatchSourceFileSystemObject?
	private var pending: DispatchWorkItem?
	private var reopening: DispatchWorkItem?
	/// When the first change of the burst being settled arrived.
	private var burstStart: DispatchTime?
	/// lpm.json as last seen, which folder events about other entries leave as it is.
	private var seen: FileState?
	private var stopped = false

	/// What identifies the entry at lpm.json's path and its last change.
	private enum FileState: Equatable {
		case missing
		case file(device: dev_t, inode: ino_t, size: off_t, modified: timespec, changed: timespec)
		/// Not a regular file, such as a link or a pipe; it isn't opened.
		case other(device: dev_t, inode: ino_t, mode: mode_t)

		static func == (lhs: Self, rhs: Self) -> Bool {
			switch (lhs, rhs) {
			case (.missing, .missing): true
			case let (.file(d1, i1, s1, m1, c1), .file(d2, i2, s2, m2, c2)):
				d1 == d2 && i1 == i2 && s1 == s2 && m1.tv_sec == m2.tv_sec && m1.tv_nsec == m2.tv_nsec && c1.tv_sec == c2.tv_sec && c1.tv_nsec == c2.tv_nsec
			case let (.other(d1, i1, m1), .other(d2, i2, m2)): d1 == d2 && i1 == i2 && m1 == m2
			default: false
			}
		}
	}

	init(folder: String, settling: DispatchTimeInterval, maximumDelay: DispatchTimeInterval, retry: DispatchTimeInterval, onChange: @escaping @Sendable () -> Void) {
		self.folder = folder
		file = folder + "/lpm.json"
		self.settling = settling
		self.maximumDelay = maximumDelay
		self.retry = retry
		self.onChange = onChange
	}

	func start() {
		queue.async { [self] in watchFolder() }
	}

	func stop() {
		queue.async { [self] in
			stopped = true
			pending?.cancel()
			reopening?.cancel()
			folderSource?.cancel()
			fileSource?.cancel()
			folderSource = nil
			fileSource = nil
		}
	}

	/// Watches the folder at the path, or tries again later while there's none.
	/// lpm.json that differs from what was seen before is a change.
	private func watchFolder() {
		guard !stopped else { return }
		reopening = nil
		let descriptor = open(folder, O_EVTONLY | O_DIRECTORY | O_NONBLOCK | O_CLOEXEC)
		guard descriptor >= 0 else {
			note(.missing)
			scheduleReopen()
			return
		}
		let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .link, .rename, .delete, .revoke], queue: queue)
		source.setEventHandler { [weak self, weak source] in
			guard let self, let source else { return }
			folderChanged(source.data)
		}
		source.setCancelHandler { close(descriptor) }
		source.resume()
		folderSource = source
		note(state())
		watchFile()
	}

	private func folderChanged(_ events: DispatchSource.FileSystemEvent) {
		if !events.isDisjoint(with: [.rename, .delete, .revoke]) {
			// The folder moved or went away; watch what's at its path instead.
			folderSource?.cancel()
			folderSource = nil
			fileSource?.cancel()
			fileSource = nil
			watchFolder()
			return
		}
		let now = state()
		guard now != seen else { return }
		note(now)
		watchFile()
	}

	/// Records what's at lpm.json's path; anything other than what was seen
	/// before is a change.
	private func note(_ now: FileState) {
		defer { seen = now }
		if let seen, seen != now { changed() }
	}

	private func scheduleReopen() {
		let work = DispatchWorkItem { [weak self] in self?.watchFolder() }
		reopening = work
		queue.asyncAfter(deadline: .now() + retry, execute: work)
	}

	/// The entry at lpm.json's path, without following a link.
	private func state() -> FileState {
		var info = stat()
		guard lstat(file, &info) == 0 else { return .missing }
		guard info.st_mode & S_IFMT == S_IFREG else { return .other(device: info.st_dev, inode: info.st_ino, mode: info.st_mode) }
		return .file(device: info.st_dev, inode: info.st_ino, size: info.st_size, modified: info.st_mtimespec, changed: info.st_ctimespec)
	}

	/// Follows lpm.json to the file now at its path, since a save that
	/// replaces it leaves the old descriptor on the old file.
	private func watchFile() {
		fileSource?.cancel()
		fileSource = nil
		guard case .file(_, let inode, _, _, _)? = seen else { return }
		let descriptor = open(file, O_EVTONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
		guard descriptor >= 0 else { return }
		var info = stat()
		guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_ino == inode else {
			close(descriptor)
			return
		}
		let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .extend, .delete, .rename, .revoke], queue: queue)
		source.setEventHandler { [weak self, weak source] in
			guard let self, let source else { return }
			seen = state()
			if !source.data.isDisjoint(with: [.delete, .rename, .revoke]) { watchFile() }
			changed()
		}
		source.setCancelHandler { close(descriptor) }
		source.resume()
		fileSource = source
	}

	/// Reports once the changes settle, or once they've gone on for `maximumDelay`.
	private func changed() {
		guard !stopped else { return }
		pending?.cancel()
		let now = DispatchTime.now()
		let start = burstStart ?? now
		burstStart = start
		let work = DispatchWorkItem { [weak self] in
			guard let self, !stopped else { return }
			burstStart = nil
			onChange()
		}
		pending = work
		queue.asyncAfter(deadline: min(now + settling, start + maximumDelay), execute: work)
	}
}
