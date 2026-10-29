import SwiftUI

/// What value search says, on screen and to VoiceOver. Nothing here ever
/// holds a value: results say where, not what.
enum ValueSearchWording {
	static let findIntro = "Type or paste a value to see every place LPM Vault stores it. The value isn’t shown, saved or remembered."
	static let reuseIntro = "Values stored under more than one key. Values are never shown."
	static let findCoverage = "Searches stored values only — not personal overrides, .env files or platforms."
	static let reuseCoverage = "Compares stored values only — not personal overrides, .env files or platforms."
	static let containsOption = "Also find values that contain it"
	static let containsMinimum = "· \(ValueMatcher.minimumContainedCharacters) characters or more"

	/// "in Personal vault", or "on this Mac" for every account.
	static func scope(_ accountName: String?) -> String {
		accountName.map { "in \($0)" } ?? "on this Mac"
	}

	/// A choice of the scope menu, which follows "Search in": "Personal vault" or "Every account".
	static func scopeOption(_ scope: ValueSearchModel.Scope, accountName: String) -> String {
		switch scope {
		case .account: accountName
		case .everyAccount: "Every account"
		}
	}

	// MARK: Finding a value

	static func findSubtitle(_ find: ValueSearchModel.Find?, termKept: Bool) -> String {
		guard let find, find.phase != .running else { return findIntro }
		if !termKept {
			let found = find.hits.isEmpty ? "No matches in \(find.searched.counted("project"))" : "\(placesIn(find))"
			return "\(found) · from your last search. The value wasn’t kept."
		}
		if find.phase == .stopped { return "Stopped after \(find.reached) of \(find.total.counted("project"))." }
		let unread = find.skips.isEmpty ? "" : " \(couldNot(find.skips.count, "searched"))"
		if find.hits.isEmpty {
			return find.skips.isEmpty
				? "Searched \(find.searched.counted("project")) \(scope(find.accountName))."
				: "Searched \(find.searched.counted("project")).\(unread)"
		}
		return find.skips.isEmpty ? "\(placesIn(find)) \(whereFound(find))." : "\(placesIn(find)).\(unread)"
	}

	/// "7 places in 5 projects".
	static func placesIn(_ find: ValueSearchModel.Find) -> String {
		"\(find.hits.count.counted("place")) in \(find.projectCount.counted("project"))"
	}

	/// "in Personal vault", "in Acme" or "across 2 accounts".
	static func whereFound(_ find: ValueSearchModel.Find) -> String {
		if let accountName = find.accountName { return "in \(accountName)" }
		if find.accountCount == 1, let account = find.hits.first?.place.account { return "in \(account.name)" }
		return "across \(find.accountCount) accounts"
	}

	/// "3 projects couldn’t be searched." or "1 project couldn’t be compared."
	static func couldNot(_ count: Int, _ verb: String) -> String {
		"\(count.counted("project")) couldn’t be \(verb)."
	}

	static func idleFind(projects: Int, accountName: String?) -> String {
		"Press Return to search \(projects.counted("project")) \(scope(accountName)). Nothing is searched as you type."
	}

	static func searching(_ find: ValueSearchModel.Find) -> String {
		"Searching \(min(find.reached + 1, find.total)) of \(find.total.counted("project"))…"
	}

	static func resultsHeading(_ find: ValueSearchModel.Find) -> String {
		switch find.phase {
		case .running: "Found so far · \(find.hits.count)"
		case .stopped: "Found in \(find.reached) of \(find.total.counted("project")) · \(find.hits.count)"
		case .finished: find.hits.count.counted("place")
		}
	}

	/// "5 exact · 2 contain it", when the search found values that contain the term.
	static func matchCounts(_ find: ValueSearchModel.Find) -> String? {
		guard find.findsContainingValues else { return nil }
		return "\(find.hits.count - find.containingCount) exact · \(find.containingCount) contain it"
	}

