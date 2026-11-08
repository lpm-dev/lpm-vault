import AppKit
import SwiftUI
import Testing

@testable import LPMVault

@Suite("The app's popover and menu list")
struct VaultPopoverTests {
	private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
	private let size = CGSize(width: 240, height: 120)

	@Test("a popover sits below its view from the view's leading edge, or above it when the screen ends")
	func belowOrAbove() {
		let anchor = CGRect(x: 400, y: 600, width: 80, height: 28)
		let below = VaultPopoverPresenter.frame(size: size, beside: anchor, on: .bottom, window: screen, screen: screen)
		#expect(below.minX == anchor.minX)
		#expect(below.maxY == anchor.minY - VaultPopoverPresenter.gap)
		let low = CGRect(x: 400, y: 40, width: 80, height: 28)
		let flipped = VaultPopoverPresenter.frame(size: size, beside: low, on: .bottom, window: screen, screen: screen)
		#expect(flipped.minY == low.maxY + VaultPopoverPresenter.gap, "No room below, so it goes above")
	}

	@Test("a popover beside its view is centered on it, and goes to the other side when there's no room")
	func beside() {
		let anchor = CGRect(x: 600, y: 400, width: 28, height: 28)
		let leading = VaultPopoverPresenter.frame(size: size, beside: anchor, on: .leading, window: screen, screen: screen)
		#expect(leading.maxX == anchor.minX - VaultPopoverPresenter.gap)
		#expect(leading.midY == anchor.midY)
		let nearEdge = CGRect(x: 20, y: 400, width: 28, height: 28)
		let flipped = VaultPopoverPresenter.frame(size: size, beside: nearEdge, on: .leading, window: screen, screen: screen)
		#expect(flipped.minX == nearEdge.maxX + VaultPopoverPresenter.gap)
	}

	@Test("a popover stays inside the screen's margins")
	func staysOnScreen() {
		let anchor = CGRect(x: 1400, y: 600, width: 30, height: 28)
		let frame = VaultPopoverPresenter.frame(size: size, beside: anchor, on: .bottom, window: screen, screen: screen)
		#expect(frame.maxX <= screen.maxX - VaultPopoverPresenter.screenMargin)
		#expect(frame.minX >= screen.minX + VaultPopoverPresenter.screenMargin)
	}

	@Test("a popover stays inside its window when there's room, rather than running past its edge")
	func staysInWindow() {
		let window = CGRect(x: 100, y: 50, width: 1280, height: 754)
		let anchor = CGRect(x: 1000, y: 400, width: 120, height: 28)
		let wide = CGSize(width: 540, height: 300)
		let frame = VaultPopoverPresenter.frame(size: wide, beside: anchor, on: .bottom, window: window, screen: screen)
		#expect(frame.maxX <= window.maxX - VaultPopoverPresenter.screenMargin, "It moves left to end inside the window")
		#expect(frame.maxY == anchor.minY - VaultPopoverPresenter.gap, "It still opens below")
	}

	@Test("a menu has the larger of the room below and above its view inside the window, so a long one scrolls rather than covering the title bar")
	func roomBesideView() {
		let window = CGRect(x: 0, y: 100, width: 1280, height: 754)
		let anchor = CGRect(x: 1000, y: 452, width: 120, height: 28)
		let room = VaultPopoverPresenter.room(beside: anchor, on: .bottom, window: window, screen: screen)
		let above = window.maxY - VaultPopoverPresenter.windowMargin - anchor.maxY - VaultPopoverPresenter.gap
		#expect(room == above, "More room above than below")
		let size = CGSize(width: 320, height: room)
		let frame = VaultPopoverPresenter.frame(size: size, beside: anchor, on: .bottom, window: window, screen: screen)
		#expect(frame.maxY <= window.maxY - VaultPopoverPresenter.windowMargin && frame.minY > anchor.maxY, "A menu that tall fits above, inside the window")
	}

	@Test("a window too small to hold a menu gives it the screen's room instead, so its rows still show")
	func roomInSmallWindow() {
		let window = CGRect(x: 400, y: 400, width: 240, height: 80)
		let anchor = CGRect(x: 420, y: 420, width: 80, height: 28)
		let room = VaultPopoverPresenter.room(beside: anchor, on: .bottom, window: window, screen: screen)
		#expect(room >= VaultPopoverPresenter.minimumRoom, "\(room)")
		#expect(room == screen.maxY - VaultPopoverPresenter.screenMargin - anchor.maxY - VaultPopoverPresenter.gap)
	}

