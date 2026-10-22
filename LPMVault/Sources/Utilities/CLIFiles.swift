import Foundation
import LPMEnv

/// The LPM home: the directory where the LPM CLI keeps login and env state.
struct LPMHome: Equatable, Sendable {
	let url: URL
	/// The home folder of the user it belongs to. The CLI never takes it, or a
	/// folder above it, for a project.
	let userHome: URL

	/// `~/.lpm`, the home the CLI uses unless `LPM_HOME` names another.
	static var standard: LPMHome {
		let userHome = FileManager.default.homeDirectoryForCurrentUser
		return LPMHome(url: userHome.appendingPathComponent(".lpm", isDirectory: true), userHome: userHome)
	}
}

/// The LPM home and project files, handled by the LPM CLI's own code in the
/// bundled engine, so the app keeps them exactly as the CLI does.
enum CLIFiles {
	/// Why the engine refused or failed an operation: a stable code, and a
	/// message naming what it found.
	struct Refusal: Error, Equatable, Sendable {
		let code: String
		let message: String
	}

	/// The project the CLI's env commands act on for a folder.
	struct ProjectRoot: Equatable, Sendable {
		/// The nearest folder at or above the chosen one with a `package.json`
		/// or an `lpm.json`, below the user's home folder, else the chosen folder.
		let url: URL
		/// Whether `url` holds a `package.json` or an `lpm.json`.
		let isProject: Bool
		/// Whether the project's `.lpm` is the LPM home, which keeps no project state.
		let stateIsHome: Bool
	}

	private static let maximumOutputBytes = 1024 * 1024

	/// The project the CLI acts on for `folder`, with `home` as the LPM home;
	/// nil when the engine can't tell.
	static func projectRoot(for folder: URL, home: LPMHome) -> ProjectRoot? {
		let result = folder.path.withEngineBytes { folder in
			home.userHome.path.withEngineBytes { userHome in
				home.url.path.withEngineBytes { home in
					lpm_env_project_root(folder.baseAddress, folder.count, userHome.baseAddress, userHome.count, home.baseAddress, home.count)
				}
			}
		}
		guard case .success(let output) = decode(result),
			case .string(let root)? = output["root"], !root.isEmpty,
			case .bool(let isProject)? = output["isProject"],
			case .bool(let stateIsHome)? = output["stateIsHome"]
		else { return nil }
		return ProjectRoot(url: URL(fileURLWithPath: root, isDirectory: true), isProject: isProject, stateIsHome: stateIsHome)
	}

	/// Opens the `.lpm` of the project directory open at `descriptor`, at
	/// `url`, as the CLI does, and returns a descriptor for it that the caller
	/// closes. Codes: `env.project_state_is_home`, `env.project_state_link`,
	/// and `env.project_state`.
	static func openProjectState(in descriptor: Int32, at url: URL, home: LPMHome) throws(Refusal) -> Int32 {
		var state: Int32 = -1
		let result = url.path.withEngineBytes { display in
			home.url.path.withEngineBytes { home in
				lpm_env_open_project_state(descriptor, display.baseAddress, display.count, home.baseAddress, home.count, &state)
			}
		}
		switch decode(result) {
		case .success:
			guard state >= 0 else { throw Refusal(code: "env.engine_internal", message: "The LPM engine opened no state directory.") }
			return state
		case .failure(let refusal):
			if state >= 0 { close(state) }
			throw refusal
		}
	}

	/// The output of an engine call, which this releases: its JSON object when
	/// it succeeded, else why it didn't.
	private static func decode(_ result: LPMEnvResult) -> Result<LPMConfigJSON, Refusal> {
		defer { lpm_env_release(result) }
		guard lpm_env_abi_version() == 1 else {
			return .failure(Refusal(code: "env.abi_mismatch", message: "The bundled LPM engine is not the version this app expects."))
		}
		guard let data = result.data, result.length > 0, result.length <= maximumOutputBytes,
			let output = try? LPMConfigJSON(parsing: Data(bytes: data, count: result.length), rejectDuplicateKeys: true),
			case .object = output
		else {
			return .failure(Refusal(code: "env.engine_internal", message: "The LPM engine returned an unreadable answer."))
		}
		if result.status == 0 { return .success(output) }
		guard case .string(let code)? = output["code"] else {
			return .failure(Refusal(code: "env.engine_internal", message: "The LPM engine returned an unreadable answer."))
		}
		let message: String
		if case .string(let text)? = output["message"], !text.isEmpty { message = text } else {
			message = result.status == 2 ? "The LPM engine was given an invalid path." : "The LPM engine failed (\(code))."
		}
		return .failure(Refusal(code: code, message: message))
	}
}

private extension String {
	/// Runs `body` with this string's UTF-8 bytes, as the engine's byte ranges take them.
	func withEngineBytes<T>(_ body: (UnsafeBufferPointer<UInt8>) -> T) -> T {
		var contiguous = self
		return contiguous.withUTF8(body)
	}
}