	/// What a search that found nothing says. With projects it couldn't
	/// read, it speaks only for the ones it read.
	static func noMatches(_ find: ValueSearchModel.Find, canWidenToEveryAccount: Bool, canWidenToContaining: Bool) -> String {
		var tries: [String] = []
		if find.scope == .account, canWidenToEveryAccount { tries.append("searching every account on this Mac") }
		if canWidenToContaining, !find.findsContainingValues { tries.append("turning on “\(containsOption)”") }
		let stored = if find.skips.isEmpty {
			"This value isn’t stored \(scope(find.accountName))."
		} else if find.searched == 1 {
			"The project searched doesn’t store this value."
		} else {
			"None of the \(find.searched) projects searched store this value."
		}
		return tries.isEmpty ? stored : "\(stored) Try \(tries.joined(separator: ", or "))."
	}

	static func stopped(unread: Int) -> String {
		"Search stopped. \(unread.counted("project")) \(unread == 1 ? "wasn’t" : "weren’t") read."
	}

	static func findFooter(_ find: ValueSearchModel.Find?, termKept: Bool) -> String {
		guard let find else { return "The search field stays masked and keeps no history." }
		switch find.phase {
		case .running:
			return "Projects are read one at a time, and their values aren’t kept."
		case .stopped:
			return termKept ? "Partial results. Continue to read the remaining projects." : "Partial results from your last search."
		case .finished:
			if !find.skips.isEmpty { return "Fix a project and search again to include it." }
			if find.hits.isEmpty { return "All \(find.searched.counted("project")) were read." }
			return termKept
				? "Click a place to open it. Results stay until you lock, switch account or search again; the value doesn’t."
				: "Results clear when you lock, switch account or search again."
		}
	}

	// MARK: Reused values

	static func reuseSubtitle(_ reuse: ValueSearchModel.Reuse?) -> String {
		guard let reuse else { return reuseIntro }
		switch reuse.phase {
		case .running: return reuseIntro
		case .stopped: return "Scan stopped after \(reuse.reached) of \(reuse.total.counted("project"))."
		case .finished:
			let unread = reuse.skips.isEmpty ? "" : " \(couldNot(reuse.skips.count, "compared"))"
			if reuse.reported.isEmpty { return "Compared \(reuse.compared.counted("project")) \(scope(reuse.accountName)).\(unread)" }
			return "\(reuse.reported.count.counted("group")) in \(reuse.compared.counted("project")).\(reuse.skips.isEmpty ? " Riskiest first." : unread)"
		}
	}

	/// What a scan that found nothing reused says. With projects it couldn't
	/// read, it speaks only for the ones it compared.
	static func nothingReused(_ reuse: ValueSearchModel.Reuse) -> String {
		reuse.skips.isEmpty
			? "Every secret-looking value is stored under one key only."
			: "In the \(reuse.compared.counted("project")) compared, every secret-looking value is stored under one key only."
	}

	static func idleReuse(projects: Int, accountName: String?) -> String {
		"Press Return to compare the values in \(projects.counted("project")) \(scope(accountName))."
	}

	static func comparing(_ reuse: ValueSearchModel.Reuse) -> String {
		"Comparing \(min(reuse.reached + 1, reuse.total)) of \(reuse.total.counted("project"))…"
	}

	static func leftOut(_ count: Int) -> String {
		"\(count.counted("group")) left out as configuration — ports, hosts, true/false and keys marked public."
	}

	static func reuseFooter(_ reuse: ValueSearchModel.Reuse?) -> String {
		guard let reuse else { return "Values are compared one project at a time and never kept." }
		switch reuse.phase {
		case .running: return "Values are compared one project at a time and never kept."
		case .stopped: return "Nothing from a stopped scan is kept. Scan again to compare every project."
		case .finished:
			if !reuse.skips.isEmpty { return "Fix a project and scan again to include it." }
			if reuse.reported.isEmpty { return "All \(reuse.compared.counted("project")) were compared." }
			return "Click a key to open it. Groups stay until you lock, switch account or scan again."
		}
	}

