import Foundation
import Observation

/// What a project's icon files resolved to when last checked.
struct ProjectIconResolution: Equatable, Sendable {
	struct Loaded: Equatable, Sendable {
		let path: String
		let signature: ProjectIconFileSignature
		let image: ProjectIconImage
	}

	/// A chosen image file; its image is nil when it's missing or can't be drawn.
	struct Chosen: Equatable, Sendable {
		let choice: ProjectIconChoice
		let signature: ProjectIconFileSignature?
		let image: ProjectIconImage?
	}

	var detection: ProjectIconDetection = .searching
	var automatic: Loaded?
	var chosen: Chosen?
	/// Each source file's icon link as last read, so an unchanged source isn't read again.
	var sources: [String: ProjectIconDiscovery.SourceLinks] = [:]
	/// Files that couldn't be drawn as they were last seen, so they aren't tried
	/// again until they change; only files the project can still name are kept.
	var undrawable: [String: ProjectIconFileSignature] = [:]
}

/// One project's icon state. Each project has its own, so a change to one
/// project's icon updates only what shows that project.
@Observable
@MainActor
final class ProjectIconEntry {
	fileprivate(set) var choice: ProjectIconChoice?
	fileprivate(set) var resolution: ProjectIconResolution?
	/// Images chosen but not saved yet, by the choice that shows them.
	fileprivate(set) var previews: [ProjectIconChoice: ProjectIconImage] = [:]
	fileprivate(set) var isImporting = false
	fileprivate(set) var importFailure: ProjectIconStore.ImportFailure?
	@ObservationIgnored fileprivate var target: ProjectIconStore.Target?
	@ObservationIgnored fileprivate var choiceLoaded = false
}

/// Each project's icon: the one chosen in Project Settings, kept in the
/// app's preferences, or else the one found in its folder. Files are read
/// and drawn off the main thread, a few projects at a time, and drawn again
/// only when they change.
@Observable
@MainActor
final class ProjectIconStore {
	struct Target: Hashable, Sendable {
		let id: String
		let folder: String
	}

	enum ImportFailure: Error, Equatable {
		case unreadable
		case notAnImage
		case couldNotSave
	}

	static let preferencePrefix = "lpm-vault-project-icon."
	/// The longest name kept for a copied image, in bytes, as choices allow.
	nonisolated static let maximumImageNameBytes = 255
	private static let maximumConcurrentResolutions = 4

	static var defaultImagesDirectory: URL {
		let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
		return base.appending(path: "dev.lpm.vault", directoryHint: .isDirectory).appending(path: "ProjectIcons", directoryHint: .isDirectory)
	}

	/// A copied image's file name: a UUID, as LPM Vault names them.
	nonisolated static func isStoredImageName(_ name: String) -> Bool {
		name.hasSuffix(".png") && UUID(uuidString: String(name.dropLast(4))) != nil && !name.contains("/")
	}

	@ObservationIgnored private let preferences: UserDefaults
	@ObservationIgnored let imagesDirectory: URL

	/// Each project's entry. The dictionary changes only as projects come and
	/// go; what changes for one project changes in its entry.
	private var entries: [String: ProjectIconEntry] = [:]

	@ObservationIgnored private var queue: [String] = []
	@ObservationIgnored private var queueHead = 0
	@ObservationIgnored private var queued: Set<String> = []
	@ObservationIgnored private var running: Set<String> = []
	@ObservationIgnored private var rerun: Set<String> = []
	/// The project whose automatic icon is found even while another is chosen, as Project Settings shows it.
	@ObservationIgnored private var detailedProject: String?
	/// Copied images whose choice isn't saved yet.
	@ObservationIgnored private var staged: Set<String> = []
	@ObservationIgnored private var idleWaiters: [CheckedContinuation<Void, Never>] = []
	@ObservationIgnored private var fileWork: Task<Void, Never>?

	init(preferences: UserDefaults, imagesDirectory: URL = ProjectIconStore.defaultImagesDirectory) {
		self.preferences = preferences
		self.imagesDirectory = imagesDirectory
	}

