import CryptoKit
import Foundation
import Observation

/// One run of the Publish sheet: choosing where an environment goes, the
/// review of what that changes, and the publish itself.
@MainActor
@Observable
final class PublishSession: Identifiable {
	/// What the session reads and changes outside itself.
	struct Dependencies {
		/// The environment's saved values, once local changes are read; nil when it's gone.
		var values: @MainActor (_ environment: String) async -> [String: String]?
		var rules: @MainActor () -> Rules
		var check: @MainActor (_ environment: String) -> ProjectEnvValueCheck.Environment?
		/// Asks for Touch ID or the password, without reusing an earlier approval.
		var confirm: @MainActor (_ reason: String) async -> Bool
		var publishing: PublishingStore
		var connections: PlatformConnectionStore
		var vercel: @Sendable (_ token: String) -> any VercelClientProtocol
		var coolify: CoolifyConnector.ClientFactory = { CoolifyClient(instance: $0, token: $1) }
		var now: @Sendable () -> Date = { Date() }
		/// Called after destinations or history change.
		var didChange: @MainActor () -> Void = {}
	}

	/// The project's rules as the review uses them.
	enum Rules: Equatable, Sendable {
		case known(ProjectEnvSchemaOverview)
		/// The project has no rules, so every key is undeclared.
		case none
		/// lpm.json can't be read; every key is treated as undeclared and nothing is checked.
		case unreadable

		var overview: ProjectEnvSchemaOverview {
			if case .known(let overview) = self { return overview }
			return .empty
		}
	}

	enum Step: Equatable {
		case destination
		case review
		case results
	}

	enum Loadable<Value: Equatable>: Equatable {
		case idle
		case loading
		case loaded(Value)
		case failed(String)

		var value: Value? {
			if case .loaded(let value) = self { return value }
			return nil
		}
	}

	struct Review {
		let destination: PublishDestination
		let isSaved: Bool
		/// The destination is new, or differs from the saved one, so a publish saves it first.
		let needsSave: Bool
		let plan: PublishPlan
		var selection: PublishPlan.Selection
		let fingerprintKey: SymmetricKey
		let lastPublishedAt: Date?
		let rules: Rules
		let hasValueCheck: Bool
		/// The platform's variables the plan was made from, by key.
		let remote: [String: PublishPlan.RemoteVariable]

		var summary: PublishPlan.Summary { plan.summary(of: selection) }
		var platform: PublishPlatform { destination.target.platform }
	}

	struct Results: Equatable {
		let destination: PublishDestination
		/// Each sent key with its outcome, in the review's order.
		let rows: [(key: String, outcome: PublishOutcome)]
		let needsReconnect: Bool
		/// Why the publish couldn't be recorded, when it couldn't.
		let recordFailure: String?

		var publishedCount: Int { rows.lazy.filter { $0.outcome == .published }.count }

		static func == (lhs: Results, rhs: Results) -> Bool {
			lhs.destination == rhs.destination && lhs.rows.elementsEqual(rhs.rows) { $0.key == $1.key && $0.outcome == $1.outcome }
				&& lhs.needsReconnect == rhs.needsReconnect && lhs.recordFailure == rhs.recordFailure
		}
	}

	let id = UUID()
	let vaultID: String
	let projectName: String
	/// The project's environments, in its order.
	let environments: [String]

	private(set) var step: Step
	/// The destination the sheet opened with, when it's a saved one.
	private(set) var saved: PublishDestination?

	var sourceEnvironment: String { didSet { if sourceEnvironment != oldValue { invalidateReview() } } }
	private(set) var connections: Loadable<[PlatformConnection]> = .idle
	var connectionID: PlatformConnection.ID? {
		didSet {
			guard connectionID != oldValue else { return }
			invalidateReview()
			form = makeForm()
			loadForm()
		}
	}
	/// The chosen connection's fields.
	private(set) var form: PublishDestinationForm?

	private(set) var review: Review?
	private(set) var isLoadingReview = false
	/// Why the review couldn't be made or used.
	private(set) var reviewError: String?
	private(set) var isPublishing = false
	private(set) var results: Results?

