import Foundation

/// The LPM home: the directory where the LPM CLI keeps login and env state,
/// `~/.lpm` unless `LPM_HOME` names another. The CLI keeps another home's
/// credential-store entries apart by appending a digest of its location to
/// their service names, which `service(_:)` does here too.
struct LPMHome: Equatable, Sendable {
	let url: URL
	/// The home folder of the user it belongs to. The CLI never takes it, or a
	/// folder above it, for a project.
	let userHome: URL
	/// What the CLI appends to its service names here; nil in the default home.
	let scope: String?

	/// `.lpm` in `userHome`, the home the CLI uses unless `LPM_HOME` names another.
	init(defaultIn userHome: URL) {
		url = userHome.appendingPathComponent(".lpm", isDirectory: true)
		self.userHome = userHome
		scope = nil
	}

	private init(url: URL, userHome: URL, scope: String?) {
		self.url = url
		self.userHome = userHome
		self.scope = scope
	}

	/// The home at `url`, an absolute path, as the CLI with `LPM_HOME` set to it
	/// would use it, kept where it is once links on the way are followed, as the
	/// CLI opens it; nil when the engine can't place it. Blocking file work.
	static func at(_ url: URL, userHome: URL = FileManager.default.homeDirectoryForCurrentUser) -> LPMHome? {
		guard url.isFileURL, url.path.hasPrefix("/") else { return nil }
		let description: (identity: String, scope: String?)
		do { description = try CLIFiles.describeHome(at: url, userHome: userHome) } catch { return nil }
		guard let scope = description.scope else { return LPMHome(defaultIn: userHome) }
		return LPMHome(url: URL(fileURLWithPath: description.identity, isDirectory: true), userHome: userHome, scope: scope)
	}

	/// `~/.lpm`.
	static var standard: LPMHome { LPMHome(defaultIn: FileManager.default.homeDirectoryForCurrentUser) }

	/// The preference that names the home the app uses; absent for `~/.lpm`.
	static let preferenceKey = "lpm-vault-lpm-home"

	/// The home this launch of the app uses, chosen in Settings. Changing it
	/// relaunches the app, so every service name and path in one launch comes
	/// from the same home.
	static let current = chosen(in: UserDefaults.standard)

	/// The home `preferences` names, or `~/.lpm` when it names none, or one the
	/// engine can't place.
	static func chosen(in preferences: UserDefaults, userHome: URL = FileManager.default.homeDirectoryForCurrentUser) -> LPMHome {
		guard let path = preferences.string(forKey: preferenceKey), path.hasPrefix("/"),
			let home = at(URL(fileURLWithPath: path, isDirectory: true), userHome: userHome)
		else { return LPMHome(defaultIn: userHome) }
		return home
	}

	/// Makes `home` the one `preferences` names, for the next launch.
	static func choose(_ home: LPMHome, in preferences: UserDefaults) {
		if home.isDefault {
			preferences.removeObject(forKey: preferenceKey)
		} else {
			preferences.set(home.url.path, forKey: preferenceKey)
		}
	}

	/// The preference that keeps what a move couldn't remove from the home it left.
	static let leftoversKey = "lpm-vault-lpm-home-move-leftovers"

	/// Keeps, for the next launch to show, what a move left in `source`.
	static func recordLeftovers(_ leftovers: [String], of source: LPMHome, in preferences: UserDefaults) {
		if leftovers.isEmpty {
			preferences.removeObject(forKey: leftoversKey)
		} else {
			preferences.set(["home": source.displayPath, "items": leftovers], forKey: leftoversKey)
		}
	}

	/// What the last move left in the home it moved from, and that home.
	static func leftovers(in preferences: UserDefaults) -> (home: String, items: [String])? {
		guard let record = preferences.dictionary(forKey: leftoversKey),
			let home = record["home"] as? String, let items = record["items"] as? [String], !items.isEmpty
		else { return nil }
		return (home, items)
	}

	/// The preference that names the homes a move runs between until it ends,
	/// so an unlock after one that didn't removes the copies it left.
	static let moveKey = "lpm-vault-lpm-home-move"

	/// Keeps, until `endMove(in:)`, that a move from `source` to `target` runs.
	static func beginMove(from source: LPMHome, to target: LPMHome, in preferences: UserDefaults) {
		preferences.set(["from": source.url.path, "to": target.url.path], forKey: moveKey)
	}

	static func endMove(in preferences: UserDefaults) {
		preferences.removeObject(forKey: moveKey)
	}

	/// The folders of the homes a move ran between, when one didn't end.
	static func unfinishedMove(in preferences: UserDefaults) -> (from: URL, to: URL)? {
		guard let record = preferences.dictionary(forKey: moveKey),
			let from = record["from"] as? String, let to = record["to"] as? String,
			from.hasPrefix("/"), to.hasPrefix("/")
		else { return nil }
		return (URL(fileURLWithPath: from, isDirectory: true), URL(fileURLWithPath: to, isDirectory: true))
	}

	var isDefault: Bool { scope == nil }

	/// `service` as the CLI names it in the credential store for this home.
	func service(_ service: String) -> String {
		scope.map { "\(service):\($0)" } ?? service
	}

	/// The home as the user reads it, with their home folder as `~`.
	var displayPath: String { (url.path as NSString).abbreviatingWithTildeInPath }
}

/// `UserDefaults`, which Foundation documents as thread-safe but doesn't mark
/// `Sendable`, for work that records a choice off the main actor.
struct ThreadSafeDefaults: @unchecked Sendable {
	let defaults: UserDefaults
}
