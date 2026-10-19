import Foundation

/// Cloudflare's API for one generation of a connection. The connection's
/// token is read for each request, so it's renewed before it expires; when
/// Cloudflare refuses it anyway, as after another renewal replaced it, the
/// connection's current token is asked for, renewed when it must be, and a
/// read is sent once more. Cloudflare applies nothing it refuses that way, so
/// sending again is safe. A publish, which checks the Worker again after any
/// renewal, is told `.renewed` instead of the request being sent again, and
/// whenever the token changed since its last request.
///
/// The token is the reviewed generation's only: a connection connected again
/// since fails as `.credentials(.replaced)`, so a review's login can't change
/// under it.
actor RenewingCloudflareClient: CloudflareClientProtocol {
	typealias ClientFactory = @Sendable (String) -> any CloudflareClientProtocol

	private let connectionID: PlatformConnection.ID
	private let generation: String
	private let credentials: PlatformCredentials
	private let make: ClientFactory
	private let resendsAfterRenewal: Bool
	/// The token the last request went with.
	private var lastToken: String?

	init(
		connectionID: PlatformConnection.ID,
		generation: String,
		credentials: PlatformCredentials,
		resendsAfterRenewal: Bool = true,
		make: @escaping ClientFactory
	) {
		self.connectionID = connectionID
		self.generation = generation
		self.credentials = credentials
		self.resendsAfterRenewal = resendsAfterRenewal
		self.make = make
	}

	private func send<Value: Sendable>(
		_ request: @Sendable (any CloudflareClientProtocol) async -> Result<Value, CloudflareAPIError>
	) async -> Result<Value, CloudflareAPIError> {
		let current: String
		switch await credentials.accessToken(for: connectionID, generation: generation) {
		case .success(let value): current = value
		case .failure(let error): return .failure(.credentials(error))
		}
		let changed = lastToken.map { $0 != current } ?? false
		lastToken = current
		if changed, !resendsAfterRenewal { return .failure(.renewed) }
		let answer = await request(make(current))
		guard case .failure(.unauthorized) = answer else { return answer }
		switch await credentials.accessToken(for: connectionID, replacing: current, generation: generation) {
		case .success(let renewed) where renewed != current:
			lastToken = renewed
			guard resendsAfterRenewal else { return .failure(.renewed) }
			return await request(make(renewed))
		case .success, .failure(.expired):
			// Cloudflare's own refusal says the connection must be connected again.
			return answer
		case .failure(let error):
			return .failure(.credentials(error))
		}
	}

	func workers(in account: String) async -> Result<[CloudflareWorker], CloudflareAPIError> {
		await send { await $0.workers(in: account) }
	}

	func worker(_ idOrName: String, in account: String) async -> Result<CloudflareWorker, CloudflareAPIError> {
		await send { await $0.worker(idOrName, in: account) }
	}

	func newestVersion(ofWorker id: String, in account: String) async -> Result<CloudflareVersion, CloudflareAPIError> {
		await send { await $0.newestVersion(ofWorker: id, in: account) }
	}

	func activeDeployment(ofScript name: String, in account: String) async -> Result<CloudflareDeployment, CloudflareAPIError> {
		await send { await $0.activeDeployment(ofScript: name, in: account) }
	}

	func updateSecrets(_ secrets: [String: String], ofScript name: String, in account: String) async
		-> Result<CloudflareSecretsUpdate, CloudflareAPIError>
	{
		await send { await $0.updateSecrets(secrets, ofScript: name, in: account) }
	}
}
