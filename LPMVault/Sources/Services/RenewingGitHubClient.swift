import Foundation

/// GitHub's API for one connection. The connection's token is read for each
/// request, so it's renewed before it expires rather than after GitHub
/// refuses it partway through a list. When GitHub refuses it anyway, as after
/// another renewal replaced it or once it expired early by a wrong clock, the
/// connection's current token is asked for, renewed when it must be, and the
/// request is sent once more. GitHub applies nothing it refuses that way, so
/// sending again is safe. A publish, which checks GitHub again after any
/// wait, is told `.renewed` instead of the request being sent again.
actor RenewingGitHubClient: GitHubClientProtocol {
	private let connectionID: PlatformConnection.ID
	private let credentials: PlatformCredentials
	private let make: GitHubConnector.ClientFactory
	private let resendsAfterRenewal: Bool
	/// A token just read for the connection, which the first request uses.
	private var token: String?

	/// `token` is one just read for the connection, when there is one.
	init(
		connectionID: PlatformConnection.ID,
		credentials: PlatformCredentials,
		token: String? = nil,
		resendsAfterRenewal: Bool = true,
		make: @escaping GitHubConnector.ClientFactory
	) {
		self.connectionID = connectionID
		self.credentials = credentials
		self.token = token
		self.resendsAfterRenewal = resendsAfterRenewal
		self.make = make
	}

	private func send<Value: Sendable>(
		_ request: @Sendable (any GitHubClientProtocol) async -> Result<Value, GitHubAPIError>
	) async -> Result<Value, GitHubAPIError> {
		let current: String
		if let token {
			current = token
			self.token = nil
		} else {
			switch await credentials.accessToken(for: connectionID) {
			case .success(let value): current = value
			case .failure(let error): return .failure(.credentials(error))
			}
		}
		let answer = await request(make(current))
		guard case .failure(.unauthorized) = answer else { return answer }
		switch await credentials.accessToken(for: connectionID, replacing: current) {
		case .success(let renewed) where renewed != current:
			guard resendsAfterRenewal else { return .failure(.renewed) }
			return await request(make(renewed))
		case .success, .failure(.expired):
			// GitHub's own refusal says the connection must be connected again.
			return answer
		case .failure(let error):
			return .failure(.credentials(error))
		}
	}

	func user() async -> Result<GitHubUser, GitHubAPIError> { await send { await $0.user() } }
	func repositories() async -> Result<GitHubRepositoryList, GitHubAPIError> { await send { await $0.repositories() } }
	func repository(id: String) async -> Result<GitHubRepository, GitHubAPIError> { await send { await $0.repository(id: id) } }
	func environments(of repository: String) async -> Result<[GitHubEnvironment], GitHubAPIError> {
		await send { await $0.environments(of: repository) }
	}
	func environment(named name: String, of repository: String) async -> Result<GitHubEnvironment?, GitHubAPIError> {
		await send { await $0.environment(named: name, of: repository) }
	}
	func secrets(in scope: GitHubScope) async -> Result<[GitHubValueRecord], GitHubAPIError> { await send { await $0.secrets(in: scope) } }
	func secret(_ name: String, in scope: GitHubScope) async -> Result<GitHubValueRecord?, GitHubAPIError> {
		await send { await $0.secret(name, in: scope) }
	}
	func publicKey(of scope: GitHubScope) async -> Result<GitHubPublicKey, GitHubAPIError> { await send { await $0.publicKey(of: scope) } }
	func setSecret(_ name: String, to sealed: GitHubSealedSecret, in scope: GitHubScope) async -> Result<Void, GitHubAPIError> {
		await send { await $0.setSecret(name, to: sealed, in: scope) }
	}
	func variables(in scope: GitHubScope) async -> Result<[GitHubValueRecord], GitHubAPIError> { await send { await $0.variables(in: scope) } }
	func variable(_ name: String, in scope: GitHubScope) async -> Result<GitHubValueRecord?, GitHubAPIError> {
		await send { await $0.variable(name, in: scope) }
	}
	func createVariable(_ name: String, value: String, in scope: GitHubScope) async -> Result<Void, GitHubAPIError> {
		await send { await $0.createVariable(name, value: value, in: scope) }
	}
	func updateVariable(_ name: String, value: String, in scope: GitHubScope) async -> Result<Void, GitHubAPIError> {
		await send { await $0.updateVariable(name, value: value, in: scope) }
	}
}
