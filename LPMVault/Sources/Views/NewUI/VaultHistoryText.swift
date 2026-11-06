import Foundation
import SwiftUI

/// What the History page, the inspector and the reviews say about entries.
/// The year shows only in the status bar and in dates outside this year.
struct VaultHistoryText {
	var now: Date
	var calendar = Calendar.current
	var locale = Locale.current

	static let sources: [(VaultLocalHistory.Source?, String)] = [
		(nil, "All"),
		(.app, "LPM Vault"),
		(.cli, "LPM CLI"),
		(.import, "Imports"),
		(.restore, "Restores"),
		(.pull, "Pulls"),
		(.rollback, "Rollbacks"),
		(.outside, "Outside history"),
	]

	static func date(_ milliseconds: Int64) -> Date {
		Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1000)
	}

	/// A format in this text's locale, calendar and the calendar's time zone.
	private func style(date: Date.FormatStyle.DateStyle? = nil, time: Date.FormatStyle.TimeStyle? = nil) -> Date.FormatStyle {
		Date.FormatStyle(date: date, time: time, locale: locale, calendar: calendar, timeZone: calendar.timeZone)
	}

	// MARK: - Times

	/// A clock time, as the user's locale writes it: "14:02".
	func clock(_ date: Date) -> String {
		date.formatted(style(date: .omitted, time: .shortened))
	}

	/// A day heading: "Today", "Yesterday", "Nov 2", or "Nov 2, 2025" outside this year.
	func day(_ date: Date) -> String {
		if calendar.isDate(date, inSameDayAs: now) { return "Today" }
		if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
			return "Yesterday"
		}
		return dayAndMonth(date)
	}

	/// "Nov 3", or "Nov 3, 2025" outside this year.
	func dayAndMonth(_ date: Date) -> String {
		let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
		let format = style().month(.abbreviated).day()
		return date.formatted(sameYear ? format : format.year())
	}

	/// "Today, 13:40", "Nov 3, 14:02" or "Nov 3, 2025, 14:02".
	func moment(_ date: Date) -> String {
		"\(day(date)), \(clock(date))"
	}

	/// "since 13:40 today", "since Nov 3, 14:02".
	func since(_ date: Date) -> String {
		calendar.isDate(date, inSameDayAs: now) ? "since \(clock(date)) today" : "since \(moment(date))"
	}

	/// The inspector's full time: "Today, Nov 4, 2026 at 13:40:07".
	func full(_ date: Date) -> String {
		let written = date.formatted(style(date: .abbreviated, time: .standard))
		return calendar.isDate(date, inSameDayAs: now) ? "Today, \(written)" : written
	}

	/// The status bar: "312 changes kept on this Mac since Oct 2, 2026", or
	/// the readable count alone when a part couldn't be read.
	func status(_ timeline: HistoryEngine.Timeline) -> String {
		if timeline.unreadableParts > 0 || timeline.damagedTail {
			return "\(timeline.readable.counted("change")) readable"
		}
		guard let oldest = timeline.oldest else { return "No changes kept yet" }
		let since = Self.date(oldest).formatted(style().month(.abbreviated).day().year())
		return "\(timeline.readable.counted("change")) kept on this Mac since \(since)"
	}

	/// Why every project keeps less history: "This Mac holds a lot of LPM
	/// data (4,120 records), so LPM keeps less local history for each project."
	func crowded(_ records: Int) -> String {
		"This Mac holds a lot of LPM data (\(records.formatted(.number.locale(locale))) records), so LPM keeps less local history for each project."
	}

	/// Project settings' line under the switch, or nil when there's nothing
	/// to say, as while history is off.
	struct StateLine: Equatable {
		let text: String
		var warns = false
		/// Reading again may help: offer Try Again.
		var retries = false
	}

	func stateLine(_ summary: VaultLocalHistory.Summary?, notRecorded: String?, readFailed: Bool) -> StateLine? {
		if readFailed {
			return StateLine(text: "Can’t be read right now: the Keychain is locked or unavailable.", warns: true, retries: true)
		}
		guard let summary, summary.state.history != "off" else { return nil }
		switch summary.state.history {
		case "unsupported", "removing":
			return StateLine(text: "Recorded by a newer version of LPM. Update LPM Vault to see it.", warns: true)
		case "both":
			return StateLine(text: "Paused — this project’s history is damaged.", warns: true)
		default:
			if !summary.state.damage.isEmpty { return StateLine(text: "Paused — this project’s history is damaged.", warns: true) }
		}
		switch notRecorded {
		case "limit": return StateLine(text: "Paused — this Mac holds too much LPM data to keep history for this project.", warns: true)
		case "tooManyValues": return StateLine(text: "Paused — this project has too many values to keep history.", warns: true)
		default: break
		}
		guard let timeline = summary.timeline else { return nil }
		if timeline.unreadableParts > 0 || timeline.damagedTail {
			return StateLine(
				text: "\(timeline.readable.counted("change")) readable. Part of this project’s history couldn’t be read.",
				warns: true, retries: true)
		}
		guard let oldest = timeline.oldest, timeline.readable > 0 else {
			return StateLine(text: "History starts with the next change made on this Mac.")
		}
		return StateLine(text: "\(timeline.readable.counted("change")) kept since \(dayAndMonth(Self.date(oldest)))")
	}

	// MARK: - Entries

	struct Badge: Equatable {
		let text: String
		let foreground: Color
		let background: Color
		var warns = false
	}

	/// The badge a row shows for where its change came from.
	static func badge(_ entry: HistoryEngine.Entry) -> Badge {
		switch entry.source {
		case "app": Badge(text: "LPM Vault", foreground: VaultPalette.accentText, background: VaultPalette.accentTint)
		case "cli": Badge(text: "LPM CLI", foreground: VaultPalette.textSecondary, background: VaultPalette.neutralTint)
		case "import": Badge(text: "Import", foreground: VaultPalette.greenTintText, background: VaultPalette.greenTint)
		case "restore": Badge(text: "Restore", foreground: VaultPalette.greenTintText, background: VaultPalette.greenTint)
		case "pull": Badge(text: "Pull", foreground: VaultPalette.accentText, background: VaultPalette.accentTint)
		case "rollback": Badge(text: "Rollback", foreground: VaultPalette.orangeTintText, background: VaultPalette.orangeTint)
		case "outside": Badge(text: "Outside", foreground: VaultPalette.orangeTintText, background: .clear, warns: true)
		default: Badge(text: "Other", foreground: VaultPalette.textSecondary, background: VaultPalette.neutralTint)
		}
	}

	/// Every key the entry changed, in its environments' order.
	static func keys(_ entry: HistoryEngine.Entry) -> [String] {
		var seen = Set<String>()
		return entry.environments.flatMap { $0.keys ?? [] }.map(\.key).filter { seen.insert($0).inserted }
	}

	/// How many keys the entry changed, counting an oversized change's too.
	static func keyCount(_ entry: HistoryEngine.Entry) -> Int {
		entry.environments.reduce(0) { $0 + ($1.keys?.count ?? $1.keyCount ?? 0) }
	}

	/// The entry's one line: "Set API_URL", "Imported .env.local · 12 keys".
	/// `related` finds the entry an undo or rollback refers to.
	func describe(_ entry: HistoryEngine.Entry, related: (String) -> HistoryEngine.Entry? = { _ in nil }) -> String {
		let keys = Self.keys(entry)
		let count = Self.keyCount(entry)
		let oneKey = keys.count == 1 ? keys[0] : nil
		let counted = count.counted("key")
		let environment = entry.environments.first?.name ?? ""
		switch entry.action {
		case "set": return oneKey.map { "Set \($0)" } ?? "Set \(counted)"
		case "delete": return oneKey.map { "Deleted \($0)" } ?? "Deleted \(counted)"
		case "editKey": return oneKey.map { "Changed \($0)" } ?? "Changed \(counted)"
		case "renameKey":
			if let renamed = entry.environments.lazy.compactMap({ $0.keys?.first { $0.renamedFrom != nil } }).first,
				let from = renamed.renamedFrom
			{
				return "Renamed \(from) to \(renamed.key)"
			}
			return "Renamed \(counted)"
		case "rawEdit": return "Edited \(environment) as raw text · \(counted) changed"
		case "createEnvironment":
			if let file = entry.fileName { return "Created \(environment) from \(file) · \(counted)" }
			if entry.pasted { return "Created \(environment) from pasted text · \(counted)" }
			return "Created \(environment)"
		case "renameEnvironment":
			if let renamed = entry.environments.first(where: { $0.renamedFrom != nil }), let from = renamed.renamedFrom {
				return "Renamed \(from) to \(renamed.name)"
			}
			return "Renamed \(environment)"
		case "duplicateEnvironment": return "Created \(environment) as a copy · \(counted)"
		case "clearEnvironment": return "Cleared \(environment) · \(counted)"
		case "deleteEnvironment": return "Deleted \(environment) · \(counted)"
		case "copyEnvironment": return "Copied into \(environment) · \(counted)"
		case "initFromFiles": return "Set up from files · \(counted)"
		case "import":
			if let file = entry.fileName { return "Imported \(file) · \(counted)" }
			return "Imported pasted text · \(counted)"
		case "restore": return "Restored from a backup · \(counted)"
		case "pull":
			return "Pulled from lpm.dev\(Self.remote(entry).map { " (\($0))" } ?? "") · \(counted) changed"
		case "projectImport":
			return "Added from lpm.dev\(Self.remote(entry).map { " (\($0))" } ?? "") · \(counted)"
		case "platformPull": return "Pulled from \(Self.platform(entry.platform)) · \(counted) changed"
		case "rollback":
			guard let point = entry.related else { return "Rolled back · \(counted)" }
			let at = moment(Self.date(point.time))
			return point.side == "before" ? "Rolled back to before \(at)" : "Rolled back to \(at)"
		case "undo":
			guard let point = entry.related else { return "Undid a change · \(counted)" }
			if let undone = related(point.id), undone.action == "import" {
				return "Undid the import of \(undone.fileName ?? "pasted text")"
			}
			if let undone = related(point.id), undone.action == "rawEdit" {
				return "Undid the raw text edit of \(undone.environments.first?.name ?? environment)"
			}
			return "Undid the change from \(moment(Self.date(point.time)))"
		case "outside":
			let until = Self.date(entry.time)
			guard let since = entry.since.map(Self.date) else { return "Changed outside local history · until \(clock(until))" }
			// Its row sits under the day it ended, so a start on another day names that day.
			let start = calendar.isDate(since, inSameDayAs: until) ? clock(since) : moment(since)
			return "Changed outside local history · \(start) to \(clock(until))"
		default:
			return "Changed \(counted)"
		}
	}

	/// "acme, v14", "v14" or nil.
	static func remote(_ entry: HistoryEngine.Entry) -> String? {
		var parts: [String] = []
		if case .org(let slug)? = entry.remote { parts.append(slug) }
		if let version = entry.remoteVersion { parts.append("v\(version)") }
		return parts.isEmpty ? nil : parts.joined(separator: ", ")
	}

	static func platform(_ name: String?) -> String {
		switch name {
		case "vercel": "Vercel"
		case "netlify": "Netlify"
		case "github": "GitHub"
		case "cloudflare": "Cloudflare"
		case "coolify": "Coolify"
		default: "a platform"
		}
	}

	/// Why a value isn't known, as a rollback row or a side says it.
	static func unknownReason(_ reason: String?) -> String {
		switch reason {
		case "notRecorded": "Its earlier value wasn’t recorded: it changed outside local history."
		case "tooLarge": "Too large to keep."
		case "removed": "Removed from history."
		case "unreadable": "Part of history couldn’t be read."
		default: "Its earlier value isn’t known."
		}
	}

	/// A side the inspector can't show, nil for one it can: an entry that
	/// kept no values was too large, any other side only a digest of was
	/// changed outside history.
	static func unknownSide(_ side: String, of entry: HistoryEngine.Entry) -> String? {
		switch side {
		case "digestOnly": entry.valuesKept ? "Not recorded: changed outside local history" : "Too large to keep"
		case "removed": "Removed from history"
		default: nil
		}
	}

	/// An unknown target, as its field says it.
	static func unknownTarget(_ reason: String?) -> String {
		switch reason {
		case "notRecorded": "not recorded"
		case "tooLarge": "too large"
		case "removed": "removed"
		case "unreadable": "unreadable"
		default: "unknown"
		}
	}

	/// Who made a change: "by the LPM CLI", "in LPM Vault", "outside local history".
	static func actor(_ actor: String) -> String {
		switch actor {
		case "cli": "by the LPM CLI"
		case "app": "in LPM Vault"
		default: "outside local history"
		}
	}

	/// The change an entry made, as a review names it: "the pull", "that change".
	static func change(_ entry: HistoryEngine.Entry?) -> String {
		switch entry?.action {
		case "pull", "platformPull", "projectImport": "the pull"
		case "import": "the import"
		case "restore": "the restore"
		case "rollback": "the rollback"
		case "undo": "the undo"
		default: "that change"
		}
	}

	// MARK: - Rollback reviews

	/// "Roll back production to Nov 3, 14:02?", "Roll back API_KEY in
	/// production to its value before Today, 13:40?", "Undo this change?".
	func rollbackTitle(_ target: HistoryEngine.RollbackTarget, at time: Int64) -> String {
		let at = moment(Self.date(time))
		switch target {
		case .environment(let environment, _, let side, _):
			return side == "before" ? "Roll back \(environment) to before \(at)?" : "Roll back \(environment) to \(at)?"
		case .key(let key, let environment, _):
			return "Roll back \(key) in \(environment) to its value before \(at)?"
		case .undo:
			return "Undo this change?"
		}
	}

	/// What the rollback does, under its title. `entry` is the entry it
	/// points at, when it's on the page.
	func rollbackDetail(_ review: VaultLocalHistory.RollbackReview, entry: HistoryEngine.Entry?) -> String {
		let plan = review.plan
		switch review.target {
		case .environment(let name, _, let side, _):
			let environment = plan.environments.first
			if environment?.offersDeletion == true { return "\(name) goes back to its state at that point." }
			let change = if let entry, entry.environments.count > 1 { "“\(describe(entry))”" } else { "that change" }
			let state = "\(name) goes back to its state \(side == "before" ? "before" : "after") \(change)."
			let total = environment?.rows.count ?? 0
			guard total > 1, environment?.recreates != true else { return state }
			return "\(state) \(review.changing) of \(total) keys change; switch any off to keep its current value."
		case .key:
			if plan.environments.allSatisfy({ $0.rows.allSatisfy { $0.change == "unknown" } }) {
				return "Its value from before \(Self.change(entry)) isn’t known, so it keeps its value now."
			}
			return "Only this key changes. The value from before \(Self.change(entry)) is restored."
		case .undo:
			let what = entry.map { "\(describe($0)) · " } ?? ""
			let scope = switch plan.environments.count {
			case 0, 1: "Each key it changed goes back to its value before it."
			case 2: "Keys in both environments go back to their values before it."
			default: "Keys in all \(plan.environments.count) environments go back to their values before it."
			}
			return "\(what)\(moment(Self.date(plan.point.time))). \(scope)"
		}
	}

	/// What happens to an environment besides its keys, or nil. An undo's
	/// point is just before its change.
	func environmentNote(_ environment: HistoryEngine.PlanEnvironment, deletedAt: Int64?, undoes: Bool = false) -> String? {
		if environment.recreates, let name = environment.target {
			let keys = environment.rows.count.counted("key")
			let recreates = "\(undoes ? "Undoing" : "Rolling back") recreates it with \(keys)."
			guard let deletedAt else { return "\(name) doesn’t exist now. \(recreates)" }
			return "\(name) was deleted on \(dayAndMonth(Self.date(deletedAt))). \(recreates)"
		}
		if environment.offersDeletion, let name = environment.current {
			let existed = "\(name) didn’t exist \(undoes ? "before that change" : "at that point")."
			let count = environment.rows.count
			guard count > 0 else { return existed }
			return "\(existed) Its \(count.counted("key")) \(count == 1 ? "is" : "are") removed."
		}
		if environment.renames, let current = environment.current, let target = environment.target {
			return "\(current) goes back to its earlier name, \(target)."
		}
		return nil
	}

	/// Why some keys an environment had at the point aren't in the review.
	static func unnamedKeys(_ reason: String, environment: String) -> String {
		reason == "tooLarge"
			? "History can’t name every key \(environment) had then, because a change was too large to keep. Those keys stay as they are."
			: "History can’t name every key \(environment) had then. Those keys stay as they are."
	}

	/// The review's footer: an undo, like a rollback, is a change of its own.
	static func rollbackFootnote(undoes: Bool) -> String {
		undoes
			? "The undo is saved as a new change in this project’s history, so you can undo it too. Nothing is pushed."
			: "The rollback is saved as a new change in this project’s history, so you can roll it back too. Nothing is pushed."
	}

	/// "This also replaces a change made outside local history between Nov 3, 09:10 and 13:40."
	func gap(_ gap: HistoryEngine.Gap) -> String {
		let replaces = "This also replaces a change made outside local history"
		switch (gap.since.map(Self.date), gap.until.map(Self.date)) {
		case (let since?, let until?):
			let end = calendar.isDate(since, inSameDayAs: until) ? clock(until) : moment(until)
			return "\(replaces) between \(moment(since)) and \(end)."
		case (let since?, nil):
			return "\(replaces) \(self.since(since))."
		case (nil, let until?):
			return "\(replaces) before \(moment(until))."
		case (nil, nil):
			return "\(replaces)."
		}
	}

	/// Where a key's current value came from, when a pull set it. The
	/// wording follows the pull's own remote, not the project's sync now.
	func pulled(_ pulled: HistoryEngine.Pulled, key: String, undoes: Bool = false) -> String {
		let version = pulled.version.map { ", v\($0)" } ?? ""
		let came = "\(key)’s current value came from lpm.dev (pulled \(dayAndMonth(Self.date(pulled.time)))\(version))."
		let change = undoes ? "undo" : "rollback"
		let push = switch pulled.remote {
		case .org: "If you push this \(change), it replaces that value for everyone on the team,"
		case .personal: "If you push this \(change), it replaces that value on lpm.dev and on your other Macs when they pull,"
		}
		return "\(came) \(push) and the value it replaces then stays only in this Mac’s history. Until you push, pulling again brings lpm.dev’s value back."
	}

	/// "Changed again on Nov 5 by the LPM CLI. Undoing this replaces that change too."
	func changedAgain(_ again: HistoryEngine.ChangedAgain) -> String {
		"Changed again on \(dayAndMonth(Self.date(again.time))) \(Self.actor(again.actor)). Undoing this replaces that change too."
	}

	// MARK: - Removal reviews

	/// The chosen value's card: "Set Nov 3, 2026 at 14:02 by the LPM CLI",
	/// or "Replaced …" for the value a change replaced.
	func removalSubject(_ entry: HistoryEngine.Entry, side: String) -> String {
		let at = Self.date(entry.time).formatted(style(date: .abbreviated, time: .shortened))
		return "\(side == "before" ? "Replaced" : "Set") \(at) \(Self.actor(entry.actor))"
	}

	/// A place's occurrences, newest first: "set Nov 3, replaced Nov 9; set Sep 30".
	func occurrences(_ occurrences: [HistoryEngine.Occurrence]) -> String {
		occurrences
			.sorted { ($0.set ?? $0.replaced ?? .min) > ($1.set ?? $1.replaced ?? .min) }
			.map { occurrence in
				var parts: [String] = []
				if let set = occurrence.set { parts.append("set \(dayAndMonth(Self.date(set)))") }
				if let replaced = occurrence.replaced { parts.append("replaced \(dayAndMonth(Self.date(replaced)))") }
				return parts.joined(separator: ", ")
			}
			.filter { !$0.isEmpty }
			.joined(separator: "; ")
	}
}
