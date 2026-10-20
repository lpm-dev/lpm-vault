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
	) async -> Result<(grant: VercelGrant, account: VercelAccount), BrowserConnectError>

	/// One check of a Coolify address and token; see `CoolifyConnector.connect`.
	typealias ConnectCoolify = @Sendable (_ address: String, _ token: String) async -> Result<CoolifyConnection, CoolifyConnectError>

	/// One run of connecting Netlify; see `NetlifyConnector.connect`.
	typealias ConnectNetlify = @Sendable (
		_ session: PlatformSession,
		_ open: @escaping @Sendable (URL) async -> Void
	) async -> Result<NetlifyConnection, BrowserConnectError>

	/// One run of connecting GitHub; see `GitHubConnector.connect`.
	typealias ConnectGitHub = @Sendable (
		_ session: PlatformSession,
		_ open: @escaping @Sendable (URL) async -> Void
	) async -> Result<GitHubConnection, BrowserConnectError>

	/// One run of connecting Cloudflare; see `CloudflareConnector.connect`.
	typealias ConnectCloudflare = @Sendable (
		_ session: PlatformSession,
		_ open: @escaping @Sendable (URL) async -> Void
	) async -> Result<CloudflareConnection, BrowserConnectError>

	/// What the page asks about a Cloudflare login just approved, before
	/// anything already connected changes.
	enum CloudflarePrompt: Equatable {
		/// The person reconnected the login labelled `reconnecting`, but approved another.
		case otherLogin(reconnecting: String)
		/// The login labelled `label` would reach none of `accounts` any more.
		case losesAccounts(label: String, accounts: [String])
	}

	enum CloudflarePromptAnswer: Equatable {
		/// Go on, losing the accounts.
		case proceed
		/// Keep the login being reconnected, and add the other beside it.
		case addSeparately
		/// Put the other login in the place of the one being reconnected.
		case replace
		case cancel
	}

	enum CoolifyOutcome: Equatable {
		case connected(PlatformConnection)
		case failed(String)
		/// It was cancelled, or the vault locked, before the token was saved.
		case dropped
	}

	private(set) var connections: [PlatformConnection] = []
	/// Connections whose token can't be renewed any more, which must be connected again.
	private(set) var expired: Set<PlatformConnection.ID> = []
	private(set) var phase: Phase = .idle
	/// The platform connecting in the browser, one at a time.
	private(set) var connecting: PublishPlatform?
	private(set) var notice: Notice?
	private(set) var isLoading = false
	/// Connections whose disconnect is still running.
	private(set) var disconnecting: Set<PlatformConnection.ID> = []
	/// The generations of retired Cloudflare logins whose tokens are still being revoked.
	private(set) var retiring: [String] = []
	/// Some of `retiring` wait for a sign-in to the Registry that issued their tokens.
	private(set) var retiringAwaitsSignIn = false
	/// Cleanups whose revocation couldn't be confirmed, until the person dismisses them.
	private(set) var markers: [PlatformCleanupMarker] = []
	/// The question about a Cloudflare login just approved, while it waits for an answer.
	private(set) var cloudflarePrompt: CloudflarePrompt?
	/// Counts the questions asked, so an answer meant for one never answers the next.
	private(set) var cloudflarePromptNumber = 0
	/// The connection being connected again, while it is.
	private(set) var reconnecting: PlatformConnection.ID?

	private let store: PlatformConnectionStore
	private let connect: Connect
	private let connectCoolifyTeam: ConnectCoolify
	private let connectNetlifyAccount: ConnectNetlify
	private let connectGitHubAccount: ConnectGitHub
	private let connectCloudflareLogin: ConnectCloudflare
	/// Retires, revokes and discards Cloudflare logins' tokens; without it, there are none to clean up.
	private let credentials: PlatformCredentials?
	private let session: SessionProvider
	private let openURL: @MainActor @Sendable (URL) -> Void
	private let now: @Sendable () -> Date
	/// Called after a connection is saved or removed.
	private let didChange: @MainActor () -> Void
	private var connectTask: Task<Void, Never>?
	private var coolifyTask: Task<CoolifyOutcome, Never>?
	private var loadTask: Task<Void, Never>?
	/// Forgetting dismissed notes, which a listing waits for so they don't come back.
	private var dismissing: Task<Void, Never>?
	private var generation = 0
	private var promptAnswer: CheckedContinuation<CloudflarePromptAnswer, Never>?

	init(
		store: PlatformConnectionStore,
		connect: @escaping Connect = { await VercelConnector().connect(session: $0, open: $1) },
		connectCoolify: @escaping ConnectCoolify = { await CoolifyConnector().connect(address: $0, token: $1) },
		connectNetlify: @escaping ConnectNetlify = { await NetlifyConnector().connect(session: $0, open: $1) },
		connectGitHub: @escaping ConnectGitHub = { await GitHubConnector().connect(session: $0, open: $1) },
		connectCloudflare: ConnectCloudflare? = nil,
		credentials: PlatformCredentials? = nil,
		session: @escaping SessionProvider,
		openURL: @escaping @MainActor @Sendable (URL) -> Void = PlatformConnections.openInBrowser,
		now: @escaping @Sendable () -> Date = { Date() },
		didChange: @escaping @MainActor () -> Void = {}
	) {
		self.store = store
		self.connect = connect
		self.connectCoolifyTeam = connectCoolify
		self.connectNetlifyAccount = connectNetlify
		self.connectGitHubAccount = connectGitHub
		self.credentials = credentials
		self.connectCloudflareLogin = connectCloudflare ?? { [credentials] session, open in
			await CloudflareConnector(discard: { token, connectionID, generation, issuer, clientID in
				_ = await credentials?.discard(
					refreshToken: token, connectionID: connectionID, generation: generation, issuer: issuer, clientID: clientID)
			}).connect(session: session, open: open)
		}
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
		loadTask = Task { [weak self, store, credentials, dismissing, now] in
			await dismissing?.value
			let result = await store.listing(at: now())
			let unsaved = await credentials?.unsavedMarkers ?? []
			let awaitingSignIn = await credentials?.waitingForSignIn ?? []
			guard let self, generation == self.generation, !Task.isCancelled else { return }
			self.isLoading = false
			self.loadTask = nil
			switch result {
			case .success(let listing):
				self.connections = listing.connections
				self.expired = listing.expired
				self.retiring = listing.retiring
				self.retiringAwaitsSignIn = listing.retiring.contains(where: awaitingSignIn.contains)
				let saved = Set(listing.markers.map(\.generation))
				self.markers = listing.markers + unsaved.filter { !saved.contains($0.generation) }
			case .failure(let error): self.notice = Notice(message: "Platform connections couldn't be read. \(error)", isError: true)
			}
		}
	}

	/// Connects a Vercel account in the browser; does nothing while a browser connection runs.
	func connectVercel() {
		connectInBrowser(.vercel, vercelConnection)
	}

	private var vercelConnection: BrowserConnection {
		{ [connect] session, open in
			await connect(session, open).map { connected in
				let grant = connected.grant
				return BrowserConnected(
					account: .vercel(VercelConnectionAccount(
						installationID: grant.installationID, teamID: grant.teamID, userID: grant.userID,
						name: connected.account.name, slug: connected.account.slug)),
					token: grant.accessToken)
			}
		}
	}

	/// Connects a Netlify account in the browser; does nothing while a browser connection runs.
	func connectNetlify() {
		connectInBrowser(.netlify, netlifyConnection)
	}

	private var netlifyConnection: BrowserConnection {
		{ [connectNetlifyAccount] session, open in
			await connectNetlifyAccount(session, open).map { connected in
				let user = connected.user
				return BrowserConnected(
					account: .netlify(NetlifyConnectionAccount(userID: user.id, name: user.name ?? user.email ?? "Netlify account", email: user.email)),
					token: connected.token)
			}
		}
	}

	/// Opens the page installing LPM Vault's GitHub App on more accounts and
	/// repositories, for a GitHub connection.
	func openInstallPage(for connection: PlatformConnection) {
		guard case .github(let account) = connection.account, let url = account.installURL else { return }
		openURL(url)
	}

	/// Connects a GitHub account in the browser; does nothing while a browser connection runs.
	func connectGitHub() {
		connectInBrowser(.github, githubConnection)
	}

	private var githubConnection: BrowserConnection {
		{ [connectGitHubAccount] session, open in
			await connectGitHubAccount(session, open).map { connected in
				let user = connected.user
				return BrowserConnected(
					account: .github(GitHubConnectionAccount(userID: user.id, login: user.login, name: user.name, appSlug: connected.appSlug)),
					token: connected.tokens.accessToken,
					refresh: connected.tokens.refresh(receivedAt: connected.receivedAt, principalID: session.principalID))
			}
		}
	}

	/// Connects a Cloudflare login in the browser; does nothing while a browser connection runs.
	func connectCloudflare() {
		startCloudflare(reconnecting: nil)
	}

	/// Connects an expired connection again in the browser, while
	/// `reconnecting` names it: a Cloudflare login as `reconnectCloudflare`
	/// does, and an account on another browser platform by connecting that
	/// platform again, which replaces the connection when the person approves
	/// the same account. A Coolify team connects again with a token, on its sheet.
	func reconnect(_ connection: PlatformConnection) {
		switch connection.account {
		case .vercel: connectInBrowser(.vercel, reconnecting: connection, vercelConnection)
		case .netlify: connectInBrowser(.netlify, reconnecting: connection, netlifyConnection)
		case .github: connectInBrowser(.github, reconnecting: connection, githubConnection)
		case .cloudflare: reconnectCloudflare(connection)
		case .coolify: break
		}
	}

	/// Connects a Cloudflare login again, as one that expired: a login
	/// that's already connected is connected again in its own place, and
	/// another is added beside this one or put in its place, as the person chooses.
	func reconnectCloudflare(_ connection: PlatformConnection) {
		guard case .cloudflare = connection.account else { return }
		startCloudflare(reconnecting: connection)
	}

	/// Answers the question about the Cloudflare login just approved; with
	/// `number`, only while that question is the one waiting.
	func answerCloudflare(_ answer: CloudflarePromptAnswer, to number: Int? = nil) {
		guard number.map({ $0 == cloudflarePromptNumber }) ?? true else { return }
		let waiting = promptAnswer
		promptAnswer = nil
		cloudflarePrompt = nil
		waiting?.resume(returning: answer)
	}

	/// Asks `prompt` while the connection started in `generation` still
	/// runs; a cancelled or locked connection is answered `.cancel`, as is a
	/// question waiting when it's cancelled.
	private func ask(_ prompt: CloudflarePrompt, generation: Int) async -> CloudflarePromptAnswer {
		guard generation == self.generation, !Task.isCancelled else { return .cancel }
		cloudflarePromptNumber &+= 1
		let number = cloudflarePromptNumber
		return await withTaskCancellationHandler {
			await withCheckedContinuation { continuation in
				promptAnswer?.resume(returning: .cancel)
				promptAnswer = continuation
				cloudflarePrompt = prompt
			}
		} onCancel: {
			Task { @MainActor [weak self] in self?.answerCloudflare(.cancel, to: number) }
		}
	}

	private func startCloudflare(reconnecting target: PlatformConnection?) {
		guard connectTask == nil, let credentials else { return }
		notice = nil
		connecting = .cloudflare
		reconnecting = target?.id
		let generation = generation
		connectTask = Task { [weak self] in
			guard let self else { return }
			defer {
				if generation == self.generation {
					self.connectTask = nil
					self.connecting = nil
					self.reconnecting = nil
					self.phase = .idle
				}
			}
			guard let session = await self.session() else {
				self.notice = Notice(message: BrowserConnectError.signedOut.message(for: .cloudflare, now: self.now()), isError: true)
				return
			}
			guard generation == self.generation, !Task.isCancelled else { return }
			let openURL = self.openURL
			let result = await self.connectCloudflareLogin(session) { [weak self] url in
				// Checked and opened in one turn on the main actor, so a lock can't land in between.
				await MainActor.run {
					guard let self, generation == self.generation, !Task.isCancelled else { return }
					self.phase = .waitingForBrowser
					openURL(url)
				}
			}
			switch result {
			case .success(let connected):
				guard generation == self.generation, !Task.isCancelled else {
					await self.discardCloudflare(connected, credentials: credentials)
					return
				}
				self.phase = .idle
				await self.installCloudflare(connected, reconnecting: target, session: session, generation: generation, credentials: credentials)
			case .failure(.cancelled):
				if generation == self.generation { self.notice = nil }
			case .failure(let error):
				if generation == self.generation { self.notice = Notice(message: error.message(for: .cloudflare, now: self.now()), isError: true) }
			}
			if generation == self.generation { self.load() }
		}
	}

	/// Installs a Cloudflare login just approved, once every question about
	/// it is answered: the generations it replaces are retired and revoked
	/// first, then it's saved. Cancelling, locking or declining before it's
	/// saved revokes only the new grant.
	private func installCloudflare(
		_ new: CloudflareConnection,
		reconnecting target: PlatformConnection?,
		session: PlatformSession,
		generation: Int,
		credentials: PlatformCredentials
	) async {
		// What's stored decides, not the page's list, which may not be loaded: a generation left unretired would never be revoked.
		var replacing: [PlatformConnection] = []
		switch await stored(new.connectionID) {
		case .connection(let own):
			replacing.append(own)
		case .unreadable:
			// It can't be revoked; connecting again mends it, and a note says it may still be authorized.
			await credentials.note(PlatformCleanupMarker(platform: .cloudflare, generation: CloudflareConnectionAccount.makeGeneration(), createdAt: now()))
		case .absent:
			break
		case .failed(let message):
			notice = Notice(message: message, isError: true)
			return await discardCloudflare(new, credentials: credentials)
		}
		// The login being reconnected, when the person approved another: what became of it is said once the new one is saved.
		var other: (name: String, replaced: Bool)?
		if let target, target.id != new.connectionID, case .connection(let current) = await stored(target.id) {
			other = (current.name, false)
			// A login that has its own connection is connected again there, asking nothing.
			if replacing.isEmpty {
				switch await ask(.otherLogin(reconnecting: current.name), generation: generation) {
				case .addSeparately: break
				case .replace:
					replacing.append(current)
					other = (current.name, true)
				case .proceed, .cancel: return await discardCloudflare(new, credentials: credentials)
				}
			}
		}
		let reached = Set(new.accounts.map(\.id))
		for old in replacing {
			guard case .cloudflare(let account) = old.account else { continue }
			let lost = account.accounts.filter { !reached.contains($0.id) }.map(\.name)
			guard !lost.isEmpty else { continue }
			guard await ask(.losesAccounts(label: old.name, accounts: lost), generation: generation) == .proceed else {
				return await discardCloudflare(new, credentials: credentials)
			}
		}
		guard generation == self.generation, !Task.isCancelled else { return await discardCloudflare(new, credentials: credentials) }

		let label: String
		if let own = replacing.first(where: { $0.id == new.connectionID }), case .cloudflare(let account) = own.account {
			label = account.label
		} else {
			guard case .success(let salt) = await store.loginLabelSalt(),
				case .success(let taken) = await store.cloudflareLabels(except: new.connectionID)
			else {
				self.notice = Notice(message: "Cloudflare connected, but the connection couldn't be saved.", isError: true)
				return await discardCloudflare(new, credentials: credentials)
			}
			label = CloudflareLogin.defaultLabel(for: new.login, accounts: new.accounts, salt: salt, taken: taken)
		}
		// The generations it replaces are revoked first: a crash before the save costs one more approval, never an unrevoked family.
		for old in replacing {
			guard case .cloudflare(let account) = old.account else { continue }
			switch await credentials.retire(old.id, generation: account.generation) {
			case .success(.entry(let entry)):
				_ = await credentials.revokeNow(entry)
			case .success(.ended), .success(.gone):
				break
			case .failure(let error):
				// Saving over a generation nothing will revoke would strand it: nothing changes, and the new grant goes.
				notice = Notice(
					message: "Cloudflare connected, but \(old.name)'s earlier connection couldn't be set aside to revoke, so nothing changed. \(error.message(for: .cloudflare))",
					isError: true)
				return await discardCloudflare(new, credentials: credentials)
			}
		}
		let account = CloudflareConnectionAccount(
			login: new.login, label: label, accounts: new.accounts, issuer: new.issuer, clientID: new.clientID, generation: new.generation)
		let refresh = new.grant.tokens.refresh(receivedAt: new.receivedAt, principalID: session.principalID)
		switch await store.saveUndoably(.cloudflare(account), accessToken: new.grant.tokens.accessToken, refresh: refresh, at: now()) {
		case .success(let saved):
			guard await keep(saved, generation: generation) else { return await discardCloudflare(new, credentials: credentials) }
			for old in replacing { connections.removeAll { $0.id == old.id } }
			insert(saved.connection)
			let name = saved.connection.name
			let again = replacing.contains { $0.id == new.connectionID }
			notice = switch other {
			case nil: Notice(message: "Connected \(name) on Cloudflare.", isError: false)
			case (let target, true)?: Notice(message: "Connected \(name) on Cloudflare in \(target)'s place.", isError: false)
			case (let target, false)? where again:
				Notice(message: "Connected \(name) on Cloudflare again. You approved \(name), not \(target), which still needs reconnecting.", isError: false)
			case (let target, false)?:
				Notice(message: "Connected \(name) on Cloudflare, beside \(target), which still needs reconnecting.", isError: false)
			}
		case .failure(.cancelled):
			await discardCloudflare(new, credentials: credentials)
		case .failure(let error):
			notice = Notice(message: "Cloudflare connected, but the connection couldn't be saved. \(error)", isError: true)
			await discardCloudflare(new, credentials: credentials)
		}
	}

	private enum StoredConnection {
		case connection(PlatformConnection)
		/// Nothing is stored, or what is was already retired.
		case absent
		case unreadable
		case failed(String)
	}

	/// The connection stored under `id`, as a reconnect decides by it.
	private func stored(_ id: PlatformConnection.ID) async -> StoredConnection {
		switch await store.record(for: id) {
		case .success(let record): .connection(record.connection)
		case .failure(.notFound), .failure(.retired): .absent
		case .failure(.unreadable): .unreadable
		case .failure(.newerVersion): .failed("A newer LPM Vault saved this Cloudflare login's connection, so this one leaves it alone.")
		case .failure(let error): .failed("Cloudflare connected, but the connections on this Mac couldn't be read. \(error)")
		}
	}

	/// Revokes a Cloudflare grant that won't be kept. One whose revocation
	/// isn't confirmed leaves a note on the page, which says what to do.
	private func discardCloudflare(_ new: CloudflareConnection, credentials: PlatformCredentials) async {
		_ = await credentials.discard(
			refreshToken: new.grant.expiry.refreshToken, connectionID: new.connectionID, generation: new.generation,
			issuer: new.issuer, clientID: new.clientID)
	}

	/// What to do about `count` Cloudflare logins whose access LPM Vault couldn't confirm it revoked.
	static func unrevokedMessage(count: Int) -> String {
		let which = count == 1
			? "a Cloudflare login's access was revoked, so it may still be authorized"
			: "the access of \(count) Cloudflare logins was revoked, so they may still be authorized"
		return "LPM Vault couldn't confirm that \(which). To end it, remove LPM Vault under My Profile → Access Management → Connected Applications on Cloudflare. That also ends its access from other Macs, and any connection made since."
	}

	/// Gives a Cloudflare login a name the person chose, unique among connected logins.
	func rename(_ connection: PlatformConnection, to text: String) async -> String? {
		guard case .cloudflare = connection.account else { return nil }
		let label: String
		switch CloudflareLogin.label(from: text) {
		case .success(let value): label = value
		case .failure(let problem): return problem.message
		}
		switch await store.relabel(connection.id, to: label) {
		case .success(let relabeled):
			insert(relabeled)
			didChange()
			return nil
		case .failure(.labelTaken):
			return "Another connected Cloudflare login is called \(label). Choose another name."
		case .failure(let error):
			return "The name couldn't be saved. \(error)"
		}
	}

	/// The other connected logins that reach a Cloudflare login's accounts,
	/// by account name, which go on publishing there once it's disconnected.
	func otherLogins(reaching connection: PlatformConnection) -> [(account: String, logins: [String])] {
		guard case .cloudflare(let login) = connection.account else { return [] }
		var reaching: [String: [String]] = [:]
		// One that no longer works publishes nowhere.
		for other in connections where other.id != connection.id && !expired.contains(other.id) {
			guard case .cloudflare(let otherLogin) = other.account, otherLogin.issuer == login.issuer else { continue }
			for account in otherLogin.accounts { reaching[account.id, default: []].append(other.name) }
		}
		return login.accounts.compactMap { account in reaching[account.id].map { (account.name, $0) } }
	}

	/// Forgets the notes of Cloudflare logins whose revocation couldn't be confirmed.
	func dismissMarkers() {
		let generations = Set(markers.map(\.generation))
		guard !generations.isEmpty else { return }
		markers = []
		dismissing = Task { [store, credentials, dismissing] in
			await dismissing?.value
			await credentials?.forgetUnsavedMarkers(generations)
			for generation in generations { _ = await store.dismissMarker(generation) }
		}
	}

	/// What a browser connection connected, ready to save: the token, and
	/// how it renews when the platform's tokens expire.
	private struct BrowserConnected: Sendable {
		let account: PlatformConnection.Account
		let token: String
		var refresh: PlatformTokenRefresh?
	}

	/// One run of connecting a platform in the browser, which opens the
	/// platform's page with the `open` it's given.
	private typealias BrowserConnection = @Sendable (
		_ session: PlatformSession,
		_ open: @escaping @Sendable (URL) async -> Void
	) async -> Result<BrowserConnected, BrowserConnectError>

	/// Runs `run` with the LPM session, then saves what it connected, in
	/// `target`'s place when the person approved its account again. Without
	/// a session nothing starts. The page opens only while the connection is
	/// still wanted, and a connection the vault locked or the person cancelled
	/// before it could be used is never kept.
	private func connectInBrowser(_ platform: BrowserPlatform, reconnecting target: PlatformConnection? = nil, _ run: @escaping BrowserConnection) {
		guard connectTask == nil else { return }
		notice = nil
		connecting = platform.publishPlatform
		reconnecting = target?.id
		let generation = generation
		connectTask = Task { [weak self] in
			guard let self else { return }
			defer {
				if generation == self.generation {
					self.connectTask = nil
					self.connecting = nil
					self.reconnecting = nil
					self.phase = .idle
				}
			}
			let outcome: Result<BrowserConnected, BrowserConnectError>
			if let session = await self.session() {
				guard generation == self.generation, !Task.isCancelled else { return }
				let openURL = self.openURL
				outcome = await run(session) { [weak self] url in
					// Checked and opened in one turn on the main actor, so a lock can't land in between.
					await MainActor.run {
						guard let self, generation == self.generation, !Task.isCancelled else { return }
						self.phase = .waitingForBrowser
						openURL(url)
					}
				}
			} else {
				outcome = .failure(.signedOut)
			}
			guard generation == self.generation else { return }
			switch outcome {
			case .success(let connected):
				switch await self.store.saveUndoably(connected.account, accessToken: connected.token, refresh: connected.refresh, at: self.now()) {
				case .success(let saved):
					guard await self.keep(saved, generation: generation) else { return }
					let connection = saved.connection
					self.insert(connection)
					self.notice = Notice(message: Self.connectedMessage(connection, on: platform, reconnecting: target), isError: false)
				case .failure(.cancelled):
					self.notice = nil
				case .failure(let error):
					guard generation == self.generation else { return }
					self.notice = Notice(message: "\(platform.displayName) connected, but the connection couldn't be saved. \(error)", isError: true)
				}
			case .failure(.cancelled):
				self.notice = nil
			case .failure(let error):
				self.notice = Notice(message: error.message(for: platform, now: self.now()), isError: true)
			}
		}
	}

	/// What connecting `connection` in the browser says, naming the
	/// connection being reconnected when the person approved another account.
	private static func connectedMessage(_ connection: PlatformConnection, on platform: BrowserPlatform, reconnecting target: PlatformConnection?) -> String {
		switch target {
		case nil: "Connected \(connection.name) on \(platform.displayName)."
		case let target? where target.id == connection.id: "Connected \(connection.name) on \(platform.displayName) again."
		case let target?: "Connected \(connection.name) on \(platform.displayName), beside \(target.name), which still needs reconnecting."
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
		expired.remove(connection.id)
		connections.append(connection)
		connections.sort(by: PlatformConnectionStore.displayOrder)
	}

	func cancelConnecting() {
		answerCloudflare(.cancel)
		connectTask?.cancel()
	}

	/// Forgets the connection and its token on this Mac. Nothing changes on
	/// the platform, but for a Cloudflare login, whose access is revoked
	/// through lpm.dev: its cleanup entry is written first, and goes on
	/// revoking it until lpm.dev confirms.
	func disconnect(_ connection: PlatformConnection) {
		guard disconnecting.insert(connection.id).inserted else { return }
		let generation = generation
		if case .cloudflare(let login) = connection.account, let credentials {
			Task { [weak self] in
				let retired = await credentials.retire(connection.id, generation: login.generation)
				var revocation = PlatformRevocation.revoked
				if case .success(.entry(let entry)) = retired { revocation = await credentials.revokeNow(entry) }
				guard let self else { return }
				self.didChange()
				guard generation == self.generation else { return }
				self.disconnecting.remove(connection.id)
				switch retired {
				case .success(.gone):
					// It was connected again meanwhile, or disconnected already: what's stored now is shown.
					break
				case .success(.ended):
					self.connections.removeAll { $0.id == connection.id }
					self.expired.remove(connection.id)
					self.notice = Notice(message: "Disconnected \(connection.name). Cloudflare had already ended LPM Vault's access to it.", isError: false)
				case .success(.entry):
					self.connections.removeAll { $0.id == connection.id }
					self.expired.remove(connection.id)
					self.notice = switch revocation {
					case .revoked:
						Notice(message: "Disconnected \(connection.name). LPM Vault's access to it on Cloudflare has ended.", isError: false)
					case .pending:
						Notice(
							message: "Disconnected \(connection.name). LPM Vault goes on revoking its access on Cloudflare until lpm.dev confirms it.",
							isError: false)
					case .waitingForSignIn:
						Notice(message: "Disconnected \(connection.name). Sign in to LPM to finish revoking its access on Cloudflare.", isError: false)
					case .unconfirmed:
						Notice(
							message: "Disconnected \(connection.name), but lpm.dev couldn't confirm that LPM Vault's access to it on Cloudflare ended.",
							isError: true)
					}
				case .failure(let error):
					self.notice = Notice(message: "\(connection.name) couldn't be disconnected. \(error.message(for: .cloudflare))", isError: true)
				}
				self.load()
			}
			return
		}
		Task { [weak self, store] in
			let result = await store.remove(connection.id)
			guard let self else { return }
			if case .success = result { self.didChange() }
			guard generation == self.generation else { return }
			self.disconnecting.remove(connection.id)
			switch result {
			case .success:
				self.connections.removeAll { $0.id == connection.id }
				self.expired.remove(connection.id)
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
		answerCloudflare(.cancel)
		reconnecting = nil
		retiring = []
		retiringAwaitsSignIn = false
		markers = []
		connectTask?.cancel()
		connectTask = nil
		connecting = nil
		coolifyTask?.cancel()
		coolifyTask = nil
		loadTask?.cancel()
		loadTask = nil
		phase = .idle
		connections = []
		expired = []
		notice = nil
		isLoading = false
		disconnecting = []
	}
}
