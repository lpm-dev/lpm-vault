import AppKit
import SwiftUI
import Testing

@testable import LPMVault

@Suite("Vault appearance")
@MainActor
struct VaultAppearanceTests {
	@Test("new and unknown preferences follow macOS")
	func defaultFollowsSystem() throws {
		let (defaults, domain) = try Self.isolatedDefaults()
		defer { defaults.removePersistentDomain(forName: domain) }
		for rawValue in [nil, "unknown"] as [String?] {
			defaults.set(rawValue, forKey: VaultAppearanceSettings.defaultsKey)
			let settings = VaultAppearanceSettings(defaults: defaults)
			#expect(settings.selection == .system)
			#expect(settings.selection.nativeAppearance == nil)
		}
	}

	@Test("appearance choices survive relaunch without changing other preferences", arguments: VaultAppearance.allCases)
	func preferencePersists(choice: VaultAppearance) throws {
		let (defaults, domain) = try Self.isolatedDefaults()
		defer { defaults.removePersistentDomain(forName: domain) }
		defaults.set("production", forKey: "lpm-vault-environment")
		let settings = VaultAppearanceSettings(defaults: defaults)
		settings.selection = choice
		let restarted = VaultAppearanceSettings(defaults: try #require(UserDefaults(suiteName: domain)))
		#expect(restarted.selection == choice)
		#expect(defaults.string(forKey: "lpm-vault-environment") == "production")
		settings.selection = .system
		#expect(VaultAppearanceSettings(defaults: defaults).selection == .system)
	}

	@Test("explicit choices override either system appearance, and System leaves it to macOS")
	func overrideMapping() {
		#expect(VaultAppearance.system.nativeAppearance == nil)
		#expect(VaultAppearance.light.nativeAppearance?.name == .aqua)
		#expect(VaultAppearance.dark.nativeAppearance?.name == .darkAqua)
	}

	@Test("the palette keeps its light colors and resolves the near-black dark theme, with text as translucent white")
	func paletteColors() {
		let colors: [(color: Color, light: UInt, dark: UInt, darkOpacity: Float)] = [
			(VaultPalette.content, 0xFFFFFF, 0x121212, 1),
			(VaultPalette.titleBar, 0xFAFAFC, 0x101010, 1),
			(VaultPalette.sidebar, 0xF7F7FA, 0x101010, 1),
			(VaultPalette.sidebarSelection, 0xEAEAEA, 0x1C1C1E, 1),
			(VaultPalette.inspector, 0xFAFAFC, 0x101010, 1),
			(VaultPalette.control, 0xFFFFFF, 0x101010, 1),
			(VaultPalette.border, 0xDCDBE2, 0x262626, 1),
			(VaultPalette.titleBarBorder, 0xDCDBE2, 0x262626, 1),
			(VaultPalette.sidebarBorder, 0xE4E3E9, 0x262626, 1),
			(VaultPalette.divider, 0xECEAF0, 0x262626, 1),
			(VaultPalette.rowDivider, 0xF0EFF4, 0x191919, 1),
			(VaultPalette.rowHover, 0xFAFAFC, 0x161616, 1),
			(VaultPalette.headerHover, 0xF0EFF4, 0x262626, 1),
			(VaultPalette.textPrimary, 0x1C1C1E, 0xFFFFFF, 0.8),
			(VaultPalette.textSecondary, 0x3C3C43, 0xFFFFFF, 0.55),
			(VaultPalette.textTertiary, 0x6F6F75, 0xFFFFFF, 0.55),
			(VaultPalette.accentTint, 0xECEAFC, 0x29263D, 1),
			(VaultPalette.accentText, 0x2C2B4A, 0xD5D4FF, 1),
			(VaultPalette.accent, 0x5E5CE6, 0x5E5CE6, 1),
		]
		for entry in colors {
			for (scheme, hex, opacity) in [(ColorScheme.light, entry.light, Float(1)), (.dark, entry.dark, entry.darkOpacity)] {
				var environment = EnvironmentValues()
				environment.colorScheme = scheme
				let resolved = entry.color.resolve(in: environment)
				#expect(abs(resolved.red - Float((hex >> 16) & 0xFF) / 255) < 0.001, "\(entry.color) \(scheme)")
				#expect(abs(resolved.green - Float((hex >> 8) & 0xFF) / 255) < 0.001, "\(entry.color) \(scheme)")
				#expect(abs(resolved.blue - Float(hex & 0xFF) / 255) < 0.001, "\(entry.color) \(scheme)")
				#expect(abs(resolved.opacity - opacity) < 0.001, "\(entry.color) \(scheme)")
			}
		}
	}

	@Test("a hovered row steps away from the content the way a selected row does, but less", arguments: [ColorScheme.light, .dark])
	func rowStatesStepFromContent(scheme: ColorScheme) {
		var environment = EnvironmentValues()
		environment.colorScheme = scheme
		func lightness(_ color: Color) -> Float {
			let resolved = color.resolve(in: environment)
			return 0.2126 * resolved.linearRed + 0.7152 * resolved.linearGreen + 0.0722 * resolved.linearBlue
		}
		let content = lightness(VaultPalette.content)
		let hover = lightness(VaultPalette.rowHover) - content
		let selected = lightness(VaultPalette.rowSelected) - content
		#expect(hover != 0 && (hover > 0) == (selected > 0), "Hover moves \(hover) from the content, selection \(selected)")
		#expect(abs(hover) < abs(selected), "Hover moves \(hover) from the content, selection \(selected)")
	}

	@Test("dark text and status labels retain readable contrast")
	func darkTextContrast() {
		var environment = EnvironmentValues()
		environment.colorScheme = .dark
		func linear(_ value: Double) -> Double {
			value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
		}
		/// The luminance of `color` as it's drawn over `background`, which a translucent color shows through.
		func luminance(_ color: Color, over background: Color.Resolved? = nil) -> Double {
			let resolved = color.resolve(in: environment)
			let alpha = Double(resolved.opacity)
			func channel(_ value: Float, _ under: Float?) -> Double {
				linear(Double(value) * alpha + Double(under ?? 0) * (1 - alpha))
			}
			return 0.2126 * channel(resolved.red, background?.red) + 0.7152 * channel(resolved.green, background?.green)
				+ 0.0722 * channel(resolved.blue, background?.blue)
		}
		for (foreground, background) in [
			(VaultPalette.textPrimary, VaultPalette.content),
			(VaultPalette.textSecondary, VaultPalette.control),
			(VaultPalette.textTertiary, VaultPalette.sidebar),
			(VaultPalette.textTertiary, VaultPalette.content),
			(VaultPalette.accentForeground, VaultPalette.accentTint),
			(VaultPalette.accentText, VaultPalette.sidebarSelection),
			(VaultPalette.accentForeground, VaultPalette.sidebarSelection),
			(VaultPalette.greenTintText, VaultPalette.greenTint),
			(VaultPalette.orangeTintText, VaultPalette.orangeTint),
			(VaultPalette.redText, VaultPalette.redTint),
			(Color.white, VaultPalette.strongFill),
			(Color.white, VaultPalette.accentHover),
		] {
			let values = [luminance(foreground, over: background.resolve(in: environment)), luminance(background)].sorted()
			#expect((values[1] + 0.05) / (values[0] + 0.05) >= 4.5, "\(foreground) on \(background)")
		}
	}

	@Test("the Settings page's Appearance card exposes a working picker")
	func appearancePicker() async throws {
		let (defaults, domain) = try Self.isolatedDefaults()
		defer { defaults.removePersistentDomain(forName: domain) }
		let settings = VaultAppearanceSettings(defaults: defaults)
		let host = NSHostingView(rootView: VaultAppearanceSettingsSection().environment(settings))
		let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 700),
			styleMask: [.titled], backing: .buffered, defer: false)
		window.isReleasedWhenClosed = false
		window.contentView = host
		window.orderBack(nil)
		defer { window.close() }
		try #require(try await waitUntil {
			host.layoutSubtreeIfNeeded()
			return segmentedControl(in: host) != nil
		})
		let picker = try #require(segmentedControl(in: host))
		#expect(picker.segmentCount == 3)
		for (index, choice) in VaultAppearance.allCases.enumerated() {
			#expect(picker.label(forSegment: index) == choice.title)
		}
		for choice in [VaultAppearance.dark, .light, .system] {
			let index = try #require(VaultAppearance.allCases.firstIndex(of: choice))
			picker.selectedSegment = index
			#expect(picker.sendAction(picker.action, to: picker.target))
			#expect(settings.selection == choice)
			#expect(VaultAppearanceSettings(defaults: defaults).selection == choice)
		}
	}

	static func isolatedDefaults() throws -> (UserDefaults, String) {
		let domain = "dev.lpm.vault.appearance-tests.\(UUID().uuidString)"
		return (try #require(UserDefaults(suiteName: domain)), domain)
	}

	private func makeStore() -> VaultStore {
		VaultStore(keychainService: MockKeychainService(), biometricService: MockBiometricService(),
			apiService: MockAPIService(), authTokenProvider: { _, _ in nil })
	}

	private func segmentedControl(in view: NSView) -> NSSegmentedControl? {
		if let control = view as? NSSegmentedControl { return control }
		for child in view.subviews {
			if let control = segmentedControl(in: child) { return control }
		}
		return nil
	}

}

