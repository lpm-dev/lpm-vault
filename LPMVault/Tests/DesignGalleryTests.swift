import AppKit
import SwiftUI
import Testing

@testable import LPMVault

/// Where the design gallery writes its pictures: the folder `LPM_VAULT_GALLERY`
/// names. The gallery runs only when it's set.
enum DesignGallery {
	static let folder = ProcessInfo.processInfo.environment["LPM_VAULT_GALLERY"].map { URL(fileURLWithPath: $0, isDirectory: true) }
}

extension SheetInteractionTests {
	/// Renders the window's pages and main sheets in both appearances, with
	/// sample projects, as PNG files for design review:
	/// `LPM_VAULT_GALLERY=/tmp/gallery swift test --package-path LPMVault --filter DesignGallery`.
	@Suite("Design gallery", .serialized, .enabled(if: DesignGallery.folder != nil))
	@MainActor
	struct DesignGalleryTests {
		private static let projectID = "storefront-api"
		private static let sidebar = CGRect(x: 0, y: 0, width: 0.25, height: 1)
		private static let now = Date(timeIntervalSince1970: 1_793_800_000)
		private static let size = NSSize(width: 1280, height: 800)

		private static let initial: [String: [String: String]] = [
			"default": [
				"DATABASE_URL": "postgres://localhost:5432/storefront",
				"NEXT_PUBLIC_API_URL": "http://localhost:3000",
				"STRIPE_SECRET_KEY": "sk_test_51Mz9aLocal",
				"SMTP_PASSWORD": "local-mail-password",
				"REDIS_URL": "redis://localhost:6379",
				"LOG_LEVEL": "debug",
				"JWT_SECRET": "dev-only-jwt-secret-value",
				"PORT": "3000",
			],
			"staging": [
				"DATABASE_URL": "postgres://db.stg.internal:5432/storefront",
				"NEXT_PUBLIC_API_URL": "https://api.stg.acme.io",
				"STRIPE_SECRET_KEY": "sk_test_51Mz9aStaging",
				"SMTP_PASSWORD": "staging-mail-password",
				"REDIS_URL": "redis://redis.stg.internal:6379",
				"LOG_LEVEL": "info",
				"SENTRY_DSN": "https://4f1@o42.ingest.sentry.io/77",
				"JWT_SECRET": "staging-jwt-secret-value-0001",
				"PORT": "3000",
			],
			"production": [
				"DATABASE_URL": "postgres://db.prod.internal:5432/storefront",
				"NEXT_PUBLIC_API_URL": "https://api.acme.io",
				"STRIPE_SECRET_KEY": "sk_live_51Mz9aProduction",
				"REDIS_URL": "redis://redis.prod.internal:6379",
				"LOG_LEVEL": "warn",
				"SENTRY_DSN": "https://9c2@o42.ingest.sentry.io/78",
				"JWT_SECRET": "production-jwt-secret-value-0001",
				"PORT": "8080",
			],
		]

		private static var edited: [String: [String: String]] {
			var values = initial
			values["production"]?["LOG_LEVEL"] = "error"
			values["production"]?["STRIPE_SECRET_KEY"] = "sk_live_51Mz9aRotated"
			values["staging"]?["FEATURE_FLAGS"] = "checkout-v2,search-beta"
			return values
		}

