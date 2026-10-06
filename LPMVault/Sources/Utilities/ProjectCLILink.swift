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

	/// Adds or replaces the `vault` field in the folder's `lpm.json`, keeping other settings.
	static func link(vaultId: String, folder: String, replacingVaultId: String? = nil) throws(ProjectCLILinkError) {
		guard folderExists(folder) else { throw .noFolder }
		do {
			try ProjectConfigFile.writeVaultID(
				vaultId, to: configURL(inFolder: folder),
				policy: replacingVaultId.map(ProjectConfigFile.VaultWritePolicy.replacing) ?? .unlinked
			)
		} catch let error as ProjectConfigFile.FileError {
			switch error {
			case .invalidJSON, .duplicateJSONKey: throw .invalidJSON
			case .unsafeFile: throw .unsafeFile
			case .tooLarge: throw .tooLarge
			case .notFound, .readFailed, .writeFailed: throw .writeFailed
			case .changed: throw .vaultChanged
			}
		} catch {
			throw .writeFailed
		}
	}

	/// `link(vaultId:folder:replacingVaultId:)` on the queue that orders the app's
	/// `lpm.json` edits, returning why it failed.
	static func linkInBackground(vaultId: String, folder: String, replacingVaultId: String? = nil) async -> ProjectCLILinkError? {
		await withCheckedContinuation { continuation in
			ProjectConfigFile.editQueue.async {
				do throws(ProjectCLILinkError) {
					try link(vaultId: vaultId, folder: folder, replacingVaultId: replacingVaultId)
					continuation.resume(returning: nil)
				} catch {
					continuation.resume(returning: error)
				}
			}
		}
	}

	private static func folderExists(_ folder: String) -> Bool {
		var isDirectory: ObjCBool = false
		return !folder.isEmpty
			&& FileManager.default.fileExists(atPath: folder, isDirectory: &isDirectory)
			&& isDirectory.boolValue
	}
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
			? "Check lpm.json aliases before running. The project configuration has not been verified."
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
			? "Check lpm.json aliases before using the example. The project configuration has not been verified."
			: nil
	}
}
