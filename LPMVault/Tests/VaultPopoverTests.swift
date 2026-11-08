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
		let below = VaultPopoverPresenter.frame(size: size, beside: anchor, on: .bottom, within: screen)
		#expect(below.minX == anchor.minX)
		#expect(below.maxY == anchor.minY - VaultPopoverPresenter.gap)
		let low = CGRect(x: 400, y: 40, width: 80, height: 28)
		let flipped = VaultPopoverPresenter.frame(size: size, beside: low, on: .bottom, within: screen)
		#expect(flipped.minY == low.maxY + VaultPopoverPresenter.gap, "No room below, so it goes above")
	}

	@Test("a popover beside its view is centered on it, and goes to the other side when there's no room")
	func beside() {
		let anchor = CGRect(x: 600, y: 400, width: 28, height: 28)
		let leading = VaultPopoverPresenter.frame(size: size, beside: anchor, on: .leading, within: screen)
		#expect(leading.maxX == anchor.minX - VaultPopoverPresenter.gap)
		#expect(leading.midY == anchor.midY)
		let nearEdge = CGRect(x: 20, y: 400, width: 28, height: 28)
		let flipped = VaultPopoverPresenter.frame(size: size, beside: nearEdge, on: .leading, within: screen)
		#expect(flipped.minX == nearEdge.maxX + VaultPopoverPresenter.gap)
	}

	@Test("a popover stays inside the screen's margins")
	func staysOnScreen() {
		let anchor = CGRect(x: 1400, y: 600, width: 30, height: 28)
		let frame = VaultPopoverPresenter.frame(size: size, beside: anchor, on: .bottom, within: screen)
		#expect(frame.maxX <= screen.maxX - VaultPopoverPresenter.screenMargin)
		#expect(frame.minX >= screen.minX + VaultPopoverPresenter.screenMargin)
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