	static func sectionTitle(_ span: ReusedValueGroup.Span) -> String {
		switch span {
		case .projects: "Across projects"
		case .environments: "Across environments"
		case .environment: "Within one environment"
		}
	}

	static func sectionDetail(_ span: ReusedValueGroup.Span) -> String {
		switch span {
		case .projects: "one secret, several projects"
		case .environments: "one secret, several environments"
		case .environment: "one secret, several keys"
		}
	}

	static func badge(_ span: ReusedValueGroup.Span) -> String {
		switch span {
		case .projects: "ACROSS PROJECTS"
		case .environments: "ACROSS ENVIRONMENTS"
		case .environment: "ONE ENVIRONMENT"
		}
	}

	static func groupTitle(_ group: ReusedValueGroup) -> String {
		"Shared by \(group.places.count) keys"
	}

	/// "2 projects · .env.production in both", "demo-api · .env.production and .env" or "demo-api · .env.staging".
	static func groupSummary(_ group: ReusedValueGroup) -> String {
		let environments = orderedUnique(group.places.map { VaultProject.displayName(for: $0.location.environment) })
		switch group.span {
		case .projects:
			let projects = Set(group.places.map(\.location.projectID)).count
			guard environments.count == 1, let environment = environments.first else { return projects.counted("project") }
			return "\(projects.counted("project")) · \(environment) in \(projects == 2 ? "both" : "each")"
		case .environments:
			return "\(group.places[0].projectName) · \(ListFormatter.localizedString(byJoining: environments))"
		case .environment:
			return "\(group.places[0].projectName) · \(environments.first ?? "")"
		}
	}

	static func groupSpoken(_ group: ReusedValueGroup) -> String {
		let summary = groupSummary(group)
		return switch group.span {
		case .projects: "\(groupTitle(group)) across \(summary.replacingOccurrences(of: " · ", with: ", ")). Across projects."
		case .environments: "\(groupTitle(group)) in \(summary.replacingOccurrences(of: " · ", with: ", ")). Across environments."
		case .environment: "\(groupTitle(group)) in \(summary.replacingOccurrences(of: " · ", with: ", ")). One environment."
		}
	}

	// MARK: Places and projects

	/// A place in words: "demo-api, .env.production, DATABASE_URL", then how
	/// it matched and its account when the results span accounts.
	static func spokenPlace(_ place: ValueSearchPlace, match: ValueSearchHit.Match?, showsAccount: Bool) -> String {
		var parts = [place.projectName, VaultProject.displayName(for: place.location.environment), place.location.key]
		switch match {
		case .exact?: parts.append("exact match")
		case .contains?: parts.append("contains the value")
		case nil: break
		}
		if showsAccount { parts.append("in \(place.account.name)") }
		return parts.joined(separator: ", ")
	}

	/// What VoiceOver hears once a result opens: "Opened PAYMENTS in Bravo, .env".
	static func opened(_ location: ValueLocation, projectName: String) -> String {
		"Opened \(location.key) in \(projectName), \(VaultProject.displayName(for: location.environment))"
	}

	/// What VoiceOver hears once a project a search couldn't read opens.
	static func opened(project name: String) -> String {
		"Opened \(name)"
	}

	static func reason(_ reason: ValueSearchSkip.Reason) -> String {
		switch reason {
		case .newerVersion: "Made with a newer LPM version. Update LPM Vault to read it."
		case .damaged: "Its newer data is damaged."
		case .unfinished: "An interrupted change to its newer data wasn’t finished."
		case .unchecked: "Its newer data couldn’t be checked."
		case .unreadable: "The Keychain couldn’t read it."
		}
	}

	static func unreadTitle(_ count: Int) -> String {
		count.counted("project")
	}

	static let unreadDetail = "The search stopped before they were read."

	// MARK: The workspace

