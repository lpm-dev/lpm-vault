import CryptoKit
import Foundation
import os
import Testing
@testable import LPMVault

@MainActor
struct PublishSessionTests {
	private let keychain = MockKeychainService()
	private let api = FakeVercelAPI()
	private let vault = "publish-session-vault"
	private let values = ValuesBox(["production": ["API_TOKEN": "tok", "NEXT_PUBLIC_URL": "https://x"], "staging": ["A": "1"]])
	private let confirmations = Confirmations()
	private let reads = SnapshotReads()

	private var publishing: PublishingStore { PublishingStore(service: keychain) }
	private var connections: PlatformConnectionStore { PlatformConnectionStore(service: keychain) }
	private let rules = ProjectEnvSchemaOverview(
		rules: [ProjectEnvSchemaOverview.Rule(key: "NEXT_PUBLIC_URL", isPublic: true, source: nil, badges: [])], groups: [])

	private func connect(team: String = "team_acme") async throws {
		_ = try await connections.save(
			VercelGrant(accessToken: "vca_1", installationID: "icfg_1", teamID: team, userID: "u_1")!,
			account: VercelAccount(name: "Acme", slug: "acme"), at: Date()).get()
	}

	private func session(
		saved: PublishDestination? = nil,
		source: String = "production",
		client: (@Sendable (String) -> any VercelClientProtocol)? = nil
	) -> PublishSession {
		let values = values
		let confirmations = confirmations
		let api = api
		let reads = reads
		return PublishSession(
			vaultID: vault, projectName: "demo-api", environments: ["production", "staging"], sourceEnvironment: source,
			saved: saved,
			dependencies: .init(
				snapshot: { [rules] environment, contents in
					reads.contents.append(contents)
					return values.get(environment).map { .init(values: $0, rules: .known(rules), check: nil) }
				},
				confirm: { confirmations.ask($0) },
				publishing: publishing,
				connections: connections,
				vercel: client ?? { _ in api },
				now: { Date(timeIntervalSince1970: 1_760_000_000) }))
	}

	private func waitUntil(_ condition: () -> Bool) async throws {
		for _ in 0..<400 where !condition() { try await Task.sleep(for: .milliseconds(5)) }
		#expect(condition())
	}

	private func chooseProduction(_ session: PublishSession) async throws {
		session.start()
		try await waitUntil { session.connectionID != nil && session.vercel?.projects.value != nil }
		session.vercel?.projectID = "prj_api"
		session.vercel?.environment = .production
		#expect(session.canReview)
		session.loadReview()
		try await waitUntil { session.review != nil || session.reviewError != nil }
	}

