import Foundation
import Observation

/// A setting Settings' search finds: the page it's on, its name as its row
/// shows it, and other words people look for it by. A page's rows take their
/// names from here, so search always names them as the page does.
struct VaultSettingsEntry: Hashable, Identifiable, Sendable {
	let id: String
	let category: VaultSettingsCategory
	let title: String
	let keywords: [String]

	private init(_ id: String, _ category: VaultSettingsCategory, _ title: String, _ keywords: [String]) {
		self.id = id
		self.category = category
		self.title = title
		self.keywords = keywords
	}

	static let quitShortcut = Self("quit-shortcut", .general, "Quit shortcut",
		["quit", "exit", "command q", "⌘Q", "double press", "hold", "keyboard shortcut"])
	static let newProjectHistory = Self("new-project-history", .general, "Keep local history for new projects",
		["history", "rollback", "roll back", "undo", "versions", "changes", "space", "storage", "usage"])

	static let lockAfter = Self("lock-after", .security, "Lock after",
		["auto-lock", "autolock", "timeout", "idle", "inactivity", "minutes", "locking"])
	static let lockOnSleep = Self("lock-on-sleep", .security, "Locks when your Mac sleeps, its screen locks or you close the window",
		["screen saver", "screensaver", "lid", "locking"])
	static let hideInBackground = Self("hide-in-background", .security, "Hides values while another app is in front",
		["privacy", "background", "switch apps", "inactive"])
	static let valueApproval = Self("value-approval", .security, "Ask again to show or copy a value",
		["Touch ID", "password", "biometric", "authenticate", "approval", "reveal"])
	static let rehideValues = Self("rehide-values", .security, "Hide shown values again",
		["mask", "re-hide", "rehide", "conceal", "reveal"])
	static let sensitiveActions = Self("sensitive-actions", .security,
		"Publishing and backups ask for Touch ID or your password every time, however recently you unlocked",
		["approval", "authenticate", "biometric", "values"])
	static let clipboardClear = Self("clipboard-clear", .security, "Clear copied values after",
		["clipboard", "copy", "paste", "pasteboard", "seconds"])
	static let clipboardStaysLocal = Self("clipboard-stays-local", .security,
		"Copies stay on this Mac: Universal Clipboard and clipboard history apps skip them",
		["Handoff", "iPhone", "iPad", "other devices", "pasteboard", "copy"])
	static let hideFromCapture = Self("hide-from-capture", .security, "Hide from screenshots and screen sharing",
		["screenshot", "screen recording", "record", "capture", "Zoom", "Meet", "Teams", "privacy"])

	static let theme = Self("theme", .appearance, "Theme",
		["dark mode", "light mode", "colors", "colours", "system appearance"])

	static let account = Self("account", .account, "Account",
		["sign in", "sign out", "log in", "log out", "login", "logout", "lpm.dev", "profile", "plan", "email", "username"])
	static let registryServer = Self("registry-server", .account, "Registry server",
		["sync", "cloud", "lpm.dev", "localhost"])

	static let cliStatus = Self("cli-status", .cli, "LPM CLI",
		["lpm", "command line", "terminal", "shell", "install", "version", "PATH"])
	static let cliApproval = Self("cli-approval", .cli, "Ask before the CLI reads a new project",
		["Touch ID", "password", "approval", "access", "new projects"])
	static let lpmHome = Self("lpm-home", .cli, "LPM home",
		["LPM_HOME", "~/.lpm", "folder", "directory", "location", "move"])

	static let connectedPlatforms = Self("connected-platforms", .platforms, "Connected platforms",
		["Vercel", "Netlify", "GitHub", "Cloudflare", "Coolify", "disconnect", "rename", "reconnect", "publish", "deploy"])
	static let addPlatform = Self("add-platform", .platforms, "Add a platform",
		["connect", "Vercel", "Netlify", "GitHub", "Cloudflare", "Coolify", "API token", "publish", "deploy"])
	static let revokePlatformAccess = Self("revoke-platform-access", .platforms, "How to Remove LPM Vault’s Access",
		["revoke", "disconnect", "tokens"])

	static let exportBackup = Self("export-backup", .backup, "Export Backup",
		["save", "new Mac", "migrate", "move", "transfer", "encrypted file", "erase"])
	static let restoreBackup = Self("restore-backup", .backup, "Restore from Backup",
		["import", "new Mac", "migrate", "move", "transfer", "recover"])
	static let backupReminder = Self("backup-reminder", .backup, "Remind me to back up every month",
		["backup", "reminder", "monthly"])

	static let installedVersion = Self("installed-version", .updates, "Installed version",
		["check for updates", "build", "upgrade", "new version"])
	static let automaticChecks = Self("automatic-checks", .updates, "Check automatically",
		["automatic updates", "auto-update", "autoupdate", "upgrade"])
	static let backgroundInstall = Self("background-install", .updates, "Download and install in the background",
		["automatic updates", "auto-update", "autoupdate", "silent", "upgrade"])
	static let updateChannel = Self("update-channel", .updates, "Update channel",
		["beta", "stable", "preview", "prerelease", "release"])

