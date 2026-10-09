import Darwin
import Foundation

/// Reports changes to a project folder's lpm.json and to the schemas it
/// imports, `imports` being their paths in the folder, whether a file is
/// written in place or replaced, as editors, the LPM CLI and git save it.
/// Changes in quick succession arrive as one, and at least every
/// `maximumDelay` while they continue. A folder that's missing, or deleted
/// and made again, is watched once it's at its path.
enum ProjectConfigWatcher {
	static func changes(
		inFolder folder: String, imports: [String] = [], settling: DispatchTimeInterval = .milliseconds(250),
		maximumDelay: DispatchTimeInterval = .seconds(1), retryingEvery retry: DispatchTimeInterval = .seconds(1)
	) -> AsyncStream<Void> {
		AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
			let watch = Watch(root: folder, files: ["lpm.json"] + imports, settling: settling, maximumDelay: maximumDelay, retry: retry) {
				continuation.yield()
			}
			watch.start()
			continuation.onTermination = { _ in watch.stop() }
		}
	}
}

/// Watches each folder that holds a watched file for entries being added,
/// replaced, or removed, and each file for writes: one descriptor for each
/// folder however many files it holds, and one for each file. Folders below
/// the project folder are opened a component at a time, never through a
/// link, as the engine reads them. lpm.json and what it imports come from
/// the project, so only a regular file is opened, never followed through a
/// link: opening a pipe or a device could block the queue `stop()` runs on,
/// or reach a device's driver. All state lives on `queue`, which nothing blocks.
private final class Watch: @unchecked Sendable {
	private final class Folder {
		/// Its path below the project folder; empty for the project folder.
		let components: [String]
		/// The files watched in it, by name.
		var files: [String: File] = [:]
		var source: DispatchSourceFileSystemObject?
		/// The folder's descriptor while `source` is open; the source closes it.
		var descriptor: Int32 = -1
		var reopening: DispatchWorkItem?

		init(components: [String]) { self.components = components }
	}

	private final class File {
		/// The file as last seen, which folder events about other entries leave as it is.
		var seen: FileState?
		var source: DispatchSourceFileSystemObject?
	}

	/// What identifies the entry at a file's path and its last change.
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

	private let root: String
	private let folders: [Folder]
	private let settling: DispatchTimeInterval
	private let maximumDelay: DispatchTimeInterval
	private let retry: DispatchTimeInterval
	private let onChange: @Sendable () -> Void
	private let queue = DispatchQueue(label: "dev.lpm.vault.lpm-json-watch")
	private var pending: DispatchWorkItem?
	/// When the first change of the burst being settled arrived.
	private var burstStart: DispatchTime?
	private var stopped = false

