import Foundation
import Observation

/// Searches the values stored on this Mac by value: where one value is
/// stored, and which values are stored in more than one place. It holds the
/// term only while the sheet is open and holds no value at all; results say
/// where, never what. Locking, switching accounts or a new search clears it.
@Observable
@MainActor
final class ValueSearchModel {
	enum Mode: Hashable, Sendable {
		/// Where one value is stored.
		case find
		/// The values stored in more than one place.
		case reuse
	}

	enum Scope: Hashable, Sendable {
		/// The selected account's projects.
		case account
		case everyAccount
	}

	enum Phase: Hashable, Sendable {
		case running
		case finished
		case stopped
	}

	/// The last search for one value.
	struct Find: Sendable {
		let scope: Scope
		/// The account searched; nil when every account was.
		let accountName: String?
		let findsContainingValues: Bool
		/// The projects to read, in order, by ID.
		let order: [String]
		/// How many of `order` the search has reached.
		var reached = 0
		/// How many projects' values were compared.
		var searched = 0
		/// Where the value is, in the order the search reads projects.
		private(set) var hits: [ValueSearchHit] = []
		/// The projects that couldn't be read, in the order the search reads them.
		private(set) var skips: [ValueSearchSkip] = []
		var phase: Phase = .running
		/// How many hits hold the value inside a longer one.
		private(set) var containingCount = 0
		private var projectsFound: Set<String> = []
		private var accountsFound: Set<ValueSearchAccount> = []
		private let positions: [String: Int]

		init(
			scope: Scope, accountName: String?, findsContainingValues: Bool, order: [String], reached: Int = 0, searched: Int = 0,
			hits: [ValueSearchHit] = [], skips: [ValueSearchSkip] = [], phase: Phase = .running
		) {
			self.scope = scope
			self.accountName = accountName
			self.findsContainingValues = findsContainingValues
			self.order = order
			self.reached = reached
			self.searched = searched
			self.phase = phase
			positions = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
			for (projectID, found) in Dictionary(grouping: hits, by: \.place.location.projectID) { add(found, from: projectID) }
			for skip in skips { add(skip) }
		}

		var total: Int { order.count }
		/// The projects the search stopped before reading.
		var unread: ArraySlice<String> { phase == .stopped ? order[reached...] : [] }
		var projectCount: Int { projectsFound.count }
		var accountCount: Int { accountsFound.count }

		/// Records one project's hits where the project falls in the search's
		/// order: after the others, unless it's one read again.
		mutating func add(_ found: [ValueSearchHit], from projectID: String) {
			guard !found.isEmpty else { return }
			let position = position(of: projectID)
			hits.insert(contentsOf: found, at: insertionIndex(in: hits, forProjectAt: position) { $0.place.location.projectID })
			projectsFound.insert(projectID)
			for hit in found {
				accountsFound.insert(hit.place.account)
				if hit.match == .contains { containingCount += 1 }
			}
		}

		mutating func add(_ skip: ValueSearchSkip) {
			skips.insert(skip, at: insertionIndex(in: skips, forProjectAt: position(of: skip.projectID)) { $0.projectID })
		}

		mutating func removeSkip(of projectID: String) {
			skips.removeAll { $0.projectID == projectID }
		}

		/// Records that the project at `id` was reached, which reaches every one before it.
		mutating func reach(_ id: String) {
			if let position = positions[id], position >= reached { reached = position + 1 }
		}

		private func position(of projectID: String) -> Int {
			positions[projectID] ?? .max
		}

		/// Where an entry of the project at `position` goes in `list`, which is
		/// in the search's order: its end, but for a project read again.
		private func insertionIndex<Entry>(in list: [Entry], forProjectAt position: Int, project: (Entry) -> String) -> Int {
			guard let last = list.last, self.position(of: project(last)) > position else { return list.endIndex }
			var low = 0, high = list.count
			while low < high {
				let middle = (low + high) / 2
				if self.position(of: project(list[middle])) <= position { low = middle + 1 } else { high = middle }
			}
			return low
		}
	}

	/// The last scan for values stored in more than one place.
	struct Reuse: Sendable {
		let scope: Scope
		let accountName: String?
		let total: Int
		var reached = 0
		var groups: [ReusedValueGroup] = []
		var skips: [ValueSearchSkip] = []
		/// How many projects' values were read and compared.
		var compared = 0
		var phase: Phase = .running

		/// The groups of values that look secret, which the report lists.
		var reported: [ReusedValueGroup] { groups.filter { !$0.isConfiguration } }
		/// The groups left out as configuration, which the report can show.
		var configuration: [ReusedValueGroup] { groups.filter(\.isConfiguration) }
	}

