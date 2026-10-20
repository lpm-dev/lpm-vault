import AppKit
import SwiftUI
import Testing

@testable import LPMVault

private let now = Date(timeIntervalSince1970: 1_760_000_000)

private func vercel(team: String, name: String = "Northwind", project: String, source: String = "production") -> PublishDestination {
	PublishDestination(
		sourceEnvironment: source,
		target: .vercel(VercelPublishTarget(teamID: team, accountID: team, teamName: name,
			projectID: "prj_\(project)", projectName: project, environment: .production)),
		createdAt: now)
}

private func worker(source: String = "production") -> PublishDestination {
	PublishDestination(
		sourceEnvironment: source,
		target: .cloudflare(CloudflarePublishTarget(
			accountID: CloudflareLoginFixture.acme.id, accountName: "Acme", workerID: CloudflareFixture.workerID, workerName: "api",
			preferredLogin: CloudflareLogin.key(subject: CloudflareLoginFixture.subject))),
		createdAt: now)
}

private let repository = GitHubPublishTarget(
	userID: "583231", userLogin: "octocat", repositoryID: "1296269", repositoryName: "northwind/storefront", scope: .repository)

private let coolify = CoolifyPublishTarget(
	instance: CoolifyInstance(origin: "https://coolify.example.com")!, teamID: "0", teamName: "Root Team",
	resource: .application, resourceID: "app-api", resourceName: "api",
	projectName: "Storefront", environmentName: "production", deployments: .production)

@MainActor
struct PublishMenuEntryTests {
	@Test("a row names its place, the part written to, where it publishes from and its account, then when this Mac last published there")
	func row() {
		let summary = PublishDestinationSummary(
			destination: vercel(team: "team_northwind", project: "storefront"), lastPublishedAt: now.addingTimeInterval(-2 * 3600),
			accountDetail: "northwind")
		let entry = VaultPublishMenu.Entry(summary, now: now)
		#expect(entry.title == "storefront" && entry.part == "Production")
		#expect(entry.detail == "from .env.production · Northwind")
		#expect(entry.when == "2h ago")
		#expect(entry.accessibilityLabel == "storefront, Production, Vercel, from .env.production · Northwind, published 2h ago")
		#expect(entry.help == "storefront / Production on Vercel\nfrom .env.production · Northwind\nThrough Northwind (northwind)")
		let never = VaultPublishMenu.Entry(PublishDestinationSummary(destination: worker(), lastPublishedAt: nil), now: now)
		#expect(never.when == "Never" && never.accessibilityLabel.hasSuffix(", never published"))
	}