	private let dependencies: Dependencies
	private var reviewTask: Task<Void, Never>?
	/// Loads the form's choices: a Vercel project list or Coolify's resources.
	private var choicesTask: Task<Void, Never>?
	private var environmentsTask: Task<Void, Never>?
	private var publishTask: Task<Void, Never>?

	init(
		vaultID: String,
		projectName: String,
		environments: [String],
		sourceEnvironment: String,
		saved: PublishDestination? = nil,
		dependencies: Dependencies
	) {
		self.vaultID = vaultID
		self.projectName = projectName
		self.environments = environments
		self.dependencies = dependencies
		self.saved = saved
		if let saved {
			self.sourceEnvironment = saved.sourceEnvironment
			self.connectionID = saved.target.connectionID
			switch saved.target {
			case .vercel(let target):
				self.form = .vercel(VercelDestinationForm(projectID: target.projectID, environment: target.environment))
			case .coolify(let target):
				self.form = .coolify(CoolifyDestinationForm(resourceID: target.resourceID, deployments: target.deployments))
			}
			self.step = .review
		} else {
			self.sourceEnvironment = sourceEnvironment
			self.step = .destination
		}
		observe(form)
	}

	/// Loads what the open step needs. A saved destination goes straight to
	/// its review, and lists its platform's choices only when it's changed.
	func start() {
		Task { [weak self] in
			guard let self else { return }
			await self.loadConnections()
			guard self.saved != nil else { return }
			self.loadReview()
		}
	}

	func cancel() {
		reviewTask?.cancel()
		choicesTask?.cancel()
		environmentsTask?.cancel()
		publishTask?.cancel()
	}

	// MARK: - Destination

	var connection: PlatformConnection? {
		connections.value?.first { $0.id == connectionID }
	}

	/// The platform the destination publishes to, once a connection is chosen.
	var platform: PublishPlatform? {
		switch form {
		case .vercel?: .vercel
		case .coolify?: .coolify
		case nil: nil
		}
	}

	var vercel: VercelDestinationForm? {
		if case .vercel(let form)? = form { return form }
		return nil
	}

	var coolify: CoolifyDestinationForm? {
		if case .coolify(let form)? = form { return form }
		return nil
	}

	var canReview: Bool {
		let isComplete = switch form {
		case .vercel(let form)?: form.isComplete
		case .coolify(let form)?: form.isComplete
		case nil: false
		}
		return environments.contains(sourceEnvironment) && connection != nil && isComplete && !isLoadingReview && !isPublishing
	}

	func showDestination() {
		guard !isPublishing else { return }
		reviewTask?.cancel()
		isLoadingReview = false
		step = .destination
		if needsChoices { loadForm() }
	}

	/// Whether the form's choices, such as Coolify's resources, haven't been listed yet.
	private var needsChoices: Bool {
		switch form {
		case .vercel(let form)?: form.projects == .idle
		case .coolify(let form)?: form.resources == .idle
		case nil: false
		}
	}

	func loadReview() {
		reviewTask?.cancel()
		reviewError = nil
		isLoadingReview = true
		step = .review
		reviewTask = Task { [weak self] in
			guard let self else { return }
			let outcome = await self.makeReview()
			guard !Task.isCancelled else { return }
			self.isLoadingReview = false
			switch outcome {
			case .success(let review): self.review = review
			case .failure(let error):
				self.review = nil
				self.reviewError = error.message
			}
		}
	}

	private func loadConnections() async {
		connections = .loading
		switch await dependencies.connections.connections() {
		case .success(let list):
			connections = .loaded(list)
			if connectionID == nil, list.count == 1 { connectionID = list[0].id }
		case .failure(let error):
			connections = .failed("Platform connections couldn't be read. \(error)")
		}
	}

