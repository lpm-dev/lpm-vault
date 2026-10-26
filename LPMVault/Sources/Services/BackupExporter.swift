import Foundation
import SystemConfiguration

/// Makes a backup of every env project: reads them, with what LPM Vault
/// keeps beside them, writes the payload, and seals it off the main actor.
/// It doesn't save the file: the store does that once it knows the session
/// that asked is still the one unlocked.
struct BackupExporter: Sendable {
	/// What a backup carries beyond the projects, which it always carries.
	struct Contents: Equatable, Sendable {
		var destinations = true
		var settingsAndIcons = true
		/// The keys lpm.dev sync encrypts with, so another Mac keeps syncing.
		var syncKeys = true
	}

	/// What a backup holds, counted as the person sees it.
	struct Summary: Equatable, Sendable {
		var projects = 0
		/// Projects removed from the sidebar, whose values the Keychain keeps.
		var removedProjects = 0
		var keys = 0
		var destinations = 0
		/// lpm.dev sync keys, a sharing key's live and pending halves apart.
		var syncKeys = 0
		var settings = false
		/// Keychain items whose names LPM Vault can't use as vault IDs, left out.
		var unusableItems = 0
		/// Projects left out because of their newer data, with why.
		var leftOut: [LeftOut] = []
		/// Names of projects backed up without their newer data, which backups don't carry yet.
		var withNewerData: [String] = []
	}

	/// A project a backup left out.
	struct LeftOut: Equatable, Sendable {
		let name: String
		let reason: String
	}

	/// What a backup will do with projects' newer data, said before it runs.
	struct CompanionPreview: Equatable, Sendable {
		var leftOut: [LeftOut] = []
		/// Names of projects that will be backed up without their newer data.
		var withNewerData: [String] = []
	}

	/// LPM Vault's settings and each project's chosen icon, as the store holds
	/// them on the main actor.
	struct AppState: Sendable {
		let settings: BackupAppSection.Settings
		let iconChoices: [String: ProjectIconChoice]
	}

	enum Failure: Error, Equatable, Sendable {
		case unreadableProjects
		case unreadableDestinations(project: String)
		case newerDestinations(project: String)
		/// The LPM CLI couldn't store the project as it is, for the engine's `reason`.
		case invalidProject(name: String, reason: String)
		case keys(BackupKeyStore.Failure)
		case engine(BackupEngine.Failure)

		var message: String {
			switch self {
			case .unreadableProjects:
				"Your env projects couldn’t be read, so nothing was exported. Try again."
			case .unreadableDestinations(let project):
				"The publish destinations of \(project.escapingDirectionControls) couldn’t be read. Try again, or export without publish destinations."
			case .newerDestinations(let project):
				"A newer LPM Vault saved the publish destinations of \(project.escapingDirectionControls). Update LPM Vault, or export without publish destinations."
			case .invalidProject(let name, let reason):
				reason == "project_too_large"
					? "\(name.escapingDirectionControls) is larger than the LPM CLI can store, so it can’t be backed up. Remove values it doesn’t need, then export again."
					: "\(name.escapingDirectionControls) holds a name the LPM CLI doesn’t accept, so it can’t be backed up."
			case .keys(let failure):
				failure.message
			case .engine(let failure):
				failure.message
			}
		}
	}

	let persistence: VaultPersistenceCoordinator
	let publishing: PublishingStore
	let imagesDirectory: URL
	let keyStore: BackupKeyStore