	static let releaseNotes = Self("release-notes", .about, "Release notes",
		["changelog", "what’s new", "whats new", "changes", "releases"])
	static let documentation = Self("documentation", .about, "Documentation",
		["docs", "help", "guide", "manual"])
	static let feedback = Self("feedback", .about, "Send feedback",
		["bug", "issue", "report", "GitHub", "support", "contact", "problem"])
	static let acknowledgements = Self("acknowledgements", .about, "Acknowledgements",
		["acknowledgments", "licenses", "licences", "open source", "credits", "third party"])

	/// Every setting search finds, page by page in the menu's order, and each
	/// page's in the order it shows them.
	static let all: [VaultSettingsEntry] = [
		quitShortcut, newProjectHistory,
		lockAfter, lockOnSleep, hideInBackground, valueApproval, rehideValues, sensitiveActions,
		clipboardClear, clipboardStaysLocal, hideFromCapture,
		theme,
		account, registryServer,
		cliStatus, cliApproval, lpmHome,
		connectedPlatforms, addPlatform, revokePlatformAccess,
		exportBackup, restoreBackup, backupReminder,
		installedVersion, automaticChecks, backgroundInstall, updateChannel,
		releaseNotes, documentation, feedback, acknowledgements,
	]
}

/// What Settings' search has found, which result it shows, and the setting
/// its page should bring into view.
@Observable
@MainActor
final class VaultSettingsSearch {
	/// A request to bring a setting into view and mark it. Choosing the same
	/// setting again is a new request, so its page shows it again.
	struct Highlight: Equatable, Sendable {
		let entry: VaultSettingsEntry.ID
		let request: Int
	}

	var query = "" {
		didSet {
			guard query != oldValue else { return }
			results = Self.results(for: query)
			if let selected, !results.contains(where: { $0.id == selected }) { self.selected = nil }
		}
	}

	private(set) var results: [VaultSettingsEntry] = []
	/// The result shown, which arrows move from.
	private(set) var selected: VaultSettingsEntry.ID?
	private(set) var highlight: Highlight?
	@ObservationIgnored private var requests = 0

	var isSearching: Bool { !Self.terms(in: query).isEmpty }

	/// Selects `entry` and asks its page to bring it into view.
	func choose(_ entry: VaultSettingsEntry) {
		selected = entry.id
		requests += 1
		highlight = Highlight(entry: entry.id, request: requests)
	}

	/// The result `offset` places from the one shown, or the first one going
	/// down while none is; nil when there's nowhere to go.
	func result(movingBy offset: Int) -> VaultSettingsEntry? {
		guard !results.isEmpty else { return nil }
		guard let index = selected.flatMap({ id in results.firstIndex { $0.id == id } }) else {
			return offset > 0 ? results.first : nil
		}
		let next = min(max(index + offset, 0), results.count - 1)
		return next == index ? nil : results[next]
	}

	/// What Return shows: the result shown, or the best one.
	var resultForReturn: VaultSettingsEntry? {
		selected.flatMap { id in results.first { $0.id == id } } ?? results.first
	}

	func clear() {
		query = ""
		selected = nil
		highlight = nil
	}

	// MARK: - Matching

	private struct Indexed: Sendable {
		let entry: VaultSettingsEntry
		let title: [String]
		let category: [String]
		let all: [String]
	}

	private nonisolated static let index: [Indexed] = VaultSettingsEntry.all.map { entry in
		let title = terms(in: entry.title)
		let category = terms(in: entry.category.title)
		return Indexed(entry: entry, title: title, category: category,
			all: title + category + entry.keywords.flatMap(terms(in:)))
	}

	/// The settings `query` finds: every word of it begins a word of a
	/// setting's name, page or keywords. Those whose names hold every word come
	/// first, and those on a page the query names; a page's results stay together.
	nonisolated static func results(for query: String) -> [VaultSettingsEntry] {
		let words = terms(in: query)
		guard !words.isEmpty else { return [] }
		var found: [(entry: VaultSettingsEntry, score: Int, order: Int)] = []
		for (order, item) in index.enumerated() {
			guard words.allSatisfy({ word in item.all.contains { $0.hasPrefix(word) } }) else { continue }
			var score = 0
			if words.allSatisfy({ word in item.title.contains { $0.hasPrefix(word) } }) { score += 2 }
			if words.contains(where: { word in item.category.contains { $0.hasPrefix(word) } }) { score += 1 }
			found.append((item.entry, score, order))
		}
		var best: [VaultSettingsCategory: Int] = [:]
		for item in found { best[item.entry.category] = max(best[item.entry.category, default: 0], item.score) }
		return found.sorted { lhs, rhs in
			let left = lhs.entry.category, right = rhs.entry.category
			if left != right {
				let leftBest = best[left, default: 0], rightBest = best[right, default: 0]
				if leftBest != rightBest { return leftBest > rightBest }
				return pageOrder[left, default: 0] < pageOrder[right, default: 0]
			}
			return lhs.score != rhs.score ? lhs.score > rhs.score : lhs.order < rhs.order
		}.map(\.entry)
	}

	private nonisolated static let pageOrder = Dictionary(uniqueKeysWithValues:
		VaultSettingsCategory.allCases.enumerated().map { ($0.element, $0.offset) })

	/// The words of `text`, folded so case, accents and width don't matter.
	nonisolated static func terms(in text: String) -> [String] {
		text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
			.split { !$0.isLetter && !$0.isNumber }
			.map(String.init)
	}
}