	@Test("a new destination is chosen, reviewed, confirmed, published, and saved with what was published")
	func publishesNewDestination() async throws {
		try await connect()
		let session = session()
		try await chooseProduction(session)
		let review = try #require(session.review)
		#expect(!review.isSaved && review.plan.rows.map(\.key) == ["API_TOKEN", "NEXT_PUBLIC_URL"])
		#expect(review.selection.keys == ["API_TOKEN", "NEXT_PUBLIC_URL"])
		session.publish()
		try await waitUntil { session.step == .results }
		#expect(confirmations.reasons == ["Publish 2 variables to demo-api / Production on Vercel"])
		#expect(reads.contents == [.checked, .unchecked], "The publish compares the values and rules with its review's, without checking them again")
		#expect(Set(api.createdWrites.map(\.key)) == ["API_TOKEN", "NEXT_PUBLIC_URL"])
		#expect(session.results?.publishedCount == 2)
		let saved = try await publishing.destinations(of: vault).get()
		#expect(saved.count == 1 && saved.first?.sourceEnvironment == "production")
		guard case .vercel(let target)? = saved.first?.target else { Issue.record("Not a Vercel destination"); return }
		#expect(target.accountID == "team_acme" && target.teamID == "team_acme" && target.environment == .production)
		let history = try await publishing.history(of: try #require(saved.first).id, in: vault).get()
		#expect(Set(history.keys.keys) == ["API_TOKEN", "NEXT_PUBLIC_URL"] && history.keys["NEXT_PUBLIC_URL"]?.publishedAsSecret == false)
		#expect(session.saved?.id == saved.first?.id)
	}

	@Test("a Netlify connection isn't offered for publishing yet, so its token never reaches another platform's client")
	func netlifyNotOffered() async throws {
		try await connect()
		_ = try await connections.save(
			.netlify(NetlifyConnectionAccount(userID: "5f1a2b3c4d5e6f7a8b9c0d1e", name: "Tolga", email: nil)),
			accessToken: "nfo_secret", at: Date()).get()
		let tokens = TokenLog()
		let api = api
		let session = session(client: { token in
			tokens.append(token)
			return api
		})
		session.start()
		try await waitUntil { session.vercel?.projects.value != nil }
		#expect(session.connections.value?.map(\.id) == ["vercel.team_acme"])
		#expect(session.connectionID == "vercel.team_acme", "The only connection that can publish is chosen")
		#expect(Set(tokens.values) == ["vca_1"])
	}

	@Test("a saved destination opens on its review, with what this Mac published there")
	func savedOpensOnReview() async throws {
		try await connect()
		let first = session()
		try await chooseProduction(first)
		first.publish()
		try await waitUntil { first.step == .results }
		let saved = try #require(try await publishing.destinations(of: vault).get().first)

		api.variableList = VercelVariableList(variables: [vercelVariable("API_TOKEN", updatedAt: Date(timeIntervalSince1970: 1_760_000_100))], hiddenProductionCount: 0)
		let again = session(saved: saved)
		#expect(again.step == .review)
		again.start()
		try await waitUntil { again.review != nil || again.reviewError != nil }
		let review = try #require(again.review)
		#expect(review.isSaved && !review.needsSave && review.lastPublishedAt != nil)
		#expect(review.plan.row("API_TOKEN")?.status.isUpToDate == true, "Vercel has the value this Mac published")
		#expect(review.plan.row("API_TOKEN")?.operation == .replace(remoteID: "env_API_TOKEN"))
	}

	@Test("values changed after the review aren't sent, and Touch ID isn't asked")
	func staleValues() async throws {
		try await connect()
		let session = session()
		try await chooseProduction(session)
		values.set("production", ["API_TOKEN": "rotated", "NEXT_PUBLIC_URL": "https://x"])
		session.publish()
		try await waitUntil { !session.isPublishing }
		#expect(session.reviewError?.contains("API_TOKEN changed since this review") == true)
		#expect(confirmations.reasons.isEmpty && api.createdWrites.isEmpty)
		#expect(try await publishing.destinations(of: vault).get().isEmpty)
	}

	@Test("declining Touch ID sends nothing")
	func declined() async throws {
		try await connect()
		confirmations.approve = false
		let session = session()
		try await chooseProduction(session)
		session.publish()
		try await waitUntil { !session.isPublishing }
		#expect(confirmations.reasons.count == 1 && api.createdWrites.isEmpty && session.step == .review)
	}

	@Test("a publish that nothing got through saves no new destination, and says to reconnect")
	func nothingPublished() async throws {
		try await connect()
		api.createFailure = .unauthorized
		let session = session()
		try await chooseProduction(session)
		session.publish()
		try await waitUntil { session.step == .results }
		#expect(session.results?.needsReconnect == true && session.results?.publishedCount == 0)
		#expect(try await publishing.destinations(of: vault).get().isEmpty)
	}

	@Test("a variable Vercel shares with another environment waits until the person publishes it anyway")
	func sharedNeedsConfirmation() async throws {
		try await connect()
		api.variableList = VercelVariableList(variables: [vercelVariable("API_TOKEN", targets: [.production, .preview])], hiddenProductionCount: 0)
		let session = session()
		try await chooseProduction(session)
		#expect(!session.isSelected("API_TOKEN"))
		#expect(!session.set("API_TOKEN", selected: true))
		#expect(session.set("API_TOKEN", selected: true, confirmed: true))
		#expect(session.isSelected("API_TOKEN"))
	}

	@Test("choosing the place a saved destination already publishes to reuses it, with its exclusions")
	func reusesSavedPlace() async throws {
		try await connect()
		let existing = PublishDestination(
			sourceEnvironment: "staging",
			target: .vercel(VercelPublishTarget(teamID: "team_acme", accountID: "team_acme", teamName: "Acme", projectID: "prj_api",
				projectName: "demo-api", environment: .production)),
			excludedKeys: ["API_TOKEN"], createdAt: Date(timeIntervalSince1970: 1_750_000_000))
		_ = try await publishing.save(existing, to: vault).get()
		let session = session()
		try await chooseProduction(session)
		let review = try #require(session.review)
		#expect(review.isSaved && review.needsSave && review.destination.id == existing.id)
		#expect(review.destination.sourceEnvironment == "production")
		#expect(review.plan.row("API_TOKEN")?.holds == [.excluded])
	}

	@Test("a saved destination can't be moved onto another saved destination's place")
	func refusesCollision() async throws {
		try await connect()
		func destination(_ environment: VercelPublishTarget.Environment) -> PublishDestination {
			PublishDestination(
				sourceEnvironment: "production",
				target: .vercel(VercelPublishTarget(teamID: "team_acme", accountID: "team_acme", teamName: "Acme", projectID: "prj_api",
					projectName: "demo-api", environment: environment)),
				createdAt: Date(timeIntervalSince1970: 1_750_000_000))
		}
		let preview = destination(.preview)
		_ = try await publishing.save(destination(.production), to: vault).get()
		_ = try await publishing.save(preview, to: vault).get()
		let session = session(saved: preview)
		session.start()
		try await waitUntil { session.review != nil || session.reviewError != nil }
		session.showDestination()
		session.vercel?.environment = .production
		session.loadReview()
		try await waitUntil { session.review != nil || session.reviewError != nil }
		#expect(session.reviewError?.contains("Another saved destination already publishes") == true)
	}

	@Test("a saved destination whose Vercel account isn't connected here says so")
	func missingConnection() async throws {
		let saved = PublishDestination(
			sourceEnvironment: "production",
			target: .vercel(VercelPublishTarget(teamID: "team_other", accountID: "team_other", teamName: "Other Inc", projectID: "prj_api",
				projectName: "demo-api", environment: .production)),
			createdAt: Date(timeIntervalSince1970: 1_750_000_000))
		_ = try await publishing.save(saved, to: vault).get()
		let session = session(saved: saved)
		session.start()
		try await waitUntil { session.reviewError != nil }
		#expect(session.reviewError?.contains("Other Inc on Vercel, which isn't connected on this Mac") == true)
	}

	@Test("a production review stops while Vercel hides production variables from the connection")
	func hiddenProduction() async throws {
		try await connect()
		api.variableList = VercelVariableList(variables: [], hiddenProductionCount: 2)
		let session = session()
		try await chooseProduction(session)
		#expect(session.review == nil && session.reviewError?.contains("hides 2 production variables") == true)
	}

	@Test("a revoked connection's projects and review say to connect Vercel again")
	func revokedConnectionGuidance() async throws {
		try await connect()
		let route = PlatformHTTPStub.platform { _ in VercelPublishingTests.revokedToken }
		let session = session(client: { VercelClient(token: $0, baseURL: route.baseURL, session: route.session) })
		session.start()
		try await waitUntil { session.vercel.map { $0.projects != .idle && $0.projects != .loading } == true }
		#expect(session.vercel?.projects == .failed(VercelPublishing.message(.unauthorized)))
		session.vercel?.projectID = "prj_api"
		session.vercel?.environment = .production
		session.loadReview()
		try await waitUntil { session.reviewError != nil }
		#expect(session.reviewError == VercelPublishing.message(.unauthorized))
	}

	@Test("a saved destination opens on its review without listing the account's projects, and lists them once to change it")
	func savedSkipsProjects() async throws {
		try await connect()
		let first = session()
		try await chooseProduction(first)
		first.publish()
		try await waitUntil { first.step == .results }
		let saved = try #require(try await publishing.destinations(of: vault).get().first)
		let before = api.projectListingCount
		let again = session(saved: saved)
		again.start()
		try await waitUntil { again.review != nil || again.reviewError != nil }
		#expect(api.projectListingCount == before)
		again.showDestination()
		try await waitUntil { again.vercel?.projects.value != nil }
		#expect(api.projectListingCount == before + 1)
	}

	@Test("changing a destination's source forgets exclusions of keys the new source lacks, unless the destination changed meanwhile")
	func staleExclusionsAfterSourceChange() async throws {
		try await connect()
		values.set("production", ["NEW": "n"])
		values.set("staging", ["OLD": "o", "NEW": "s"])
		let existing = PublishDestination(
			sourceEnvironment: "staging",
			target: .vercel(VercelPublishTarget(teamID: "team_acme", accountID: "team_acme", teamName: "Acme", projectID: "prj_api",
				projectName: "demo-api", environment: .production)),
			excludedKeys: ["OLD"], createdAt: Date(timeIntervalSince1970: 1_750_000_000))
		_ = try await publishing.save(existing, to: vault).get()
		let session = session(saved: existing)
		session.start()
		try await waitUntil { session.review != nil || session.reviewError != nil }
		session.sourceEnvironment = "production"
		session.loadReview()
		try await waitUntil { session.review != nil && !session.isLoadingReview }
		session.publish()
		try await waitUntil { session.step == .results }
		#expect(session.results?.recordFailure == nil)
		#expect(try await publishing.destinations(of: vault).get().first?.excludedKeys == [])

		let stored = try #require(try await publishing.destinations(of: vault).get().first)
		let again = self.session(saved: stored)
		again.start()
		try await waitUntil { again.review != nil || again.reviewError != nil }
		again.sourceEnvironment = "staging"
		again.loadReview()
		try await waitUntil { again.review != nil && !again.isLoadingReview }
		var changed = try #require(try await publishing.destinations(of: vault).get().first)
		changed.excludedKeys = ["MEANWHILE"]
		changed.updatedAt = Date(timeIntervalSince1970: 1_770_000_000)
		_ = try await publishing.save(changed, to: vault).get()
		again.publish()
		try await waitUntil { again.step == .results }
		#expect(again.results?.recordFailure?.contains("changed") == true)
		#expect(try await publishing.destinations(of: vault).get().first?.excludedKeys == ["MEANWHILE"])
	}

	@Test("the values a review reads come with the rules and check made for those same values")
	func reviewReadsOneSnapshot() async throws {
		try await connect()
		let gate = AsyncFlag()
		let current = SnapshotBox(values: ["PORT": "8080"], check: .init(problems: [:]))
		let failing = ProjectEnvValueCheck.Environment(problems: ["PORT": [.init(key: "PORT", kind: .format("port"))]])
		let session = PublishSession(
			vaultID: vault, projectName: "demo-api", environments: ["production"], sourceEnvironment: "production",
			dependencies: .init(
				snapshot: { [rules] _, _ in
					await gate.wait()
					return .init(values: current.values, rules: .known(rules), check: current.check)
				},
				confirm: { _ in true },
				publishing: publishing, connections: connections,
				vercel: { [api] _ in api }))
		session.start()
		try await waitUntil { session.vercel?.projects.value != nil }
		session.vercel?.projectID = "prj_api"
		session.vercel?.environment = .production
		session.loadReview()
		try await Task.sleep(for: .milliseconds(30))
		current.values = ["PORT": "not-a-port"]
		current.check = failing
		await gate.open()
		try await waitUntil { session.review != nil || session.reviewError != nil }
		let row = try #require(session.review?.plan.row("PORT"))
		#expect(row.holds.contains { if case .failsRules = $0 { true } else { false } } && !row.isSelectedByDefault)
	}

	@Test("cancelling the sheet while it starts stops everything it would start")
	func cancelDuringStart() async throws {
		try await connect()
		let saved = PublishDestination(
			sourceEnvironment: "production",
			target: .vercel(VercelPublishTarget(teamID: "team_acme", accountID: "team_acme", teamName: "Acme", projectID: "prj_api",
				projectName: "demo-api", environment: .production)),
			createdAt: Date(timeIntervalSince1970: 1_750_000_000))
		_ = try await publishing.save(saved, to: vault).get()
		let entered = DispatchSemaphore(value: 0)
		let held = DispatchSemaphore(value: 0)
		keychain.beforeAppItemListing = {
			entered.signal()
			_ = held.wait(timeout: .now() + 30)
		}
		let session = session(saved: saved)
		session.start()
		await withCheckedContinuation { continuation in
			Thread.detachNewThread {
				_ = entered.wait(timeout: .now() + 30)
				continuation.resume()
			}
		}
		keychain.beforeAppItemListing = nil
		session.cancel()
		held.signal()
		try await Task.sleep(for: .milliseconds(100))
		#expect(api.listingCount == 0 && api.projectListingCount == 0 && api.customListingCount == 0)
		#expect(session.review == nil && session.connections.value == nil)
	}

	@Test("a variable changed on Vercel after its review isn't replaced, so the review has to be made again")
	func refusesDriftSinceReview() async throws {
		try await connect()
		values.set("production", ["SHARED": "s", "RENAMED": "r", "EDITED": "e", "ADDED": "a"])
		api.variableList = VercelVariableList(variables: [
			vercelVariable("SHARED", targets: [.preview]), vercelVariable("RENAMED"), vercelVariable("EDITED"),
		], hiddenProductionCount: 0)
		let session = session()
		session.start()
		try await waitUntil { session.vercel?.projects.value != nil }
		session.vercel?.projectID = "prj_api"
		session.vercel?.environment = .preview
		session.loadReview()
		try await waitUntil { session.review != nil }
		for key in ["SHARED", "RENAMED", "EDITED", "ADDED"] { session.set(key, selected: true, confirmed: true) }
		session.vercel?.environment = .production
		session.loadReview()
		try await waitUntil { session.review != nil && !session.isLoadingReview }
		for key in ["SHARED", "RENAMED", "EDITED", "ADDED"] { session.set(key, selected: true, confirmed: true) }
		api.variableList = VercelVariableList(variables: [
			vercelVariable("SHARED", targets: [.production, .preview]),
			VercelEnvironmentVariable(id: "env_RENAMED", key: "RENAMED_AGAIN", kind: .sensitive, isSecret: true, targets: [.production],
				customEnvironmentIDs: [], gitBranch: nil, updatedAt: Date(timeIntervalSince1970: 1_760_000_000)),
			vercelVariable("EDITED", updatedAt: Date(timeIntervalSince1970: 1_760_000_900)),
			vercelVariable("ADDED"),
		], hiddenProductionCount: 0)
		session.publish()
		try await waitUntil { session.step == .results }
		let outcomes = Dictionary(uniqueKeysWithValues: session.results?.rows.map { ($0.key, $0.outcome) } ?? [])
		#expect(outcomes["RENAMED"] == .failed("Removed on Vercel since this review. Review again."))
		#expect(outcomes["EDITED"] == .failed("Changed on Vercel since this review. Review again."))
		#expect(outcomes["ADDED"] == .failed("Added on Vercel since this review. Review again."))
		#expect(api.replacedValues.isEmpty && api.createdWrites.isEmpty)
		#expect(outcomes["SHARED"] == .failed("Added on Vercel since this review. Review again."), "Shared with Production since: it's there now")
	}

	@Test("reopening a saved destination reads its custom environments once and lists no projects")
	func savedReadsCustomEnvironmentsOnce() async throws {
		try await connect()
		let first = session()
		try await chooseProduction(first)
		first.publish()
		try await waitUntil { first.step == .results }
		let saved = try #require(try await publishing.destinations(of: vault).get().first)
		let (projects, customs) = (api.projectListingCount, api.customListingCount)
		let again = session(saved: saved)
		again.start()
		try await waitUntil { again.review != nil || again.reviewError != nil }
		#expect(api.projectListingCount == projects && api.customListingCount == customs + 1)
	}

	@Test("two Vercel teams with one name are told apart, and the chosen one's token is used")
	func distinguishesSameNameTeams() async throws {
		try await connect()
		_ = try await connections.save(
			VercelGrant(accessToken: "vca_eu", installationID: "icfg_2", teamID: "team_acme_eu", userID: "u_1")!,
			account: VercelAccount(name: "Acme", slug: "acme-eu"), at: Date()).get()
		let tokens = TokenLog()
		let api = api
		let session = session(client: { token in
			tokens.append(token)
			return api
		})
		session.start()
		try await waitUntil { session.connections.value?.count == 2 }
		let labels = (session.connections.value ?? []).map(PublishSheet.connectionLabel)
		#expect(Set(labels) == ["Vercel · Acme · acme", "Vercel · Acme · acme-eu"])
		session.connectionID = "vercel.team_acme_eu"
		try await waitUntil { session.vercel?.projects != nil && session.vercel?.projects != .loading }
		#expect(tokens.values == ["vca_eu"])
	}

	@Test("a Vercel review that replaces variables says a change made on Vercel moments before can still be overwritten")
	func vercelReplaceNote() async throws {
		try await connect()
		api.variableList = VercelVariableList(variables: [vercelVariable("API_TOKEN")], hiddenProductionCount: 0)
		let session = session()
		try await chooseProduction(session)
		let review = try #require(session.review)
		#expect(PublishSheet.notes(for: review).contains { $0.contains("moments before publishing can still be overwritten") })
	}

	private func savedProduction(team: String = "team_acme", teamName: String = "Acme") -> PublishDestination {
		PublishDestination(
			sourceEnvironment: "production",
			target: .vercel(VercelPublishTarget(teamID: team, accountID: team, teamName: teamName, projectID: "prj_api",
				projectName: "demo-api", environment: .production)),
			createdAt: Date(timeIntervalSince1970: 1_750_000_000))
	}

	@Test("following a saved destination moved to another connection lists no projects for a form it then replaces")
	func followsMoveQuietly() async throws {
		try await connect()
		_ = try await connections.save(
			VercelGrant(accessToken: "vca_eu", installationID: "icfg_2", teamID: "team_acme_eu", userID: "u_1")!,
			account: VercelAccount(name: "Acme EU", slug: "acme-eu"), at: Date()).get()
		let opened = savedProduction()
		_ = try await publishing.save(opened, to: vault).get()
		var moved = opened
		moved.target = savedProduction(team: "team_acme_eu", teamName: "Acme EU").target
		_ = try await publishing.save(moved, to: vault).get()
		let session = session(saved: opened)
		session.start()
		try await waitUntil { session.review != nil || session.reviewError != nil }
		#expect(session.connectionID == "vercel.team_acme_eu" && session.review != nil)
		try await Task.sleep(for: .milliseconds(50))
		#expect(api.projectListingCount == 0)
	}

	@Test("a saved destination forgotten meanwhile opens on the destination step with its choices, ready to review")
	func forgottenOpensOnDestination() async throws {
		try await connect()
		let session = session(saved: savedProduction())
		session.start()
		try await waitUntil { session.step == .destination && session.vercel?.projects.value != nil }
		#expect(session.saved == nil && session.review == nil && api.listingCount == 0)
		#expect(session.destinationError?.contains("forgotten") == true)
		#expect(session.vercel?.projectID == "prj_api" && session.vercel?.environment == .production)
		#expect(session.canReview)
		session.loadReview()
		try await waitUntil { session.review != nil }
		#expect(session.destinationError == nil && session.review?.isSaved == false)
	}

	@Test("choosing Destination while a saved destination opens keeps the person there")
	func destinationDuringStart() async throws {
		try await connect()
		let saved = savedProduction()
		_ = try await publishing.save(saved, to: vault).get()
		let session = session(saved: saved)
		session.start()
		session.showDestination()
		try await waitUntil { session.vercel?.projects.value != nil }
		try await Task.sleep(for: .milliseconds(50))
		#expect(session.step == .destination && !session.isLoadingReview && api.listingCount == 0)
	}

	@Test("a key lpm.json stopped making public after the review isn't sent readable: the publish is refused")
	func rulesChangedSinceReview() async throws {
		try await connect()
		values.set("production", ["SITE_URL": "https://x"])
		let current = RulesBox(.known(ProjectEnvSchemaOverview(
			rules: [ProjectEnvSchemaOverview.Rule(key: "SITE_URL", isPublic: true, source: nil, badges: [])], groups: [])))
		let values = values
		let session = PublishSession(
			vaultID: vault, projectName: "demo-api", environments: ["production"], sourceEnvironment: "production",
			dependencies: .init(
				snapshot: { environment, _ in values.get(environment).map { .init(values: $0, rules: current.rules, check: nil) } },
				confirm: { [confirmations] in confirmations.ask($0) },
				publishing: publishing, connections: connections,
				vercel: { [api] _ in api }))
		try await chooseProduction(session)
		#expect(session.review?.plan.row("SITE_URL")?.publishesAsSecret == false)
		current.rules = .known(ProjectEnvSchemaOverview(
			rules: [ProjectEnvSchemaOverview.Rule(key: "SITE_URL", isPublic: false, source: nil, badges: [])], groups: []))
		session.publish()
		try await waitUntil { !session.isPublishing }
		#expect(session.reviewError?.contains("lpm.json") == true)
		#expect(confirmations.reasons.isEmpty && api.createdWrites.isEmpty)
	}

	@Test("after a publish Vercel refused part of, the same destination is reviewed again from the results")
	func reviewAgainFromResults() async throws {
		try await connect()
		let session = session()
		try await chooseProduction(session)
		api.variableList = VercelVariableList(variables: [vercelVariable("API_TOKEN")], hiddenProductionCount: 0)
		session.publish()
		try await waitUntil { session.step == .results }
		#expect(session.results?.rows.first { $0.key == "API_TOKEN" }?.outcome == .failed("Added on Vercel since this review. Review again."))
		session.reviewAgain()
		#expect(session.step == .review && session.results == nil)
		try await waitUntil { session.review != nil && !session.isLoadingReview }
		#expect(session.review?.plan.row("API_TOKEN")?.operation == .replace(remoteID: "env_API_TOKEN"))
		#expect(session.review?.isSaved == true, "The publish saved the destination for what Vercel accepted")
	}

	@Test("a key failing a group rule is explained from the values the review read, not from a check made before")
	func ruleNotesFromReview() async throws {
		try await connect()
		values.set("production", ["PASSWORD": "p", "OAUTH_TOKEN": "t"])
		let group = ProjectEnvSchemaOverview.Group(name: "login", members: ["OAUTH_TOKEN", "PASSWORD"], mode: "exactlyOne")
		let rules = ProjectEnvSchemaOverview(rules: [], groups: [group])
		let failing = ProjectEnvValueCheck.Environment(problems: [
			"PASSWORD": [.init(key: "PASSWORD", kind: .group(name: "login", mode: "exactlyOne"))],
			"OAUTH_TOKEN": [.init(key: "OAUTH_TOKEN", kind: .group(name: "login", mode: "exactlyOne"))],
		])
		let values = values
		let session = PublishSession(
			vaultID: vault, projectName: "demo-api", environments: ["production"], sourceEnvironment: "production",
			dependencies: .init(
				snapshot: { environment, _ in values.get(environment).map { .init(values: $0, rules: .known(rules), check: failing) } },
				confirm: { _ in true },
				publishing: publishing, connections: connections,
				vercel: { [api] _ in api }))
		try await chooseProduction(session)
		let review = try #require(session.review)
		let note = try #require(review.ruleNotes["PASSWORD"])
		#expect(note.hasSuffix("both set"))
		let row = try #require(review.plan.row("PASSWORD"))
		#expect(PublishSheet.holdNote(try #require(row.holds.first), row: row, review: review) == "Fails its rule: \(note)")
	}

	@Test("a snapshot never prints its values")
	func snapshotRedacted() {
		let snapshot = PublishSession.Snapshot(values: ["API_TOKEN": "sk_live_secret"], rules: .none, check: nil)
		var dumped = ""
		dump(snapshot, to: &dumped)
		for text in [String(describing: snapshot), String(reflecting: snapshot), dumped] {
			#expect(!text.contains("sk_live_secret"))
		}
	}

	@Test("changing the source, project or environment drops a review made for the old choice")
	func choiceChangeInvalidates() async throws {
		try await connect()
		api.projectList.append(VercelProject(id: "prj_web", name: "web", accountID: "team_acme"))
		let session = session()
		try await chooseProduction(session)
		#expect(session.review != nil)
		session.sourceEnvironment = "staging"
		#expect(session.review == nil)
		session.loadReview()
		try await waitUntil { session.review != nil }
		session.vercel?.projectID = "prj_web"
		#expect(session.review == nil, "A review of another project")
		session.vercel?.environment = .production
		session.loadReview()
		try await waitUntil { session.review != nil }
		session.vercel?.environment = .preview
		#expect(session.review == nil)
	}
}

@MainActor
private final class SnapshotReads {
	var contents: [PublishSession.Snapshot.Contents] = []
}

@MainActor
private final class RulesBox {
	var rules: PublishSession.Rules
	init(_ rules: PublishSession.Rules) { self.rules = rules }
}

@MainActor
private final class SnapshotBox {
	var values: [String: String]
	var check: ProjectEnvValueCheck.Environment
	init(values: [String: String], check: ProjectEnvValueCheck.Environment) {
		self.values = values
		self.check = check
	}
}

actor AsyncFlag {
	private var isOpen = false
	private var waiters: [CheckedContinuation<Void, Never>] = []

	func wait() async {
		guard !isOpen else { return }
		await withCheckedContinuation { waiters.append($0) }
	}

	func open() {
		isOpen = true
		for waiter in waiters { waiter.resume() }
		waiters = []
	}
}

private final class TokenLog: @unchecked Sendable {
	private let lock = NSLock()
	private var tokens: [String] = []
	var values: [String] { lock.withLock { tokens } }
	func append(_ token: String) { lock.withLock { tokens.append(token) } }
}

@MainActor
struct CoolifyPublishSessionTests {
	private let keychain = MockKeychainService()
	private let api = FakeCoolifyAPI()
	private let vault = "publish-session-vault"
	private let values = ValuesBox(["production": ["API_TOKEN": "tok", "NEXT_PUBLIC_URL": "https://x"]])
	private let confirmations = Confirmations()
	private let rules = ProjectEnvSchemaOverview(
		rules: [ProjectEnvSchemaOverview.Rule(key: "NEXT_PUBLIC_URL", isPublic: true, source: nil, badges: [])], groups: [])