	/// `files` are paths in the project folder `root`; one that leaves the
	/// folder isn't watched.
	init(root: String, files: [String], settling: DispatchTimeInterval, maximumDelay: DispatchTimeInterval, retry: DispatchTimeInterval,
		onChange: @escaping @Sendable () -> Void)
	{
		self.root = root
		var byPath: [[String]: Folder] = [:]
		var order: [Folder] = []
		for path in files {
			var components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init).filter { $0 != "." }
			guard let name = components.popLast(), !components.contains(".."), name != ".." else { continue }
			let folder = byPath[components] ?? {
				let folder = Folder(components: components)
				byPath[components] = folder
				order.append(folder)
				return folder
			}()
			folder.files[name] = File()
		}
		folders = order
		self.settling = settling
		self.maximumDelay = maximumDelay
		self.retry = retry
		self.onChange = onChange
	}

	func start() {
		queue.async { [self] in for folder in folders { watch(folder) } }
	}

	func stop() {
		queue.async { [self] in
			stopped = true
			pending?.cancel()
			for folder in folders { close(folder) }
		}
	}

	/// Opens the folder below the project folder a component at a time
	/// without following links; -1 when it isn't there.
	private func open(_ folder: Folder) -> Int32 {
		var current = Darwin.open(root, O_EVTONLY | O_DIRECTORY | O_NONBLOCK | O_CLOEXEC)
		for component in folder.components {
			guard current >= 0 else { return -1 }
			let next = openat(current, component, O_EVTONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
			Darwin.close(current)
			current = next
		}
		return current
	}

	private func close(_ folder: Folder) {
		folder.reopening?.cancel()
		folder.reopening = nil
		folder.source?.cancel()
		folder.source = nil
		folder.descriptor = -1
		for file in folder.files.values {
			file.source?.cancel()
			file.source = nil
		}
	}

	/// Watches the folder at its path, or tries again later while there's
	/// none. A file that differs from what was seen before is a change.
	private func watch(_ folder: Folder) {
		guard !stopped else { return }
		close(folder)
		let descriptor = open(folder)
		guard descriptor >= 0 else {
			for name in folder.files.keys { note(.missing, for: name, in: folder) }
			let work = DispatchWorkItem { [weak self, weak folder] in
				guard let self, let folder else { return }
				watch(folder)
			}
			folder.reopening = work
			queue.asyncAfter(deadline: .now() + retry, execute: work)
			return
		}
		let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .link, .rename, .delete, .revoke], queue: queue)
		source.setEventHandler { [weak self, weak folder, weak source] in
			guard let self, let folder, let source else { return }
			folderChanged(folder, events: source.data)
		}
		source.setCancelHandler { Darwin.close(descriptor) }
		source.resume()
		folder.source = source
		folder.descriptor = descriptor
		for name in folder.files.keys {
			note(state(of: name, in: folder), for: name, in: folder)
			watchFile(name, in: folder)
		}
	}

	private func folderChanged(_ folder: Folder, events: DispatchSource.FileSystemEvent) {
		if !events.isDisjoint(with: [.rename, .delete, .revoke]) {
			// The folder moved or went away; watch what's at its path instead. Folders
			// below the project folder were reached through it, so they're reopened too.
			if folder.components.isEmpty {
				for folder in folders { watch(folder) }
			} else {
				watch(folder)
			}
			return
		}
		for (name, file) in folder.files {
			let now = state(of: name, in: folder)
			guard now != file.seen else { continue }
			note(now, for: name, in: folder)
			watchFile(name, in: folder)
		}
	}

	/// Records what's at a file's path; anything other than what was seen
	/// before is a change.
	private func note(_ now: FileState, for name: String, in folder: Folder) {
		guard let file = folder.files[name] else { return }
		defer { file.seen = now }
		if let seen = file.seen, seen != now { changed() }
	}

	/// The entry at a file's path, without following a link.
	private func state(of name: String, in folder: Folder) -> FileState {
		var info = stat()
		guard folder.descriptor >= 0, fstatat(folder.descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { return .missing }
		guard info.st_mode & S_IFMT == S_IFREG else { return .other(device: info.st_dev, inode: info.st_ino, mode: info.st_mode) }
		return .file(device: info.st_dev, inode: info.st_ino, size: info.st_size, modified: info.st_mtimespec, changed: info.st_ctimespec)
	}

	/// Follows a file to the one now at its path, since a save that replaces
	/// it leaves the old descriptor on the old file.
	private func watchFile(_ name: String, in folder: Folder) {
		guard let file = folder.files[name] else { return }
		file.source?.cancel()
		file.source = nil
		guard case .file(_, let inode, _, _, _)? = file.seen, folder.descriptor >= 0 else { return }
		let descriptor = openat(folder.descriptor, name, O_EVTONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
		guard descriptor >= 0 else { return }
		var info = stat()
		guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_ino == inode else {
			Darwin.close(descriptor)
			return
		}
		let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .extend, .delete, .rename, .revoke], queue: queue)
		source.setEventHandler { [weak self, weak folder, weak file, weak source] in
			guard let self, let folder, let file, let source else { return }
			file.seen = state(of: name, in: folder)
			if !source.data.isDisjoint(with: [.delete, .rename, .revoke]) { watchFile(name, in: folder) }
			changed()
		}
		source.setCancelHandler { Darwin.close(descriptor) }
		source.resume()
		file.source = source
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