	/// What the strip above a project's table says about the last search.
	static func strip(find: ValueSearchModel.Find?, reuse: ValueSearchModel.Reuse?) -> String? {
		if let find, find.phase != .running {
			if find.hits.isEmpty { return "Value search · no matches in \(find.searched.counted("project"))" }
			let places = "Value search · \(find.hits.count.counted("place")) in \(find.projectCount.counted("project"))"
			return find.phase == .stopped ? "\(places), stopped after \(find.reached) of \(find.total)" : places
		}
		if let reuse, reuse.phase == .finished {
			return "Reused values · \(reuse.reported.count.counted("group")) in \(reuse.compared.counted("project"))"
		}
		return nil
	}

	/// The inspector's note on a secret-looking value that another
	/// environment holds too: "Same value as .env.production."
	static func sameValue(as environments: [String]) -> String {
		let names = environments.map(VaultProject.displayName(for:))
		if names.count <= 2 { return "Same value as \(ListFormatter.localizedString(byJoining: names))." }
		return "Same value in \(names.count) other environments: \(names.joined(separator: ", "))."
	}

	private static func orderedUnique(_ values: [String]) -> [String] {
		var seen: Set<String> = []
		return values.filter { seen.insert($0).inserted }
	}
}

/// One place a value is stored: project › environment › key. Clicking it
/// opens the key; the value is never shown.
struct ValueSearchPlaceRow: View {
	@Bindable var store: VaultStore
	let place: ValueSearchPlace
	var match: ValueSearchHit.Match?
	var showsAccount = false
	var group: Int?

	@State private var hovering = false

	var body: some View {
		let canOpen = store.valueSearch.canOpen(place)
		Button { store.valueSearch.open(place, group: group) } label: {
			HStack(spacing: 7) {
				VaultProjectIconView(appearance: store.projectIcons.appearance(for: place.location.projectID), size: 16)
				VStack(alignment: .leading, spacing: 1) {
					HStack(spacing: 7) {
						// The project and key share what an environment's name, at most 140 points, leaves.
						Text(place.projectName)
							.font(.system(size: 13))
							.foregroundStyle(VaultPalette.textPrimary)
							.lineLimit(1)
							.truncationMode(.middle)
							.layoutPriority(1)
						separator
						VaultEnvSwatch(color: VaultPalette.environment(place.environmentIndex))
						Text(VaultProject.displayName(for: place.location.environment))
							.font(VaultTypography.tabular(13))
							.foregroundStyle(VaultPalette.textSecondary)
							.lineLimit(1)
							.truncationMode(.middle)
							.frame(maxWidth: 140, alignment: .leading)
							.fixedSize()
							.layoutPriority(2)
						separator
						Text(place.location.key)
							.font(VaultTypography.tabular(13, .semibold))
							.foregroundStyle(VaultPalette.textPrimary)
							.lineLimit(1)
							.truncationMode(.middle)
							.layoutPriority(1)
					}
					if showsAccount {
						Text(place.account.name)
							.font(.system(size: 11.5))
							.foregroundStyle(VaultPalette.textTertiary)
							.lineLimit(1)
					}
				}
				Spacer(minLength: 6)
				if match == .contains {
					VaultTagBadge(text: "CONTAINS", foreground: VaultPalette.accentText, background: VaultPalette.accentTint, size: 9.5)
				}
				Image(systemName: "chevron.right")
					.font(.system(size: 9, weight: .semibold))
					.foregroundStyle(VaultPalette.textTertiary)
					.hidden(!canOpen)
			}
			.padding(.horizontal, 12)
			.frame(height: showsAccount ? 44 : 36)
			.frame(maxWidth: .infinity, alignment: .leading)
			.background(hovering && canOpen ? VaultPalette.rowHover : .clear)
			.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.disabled(!canOpen)
		.onHover { hovering = $0 }
		.help(canOpen ? "Open \(place.location.key) in \(place.projectName)" : "This project is no longer on this Mac")
		// The button's own element keeps its press, which VoiceOver opens the place with.
		.accessibilityLabel(ValueSearchWording.spokenPlace(place, match: match, showsAccount: showsAccount))
		.accessibilityHint(canOpen ? "Opens the key" : "")
	}

	private var separator: some View {
		Text("›")
			.font(.system(size: 12))
			.foregroundStyle(VaultPalette.textTertiary)
			.fixedSize()
			.accessibilityHidden(true)
	}
}

/// A card of rows separated by hairlines, as the sheet's lists are drawn.
struct ValueSearchCard<Content: View>: View {
	@ViewBuilder let content: Content