	private var publishing: PublishingStore { PublishingStore(service: keychain) }
	private var connections: PlatformConnectionStore { PlatformConnectionStore(service: keychain) }

	private func connect() async throws {
		_ = try await connections.save(
			.coolify(CoolifyConnectionAccount(instance: CoolifyInstance(origin: "https://coolify.example.com")!, teamID: "0", teamName: "Root Team")),
			accessToken: "3|coolify", at: Date()).get()
	}

	private func session(saved: PublishDestination? = nil) -> PublishSession {
		let values = values
		let confirmations = confirmations
		let api = api
		return PublishSession(
			vaultID: vault, projectName: "demo-api", environments: ["production"], sourceEnvironment: "production",
			saved: saved,
			dependencies: .init(
				snapshot: { [rules] environment, _ in values.get(environment).map { .init(values: $0, rules: .known(rules), check: nil) } },
				confirm: { confirmations.ask($0) },
				publishing: publishing,
				connections: connections,
				vercel: { _ in FakeVercelAPI() },
				coolify: { instance, token in
					#expect(instance.origin == "https://coolify.example.com" && token == "3|coolify")
					return api
				},
				now: { Date(timeIntervalSince1970: 1_760_000_000) }))
	}

	private func waitUntil(_ condition: () -> Bool) async throws {
		for _ in 0..<400 where !condition() { try await Task.sleep(for: .milliseconds(5)) }
		#expect(condition())
	}

