import AppKit
import SwiftUI
import Testing
import Vision

@testable import LPMVault

@Suite("Vault appearance")
@MainActor
struct VaultAppearanceTests {
	@Test("new and unknown preferences follow macOS")
	func defaultFollowsSystem() throws {
		let (defaults, domain) = try isolatedDefaults()
		defer { defaults.removePersistentDomain(forName: domain) }
		for rawValue in [nil, "unknown"] as [String?] {
			defaults.set(rawValue, forKey: VaultAppearanceSettings.defaultsKey)
			let settings = VaultAppearanceSettings(defaults: defaults)
			#expect(settings.selection == .system)
			#expect(settings.selection.colorScheme == nil)
			#expect(settings.selection.nativeAppearance == nil)
		}
	}

	@Test("appearance choices survive relaunch without changing other preferences", arguments: VaultAppearance.allCases)
	func preferencePersists(choice: VaultAppearance) throws {
		let (defaults, domain) = try isolatedDefaults()
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

	@Test("explicit choices override either system appearance")
	func overrideMapping() {
		for systemScheme in [ColorScheme.light, .dark] {
			#expect((VaultAppearance.system.colorScheme ?? systemScheme) == systemScheme)
			#expect((VaultAppearance.light.colorScheme ?? systemScheme) == .light)
			#expect((VaultAppearance.dark.colorScheme ?? systemScheme) == .dark)
		}
		#expect(VaultAppearance.light.nativeAppearance?.name == .aqua)
		#expect(VaultAppearance.dark.nativeAppearance?.name == .darkAqua)
	}

	@Test("the palette preserves light colors and resolves the requested dark colors")
	func paletteColors() {
		let colors: [(Color, UInt, UInt)] = [
			(VaultPalette.content, 0xFFFFFF, 0x181818),
			(VaultPalette.titleBar, 0xF2F1F5, 0x181818),
			(VaultPalette.sidebar, 0xF7F7FA, 0x232323),
			(VaultPalette.inspector, 0xFAFAFC, 0x232323),
			(VaultPalette.control, 0xFFFFFF, 0x292929),
			(VaultPalette.border, 0xDCDBE2, 0x2B2B2B),
			(VaultPalette.titleBarBorder, 0xDEDDE3, 0x2B2B2B),
			(VaultPalette.sidebarBorder, 0xE4E3E9, 0x2B2B2B),
			(VaultPalette.textPrimary, 0x1C1C1E, 0xFFFFFF),
			(VaultPalette.textSecondary, 0x3C3C43, 0xA3A3A3),
			(VaultPalette.accent, 0x5E5CE6, 0x5E5CE6),
		]
		for (color, light, dark) in colors {
			for (scheme, hex) in [(ColorScheme.light, light), (.dark, dark)] {
				var environment = EnvironmentValues()
				environment.colorScheme = scheme
				let resolved = color.resolve(in: environment)
				#expect(abs(resolved.red - Float((hex >> 16) & 0xFF) / 255) < 0.001)
				#expect(abs(resolved.green - Float((hex >> 8) & 0xFF) / 255) < 0.001)
				#expect(abs(resolved.blue - Float(hex & 0xFF) / 255) < 0.001)
			}
		}
	}

	@Test("dark text and status labels retain readable contrast")
	func darkTextContrast() {
		var environment = EnvironmentValues()
		environment.colorScheme = .dark
		func luminance(_ color: Color) -> Double {
			let resolved = color.resolve(in: environment)
			func linear(_ value: Float) -> Double {
				let value = Double(value)
				return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
			}
			return 0.2126 * linear(resolved.red) + 0.7152 * linear(resolved.green) + 0.0722 * linear(resolved.blue)
		}
		for (foreground, background) in [
			(VaultPalette.textPrimary, VaultPalette.content),
			(VaultPalette.textSecondary, VaultPalette.control),
			(VaultPalette.accentForeground, VaultPalette.accentTint),
			(VaultPalette.greenTintText, VaultPalette.greenTint),
			(VaultPalette.orangeTintText, VaultPalette.orangeTint),
			(VaultPalette.redText, VaultPalette.redTint),
			(Color.white, VaultPalette.strongFill),
			(Color.white, VaultPalette.accentHover),
		] {
			let values = [luminance(foreground), luminance(background)].sorted()
			#expect((values[1] + 0.05) / (values[0] + 0.05) >= 4.5)
		}
	}

	@Test("settings expose a working appearance picker before and after sign-in", arguments: [false, true])
	func appearancePicker(signedIn: Bool) async throws {
		let (defaults, domain) = try isolatedDefaults()
		defer { defaults.removePersistentDomain(forName: domain) }
		let settings = VaultAppearanceSettings(defaults: defaults)
		let store = makeStore()
		if signedIn {
			store.currentUser = LPMUser(id: "theme-test", username: "demo", name: nil, email: nil,
				avatarUrl: nil, plan: "free", createdAt: nil, orgs: nil)
		}
		let host = NSHostingView(rootView: AuthStatusView(store: store).environment(settings))
		let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 700),
			styleMask: [.titled], backing: .buffered, defer: false)
		window.isReleasedWhenClosed = false
		window.contentView = host
		window.orderBack(nil)
		defer { window.close() }
		for _ in 0..<100 {
			host.layoutSubtreeIfNeeded()
			if segmentedControl(in: host) != nil { break }
			try await Task.sleep(for: .milliseconds(10))
		}
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