	/// A form for the chosen connection's platform, keeping the saved
	/// destination's choices when it's the saved destination's connection.
	private func makeForm() -> PublishDestinationForm? {
		guard let connectionID, let connection = connections.value?.first(where: { $0.id == connectionID }) else { return nil }
		let form: PublishDestinationForm = switch connection.platform {
		case .vercel: .vercel(VercelDestinationForm())
		case .coolify: .coolify(CoolifyDestinationForm())
		}
		observe(form)
		return form
	}

	private func observe(_ form: PublishDestinationForm?) {
		switch form {
		case .vercel(let form)?:
			form.didChange = { [weak self, weak form] field in
				guard let self, let form else { return }
				self.invalidateReview()
				if field == .project { self.loadCustomEnvironments(form) }
			}
		case .coolify(let form)?:
			form.didChange = { [weak self] in self?.invalidateReview() }
		case nil:
			break
		}
	}

	private func loadForm() {
		choicesTask?.cancel()
		environmentsTask?.cancel()
		switch form {
		case .vercel(let form)?:
			loadProjects(form)
			loadCustomEnvironments(form)
		case .coolify(let form)?:
			loadResources(form)
		case nil:
			break
		}
	}

	/// The chosen connection's token, read when a request needs it.
	private func token(for connectionID: PlatformConnection.ID) async -> Result<String, PublishSessionError> {
		await dependencies.connections.accessToken(for: connectionID)
			.mapError { "The connection's token can't be read. \($0)" }
	}