	private func chooseApplication(_ session: PublishSession) async throws {
		session.start()
		try await waitUntil { session.coolify?.resources.value != nil }
		session.coolify?.resourceID = "app-api"
		#expect(session.coolify?.deployments == .production, "An application starts on its production deployments")
		#expect(session.canReview)
		session.loadReview()
		try await waitUntil { session.review != nil || session.reviewError != nil }
	}

	@Test("a Coolify application is chosen, reviewed, published with Touch ID, and saved with its names")
	func publishesNewDestination() async throws {
		try await connect()
		let session = session()
		try await chooseApplication(session)
		let review = try #require(session.review)
		#expect(review.platform == .coolify && review.selection.keys == ["API_TOKEN", "NEXT_PUBLIC_URL"])
		session.publish()
		try await waitUntil { session.step == .results }
		#expect(confirmations.reasons == ["Publish 2 variables to api / Production on Coolify"])
		#expect(session.results?.publishedCount == 2)
		let saved = try #require(try await publishing.destinations(of: vault).get().first)
		guard case .coolify(let target) = saved.target else { Issue.record("Not a Coolify destination"); return }
		#expect(target.resourceID == "app-api" && target.resourceName == "api" && target.projectName == "Storefront")
		#expect(target.environmentName == "production" && target.deployments == .production && target.teamName == "Root Team")
		let history = try await publishing.history(of: saved.id, in: vault).get()
		#expect(history.keys["API_TOKEN"]?.publishedAsSecret == true && history.keys["NEXT_PUBLIC_URL"]?.publishedAsSecret == false)
		#expect(history.keys["API_TOKEN"]?.remoteID == api.variables.first { $0.key == "API_TOKEN" && !$0.isPreview }?.id)
		#expect(api.variables.first { $0.key == "API_TOKEN" && $0.isPreview }?.isLocked == true, "The secret's preview copy is locked")
		#expect(VaultTitleBarView.title(of: saved) == "api / Production — Coolify · Root Team")
	}

