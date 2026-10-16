import AppKit
import SwiftUI
import Testing

extension SheetInteractionTests {
	@Suite("Accessibility tree reading", .serialized)
	@MainActor
	struct AccessibilityTreeTests {
		@Test("text, buttons, fields and headings are found by what they say, and only what's in view is said")
		func readsWhatViewsSay() async throws {
			var saves = 0
			let host = SheetTestHost(TreeFixture { saves += 1 }, size: NSSize(width: 480, height: 320), keepsRequestedSize: true)
			defer { host.window.close() }
			try await host.settle()
			#expect(try await host.waitForText("Project Settings"))
			let text = try await host.text()
			#expect(text.contains("Shown in the sidebar"))
			#expect(text.contains("Pressed 0"))
			#expect(!text.contains("Hidden caption"), "A hidden view says nothing")
			#expect(!text.contains("Below the fold"), "Text scrolled out of view isn't said")
			let save = try await host.waitForElement(saying: "Save")
			#expect(save.role == .button)
			#expect(save.help == "Saves the project")
			#expect(try await host.waitForElement(saying: "Project Settings").role?.rawValue == "AXHeading")
			let field = try await host.waitForElement(saying: "demo-api")
			#expect(field.role == .textField)
			#expect(field.placeholder == "Project name")
			try await host.click("Save")
			#expect(try await host.waitUntil { saves == 1 })
			#expect(try await host.waitForText("Pressed 1"))
			#expect(try await host.waitForTextToDisappear("Pressed 0"))
		}

		@Test("a region limits where a label is looked for, and a phrase can span the elements of one line")
		func regionsAndLines() async throws {
			var copied: [String] = []
			let host = SheetTestHost(RowsFixture { copied.append($0) }, size: NSSize(width: 480, height: 200), keepsRequestedSize: true)
			defer { host.window.close() }
			try await host.settle()
			try await host.click("Copy", region: CGRect(x: 0.5, y: 0, width: 0.5, height: 1))
			#expect(try await host.waitUntil { copied == ["right"] })
			try await host.click("Copy", region: CGRect(x: 0, y: 0, width: 0.5, height: 1))
			#expect(try await host.waitUntil { copied == ["right", "left"] })
			#expect(try await host.text().contains("API_KEY Copy 3 environments Copy"), "One line reads left to right across its elements")
			let lines = AccessibilityTree.lines(in: host.view, region: CGRect(x: 0, y: 0, width: 0.5, height: 1))
			#expect(lines.contains { $0.text.contains("API_KEY") })
			#expect(!lines.contains { $0.text.contains("3 environments") }, "Text outside the region isn't read")
		}

		@Test("clicking a segmented control selects the segment under the point without waiting on a mouse-up")
		func clicksTrackingControls() async throws {
			let host = SheetTestHost(SegmentsFixture(), size: NSSize(width: 360, height: 120), keepsRequestedSize: true)
			defer { host.window.close() }
			try await host.settle()
			try await host.click("Emoji")
			#expect(try await host.waitForText("Showing Emoji"))
			try await host.click("Icons")
			#expect(try await host.waitForText("Showing Icons"))
		}

		@Test("a click finds the element saying the label, then one beginning with it, then one saying it as whole words")
		func matchingTiers() async throws {
			var clicked: [String] = []
			let host = SheetTestHost(MatchingFixture { clicked.append($0) }, size: NSSize(width: 480, height: 260), keepsRequestedSize: true)
			defer { host.window.close() }
			try await host.settle()
			try await host.click("PORT")
			try await host.click("Exactly one of")
			try await host.click("REGION")
			try await host.click("Save")
			#expect(try await host.waitUntil { clicked.count == 4 })
			#expect(clicked == ["port row", "mode option", "region row", "save"],
				"PORT isn't found in Import; a label beginning with the words beats one that only holds them")
		}

		@Test("a row partly scrolled out of view is clicked where it shows, and one scrolled out isn't said")
		func readsWhatScrollAreasShow() async throws {
			var clicked: [String] = []
			let host = SheetTestHost(ScrolledRowsFixture { clicked.append($0) }, size: NSSize(width: 320, height: 220), keepsRequestedSize: true)
			defer { host.window.close() }
			try await host.settle()
			let text = try await host.text()
			#expect(text.contains("Row two"))
			#expect(!text.contains("Row three"), "A row the scroll area doesn't show isn't said, though it's inside the window")
			try await host.click("Row two")
			#expect(try await host.waitUntil { !clicked.isEmpty })
			#expect(clicked == ["Row two"], "The click lands on the part of the row that shows, not below the scroll area")
		}

