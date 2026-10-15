import AppKit
import Foundation
import Observation

/// The platform connections the Platforms page shows and changes.
@MainActor
@Observable
final class PlatformConnections {
	enum Phase: Equatable {
		case idle
		/// The platform's page is open in the browser.
		case waitingForBrowser
	}

	struct Notice: Equatable {
		let message: String
		let isError: Bool
	}

	typealias SessionProvider = @MainActor () async -> PlatformSession?
	/// One run of connecting Vercel; see `VercelConnector.connect`.
	typealias Connect = @Sendable (
		_ session: PlatformSession,
		_ open: @escaping @Sendable (URL) async -> Void
	) async -> Result<(grant: VercelGrant, account: VercelAccount), VercelConnectError>

	/// One check of a Coolify address and token; see `CoolifyConnector.connect`.
	typealias ConnectCoolify = @Sendable (_ address: String, _ token: String) async -> Result<CoolifyConnection, CoolifyConnectError>

	/// One run of connecting Netlify; see `NetlifyConnector.connect`.
	typealias ConnectNetlify = @Sendable (
		_ open: @escaping @Sendable (URL) async -> Void
	) async -> Result<NetlifyConnection, NetlifyConnectError>

	enum CoolifyOutcome: Equatable {
		case connected(PlatformConnection)
		case failed(String)
		/// It was cancelled, or the vault locked, before the token was saved.
		case dropped
	}

	private(set) var connections: [PlatformConnection] = []
	private(set) var phase: Phase = .idle
	/// The platform connecting in the browser, one at a time.
	private(set) var connecting: PublishPlatform?
	private(set) var notice: Notice?
	private(set) var isLoading = false
	/// Connections whose disconnect is still running.
	private(set) var disconnecting: Set<PlatformConnection.ID> = []

	private let store: PlatformConnectionStore
	private let connect: Connect
	private let connectCoolifyTeam: ConnectCoolify
	private let connectNetlifyAccount: ConnectNetlify
	private let session: SessionProvider
	private let openURL: @MainActor @Sendable (URL) -> Void
	private let now: @Sendable () -> Date
	/// Called after a connection is saved or removed.
	private let didChange: @MainActor () -> Void
	private var connectTask: Task<Void, Never>?
	private var coolifyTask: Task<CoolifyOutcome, Never>?
	private var loadTask: Task<Void, Never>?
	private var generation = 0

	init(
		store: PlatformConnectionStore,
		connect: @escaping Connect = { await VercelConnector().connect(session: $0, open: $1) },
		connectCoolify: @escaping ConnectCoolify = { await CoolifyConnector().connect(address: $0, token: $1) },
		connectNetlify: @escaping ConnectNetlify = { await NetlifyConnector().connect(open: $0) },
		session: @escaping SessionProvider,
		openURL: @escaping @MainActor @Sendable (URL) -> Void = PlatformConnections.openInBrowser,
		now: @escaping @Sendable () -> Date = { Date() },
		didChange: @escaping @MainActor () -> Void = {}
	) {
		self.store = store
		self.connect = connect
		self.connectCoolifyTeam = connectCoolify
		self.connectNetlifyAccount = connectNetlify
		self.session = session
		self.openURL = openURL
		self.now = now
		self.didChange = didChange
	}

	var isConnecting: Bool { connectTask != nil }

	nonisolated static let openInBrowser: @MainActor @Sendable (URL) -> Void = { url in
		_ = NSWorkspace.shared.open(url)
	}

	func load() {
		loadTask?.cancel()
		let generation = generation
		isLoading = true
		loadTask = Task { [weak self, store] in
			let result = await store.connections()
			guard let self, generation == self.generation, !Task.isCancelled else { return }
			self.isLoading = false
			self.loadTask = nil
			switch result {
			case .success(let connections): self.connections = connections
			case .failure(let error): self.notice = Notice(message: "Platform connections couldn't be read. \(error)", isError: true)
			}
		}
	}

	/// Connects a Vercel account in the browser; does nothing while a browser connection runs.
	func connectVercel() {
		connectInBrowser(.vercel) { [weak self] open in
			guard let self, let session = await self.session() else { return .failed(VercelConnectError.signedOut.message) }
			guard !Task.isCancelled else { return .cancelled }
			switch await self.connect(session, open) {
			case .success(let connected):
				let grant = connected.grant
				return .connected(
					.vercel(VercelConnectionAccount(
						installationID: grant.installationID, teamID: grant.teamID, userID: grant.userID,
						name: connected.account.name, slug: connected.account.slug)),
					token: grant.accessToken)
			case .failure(.cancelled): return .cancelled
			case .failure(let error): return .failed(error.message)
			}
		}
	}

	/// Connects a Netlify account in the browser; does nothing while a
	/// browser connection runs. It needs no LPM sign-in.
	func connectNetlify() {
		connectInBrowser(.netlify) { [connectNetlifyAccount] open in
			switch await connectNetlifyAccount(open) {
			case .success(let connected):
				let user = connected.user
				return .connected(
					.netlify(NetlifyConnectionAccount(userID: user.id, name: user.name ?? user.email ?? "Netlify account", email: user.email)),
					token: connected.token)
			case .failure(.cancelled): return .cancelled
			case .failure(let error): return .failed(error.message)
			}
		}
	}

	/// How a browser connection ended.
	private enum BrowserOutcome: Sendable {
		case connected(PlatformConnection.Account, token: String)
		case failed(String)
		case cancelled
	}

