import Foundation
import Testing

@testable import LPMVault

@MainActor
struct SettingsSearchTests {
	private func ids(_ query: String) -> [VaultSettingsEntry.ID] {
		VaultSettingsSearch.results(for: query).map(\.id)
	}

	@Test("every setting search lists has its own id and name, every page has some, and they're listed page by page")
	func catalog() {
		let all = VaultSettingsEntry.all
		#expect(Set(all.map(\.id)).count == all.count)
		#expect(Set(all.map(\.title)).count == all.count)
		#expect(Set(all.map(\.category)) == Set(VaultSettingsCategory.allCases))
		let pages = VaultSettingsCategory.allCases
		let order = all.map { pages.firstIndex(of: $0.category) ?? -1 }
		#expect(order == order.sorted(), "In the menu's order")
	}

	@Test("each word typed begins a word of a setting's name, its page or the words people look for it by")
	func matching() {
		#expect(ids("screenshot") == [VaultSettingsEntry.hideFromCapture.id])
		#expect(ids("dark mode") == [VaultSettingsEntry.theme.id], "A keyword")
		#expect(ids("THÈME") == [VaultSettingsEntry.theme.id], "Case and accents don't matter")
		#expect(ids("LPM_HOME").first == VaultSettingsEntry.lpmHome.id, "Underscores split words, as spaces do")
		#expect(ids("touch cli") == [VaultSettingsEntry.cliApproval.id], "Every word has to match")
		#expect(ids("timeout") == [VaultSettingsEntry.lockAfter.id])
		#expect(ids("zzz").isEmpty)
		#expect(ids("").isEmpty && ids("  ").isEmpty)
	}

	@Test("settings whose names hold the words come first, and those on a page the words name; a page's results stay together")
	func ranking() {
		#expect(ids("lock").first == VaultSettingsEntry.lockAfter.id)
		let backup = ids("backup")
		#expect(Array(backup.prefix(3)) == [VaultSettingsEntry.exportBackup.id, VaultSettingsEntry.restoreBackup.id,
			VaultSettingsEntry.backupReminder.id], "Backup & Restore's first, as the words name it: \(backup)")
		#expect(backup.contains(VaultSettingsEntry.sensitiveActions.id), "Security's fact about backups too")
		#expect(ids("update").first == VaultSettingsEntry.updateChannel.id)
		for query in ["a", "e", "s", "touch", "copy", "version"] {
			let pages = VaultSettingsSearch.results(for: query).map(\.category)
			var seen: [VaultSettingsCategory] = []
			for page in pages where seen.last != page { seen.append(page) }
			#expect(Set(seen).count == seen.count, "\(query): \(pages)")
		}
	}

	@Test("arrows move through the results from none shown, and stop at either end; Return shows the one shown, or the best")
	func selection() throws {
		let search = VaultSettingsSearch()
		#expect(!search.isSearching && search.results.isEmpty && search.resultForReturn == nil)
		search.query = "backup"
		#expect(search.isSearching && search.selected == nil)
		#expect(search.result(movingBy: -1) == nil, "Nothing above the field")
		#expect(search.resultForReturn == .exportBackup)
		let first = try #require(search.result(movingBy: 1))
		#expect(first == .exportBackup)
		search.choose(first)
		#expect(search.selected == first.id && search.highlight == .init(entry: first.id, request: 1))
		let second = try #require(search.result(movingBy: 1))
		search.choose(second)
		#expect(search.resultForReturn == second)
		#expect(search.result(movingBy: -1) == first)
		search.choose(try #require(search.results.last))
		#expect(search.result(movingBy: 1) == nil, "The last stays the last")

		search.choose(first)
		let shown = search.highlight
		search.choose(first)
		#expect(search.highlight?.entry == first.id && search.highlight != shown, "Choosing it again asks its page again")
	}

	@Test("typing on keeps the result shown while it still matches, and drops it once it doesn't; clearing ends the search")
	func refining() throws {
		let search = VaultSettingsSearch()
		search.query = "back"
		search.choose(.restoreBackup)
		search.query = "backup"
		#expect(search.selected == VaultSettingsEntry.restoreBackup.id)
		search.query = "backup export"
		#expect(search.results == [.exportBackup] && search.selected == nil)
		search.clear()
		#expect(search.query.isEmpty && !search.isSearching && search.results.isEmpty)
		#expect(search.selected == nil && search.highlight == nil)
	}

	@Test("⌘F searches Settings while it shows, rather than the projects hidden under it")
	func findTarget() {
		#expect(VaultFindTarget(showingSettings: false) == .secrets)
		#expect(VaultFindTarget(showingSettings: false).notification == .findSecrets)
		#expect(VaultFindTarget(showingSettings: true) == .settings)
		#expect(VaultFindTarget(showingSettings: true).notification == .findSettings)
		#expect(VaultFindTarget(showingSettings: true).title == "Find in Settings")
	}
}