		@Test("a host keeps the size it asks for when that's larger than the screen, as a runner's small screen is")
		func keepsSizeLargerThanScreen() async throws {
			let screen = try #require(NSScreen.main?.visibleFrame.size)
			let size = NSSize(width: screen.width + 400, height: screen.height + 300)
			let host = SheetTestHost(Text("Wide").frame(maxWidth: .infinity, maxHeight: .infinity), size: size, keepsRequestedSize: true)
			defer { host.window.close() }
			try await host.settle()
			#expect(host.window.contentLayoutRect.size == size)
			#expect(host.view.frame.size == size)
		}

		@Test("a sheet is read in its own window")
		func readsSheets() async throws {
			let host = SheetTestHost(SheetFixture(), size: NSSize(width: 520, height: 360))
			defer { host.window.close() }
			let sheet = try #require(try await host.waitUntil { host.window.attachedSheet != nil } ? host.window.attachedSheet : nil)
			#expect(try await host.waitForText("Quit with unsaved changes?", in: sheet))
			#expect(try await !host.text().contains("Quit with unsaved changes?"), "The window behind the sheet doesn't say the sheet's text")
		}
	}

	@Test("native clicks ignore controls outside the visible window")
	func clippedNativeButtonsAreNotClicked() async throws {
		let visible = NativeClicks(), clipped = NativeClicks()
		let fixture = ClippedButtonFixture(visibleAction: { visible.count += 1 }, clippedAction: { clipped.count += 1 })
		let host = SheetTestHost(fixture.frame(width: 620, height: 240), size: NSSize(width: 620, height: 240), keepsRequestedSize: true)
		defer { host.window.close() }
		try await host.settle()
		try await host.click("CLIPPED BUTTON")
		#expect(visible.count == 1)
		#expect(clipped.count == 0)
	}

	@Test("a native button is clicked as itself, enabled or not", arguments: [true, false])
	func nativeButtonsAreClickedDirectly(enabled: Bool) async throws {
		let clicks = NativeClicks()
		let host = SheetTestHost(NativeButtonFixture(enabled: enabled) { clicks.count += 1 }.disabled(!enabled), size: NSSize(width: 620, height: 240))
		defer { host.window.close() }
		try await host.settle()
		try await host.click("NATIVE BUTTON")
		#expect(clicks.count == (enabled ? 1 : 0))
		let point = host.view.convert(NSPoint(x: host.view.bounds.midX, y: host.view.bounds.midY), to: nil)
		try NativeTestClick.send(to: host.window, at: point)
		#expect(clicks.count == (enabled ? 2 : 0))
	}
}

private struct TreeFixture: View {
	let onSave: () -> Void
	@State private var presses = 0

	var body: some View {
		VStack(alignment: .leading, spacing: 8) {
			Text("Project Settings").font(.title2).accessibilityAddTraits(.isHeader)
			Text("Shown in the sidebar and the title bar.")
			Text("Hidden caption").hidden()
			TextField("Project name", text: .constant("demo-api"))
			Button("Save") {
				presses += 1
				onSave()
			}
			.help("Saves the project")
			Text("Pressed \(presses)")
			ScrollView {
				VStack {
					Color.clear.frame(height: 400)
					Text("Below the fold")
				}
			}
			.frame(height: 60)
		}
		.padding()
		.frame(width: 480, height: 320, alignment: .topLeading)
	}
}

private struct RowsFixture: View {
	let onCopy: (String) -> Void

	var body: some View {
		VStack {
			HStack {
				Text("API_KEY")
				Button("Copy") { onCopy("left") }
				Spacer()
				Text("3 environments")
				Button("Copy") { onCopy("right") }
			}
			.padding()
			Spacer()
		}
		.frame(width: 480, height: 200)
	}
}

private struct MatchingFixture: View {
	let onClick: (String) -> Void

