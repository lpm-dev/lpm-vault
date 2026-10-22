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
		/// For a file of secrets git tracks, the commands that untrack it, each quoted in backticks.
		var untrack: String? = nil
	}

	/// How a file of secrets was kept out of git before it was written.
	struct SecretFile: Equatable, Sendable {
		/// The engine's account of it: `outsideProject`, `alreadyIgnored`,
		/// `added`, `noRepository`, `unverified`, or `failed`.
		let ignore: String
		/// The ignore files that took a rule for it.
		let ignoreFiles: [String]
		/// What the user should know, such as a rule git couldn't confirm.
		let warnings: [String]
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

	/// Why git could commit what an LPM home holds.
	struct HomeExposure: Equatable, Sendable {
		let reason: String
		/// Whether the home is a repository's root, which only moving the home keeps out of git.
		let atRepositoryRoot: Bool

		/// Why the `contents` saved in the home could be committed, and what keeps them out.
		func explanation(of contents: String) -> String {
			let remedy = atRepositoryRoot
				? "Use an LPM home outside the repository."
				: "Give it a .gitignore that ignores everything (*), or use an LPM home outside the repository."
			return "\(reason), so git could commit the \(contents) saved there. \(remedy)"
		}
	}

	private static let maximumOutputBytes = 1024 * 1024

	/// Creates `home` owner-only where it is missing and keeps it out of git
	/// with a `.gitignore` that ignores everything, as the CLI does before it
	/// writes login or env state there. Returns why git could still commit
	/// what the home holds, where a repository around it could; nothing that
	/// adds login or env state may be written there then.
	static func prepareHome(_ home: LPMHome) throws(Refusal) -> HomeExposure? {
		let result = home.url.path.withEngineBytes { home in
			lpm_env_prepare_home(home.baseAddress, home.count)
		}
		switch decode(result) {
		case .success(let output):
			guard let exposed = output["exposed"], exposed != .null else { return nil }
			guard case .string(let reason)? = exposed["reason"], case .bool(let atRoot)? = exposed["atRepositoryRoot"] else {
				throw Refusal(code: "env.engine_internal", message: "The LPM engine returned an unreadable answer.")
			}
			return HomeExposure(reason: reason, atRepositoryRoot: atRoot)
		case .failure(let refusal):
			throw refusal
		}
	}

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

	/// Readies `path` for a file of secrets the caller then writes, as `lpm env
	/// export` readies one for the project at `project`: git is made to ignore
	/// it, by a rule in the `.gitignore` of the project or of the repository
	/// that holds it, and a file git tracks is refused (`env.secret_tracked`).
	/// Runs git, so it blocks.
	static func prepareSecretFile(at path: URL, project: URL) throws(Refusal) -> SecretFile {
		let result = project.path.withEngineBytes { project in
			path.path.withEngineBytes { path in
				lpm_env_prepare_secret_file(project.baseAddress, project.count, path.baseAddress, path.count)
			}
		}
		let output = try decode(result).get()
		guard case .object? = output["ignore"], case .string(let kind)? = output["ignore"]?["kind"],
			case .array(let files)? = output["ignore"]?["files"], case .array(let warnings)? = output["warnings"]
		else { throw Refusal(code: "env.engine_internal", message: "The LPM engine returned an unreadable answer.") }
		let strings = { (values: [LPMConfigJSON]) in values.compactMap { if case .string(let text) = $0 { text } else { nil } } }
		return SecretFile(ignore: kind, ignoreFiles: strings(files), warnings: strings(warnings))
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
		var untrack: String?
		if case .string(let commands)? = output["untrack"] { untrack = commands }
		return .failure(Refusal(code: code, message: message, untrack: untrack))
	}
}

private extension String {
	/// Runs `body` with this string's UTF-8 bytes, as the engine's byte ranges take them.
	func withEngineBytes<T>(_ body: (UnsafeBufferPointer<UInt8>) -> T) -> T {
		var contiguous = self
		return contiguous.withUTF8(body)
	}
}