	private func loadProjects(_ form: VercelDestinationForm) {
		guard let connectionID else { return }
		form.projects = .loading
		let teamID = vercelTeamID()
		choicesTask = Task { [weak self, weak form, dependencies] in
			let result: Result<[VercelProject], PublishSessionError>
			switch await self?.token(for: connectionID) {
			case .success(let token)?:
				result = await dependencies.vercel(token).projects(teamID: teamID)
					.map { $0.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } }
					.mapError { PublishSessionError(VercelPublishing.message($0)) }
			case .failure(let error)?:
				result = .failure(error)
			case nil:
				return
			}
			guard let self, let form, !Task.isCancelled, self.vercel === form else { return }
			switch result {
			case .success(let list): form.projects = .loaded(list)
			case .failure(let error): form.projects = .failed(error.message)
			}
		}
	}

	private func loadCustomEnvironments(_ form: VercelDestinationForm) {
		environmentsTask?.cancel()
		guard let connectionID, let projectID = form.projectID else {
			form.customEnvironments = .idle
			return
		}
		form.customEnvironments = .loading
		let teamID = vercelTeamID()
		environmentsTask = Task { [weak self, weak form, dependencies] in
			let result: Result<[VercelCustomEnvironment], PublishSessionError>
			switch await self?.token(for: connectionID) {
			case .success(let token)?:
				result = await dependencies.vercel(token).customEnvironments(projectID: projectID, teamID: teamID)
					.mapError { PublishSessionError(VercelPublishing.message($0)) }
			case .failure(let error)?:
				result = .failure(error)
			case nil:
				return
			}
			guard let self, let form, !Task.isCancelled, self.vercel === form, form.projectID == projectID else { return }
			switch result {
			case .success(let list): form.customEnvironments = .loaded(list)
			case .failure(let error): form.customEnvironments = .failed(error.message)
			}
		}
	}

	private func loadResources(_ form: CoolifyDestinationForm) {
		guard let connectionID, let instance = coolifyInstance() else { return }
		form.resources = .loading
		choicesTask = Task { [weak self, weak form, dependencies] in
			let result: Result<[CoolifyResource], PublishSessionError>
			switch await self?.token(for: connectionID) {
			case .success(let token)?:
				result = await dependencies.coolify(instance, token).resources()
					.map(CoolifyDestinationForm.sorted)
					.mapError { PublishSessionError(CoolifyPublishing.message($0)) }
			case .failure(let error)?:
				result = .failure(error)
			case nil:
				return
			}
			guard let self, let form, !Task.isCancelled, self.coolify === form else { return }
			switch result {
			case .success(let list): form.resources = .loaded(list)
			case .failure(let error): form.resources = .failed(error.message)
			}
		}
	}

	/// The Vercel team the chosen connection reaches; nil for a personal account.
	private func vercelTeamID() -> String? {
		if case .vercel(let account)? = connection?.account { return account.teamID }
		if case .vercel(let target)? = saved?.target, target.connectionID == connectionID { return target.teamID }
		return nil
	}

	/// The Coolify instance the chosen connection reaches.
	private func coolifyInstance() -> CoolifyInstance? {
		if case .coolify(let account)? = connection?.account { return account.instance }
		if case .coolify(let target)? = saved?.target, target.connectionID == connectionID { return target.instance }
		return nil
	}

	/// Where the fields say to publish, from the chosen connection.
	private func target() -> Result<PublishTarget, PublishSessionError> {
		if connection == nil, let saved, connectionID == saved.target.connectionID, connections.value != nil {
			return .failure("This destination publishes through \(saved.target.accountName) on \(saved.target.platform.displayName), which isn't connected on this Mac. Connect it on the Platforms page.")
		}
		switch (connection?.account, form) {
		case (.vercel(let account)?, .vercel(let form)?):
			guard let projectID = form.projectID, let environment = form.environment else { return .failure("Choose a destination first.") }
			let projectName = form.project?.name ?? {
				if case .vercel(let target)? = saved?.target, target.projectID == projectID { return target.projectName }
				return projectID
			}()
			return .success(.vercel(VercelPublishTarget(
				teamID: account.teamID, accountID: account.ownerID, teamName: account.name,
				projectID: projectID, projectName: projectName, environment: environment)))
		case (.coolify(let account)?, .coolify(let form)?):
			var savedTarget: CoolifyPublishTarget?
			if case .coolify(let target)? = saved?.target, target.resourceID == form.resourceID, target.instance == account.instance {
				savedTarget = target
			}
			guard let resourceID = form.resourceID, let deployments = form.deployments,
				let kind = form.resource?.kind ?? savedTarget?.resource
			else { return .failure("Choose a destination first.") }
			let resource = form.resource
			return .success(.coolify(CoolifyPublishTarget(
				instance: account.instance, teamID: account.teamID, teamName: account.teamName,
				resource: kind, resourceID: resourceID, resourceName: resource?.name ?? savedTarget?.resourceName ?? resourceID,
				projectName: resource == nil ? savedTarget?.projectName : resource?.projectName,
				environmentName: resource == nil ? savedTarget?.environmentName : resource?.environmentName,
				deployments: deployments)))
		default:
			return .failure("Choose a destination first.")
		}
	}

	/// The destination the fields describe: the saved one, the saved one
	/// that already publishes to the same place, or a new one.
	private func destination(
		target: PublishTarget,
		among existing: [PublishDestination]
	) -> Result<(destination: PublishDestination, stored: PublishDestination?), PublishSessionError> {
		let location = target.location
		let stored: PublishDestination?
		if let saved {
			if let other = existing.first(where: { $0.id != saved.id && $0.target.location == location }) {
				return .failure("Another saved destination already publishes to \(target.placeName), from \(VaultProject.displayName(for: other.sourceEnvironment)). Choose it from the Publish menu.")
			}
			stored = existing.first { $0.id == saved.id }
		} else {
			stored = existing.first { $0.target.location == location }
		}
		var updated = stored ?? saved ?? PublishDestination(sourceEnvironment: sourceEnvironment, target: target, createdAt: dependencies.now())
		updated.sourceEnvironment = sourceEnvironment
		updated.target = target
		return .success((updated, stored))
	}

	/// The platform's variables for the destination, and what the platform accepts.
	private struct Remote {
		let variables: [String: PublishPlan.RemoteVariable]
		let platform: PublishPlan.Platform
	}

	private func remote(of target: PublishTarget, token: String) async -> Result<Remote, PublishSessionError> {
		switch target {
		case .vercel(let target):
			let client = dependencies.vercel(token)
			async let listing = client.variables(projectID: target.projectID, teamID: target.teamID)
			async let customs = client.customEnvironments(projectID: target.projectID, teamID: target.teamID)
			let list: VercelVariableList
			switch await listing {
			case .success(let value): list = value
			case .failure(let error): return .failure(PublishSessionError(VercelPublishing.message(error)))
			}
			return VercelPublishing.snapshot(list, for: target.environment, customEnvironments: (try? await customs.get()) ?? [])
				.map { Remote(variables: $0.variables, platform: VercelPublishing.platform) }
				.mapError { PublishSessionError($0.message) }
		case .coolify(let target):
			let client = dependencies.coolify(target.instance, token)
			async let listing = client.variables(of: target.resource, id: target.resourceID)
			let buildPack: String?
			if target.resource == .application {
				switch await client.buildPack(ofApplication: target.resourceID) {
				case .success(let value): buildPack = value
				case .failure(let error): return .failure(PublishSessionError(CoolifyPublishing.message(error)))
				}
			} else {
				buildPack = nil
			}
			switch await listing {
			case .success(let list):
				return CoolifyPublishing.snapshot(list, for: target.deployments)
					.map { Remote(variables: $0.variables, platform: CoolifyPublishing.platform(for: target.resource, buildPack: buildPack)) }
					.mapError { PublishSessionError($0.message) }
			case .failure(let error):
				return .failure(PublishSessionError(CoolifyPublishing.message(error)))
			}
		}
	}

	private func makeReview() async -> Result<Review, PublishSessionError> {
		let target: PublishTarget
		switch self.target() {
		case .success(let value): target = value
		case .failure(let error): return .failure(error)
		}
		let source = sourceEnvironment
		let rules = dependencies.rules()
		let check = dependencies.check(source)
		guard let values = await dependencies.values(source) else {
			return .failure("\(VaultProject.displayName(for: source)) can't be read right now.")
		}
		let publishing = dependencies.publishing
		let destination: PublishDestination
		let stored: PublishDestination?
		switch await publishing.destinations(of: vaultID) {
		case .success(let existing):
			switch self.destination(target: target, among: existing) {
			case .success(let found): (destination, stored) = found
			case .failure(let error): return .failure(error)
			}
		case .failure(let error):
			return .failure("Saved destinations can't be read. \(error)")
		}
		let history: PublishHistory?
		if let stored, stored.target.location == destination.target.location {
			switch await publishing.history(of: destination.id, in: vaultID) {
			case .success(let value): history = value
			case .failure(let error): return .failure("This destination's history can't be read. \(error)")
			}
		} else {
			history = nil
		}
		let fingerprintKey: SymmetricKey
		switch await publishing.fingerprintKey() {
		case .success(let key): fingerprintKey = key
		case .failure(let error): return .failure("LPM Vault's publish key can't be read. \(error)")
		}
		let token: String
		switch await self.token(for: target.connectionID) {
		case .success(let value): token = value
		case .failure(let error): return .failure(error)
		}
		let remote: Remote
		switch await self.remote(of: target, token: token) {
		case .success(let value): remote = value
		case .failure(let error): return .failure(error)
		}
		let plan = PublishPlan(
			destination: destination,
			values: values,
			rules: rules.overview,
			check: check,
			remote: remote.variables,
			platform: remote.platform,
			history: history,
			fingerprintKey: fingerprintKey)
		return .success(Review(
			destination: destination,
			isSaved: stored != nil,
			needsSave: stored != destination,
			plan: plan,
			selection: PublishPlan.Selection(defaultsOf: plan),
			fingerprintKey: fingerprintKey,
			lastPublishedAt: history?.publishedAt,
			rules: rules,
			hasValueCheck: check != nil,
			remote: remote.variables))
	}

	private func invalidateReview() {
		guard !isPublishing else { return }
		reviewTask?.cancel()
		review = nil
		reviewError = nil
		isLoadingReview = false
	}

	// MARK: - Review

	/// Chooses or drops the key; a key shared with other environments needs `confirmed`.
	@discardableResult
	func set(_ key: String, selected: Bool, confirmed: Bool = false) -> Bool {
		guard var review, !isPublishing else { return false }
		let changed = review.selection.set(key, selected: selected, confirmed: confirmed, in: review.plan)
		self.review = review
		return changed
	}

	func isSelected(_ key: String) -> Bool {
		review?.selection.keys.contains(key) ?? false
	}

	// MARK: - Publish

	/// Checks the chosen values are still the reviewed ones, asks for Touch
	/// ID, sends them, and records what the platform accepted.
	func publish() {
		guard publishTask == nil, let review, !review.selection.keys.isEmpty else { return }
		reviewError = nil
		isPublishing = true
		publishTask = Task { [weak self] in
			guard let self else { return }
			defer {
				self.isPublishing = false
				self.publishTask = nil
			}
			await self.run(review)
		}
	}

	private func run(_ review: Review) async {
		let dependencies = dependencies
		guard let values = await dependencies.values(review.destination.sourceEnvironment) else {
			reviewError = "\(VaultProject.displayName(for: review.destination.sourceEnvironment)) can't be read right now."
			return
		}
		let changes: [PublishPlan.Change]
		switch review.plan.changes(for: review.selection, values: values, fingerprintKey: review.fingerprintKey) {
		case .success(let value): changes = value
		case .failure(.stale(let keys)):
			reviewError = "\(keys.joined(separator: ", ")) changed since this review. Review again to publish the current \(keys.count == 1 ? "value" : "values")."
			return
		case .failure(.foreignSelection):
			reviewError = "This review is out of date. Review again."
			return
		}
		let count = changes.count
		let reason = "Publish \(count) \(count == 1 ? "variable" : "variables") to \(review.platform.displayName)"
		guard await dependencies.confirm(reason), !Task.isCancelled else { return }

		let token: String
		switch await self.token(for: review.destination.target.connectionID) {
		case .success(let value): token = value
		case .failure(let error):
			reviewError = error.message
			return
		}
		let report: PublishReport
		switch review.destination.target {
		case .vercel(let target):
			report = await VercelPublishing.publish(changes, to: target, using: dependencies.vercel(token))
		case .coolify(let target):
			report = await CoolifyPublishing.publish(
				changes, to: target, reviewed: review.remote, using: dependencies.coolify(target.instance, token))
		}
		var recordFailure: String?
		if !report.published.isEmpty {
			recordFailure = await record(report.published, of: review)
		}
		dependencies.didChange()
		results = Results(
			destination: review.destination,
			rows: changes.map { ($0.key, report.outcomes[$0.key] ?? .notSent) },
			needsReconnect: report.needsReconnect,
			recordFailure: recordFailure)
		step = .results
	}

	/// Saves the destination when it's new or changed, then records the
	/// publish; the reason it couldn't, or nil.
	private func record(_ published: [PublishHistory.Published], of review: Review) async -> String? {
		let publishing = dependencies.publishing
		var destination = review.destination
		if review.needsSave {
			switch await publishing.save(destination, to: vaultID) {
			case .success(let saved):
				guard let stored = saved.first(where: { $0.id == destination.id }) else { return "The destination couldn't be saved." }
				destination = stored
			case .failure(let error):
				return "The variables were published, but the destination couldn't be saved. \(error)"
			}
		}
		switch await publishing.recordPublish(
			published, to: destination.id, at: destination.target.location,
			choices: review.plan.choices(for: review.selection), of: vaultID, at: dependencies.now())
		{
		case .success(let recorded):
			saved = recorded
			return nil
		case .failure(let error):
			return "The variables were published, but this Mac couldn't record it. \(error)"
		}
	}
}

/// A reason the Publish sheet shows, as text.
struct PublishSessionError: Error, Equatable, Sendable, ExpressibleByStringInterpolation {
	let message: String

	init(_ message: String) {
		self.message = message
	}

	init(stringLiteral value: String) {
		message = value
	}

	init(stringInterpolation: DefaultStringInterpolation) {
		message = String(stringInterpolation: stringInterpolation)
	}
}

/// A saved destination with when this Mac last published to it.
struct PublishDestinationSummary: Identifiable, Equatable, Sendable {
	let destination: PublishDestination
	let lastPublishedAt: Date?

	var id: UUID { destination.id }
}