@Test("unknown CLI approval never advertises automatic access")
func unknownCliApprovalPresentationIsTruthful() {
	let presentation = VaultCliAccessPresentation(access: nil)
	#expect(presentation.help == "CLI approval is unavailable until its policy can be read.")
	#expect(presentation.accessibilityValue == "Unavailable")
}

extension SheetInteractionTests {
	/// Serialized with the other window tests because it changes the app's appearance.
	@Suite("App appearance", .serialized)
	@MainActor
	struct AppAppearanceTests {
		/// SwiftUI's `preferredColorScheme` pins the scene's window to the explicit
		/// choice and does not unpin it for System, so the window kept Light or Dark.
		/// The choice is applied app-wide instead, and windows inherit it.
		@Test("choosing System after Light or Dark follows the system appearance again", arguments: [VaultAppearance.light, .dark])
		func systemAfterExplicitChoice(explicit: VaultAppearance) async throws {
			let app = NSApplication.shared
			let previous = app.appearance
			defer { app.appearance = previous }
			app.appearance = nil
			let system = app.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
			let domain = "dev.lpm.vault.app-appearance-tests.\(UUID().uuidString)"
			let defaults = try #require(UserDefaults(suiteName: domain))
			defer { defaults.removePersistentDomain(forName: domain) }
			let settings = VaultAppearanceSettings(defaults: defaults)
			let host = SheetTestHost(AppearanceFixture(settings: settings), size: NSSize(width: 200, height: 100))
			defer { host.window.close() }
			try await host.settle()

			settings.selection = explicit
			try await host.settle()
			#expect(host.window.appearance == nil)
			#expect(host.window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == explicit.nativeAppearance?.name)

			settings.selection = .system
			try await host.settle()
			#expect(host.window.appearance == nil)
			#expect(host.window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == system)
		}
	}
}