	/// Runs `run`, which opens the platform's page with the `open` it's given,
	/// then saves what it connected. The page opens only while the connection
	/// is still wanted, and a connection the vault locked or the person
	/// cancelled before it could be used is never kept.
	private func connectInBrowser(
		_ platform: PublishPlatform,
		_ run: @escaping @MainActor (_ open: @escaping @Sendable (URL) async -> Void) async -> BrowserOutcome
	) {
		guard connectTask == nil else { return }
		notice = nil
		connecting = platform
		let generation = generation
		connectTask = Task { [weak self] in
			guard let self else { return }
			defer {
				if generation == self.generation {
					self.connectTask = nil
					self.connecting = nil
					self.phase = .idle
				}
			}
			let openURL = self.openURL
			let outcome = await run { [weak self] url in
				// Checked and opened in one turn on the main actor, so a lock can't land in between.
				await MainActor.run {
					guard let self, generation == self.generation, !Task.isCancelled else { return }
					self.phase = .waitingForBrowser
					openURL(url)
				}
			}
			guard generation == self.generation else { return }
			switch outcome {
			case .connected(let account, let token):
				switch await self.store.saveUndoably(account, accessToken: token, at: self.now()) {
				case .success(let saved):
					guard await self.keep(saved, generation: generation) else { return }
					let connection = saved.connection
					self.insert(connection)
					self.notice = Notice(message: "Connected \(connection.name) on \(platform.displayName).", isError: false)
				case .failure(.cancelled):
					self.notice = nil
				case .failure(let error):
					guard generation == self.generation else { return }
					self.notice = Notice(message: "\(platform.displayName) connected, but the connection couldn't be saved. \(error)", isError: true)
				}
			case .cancelled:
				self.notice = nil
			case .failed(let message):
				self.notice = Notice(message: message, isError: true)
			}
		}
	}

	/// Checks the token with the Coolify instance at `address`, then saves
	/// the connection, replacing an earlier one to the same team. Cancelling
	/// the caller, or locking the vault, stops it before the token is saved.
	func connectCoolify(address: String, token: String) async -> CoolifyOutcome {
		coolifyTask?.cancel()
		notice = nil
		let generation = generation
		let task = Task { [weak self] () -> CoolifyOutcome in
			await self?.completeCoolify(address: address, token: token, generation: generation) ?? .dropped
		}
		coolifyTask = task
		let outcome = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
		if coolifyTask == task { coolifyTask = nil }
		return outcome
	}

	private func completeCoolify(address: String, token: String, generation: Int) async -> CoolifyOutcome {
		let result = await connectCoolifyTeam(address, token)
		guard generation == self.generation, !Task.isCancelled else { return .dropped }
		switch result {
		case .success(let connected):
			let account = CoolifyConnectionAccount(instance: connected.instance, teamID: connected.team.id, teamName: connected.team.name)
			switch await store.saveUndoably(.coolify(account), accessToken: connected.token, at: now()) {
			case .success(let saved):
				guard await keep(saved, generation: generation) else { return .dropped }
				let connection = saved.connection
				insert(connection)
				notice = Notice(message: "Connected \(connection.name) on Coolify.", isError: false)
				return .connected(connection)
			case .failure(.cancelled):
				return .dropped
			case .failure(let error):
				guard generation == self.generation else { return .dropped }
				return .failed("Coolify accepted the token, but the connection couldn't be saved. \(error)")
			}
		case .failure(.cancelled):
			return .dropped
		case .failure(let error):
			return .failed(error.message)
		}
	}

	/// Whether a connection saved for `generation` is still wanted. One the
	/// vault locked, or the person cancelled, before this could use it is
	/// taken back: the save had finished, but nobody asked for it any longer.
	private func keep(_ saved: PlatformConnectionStore.SavedConnection, generation: Int) async -> Bool {
		didChange()
		guard generation != self.generation || Task.isCancelled else { return true }
		_ = await store.undo(saved)
		didChange()
		return false
	}

	private func insert(_ connection: PlatformConnection) {
		connections.removeAll { $0.id == connection.id }
		connections.append(connection)
		connections.sort(by: PlatformConnectionStore.displayOrder)
	}

	func cancelConnecting() {
		connectTask?.cancel()
	}

	/// Forgets the connection and its token on this Mac. Nothing changes on the platform.
	func disconnect(_ connection: PlatformConnection) {
		guard disconnecting.insert(connection.id).inserted else { return }
		let generation = generation
		Task { [weak self, store] in
			let result = await store.remove(connection.id)
			guard let self else { return }
			if case .success = result { self.didChange() }
			guard generation == self.generation else { return }
			self.disconnecting.remove(connection.id)
			switch result {
			case .success:
				self.connections.removeAll { $0.id == connection.id }
				self.notice = Notice(message: "Disconnected \(connection.name). Its token was removed from this Mac.", isError: false)
			case .failure(let error):
				self.notice = Notice(message: "\(connection.name) couldn't be disconnected. \(error)", isError: true)
			}
		}
	}

	func dismissNotice() {
		notice = nil
	}

	/// Drops everything in memory and stops a connection in progress, as when the vault locks.
	func reset() {
		generation &+= 1
		connectTask?.cancel()
		connectTask = nil
		connecting = nil
		coolifyTask?.cancel()
		coolifyTask = nil
		loadTask?.cancel()
		loadTask = nil
		phase = .idle
		connections = []
		notice = nil
		isLoading = false
		disconnecting = []
	}
}