	var body: some View {
		VStack(spacing: 0) { content }
			.background(RoundedRectangle(cornerRadius: 10).fill(VaultPalette.content))
			.clipShape(RoundedRectangle(cornerRadius: 10))
			.overlay { RoundedRectangle(cornerRadius: 10).stroke(VaultPalette.border, lineWidth: 1) }
	}
}

/// A section's small capitals heading, with a note at its end.
struct ValueSearchSectionHeading: View {
	let title: String
	var detail: String?

	var body: some View {
		HStack(spacing: 8) {
			Text(title.uppercased())
				.vaultSectionLabel()
				.accessibilityAddTraits(.isHeader)
			Spacer(minLength: 8)
			if let detail {
				Text(detail)
					.font(.system(size: 11.5))
					.foregroundStyle(VaultPalette.textTertiary)
			}
		}
	}
}

/// Values stored in more than one place: who shares them, never what.
struct ReusedValueGroupCard: View {
	@Bindable var store: VaultStore
	let group: ReusedValueGroup
	let showsAccount: Bool

	var body: some View {
		ValueSearchCard {
			HStack(spacing: 8) {
				VStack(alignment: .leading, spacing: 1) {
					Text(ValueSearchWording.groupTitle(group))
						.font(.system(size: 13, weight: .semibold))
						.foregroundStyle(VaultPalette.textPrimary)
					Text(ValueSearchWording.groupSummary(group))
						.font(.system(size: 11.5))
						.foregroundStyle(VaultPalette.textTertiary)
						.lineLimit(1)
						.truncationMode(.middle)
				}
				Spacer(minLength: 8)
				VaultTagBadge(
					text: ValueSearchWording.badge(group.span),
					foreground: group.span == .environment ? VaultPalette.textSecondary : VaultPalette.orangeTintText,
					background: group.span == .environment ? VaultPalette.neutralTint : VaultPalette.orangeTint,
					size: 9.5)
			}
			.padding(.horizontal, 12)
			.padding(.vertical, 8)
			.frame(maxWidth: .infinity, alignment: .leading)
			.background(VaultPalette.headerRow)
			.accessibilityElement(children: .ignore)
			.accessibilityLabel(ValueSearchWording.groupSpoken(group))
			.accessibilityAddTraits(.isHeader)
			VaultHairline(color: VaultPalette.border)
			// A group can hold thousands of places; only those on screen are made.
			LazyVStack(spacing: 0) {
				ForEach(group.places) { place in
					if place.id != group.places.first?.id { VaultHairline(color: VaultPalette.rowDivider) }
					ValueSearchPlaceRow(store: store, place: place, showsAccount: showsAccount, group: group.id)
				}
			}
		}
		.accessibilityElement(children: .contain)
	}
}

/// A project a search couldn't read: why, and what fixes it.
struct ValueSearchSkipRow: View {
	@Bindable var store: VaultStore
	let skip: ValueSearchSkip
	/// What VoiceOver says of it: "not searched", or "not compared" in a scan for reused values.
	var unreadAs = "not searched"
	/// Whether a project that couldn't be read can be read again now.
	var canRetry: Bool
	let onCheckForUpdates: () -> Void