private struct AppearanceFixture: View {
	let settings: VaultAppearanceSettings

	var body: some View {
		Color.clear.frame(width: 200, height: 100).vaultAppearance(settings.selection)
	}
}

extension SheetInteractionTests {
	@Suite("Vault appearance, rendered")
	@MainActor
	struct VaultAppearanceRenderingTests {
		@Test("workspace, settings, lock screen, and sheets render in both appearances", arguments: [ColorScheme.light, .dark])
		func appearanceRenders(scheme: ColorScheme) async throws {
			let (defaults, domain) = try VaultAppearanceTests.isolatedDefaults()
			defer { defaults.removePersistentDomain(forName: domain) }
			let settings = VaultAppearanceSettings(defaults: defaults)
			settings.selection = scheme == .dark ? .dark : .light
			let keychain = MockKeychainService()
			let store = VaultStore(keychainService: keychain, biometricService: MockBiometricService(),
				apiService: MockAPIService(), authTokenProvider: { _, _ in nil })
			let project = VaultProject(id: "theme-preview-project", name: "demo-api", path: "/tmp/demo-api",
				environments: ["development": ["API_URL": "https://example.test", "PORT": "3000"],
					"production": ["API_URL": "https://example.test", "PORT": "8080"]])
			keychain.envStorage[project.id] = (project.name, project.path, project.environments)
			keychain.envStorage["protected-preview"] = ("protected-api", "", ["default": [:]])
			keychain.cliAccessPolicies["protected-preview"] = .requireApproval
			store.isUnlocked = true
			store.projects = [project]
			store.selectedProjectId = project.id
			store.selectedEnvironment = "development"
			#expect(await store.loadProjects())
			defer { store.lock() }
			try #require(try await waitUntil { store.workspaceSnapshots[project.id] != nil })
			await store.refreshCliAccess()
			#expect(store.selectedProjectCliAccess == .automatic)
			let suffix = scheme == .dark ? "dark" : "light"
			try await render(ContentView(store: store).environment(UpdateChecker()).environment(settings),
				size: CGSize(width: 1200, height: 760), scheme: scheme, name: "workspace-\(suffix)",
				expectedText: ["All variables", "CLI", "API_URL", "PORT", "protected-api"])
			try await render(VaultAppearanceSettingsSection().environment(settings),
				size: CGSize(width: 520, height: 120), scheme: scheme, name: "settings-appearance-\(suffix)",
				expectedText: ["Theme", "System", "Light", "Dark"])
			try await render(VaultUpdateSettingsSection().environment(UpdateChecker()),
				size: CGSize(width: 520, height: 200), scheme: scheme, name: "settings-updates-\(suffix)",
				expectedText: ["Installed version", "Update channel", "Stable", "Nightly"])
			try await render(VaultGeneralSettingsSection().environment(VaultQuitSettings(defaults: defaults)),
				size: CGSize(width: 520, height: 120), scheme: scheme, name: "settings-general-\(suffix)",
				expectedText: ["Quit shortcut", "Direct", "Double press", "Hold"])
			try await render(VaultSettingsPage(store: store).environment(settings).environment(UpdateChecker())
				.environment(VaultQuitSettings(defaults: defaults)),
				size: CGSize(width: 700, height: 900), scheme: scheme, name: "settings-\(suffix)",
				expectedText: ["Settings", "SERVER", "GENERAL", "Quit shortcut", "APPEARANCE", "Theme", "UPDATES", "Installed version"])
			try await render(AddVariableSheet(store: store, projectId: project.id, environment: "development"),
				size: CGSize(width: 560, height: 520), scheme: scheme, name: "add-variable-\(suffix)",
				expectedText: ["Add variable", "Key", "Value", "Environments", "Cancel"])
			store.lock()
			try await render(ContentView(store: store).environment(settings),
				size: CGSize(width: 1040, height: 640), scheme: scheme, name: "locked-\(suffix)",
				expectedText: ["LPM Vault is Locked", "Unlock"])
		}

		private func render<V: View>(_ view: V, size: CGSize, scheme: ColorScheme, name: String, expectedText: [String]) async throws {
			let text = try await AccessibilityTree.text(of: view.environment(\.colorScheme, scheme).tint(VaultPalette.accent), size: size,
				appearance: NSAppearance(named: scheme == .dark ? .darkAqua : .aqua), attaching: name + ".png")
			for label in expectedText {
				#expect(text.contains(label), "Missing \(label) in \(name): \(text)")
			}
		}
	}
}