	@Test("a team's slug shows only beside another team with its name, reached through another connection")
	func slugOnlyWhenAmbiguous() {
		func summary(_ destination: PublishDestination, slug: String) -> PublishDestinationSummary {
			PublishDestinationSummary(destination: destination, lastPublishedAt: nil, accountDetail: slug)
		}
		let storefront = summary(vercel(team: "team_northwind", project: "storefront"), slug: "northwind")
		let sameTeam = summary(vercel(team: "team_northwind", project: "api"), slug: "northwind")
		let otherTeam = summary(vercel(team: "team_northwind_eu", project: "api"), slug: "northwind-eu")
		let acme = summary(vercel(team: "team_acme", name: "Acme", project: "web"), slug: "acme")
		#expect(VaultPublishMenu.Entry.entries(for: [storefront, sameTeam, acme], now: now).map(\.detail) == [
			"from .env.production · Northwind", "from .env.production · Northwind", "from .env.production · Acme",
		])
		#expect(VaultPublishMenu.Entry.entries(for: [storefront, otherTeam, acme], now: now).map(\.detail) == [
			"from .env.production · Northwind (northwind)", "from .env.production · Northwind (northwind-eu)", "from .env.production · Acme",
		])
	}

	@Test("a repository's row doesn't name its owner again, a Worker's pill says runtime, and a Coolify resource says where it is")
	func platformRows() {
		let github = PublishDestination(sourceEnvironment: "default", target: .github(repository), createdAt: now)
		let githubEntry = VaultPublishMenu.Entry(PublishDestinationSummary(destination: github, lastPublishedAt: nil), now: now)
		#expect(githubEntry.title == "northwind/storefront" && githubEntry.part == "Repository" && githubEntry.detail == "from .env")
		let workerEntry = VaultPublishMenu.Entry(PublishDestinationSummary(destination: worker(), lastPublishedAt: nil), now: now)
		#expect(workerEntry.title == "api" && workerEntry.part == "runtime" && workerEntry.detail == "from .env.production · Acme")
		let resource = PublishDestination(sourceEnvironment: "production", target: .coolify(coolify), createdAt: now)
		let resourceEntry = VaultPublishMenu.Entry(PublishDestinationSummary(destination: resource, lastPublishedAt: nil), now: now)
		#expect(resourceEntry.detail == "from .env.production · Root Team · Storefront / production on coolify.example.com")
	}

	@Test("the header names the environment every destination publishes from, and none when they differ")
	func sharedSource() {
		let production = PublishDestinationSummary(destination: vercel(team: "team_northwind", project: "storefront"), lastPublishedAt: nil)
		let alsoProduction = PublishDestinationSummary(destination: worker(), lastPublishedAt: nil)
		let staging = PublishDestinationSummary(destination: worker(source: "staging"), lastPublishedAt: nil)
		#expect(VaultPublishMenu.sharedSource(of: [production, alsoProduction]) == "production")
		#expect(VaultPublishMenu.sharedSource(of: [production, staging]) == nil)
		#expect(VaultPublishMenu.sharedSource(of: []) == nil)
	}

	@Test("↑ and ↓ start at the menu's first or last item and go around from either end")
	func keyboardOrder() {
		let first = UUID()
		let second = UUID()
		let items: [VaultPublishMenu.Item] = [.destination(first), .destination(second), .newDestination, .platforms]
		#expect(VaultPublishMenu.item(after: nil, by: 1, in: items) == .destination(first))
		#expect(VaultPublishMenu.item(after: nil, by: -1, in: items) == .platforms)
		#expect(VaultPublishMenu.item(after: .destination(second), by: 1, in: items) == .newDestination)
		#expect(VaultPublishMenu.item(after: .platforms, by: 1, in: items) == .destination(first))
		#expect(VaultPublishMenu.item(after: .destination(first), by: -1, in: items) == .platforms)
		#expect(VaultPublishMenu.item(after: .destination(UUID()), by: 1, in: items) == .destination(first), "A gone row starts over")
	}

	@Test("only ↑, ↓, Return, Enter and Esc without modifiers are the menu's keys")
	func menuKeys() {
		let arrow: NSEvent.ModifierFlags = [.numericPad, .function]
		#expect(VaultMenuKeys.key(modifiers: arrow, keyCode: 126) == .up)
		#expect(VaultMenuKeys.key(modifiers: arrow, keyCode: 125) == .down)
		#expect(VaultMenuKeys.key(modifiers: [], keyCode: 36) == .open)
		#expect(VaultMenuKeys.key(modifiers: .numericPad, keyCode: 76) == .open)
		#expect(VaultMenuKeys.key(modifiers: [], keyCode: 53) == .close)
		#expect(VaultMenuKeys.key(modifiers: arrow.union(.option), keyCode: 125) == nil, "⌥↓ stays with the sidebar")
		#expect(VaultMenuKeys.key(modifiers: .command, keyCode: 36) == nil)
		#expect(VaultMenuKeys.key(modifiers: [], keyCode: 0) == nil)
	}
}

@MainActor
struct PublishReviewPartsTests {
	@Test("the pills count what each planned action does, leaving out actions no key takes, with can't publish in red")
	func pills() {
		let pills = PublishSummaryPills.pills(for: PublishPlan.Summary(adding: 2, replacing: 1, blocked: 1, secrets: 3))
		#expect(pills.map(\.text) == ["2 add", "1 replace", "1 can't publish"])
		#expect(pills.map(\.tone) == [.add, .replace, .blocked])
		#expect(PublishSummaryPills.pills(for: PublishPlan.Summary(upToDate: 3, skipped: 1)).map(\.text) == ["3 up to date", "1 skipped"])
		#expect(PublishSummaryPills.pills(for: PublishPlan.Summary()).isEmpty)
	}

	@Test("a place splits into the place, the part written to and the account holding it, as each platform names them")
	func placeParts() {
		let targets: [(PublishTarget, String, String, String?)] = [
			(vercel(team: "team_northwind", project: "storefront").target, "storefront", "Production", "Northwind"),
			(.coolify(coolify), "api", "Production", "Root Team"),
			(.netlify(netlifyTarget(.production)), "storefront", "Production", "Northwind"),
			(.github(repository), "northwind/storefront", "Repository", nil),
			(worker().target, "api", "runtime", "Acme"),
		]
		for (target, title, part, account) in targets {
			#expect(target.placeTitle == title && target.placePart == part && target.placeAccountName == account, "\(target.platform)")
		}
		#expect(worker().target.placeName == "api / Worker secrets (runtime)", "A Worker's place keeps its full kind")
		#expect(PublishTarget.coolify(coolify).placeName == "api / Production")
	}