	@Test("a menu too wide to run right from its view hangs back from the view's trailing edge, as a menu near the edge does")
	func hangsFromTrailingEdge() {
		let window = CGRect(x: 0, y: 0, width: 1280, height: 754)
		let anchor = CGRect(x: 1100, y: 400, width: 120, height: 28)
		let frame = VaultPopoverPresenter.frame(size: CGSize(width: 320, height: 200), beside: anchor, on: .bottom, window: window, screen: screen)
		#expect(frame.maxX == anchor.maxX)
	}

	@Test("a popover that doesn't fit below its view inside the window opens above it there, not past the window's bottom")
	func flipsInsideWindow() {
		let window = CGRect(x: 100, y: 150, width: 1280, height: 740)
		let anchor = CGRect(x: 400, y: 400, width: 120, height: 28)
		let frame = VaultPopoverPresenter.frame(size: CGSize(width: 240, height: 300), beside: anchor, on: .bottom, window: window, screen: screen)
		#expect(frame.minY == anchor.maxY + VaultPopoverPresenter.gap)
		#expect(frame.maxY <= window.maxY - VaultPopoverPresenter.screenMargin)
	}

	@Test("a popover too big for the room in its window goes where the screen has room")
	func screenWhenWindowIsFull() {
		let window = CGRect(x: 100, y: 300, width: 1040, height: 400)
		let anchor = CGRect(x: 400, y: 480, width: 120, height: 28)
		let frame = VaultPopoverPresenter.frame(size: CGSize(width: 240, height: 320), beside: anchor, on: .bottom, window: window, screen: screen)
		#expect(frame.maxY == anchor.minY - VaultPopoverPresenter.gap, "Below, past the window, as a menu goes")
		#expect(frame.minY >= screen.minY + VaultPopoverPresenter.screenMargin)
	}

	@Test("the area a popover may use leaves out the window's title bar, unless the popover's view is in it")
	func clearOfTitleBar() {
		let screen = CGRect(x: 0, y: 0, width: 1440, height: 1200)
		let window = CGRect(x: 100, y: 50, width: 1280, height: 800)
		let content = CGRect(x: 400, y: 500, width: 120, height: 28)
		#expect(VaultPopoverPresenter.area(of: window, for: content).maxY == window.maxY - VaultMetrics.titleBar)
		let inTitleBar = CGRect(x: 1100, y: window.maxY - 37, width: 120, height: 28)
		#expect(VaultPopoverPresenter.area(of: window, for: inTitleBar) == window)
		let tall = CGSize(width: 240, height: 400)
		let frame = VaultPopoverPresenter.frame(size: tall, beside: content, on: .top, window: VaultPopoverPresenter.area(of: window, for: content), screen: screen)
		#expect(frame.maxY <= window.maxY - VaultMetrics.titleBar, "No room above under the title bar, so it opens below")
	}

	@Test("the arrow keys step through a menu's enabled rows, around from either end")
	@MainActor
	func menuSteps() {
		typealias List = VaultMenuList<Int>
		let rows: [List.Row] = [
			.init(id: 1, title: "One"), .init(id: 2, title: "Two", isEnabled: false), .init(id: 3, title: "Three"),
		]
		#expect(List.row(after: nil, by: 1, in: rows) == 1)
		#expect(List.row(after: nil, by: -1, in: rows) == 3)
		#expect(List.row(after: 1, by: 1, in: rows) == 3, "A row that can't be chosen is stepped over")
		#expect(List.row(after: 3, by: 1, in: rows) == 1)
		#expect(List.row(after: 1, by: -1, in: rows) == 3)
		#expect(List.row(after: nil, by: 1, in: [List.Row(id: 9, title: "Off", isEnabled: false)]) == nil)
	}
}