	// MARK: - Appearance

	func appearance(for projectID: String) -> ProjectIconAppearance {
		appearance(of: choice(for: projectID) ?? .automatic, for: projectID)
	}

	/// How `choice` looks for the project, such as an unsaved one in Project Settings.
	func appearance(of choice: ProjectIconChoice, for projectID: String) -> ProjectIconAppearance {
		switch choice {
		case .symbol(let name, let color): return .symbol(name, color)
		case .emoji(let emoji): return .emoji(emoji)
		case .monogram(let letters, let color): return .monogram(letters, color)
		case .projectFile, .storedImage:
			if let image = chosenImage(choice, for: projectID) { return .image(image) }
			return automaticAppearance(for: projectID)
		case .automatic:
			return automaticAppearance(for: projectID)
		}
	}

	/// The project's chosen icon; nil while it's automatic.
	func choice(for projectID: String) -> ProjectIconChoice? {
		entries[projectID]?.choice
	}

	func resolution(for projectID: String) -> ProjectIconResolution? {
		entries[projectID]?.resolution
	}

	/// The image a chosen file shows, or nil when it isn't drawn yet or can't be.
	func chosenImage(_ choice: ProjectIconChoice, for projectID: String) -> ProjectIconImage? {
		guard let entry = entries[projectID] else { return nil }
		if let preview = entry.previews[choice] { return preview }
		guard let chosen = entry.resolution?.chosen, chosen.choice == choice else { return nil }
		return chosen.image
	}

	/// Whether a chosen file was found missing or unreadable.
	func chosenFileFailed(_ choice: ProjectIconChoice, for projectID: String) -> Bool {
		guard let entry = entries[projectID], entry.previews[choice] == nil,
			let chosen = entry.resolution?.chosen, chosen.choice == choice
		else { return false }
		return chosen.image == nil
	}

	func detection(for projectID: String) -> ProjectIconDetection {
		entries[projectID]?.resolution?.detection ?? .searching
	}

	func isImporting(_ projectID: String) -> Bool {
		entries[projectID]?.isImporting ?? false
	}

	func importFailure(for projectID: String) -> ImportFailure? {
		entries[projectID]?.importFailure
	}

	/// Each project's last import failure, by project ID.
	var importFailures: [String: ImportFailure] {
		entries.compactMapValues(\.importFailure)
	}

	private func automaticAppearance(for projectID: String) -> ProjectIconAppearance {
		entries[projectID]?.resolution?.automatic.map { .image($0.image) } ?? .folder
	}

	/// The paths in a project folder whose change can change its icon.
	func watchedPaths(for projectID: String) -> [String] {
		var paths = ProjectIconDiscovery.candidates + ProjectIconDiscovery.sourceFiles
		var seen = Set(paths)
		let entry = entries[projectID]
		for source in ProjectIconDiscovery.sourceFiles {
			for path in entry?.resolution?.sources[source]?.paths ?? [] where seen.insert(path).inserted { paths.append(path) }
		}
		if case .projectFile(let path)? = entry?.choice, seen.insert(path).inserted { paths.append(path) }
		return paths
	}

	private func entry(_ projectID: String) -> ProjectIconEntry {
		if let entry = entries[projectID] { return entry }
		let entry = ProjectIconEntry()
		entries[projectID] = entry
		return entry
	}

	// MARK: - Resolving

