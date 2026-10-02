import Foundation

/// Whether a project folder's `lpm.json` points the lpm CLI at a vault.
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
		}
	}
}

enum ProjectCLILink {
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
	static func link(vaultId: String, folder: String) throws(ProjectCLILinkError) {
		guard folderExists(folder) else { throw .noFolder }
		do {
			try ProjectConfigFile.writeVaultID(vaultId, to: configURL(inFolder: folder))
		} catch let error as ProjectConfigFile.FileError {
			switch error {
			case .invalidJSON: throw .invalidJSON
			case .unsafeFile: throw .unsafeFile
			case .tooLarge: throw .tooLarge
			case .notFound, .readFailed: throw .writeFailed
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