@Suite("Menu columns")
struct VaultMenuColumnTests {
	@Test("a long menu splits at section starts into columns as even as they can be, keeping its order")
	@MainActor
	func balancedColumns() {
		typealias List = VaultMenuList<String>
		func section(_ name: String, _ count: Int) -> [List.Row] {
			(0..<count).map { List.Row(id: "\(name)\($0)", title: "\(name)\($0)", section: $0 == 0 ? name : nil) }
		}
		// Presence, Shape, Defaults and Exposure, as the Add rule menu lists them.
		let rows = section("P", 4) + section("S", 5) + section("D", 2) + section("E", 3)
		let columns = List.columns(of: rows, count: 2)
		#expect(columns.map { $0.map(\.id) } == [
			["P0", "P1", "P2", "P3", "S0", "S1", "S2", "S3", "S4"], ["D0", "D1", "E0", "E1", "E2"],
		])
		#expect(List.columns(of: rows, count: 1).count == 1)
		#expect(List.columns(of: section("P", 3), count: 2).count == 1, "One section stays whole")
		#expect(List.columns(of: rows, count: 2).flatMap { $0 }.map(\.id) == rows.map(\.id), "Reading order is kept")
	}
}

@Suite("The sync menu's explanation")
@MainActor
struct VaultSyncExplanationTests {
	private let date = Date(timeIntervalSinceReferenceDate: 815_000_000)

	@Test("it says what each sync state means, with the last sync's direction and time when one is known")
	func explanations() {
		let shown = date.formatted(date: .abbreviated, time: .shortened)
		#expect(VaultTitleBarView.syncExplanation(isLoggedIn: false, status: .synced, last: nil)
			== "Values stay on this Mac. Sign in to sync them with lpm.dev.")
		#expect(VaultTitleBarView.syncExplanation(isLoggedIn: true, status: nil, last: nil) == "Choose a project to sync it.")
		#expect(VaultTitleBarView.syncExplanation(isLoggedIn: true, status: .synced, last: (date, true))
			== "Matches lpm.dev as of the last push, \(shown).")
		#expect(VaultTitleBarView.syncExplanation(isLoggedIn: true, status: .localChanges, last: (date, false))
			== "Changed on this Mac since the last pull, \(shown).")
		#expect(VaultTitleBarView.syncExplanation(isLoggedIn: true, status: .localChanges, last: nil)
			== "Changed on this Mac since the last sync.")
		#expect(VaultTitleBarView.syncExplanation(isLoggedIn: true, status: .neverSynced, last: nil)
			== "Not pulled or pushed with this account yet.")
	}
}

extension SheetInteractionTests {
	@Suite("The app's popover window", .serialized)
	@MainActor
	struct VaultPopoverWindowTests {
		@Test("a popover open as its window closes goes with it, leaving no window behind")
		func closesWithItsWindow() async throws {
			let host = SheetTestHost(PopoverFixture(), size: NSSize(width: 320, height: 200), keepsRequestedSize: true, usesHostingView: true)
			try await host.click("Open")
			let popover = try await host.popoverWindow()
			#expect(try await host.waitForText("Inside", in: popover))
			host.window.close()
			#expect(try await host.waitUntil { !popover.isVisible }, "The popover's window is gone with its own")
		}

		@Test("a menu's arrow keys and Return choose a row, however quickly they're pressed")
		func keyboardChoice() async throws {
			let chosen = ChosenMenuRow()
			let host = SheetTestHost(MenuFixture(chosen: chosen), size: NSSize(width: 320, height: 240), keepsRequestedSize: true, usesHostingView: true)
			defer { host.window.close() }
			try await host.click("Choose")
			let menu = try await host.popoverWindow()
			#expect(try await host.waitForText("Second", in: menu))
			try host.key("\u{f701}", code: 125, modifiers: [.numericPad, .function], in: menu)
			try host.key("\u{f701}", code: 125, modifiers: [.numericPad, .function], in: menu)
			try host.key("\r", code: 36, in: menu)
			#expect(try await host.waitUntil { chosen.id == 2 }, "Down twice from the start is the second row")
			#expect(try await host.waitUntil { !menu.isVisible })
		}
	}
}

@MainActor
private final class ChosenMenuRow {
	var id: Int?
}

private struct MenuFixture: View {
	let chosen: ChosenMenuRow

	var body: some View {
		VaultBarMenu(accessibilityLabel: "Choose", rows: [
			VaultMenuList<Int>.Row(id: 1, title: "First"), .init(id: 2, title: "Second"), .init(id: 3, title: "Third"),
		], onChoose: { chosen.id = $0 }) {
			Text("Choose")
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
	}
}

private struct PopoverFixture: View {
	@State private var isPresented = false

	var body: some View {
		Button("Open") { isPresented = true }
			.vaultPopover(isPresented: $isPresented) { Text("Inside").padding(20) }
			.frame(maxWidth: .infinity, maxHeight: .infinity)
	}
}
