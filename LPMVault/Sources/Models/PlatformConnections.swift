import AppKit
import Foundation
import Observation

/// The platform connections the Platforms page shows and changes.
@MainActor
@Observable
final class PlatformConnections {
	enum Phase: Equatable {
		case idle
		/// Vercel's page is open in the browser.
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

	private(set) var connections: [PlatformConnection] = []
	private(set) var phase: Phase = .idle
	private(set) var notice: Notice?
	private(set) var isLoading = false
	/// Connections whose disconnect is still running.
	private(set) var disconnecting: Set<PlatformConnection.ID> = []

	private let store: PlatformConnectionStore
	private let connect: Connect
	private let session: SessionProvider
	private let openURL: @Sendable (URL) async -> Void
	private let now: @Sendable () -> Date
	private var connectTask: Task<Void, Never>?
	private var loadTask: Task<Void, Never>?
	private var generation = 0

	init(
		store: PlatformConnectionStore,
		connect: @escaping Connect = { await VercelConnector().connect(session: $0, open: $1) },
		session: @escaping SessionProvider,
		openURL: @escaping @Sendable (URL) async -> Void = PlatformConnections.openInBrowser,
		now: @escaping @Sendable () -> Date = { Date() }
	) {
		self.store = store
		self.connect = connect
		self.session = session
		self.openURL = openURL
		self.now = now
	}

	var isConnecting: Bool { connectTask != nil }

	nonisolated static let openInBrowser: @Sendable (URL) async -> Void = { url in
		await MainActor.run { _ = NSWorkspace.shared.open(url) }
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

	/// Connects a Vercel account in the browser; a second call while one runs does nothing.
	func connectVercel() {
		guard connectTask == nil else { return }
		notice = nil
		let generation = generation
		connectTask = Task { [weak self] in
			guard let self else { return }
			defer {
				if generation == self.generation {
					self.connectTask = nil
					self.phase = .idle
				}
			}
			guard let session = await self.session() else {
				self.notice = Notice(message: VercelConnectError.signedOut.message, isError: true)
				return
			}
			guard generation == self.generation, !Task.isCancelled else { return }
			let openURL = self.openURL
			let result = await self.connect(session) { [weak self] url in
				await MainActor.run {
					guard let self, generation == self.generation else { return }
					self.phase = .waitingForBrowser
				}
				await openURL(url)
			}
			guard generation == self.generation else { return }
			switch result {
			case .success(let connected):
				switch await self.store.save(connected.grant, account: connected.account, at: self.now()) {
				case .success(let connection):
					guard generation == self.generation else { return }
					self.connections.removeAll { $0.id == connection.id }
					self.connections.append(connection)
					self.connections.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
					self.notice = Notice(message: "Connected \(connection.name) on Vercel.", isError: false)
				case .failure(let error):
					guard generation == self.generation else { return }
					self.notice = Notice(message: "Vercel connected, but the connection couldn't be saved. \(error)", isError: true)
				}
			case .failure(.cancelled):
				self.notice = nil
			case .failure(let error):
				self.notice = Notice(message: error.message, isError: true)
			}
		}
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
			guard let self, generation == self.generation else { return }
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
		loadTask?.cancel()
		loadTask = nil
		phase = .idle
		connections = []
		notice = nil
		isLoading = false
		disconnecting = []
	}
}
