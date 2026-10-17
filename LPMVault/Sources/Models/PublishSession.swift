import CryptoKit
import Foundation
import Observation

/// One run of the Publish sheet: choosing where an environment goes, the
/// review of what that changes, and the publish itself.
@MainActor
@Observable
final class PublishSession: Identifiable {
	/// An environment's saved values with the project's rules and the
	/// values' check against them, all describing the same moment. Its
	/// values never appear when it's printed, logged or dumped.
	struct Snapshot: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
		/// What a read of a snapshot includes.
		enum Contents: Sendable {
			/// The values and rules, with the values' check.
			case checked
			/// The values and rules only, as a publish needs to compare them with its review.
			case unchecked
		}

		let values: [String: String]
		let rules: Rules
		/// The values' check, when the project has rules to check them by and the read asked for it.
		let check: ProjectEnvValueCheck.Environment?

		var description: String { "Snapshot(\(values.count) values: <redacted>)" }
		var debugDescription: String { description }
		var customMirror: Mirror { Mirror(self, children: ["keys": values.keys.sorted()]) }
	}

	/// What the session reads and changes outside itself.
	struct Dependencies {
		/// The environment's snapshot once local changes are read; nil when it's gone.
		var snapshot: @MainActor (_ environment: String, _ contents: Snapshot.Contents) async -> Snapshot?
		/// Asks for Touch ID or the password, without reusing an earlier approval.
		var confirm: @MainActor (_ reason: String) async -> Bool
		var publishing: PublishingStore
		var connections: PlatformConnectionStore
		/// The connections' access tokens, renewed when a platform's tokens expire.
		var credentials: PlatformCredentials
		var vercel: @Sendable (_ token: String) -> any VercelClientProtocol
		var coolify: CoolifyConnector.ClientFactory = { CoolifyClient(instance: $0, token: $1) }
		var netlify: NetlifyConnector.ClientFactory = { NetlifyClient(token: $0) }
		var github: GitHubConnector.ClientFactory = { GitHubClient(token: $0) }
		/// How a GitHub publish leaves time between writes.
		var githubPacing = GitHubPublishing.Pacing()
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
		/// The destination as it was stored when the review was made.
		let stored: PublishDestination?
		let isSaved: Bool
		/// The destination is new, or differs from the saved one, so a publish saves it first.
		let needsSave: Bool
		let plan: PublishPlan
		var selection: PublishPlan.Selection
		let fingerprintKey: SymmetricKey
		let lastPublishedAt: Date?
		let rules: Rules
		let hasValueCheck: Bool
		/// Why each key that fails the project's rules fails, as the values
		/// and check the plan was made from show it.
		let ruleNotes: [String: String]
		/// The platform's variables the plan was made from, by key.
		let remote: [String: PublishPlan.RemoteVariable]
		/// The platform's variables without a value of the destination's own the plan was made from, by key.
		let remoteKeys: [String: PublishPlan.RemoteKey]

		var summary: PublishPlan.Summary { plan.summary(of: selection) }
		var platform: PublishPlatform { destination.target.platform }
	}

	struct Results: Equatable {
		let destination: PublishDestination
		/// Each sent key with its outcome, in the review's order.
		let rows: [(key: String, outcome: PublishOutcome)]
		/// How many of the keys were sent as secrets.
		var secrets = 0
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
	/// The chosen connection. Choosing another starts its fields afresh.
	var connectionID: PlatformConnection.ID? {
		get { chosenConnectionID }
		set {
			guard newValue != chosenConnectionID else { return }
			chosenConnectionID = newValue
			invalidateReview()
			form = makeForm()
			loadForm()
		}
	}
	private var chosenConnectionID: PlatformConnection.ID?
	/// The chosen connection's fields.
	private(set) var form: PublishDestinationForm?
	/// Why the destination step opened in place of the review, as when the
	/// saved destination was forgotten meanwhile.
	private(set) var destinationError: String?

	private(set) var review: Review?
	private(set) var isLoadingReview = false
	/// Why the review couldn't be made or used.
	private(set) var reviewError: String?
	private(set) var isPublishing = false
	private(set) var results: Results?

	private let dependencies: Dependencies
	/// Set once the sheet closes or the vault locks; nothing starts after it.
	private(set) var isCancelled = false
	private var startTask: Task<Void, Never>?
	private var reviewTask: Task<Void, Never>?
	/// Loads the form's choices: a Vercel project list, Coolify's resources, Netlify's sites or GitHub's repositories.
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
			self.chosenConnectionID = saved.target.connectionID
			self.form = Self.form(for: saved.target)
			self.step = .review
		} else {
			self.sourceEnvironment = sourceEnvironment
			self.step = .destination
		}
		observe(form)
	}

	/// Loads what the open step needs. A saved destination is read again,
	/// since the one the sheet opened with may be out of date, then goes
	/// straight to its review, unless the person chose Destination meanwhile;
	/// its platform's choices are listed only when it's changed.
	func start() {
		guard !isCancelled, startTask == nil else { return }
		startTask = Task { [weak self] in
			guard let self else { return }
			await self.loadConnections()
			guard !Task.isCancelled, self.saved != nil, await self.refreshSaved(), !Task.isCancelled, self.step == .review else { return }
			self.loadReview()
		}
	}

	/// Returns once everything the session has started has ended, including
	/// what that work started in turn.
	func waitUntilIdle() async {
		var awaited: [Task<Void, Never>?]
		repeat {
			awaited = tasks
			for task in awaited { await task?.value }
		} while awaited != tasks
	}

	private var tasks: [Task<Void, Never>?] { [startTask, reviewTask, choicesTask, environmentsTask, publishTask] }

	/// Stops everything the session runs, for good.
	func cancel() {
		isCancelled = true
		startTask?.cancel()
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
		case .netlify?: .netlify
		case .github?: .github
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

	var netlify: NetlifyDestinationForm? {
		if case .netlify(let form)? = form { return form }
		return nil
	}

	var github: GitHubDestinationForm? {
		if case .github(let form)? = form { return form }
		return nil
	}

	var canReview: Bool {
		let isComplete = switch form {
		case .vercel(let form)?: form.isComplete
		case .coolify(let form)?: form.isComplete
		case .netlify(let form)?: form.isComplete
		case .github(let form)?: form.isComplete
		case nil: false
		}
		return environments.contains(sourceEnvironment) && connection != nil && isComplete && !isLoadingReview && !isPublishing
	}

	func showDestination() {
		guard !isPublishing, !isCancelled else { return }
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
		case .netlify(let form)?: form.sites == .idle
		case .github(let form)?: form.repositories == .idle
		case nil: false
		}
	}

	func loadReview() {
		guard !isCancelled else { return }
		reviewTask?.cancel()
		reviewError = nil
		destinationError = nil
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
		let result = await dependencies.connections.connections()
		guard !Task.isCancelled else { return }
		switch result {
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
		let form: PublishDestinationForm
		switch connection.platform {
		case .vercel: form = .vercel(VercelDestinationForm())
		case .coolify: form = .coolify(CoolifyDestinationForm())
		case .netlify: form = .netlify(NetlifyDestinationForm())
		case .github: form = .github(GitHubDestinationForm())
		}
		observe(form)
		return form
	}

	/// Reads the saved destination as it's stored now, following a rename of
	/// its source or a move to another place; false when it can't be
	/// reviewed. A destination forgotten meanwhile isn't brought back: the
	/// destination step opens on its choices instead.
	private func refreshSaved() async -> Bool {
		guard let saved else { return true }
		let result = await dependencies.publishing.destinations(of: vaultID)
		guard !Task.isCancelled else { return false }
		switch result {
		case .success(let destinations):
			guard let stored = destinations.first(where: { $0.id == saved.id }) else {
				self.saved = nil
				step = .destination
				destinationError = "This destination was forgotten on this Mac, as when its source environment is deleted. Choose where to publish instead."
				loadForm()
				return false
			}
			guard stored != saved else { return true }
			self.saved = stored
			sourceEnvironment = stored.sourceEnvironment
			if stored.target != saved.target {
				choicesTask?.cancel()
				environmentsTask?.cancel()
				chosenConnectionID = stored.target.connectionID
				form = Self.form(for: stored.target)
				observe(form)
				invalidateReview()
			}
			return true
		case .failure(let error):
			reviewError = "Saved destinations can't be read. \(error)"
			return false
		}
	}

	private static func form(for target: PublishTarget) -> PublishDestinationForm {
		switch target {
		case .vercel(let target): .vercel(VercelDestinationForm(projectID: target.projectID, environment: target.environment))
		case .coolify(let target): .coolify(CoolifyDestinationForm(resourceID: target.resourceID, deployments: target.deployments))
		case .netlify(let target): .netlify(NetlifyDestinationForm(siteID: target.siteID, context: target.context))
		case .github(let target): .github(GitHubDestinationForm(repositoryID: target.repositoryID, scope: target.scope))
		}
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
		case .netlify(let form)?:
			form.didChange = { [weak self] in self?.invalidateReview() }
		case .github(let form)?:
			form.didChange = { [weak self, weak form] field in
				guard let self, let form else { return }
				self.invalidateReview()
				if field == .repository { self.loadEnvironments(form) }
			}
		case nil:
			break
		}
	}

	private func loadForm() {
		guard !isCancelled else { return }
		choicesTask?.cancel()
		environmentsTask?.cancel()
		switch form {
		case .vercel(let form)?:
			loadProjects(form)
			loadCustomEnvironments(form)
		case .coolify(let form)?:
			loadResources(form)
		case .netlify(let form)?:
			loadSites(form)
		case .github(let form)?:
			// Environments are listed once the repositories say the chosen one's current name.
			loadRepositories(form)
		case nil:
			break
		}
	}

	/// Lists the form's choices again, as after installing LPM Vault's GitHub App on more repositories.
	func reloadChoices() {
		guard !isCancelled, step == .destination, !isPublishing else { return }
		loadForm()
	}

	/// The connection's token, read when a request needs it, and renewed first when it's about to expire.
	private func token(for connectionID: PlatformConnection.ID, on platform: PublishPlatform) async -> Result<String, PublishSessionError> {
		await dependencies.credentials.accessToken(for: connectionID)
			.mapError { PublishSessionError($0.message(for: platform)) }
	}

	private func loadProjects(_ form: VercelDestinationForm) {
		guard let connectionID else { return }
		form.projects = .loading
		let teamID = vercelTeamID()
		choicesTask = Task { [weak self, weak form, dependencies] in
			let result: Result<[VercelProject], PublishSessionError>
			switch await self?.token(for: connectionID, on: .vercel) {
			case .success(let token)? where !Task.isCancelled:
				result = await dependencies.vercel(token).projects(teamID: teamID)
					.map { $0.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } }
					.mapError { PublishSessionError(VercelPublishing.message($0)) }
			case .failure(let error)? where !Task.isCancelled:
				result = .failure(error)
			case .success?, .failure?, nil:
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
			switch await self?.token(for: connectionID, on: .vercel) {
			case .success(let token)? where !Task.isCancelled:
				result = await dependencies.vercel(token).customEnvironments(projectID: projectID, teamID: teamID)
					.mapError { PublishSessionError(VercelPublishing.message($0)) }
			case .failure(let error)? where !Task.isCancelled:
				result = .failure(error)
			case .success?, .failure?, nil:
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
			switch await self?.token(for: connectionID, on: .coolify) {
			case .success(let token)? where !Task.isCancelled:
				result = await dependencies.coolify(instance, token).resources()
					.map(CoolifyDestinationForm.sorted)
					.mapError { PublishSessionError(CoolifyPublishing.message($0)) }
			case .failure(let error)? where !Task.isCancelled:
				result = .failure(error)
			case .success?, .failure?, nil:
				return
			}
			guard let self, let form, !Task.isCancelled, self.coolify === form else { return }
			switch result {
			case .success(let list): form.resources = .loaded(list)
			case .failure(let error): form.resources = .failed(error.message)
			}
		}
	}

	private func loadSites(_ form: NetlifyDestinationForm) {
		guard let connectionID else { return }
		form.sites = .loading
		choicesTask = Task { [weak self, weak form, dependencies] in
			let result: Result<[NetlifySite], PublishSessionError>
			switch await self?.token(for: connectionID, on: .netlify) {
			case .success(let token)? where !Task.isCancelled:
				result = await Self.sortedSites(from: dependencies.netlify(token))
			case .failure(let error)? where !Task.isCancelled:
				result = .failure(error)
			case .success?, .failure?, nil:
				return
			}
			guard let self, let form, !Task.isCancelled, self.netlify === form else { return }
			switch result {
			case .success(let list): form.sites = .loaded(list)
			case .failure(let error): form.sites = .failed(error.message)
			}
		}
	}

	/// The client's sites in the menu's order, listed and sorted off the main actor.
	private nonisolated static func sortedSites(from client: any NetlifyClientProtocol) async -> Result<[NetlifySite], PublishSessionError> {
		await client.sites()
			.map(NetlifyDestinationForm.sorted)
			.mapError { PublishSessionError(NetlifyPublishing.message($0)) }
	}

	private func loadRepositories(_ form: GitHubDestinationForm) {
		guard let connectionID else { return }
		environmentsTask?.cancel()
		form.repositories = .loading
		form.hidesSSORepositories = false
		form.skipsInstallations = false
		let client = githubClient(for: connectionID)
		choicesTask = Task { [weak self, weak form] in
			let result = await Self.sortedRepositories(from: client)
			guard let self, let form, !Task.isCancelled, self.github === form else { return }
			switch result {
			case .success(let list):
				form.repositories = .loaded(list.repositories)
				form.hidesSSORepositories = list.hidesSSORepositories
				form.skipsInstallations = list.skipsInstallations
				if form.repositoryID != nil { self.loadEnvironments(form) }
			case .failure(let error): form.repositories = .failed(error.message)
			}
		}
	}

	/// GitHub's API for the connection, with its token renewed whenever GitHub
	/// refuses it. A publish is told of a renewal instead of a request being
	/// sent again, so it checks GitHub again first.
	private func githubClient(
		for connectionID: PlatformConnection.ID,
		token: String? = nil,
		publishing: Bool = false
	) -> RenewingGitHubClient {
		RenewingGitHubClient(
			connectionID: connectionID, credentials: dependencies.credentials, token: token, resendsAfterRenewal: !publishing,
			make: dependencies.github)
	}

	/// The client's repositories in the menu's order, listed and sorted off the main actor.
	private nonisolated static func sortedRepositories(from client: any GitHubClientProtocol) async -> Result<GitHubRepositoryList, PublishSessionError> {
		await client.repositories()
			.map { list in
				var sorted = list
				sorted.repositories = GitHubDestinationForm.sorted(list.repositories)
				return sorted
			}
			.mapError { PublishSessionError(GitHubPublishing.message($0)) }
	}

	/// Lists the chosen repository's environments, by the name the repositories
	/// just listed give it; nothing while they're still listed, as their
	/// listing lists the environments when it ends.
	private func loadEnvironments(_ form: GitHubDestinationForm) {
		environmentsTask?.cancel()
		guard let connectionID, let repositoryID = form.repositoryID, let repository = form.repository?.fullName else {
			form.environments = .idle
			return
		}
		form.environments = .loading
		let client = githubClient(for: connectionID)
		environmentsTask = Task { [weak self, weak form] in
			let result = await Self.sortedEnvironments(of: repository, from: client)
			guard let self, let form, !Task.isCancelled, self.github === form, form.repositoryID == repositoryID else { return }
			switch result {
			case .success(let list): form.environments = .loaded(list)
			case .failure(let error): form.environments = .failed(error.message)
			}
		}
	}

	/// The repository's environments by name, listed and sorted off the main actor.
	private nonisolated static func sortedEnvironments(
		of repository: String,
		from client: any GitHubClientProtocol
	) async -> Result<[GitHubEnvironment], PublishSessionError> {
		await client.environments(of: repository)
			.map { $0.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } }
			.mapError { error in
				// On the destination step, listing the repositories again is what helps.
				PublishSessionError(error == .moved
					? "The repository was renamed or moved on GitHub. Refresh to list it again."
					: GitHubPublishing.message(error))
			}
	}

	/// The chosen repository's `owner/name`: as listed, or as the saved destination names it.
	private func githubRepositoryName(_ form: GitHubDestinationForm) -> String? {
		if let repository = form.repository { return repository.fullName }
		if case .github(let target)? = saved?.target, target.repositoryID == form.repositoryID { return target.repositoryName }
		return nil
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
			return .failure("This destination publishes through \(saved.target.connectionName) on \(saved.target.platform.displayName), which isn't connected on this Mac. Connect it on the Platforms page.")
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
		case (.netlify(let account)?, .netlify(let form)?):
			var savedTarget: NetlifyPublishTarget?
			if case .netlify(let target)? = saved?.target, target.siteID == form.siteID, target.userID == account.userID {
				savedTarget = target
			}
			let site = form.site
			guard let siteID = form.siteID, let context = form.context, let teamID = site?.teamID ?? savedTarget?.teamID else {
				return .failure("Choose a destination first.")
			}
			return .success(.netlify(NetlifyPublishTarget(
				userID: account.userID, userName: account.name,
				teamID: teamID, teamName: site?.teamName ?? savedTarget?.teamName ?? teamID,
				siteID: siteID, siteName: site?.name ?? savedTarget?.siteName ?? siteID,
				context: context)))
		case (.github(let account)?, .github(let form)?):
			guard let repositoryID = form.repositoryID, let repositoryName = githubRepositoryName(form), let scope = form.scope else {
				return .failure("Choose a destination first.")
			}
			return .success(.github(GitHubPublishTarget(
				userID: account.userID, userLogin: account.login,
				repositoryID: repositoryID, repositoryName: repositoryName, scope: scope)))
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
			guard let found = existing.first(where: { $0.id == saved.id }) else {
				return .failure("This destination was forgotten on this Mac, as when its source environment is deleted. Choose where to publish instead.")
			}
			stored = found
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
		var keys: [String: PublishPlan.RemoteKey] = [:]
		let platform: PublishPlan.Platform
		/// The target as the platform names its places now, when that differs
		/// from how it was saved, as after a repository is renamed.
		var target: PublishTarget?
	}

	private func remote(of target: PublishTarget, token: String, rules: ProjectEnvSchemaOverview) async -> Result<Remote, PublishSessionError> {
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
		case .netlify(let target):
			switch await dependencies.netlify(token).variables(siteID: target.siteID, teamID: target.teamID) {
			case .success(let list):
				return NetlifyPublishing.snapshot(list, for: target.context)
					.map { Remote(variables: $0.variables, keys: $0.keys, platform: NetlifyPublishing.platform) }
					.mapError { PublishSessionError($0.message) }
			case .failure(let error):
				return .failure(PublishSessionError(NetlifyPublishing.message(error)))
			}
		case .github(let target):
			return await Self.githubRemote(
				of: target, using: githubClient(for: target.connectionID, token: token), readableKeys: rules.ciVariableKeys)
		}
	}

	/// A GitHub destination's secrets and variables, read by the repository's
	/// and environment's current names, which GitHub's paths use: the
	/// repository by its ID, and the environment by its ID among the repository's.
	private nonisolated static func githubRemote(
		of target: GitHubPublishTarget,
		using client: any GitHubClientProtocol,
		readableKeys: Set<String>
	) async -> Result<Remote, PublishSessionError> {
		func failure(_ error: GitHubAPIError) -> Result<Remote, PublishSessionError> {
			.failure(PublishSessionError(GitHubPublishing.message(error)))
		}
		var current = target
		switch await client.repository(id: target.repositoryID) {
		case .success(let repository):
			current.repositoryName = repository.fullName
			if let refusal = GitHubPublishing.accessRefusal(repository, for: target.scope) { return .failure(PublishSessionError(refusal)) }
		case .failure(.notFound):
			return .failure("\(target.repositoryName) isn't reachable on GitHub any more. Install LPM Vault's GitHub App on it, or choose another destination.")
		case .failure(let error): return failure(error)
		}
		if case .environment(let id, let name) = target.scope {
			switch await client.environments(of: current.repositoryName) {
			case .success(let environments):
				guard let environment = environments.first(where: { $0.id == id }) else {
					return .failure("The environment \(GitHubPublishTarget.Scope.shownName(id: id, name: name)) isn't in \(current.repositoryName) any more. Choose another destination.")
				}
				current.scope = .environment(id: id, name: environment.name)
			case .failure(let error): return failure(error)
			}
		}
		let scope = GitHubScope(repository: current.repositoryName, environment: current.scope.environmentName)
		async let secretList = client.secrets(in: scope)
		let variables: [GitHubValueRecord]
		switch await client.variables(in: scope) {
		case .success(let value): variables = value
		case .failure(let error):
			_ = await secretList
			return failure(error)
		}
		let secrets: [GitHubValueRecord]
		switch await secretList {
		case .success(let value): secrets = value
		case .failure(let error): return failure(error)
		}
		return GitHubPublishing.snapshot(secrets: secrets, variables: variables)
			.map { snapshot in
				Remote(
					variables: snapshot.variables, keys: snapshot.keys,
					platform: GitHubPublishing.platform(readableKeys: readableKeys, scope: current.scope),
					target: current == target ? nil : .github(current))
			}
			.mapError { PublishSessionError($0.message) }
	}

	/// The review of the destination the fields describe. Nothing more is
	/// read once the review is cancelled, as when the vault locks.
	private func makeReview() async -> Result<Review, PublishSessionError> {
		let target: PublishTarget
		switch self.target() {
		case .success(let value): target = value
		case .failure(let error): return .failure(error)
		}
		let source = sourceEnvironment
		let read = await dependencies.snapshot(source, .checked)
		guard !Task.isCancelled else { return .failure(.cancelled) }
		guard let snapshot = read else {
			return .failure("\(VaultProject.displayName(for: source)) can't be read right now.")
		}
		let (values, rules, check) = (snapshot.values, snapshot.rules, snapshot.check)
		let publishing = dependencies.publishing
		var destination: PublishDestination
		let stored: PublishDestination?
		let destinations = await publishing.destinations(of: vaultID)
		guard !Task.isCancelled else { return .failure(.cancelled) }
		switch destinations {
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
			let read = await publishing.history(of: destination.id, in: vaultID)
			guard !Task.isCancelled else { return .failure(.cancelled) }
			switch read {
			case .success(let value): history = value
			case .failure(let error): return .failure("This destination's history can't be read. \(error)")
			}
		} else {
			history = nil
		}
		let key = await publishing.fingerprintKey()
		guard !Task.isCancelled else { return .failure(.cancelled) }
		let fingerprintKey: SymmetricKey
		switch key {
		case .success(let value): fingerprintKey = value
		case .failure(let error): return .failure("LPM Vault's publish key can't be read. \(error)")
		}
		let token: String
		switch await self.token(for: target.connectionID, on: target.platform) {
		case .success(let value) where !Task.isCancelled: token = value
		case .failure(let error) where !Task.isCancelled: return .failure(error)
		case .success, .failure: return .failure(.cancelled)
		}
		let remote: Remote
		switch await self.remote(of: target, token: token, rules: rules.overview) {
		case .success(let value): remote = value
		case .failure(let error): return .failure(error)
		}
		guard !Task.isCancelled else { return .failure(.cancelled) }
		if let current = remote.target, current.location == destination.target.location {
			destination.target = current
		}
		let plan = PublishPlan(
			destination: destination,
			values: values,
			rules: rules.overview,
			check: check,
			remote: remote.variables,
			remoteKeys: remote.keys,
			platform: remote.platform,
			history: history,
			fingerprintKey: fingerprintKey)
		return .success(Review(
			destination: destination,
			stored: stored,
			isSaved: stored != nil,
			needsSave: stored != destination,
			plan: plan,
			selection: PublishPlan.Selection(defaultsOf: plan),
			fingerprintKey: fingerprintKey,
			lastPublishedAt: history?.publishedAt,
			rules: rules,
			hasValueCheck: check != nil,
			ruleNotes: Self.ruleNotes(for: plan, values: values, rules: rules, check: check, in: source),
			remote: remote.variables,
			remoteKeys: remote.keys))
	}

	/// Why each key failing the project's rules fails, from the values and check `plan` was made from.
	private static func ruleNotes(
		for plan: PublishPlan,
		values: [String: String],
		rules: Rules,
		check: ProjectEnvValueCheck.Environment?,
		in environment: String
	) -> [String: String] {
		guard let check else { return [:] }
		let presentation = VaultValueCheckPresentation(
			check: ProjectEnvValueCheck(environments: [environment: check]), rules: rules.overview, environments: [environment: values])
		var notes: [String: String] = [:]
		for row in plan.rows {
			for case .failsRules(let problems) in row.holds {
				if let problem = problems.first { notes[row.key] = presentation.message(for: problem, in: environment) }
			}
		}
		return notes
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

	/// Reviews the destination again after a publish, as when the platform
	/// changed some of its variables meanwhile.
	func reviewAgain() {
		guard step == .results, !isPublishing, !isCancelled else { return }
		results = nil
		review = nil
		loadReview()
	}

	// MARK: - Publish

	/// Checks the chosen values are still the reviewed ones, asks for Touch
	/// ID, sends them, and records what the platform accepted.
	func publish() {
		guard !isCancelled, publishTask == nil, let review, !review.selection.keys.isEmpty,
			review.plan.overflows(of: review.selection).isEmpty
		else { return }
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
		let source = review.destination.sourceEnvironment
		guard let snapshot = await dependencies.snapshot(source, .unchecked), !Task.isCancelled else {
			if !Task.isCancelled { reviewError = "\(VaultProject.displayName(for: source)) can't be read right now." }
			return
		}
		// The rules decide which keys publish readable, so ones changed since the review would send what wasn't reviewed.
		guard snapshot.rules == review.rules else {
			reviewError = "lpm.json's rules changed since this review. Review again to publish by the current rules."
			return
		}
		let changes: [PublishPlan.Change]
		switch review.plan.changes(for: review.selection, values: snapshot.values, fingerprintKey: review.fingerprintKey) {
		case .success(let value): changes = value
		case .failure(.stale(let keys)):
			reviewError = "\(keys.joined(separator: ", ")) changed since this review. Review again to publish the current \(keys.count == 1 ? "value" : "values")."
			return
		case .failure(.foreignSelection):
			reviewError = "This review is out of date. Review again."
			return
		}
		let secrets = changes.lazy.filter(\.publishesAsSecret).count
		let place = review.destination.target.placeName
		let counted = review.platform.countedValues(secrets: secrets, variables: changes.count - secrets)
		let reason = "Publish \(counted) to \(place) on \(review.platform.displayName)"
		guard await dependencies.confirm(reason), !Task.isCancelled else { return }

		let token: String
		switch await self.token(for: review.destination.target.connectionID, on: review.platform) {
		case .success(let value): token = value
		case .failure(let error):
			reviewError = error.message
			return
		}
		guard !Task.isCancelled else { return }
		let report: PublishReport
		switch review.destination.target {
		case .vercel(let target):
			report = await VercelPublishing.publish(changes, to: target, reviewed: review.remote, using: dependencies.vercel(token))
		case .coolify(let target):
			report = await CoolifyPublishing.publish(
				changes, to: target, reviewed: review.remote, using: dependencies.coolify(target.instance, token))
		case .netlify(let target):
			report = await NetlifyPublishing.publish(
				changes, to: target, reviewed: NetlifyRemoteSnapshot(variables: review.remote, keys: review.remoteKeys),
				using: dependencies.netlify(token))
		case .github(let target):
			report = await GitHubPublishing.publish(
				changes, to: target, reviewed: GitHubRemoteSnapshot(variables: review.remote, keys: review.remoteKeys),
				using: githubClient(for: target.connectionID, token: token, publishing: true), pacing: dependencies.githubPacing)
		}
		var recordFailure: String?
		if !report.published.isEmpty {
			recordFailure = await record(report.published, advancing: report.advances, of: review)
		}
		dependencies.didChange()
		results = Results(
			destination: review.destination,
			rows: changes.map { ($0.key, report.outcomes[$0.key] ?? .notSent) },
			secrets: changes.lazy.filter(\.publishesAsSecret).count,
			needsReconnect: report.needsReconnect,
			recordFailure: recordFailure)
		step = .results
	}

	/// Saves the destination when it's new or changed, then records the
	/// publish; the reason it couldn't, or nil. What the platform accepted
	/// is recorded even when the vault locked meanwhile: the platform holds
	/// those values, so the next review has to know them. Only the
	/// destination and fingerprints are written, never a value or token.
	private func record(
		_ published: [PublishHistory.Published],
		advancing advances: [PublishHistory.Advance],
		of review: Review
	) async -> String? {
		let publishing = dependencies.publishing
		var destination = review.destination
		var choices = review.plan.choices(for: review.selection)
		if review.needsSave {
			// Saved only over the destination the review read, so a change made meanwhile isn't lost.
			switch await publishing.save(destination, to: vaultID, replacing: review.stored) {
			case .success(let saved):
				guard let stored = saved.first(where: { $0.id == destination.id }) else { return "The destination couldn't be saved." }
				destination = stored
				choices = choices.made(at: stored.updatedAt)
			case .failure(.destinationChanged), .failure(.destinationRemoved):
				return "The variables were published, but the destination changed on this Mac meanwhile, so this publish wasn't recorded. Review again."
			case .failure(let error):
				return "The variables were published, but the destination couldn't be saved. \(error)"
			}
		}
		switch await publishing.recordPublish(
			published, to: destination.id, at: destination.target.location,
			choices: choices, advancing: advances, of: vaultID, at: dependencies.now())
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
	static let cancelled = PublishSessionError("Cancelled.")

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
	/// What tells the connection apart from another with the same name, such
	/// as a Vercel team's slug; nil when it isn't connected on this Mac.
	var accountDetail: String?

	var id: UUID { destination.id }
}
