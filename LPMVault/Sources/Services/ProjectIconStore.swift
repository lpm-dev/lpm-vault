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
	/// Files that couldn't be drawn as they were last seen, so they aren't tried again until they change.
	var undrawable: [String: ProjectIconFileSignature] = [:]
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
	/// How large a copied image is kept, enough for every size it's drawn at.
	nonisolated static let storedImagePixels = 128
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

	/// Each project's chosen icon; absent while it's automatic.
	private(set) var choices: [String: ProjectIconChoice] = [:]
	private(set) var resolutions: [String: ProjectIconResolution] = [:]
	/// Images chosen but not saved yet, by the choice that shows them.
	private(set) var previews: [ProjectIconChoice: ProjectIconImage] = [:]

	@ObservationIgnored private var targets: [String: Target] = [:]
	@ObservationIgnored private var loadedChoices: Set<String> = []
	@ObservationIgnored private var waiting: [String] = []
	@ObservationIgnored private var waitingIDs: Set<String> = []
	@ObservationIgnored private var running: Set<String> = []
	@ObservationIgnored private var rerun: Set<String> = []
	/// The project whose automatic icon is found even while another is chosen, as Project Settings shows it.
	@ObservationIgnored private var detailedProject: String?
	/// Copied images whose choice isn't saved yet.
	@ObservationIgnored private var staged: Set<String> = []
	@ObservationIgnored private var idleWaiters: [CheckedContinuation<Void, Never>] = []

	init(preferences: UserDefaults, imagesDirectory: URL = ProjectIconStore.defaultImagesDirectory) {
		self.preferences = preferences
		self.imagesDirectory = imagesDirectory
	}

	// MARK: - Appearance

	func appearance(for projectID: String) -> ProjectIconAppearance {
		appearance(of: choices[projectID] ?? .automatic, for: projectID)
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

	/// The image a chosen file shows, or nil when it isn't drawn yet or can't be.
	func chosenImage(_ choice: ProjectIconChoice, for projectID: String) -> ProjectIconImage? {
		if let preview = previews[choice] { return preview }
		guard let chosen = resolutions[projectID]?.chosen, chosen.choice == choice else { return nil }
		return chosen.image
	}

	/// Whether a chosen file was found missing or unreadable.
	func chosenFileFailed(_ choice: ProjectIconChoice, for projectID: String) -> Bool {
		guard previews[choice] == nil, let chosen = resolutions[projectID]?.chosen, chosen.choice == choice else { return false }
		return chosen.image == nil
	}

	func detection(for projectID: String) -> ProjectIconDetection {
		resolutions[projectID]?.detection ?? .searching
	}

	private func automaticAppearance(for projectID: String) -> ProjectIconAppearance {
		resolutions[projectID]?.automatic.map { .image($0.image) } ?? .folder
	}

	/// The paths in a project folder whose change can change its icon.
	func watchedPaths(for projectID: String) -> [String] {
		var paths = ProjectIconDiscovery.candidates + ProjectIconDiscovery.sourceFiles
		var seen = Set(paths)
		for source in ProjectIconDiscovery.sourceFiles {
			for path in resolutions[projectID]?.sources[source]?.paths ?? [] where seen.insert(path).inserted { paths.append(path) }
		}
		if case .projectFile(let path)? = choices[projectID], seen.insert(path).inserted { paths.append(path) }
		return paths
	}

	// MARK: - Resolving

	/// Follows the projects in `targets`: resolves those that are new or
	/// moved, and forgets the rest.
	func follow(_ targets: [Target]) {
		let current = Dictionary(targets.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
		for id in self.targets.keys where current[id] == nil {
			self.targets[id] = nil
			resolutions[id] = nil
			choices[id] = nil
			loadedChoices.remove(id)
			rerun.remove(id)
			if waitingIDs.remove(id) != nil { waiting.removeAll { $0 == id } }
		}
		for target in targets where self.targets[target.id] != target {
			if let previous = self.targets[target.id], previous.folder != target.folder { resolutions[target.id] = nil }
			self.targets[target.id] = target
			loadChoice(target.id)
			enqueue(target.id)
		}
	}

	/// Checks every project's icon files again, drawing only those that changed.
	func revalidate() {
		for id in targets.keys.sorted() { enqueue(id) }
	}

	func revalidate(_ projectID: String) {
		guard targets[projectID] != nil else { return }
		enqueue(projectID)
	}

	/// Finds the project's automatic icon even while another one is chosen,
	/// for Project Settings, which shows both; nil stops.
	func setDetailedProject(_ projectID: String?) {
		guard detailedProject != projectID else { return }
		detailedProject = projectID
		if let projectID { revalidate(projectID) }
	}

	/// Returns once nothing is being resolved.
	func waitUntilIdle() async {
		guard !running.isEmpty || !waiting.isEmpty else { return }
		await withCheckedContinuation { idleWaiters.append($0) }
	}

	private func enqueue(_ id: String) {
		if running.contains(id) {
			rerun.insert(id)
		} else if waitingIDs.insert(id).inserted {
			waiting.append(id)
		}
		startWaiting()
	}

	private func startWaiting() {
		while running.count < Self.maximumConcurrentResolutions, !waiting.isEmpty {
			let id = waiting.removeFirst()
			waitingIDs.remove(id)
			start(id)
		}
	}

	private func start(_ id: String) {
		guard let target = targets[id] else { return }
		running.insert(id)
		let choice = choices[id] ?? .automatic
		let previous = resolutions[id]
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
		if targets[id] == target, (choices[id] ?? .automatic) == choice {
			if resolutions[id] != resolution { resolutions[id] = resolution }
			// A saved choice shows what its file resolves to from now on, even when that can't be drawn.
			if let chosen = resolution.chosen, previews[chosen.choice] != nil { previews[chosen.choice] = nil }
		} else if targets[id] != nil {
			rerun.insert(id)
		}
		if rerun.remove(id) != nil { enqueue(id) }
		startWaiting()
		if running.isEmpty, waiting.isEmpty {
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
				read: { () throws(ProjectIconFile.Failure) in try ProjectIconFile.read(path, in: folder, maximumBytes: ProjectIconFile.maximumImageBytes) }, path: path)
		case .storedImage(let file, _):
			let url = imagesDirectory.appending(path: file, directoryHint: .notDirectory)
			result.chosen = resolveChosen(choice, previous: previous?.chosen,
				signature: { ProjectIconFile.signature(of: url) },
				read: { () throws(ProjectIconFile.Failure) in try ProjectIconFile.read(url, maximumBytes: ProjectIconFile.maximumImageBytes) }, path: file)
		case .automatic, .symbol, .emoji, .monogram:
			result.chosen = nil
		}
		let showsAutomatic = choice.isAutomatic || (result.chosen != nil && result.chosen?.image == nil)
		if showsAutomatic || findsAutomatic { resolveAutomatic(in: folder, into: &result) }
		return result
	}

	nonisolated private static func resolveChosen(
		_ choice: ProjectIconChoice, previous: ProjectIconResolution.Chosen?,
		signature: () -> ProjectIconFileSignature?,
		read: () throws(ProjectIconFile.Failure) -> (data: Data, signature: ProjectIconFileSignature), path: String
	) -> ProjectIconResolution.Chosen {
		let current = signature()
		if let previous, previous.choice == choice, let current, previous.signature == current { return previous }
		guard current != nil, let file = try? read() else { return .init(choice: choice, signature: current, image: nil) }
		return .init(choice: choice, signature: file.signature, image: ProjectIconRenderer.image(from: file.data, path: path))
	}

	/// The first icon file that can be drawn: a well-known one, then one a
	/// source file links to.
	nonisolated private static func resolveAutomatic(in folder: String, into result: inout ProjectIconResolution) {
		guard ProjectIconFile.folderExists(folder) else {
			result = ProjectIconResolution(detection: .folderMissing, chosen: result.chosen)
			return
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
			let image = ProjectIconRenderer.image(from: file.data, path: path)
		else {
			result.undrawable[path] = signature
			return nil
		}
		result.undrawable[path] = nil
		return .init(path: path, signature: file.signature, image: image)
	}

	// MARK: - Choices

	/// Saves a project's icon choice; `.automatic` removes the one chosen.
	func save(_ choice: ProjectIconChoice, for projectID: String) {
		let previous = choices[projectID]
		let key = Self.preferencePrefix + projectID
		if choice.isAutomatic {
			preferences.removeObject(forKey: key)
			choices[projectID] = nil
		} else {
			guard choice.isValid, let data = try? JSONEncoder().encode(choice) else { return }
			preferences.set(data, forKey: key)
			choices[projectID] = choice
		}
		loadedChoices.insert(projectID)
		if case .storedImage(let file, _) = choice { staged.remove(file) }
		if case .storedImage(let file, _)? = previous, previous != choice { deleteStoredImage(file) }
		if targets[projectID] != nil { enqueue(projectID) }
	}

	/// Prepares a chosen image: one in the project folder is followed there;
	/// any other is copied into LPM Vault's folder. The choice isn't saved
	/// until `save(_:for:)`; `discardPreview(of:)` drops it.
	func importImage(at url: URL, projectFolder: String) async -> Result<ProjectIconChoice, ImportFailure> {
		let directory = imagesDirectory
		let result = await BlockingWork.run { Self.prepareImport(url, projectFolder: projectFolder, directory: directory) }
		guard case .success(let prepared) = result else {
			if case .failure(let failure) = result { return .failure(failure) }
			return .failure(.unreadable)
		}
		if case .storedImage(let file, _) = prepared.choice { staged.insert(file) }
		previews[prepared.choice] = prepared.image
		return .success(prepared.choice)
	}

	/// Drops an unsaved choice's image, and its copy when it was copied.
	func discardPreview(of choice: ProjectIconChoice) {
		previews[choice] = nil
		if case .storedImage(let file, _) = choice, staged.remove(file) != nil { deleteStoredImage(file) }
	}

	/// Forgets a project's chosen icon and its copied image, as when it's deleted.
	func forget(_ projectID: String) {
		let key = Self.preferencePrefix + projectID
		if let file = storedImageFile(forKey: key) { deleteStoredImage(file) }
		preferences.removeObject(forKey: key)
		choices[projectID] = nil
		loadedChoices.remove(projectID)
	}

	/// Forgets the chosen icons of projects no longer on this Mac.
	func forget(keeping projectIDs: Set<String>) {
		for key in preferences.dictionaryRepresentation().keys where key.hasPrefix(Self.preferencePrefix) {
			let id = String(key.dropFirst(Self.preferencePrefix.count))
			if !projectIDs.contains(id) { forget(id) }
		}
	}

	/// Deletes copied images no saved choice uses, such as one left by a quit
	/// before its choice was saved.
	func collectUnusedImages() async {
		var used = staged
		for key in preferences.dictionaryRepresentation().keys where key.hasPrefix(Self.preferencePrefix) {
			if let file = storedImageFile(forKey: key) { used.insert(file) }
		}
		let directory = imagesDirectory
		let kept = used
		await BlockingWork.run {
			let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
			for name in names where Self.isStoredImageName(name) && !kept.contains(name) {
				try? FileManager.default.removeItem(at: directory.appending(path: name, directoryHint: .notDirectory))
			}
		}
	}

	private func loadChoice(_ projectID: String) {
		guard loadedChoices.insert(projectID).inserted else { return }
		let key = Self.preferencePrefix + projectID
		guard let data = preferences.data(forKey: key) else {
			choices[projectID] = nil
			return
		}
		if let choice = try? JSONDecoder().decode(ProjectIconChoice.self, from: data), choice.isValid, !choice.isAutomatic {
			choices[projectID] = choice
		} else {
			preferences.removeObject(forKey: key)
			choices[projectID] = nil
		}
	}

	private func storedImageFile(forKey key: String) -> String? {
		guard let data = preferences.data(forKey: key),
			case .storedImage(let file, _)? = try? JSONDecoder().decode(ProjectIconChoice.self, from: data),
			Self.isStoredImageName(file)
		else { return nil }
		return file
	}

	private func deleteStoredImage(_ file: String) {
		guard Self.isStoredImageName(file) else { return }
		let url = imagesDirectory.appending(path: file, directoryHint: .notDirectory)
		Task { await BlockingWork.run { try? FileManager.default.removeItem(at: url) } }
	}

	nonisolated private static func prepareImport(
		_ url: URL, projectFolder: String, directory: URL
	) -> Result<(choice: ProjectIconChoice, image: ProjectIconImage), ImportFailure> {
		if let path = ProjectIconPath.relativePath(of: url, in: projectFolder), ProjectIconPath.isImage(path),
			let file = try? ProjectIconFile.read(path, in: projectFolder, maximumBytes: ProjectIconFile.maximumImageBytes)
		{
			guard let image = ProjectIconRenderer.image(from: file.data, path: path) else { return .failure(.notAnImage) }
			return .success((.projectFile(path), image))
		}
		guard let file = try? ProjectIconFile.read(url, maximumBytes: ProjectIconFile.maximumImageBytes) else { return .failure(.unreadable) }
		guard let image = ProjectIconRenderer.image(from: file.data, path: url.path),
			let png = ProjectIconRenderer.png(from: file.data, path: url.path, pixels: storedImagePixels)
		else { return .failure(.notAnImage) }
		let name = UUID().uuidString + ".png"
		do {
			try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
			try png.write(to: directory.appending(path: name, directoryHint: .notDirectory), options: [.atomic])
		} catch {
			return .failure(.couldNotSave)
		}
		let displayName = String(url.lastPathComponent.prefix(255))
		return .success((.storedImage(file: name, name: displayName.isEmpty ? "Image" : displayName), image))
	}
}
