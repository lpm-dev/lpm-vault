import Foundation

/// Whether a project folder's `lpm.json` points the LPM CLI at a vault.
enum ProjectCLILinkStatus: Equatable, Sendable {
	case linked
	case notLinked
	case linkedToOtherVault(String)
	case unreadable
	case noFolder
}

enum ProjectCLILinkError: LocalizedError, Equatable, Sendable {
	case noFolder
	case invalidJSON
	case unsafeFile
	case tooLarge
	case writeFailed
	case vaultChanged
	case unsafeStateDirectory
	case folderIsLPMHome
	/// The folder couldn't be linked for the LPM CLI on this Mac.
	case notLinkedOnThisMac
	/// The vault locked, or its account changed, before the folder was linked.
	case interrupted
	/// Another project here uses the folder, whose lpm.json links none; it says why.
	case usedByAnotherProject(String)

	var errorDescription: String? {
		switch self {
		case .noFolder:
			"The project folder no longer exists."
		case .invalidJSON:
			"lpm.json is not a valid JSON object. Fix it or copy the JSON instead."
		case .unsafeFile:
			"lpm.json is a symbolic link or not a regular file. Copy the JSON instead."
		case .tooLarge:
			"lpm.json is too large to update safely."
		case .writeFailed:
			"Could not write lpm.json."
		case .vaultChanged:
			"lpm.json changed. Check the link and try again."
		case .unsafeStateDirectory:
			".lpm in this folder is a symbolic link or not a folder, so the CLI won’t use it. Remove it or copy the JSON instead."
		case .folderIsLPMHome:
			"This folder’s .lpm is where LPM keeps your login and env secrets, so it can’t hold a project. Choose the folder that contains your project’s package.json."
		case .notLinkedOnThisMac:
			"The LPM CLI on this Mac uses the project’s values only in folders linked to it. Try again, or run lpm env link in the folder."
		case .interrupted:
			"LPM Vault locked before it finished linking the folder. Unlock it and try again."
		case .usedByAnotherProject(let explanation):
			explanation
		}
	}
}

enum ProjectCLILink {
	static func folder(vaultId: String, projectPath: String, defaults: UserDefaults = .standard) -> String {
		defaults.string(forKey: folderKey(vaultId)) ?? projectPath
	}

	static func rememberFolder(_ folder: String, vaultId: String, defaults: UserDefaults = .standard) {
		defaults.set(folder, forKey: folderKey(vaultId))
	}

	static func forgetFolder(vaultId: String, defaults: UserDefaults = .standard) {
		defaults.removeObject(forKey: folderKey(vaultId))
	}

	static let folderKeyPrefix = "lpm-vault-cli-folder-"

	private static func folderKey(_ vaultId: String) -> String { folderKeyPrefix + vaultId }

	struct Snapshot: Equatable, Sendable {
		let status: ProjectCLILinkStatus
		let configuration: ProjectCLIConfiguration
	}
	static func inspect(vaultId: String, folder: String) -> Snapshot {
		guard folderExists(folder) else { return Snapshot(status: .noFolder, configuration: .unverified) }
		do {
			let data = try ProjectConfigFile.readRegularFile(at: configURL(inFolder: folder))
			let document = try LPMConfigJSON(parsing: data, rejectDuplicateKeys: true)
			guard case .object = document else {
				return Snapshot(status: .unreadable, configuration: .unverified)
			}
			let status: ProjectCLILinkStatus
			switch document["vault"] {
			case nil, .null?: status = .notLinked
			case .string(let id)?: status = id == vaultId ? .linked : .linkedToOtherVault(id)
			default: return Snapshot(status: .unreadable, configuration: .unverified)
			}
			var projection = LPMConfigJSON.object([])
			for field in ["env", "environments"] {
				if let value = document[field] { projection.set(value, forKey: field) }
			}
			let bytes = try projection.renderedData(maximumBytes: 16 * 1024 * 1024)
			let configuration = try JSONDecoder().decode(LPMJSONValue.self, from: bytes)
			return Snapshot(status: status, configuration: .loaded(configuration))
		} catch ProjectConfigFile.FileError.notFound {
			return Snapshot(status: .notLinked, configuration: .absent)
		} catch { return Snapshot(status: .unreadable, configuration: .unverified) }
	}
	static func configuration(inFolder folder: String) -> ProjectCLIConfiguration {
		inspect(vaultId: "", folder: folder).configuration
	}
	static func configURL(inFolder folder: String) -> URL {
		URL(fileURLWithPath: folder, isDirectory: true).appendingPathComponent("lpm.json")
	}
	static func status(vaultId: String, folder: String) -> ProjectCLILinkStatus {
		inspect(vaultId: vaultId, folder: folder).status
	}

	/// Stops a check-only link just before it would write.
	private struct CheckedOnly: Error {}