	@Test("a note reads as its lead, then the rest")
	func noteText() {
		#expect(PublishNote(.risk, "arrow.left.arrow.right", lead: "Existing secrets will be replaced.", "A change can be overwritten.").text
			== "Existing secrets will be replaced. A change can be overwritten.")
		#expect(PublishNote(.info, "clock", "Last published 2h ago.").text == "Last published 2h ago.")
	}
}

extension SheetInteractionTests {
	@Suite("Publish menu", .serialized)
	@MainActor
	struct PublishMenuInteractionTests {
		private let storefront = PublishDestinationSummary(
			destination: vercel(team: "team_northwind", project: "storefront"), lastPublishedAt: now.addingTimeInterval(-2 * 3600),
			accountDetail: "northwind")
		private let api = PublishDestinationSummary(destination: worker(), lastPublishedAt: nil)

		@MainActor
		private final class Record {
			var opened: [PublishDestination?] = []
			var platforms = 0
			var shown = true
		}

		private func menu(_ record: Record) -> SheetTestHost<some View> {
			SheetTestHost(
				VaultPublishMenu(
					summaries: [storefront, api], isPresented: Binding(get: { record.shown }, set: { record.shown = $0 }),
					onPublish: { record.opened.append($0) }, onPlatforms: { record.platforms += 1 }, now: { now })
					.padding(20),
				size: NSSize(width: 420, height: 320), keepsRequestedSize: true, usesHostingView: true)
		}

		@Test("the menu lists each saved destination with its pill, account and time, then New destination… and Platforms")
		func lists() async throws {
			let record = Record()
			let host = menu(record)
			defer { host.window.close() }
			#expect(try await host.waitForText("SAVED DESTINATIONS · 2"))
			#expect(try await host.waitForText("from .env.production", exactly: true), "Both publish from one environment")
			let row = try await host.waitForElement(saying: "storefront, Production, Vercel, from .env.production · Northwind, published 2h ago")
			#expect(row.role == .button && row.help?.hasSuffix("Through Northwind (northwind)") == true)
			#expect(try await host.waitForElement(saying: "api, runtime, Cloudflare, from .env.production · Acme, never published").role == .button)
			let order = host.lines().map(\.text)
			let positions = ["SAVED DESTINATIONS", "storefront", "api", "New destination…", "Platforms"].map { name in
				order.firstIndex { $0.contains(name) }
			}
			#expect(positions.allSatisfy { $0 != nil } && positions == positions.sorted { ($0 ?? 0) < ($1 ?? 0) }, "\(order)")
			try await host.click("api, runtime")
			#expect(record.opened.map { $0?.id } == [api.destination.id] && !record.shown)
		}

		@Test("↓ highlights the first destination and Return opens its review; ↑ from nothing highlights Platforms")
		func keyboard() async throws {
			let record = Record()
			let host = menu(record)
			defer { host.window.close() }
			let first = "storefront, Production"
			_ = try await host.waitForElement(saying: first)
			try host.press(.down)
			#expect(try await host.waitUntil { try highlighted(in: host) == [first] })
			try host.press(.down)
			#expect(try await host.waitUntil { try highlighted(in: host) == ["api, runtime"] })
			try host.press(.up)
			#expect(try await host.waitUntil { try highlighted(in: host) == [first] })
			try host.press(.return)
			#expect(try await host.waitUntil { record.opened.map { $0?.id } == [storefront.destination.id] })
			#expect(!record.shown)

			let other = Record()
			let platforms = menu(other)
			defer { platforms.window.close() }
			_ = try await platforms.waitForElement(saying: "Platforms")
			try platforms.press(.up)
			#expect(try await platforms.waitUntil { try highlighted(in: platforms) == ["Platforms"] })
			try platforms.press(.return)
			#expect(try await platforms.waitUntil { other.platforms == 1 })
			#expect(other.opened.isEmpty && !other.shown)
		}

		@Test("Return with nothing highlighted opens nothing, and Esc closes the menu")
		func escape() async throws {
			let record = Record()
			let host = menu(record)
			defer { host.window.close() }
			_ = try await host.waitForElement(saying: "New destination…")
			try host.press(.return)
			try await host.settle()
			#expect(record.opened.isEmpty && record.shown)
			try host.press(.escape)
			#expect(try await host.waitUntil { !record.shown })
			#expect(record.opened.isEmpty)
		}