		private static let lpmJSON = #"""
			{"envSchema":{
				"vars":{
					"DATABASE_URL":{"secret":true,"format":"url","required":true,"description":"Primary Postgres connection string."},
					"NEXT_PUBLIC_API_URL":{"client":true,"format":"url","protocols":["https"],"requiredIn":[{"environment":["production"]}]},
					"STRIPE_SECRET_KEY":{"secret":true,"minLength":16,"description":"Server-side Stripe key."},
					"SMTP_PASSWORD":{"secret":true,"requiredIn":[{"environment":["production"]}]},
					"PORT":{"format":"port","default":"3000"},
					"LOG_LEVEL":{"enum":["debug","info","warn","error"],"default":"info"},
					"JWT_SECRET":{"secret":true,"minLength":24}
				}
			}}
			"""#

		private struct Fixture {
			let store: VaultStore
			let folder: String
		}

		private func makeFixture(locked: Bool = false, empty: Bool = false) throws -> Fixture {
			let folder = FileManager.default.temporaryDirectory.appending(path: "design-gallery-\(UUID().uuidString)").path
			try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
			try Self.lpmJSON.write(toFile: folder + "/lpm.json", atomically: true, encoding: .utf8)
			let service = KeychainService(testingService: "dev.lpm.vault.gallery.\(UUID().uuidString)", backend: InMemoryKeychainBackend())
			let store = VaultStore(keychainService: service, biometricService: MockBiometricService(), apiService: MockAPIService(),
				authTokenProvider: { _, _ in nil }, clipboard: ClipboardManager(pasteboard: .withUniqueName()))
			if !empty {
				guard case .success = service.createEnvironments(
					vaultId: Self.projectID, projectName: "storefront-api", projectPath: folder, environments: Self.initial,
					source: VaultHistorySource(.set, at: Self.now.addingTimeInterval(-86_400 * 2)))
				else { throw KeychainError.encodingFailed }
				guard case .success = service.applyVaultTransaction(
					project: .update(vaultId: Self.projectID, environments: Self.edited,
						source: VaultHistorySource(.editKey, at: Self.now.addingTimeInterval(-900))),
					data: [])
				else { throw KeychainError.encodingFailed }
				for (id, name, environments) in [
					("web-dashboard", "web-dashboard", ["default": ["NEXT_PUBLIC_POSTHOG_KEY": "phc_local", "AUTH_SECRET": "a"], "production": ["NEXT_PUBLIC_POSTHOG_KEY": "phc_live", "AUTH_SECRET": "b"]]),
					("billing-worker", "billing-worker", ["default": ["QUEUE_URL": "amqp://localhost", "STRIPE_WEBHOOK_SECRET": "whsec_1"]]),
				] {
					guard case .success = service.createEnvironments(
						vaultId: id, projectName: name, projectPath: "", environments: environments,
						source: VaultHistorySource(.set, at: Self.now.addingTimeInterval(-86_400 * 5)))
					else { throw KeychainError.encodingFailed }
				}
				store.projects = try [Self.projectID, "web-dashboard", "billing-worker"].map {
					try #require(try service.getProjectResult(vaultId: $0).get())
				}
			}
			store.isUnlocked = !locked
			if !empty, !locked { store.openProject(id: Self.projectID) }
			return Fixture(store: store, folder: folder)
		}

		private func host<V: View>(_ root: V, store: VaultStore, dark: Bool, size: NSSize = Self.size) async throws -> SheetTestHost<some View> {
			let defaults = try #require(UserDefaults(suiteName: "design-gallery-\(UUID().uuidString)"))
			let now = Self.now
			let host = SheetTestHost(root.environment(UpdateChecker())
				.environment(VaultAppearanceSettings(defaults: defaults)).environment(VaultQuitSettings(defaults: defaults))
				.defaultAppStorage(defaults)
				.environment(\.vaultClock, VaultClock { now })
				// Controls draw as they do in the frontmost window, with their accent colors.
				.environment(\.controlActiveState, .key),
				size: size, keepsRequestedSize: true, usesHostingView: true)
			host.window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
			// The test runner starts as a background process, whose windows never become key.
			NSApp.setActivationPolicy(.regular)
			NSApp.activate(ignoringOtherApps: true)
			host.window.makeKeyAndOrderFront(nil)
			try await host.settle()
			return host
		}

		private func save<V: View>(_ host: SheetTestHost<V>, _ name: String, dark: Bool, window: NSWindow? = nil) async throws {
			let folder = try #require(DesignGallery.folder)
			try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
			try await host.settle()
			let target = try #require(window?.contentView ?? host.view)
			let image = try host.snapshot(target)
			let data = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
			try data.write(to: folder.appending(path: "\(name)-\(dark ? "dark" : "light").png"))
		}

		/// The window with a popover open over it, drawn where it shows, with the shadow its window casts.
		private func saveWithPopover<V: View>(_ host: SheetTestHost<V>, _ name: String, dark: Bool, popover: NSWindow) async throws {
			let folder = try #require(DesignGallery.folder)
			try await host.settle()
			let base = try host.snapshot(host.view)
			let card = try host.snapshot(try #require(popover.contentView))
			let scale = CGFloat(base.width) / host.view.bounds.width
			let view = host.window.convertToScreen(host.view.convert(host.view.bounds, to: nil))
			let context = try #require(CGContext(data: nil, width: base.width, height: base.height, bitsPerComponent: 8, bytesPerRow: 0,
				space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
			context.draw(base, in: CGRect(x: 0, y: 0, width: base.width, height: base.height))
			context.setShadow(offset: CGSize(width: 0, height: -6 * scale), blur: 18 * scale,
				color: NSColor.black.withAlphaComponent(dark ? 0.45 : 0.16).cgColor)
			context.draw(card, in: CGRect(x: (popover.frame.minX - view.minX) * scale, y: (popover.frame.minY - view.minY) * scale,
				width: CGFloat(card.width), height: CGFloat(card.height)))
			let image = try #require(context.makeImage())
			let data = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
			try data.write(to: folder.appending(path: "\(name)-\(dark ? "dark" : "light").png"))
		}

		private func closePopover<V: View>(_ popover: NSWindow, in host: SheetTestHost<V>) async throws {
			try host.key("\u{1b}", code: 53, in: popover)
			_ = try await host.waitUntil { !popover.isVisible }
		}

		private func sheet<V: View>(of host: SheetTestHost<V>) async throws -> NSWindow {
			#expect(try await host.waitUntil { host.window.sheets.first != nil })
			let sheet = try #require(host.window.sheets.first)
			sheet.appearance = host.window.appearance
			return sheet
		}

		@Test("workspace pages", arguments: [false, true])
		func workspacePages(dark: Bool) async throws {
			let fixture = try makeFixture()
			defer { fixture.store.lock(); try? FileManager.default.removeItem(atPath: fixture.folder) }
			let store = fixture.store
			// Loading reads every project's CLI approval, as unlocking does.
			#expect(await store.loadProjects())
			await store.refreshCliAccess()
			let host = try await host(VaultWorkspaceView(store: store), store: store, dark: dark)
			defer { host.window.close() }
			#expect(try await host.waitUntil { store.workspaceSnapshots[Self.projectID] != nil })
			_ = try await host.waitUntil { store.keyDescriptions[Self.projectID]?.schema?.overview != nil }
			try await save(host, "01-matrix", dark: dark)

			try await host.click("STRIPE_SECRET_KEY")
			#expect(try await host.waitForText("VALUES", exactly: true))
			try await save(host, "02-matrix-inspector", dark: dark)

			try await host.click("More for the .env value")
			let more = try await host.popoverWindow()
			try await saveWithPopover(host, "18-popover-value-more", dark: dark, popover: more)
			try await closePopover(more, in: host)

			_ = try await host.clickSidebarEnvironment(".env.production")
			#expect(try await host.waitForText("ACTIONS", exactly: true))
			try await save(host, "03-environment", dark: dark)

			try await host.click("Schema", region: Self.sidebar)
			#expect(try await host.waitForText("7 declared keys"))
			try await save(host, "04-schema", dark: dark)

			try await host.click("Client Prefixes")
			let prefixes = try await host.popoverWindow()
			try await saveWithPopover(host, "16-popover-client-prefixes", dark: dark, popover: prefixes)
			try await closePopover(prefixes, in: host)

			try await host.click("PORT")
			#expect(try await host.waitForText("Add Rule"))
			try await host.click("Add Rule")
			let rules = try await host.popoverWindow()
			try await saveWithPopover(host, "17-popover-add-rule", dark: dark, popover: rules)
			try await closePopover(rules, in: host)

			try await host.click("History", region: Self.sidebar)
			#expect(try await host.waitForText("Changed 3 keys"))
			try await save(host, "05-history", dark: dark)
			try await host.click("Changed 3 keys")
			try await save(host, "06-history-inspector", dark: dark)

			try host.choose("Project Settings…", in: try await host.contextMenu(of: "storefront-api", region: Self.sidebar))
			try await save(host, "07-project-settings", dark: dark)

			// The project card shows beside a row the pointer rests on, which a test can't do, so it's drawn alone, from the same store.
			let card = try await self.host(
				VaultProjectHoverCard(store: store, project: try #require(store.projects.first { $0.id == Self.projectID }))
					.background(VaultPalette.popover)
					.clipShape(RoundedRectangle(cornerRadius: 10))
					.overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(VaultPalette.popoverBorder, lineWidth: 1) }
					.padding(24)
					.frame(maxWidth: .infinity, maxHeight: .infinity)
					.background(VaultPalette.sidebar),
				store: store, dark: dark, size: NSSize(width: 340, height: 300))
			defer { card.window.close() }
			#expect(try await card.waitForText("Changed"), "The card reads the history the History page shows")
			try await save(card, "20-project-card", dark: dark)
		}

		/// Signed in, on a Keychain mock that platform connections can read.
		@Test("sheets and account pages", arguments: [false, true])
		func sheetsAndAccountPages(dark: Bool) async throws {
			let keychain = MockKeychainService()
			let projects = [
				VaultProject(id: Self.projectID, name: "storefront-api", path: "", environments: Self.edited),
				VaultProject(id: "web-dashboard", name: "web-dashboard", path: "", environments: ["default": ["AUTH_SECRET": "a"]]),
			]
			for project in projects {
				keychain.envStorage[project.id] = (name: project.name, path: "", environments: project.environments)
				keychain.cliAccessPolicies[project.id] = .automatic
			}
			let store = VaultStore(keychainService: keychain, biometricService: MockBiometricService(), apiService: MockAPIService(),
				authTokenProvider: { _, _ in "lpm_session" }, platformURLOpener: { _ in },
				clipboard: ClipboardManager(pasteboard: .withUniqueName()))
			store.projects = projects
			store.isUnlocked = true
			store.currentUser = LPMUser(id: "lpm_user_1", username: "avery", name: "Avery Chen", email: "avery@acme.io",
				avatarUrl: nil, plan: nil, createdAt: nil, orgs: [LPMOrg(id: "org_1", slug: "acme", name: "Acme Inc", avatarUrl: nil, role: "owner")])
			store.openProject(id: Self.projectID)
			defer { store.lock() }
			// Loading reads every project's CLI approval, as unlocking does.
			#expect(await store.loadProjects())
			await store.refreshCliAccess()
			let host = try await host(VaultWorkspaceView(store: store), store: store, dark: dark)
			defer { host.window.close() }
			#expect(try await host.waitUntil { store.workspaceSnapshots[Self.projectID] != nil })
			try await host.click("Sync status")
			let sync = try await host.popoverWindow()
			try await saveWithPopover(host, "15-popover-sync", dark: dark, popover: sync)
			try await closePopover(sync, in: host)

			try await host.click("New Key")
			let addKey = try await sheet(of: host)
			try await save(host, "10-sheet-new-key", dark: dark, window: addKey)
			try await host.click("Cancel", in: addKey)
			_ = try await host.waitUntil { host.window.sheets.isEmpty }

			try await host.click("Connect CLI")
			let connect = try await sheet(of: host)
			try await save(host, "11-sheet-connect-cli", dark: dark, window: connect)
			try await host.click("Close", in: connect)
			_ = try await host.waitUntil { host.window.sheets.isEmpty }

			store.showPlatforms()
			try await save(host, "08-platforms", dark: dark)

			store.showSettings()
			try await save(host, "09-settings", dark: dark)

			try await host.click("Account menu")
			#expect(try await host.waitForText("Manage Account on lpm.dev"))
			try await save(host, "19-account-menu", dark: dark)
		}

		@Test("lock screen, empty vault, and the smallest window", arguments: [false, true])
		func otherStates(dark: Bool) async throws {
			let locked = try makeFixture(locked: true)
			defer { try? FileManager.default.removeItem(atPath: locked.folder) }
			let lockHost = try await host(ContentView(store: locked.store), store: locked.store, dark: dark)
			try await save(lockHost, "12-locked", dark: dark)
			lockHost.window.close()

			let empty = try makeFixture(empty: true)
			defer { empty.store.lock(); try? FileManager.default.removeItem(atPath: empty.folder) }
			let emptyHost = try await host(VaultWorkspaceView(store: empty.store), store: empty.store, dark: dark)
			try await save(emptyHost, "13-empty", dark: dark)
			emptyHost.window.close()

			let small = try makeFixture()
			defer { small.store.lock(); try? FileManager.default.removeItem(atPath: small.folder) }
			#expect(await small.store.loadProjects())
			await small.store.refreshCliAccess()
			let smallHost = try await host(VaultWorkspaceView(store: small.store), store: small.store, dark: dark, size: NSSize(width: 1040, height: 640))
			defer { smallHost.window.close() }
			#expect(try await smallHost.waitUntil { small.store.workspaceSnapshots[Self.projectID] != nil })
			try await smallHost.click("JWT_SECRET")
			#expect(try await smallHost.waitForText("VALUES", exactly: true))
			try await save(smallHost, "14-small-window", dark: dark)
		}
	}
}