	@Test("a saved Coolify destination opens on its review, up to date with what this Mac published")
	func savedOpensOnReview() async throws {
		try await connect()
		let first = session()
		try await chooseApplication(first)
		first.publish()
		try await waitUntil { first.step == .results }
		let saved = try #require(try await publishing.destinations(of: vault).get().first)

		let again = session(saved: saved)
		#expect(again.step == .review && again.coolify?.resourceID == "app-api")
		again.start()
		try await waitUntil { again.review != nil || again.reviewError != nil }
		let review = try #require(again.review)
		#expect(review.isSaved && !review.needsSave)
		let upToDate = review.plan.rows.allSatisfy { $0.status.isUpToDate }
		#expect(upToDate, "Coolify has the values this Mac published")
		api.edit("API_TOKEN")
		again.loadReview()
		try await waitUntil { again.review != nil && !again.isLoadingReview }
		#expect(again.review?.plan.row("API_TOKEN")?.holds == [.changedOnPlatform])
	}

	@Test("a service publishes to its only deployments, and Coolify's own SERVICE_ names can't be published there")
	func service() async throws {
		try await connect()
		api.resourceList = .success([CoolifyResource(kind: .service, id: "svc-db", name: "db", projectName: nil, environmentName: nil, buildPack: nil)])
		values.set("production", ["SERVICE_PASSWORD_DB": "x", "APP_KEY": "k"])
		let session = session()
		session.start()
		try await waitUntil { session.coolify?.resources.value != nil }
		session.coolify?.deployments = .preview
		session.coolify?.resourceID = "svc-db"
		#expect(session.coolify?.deployments == .production && session.coolify?.deploymentChoices == [.production])
		session.loadReview()
		try await waitUntil { session.review != nil || session.reviewError != nil }
		#expect(session.review?.plan.row("SERVICE_PASSWORD_DB")?.holds.first == .reserved)
		#expect(session.review?.selection.keys == ["APP_KEY"])
	}

	@Test("choosing another platform's connection changes the fields and drops the review")
	func switchesPlatform() async throws {
		try await connect()
		_ = try await connections.save(
			VercelGrant(accessToken: "vca_1", installationID: "icfg_1", teamID: "team_acme", userID: "u_1")!,
			account: VercelAccount(name: "Acme", slug: "acme"), at: Date()).get()
		let session = session()
		session.start()
		try await waitUntil { session.connections.value?.count == 2 }
		#expect(session.form == nil, "With two connections, none is chosen for the person")
		session.connectionID = "coolify.0.https://coolify.example.com"
		try await chooseApplication(session)
		#expect(session.review != nil)
		session.connectionID = "vercel.team_acme"
		#expect(session.review == nil && session.coolify == nil && session.vercel != nil && session.platform == .vercel)
	}

	@Test("a saved destination opens on its review without listing the team's resources, and lists them once to change it")
	func savedSkipsDiscovery() async throws {
		try await connect()
		let saved = coolifyDestination()
		_ = try await publishing.save(saved, to: vault).get()
		let session = session(saved: saved)
		session.start()
		try await waitUntil { session.review != nil || session.reviewError != nil }
		#expect(session.review != nil && api.resourceListingCount == 0)
		session.showDestination()
		try await waitUntil { session.coolify?.resources.value != nil }
		session.showDestination()
		session.loadReview()
		try await waitUntil { session.review != nil && !session.isLoadingReview }
		session.showDestination()
		try await Task.sleep(for: .milliseconds(20))
		#expect(api.resourceListingCount == 1)
	}

	@Test("Coolify's choices name the instance, and resources that would read alike are told apart")
	func distinguishesAlikeChoices() throws {
		let first = PlatformConnection(
			account: .coolify(CoolifyConnectionAccount(instance: CoolifyInstance(origin: "https://coolify.example.com")!, teamID: "0", teamName: "Root Team")),
			connectedAt: Date())
		let second = PlatformConnection(
			account: .coolify(CoolifyConnectionAccount(instance: CoolifyInstance(origin: "https://coolify.example.dev")!, teamID: "0", teamName: "Root Team")),
			connectedAt: Date())
		#expect(PublishSheet.connectionLabel(first) == "Coolify · Root Team · coolify.example.com · team 0")
		#expect(PublishSheet.connectionLabel(first) != PublishSheet.connectionLabel(second))
		let resources = [
			CoolifyResource(kind: .application, id: "a1b2c3d4e5f6", name: "api", projectName: "Storefront", environmentName: "production", buildPack: nil),
			CoolifyResource(kind: .application, id: "f6e5d4c3b2a1", name: "api", projectName: "Storefront", environmentName: "production", buildPack: nil),
			CoolifyResource(kind: .application, id: "0f0f0f0f0f0f", name: "api", projectName: "Storefront", environmentName: "staging", buildPack: nil),
		]
		let labels = CoolifyDestinationForm.labels(for: resources)
		#expect(Set(labels.values).count == 3)
		#expect(labels["0f0f0f0f0f0f"] == "api — Storefront / staging")
		#expect(labels["a1b2c3d4e5f6"] == "api — Storefront / production · a1b2c3d4")
		let destination = coolifyDestination()
		#expect(VaultTitleBarView.subtitle(of: PublishDestinationSummary(destination: destination, lastPublishedAt: nil))
			== "Storefront / production on coolify.example.com · from .env.production · not published yet")
	}

	@Test("a Coolify review that replaces variables says a change made in Coolify moments before can still be overwritten")
	func replaceNote() async throws {
		try await connect()
		api.seed("API_TOKEN")
		let session = session()
		try await chooseApplication(session)
		let review = try #require(session.review)
		#expect(PublishSheet.notes(for: review).contains { $0.contains("moments before publishing can still be overwritten") })
	}

	@Test("each connection's token reaches only its own platform's client")
	func tokensStayWithTheirPlatform() async throws {
		try await connect()
		_ = try await connections.save(
			VercelGrant(accessToken: "vca_1", installationID: "icfg_1", teamID: "team_acme", userID: "u_1")!,
			account: VercelAccount(name: "Acme", slug: "acme"), at: Date()).get()
		let vercelTokens = TokenLog()
		let coolifyTokens = TokenLog()
		let api = api
		let values = values
		let confirmations = confirmations
		let session = PublishSession(
			vaultID: vault, projectName: "demo-api", environments: ["production"], sourceEnvironment: "production",
			dependencies: .init(
				snapshot: { environment, _ in values.get(environment).map { .init(values: $0, rules: .none, check: nil) } },
				confirm: { confirmations.ask($0) },
				publishing: publishing, connections: connections,
				vercel: { token in
					vercelTokens.append(token)
					return FakeVercelAPI()
				},
				coolify: { _, token in
					coolifyTokens.append(token)
					return api
				}))
		session.start()
		try await waitUntil { session.connections.value?.count == 2 }
		session.connectionID = "coolify.0.https://coolify.example.com"
		try await waitUntil { session.coolify?.resources.value != nil }
		session.connectionID = "vercel.team_acme"
		try await waitUntil { session.vercel?.projects.value != nil }
		#expect(Set(vercelTokens.values) == ["vca_1"] && Set(coolifyTokens.values) == ["3|coolify"])
	}