		@Test("New destination… opens an empty Publish sheet, and Platforms opens the Platforms page")
		func actions() async throws {
			let record = Record()
			let host = menu(record)
			defer { host.window.close() }
			try await host.click("New destination…")
			#expect(record.opened.count == 1 && record.opened.first! == nil && !record.shown)
			record.shown = true
			try await host.click("Platforms")
			#expect(record.platforms == 1 && !record.shown)
		}

		@Test("in the workspace, Publish… opens the menu under itself, ending where it ends; a click outside closes it, and a row opens its review")
		func inWorkspace() async throws {
			let fixture = try WorkspaceFixture()
			defer { fixture.tearDown() }
			let destination = vercel(team: "team_northwind", project: "storefront")
			_ = try await fixture.store.publishing.save(destination, to: WorkspaceFixture.projectID).get()
			let host = try await fixture.workspace()
			defer { host.window.close() }
			#expect(try await host.waitUntil {
				AccessibilityTree.visibleElements(in: host.window, of: host.view)
					.contains { $0.says("Publish…") && $0.help == "Publish to a saved destination or a new one" }
			}, "Publish… shows the saved destination once it's read")
			try await host.click("Publish…")
			#expect(try await host.waitForText("SAVED DESTINATIONS · 1"))
			// The menu slides in, so its place is checked once it has arrived.
			let placed = try await host.waitUntil {
				guard let button = frame(of: "Publish…", in: host), let menu = frame(of: "Saved destinations", in: host) else { return false }
				return abs(menu.maxX - button.maxX) <= 1 && abs(button.minY - menu.maxY - 6) <= 1
			}
			let button = try await layoutFrame(of: "Publish…", in: host)
			let menu = try await layoutFrame(of: "Saved destinations", in: host)
			#expect(placed, "The menu ends where Publish… does, 6 points under it: \(menu) under \(button)")
			#expect(abs(menu.width - VaultPublishMenu.width) <= 1)
			let actions = try await layoutFrame(of: "Platforms", in: host)
			#expect(menu.minY < actions.minY && actions.minY - menu.minY < 12, "The menu is as tall as what it lists: \(menu), \(actions)")

			try NativeTestClick.send(to: host.window, at: NSPoint(x: 700, y: 120))
			#expect(try await host.waitForTextToDisappear("SAVED DESTINATIONS · 1"))
			#expect(host.window.attachedSheet == nil, "A click outside only closes the menu")