	/// The sealed file and what it holds.
	func seal(
		_ contents: Contents,
		appState: AppState,
		producerVersion: String,
		deviceName: String?,
		passphrase: String,
		now: Date
	) async throws(Failure) -> (file: Data, summary: Summary) {
		let snapshot: VaultBackupSnapshot
		switch await persistence.backupSnapshot() {
		case .success(let value): snapshot = value
		case .failure: throw .unreadableProjects
		}
		let inventory = snapshot.inventory.projects
		let names = Dictionary(uniqueKeysWithValues: inventory.map { ($0.vaultId, $0.listing?.name ?? $0.vaultId) })

		var destinations: [String: [PublishDestination]] = [:]
		if contents.destinations {
			for project in inventory {
				switch await publishing.destinations(of: project.vaultId) {
				case .success(let list):
					if !list.isEmpty { destinations[project.vaultId] = list }
				case .failure(.newerVersion):
					throw .newerDestinations(project: names[project.vaultId] ?? project.vaultId)
				case .failure:
					throw .unreadableDestinations(project: names[project.vaultId] ?? project.vaultId)
				}
			}
		}

		var app: BackupAppSection?
		if contents.settingsAndIcons {
			let vaultIds = Set(names.keys)
			let choices = appState.iconChoices.filter { vaultIds.contains($0.key) }
			let icons = await BlockingWork.run { [imagesDirectory] in Self.icons(choices, imagesDirectory: imagesDirectory) }
			app = BackupAppSection(settings: Self.settings(appState.settings, keeping: vaultIds), icons: icons, destinations: destinations)
		} else if !destinations.isEmpty {
			app = BackupAppSection(settings: nil, destinations: destinations)
		}

		let projects = inventory.map { project in
			BackupPayload.Project(
				vaultId: project.vaultId,
				name: project.listing?.name ?? project.vaultId,
				folder: project.listing.flatMap { $0.folder.isEmpty ? nil : $0.folder },
				hidden: project.listing == nil,
				cliAccess: project.cliAccess,
				environments: project.environments,
				sync: Self.sync(snapshot.syncMetadata[project.vaultId], orgSlug: snapshot.orgAssociations[project.vaultId]))
		}
		var keys: BackupKeys?
		if contents.syncKeys {
			let read = await BlockingWork.run { [keyStore] in Result { () throws(BackupKeyStore.Failure) in try keyStore.read() } }
			switch read {
			case .success(let value): keys = value
			case .failure(let failure): throw .keys(failure)
			}
		}

		let payload = BackupPayload(
			createdAt: now,
			producerVersion: BackupPayload.isLabel(producerVersion, maximumBytes: BackupPayload.maximumLabelBytes) ? producerVersion : "unknown",
			deviceName: deviceName.flatMap { BackupPayload.isLabel($0, maximumBytes: BackupPayload.maximumDeviceNameBytes) ? $0 : nil },
			projects: projects,
			app: app,
			keys: keys)
		guard let encoded = payload.encoded() else { throw .engine(.tooLarge) }

		let sealed = await BlockingWork.run { BackupEngine.seal(payload: encoded.bytes, passphrase: passphrase) }
		switch sealed {
		case .success(let file):
			let summary = Summary(
				projects: inventory.count(where: { $0.listing != nil }),
				removedProjects: inventory.count(where: { $0.listing == nil }),
				keys: inventory.reduce(0) { total, project in total + project.environments.values.reduce(0) { $0 + $1.count } },
				destinations: destinations.values.reduce(0) { $0 + $1.count },
				syncKeys: keys?.keyCount ?? 0,
				settings: app?.settings != nil,
				unusableItems: snapshot.inventory.unusableItems,
				leftOut: snapshot.inventory.companion.excluded.map {
					LeftOut(name: $0.listing?.name ?? Self.removedProjectName($0.vaultId), reason: $0.reason)
				},
				withNewerData: inventory
					.filter { snapshot.inventory.companion.withNewerData.contains($0.vaultId) }
					.map { $0.listing?.name ?? Self.removedProjectName($0.vaultId) })
			return (file, summary)
		case .failure(.invalidContents(let reason, let offset?)):
			if let index = encoded.project(at: offset) { throw .invalidProject(name: projects[index].name, reason: reason) }
			throw .engine(.invalidContents(reason: reason, offset: offset))
		case .failure(let failure):
			throw .engine(failure)
		}
	}

	/// How a summary names a project removed from the sidebar, whose name
	/// went with it: by its ID, so two of them can be told apart.
	static func removedProjectName(_ vaultId: String) -> String {
		"A project removed from the sidebar (\(vaultId))"
	}

	/// Where a project syncs, when its metadata binds it to a principal the
	/// format can name; an organization's needs its slug.
	static func sync(_ metadata: SyncMetadata?, orgSlug: String?) -> BackupPayload.Sync? {
		guard let binding = metadata?.binding, binding.isValidCurrentWireBinding,
			BackupPayload.isLabel(binding.principalID, maximumBytes: BackupPayload.maximumPrincipalBytes)
		else { return nil }
		switch binding.scope {
		case "personal":
			return .init(registry: binding.registryURL, principalId: binding.principalID, scope: .personal)
		case "organization":
			guard let orgSlug, EnvValidation.isSafeOrgSlug(orgSlug) else { return nil }
			return .init(registry: binding.registryURL, principalId: binding.principalID, scope: .organization(slug: orgSlug))
		default:
			return nil
		}
	}

	/// The settings, keeping only orders of projects the backup holds and
	/// environment names it can carry.
	static func settings(_ settings: BackupAppSection.Settings, keeping vaultIds: Set<String>) -> BackupAppSection.Settings {
		var seen = Set<String>()
		var kept = settings
		kept.projectOrder = settings.projectOrder.filter { vaultIds.contains($0) && seen.insert($0).inserted }
		kept.environmentOrders = settings.environmentOrders.compactMapValues { order in
			var names = Set<String>()
			let valid = order.filter { EnvValidation.isValidEnvironmentName($0) && names.insert($0).inserted }
			return valid.isEmpty ? nil : Array(valid.prefix(BackupAppSection.maximumEnvironments))
		}.filter { vaultIds.contains($0.key) }
		return kept
	}

	/// Each chosen icon as a backup carries it: a copied image drawn again as
	/// the 128-pixel PNG LPM Vault keeps. An image that can't be read or drawn
	/// stays out, and the project shows its folder's icon after a restore.
	static func icons(_ choices: [String: ProjectIconChoice], imagesDirectory: URL) -> [String: BackupAppSection.Icon] {
		var icons: [String: BackupAppSection.Icon] = [:]
		for (vaultId, choice) in choices where choice.isValid {
			switch choice {
			case .automatic:
				continue
			case .storedImage(let file, let name):
				guard let read = try? ProjectIconImageFolder.read(file, in: imagesDirectory, maximumBytes: ProjectIconFile.maximumImageBytes),
					let copy = ProjectIconRenderer.copy(from: read.data), copy.png.count <= BackupAppSection.maximumIconBytes
				else { continue }
				icons[vaultId] = .image(name: name, png: copy.png)
			case .symbol, .emoji, .monogram, .projectFile:
				icons[vaultId] = .choice(choice)
			}
		}
		return icons
	}

	/// This Mac's name, as Sharing settings show it.
	static func computerName() -> String? {
		SCDynamicStoreCopyComputerName(nil, nil) as String?
	}
}
