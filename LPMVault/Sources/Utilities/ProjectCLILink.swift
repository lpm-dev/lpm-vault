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

	private static func folderKey(_ vaultId: String) -> String { "lpm-vault-cli-folder-" + vaultId }

	static func configURL(inFolder folder: String) -> URL {
		URL(fileURLWithPath: folder, isDirectory: true).appendingPathComponent("lpm.json")
	}

	static func status(vaultId: String, folder: String) -> ProjectCLILinkStatus {
		guard folderExists(folder) else { return .noFolder }
		do {
			switch try ProjectConfigFile.vaultID(at: configURL(inFolder: folder)) {
			case vaultId?: return .linked
			case let other?: return .linkedToOtherVault(other)
			case nil: return .notLinked
			}
		} catch ProjectConfigFile.FileError.notFound {
			return .notLinked
		} catch {
			return .unreadable
		}
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
			case .invalidJSON: throw .invalidJSON
			case .unsafeFile: throw .unsafeFile
			case .tooLarge: throw .tooLarge
			case .notFound, .readFailed: throw .writeFailed
			case .vaultChanged: throw .vaultChanged
			}
		} catch {
			throw .writeFailed
		}
	}

	private static func folderExists(_ folder: String) -> Bool {
		var isDirectory: ObjCBool = false
		return !folder.isEmpty
			&& FileManager.default.fileExists(atPath: folder, isDirectory: &isDirectory)
			&& isDirectory.boolValue
	}
}

struct ProjectCLICommands: Equatable, Sendable {
	let environment: String
	let commands: [String]
	let warning: String?

	init(environment: String, configuration: LPMJSONValue?) {
		self.environment = environment
		guard EnvValidation.isValidEnvironmentName(environment) else {
			commands = []
			warning = "This environment name cannot be used by the CLI."
			return
		}
		if case .object(let config) = configuration {
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
			warning = nil
		} else {
			warning = "Check lpm.json aliases before running. The project configuration has not been verified."
		}
		let flag = "--env=\(environment)"
		commands = ["lpm env list \(flag)", "lpm dev \(flag)", "lpm run \(flag) <script>"]
	}
}