	@Test("a saved Coolify destination whose team isn't connected here says so")
	func missingConnection() async throws {
		let saved = coolifyDestination()
		_ = try await publishing.save(saved, to: vault).get()
		let session = session(saved: saved)
		session.start()
		try await waitUntil { session.reviewError != nil }
		#expect(session.reviewError?.contains("Root Team on Coolify, which isn't connected on this Mac") == true)
	}
}

@MainActor
private final class ValuesBox {
	private var environments: [String: [String: String]]
	init(_ environments: [String: [String: String]]) { self.environments = environments }
	func get(_ environment: String) -> [String: String]? { environments[environment] }
	func set(_ environment: String, _ values: [String: String]) { environments[environment] = values }
}

@MainActor
private final class Confirmations {
	var approve = true
	private(set) var reasons: [String] = []
	func ask(_ reason: String) -> Bool {
		reasons.append(reason)
		return approve
	}
}

@MainActor
struct PublishStoreTests {
	private let keychain = MockKeychainService()
	private let biometric = MockBiometricService()
	private let api = FakeVercelAPI()

	private func makeStore() async throws -> VaultStore {
		let environments = ["default": ["A": "1"], "production": ["API_TOKEN": "tok"]]
		keychain.envStorage["project"] = (name: "demo-api", path: "", environments: environments)
		let api = api
		let store = VaultStore(
			keychainService: keychain, biometricService: biometric, apiService: MockAPIService(),
			authTokenProvider: { _, _ in nil }, platformClient: { _ in api })
		store.projects = [VaultProject(id: "project", name: "demo-api", path: "", environments: environments)]
		store.isUnlocked = true
		store.openProject(id: "project")
		store.selectEnvironment("production")
		_ = try await store.platformConnectionStore.save(
			VercelGrant(accessToken: "vca_1", installationID: "icfg_1", teamID: "team_acme", userID: "u_1")!,
			account: VercelAccount(name: "Acme", slug: "acme"), at: Date()).get()
		return store
	}

	private func waitUntil(_ condition: () -> Bool) async throws {
		for _ in 0..<400 where !condition() { try await Task.sleep(for: .milliseconds(5)) }
		#expect(condition())
	}

	@Test("publishing from the store asks for Touch ID even right after an approval, and refreshes the Publish menu")
	func publishesThroughStore() async throws {
		let store = try await makeStore()
		let session = try #require(store.makePublishSession())
		let project = try #require(store.selectedProject)
		#expect(session.sourceEnvironment == "production" && session.environments == store.orderedEnvironmentNames(for: project))
		session.start()
		try await waitUntil { session.connectionID != nil && session.vercel?.projects.value != nil }
		session.vercel?.projectID = "prj_api"
		session.vercel?.environment = .production
		session.loadReview()
		try await waitUntil { session.review != nil || session.reviewError != nil }
		#expect(session.review?.rules == .unreadable, "Rules not read yet publish everything as a Secret")
		_ = await store.authenticateForSensitiveAction(reason: "an earlier approval")
		session.publish()
		try await waitUntil { session.step == .results }
		#expect(biometric.confirmationReasons == ["Publish 1 variable to demo-api / Production on Vercel"])
		try await waitUntil { store.publishDestinations["project"]?.count == 1 }
		#expect(store.publishDestinations["project"]?.first?.lastPublishedAt != nil)
	}

	@Test("the Publish menu lists the most recently published destination first, and locking forgets the list")
	func destinationOrder() async throws {
		let store = try await makeStore()
		let publishing = store.publishing
		func destination(_ environment: VercelPublishTarget.Environment, created: TimeInterval) -> PublishDestination {
			PublishDestination(
				sourceEnvironment: "production",
				target: .vercel(VercelPublishTarget(teamID: "team_acme", accountID: "team_acme", teamName: "Acme", projectID: "prj_api",
					projectName: "demo-api", environment: environment)),
				createdAt: Date(timeIntervalSince1970: created))
		}
		let never = destination(.development, created: 1_700_000_000)
		let old = destination(.preview, created: 1_700_000_100)
		let recent = destination(.production, created: 1_700_000_200)
		for item in [never, old, recent] { _ = try await publishing.save(item, to: "project").get() }
		for (item, at) in [(old, 1_760_000_000.0), (recent, 1_760_000_500.0)] {
			_ = try await publishing.recordPublish([], to: item.id, at: item.target.location, choices: .init(leftOut: [], chosen: []),
				of: "project", at: Date(timeIntervalSince1970: at)).get()
		}
		await store.loadPublishDestinations(for: "project")
		#expect(store.publishDestinations["project"]?.map(\.id) == [recent.id, old.id, never.id])
		store.lock()
		#expect(store.publishDestinations.isEmpty)
	}