	var body: some View {
		HStack(spacing: 10) {
			VaultProjectIconView(appearance: store.projectIcons.appearance(for: skip.projectID), size: 16)
			VStack(alignment: .leading, spacing: 1) {
				Text(skip.projectName)
					.font(.system(size: 13))
					.foregroundStyle(VaultPalette.textPrimary)
					.lineLimit(1)
				Text(ValueSearchWording.reason(skip.reason))
					.font(.system(size: 11.5))
					.foregroundStyle(VaultPalette.textTertiary)
					.fixedSize(horizontal: false, vertical: true)
			}
			.accessibilityElement(children: .ignore)
			.accessibilityLabel("\(skip.projectName), \(unreadAs): \(ValueSearchWording.reason(skip.reason))")
			Spacer(minLength: 8)
			action
		}
		.padding(.horizontal, 12)
		.padding(.vertical, 6)
		.frame(minHeight: 44)
		.accessibilityElement(children: .contain)
	}

	@ViewBuilder
	private var action: some View {
		switch skip.reason {
		case .newerVersion:
			link("Check for Updates…", action: onCheckForUpdates)
		case .damaged:
			link("Open to Repair") { openProject() }
		case .unfinished:
			link("Open") { openProject() }
		case .unchecked, .unreadable:
			if canRetry { link("Try Again") { store.valueSearch.retry(skip) } }
		}
	}

	private func openProject() {
		store.valueSearch.openProject(of: skip)
	}

	private func link(_ title: String, action: @escaping () -> Void) -> some View {
		Button(title, action: action)
			.buttonStyle(.plain)
			.font(.system(size: 12, weight: .semibold))
			.foregroundStyle(VaultPalette.accentForeground)
			.vaultPointingHand()
			.accessibilityLabel("\(title), \(skip.projectName)")
	}
}

/// The last value search, above a project's table, once its sheet closes:
/// what it found, a way back to it, and a way to clear it.
struct ValueSearchStrip: View {
	let summary: String
	let onShow: () -> Void
	let onClear: () -> Void

	var body: some View {
		HStack(spacing: 10) {
			Image(systemName: "binoculars")
				.font(.system(size: 11, weight: .semibold))
				.foregroundStyle(VaultPalette.accentForeground)
				.accessibilityHidden(true)
			Text(summary)
				.font(.system(size: 12.5))
				.foregroundStyle(VaultPalette.textPrimary)
				.lineLimit(1)
				.truncationMode(.tail)
			Text("· value not kept")
				.font(.system(size: 11.5))
				.foregroundStyle(VaultPalette.textTertiary)
				.lineLimit(1)
				.fixedSize()
			Spacer(minLength: 8)
			button("Show Results", action: onShow)
			button("Clear", label: "Clear value search results", action: onClear)
		}
		.padding(.horizontal, 20)
		.frame(height: 36)
		.frame(maxWidth: .infinity, alignment: .leading)
		.background(VaultPalette.accentTint)
		.overlay(alignment: .bottom) { VaultHairline(color: VaultPalette.border) }
		.accessibilityElement(children: .contain)
		.accessibilityLabel("Value search results")
	}

	private func button(_ title: String, label: String? = nil, action: @escaping () -> Void) -> some View {
		Button(title, action: action)
			.buttonStyle(.plain)
			.font(.system(size: 12.5, weight: .semibold))
			.foregroundStyle(VaultPalette.accentForeground)
			.fixedSize()
			.vaultPointingHand()
			.accessibilityLabel(label ?? title)
	}
}

/// Marks a key a value search found. The row's label says so to VoiceOver.
struct ValueSearchFoundBadge: View {
	var body: some View {
		VaultTagBadge(text: "FOUND", foreground: VaultPalette.accentText, background: VaultPalette.accentTint, size: 9)
			.help("Found by value search")
			.accessibilityHidden(true)
	}
}

/// Marks a value a value search found. The row's label says so to VoiceOver.
struct ValueSearchFoundMark: View {
	var body: some View {
		Image(systemName: "binoculars.fill")
			.font(.system(size: 9.5))
			.foregroundStyle(VaultPalette.accentForeground)
			.help("Found by value search")
			.accessibilityHidden(true)
	}
}