	/// Adds or replaces the `vault` field in the folder's `lpm.json`, keeping
	/// other settings. With `checkOnly`, makes every check the write makes and
	/// stops before writing.
	static func link(
		vaultId: String, folder: String, replacingVaultId: String? = nil, home: LPMHome = .current,
		checkOnly: Bool = false
	) throws(ProjectCLILinkError) {
		guard folderExists(folder) else { throw .noFolder }
		do {
			try ProjectConfigFile.writeVaultID(
				vaultId, to: configURL(inFolder: folder),
				policy: replacingVaultId.map(ProjectConfigFile.VaultWritePolicy.replacing) ?? .unlinked,
				home: home,
				beforeWrite: checkOnly ? { throw CheckedOnly() } : nil
			)
		} catch is CheckedOnly {
			return
		} catch let error as ProjectConfigFile.FileError {
			switch error {
			case .invalidJSON, .duplicateJSONKey: throw .invalidJSON
			case .unsafeFile: throw .unsafeFile
			case .tooLarge: throw .tooLarge
			case .notFound, .readFailed, .writeFailed: throw .writeFailed
			case .changed: throw .vaultChanged
			case .unsafeStateDirectory: throw .unsafeStateDirectory
			case .stateIsLPMHome: throw .folderIsLPMHome
			}
		} catch {
			throw .writeFailed
		}
	}

	/// `link(vaultId:folder:replacingVaultId:)` on the queue that orders the app's
	/// `lpm.json` edits, returning why it failed.
	static func linkInBackground(
		vaultId: String, folder: String, replacingVaultId: String? = nil, home: LPMHome = .current,
		checkOnly: Bool = false
	) async -> ProjectCLILinkError? {
		await withCheckedContinuation { continuation in
			ProjectConfigFile.editQueue.async {
				do throws(ProjectCLILinkError) {
					try link(
						vaultId: vaultId, folder: folder, replacingVaultId: replacingVaultId, home: home,
						checkOnly: checkOnly)
					continuation.resume(returning: nil)
				} catch {
					continuation.resume(returning: error)
				}
			}
		}
	}

	/// Takes `chosen` as the project the LPM CLI acts on there: the nearest
	/// folder at or above it with a package.json or lpm.json, at its real
	/// path, as the CLI keeps a project's folder. A folder whose .lpm is the
	/// LPM home is refused. Blocks on the file system.
	static func choose(_ chosen: URL, for vaultId: String, home: LPMHome) -> Result<ProjectFolderChoice, ProjectCLILinkError> {
		let root = CLIFiles.projectRoot(for: chosen, home: home)
		if root?.stateIsHome == true { return .failure(.folderIsLPMHome) }
		let folder = realPath((root?.url ?? chosen).path)
		let picked = realPath(chosen.path)
		return .success(ProjectFolderChoice(
			path: folder, chosenInside: picked == folder ? nil : picked, status: status(vaultId: vaultId, folder: folder)))
	}

	private static func realPath(_ path: String) -> String {
		guard let resolved = realpath(path, nil) else { return path }
		defer { free(resolved) }
		return String(cString: resolved)
	}

	/// `folder` as it resolves on disk, links and `..` followed, so two
	/// spellings of one folder compare equal; one that's gone, as written,
	/// without a trailing slash. Blocks on the file system.
	static func resolvedFolder(_ folder: String) -> String {
		realPath(URL(fileURLWithPath: folder, isDirectory: true).standardizedFileURL.path)
	}

	/// The ID of the first of `folders` that is `folder`: one spelled the same
	/// way without asking the disk, or else one that is the same directory on
	/// it, as its device and inode say, however either is spelled. A folder
	/// that's gone matches only its own spelling. Blocks on the file system.
	static func firstFolder(
		matching folder: String, in folders: [(id: String, folder: String)],
		identity: (String) -> ProjectConfigFile.DirectoryIdentity? = { ProjectConfigFile.directoryIdentity(of: URL(fileURLWithPath: $0)) }
	) -> String? {
		let spelled = standardized(folder)
		let others = folders.map { (id: $0.id, folder: standardized($0.folder)) }
		if let same = others.first(where: { $0.folder == spelled }) { return same.id }
		guard let target = identity(spelled) else { return nil }
		return others.first { identity($0.folder) == target }?.id
	}

	/// Whether `first` and `second` are the same folder, as `firstFolder` decides.
	static func isSameFolder(_ first: String, _ second: String) -> Bool {
		firstFolder(matching: first, in: [(id: "", folder: second)]) != nil
	}

	private static func standardized(_ folder: String) -> String {
		URL(fileURLWithPath: folder, isDirectory: true).standardizedFileURL.path
	}

	private static func folderExists(_ folder: String) -> Bool {
		var isDirectory: ObjCBool = false
		return !folder.isEmpty
			&& FileManager.default.fileExists(atPath: folder, isDirectory: &isDirectory)
			&& isDirectory.boolValue
	}
}