	/// A place in another account the person chose while changes are
	/// unsaved: opening it switches accounts, which discards them.
	struct PendingOpen: Identifiable, Equatable, Sendable {
		enum Target: Equatable, Sendable {
			case place(ValueSearchPlace, group: Int?)
			case project(ValueSearchSkip)
		}

		let id = UUID()
		let target: Target
		/// The account opening it switches to.
		let accountName: String

		/// What's opened, by name: a key, or a project a search couldn't read.
		var name: String {
			switch target {
			case .place(let place, _): place.location.key
			case .project(let skip): skip.projectName
			}
		}

		var projectID: String {
			switch target {
			case .place(let place, _): place.location.projectID
			case .project(let skip): skip.projectID
			}
		}
	}

	/// A result the person opened, for the workspace to show.
	struct OpenRequest: Equatable, Sendable {
		let id = UUID()
		let projectID: String
		/// The place opened; nil for a project a search couldn't read, which
		/// opens on its own page.
		let location: ValueLocation?
		/// Opening it selected another project, whose reset comes first.
		let changedProject: Bool
	}

	@ObservationIgnored weak var store: VaultStore?

	var isPresented = false
	var mode: Mode = .find
	var scope: Scope = .account
	var findsContainingValues = false
	/// What the sheet's field holds, which only it and a running search see.
	var term = ExactText("")
	/// Whether the report lists the groups left out as configuration.
	var showsConfiguration = false

	private(set) var find: Find?
	private(set) var reuse: Reuse?
	private(set) var openRequest: OpenRequest?
	/// A place waiting for the person to agree to discard unsaved changes.
	private(set) var pendingOpen: PendingOpen?
	/// The group whose place was opened last, which the workspace marks.
	private(set) var openedGroup: Int?

	/// The search running now, which tests wait for.
	@ObservationIgnored private(set) var task: Task<Void, Never>?
	private var generation = 0
	/// The last search's term while the sheet stays open, for Continue and Try Again.
	private var matcher: ValueMatcher?
	/// The running scan for reused values' key.
	@ObservationIgnored private var reuseDigester: ValueDigester?
	/// The project being read again, and the phase its search returns to.
	private var retrying: (skip: ValueSearchSkip, phase: Phase)?
	private var isOpening = false

	var isRunning: Bool { find?.phase == .running || reuse?.phase == .running }
	/// Whether the last search's term is still held: the sheet hasn't closed since it ran.
	var keepsTerm: Bool { matcher != nil }
	/// Whether the field still holds the last search's term, byte for byte,
	/// so reading on searches for what it shows.
	var fieldHoldsLastTerm: Bool { matcher?.match(term.text) == .exact }
	/// Whether the stopped search can read on: its term is still in the field.
	var canContinue: Bool { find?.phase == .stopped && fieldHoldsLastTerm && !(find?.unread.isEmpty ?? true) }
	/// Whether a project the last search couldn't read can be read again with the term in the field.
	var canRetry: Bool { fieldHoldsLastTerm && find?.phase != .running }

	// MARK: - Presenting

	func present(_ mode: Mode) {
		guard store?.isUnlocked == true else { return }
		if !isRunning { self.mode = mode }
		isPresented = true
	}

	/// Opens the sheet to find `text`, typed where names are searched, and
	/// searches at once.
	func present(searchingFor text: String) {
		guard store?.isUnlocked == true, !text.isEmpty else { return }
		mode = .find
		term = ExactText(text)
		isPresented = true
		startFind()
	}

	/// Finds where the selected project's stored value of `key` in
	/// `environment` is used, without the person typing or pasting it.
	func findStoredValue(of key: String, in environment: String) {
		guard let store, store.isUnlocked, let project = store.selectedProject, project.hasLoadedEnvironments,
			let value = project.value(for: key, in: environment), !value.isEmpty
		else { return }
		mode = .find
		term = ExactText(value)
		isPresented = true
		startFind()
	}

	/// The sheet closed: the term goes, the results stay, and a search still
	/// running stops where it is.
	func sheetClosed() {
		isPresented = false
		stop()
		term = ExactText("")
		keepTerm(nil)
	}

	// MARK: - Searching

	/// Searches for the field's value, replacing the last search's results.
	func startFind() {
		guard let store, store.isUnlocked,
			let matcher = ValueMatcher(term: term.text, findsContainingValues: findsContainingValues)
		else { return }
		clearResults()
		let targets = store.valueSearchTargets(everyAccount: scope == .everyAccount)
		keepTerm(matcher)
		find = Find(scope: scope, accountName: accountName, findsContainingValues: matcher.findsContainingValues,
			order: targets.map(\.id))
		store.recordUserActivity()
		runFind(targets, with: matcher, generation: generation)
	}