	@Test("the review checks the values it publishes, not a check made before they changed")
	func reviewChecksItsOwnValues() async throws {
		let folder = FileManager.default.temporaryDirectory.appending(path: "publish-check-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: folder) }
		try #"{"envSchema":{"vars":{"PORT":{"format":"port"}}}}"#.write(to: folder.appending(path: "lpm.json"), atomically: true, encoding: .utf8)
		let environments = ["production": ["PORT": "8080"]]
		keychain.envStorage["project"] = (name: "demo-api", path: folder.path, environments: environments)
		let api = api
		let store = VaultStore(
			keychainService: keychain, biometricService: biometric, apiService: MockAPIService(),
			authTokenProvider: { _, _ in nil }, platformClient: { _ in api })
		store.projects = [VaultProject(id: "project", name: "demo-api", path: folder.path, environments: environments)]
		store.isUnlocked = true
		store.openProject(id: "project")
		store.selectEnvironment("production")
		defer { store.lock() }
		store.reloadKeyDescriptions()
		for _ in 0..<500 where store.valueChecks["project"] == nil { try await Task.sleep(for: .milliseconds(10)) }
		_ = try #require(store.valueChecks["project"])
		_ = try await store.platformConnectionStore.save(
			VercelGrant(accessToken: "vca_1", installationID: "icfg_1", teamID: "team_acme", userID: "u_1")!,
			account: VercelAccount(name: "Acme", slug: "acme"), at: Date()).get()
		let changed = ["production": ["PORT": "not-a-port"]]
		keychain.envStorage["project"] = (name: "demo-api", path: folder.path, environments: changed)
		store.projects = [VaultProject(id: "project", name: "demo-api", path: folder.path, environments: changed)]
		let session = try #require(store.makePublishSession())
		session.start()
		try await waitUntil { session.vercel?.projects.value != nil }
		session.vercel?.projectID = "prj_api"
		session.vercel?.environment = .production
		session.loadReview()
		try await waitUntil { session.review != nil || session.reviewError != nil }
		let row = try #require(session.review?.plan.row("PORT"))
		#expect(row.holds.contains { if case .failsRules = $0 { true } else { false } })
		#expect(!row.isSelectedByDefault)
	}

	@Test("a review waits for the value check already running for its values, rather than running another")
	func reviewWaitsForRunningCheck() async throws {
		let folder = FileManager.default.temporaryDirectory.appending(path: "publish-running-check-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: folder) }
		try #"{"envSchema":{"vars":{"PORT":{"format":"port"}}}}"#.write(to: folder.appending(path: "lpm.json"), atomically: true, encoding: .utf8)
		let environments = ["production": ["PORT": "not-a-port"]]
		keychain.envStorage["project"] = (name: "demo-api", path: folder.path, environments: environments)
		let checks = OSAllocatedUnfairLock(initialState: 0)
		let release = DispatchSemaphore(value: 0)
		let api = api
		let store = VaultStore(
			keychainService: keychain, biometricService: biometric, apiService: MockAPIService(),
			authTokenProvider: { _, _ in nil }, platformClient: { _ in api },
			valueChecker: { rules, environments in
				checks.withLock { $0 += 1 }
				_ = release.wait(timeout: .now() + 30)
				return rules.check(environments)
			})
		store.projects = [VaultProject(id: "project", name: "demo-api", path: folder.path, environments: environments)]
		store.isUnlocked = true
		store.openProject(id: "project")
		store.selectEnvironment("production")
		defer {
			release.signal()
			store.lock()
		}
		_ = try await store.platformConnectionStore.save(
			VercelGrant(accessToken: "vca_1", installationID: "icfg_1", teamID: "team_acme", userID: "u_1")!,
			account: VercelAccount(name: "Acme", slug: "acme"), at: Date()).get()
		store.reloadKeyDescriptions()
		for _ in 0..<500 where checks.withLock({ $0 }) == 0 { try await Task.sleep(for: .milliseconds(10)) }
		#expect(checks.withLock { $0 } == 1)
		let session = try #require(store.makePublishSession())
		session.start()
		try await waitUntil { session.vercel?.projects.value != nil }
		session.vercel?.projectID = "prj_api"
		session.vercel?.environment = .production
		session.loadReview()
		try await Task.sleep(for: .milliseconds(100))
		release.signal()
		release.signal()
		try await waitUntil { session.review != nil || session.reviewError != nil }
		#expect(checks.withLock { $0 } == 1)
		#expect(session.review?.plan.row("PORT")?.holds.contains { if case .failsRules = $0 { true } else { false } } == true)
	}

	@Test("locking cancels a publish waiting for Touch ID, and one between replacements, so nothing more is sent")
	func lockCancelsPublish() async throws {
		let store = try await makeStore()
		api.variableList = VercelVariableList(
			variables: (1...6).map { vercelVariable("KEY_\($0)") }, hiddenProductionCount: 0)
		let environments = ["production": Dictionary(uniqueKeysWithValues: (1...6).map { ("KEY_\($0)", "v\($0)") })]
		keychain.envStorage["project"] = (name: "demo-api", path: "", environments: environments)
		store.projects = [VaultProject(id: "project", name: "demo-api", path: "", environments: environments)]
		store.openProject(id: "project")
		store.selectEnvironment("production")
		let session = try #require(store.makePublishSession())
		session.start()
		try await waitUntil { session.vercel?.projects.value != nil }
		session.vercel?.projectID = "prj_api"
		session.vercel?.environment = .production
		session.loadReview()
		try await waitUntil { session.review != nil }
		for index in 1...6 { session.set("KEY_\(index)", selected: true) }
		let replacing = AsyncFlag()
		let released = AsyncFlag()
		api.beforeReplace = {
			await replacing.open()
			await released.wait()
		}
		session.publish()
		await replacing.wait()
		#expect(api.replacedValues.isEmpty && session.isPublishing)
		store.lock()
		await released.open()
		try await waitUntil { !session.isPublishing }
		#expect(api.replacedValues.count <= VercelPublishing.replaceConcurrency, "No replacement after the first batch")
		let replaced = Set(api.replacedValues.map { String($0.id.dropFirst("env_".count)) })
		let recorded = try #require(try await store.publishing.destinations(of: "project").get().first)
		#expect(Set(try await store.publishing.history(of: recorded.id, in: "project").get().keys.keys) == replaced,
			"What Vercel accepted before the lock is recorded, and nothing else")

		let second = try await makeStore()
		let held = AsyncFlag()
		biometric.authenticateHandlers = [{ await held.wait(); return true }]
		let waiting = try #require(second.makePublishSession())
		waiting.start()
		try await waitUntil { waiting.vercel?.projects.value != nil }
		waiting.vercel?.projectID = "prj_api"
		waiting.vercel?.environment = .production
		waiting.loadReview()
		try await waitUntil { waiting.review != nil }
		let creates = api.createdWrites.count
		waiting.publish()
		try await Task.sleep(for: .milliseconds(50))
		second.lock()
		await held.open()
		try await waitUntil { !waiting.isPublishing }
		#expect(api.createdWrites.count == creates)
	}

	@Test("no Publish sheet opens without an open project")
	func needsProject() {
		let store = VaultStore(keychainService: keychain, biometricService: biometric, apiService: MockAPIService(), authTokenProvider: { _, _ in nil })
		store.isUnlocked = true
		#expect(store.makePublishSession() == nil)
	}
}

extension SheetInteractionTests {
	@Suite("Publish sheet and title bar, rendered")
	@MainActor
	struct PublishRenderingTests {
		private let keychain = MockKeychainService()
		private let biometric = MockBiometricService()
		private let api = FakeVercelAPI()

		private func makeStore() async throws -> VaultStore {
			let environments = ["default": ["A": "1"], "production": ["API_TOKEN": "tok", "SHARED_KEY": "s"]]
			keychain.envStorage["project"] = (name: "demo-api", path: "", environments: environments)
			let api = api
			let store = VaultStore(
				keychainService: keychain, biometricService: biometric, apiService: MockAPIService(),
				authTokenProvider: { _, _ in nil }, platformClient: { _ in api })
			store.projects = [VaultProject(id: "project", name: "demo-api", path: "", environments: environments)]
			store.isUnlocked = true
			store.openProject(id: "project")
			store.selectEnvironment("production")
			_ = try await store.platformConnectionStore.save(
				VercelGrant(accessToken: "vca_1", installationID: "icfg_1", teamID: "team_northwind", userID: "u_1")!,
				account: VercelAccount(name: "Northwind", slug: "northwind"), at: Date()).get()
			return store
		}

		@Test("the sheet goes from Destination to Review to Published, and a shared variable waits for Publish anyway")
		func publishes() async throws {
			let store = try await makeStore()
			api.projectList = [VercelProject(id: "prj_api", name: "storefront", accountID: "team_northwind")]
			api.variableList = VercelVariableList(
				variables: [vercelVariable("SHARED_KEY", targets: [.production, .preview])], hiddenProductionCount: 0)
			let session = try #require(store.makePublishSession())
			let host = SheetTestHost(PublishSheet(store: store, session: session), size: NSSize(width: 640, height: 640),
				keepsRequestedSize: true, usesHostingView: true)
			defer { host.window.close(); store.lock() }
			#expect(try await host.waitForText("Publish environment"))
			#expect(try await host.waitForText("Choose a destination"))
			#expect(try await host.waitUntil { session.vercel?.projects.value != nil })
			session.vercel?.projectID = "prj_api"
			session.vercel?.environment = .production
			#expect(try await host.waitForText("storefront / Production"))
			try await host.click("Review variables")
			#expect(try await host.waitForText("Publish anyway"))
			#expect(try await host.waitForText("Shared with Preview on Vercel"))
			#expect(try await host.waitForText("Publish 1 variable"))
			try await host.click("Publish anyway")
			#expect(try await host.waitForText("Publish 2 variables"))
			try await host.click("Publish 2 variables")
			#expect(try await host.waitForText("Published 2 of 2 variables"))
			#expect(biometric.confirmationReasons == ["Publish 2 variables to storefront / Production on Vercel"])
			#expect(Set(api.createdWrites.map(\.key)) == ["API_TOKEN"] && api.replacedValues.map(\.id) == ["env_SHARED_KEY"])
		}

		@Test("a publish Vercel refused part of offers Review Again, which reviews the same destination")
		func reviewAgain() async throws {
			let store = try await makeStore()
			api.projectList = [VercelProject(id: "prj_api", name: "storefront", accountID: "team_northwind")]
			let session = try #require(store.makePublishSession())
			let host = SheetTestHost(PublishSheet(store: store, session: session), size: NSSize(width: 640, height: 640),
				keepsRequestedSize: true, usesHostingView: true)
			defer { host.window.close(); store.lock() }
			#expect(try await host.waitUntil { session.vercel?.projects.value != nil })
			session.vercel?.projectID = "prj_api"
			session.vercel?.environment = .production
			try await host.click("Review variables")
			#expect(try await host.waitForText("Publish 2 variables"))
			api.variableList = VercelVariableList(variables: [vercelVariable("API_TOKEN")], hiddenProductionCount: 0)
			try await host.click("Publish 2 variables")
			#expect(try await host.waitForText("Published 1 of 2 variables"))
			#expect(try await host.waitForText("Added on Vercel since this review"))
			try await host.click("Review Again")
			#expect(try await host.waitForText("Replaces a variable already on Vercel"))
			#expect(session.step == .review && session.review?.isSaved == true)
		}

