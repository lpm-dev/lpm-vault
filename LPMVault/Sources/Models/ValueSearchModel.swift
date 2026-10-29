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
		var hits: [ValueSearchHit] = []
		var skips: [ValueSearchSkip] = []
		var phase: Phase = .running

		var total: Int { order.count }
		/// The projects the search stopped before reading.
		var unread: ArraySlice<String> { phase == .stopped ? order[reached...] : [] }
		var projectCount: Int { Set(hits.lazy.map(\.place.location.projectID)).count }
		var accountCount: Int { Set(hits.lazy.map(\.place.account)).count }
	}

	/// The last scan for values stored in more than one place.
	struct Reuse: Sendable {
		let scope: Scope
		let accountName: String?
		let total: Int
		var reached = 0
		var groups: [ReusedValueGroup] = []
		var skips: [ValueSearchSkip] = []
		var phase: Phase = .running

		/// The groups of values that look secret, which the report lists.
		var reported: [ReusedValueGroup] { groups.filter { !$0.isConfiguration } }
		/// The groups left out as configuration, which the report can show.
		var configuration: [ReusedValueGroup] { groups.filter(\.isConfiguration) }
	}

	/// A result the person opened, for the workspace to show.
	struct OpenRequest: Equatable, Sendable {
		let id = UUID()
		let location: ValueLocation
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
	/// The group whose place was opened last, which the workspace marks.
	private(set) var openedGroup: Int?

	/// The search running now, which tests wait for.
	@ObservationIgnored private(set) var task: Task<Void, Never>?
	private var generation = 0
	/// The last search's term while the sheet stays open, for Continue and Try Again.
	private var matcher: ValueMatcher?
	/// The project being read again, and the phase its search returns to.
	private var retrying: (skip: ValueSearchSkip, phase: Phase)?
	private var isOpening = false

	var isRunning: Bool { find?.phase == .running || reuse?.phase == .running }
	/// Whether the last search's term is still held: the sheet hasn't closed since it ran.
	var keepsTerm: Bool { matcher != nil }
	/// Whether the stopped search can read on: its term is still held.
	var canContinue: Bool { find?.phase == .stopped && matcher != nil && !(find?.unread.isEmpty ?? true) }
	/// Whether a project the last search couldn't read can be read again.
	var canRetry: Bool { matcher != nil && find?.phase != .running }

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
		matcher = nil
	}

	// MARK: - Searching

	/// Searches for the field's value, replacing the last search's results.
	func startFind() {
		guard let store, store.isUnlocked,
			let matcher = ValueMatcher(term: term.text, findsContainingValues: findsContainingValues)
		else { return }
		clearResults()
		let targets = store.valueSearchTargets(everyAccount: scope == .everyAccount)
		self.matcher = matcher
		find = Find(scope: scope, accountName: accountName, findsContainingValues: matcher.findsContainingValues,
			order: targets.map(\.id))
		store.recordUserActivity()
		runFind(targets, with: matcher, generation: generation)
	}

	/// Reads the projects a stopped search didn't reach, with its term.
	/// Projects deleted since it stopped are no longer there to read.
	func continueFind() {
		guard let store, store.isUnlocked, canContinue, let matcher, let find else { return }
		let unread = Set(find.unread)
		let targets = store.valueSearchTargets(everyAccount: find.scope == .everyAccount).filter { unread.contains($0.id) }
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
		self.find?.skips.removeAll { $0.projectID == skip.projectID }
		retrying = (skip, find.phase)
		self.find?.phase = .running
		generation &+= 1
		store.recordUserActivity()
		runFind([target], with: matcher, generation: generation)
	}

	/// Compares every stored value in scope, replacing the last search's results.
	func startReuse() {
		guard let store, store.isUnlocked else { return }
		clearResults()
		matcher = nil
		let targets = store.valueSearchTargets(everyAccount: scope == .everyAccount)
		reuse = Reuse(scope: scope, accountName: accountName, total: targets.count)
		store.recordUserActivity()
		let generation = generation
		let source = store.valueSearchSource
		let secrecy = store.valueSecrecyRules
		task = Task { [weak self] in
			let found = await ValueSearchScan.reuse(in: targets, from: source, secrecy: secrecy) { [weak self] index in
				guard let self, self.generation == generation else { return false }
				self.reuse?.reached = index + 1
				return true
			}
			guard let self, !Task.isCancelled, self.generation == generation, let found else { return }
			self.reuse?.groups = found.groups
			self.reuse?.skips = found.skips
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
			find.skips = Self.ordered(find.skips + [skip], by: find.order)
			find.phase = phase
			self.find = find
		} else if find?.phase == .running {
			find?.phase = .stopped
		}
		if reuse?.phase == .running {
			reuse?.phase = .stopped
			reuse?.groups = []
		}
	}

	/// Forgets the results, as the strip's Clear does.
	func clearResults() {
		generation &+= 1
		task?.cancel()
		task = nil
		retrying = nil
		find = nil
		reuse = nil
		openRequest = nil
		openedGroup = nil
		showsConfiguration = false
	}

	/// Forgets everything, the term and the results, and closes the sheet:
	/// the vault locked, or another account was chosen.
	func reset() {
		clearResults()
		isPresented = false
		term = ExactText("")
		matcher = nil
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

	/// Shows `place` in the workspace: its project and environment, with the key selected.
	func open(_ place: ValueSearchPlace, group: Int? = nil) {
		guard let store, store.isUnlocked, store.openableProject(id: place.location.projectID) != nil else { return }
		isOpening = true
		defer { isOpening = false }
		let changedProject = store.selectedProjectId != place.location.projectID
		store.openProject(id: place.location.projectID)
		guard store.selectedProjectId == place.location.projectID else { return }
		store.selectEnvironment(place.location.environment)
		openedGroup = group
		openRequest = OpenRequest(location: place.location, changedProject: changedProject)
		sheetClosed()
	}

	/// Opens the project a search couldn't read, where its page says how to repair it.
	func openProject(of skip: ValueSearchSkip) {
		guard let store, store.isUnlocked, store.openableProject(id: skip.projectID) != nil else { return }
		isOpening = true
		defer { isOpening = false }
		store.openProject(id: skip.projectID)
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

	private var accountName: String? {
		guard scope == .account, let store else { return nil }
		return store.valueSearchAccountName(store.selectedAccount)
	}

	/// Reads `targets` for the current search. A search that reaches its
	/// last project has reached them all, deleted ones included.
	private func runFind(_ targets: [ValueSearchTarget], with matcher: ValueMatcher, generation: Int) {
		guard let store else { return }
		let source = store.valueSearchSource
		let ids = targets.map(\.id)
		task = Task { [weak self] in
			await ValueSearchScan.find(matcher, in: targets, from: source) { [weak self] index, outcome in
				guard let self, self.generation == generation else { return false }
				self.record(outcome, for: ids[index])
				return true
			}
			guard let self, !Task.isCancelled, self.generation == generation else { return }
			self.task = nil
			if let (_, phase) = retrying {
				retrying = nil
				find?.phase = phase
			} else if var find {
				find.reached = find.order.count
				find.phase = .finished
				self.find = find
			}
		}
	}

	private func record(_ outcome: ValueSearchScan.FindOutcome, for id: String) {
		guard var find else { return }
		switch outcome {
		case .searched(let hits):
			find.searched += 1
			if !hits.isEmpty { find.hits = Self.ordered(find.hits + hits, by: find.order) }
		case .skipped(let skip):
			find.skips = Self.ordered(find.skips + [skip], by: find.order)
		case .gone:
			break
		}
		if retrying == nil, let position = find.order[find.reached...].firstIndex(of: id) { find.reached = position + 1 }
		self.find = find
	}

	/// Keeps results in the order the search reads projects, so a project
	/// read again after the others still lists in its place.
	private static func ordered(_ hits: [ValueSearchHit], by order: [String]) -> [ValueSearchHit] {
		let positions = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
		return hits.enumerated().sorted {
			let left = positions[$0.element.place.location.projectID] ?? .max, right = positions[$1.element.place.location.projectID] ?? .max
			return left != right ? left < right : $0.offset < $1.offset
		}.map(\.element)
	}

	private static func ordered(_ skips: [ValueSearchSkip], by order: [String]) -> [ValueSearchSkip] {
		let positions = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
		return skips.sorted { (positions[$0.projectID] ?? .max) < (positions[$1.projectID] ?? .max) }
	}
}