	/// Follows the projects in `targets`: resolves those that are new or
	/// moved, and forgets the rest.
	func follow(_ targets: [Target]) {
		let current = Dictionary(targets.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
		let removed = Set(entries.compactMap { id, entry in entry.target != nil && current[id] == nil ? id : nil })
		if !removed.isEmpty {
			for id in removed { entries[id] = nil }
			rerun.subtract(removed)
			queued.subtract(removed)
			queue = queue[queueHead...].filter { !removed.contains($0) }
			queueHead = 0
		}
		for target in targets {
			let entry = entry(target.id)
			guard entry.target != target else { continue }
			if let previous = entry.target, previous.folder != target.folder { entry.resolution = nil }
			entry.target = target
			loadChoice(into: entry, for: target.id)
			enqueue(target.id)
		}
	}

	/// Checks every project's icon files again, drawing only those that changed.
	func revalidate() {
		for (id, entry) in entries.sorted(by: { $0.key < $1.key }) where entry.target != nil { enqueue(id) }
	}

	func revalidate(_ projectID: String) {
		guard entries[projectID]?.target != nil else { return }
		enqueue(projectID)
	}

	/// Checks the project's icon files once watching has begun, which catches
	/// a change made before, then again whenever one changes.
	func watch(_ projectID: String) async {
		guard let target = entries[projectID]?.target else { return }
		for await _ in ProjectConfigWatcher.changes(inFolder: target.folder, watching: watchedPaths(for: projectID)) {
			guard !Task.isCancelled else { return }
			revalidate(projectID)
		}
	}

	/// Finds the project's automatic icon even while another one is chosen,
	/// for Project Settings, which shows both.
	func beginDetailing(_ projectID: String) {
		guard detailedProject != projectID else { return }
		detailedProject = projectID
		revalidate(projectID)
	}

	/// Stops finding the project's automatic icon for Project Settings, unless
	/// another project's page has begun meanwhile.
	func endDetailing(_ projectID: String) {
		if detailedProject == projectID { detailedProject = nil }
	}

	/// Returns once nothing is being resolved.
	func waitUntilIdle() async {
		guard !running.isEmpty || !queued.isEmpty else { return }
		await withCheckedContinuation { idleWaiters.append($0) }
	}

	private func enqueue(_ id: String) {
		if running.contains(id) {
			rerun.insert(id)
		} else if queued.insert(id).inserted {
			queue.append(id)
		}
		startWaiting()
	}

	private func startWaiting() {
		while running.count < Self.maximumConcurrentResolutions, queueHead < queue.count {
			let id = queue[queueHead]
			queueHead += 1
			queued.remove(id)
			start(id)
		}
		if queueHead == queue.count {
			queue.removeAll(keepingCapacity: true)
			queueHead = 0
		}
	}

	private func start(_ id: String) {
		guard let entry = entries[id], let target = entry.target else { return }
		running.insert(id)
		let choice = entry.choice ?? .automatic
		let previous = entry.resolution
		let detailed = detailedProject == id
		let directory = imagesDirectory
		Task { [weak self] in
			let resolution = await BlockingWork.run {
				Self.resolve(folder: target.folder, choice: choice, findsAutomatic: detailed, previous: previous, imagesDirectory: directory)
			}
			self?.finish(id, target: target, choice: choice, resolution: resolution)
		}
	}

	private func finish(_ id: String, target: Target, choice: ProjectIconChoice, resolution: ProjectIconResolution) {
		running.remove(id)
		if let entry = entries[id], entry.target == target, (entry.choice ?? .automatic) == choice {
			if entry.resolution != resolution { entry.resolution = resolution }
			// A saved choice shows what its file resolves to from now on, even when that can't be drawn.
			if let chosen = resolution.chosen, entry.previews[chosen.choice] != nil { entry.previews[chosen.choice] = nil }
		} else if entries[id]?.target != nil {
			rerun.insert(id)
		}
		if rerun.remove(id) != nil { enqueue(id) }
		startWaiting()
		if running.isEmpty, queued.isEmpty {
			let waiters = idleWaiters
			idleWaiters.removeAll()
			for waiter in waiters { waiter.resume() }
		}
	}

	/// Resolves a project's icon files, reusing what `previous` drew from
	/// files that haven't changed. Blocks on the file system.
	nonisolated static func resolve(
		folder: String, choice: ProjectIconChoice, findsAutomatic: Bool, previous: ProjectIconResolution?, imagesDirectory: URL
	) -> ProjectIconResolution {
		var result = previous ?? ProjectIconResolution()
		switch choice {
		case .projectFile(let path):
			result.chosen = resolveChosen(choice, previous: previous?.chosen,
				signature: { ProjectIconFile.signatures(of: [path], in: folder)[path] },
				read: { () throws(ProjectIconFile.Failure) in try ProjectIconFile.read(path, in: folder, maximumBytes: ProjectIconFile.maximumImageBytes) })
		case .storedImage(let file, _):
			result.chosen = resolveChosen(choice, previous: previous?.chosen,
				signature: { ProjectIconImageFolder.signature(of: file, in: imagesDirectory) },
				read: { () throws(ProjectIconFile.Failure) in
					try ProjectIconImageFolder.read(file, in: imagesDirectory, maximumBytes: ProjectIconFile.maximumImageBytes)
				})
		case .automatic, .symbol, .emoji, .monogram:
			result.chosen = nil
		}
		let showsAutomatic = choice.isAutomatic || (result.chosen != nil && result.chosen?.image == nil)
		if showsAutomatic || findsAutomatic {
			resolveAutomatic(in: folder, into: &result)
		} else if !ProjectIconFile.folderExists(folder) {
			// Menus read whether the folder is there from here, not from the disk.
			result = ProjectIconResolution(detection: .folderMissing, chosen: result.chosen)
		} else if result.detection == .folderMissing {
			result.detection = .searching
		}
		return result
	}

	nonisolated private static func resolveChosen(
		_ choice: ProjectIconChoice, previous: ProjectIconResolution.Chosen?,
		signature: () -> ProjectIconFileSignature?,
		read: () throws(ProjectIconFile.Failure) -> (data: Data, signature: ProjectIconFileSignature)
	) -> ProjectIconResolution.Chosen {
		let current = signature()
		if let previous, previous.choice == choice, let current, previous.signature == current { return previous }
		guard current != nil, let file = try? read() else { return .init(choice: choice, signature: current, image: nil) }
		return .init(choice: choice, signature: file.signature, image: ProjectIconRenderer.image(from: file.data, allowingSVG: true))
	}

	/// The first icon file that can be drawn: a well-known one, then one a
	/// source file links to.
	nonisolated private static func resolveAutomatic(in folder: String, into result: inout ProjectIconResolution) {
		guard ProjectIconFile.folderExists(folder) else {
			result = ProjectIconResolution(detection: .folderMissing, chosen: result.chosen)
			return
		}
		defer {
			let named = Set(ProjectIconDiscovery.candidates).union(result.sources.values.flatMap(\.paths))
			result.undrawable = result.undrawable.filter { named.contains($0.key) }
		}
		let candidates = ProjectIconDiscovery.candidates
		let signatures = ProjectIconFile.signatures(of: candidates, in: folder)
		for path in candidates {
			if let signature = signatures[path], let loaded = load(path, signature: signature, in: folder, result: &result) {
				result.automatic = loaded
				result.detection = .found(path)
				return
			}
		}
		let sourceSignatures = ProjectIconFile.signatures(of: ProjectIconDiscovery.sourceFiles, in: folder)
		var sources: [String: ProjectIconDiscovery.SourceLinks] = [:]
		var linked: [String] = []
		for source in ProjectIconDiscovery.sourceFiles {
			guard let signature = sourceSignatures[source] else { continue }
			let links: ProjectIconDiscovery.SourceLinks
			if let cached = result.sources[source], cached.signature == signature {
				links = cached
			} else if let file = try? ProjectIconFile.read(source, in: folder, maximumBytes: ProjectIconFile.maximumSourceBytes) {
				links = .init(signature: file.signature, paths: ProjectIconDiscovery.linkedPaths(in: String(decoding: file.data, as: UTF8.self)))
			} else {
				links = .init(signature: signature, paths: [])
			}
			sources[source] = links
			for path in links.paths where !linked.contains(path) { linked.append(path) }
		}
		result.sources = sources
		let linkedSignatures = ProjectIconFile.signatures(of: linked, in: folder)
		for path in linked {
			if let signature = linkedSignatures[path], let loaded = load(path, signature: signature, in: folder, result: &result) {
				result.automatic = loaded
				result.detection = .found(path)
				return
			}
		}
		result.automatic = nil
		result.detection = .notFound
	}

	nonisolated private static func load(
		_ path: String, signature: ProjectIconFileSignature, in folder: String, result: inout ProjectIconResolution
	) -> ProjectIconResolution.Loaded? {
		if let current = result.automatic, current.path == path, current.signature == signature { return current }
		if result.undrawable[path] == signature { return nil }
		guard let file = try? ProjectIconFile.read(path, in: folder, maximumBytes: ProjectIconFile.maximumImageBytes),
			let image = ProjectIconRenderer.image(from: file.data, allowingSVG: false)
		else {
			result.undrawable[path] = signature
			return nil
		}
		result.undrawable[path] = nil
		return .init(path: path, signature: file.signature, image: image)
	}

	// MARK: - Choices

	/// Saves a project's icon choice; `.automatic` removes the one chosen.
	/// False when the choice isn't one LPM Vault can keep.
	@discardableResult
	func save(_ choice: ProjectIconChoice, for projectID: String) -> Bool {
		let entry = entry(projectID)
		let previous = entry.choice
		let key = Self.preferencePrefix + projectID
		if choice.isAutomatic {
			preferences.removeObject(forKey: key)
			entry.choice = nil
		} else {
			guard choice.isValid, let data = try? JSONEncoder().encode(choice) else { return false }
			preferences.set(data, forKey: key)
			entry.choice = choice
		}
		entry.choiceLoaded = true
		if case .storedImage(let file, _) = choice { staged.remove(file) }
		if case .storedImage(let file, _)? = previous, previous != choice { deleteStoredImages([file]) }
		if entry.target != nil { enqueue(projectID) }
		return true
	}

	/// Prepares a chosen image for a project: one in its folder is followed
	/// there; any other is copied into LPM Vault's folder. The choice isn't
	/// saved until `save(_:for:)`; `discardPreview(of:for:)` drops it.
	func importImage(at url: URL, projectFolder: String, for projectID: String) async -> Result<ProjectIconChoice, ImportFailure> {
		let entry = entry(projectID)
		entry.isImporting = true
		entry.importFailure = nil
		let directory = imagesDirectory
		let result = await BlockingWork.run { Self.prepareImport(url, projectFolder: projectFolder, directory: directory) }
		entry.isImporting = false
		switch result {
		case .success(let prepared):
			if case .storedImage(let file, _) = prepared.choice { staged.insert(file) }
			entry.previews[prepared.choice] = prepared.image
			return .success(prepared.choice)
		case .failure(let failure):
			entry.importFailure = failure
			return .failure(failure)
		}
	}

	/// Drops a project's unsaved choice's image, and its copy when it was copied.
	func discardPreview(of choice: ProjectIconChoice, for projectID: String) {
		entries[projectID]?.previews[choice] = nil
		if case .storedImage(let file, _) = choice, staged.remove(file) != nil { deleteStoredImages([file]) }
	}

	/// Clears the reason a project's last import failed.
	func clearImportFailure(for projectID: String) {
		entries[projectID]?.importFailure = nil
	}

	/// Forgets a project's chosen icon and its copied image, as when it's deleted.
	func forget(_ projectID: String) {
		forget([projectID])
	}

	/// Forgets the chosen icons of projects no longer on this Mac.
	func forget(keeping projectIDs: Set<String>) {
		forget(preferences.dictionaryRepresentation().keys.compactMap { key in
			guard key.hasPrefix(Self.preferencePrefix) else { return nil }
			let id = String(key.dropFirst(Self.preferencePrefix.count))
			return projectIDs.contains(id) ? nil : id
		})
	}

	private func forget(_ projectIDs: [String]) {
		var files: [String] = []
		for projectID in projectIDs {
			let key = Self.preferencePrefix + projectID
			if let file = storedImageFile(forKey: key) { files.append(file) }
			preferences.removeObject(forKey: key)
			if let entry = entries[projectID] {
				entry.choice = nil
				entry.choiceLoaded = false
			}
		}
		deleteStoredImages(files)
	}

	/// Deletes copied images no saved choice uses, such as one left by a quit
	/// before its choice was saved. A copy written since `olderThan` stays: its
	/// import may still be about to stage it.
	func collectUnusedImages(olderThan cutoff: Date = Date()) async {
		let kept = storedImagesInUse()
		let directory = imagesDirectory
		await BlockingWork.run { ProjectIconImageFolder.deleteImages(except: kept, changedBefore: cutoff, in: directory) }
	}

	private func loadChoice(into entry: ProjectIconEntry, for projectID: String) {
		guard !entry.choiceLoaded else { return }
		entry.choiceLoaded = true
		let key = Self.preferencePrefix + projectID
		guard let data = preferences.data(forKey: key) else {
			entry.choice = nil
			return
		}
		if let choice = try? JSONDecoder().decode(ProjectIconChoice.self, from: data), choice.isValid, !choice.isAutomatic {
			entry.choice = choice
		} else {
			preferences.removeObject(forKey: key)
			entry.choice = nil
		}
	}

	private func storedImageFile(forKey key: String) -> String? {
		guard let data = preferences.data(forKey: key),
			case .storedImage(let file, _)? = try? JSONDecoder().decode(ProjectIconChoice.self, from: data),
			Self.isStoredImageName(file)
		else { return nil }
		return file
	}

	/// The copied images a saved choice or an unsaved one shows.
	private func storedImagesInUse() -> Set<String> {
		var used = staged
		for key in preferences.dictionaryRepresentation().keys where key.hasPrefix(Self.preferencePrefix) {
			if let file = storedImageFile(forKey: key) { used.insert(file) }
		}
		return used
	}

	/// Deletes those of `files` that nothing shows any more. A damaged
	/// preference can name another project's copy, which then stays.
	private func deleteStoredImages(_ files: [String]) {
		guard !files.isEmpty else { return }
		let used = storedImagesInUse()
		let unused = Set(files.filter { Self.isStoredImageName($0) && !used.contains($0) })
		guard !unused.isEmpty else { return }
		let directory = imagesDirectory
		let previous = fileWork
		fileWork = Task {
			await previous?.value
			await BlockingWork.run { ProjectIconImageFolder.delete(unused, in: directory) }
		}
	}

	/// Returns once the copied images queued to be deleted are.
	func waitForFileWork() async {
		while let work = fileWork {
			await work.value
			if fileWork == work { return }
		}
	}

	/// `name` cut to whole characters that fit in `maximumImageNameBytes` bytes.
	nonisolated static func storedImageDisplayName(_ name: String) -> String {
		var trimmed = Substring(name)
		while trimmed.utf8.count > maximumImageNameBytes { trimmed = trimmed.dropLast() }
		return trimmed.isEmpty ? "Image" : String(trimmed)
	}

	nonisolated private static func prepareImport(
		_ url: URL, projectFolder: String, directory: URL
	) -> Result<(choice: ProjectIconChoice, image: ProjectIconImage), ImportFailure> {
		if let path = ProjectIconPath.relativePath(of: url, in: projectFolder), ProjectIconPath.isImage(path),
			let file = try? ProjectIconFile.read(path, in: projectFolder, maximumBytes: ProjectIconFile.maximumImageBytes)
		{
			guard let image = ProjectIconRenderer.image(from: file.data, allowingSVG: true) else { return .failure(.notAnImage) }
			return .success((.projectFile(path), image))
		}
		guard let file = try? ProjectIconFile.read(url, maximumBytes: ProjectIconFile.maximumImageBytes) else { return .failure(.unreadable) }
		guard let copy = ProjectIconRenderer.copy(from: file.data) else { return .failure(.notAnImage) }
		let name = UUID().uuidString + ".png"
		guard ProjectIconImageFolder.write(copy.png, named: name, in: directory) else { return .failure(.couldNotSave) }
		return .success((.storedImage(file: name, name: storedImageDisplayName(url.lastPathComponent)), copy.image))
	}
}