		@Test("a saved destination forgotten meanwhile opens on the destination step, which says so")
		func forgottenDestination() async throws {
			let store = try await makeStore()
			api.projectList = [VercelProject(id: "prj_api", name: "storefront", accountID: "team_northwind")]
			let saved = PublishDestination(
				sourceEnvironment: "production",
				target: .vercel(VercelPublishTarget(teamID: "team_northwind", accountID: "team_northwind", teamName: "Northwind",
					projectID: "prj_api", projectName: "storefront", environment: .production)),
				createdAt: Date())
			let session = try #require(store.makePublishSession(for: saved))
			let host = SheetTestHost(PublishSheet(store: store, session: session), size: NSSize(width: 640, height: 560),
				keepsRequestedSize: true, usesHostingView: true)
			defer { host.window.close(); store.lock() }
			#expect(try await host.waitForText("forgotten on this Mac"))
			#expect(try await host.waitForText("storefront / Production"))
			#expect(session.step == .destination && session.canReview)
		}

		@Test("a Coolify publish names the application and its deployments, explains a value Coolify would break, and says to redeploy")
		func publishesToCoolify() async throws {
			let environments = ["production": ["API_TOKEN": "tok", "QUOTED": "it's"]]
			keychain.envStorage["project"] = (name: "demo-api", path: "", environments: environments)
			let coolify = FakeCoolifyAPI()
			let store = VaultStore(
				keychainService: keychain, biometricService: biometric, apiService: MockAPIService(),
				authTokenProvider: { _, _ in nil }, coolifyClient: { _, _ in coolify })
			store.projects = [VaultProject(id: "project", name: "demo-api", path: "", environments: environments)]
			store.isUnlocked = true
			store.openProject(id: "project")
			store.selectEnvironment("production")
			_ = try await store.platformConnectionStore.save(
				.coolify(CoolifyConnectionAccount(instance: CoolifyInstance(origin: "https://coolify.northwind.dev")!, teamID: "0", teamName: "Northwind")),
				accessToken: "3|coolify", at: Date()).get()
			let session = try #require(store.makePublishSession())
			let host = SheetTestHost(PublishSheet(store: store, session: session), size: NSSize(width: 640, height: 640),
				keepsRequestedSize: true, usesHostingView: true)
			defer { host.window.close(); store.lock() }
			#expect(try await host.waitUntil { session.coolify?.resources.value != nil })
			#expect(try await host.waitForText("Application or service"))
			session.coolify?.resourceID = "app-api"
			#expect(try await host.waitForText("api / Production"))
			#expect(try await host.waitForText("TO COOLIFY"))
			try await host.click("Review variables")
			#expect(try await host.waitForText("single quote"))
			#expect(try await host.waitForText("Can't publish"))
			#expect(try await host.waitForText("copies new variables"))
			try await host.click("Publish 1 variable")
			#expect(try await host.waitForText("Redeploy in Coolify"))
			#expect(biometric.confirmationReasons == ["Publish 1 variable to api / Production on Coolify"])
			#expect(coolify.writes.map(\.key) == ["API_TOKEN", "API_TOKEN"] && coolify.value(of: "API_TOKEN") == "tok")
		}

		@Test("a destination that can't be forgotten says so and stays open, so forgetting can be tried again")
		func forgetFailure() async throws {
			let store = try await makeStore()
			let saved = PublishDestination(
				sourceEnvironment: "production",
				target: .vercel(VercelPublishTarget(teamID: "team_northwind", accountID: "team_northwind", teamName: "Northwind",
					projectID: "prj_api", projectName: "storefront", environment: .production)),
				createdAt: Date())
			_ = try await store.publishing.save(saved, to: "project").get()
			let history = "history.project.\(saved.id.uuidString.lowercased())"
			keychain.failAppItemDeletes = [history]
			let session = try #require(store.makePublishSession(for: saved))
			let host = SheetTestHost(PublishSheet(store: store, session: session), size: NSSize(width: 640, height: 560),
				keepsRequestedSize: true, usesHostingView: true)
			defer { host.window.close(); store.lock() }
			try await host.click("Destination")
			try await host.click("Forget destination")
			#expect(try await host.waitUntil { host.window.sheets.first != nil })
			try host.clickAlertButton("Forget Destination", in: try #require(host.window.sheets.first))
			#expect(try await host.waitForText("couldn't be forgotten"))
			keychain.failAppItemDeletes = []
			try await host.click("Forget destination")
			#expect(try await host.waitUntil { host.window.sheets.first != nil })
			try host.clickAlertButton("Forget Destination", in: try #require(host.window.sheets.first))
			#expect(try await host.waitUntil { keychain.publishingStorage[history] == nil })
			#expect(try await store.publishing.destinations(of: "project").get().isEmpty)
		}

		@Test("a saved Vercel destination names its team's slug, so two teams with one name are told apart")
		func vercelDetail() async throws {
			let store = try await makeStore()
			let saved = PublishDestination(
				sourceEnvironment: "production",
				target: .vercel(VercelPublishTarget(teamID: "team_northwind", accountID: "team_northwind", teamName: "Northwind",
					projectID: "prj_api", projectName: "storefront", environment: .production)),
				createdAt: Date())
			_ = try await store.publishing.save(saved, to: "project").get()
			await store.loadPublishDestinations(for: "project")
			let summary = try #require(store.publishDestinations["project"]?.first)
			#expect(VaultTitleBarView.subtitle(of: summary) == "northwind · from .env.production · not published yet")
		}

		@Test("with no platform account connected, the sheet points to Platforms")
		func noConnection() async throws {
			let store = try await makeStore()
			_ = await store.platformConnectionStore.remove("vercel.team_northwind")
			let session = try #require(store.makePublishSession())
			let host = SheetTestHost(PublishSheet(store: store, session: session), size: NSSize(width: 640, height: 480),
				keepsRequestedSize: true, usesHostingView: true)
			defer { host.window.close(); store.lock() }
			#expect(try await host.waitForText("No platform account is connected on this Mac"))
			try await host.click("Open Platforms")
			#expect(try await host.waitUntil { store.accountPage == .platforms })
		}

		@Test("the title bar offers Publish… until the project has saved destinations, then a Publish menu")
		func titleBar() async throws {
			let store = try await makeStore()
			let opened = OpenedDestinations()
			let host = SheetTestHost(
				VaultTitleBarView(store: store, mode: .environment("production"), onConnectCLI: {}, onPull: {}, onPush: {},
					onPublish: { opened.values.append($0) })
					.environment(UpdateChecker()),
				size: NSSize(width: 1200, height: VaultMetrics.titleBar), keepsRequestedSize: true, usesHostingView: true)
			defer { host.window.close(); store.lock() }
			#expect(try await host.waitForText("Publish…"))
			try await host.click("Publish…")
			#expect(opened.values.count == 1 && opened.values.first! == nil)
			let saved = PublishDestination(
				sourceEnvironment: "production",
				target: .vercel(VercelPublishTarget(teamID: "team_northwind", accountID: "team_northwind", teamName: "Northwind",
					projectID: "prj_api", projectName: "storefront", environment: .production)),
				createdAt: Date())
			_ = try await store.publishing.save(saved, to: "project").get()
			await store.loadPublishDestinations(for: "project")
			#expect(try await host.waitForTextToDisappear("Publish…"))
			#expect(try await host.waitForText("Publish"))
			#expect(VaultTitleBarView.title(of: saved) == "storefront / Production — Vercel · Northwind")
			#expect(VaultTitleBarView.subtitle(of: PublishDestinationSummary(destination: saved, lastPublishedAt: nil))
				== "from .env.production · not published yet")
		}
	}
}

@MainActor
private final class OpenedDestinations {
	var values: [PublishDestination?] = []
}