	/// Reads the projects a stopped search didn't reach, with its term, in the
	/// order it began with, whatever the sidebar's order is now. Projects
	/// deleted since it stopped are no longer there to read.
	func continueFind() {
		guard let store, store.isUnlocked, canContinue, let matcher, let find else { return }
		let current = Dictionary(
			store.valueSearchTargets(everyAccount: find.scope == .everyAccount).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
		let targets = find.unread.compactMap { current[$0] }
		self.find?.phase = .running
		generation &+= 1
		store.recordUserActivity()
		runFind(targets, with: matcher, generation: generation)
	}

	/// Reads again a project the last search couldn't read.
	func retry(_ skip: ValueSearchSkip) {
		guard let store, store.isUnlocked, canRetry, let matcher, let find,
			let target = store.valueSearchTargets(everyAccount: find.scope == .everyAccount).first(where: { $0.id == skip.projectID })
		else { return }
		self.find?.removeSkip(of: skip.projectID)
		retrying = (skip, find.phase)
		self.find?.phase = .running
		generation &+= 1
		store.recordUserActivity()
		runFind([target], with: matcher, generation: generation, isRetry: true)
	}

	/// Compares every stored value in scope, replacing the last search's results.
	func startReuse() {
		guard let store, store.isUnlocked else { return }
		clearResults()
		keepTerm(nil)
		let targets = store.valueSearchTargets(everyAccount: scope == .everyAccount)
		reuse = Reuse(scope: scope, accountName: accountName, total: targets.count)
		store.recordUserActivity()
		let generation = generation
		let source = store.valueSearchValues(for: targets)
		let secrecy = store.valueSecrecyRules
		let digester = ValueDigester()
		reuseDigester = digester
		task = Task { [weak self] in
			let found = await ValueSearchScan.reuse(in: targets, from: source, secrecy: secrecy, digester: digester) { [weak self] index in
				guard let self, self.generation == generation else { return false }
				self.reuse?.reached = index + 1
				return true
			}
			guard let self, !Task.isCancelled, self.generation == generation, let found else { return }
			dropReuseKey()
			self.reuse?.groups = found.groups
			self.reuse?.skips = found.skips
			self.reuse?.compared = found.compared
			self.reuse?.phase = .finished
			self.task = nil
		}
	}

	/// Stops a running search, keeping what it found so far.
	func stop() {
		guard isRunning else { return }
		generation &+= 1
		task?.cancel()
		task = nil
		if let (skip, phase) = retrying, var find {
			retrying = nil
			find.add(skip)
			find.phase = phase
			self.find = find
		} else if var find, find.phase == .running {
			// Stopped once its last project was read, it has read them all.
			find.phase = find.reached == find.total ? .finished : .stopped
			self.find = find
		}
		if reuse?.phase == .running {
			reuse?.phase = .stopped
			reuse?.groups = []
		}
		dropReuseKey()
	}

	/// Forgets the results, as the strip's Clear does.
	func clearResults() {
		generation &+= 1
		task?.cancel()
		task = nil
		retrying = nil
		find = nil
		reuse = nil
		dropReuseKey()
		openRequest = nil
		pendingOpen = nil
		openedGroup = nil
		showsConfiguration = false
	}

	/// Forgets everything, the term and the results, and closes the sheet:
	/// the vault locked, or another account was chosen.
	func reset() {
		clearResults()
		isPresented = false
		term = ExactText("")
		keepTerm(nil)
		mode = .find
		scope = .account
		findsContainingValues = false
	}

	/// The selected account changed. Opening a result in another account
	/// changes it too, and keeps the results it came from.
	func accountDidChange() {
		guard !isOpening else { return }
		reset()
	}

	// MARK: - Opening results

	/// Shows `place` in the workspace: its project and environment, with the
	/// key selected. One in another account waits for the person to agree,
	/// when switching accounts would discard unsaved changes.
	func open(_ place: ValueSearchPlace, group: Int? = nil) {
		guard let store, store.isUnlocked, store.openableProject(id: place.location.projectID) != nil else { return }
		if asksBeforeOpening(in: place.account) {
			pendingOpen = PendingOpen(target: .place(place, group: group), accountName: place.account.name)
			return
		}
		show(place, group: group)
	}

	/// Opens the place the person agreed to switch accounts for.
	func confirmPendingOpen() {
		guard let pending = pendingOpen else { return }
		pendingOpen = nil
		switch pending.target {
		case .place(let place, let group): show(place, group: group)
		case .project(let skip): showProject(of: skip)
		}
	}

	func cancelPendingOpen() {
		pendingOpen = nil
	}

	private func asksBeforeOpening(in account: ValueSearchAccount) -> Bool {
		guard let store, account.account != store.selectedAccount else { return false }
		return !store.unsavedWork().isEmpty
	}

	private func show(_ place: ValueSearchPlace, group: Int?) {
		guard let store, store.isUnlocked, store.openableProject(id: place.location.projectID) != nil else { return }
		isOpening = true
		defer { isOpening = false }
		let changedProject = store.selectedProjectId != place.location.projectID
		store.openProject(id: place.location.projectID, environment: place.location.environment)
		guard store.selectedProjectId == place.location.projectID else { return }
		openedGroup = group
		openRequest = OpenRequest(projectID: place.location.projectID, location: place.location, changedProject: changedProject)
		sheetClosed()
	}

	/// Opens the project a search couldn't read, where its page says how to repair it.
	func openProject(of skip: ValueSearchSkip) {
		guard let store, store.isUnlocked, store.openableProject(id: skip.projectID) != nil else { return }
		if asksBeforeOpening(in: skip.account) {
			pendingOpen = PendingOpen(target: .project(skip), accountName: skip.account.name)
			return
		}
		showProject(of: skip)
	}

	private func showProject(of skip: ValueSearchSkip) {
		guard let store, store.isUnlocked, store.openableProject(id: skip.projectID) != nil else { return }
		isOpening = true
		defer { isOpening = false }
		let changedProject = store.selectedProjectId != skip.projectID
		store.openProject(id: skip.projectID)
		guard store.selectedProjectId == skip.projectID else { return }
		openRequest = OpenRequest(projectID: skip.projectID, location: nil, changedProject: changedProject)
		sheetClosed()
	}

	/// Whether `place` can be opened: its project is still on this Mac, in an account the person belongs to.
	func canOpen(_ place: ValueSearchPlace) -> Bool {
		store?.openableProject(id: place.location.projectID) != nil
	}

	/// The open request the workspace has shown, which it no longer needs.
	func finishOpening(_ request: OpenRequest) {
		if openRequest == request { openRequest = nil }
	}

	/// The environments of `projectID` where each key is marked found: every
	/// place of the last search for a value, or of the reused group opened last.
	func foundEnvironments(in projectID: String) -> [String: Set<String>] {
		var found: [String: Set<String>] = [:]
		func mark(_ location: ValueLocation) {
			guard location.projectID == projectID else { return }
			found[location.key, default: []].insert(location.environment)
		}
		if let find, find.phase != .running {
			for hit in find.hits { mark(hit.place.location) }
		} else if let reuse, let openedGroup, let group = reuse.groups.first(where: { $0.id == openedGroup }) {
			for place in group.places { mark(place.location) }
		}
		return found
	}

	// MARK: - Private

	/// Keeps `matcher` as the last search's term and lets the one kept before
	/// go: a search still waiting on a read can't match with it after.
	private func keepTerm(_ matcher: ValueMatcher?) {
		self.matcher?.revoke()
		self.matcher = matcher
	}

	/// Lets the scan for reused values' key go, so its digests link to no value.
	private func dropReuseKey() {
		reuseDigester?.revoke()
		reuseDigester = nil
	}

	private var accountName: String? {
		guard scope == .account, let store else { return nil }
		return store.valueSearchAccountName(store.selectedAccount)
	}

	/// Reads `targets` for the current search. A search that reaches its
	/// last project has reached them all, deleted ones included; a retry,
	/// which reads one, ends as that one's outcome is recorded.
	private func runFind(_ targets: [ValueSearchTarget], with matcher: ValueMatcher, generation: Int, isRetry: Bool = false) {
		guard let store else { return }
		let source = store.valueSearchValues(for: targets)
		let ids = targets.map(\.id)
		task = Task { [weak self] in
			await ValueSearchScan.find(matcher, in: targets, from: source) { [weak self] index, outcome in
				guard let self, self.generation == generation else { return false }
				self.record(outcome, for: ids[index])
				return true
			}
			guard let self, !Task.isCancelled, self.generation == generation else { return }
			self.task = nil
			guard !isRetry, var find else { return }
			find.reached = find.order.count
			find.phase = .finished
			self.find = find
		}
	}

	/// Records one project's outcome. A retry's outcome ends the retry with
	/// it, so stopping after can't list the project as unread again.
	private func record(_ outcome: ValueSearchScan.FindOutcome, for id: String) {
		guard var find else { return }
		switch outcome {
		case .searched(let hits):
			find.searched += 1
			find.add(hits, from: id)
		case .skipped(let skip):
			find.add(skip)
		case .gone:
			break
		}
		if let (_, phase) = retrying {
			retrying = nil
			find.phase = phase
		} else {
			find.reach(id)
		}
		self.find = find
	}
}