			try await host.click("Publish…")
			try await host.click("storefront, Production")
			#expect(try await host.waitUntil { host.window.attachedSheet != nil })
			let sheet = try #require(host.window.attachedSheet)
			#expect(try await host.waitForText("Saved destination · opens on Review.", in: sheet))
			#expect(try await host.waitForTextToDisappear("SAVED DESTINATIONS · 1"))
		}

		@Test("a click outside the account menu closes it too, and goes no further")
		func accountMenuOutsideClick() async throws {
			let fixture = try WorkspaceFixture()
			defer { fixture.tearDown() }
			let host = try await fixture.workspace()
			defer { host.window.close() }
			try await host.click("Account menu")
			#expect(try await host.waitForText("VAULTS"))
			try NativeTestClick.send(to: host.window, at: NSPoint(x: 700, y: 120))
			#expect(try await host.waitForTextToDisappear("VAULTS"))
			#expect(fixture.store.isUnlocked && fixture.store.selectedProjectId == WorkspaceFixture.projectID)
		}

		@Test("with more destinations than fit, the list scrolls under a fixed header and actions, and ↑ and ↓ scroll to the highlighted row")
		func scrolls() async throws {
			let summaries = (1...12).map { index in
				PublishDestinationSummary(destination: vercel(team: "team_northwind", project: "site-\(index)"), lastPublishedAt: nil)
			}
			var shown = true
			let host = SheetTestHost(
				VaultPublishMenu(summaries: summaries, isPresented: Binding(get: { shown }, set: { shown = $0 }), onPublish: { _ in },
					onPlatforms: {}, now: { now })
					.padding(20)
					.frame(maxHeight: .infinity, alignment: .top),
				size: NSSize(width: 420, height: 600), keepsRequestedSize: true, usesHostingView: true)
			defer { host.window.close() }
			let menu = try await layoutFrame(of: "Saved destinations", in: host)
			#expect(menu.height < 420, "The list stops at 300 points: \(menu)")
			#expect(try await host.waitForElement(saying: "Platforms").visibleFrame.isEmpty == false)
			let last = AccessibilityTree.elements(in: host.window).first { $0.says("site-12, Production", as: .leading) }
			#expect(last != nil && last?.visibleFrame.isEmpty == true, "The last rows are scrolled out of view")
			try host.press(.up)
			try host.press(.up)
			try host.press(.up)
			#expect(try await host.waitUntil { try highlighted(in: host, among: ["site-12, Production"]) == ["site-12, Production"] })
			#expect(try await host.waitUntil {
				AccessibilityTree.visibleElements(in: host.window, of: host.view).contains { $0.says("site-12, Production", as: .leading) && !$0.visibleFrame.isEmpty }
			}, "Highlighting the last row scrolls it into view")
			#expect(shown)
		}

		/// Where the element saying exactly `name` is in the host's view, from its bottom-left; nil while it isn't shown.
		private func frame<V: View>(of name: String, in host: SheetTestHost<V>) -> CGRect? {
			guard let element = AccessibilityTree.visibleElements(in: host.window, of: host.view).first(where: { $0.says(name, as: .exact) })
			else { return nil }
			let bounds = AccessibilityTree.normalizedBounds(of: element, in: host.view)
			let size = host.view.bounds.size
			return CGRect(x: bounds.minX * size.width, y: bounds.minY * size.height, width: bounds.width * size.width, height: bounds.height * size.height)
		}

		private func layoutFrame<V: View>(of name: String, in host: SheetTestHost<V>) async throws -> CGRect {
			let bounds = AccessibilityTree.normalizedBounds(of: try await host.waitForElement(saying: name), in: host.view)
			let size = host.view.bounds.size
			return CGRect(x: bounds.minX * size.width, y: bounds.minY * size.height, width: bounds.width * size.width, height: bounds.height * size.height)
		}

		private func highlighted<V: View>(in host: SheetTestHost<V>, among names: [String]) throws -> [String] {
			AccessibilityTree.visibleElements(in: host.window, of: host.view)
				.filter { $0.role == .button && $0.isSelected }
				.compactMap { element in names.first { element.says($0, as: .leading) } }
		}

		private func highlighted<V: View>(in host: SheetTestHost<V>) throws -> [String] {
			AccessibilityTree.visibleElements(in: host.window, of: host.view)
				.filter { $0.role == .button && $0.isSelected }
				.compactMap { element in
					["storefront, Production", "api, runtime", "New destination…", "Platforms"].first { element.says($0, as: .leading) }
				}
		}
	}
}

/// A workspace showing one project, as the window shows it.
@MainActor
private struct WorkspaceFixture {
	static let projectID = "publish-menu"

	let store: VaultStore
	let folder: String

	init() throws {
		folder = FileManager.default.temporaryDirectory.appending(path: "publish-menu-\(UUID().uuidString)").path
		try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
		let keychain = MockKeychainService()
		let project = VaultProject(id: Self.projectID, name: "billing-app", path: folder,
			environments: ["default": ["TOKEN": "a"], "production": ["TOKEN": "b"]])
		keychain.envStorage[project.id] = (name: project.name, path: project.path, environments: project.environments)
		store = VaultStore(keychainService: keychain, biometricService: MockBiometricService(),
			apiService: MockAPIService(), authTokenProvider: { _, _ in nil }, clipboard: ClipboardManager(pasteboard: .withUniqueName()))
		store.isUnlocked = true
		store.projects = [project]
		store.openProject(id: project.id)
	}

	func workspace() async throws -> SheetTestHost<some View> {
		await store.refreshCliAccess()
		let defaults = try #require(UserDefaults(suiteName: "publish-menu"))
		let host = SheetTestHost(VaultWorkspaceView(store: store).environment(UpdateChecker())
			.environment(VaultAppearanceSettings(defaults: defaults))
			.defaultAppStorage(defaults),
			size: NSSize(width: 1200, height: 700), keepsRequestedSize: true, usesHostingView: true)
		#expect(try await host.waitUntil { store.workspaceSnapshots[Self.projectID] != nil })
		#expect(try await host.waitForText("TOKEN"))
		try await host.settle()
		return host
	}

	func tearDown() {
		store.lock()
		try? FileManager.default.removeItem(atPath: folder)
	}
}