	@Test("workspace, settings, lock screen, and sheets render in both appearances", arguments: [ColorScheme.light, .dark])
	func appearanceRenders(scheme: ColorScheme) async throws {
		let (defaults, domain) = try isolatedDefaults()
		defer { defaults.removePersistentDomain(forName: domain) }
		let settings = VaultAppearanceSettings(defaults: defaults)
		settings.selection = scheme == .dark ? .dark : .light
		let store = makeStore()
		let project = VaultProject(id: "theme-preview-project", name: "demo-api", path: "/tmp/demo-api",
			environments: ["development": ["API_URL": "https://example.test", "PORT": "3000"],
				"production": ["API_URL": "https://example.test", "PORT": "8080"]])
		store.isUnlocked = true
		store.projects = [project]
		store.selectedProjectId = project.id
		store.selectedEnvironment = "development"
		defer { store.lock() }
		for _ in 0..<500 {
			if store.workspaceSnapshots[project.id] != nil { break }
			try await Task.sleep(for: .milliseconds(10))
		}
		_ = try #require(store.workspaceSnapshots[project.id])
		let suffix = scheme == .dark ? "dark" : "light"
		try render(ContentView(store: store).environment(UpdateChecker()).environment(settings),
			size: CGSize(width: 1200, height: 760), scheme: scheme, name: "workspace-\(suffix)",
			expectedText: ["All variables", "API_URL", "PORT"])
		try render(AuthStatusView(store: store).environment(settings),
			size: CGSize(width: 700, height: 700), scheme: scheme, name: "settings-\(suffix)",
			expectedText: ["APPEARANCE", "System", "Light", "Dark"])
		try render(AddSecretSheet(store: store, projectId: project.id, environment: "development"),
			size: CGSize(width: 420, height: 390), scheme: scheme, name: "new-key-\(suffix)",
			expectedText: ["New key", "KEY", "VALUE", "Cancel"])
		store.lock()
		try render(ContentView(store: store).environment(settings),
			size: CGSize(width: 1040, height: 640), scheme: scheme, name: "locked-\(suffix)",
			expectedText: ["LPM Vault is Locked", "Unlock"])
	}

	private func isolatedDefaults() throws -> (UserDefaults, String) {
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

	private func render<V: View>(_ view: V, size: CGSize, scheme: ColorScheme, name: String, expectedText: [String]) throws {
		let host = NSHostingView(rootView: view.environment(\.colorScheme, scheme).tint(VaultPalette.accent))
		host.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
		host.frame = NSRect(origin: .zero, size: size)
		host.layoutSubtreeIfNeeded()
		let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
		host.cacheDisplay(in: host.bounds, to: bitmap)
		let data = try #require(bitmap.representation(using: .png, properties: [:]))
		Attachment.record(data, named: name + ".png")
		let image = try #require(bitmap.cgImage)
		let request = VNRecognizeTextRequest()
		request.recognitionLevel = .accurate
		try VNImageRequestHandler(cgImage: image).perform([request])
		let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
		for label in expectedText {
			#expect(text.contains(label), "Missing \(label) in \(name): \(text)")
		}
	}
}