	var body: some View {
		VStack(alignment: .leading, spacing: 6) {
			Button("Import env project from lpm.dev") { onClick("import") }
			Button("auth, Exactly one of PASSWORD, TOKEN") { onClick("group row") }
			Button("PORT, HTTP port the server listens on") { onClick("port row") }
			Button("Exactly one of: one key set, the others unset") { onClick("mode option") }
			Button("ACME_PUBLIC_REGION, Public") { onClick("region row") }
			Button("Save to lpm.json") { onClick("save to") }
			Button("Save") { onClick("save") }
		}
		.padding()
		.frame(width: 480, height: 260, alignment: .topLeading)
	}
}

/// A scroll area 100 points tall showing all of its first 80-point row and
/// a quarter of its second, over a button that catches a click below it.
private struct ScrolledRowsFixture: View {
	let onClick: (String) -> Void

	var body: some View {
		VStack(spacing: 0) {
			ScrollView {
				VStack(spacing: 0) {
					ForEach(["Row one", "Row two", "Row three"], id: \.self) { row in
						Button { onClick(row) } label: {
							Text(row).frame(maxWidth: .infinity, minHeight: 80, alignment: .topLeading).contentShape(Rectangle())
						}
						.buttonStyle(.plain)
					}
				}
			}
			.frame(height: 100)
			Button { onClick("below") } label: {
				Text("Below").frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle())
			}
			.buttonStyle(.plain)
		}
		.frame(width: 320, height: 220)
	}
}

private struct SegmentsFixture: View {
	@State private var tab = "Icons"

	var body: some View {
		VStack {
			Picker("Kind", selection: $tab) {
				ForEach(["Icons", "Emoji"], id: \.self) { Text($0).tag($0) }
			}
			.pickerStyle(.segmented)
			.labelsHidden()
			.fixedSize()
			Text("Showing \(tab)")
		}
		.frame(width: 360, height: 120)
	}
}

private struct SheetFixture: View {
	@State private var presented = true

	var body: some View {
		Text("Behind the sheet")
			.frame(width: 520, height: 360)
			.sheet(isPresented: $presented) {
				Text("Quit with unsaved changes?").padding(40)
			}
	}
}

private struct ClippedButtonFixture: NSViewRepresentable {
	let visibleAction: @MainActor () -> Void
	let clippedAction: @MainActor () -> Void
	func makeCoordinator() -> Coordinator { Coordinator(visible: visibleAction, clipped: clippedAction) }
	func makeNSView(context: Context) -> NSView {
		let view = NSView(frame: NSRect(x: 0, y: 0, width: 620, height: 240))
		for (y, action) in [(300.0, #selector(Coordinator.clipped)), (40.0, #selector(Coordinator.visible))] {
			let button = NSButton(title: "CLIPPED BUTTON", target: context.coordinator, action: action)
			button.frame = NSRect(x: 30, y: y, width: 160, height: 30)
			view.addSubview(button)
		}
		return view
	}
	func updateNSView(_ nsView: NSView, context: Context) {}
	@MainActor
	final class Coordinator: NSObject {
		let visibleAction: @MainActor () -> Void
		let clippedAction: @MainActor () -> Void
		init(visible: @escaping @MainActor () -> Void, clipped: @escaping @MainActor () -> Void) {
			visibleAction = visible
			clippedAction = clipped
		}
		@objc func visible() { visibleAction() }
		@objc func clipped() { clippedAction() }
	}
}

@MainActor
private final class NativeClicks {
	var count = 0
}

private struct NativeButtonFixture: NSViewRepresentable {
	let enabled: Bool
	let action: @MainActor () -> Void
	func makeCoordinator() -> Coordinator { Coordinator(action: action) }
	func makeNSView(context: Context) -> NSButton {
		let button = NSButton(title: "NATIVE BUTTON", target: context.coordinator, action: #selector(Coordinator.click))
		button.isEnabled = enabled
		return button
	}
	func updateNSView(_ nsView: NSButton, context: Context) { nsView.isEnabled = enabled }
	@MainActor
	final class Coordinator: NSObject {
		let action: @MainActor () -> Void
		init(action: @escaping @MainActor () -> Void) { self.action = action }
		@objc func click() { action() }
	}
}