/// A folder chosen for a project, as the LPM CLI takes it.
struct ProjectFolderChoice: Equatable, Sendable {
	/// The project the LPM CLI acts on for the folder chosen, at its real path.
	let path: String
	/// The folder chosen, when the project around it was taken instead.
	let chosenInside: String?
	/// What the folder's lpm.json says about the project.
	let status: ProjectCLILinkStatus

	/// Whether its lpm.json keeps it from becoming the project's: it links
	/// another project, or can't be read safely.
	var isTaken: Bool {
		switch status {
		case .linkedToOtherVault, .unreadable, .noFolder: true
		case .linked, .notLinked: false
		}
	}
}

/// Another project on this Mac whose folder a chosen folder is.
struct ProjectFolderUser: Equatable, Sendable {
	let id: String
	/// Its name; nil for one the person can't open here, which isn't named.
	let name: String?
	/// The folder chosen, as it was asked about.
	let folder: String

	/// Why the folder can't be another project's too: its lpm.json, there
	/// already or once one is written, links one project.
	var explanation: String {
		let folder = (folder as NSString).lastPathComponent.escapingDirectionControls
		guard let escapedName else {
			return "Another project on this Mac uses \(folder), and a folder’s lpm.json links one project. Choose another folder."
		}
		return "\(escapedName) uses \(folder), and a folder’s lpm.json links one project. Choose another folder, or open \(escapedName)."
	}

	var escapedName: String? { name?.escapingDirectionControls }
}

/// Why a folder chosen for a project wasn't taken.
enum ProjectFolderRefusal: Error, Equatable, Sendable {
	case unusable(ProjectCLILinkError)
	case usedBy(ProjectFolderUser)
}

/// What the CLI reads from the linked folder's `lpm.json` when it resolves environment names.
enum ProjectCLIConfiguration: Equatable, Sendable {
	/// The folder has not been read yet.
	case pending
	/// The folder has no `lpm.json`, so no aliases apply.
	case absent
	case loaded(LPMJSONValue)
	/// The folder or its `lpm.json` could not be read, so aliases are unknown.
	case unverified

	/// Whether `lpm.json` may define aliases that could not be checked.
	fileprivate var mayHideAliases: Bool {
		switch self {
		case .pending, .absent: false
		case .loaded(let value):
			if case .object = value { false } else { true }
		case .unverified: true
		}
	}
}

struct ProjectCLICommands: Equatable, Sendable {
	let environment: String
	let commands: [String]
	let warning: String?

	init(environment: String, configuration: ProjectCLIConfiguration) {
		self.environment = environment
		guard EnvValidation.isValidEnvironmentName(environment) else {
			commands = []
			warning = "This environment name cannot be used by the CLI."
			return
		}
		if case .loaded(.object(let config)) = configuration {
			let declared: Bool
			if case .object(let environments) = config["environments"] {
				declared = environments[environment] != nil
			} else {
				declared = false
			}
			if !declared, case .object(let aliases) = config["env"],
				case .string(let path) = aliases[environment], path.hasPrefix(".env.")
			{
				let resolved = String(path.dropFirst(5))
				if resolved != environment {
					commands = []
					warning = "lpm.json maps \(environment) to \(resolved). Declare \(environment) in its environments settings before using these values."
					return
				}
			}
		}
		warning = configuration.mayHideAliases
			? "lpm.json hasn’t been verified on this Mac yet. Check its environment aliases before running these."
			: nil
		let flag = "--env=\(environment)"
		commands = ["lpm env list \(flag)", "lpm dev \(flag)", "lpm run \(flag) <script>"]
	}
}

struct ProjectCLITaskExample: Equatable, Sendable {
	let json: String
	let warning: String?

	init?(vaultId: String, environments: [String], selectedEnvironment: String, configuration: ProjectCLIConfiguration) {
		let names = Set(environments.filter {
			!ProjectCLICommands(environment: $0, configuration: configuration).commands.isEmpty
		})
		guard let first = names.sorted().first else { return nil }
		let dev = names.contains("development") ? "development" : names.contains("default") ? "default" : first
		let start = names.contains("staging") ? "staging" : names.contains(selectedEnvironment) ? selectedEnvironment : dev
		let encoder = JSONEncoder()
		guard let vaultJSON = try? encoder.encode(vaultId),
			let devJSON = try? encoder.encode(dev), let startJSON = try? encoder.encode(start)
		else { return nil }
		json = """
		{
		  "vault": \(String(decoding: vaultJSON, as: UTF8.self)),
		  "tasks": {
		    "dev": { "env": \(String(decoding: devJSON, as: UTF8.self)) },
		    "start": { "env": \(String(decoding: startJSON, as: UTF8.self)) }
		  }
		}
		"""
		warning = configuration.mayHideAliases
			? "lpm.json hasn’t been verified on this Mac yet. Check its environment aliases before using the example."
			: nil
	}
}
