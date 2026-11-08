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

	@Test("the palette resolves its light colors and the layered dark theme, with text as translucent white at four strengths")
	func paletteColors() {
		let colors: [(color: Color, light: UInt, dark: UInt, darkOpacity: Float)] = [
			(VaultPalette.content, 0xFFFFFF, 0x1C1C1F, 1),
			(VaultPalette.titleBar, 0xF8F8FA, 0x161618, 1),
			(VaultPalette.sidebar, 0xF6F6F8, 0x161618, 1),
			(VaultPalette.sidebarSelection, 0xE7E7EA, 0x2A2A2D, 1),
			(VaultPalette.inspector, 0xF8F8FA, 0x19191B, 1),
			(VaultPalette.control, 0xFFFFFF, 0x242428, 1),
			(VaultPalette.controlHover, 0xF1F1F4, 0x2D2D32, 1),
			(VaultPalette.card, 0xF8F8FA, 0x222225, 1),
			(VaultPalette.border, 0xDCDBE2, 0x3A3A3F, 1),
			(VaultPalette.titleBarBorder, 0xE2E1E7, 0x2C2C30, 1),
			(VaultPalette.sidebarBorder, 0xE2E1E7, 0x2C2C30, 1),
			(VaultPalette.divider, 0xEAE9EF, 0x343439, 1),
			(VaultPalette.rowDivider, 0xF0EFF4, 0x252528, 1),
			(VaultPalette.rowHover, 0xF2F2F6, 0x232328, 1),
			(VaultPalette.popover, 0xFFFFFF, 0x2A2A2F, 1),
			(VaultPalette.headerHover, 0xF0EFF4, 0x26262A, 1),
			(VaultPalette.textPrimary, 0x1C1C1E, 0xFFFFFF, 0.92),
			(VaultPalette.textSecondary, 0x45454C, 0xFFFFFF, 0.74),
			(VaultPalette.textTertiary, 0x5C5C64, 0xFFFFFF, 0.58),
			(VaultPalette.textFaint, 0x6C6C74, 0xFFFFFF, 0.48),
			(VaultPalette.accentTint, 0xEEEDFD, 0x2B2946, 1),
			(VaultPalette.accentText, 0x2E2C8A, 0xD5D4FF, 1),
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

	@Test("text, status labels and selected controls keep 4.5:1 contrast in both appearances", arguments: [ColorScheme.light, .dark])
	func textContrast(scheme: ColorScheme) {
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
			(VaultPalette.textFaint, VaultPalette.content),
			(VaultPalette.textFaint, VaultPalette.inspector),
			(VaultPalette.textFaint, VaultPalette.card),
			(VaultPalette.placeholder, VaultPalette.control),
			(VaultPalette.placeholder, VaultPalette.content),
			(VaultPalette.placeholder, VaultPalette.inspector),
			(VaultPalette.placeholder, VaultPalette.sidebar),
			(VaultPalette.textTertiary, VaultPalette.card),
			(VaultPalette.textSecondary, VaultPalette.inspector),
			(VaultPalette.selectedText, VaultPalette.selectedFill),
			(VaultPalette.accentForeground, VaultPalette.content),
			(VaultPalette.orangeTintText, VaultPalette.content),
			(Color.white, VaultPalette.accent),
			(Color.white, VaultPalette.accentHover),
		] {
			#expect(Self.contrast(foreground, on: background, in: scheme) >= 4.5, "\(foreground) on \(background) in \(scheme)")
		}
	}

	@Test("an off switch's edge keeps 3:1 against the cards and pages switches sit on, in both appearances",
		arguments: [ColorScheme.light, .dark])
	func switchBorderContrast(scheme: ColorScheme) {
		for surface in [VaultPalette.card, VaultPalette.content, VaultPalette.inspector] {
			#expect(Self.contrast(VaultPalette.switchOffBorder, on: surface, in: scheme) >= 3, "The switch's edge on \(surface) in \(scheme)")
		}
	}

	@Test("a text field's edge keeps 3:1 against the field and the surfaces fields sit on, in both appearances",
		arguments: [ColorScheme.light, .dark])
	func inputBorderContrast(scheme: ColorScheme) {
		for surface in [VaultPalette.control, VaultPalette.content, VaultPalette.inspector, VaultPalette.card, VaultPalette.headerRow] {
			#expect(Self.contrast(VaultPalette.inputBorder, on: surface, in: scheme) >= 3, "The field edge on \(surface) in \(scheme)")
		}
	}

	/// A filled button's focus ring was the accent on the accent, so keyboard focus didn't show on it.
	@Test("keyboard focus keeps 3:1 against a filled button and against a plain control's surroundings, in both appearances",
		arguments: [ColorScheme.light, .dark])
	func focusRingContrast(scheme: ColorScheme) {
		for fill in [VaultPalette.accent, VaultPalette.accentHover] {
			#expect(Self.contrast(VaultFocusRing.color(onFill: true), on: fill, in: scheme) >= 3, "Focus on \(fill) in \(scheme)")
		}
		for surface in [VaultPalette.content, VaultPalette.control, VaultPalette.inspector, VaultPalette.titleBar] {
			#expect(Self.contrast(VaultFocusRing.color(onFill: false), on: surface, in: scheme) >= 3, "Focus on \(surface) in \(scheme)")
		}
	}

	/// The contrast ratio of `foreground` drawn over `background`, which a translucent foreground shows through.
	static func contrast(_ foreground: Color, on background: Color, in scheme: ColorScheme) -> Double {
		var environment = EnvironmentValues()
		environment.colorScheme = scheme
		func linear(_ value: Double) -> Double {
			value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
		}
		func luminance(_ color: Color, over background: Color.Resolved? = nil) -> Double {
			let resolved = color.resolve(in: environment)
			let alpha = Double(resolved.opacity)
			func channel(_ value: Float, _ under: Float?) -> Double {
				linear(Double(value) * alpha + Double(under ?? 0) * (1 - alpha))
			}
			return 0.2126 * channel(resolved.red, background?.red) + 0.7152 * channel(resolved.green, background?.green)
				+ 0.0722 * channel(resolved.blue, background?.blue)
		}
		let values = [luminance(foreground, over: background.resolve(in: environment)), luminance(background)].sorted()
		return (values[1] + 0.05) / (values[0] + 0.05)
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
				expectedText: ["All Keys", "CLI", "API_URL", "PORT", "protected-api"])
			try await render(VaultAppearanceSettingsSection().environment(settings),
				size: CGSize(width: 520, height: 120), scheme: scheme, name: "settings-appearance-\(suffix)",
				expectedText: ["Theme", "System", "Light", "Dark"])
			try await render(VaultUpdateSettingsSection().environment(UpdateChecker()),
				size: CGSize(width: 520, height: 200), scheme: scheme, name: "settings-updates-\(suffix)",
				expectedText: ["Installed version", "Update channel", "Stable", "Nightly"])
			try await render(VaultGeneralSettingsSection().environment(VaultQuitSettings(defaults: defaults)),
				size: CGSize(width: 520, height: 120), scheme: scheme, name: "settings-general-\(suffix)",
				expectedText: ["Quit shortcut", "Direct", "Double press", "Hold"])
			for (category, text) in [(VaultSettingsCategory.general, "Quit shortcut"), (.appearance, "Theme"), (.account, "SERVER"), (.updates, "Installed version"),
				(.platforms, "connects in your browser")] {
				try await render(VaultSettingsOverlay(store: store, category: category).environment(settings).environment(UpdateChecker())
					.environment(VaultQuitSettings(defaults: defaults)),
					size: CGSize(width: 1040, height: 700), scheme: scheme, name: "settings-\(category.rawValue)-\(suffix)",
					expectedText: ["Settings", category.title, text, "General", "Appearance", "Account & Sync", "Platforms", "Updates"])
			}
			try await render(AddVariableSheet(store: store, projectId: project.id, environment: "development"),
				size: CGSize(width: 560, height: 520), scheme: scheme, name: "add-variable-\(suffix)",
				expectedText: ["New Key", "Key", "Value", "Environments", "Cancel"])
			store.lock()
			try await render(ContentView(store: store).environment(settings),
				size: CGSize(width: 1040, height: 640), scheme: scheme, name: "locked-\(suffix)",
				expectedText: ["LPM Vault is Locked", "Unlock"])
		}

		@Test("a default button that's off keeps its accent, faded, so it never reads as the Cancel beside it", arguments: [ColorScheme.light, .dark])
		func disabledDefaultButton(scheme: ColorScheme) async throws {
			let buttons = HStack(spacing: 12) {
				VaultBarButton(title: "Cancel") {}
				VaultBarButton(title: "Add Key", shortcut: "↩", filled: true, disabled: true) {}
			}
			.padding(20)
			.frame(maxWidth: .infinity, maxHeight: .infinity)
			.background(VaultPalette.content)
			let host = SheetTestHost(buttons, size: NSSize(width: 280, height: 72), keepsRequestedSize: true)
			defer { host.window.close() }
			host.view.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
			try await host.settle()
			let add = try await host.labelFrame("Add Key")
			let cancel = try await host.labelFrame("Cancel")
			let image = try host.snapshot(host.view)
			let context = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
				space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
			context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
			let pixels = try #require(context.data).assumingMemoryBound(to: UInt8.self)
			let scale = CGFloat(image.width) / host.view.bounds.width
			func color(at point: CGPoint) -> (red: Int, green: Int, blue: Int) {
				let pixel = (Int((host.view.bounds.height - point.y) * scale) * image.width + Int(point.x * scale)) * 4
				return (Int(pixels[pixel]), Int(pixels[pixel + 1]), Int(pixels[pixel + 2]))
			}
			// Inside each button's padding, clear of its title and of its edge.
			let addFill = color(at: CGPoint(x: add.minX + 4, y: add.midY))
			let cancelFill = color(at: CGPoint(x: cancel.minX + 4, y: cancel.midY))
			#expect(addFill.blue - max(addFill.red, addFill.green) > 10, "Add Key is tinted with the accent: \(addFill)")
			#expect(abs(addFill.blue - cancelFill.blue) + abs(addFill.red - cancelFill.red) > 15, "Add Key \(addFill), Cancel \(cancelFill)")
			if scheme == .dark {
				// Its title, the whitest ink across the button's middle, is dimmed as disabled text is, not near white as a working button's.
				var whitest = 0
				for x in stride(from: add.minX + 8, to: add.maxX - 8, by: 0.5) {
					let ink = color(at: CGPoint(x: x, y: add.midY))
					whitest = max(whitest, min(ink.red, ink.green, ink.blue))
				}
				#expect(whitest < 150, "In dark, the title of a button that's off is dim: \(whitest)")
			}
			#expect(!AccessibilityTree.visibleElements(in: host.window, of: host.view).contains { $0.texts.contains { $0.contains("↩") } },
				"Its shortcut waits until it's on")
		}

		@Test("a scroll view's content fades into the surface at its bottom edge, so a line cut there reads as more below")
		func bottomFade() async throws {
			let view = ScrollView { Color.black.frame(height: 600) }
				.vaultBottomFade(16)
				.frame(width: 120, height: 200)
				.background(Color.white)
			let host = SheetTestHost(view, size: NSSize(width: 120, height: 200), keepsRequestedSize: true)
			defer { host.window.close() }
			try await host.settle()
			let image = try host.snapshot(host.view)
			let context = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
				space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
			context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
			let pixels = try #require(context.data).assumingMemoryBound(to: UInt8.self)
			let scale = CGFloat(image.width) / host.view.bounds.width
			func red(atY y: CGFloat) -> Int {
				let pixel = (Int((host.view.bounds.height - y) * scale) * image.width + Int(60 * scale)) * 4
				return Int(pixels[pixel])
			}
			#expect(red(atY: 100) < 30, "The content shows as it is above the fade")
			#expect(red(atY: 1) > 200, "At the very edge, the surface shows: \(red(atY: 1))")
			#expect(red(atY: 8) > red(atY: 20), "And the fade runs toward it")
		}

		/// A stroked capsule drawn into a bitmap had short vertical marks at its
		/// round ends, beyond the curve, where the page should show.
		@Test("filter chips draw nothing past their round ends", arguments: [ColorScheme.light, .dark], [true, false])
		func chipEndsFollowTheirCurve(scheme: ColorScheme, selected: Bool) async throws {
			let chipHeight: CGFloat = 26, inset: CGFloat = 10
			let page = Color(nsColor: .init(srgbRed: 1, green: 1, blue: 1, alpha: 1))
			let view = VaultFilterChip(title: "All Keys", trailing: "12", selected: selected) {}
				.padding(inset)
				.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
				.background(page)
			let host = SheetTestHost(view, size: NSSize(width: 160, height: chipHeight + inset * 2), keepsRequestedSize: true, usesHostingView: true)
			defer { host.window.close() }
			host.window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
			try await host.settle()

			let image = try host.snapshot(host.view)
			let context = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
				bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
			context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
			let pixels = try #require(context.data).assumingMemoryBound(to: UInt8.self)
			let scale = CGFloat(image.width) / host.view.bounds.width
			func isPage(_ x: CGFloat, _ y: CGFloat) -> Bool {
				let offset = (Int(y * scale) * image.width + Int(x * scale)) * 4
				return (0..<3).allSatisfy { pixels[offset + $0] > 250 }
			}
			let middle = inset + chipHeight / 2
			let drawn = stride(from: 0, to: host.view.bounds.width, by: 0.5).filter { !isPage($0, middle) }
			let left = try #require(drawn.first), right = try #require(drawn.last)
			#expect(abs(left - inset) <= 0.5)
			#expect(right - left > chipHeight)

			// Near either end, the curve spans under 4 points either side of the middle. The marks
			// reached 5 to 7 points out. The left end sits on a pixel; the right end falls wherever
			// the title ends, so its edge blends a little further out.
			for (x, nearest) in [(left + 0.25, CGFloat(5)), (right - 0.25, 6)] {
				for offset in stride(from: nearest, through: 9, by: 0.5) {
					#expect(isPage(x, middle - offset), "Drawn above the curve at x \(x), \(offset) points up")
					#expect(isPage(x, middle + offset), "Drawn below the curve at x \(x), \(offset) points down")
				}
			}
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

/// Disabled controls kept showing the pointing hand, as if a click would do something.
@Suite("Pointing hand")
struct VaultPointingHandTests {
	@Test("a control shows the pointing hand only while the pointer is over it and it's enabled, and gives it back once")
	func followsHoverAndEnabled() {
		var state = VaultPointingHandState()
		#expect(state.update(hovering: true, enabled: false) == nil, "A disabled control keeps the arrow")
		#expect(state.update(hovering: false, enabled: false) == nil)
		#expect(state.update(hovering: true, enabled: true) == .push)
		#expect(state.update(hovering: true, enabled: true) == nil, "Hovering again pushes nothing more")
		#expect(state.update(hovering: true, enabled: false) == .pop, "Disabling under the pointer gives the arrow back")
		#expect(state.update(hovering: false, enabled: false) == nil, "Leaving after that pops nothing more")
		#expect(state.update(hovering: true, enabled: true) == .push)
		#expect(state.update(hovering: false, enabled: true) == .pop)
	}
}

@Suite("Value text")
struct VaultValueTextTests {
	@Test("a narrow cell shortens a URL to its scheme and host, never dropping the scheme, and leaves other values as they are")
	func urlOrigin() {
		#expect(VaultValueText.origin(of: "https://api.acme.io/v1/users") == "https://api.acme.io")
		#expect(VaultValueText.origin(of: "postgres+ssl://db.example.com:5432/app?sslmode=require") == "postgres+ssl://db.example.com:5432")
		#expect(VaultValueText.origin(of: "https://api.acme.io?debug=1") == "https://api.acme.io")
		#expect(VaultValueText.origin(of: "http://localhost:3000") == nil, "Nothing after the host to leave out")
		#expect(VaultValueText.origin(of: "https://api.acme.io/") == nil)
		#expect(VaultValueText.origin(of: "k3J9x2Lq8vR4mP7wZ1nB5cT6") == nil)
		#expect(VaultValueText.origin(of: "://nothing-before/x") == nil)
		#expect(VaultValueText.origin(of: "not a url: https://example.com/x") == nil, "Only a value that begins with a scheme is a URL")
	}

}
