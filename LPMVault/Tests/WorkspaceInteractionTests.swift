import AppKit
import SwiftUI
import Testing

@testable import LPMVault

extension SheetInteractionTests {
	@Suite("Workspace interaction regressions", .serialized)
	@MainActor
		struct WorkspaceInteractionTests {
			@Test("table backgrounds and dividers fill the trailing gutter and space after shrinking", arguments: [false, true])
			func tableTrailingFiller(singleEnvironment: Bool) async throws {
				let (store, _) = makeStore(environments: ["default": ["ALPHA": "a", "ZULU": "z"], "production": ["ALPHA": "b", "ZULU": "z"]])
				defer { store.lock() }
				let host = try await workspace(store)
				defer { host.window.close() }
				try selectRow(0, in: host)
				#expect(try await host.waitForText("VALUES", exactly: true))
				if singleEnvironment {
					try await host.clickSidebarEnvironment(".env")
					#expect(try await host.waitForText("ACTIONS", exactly: true))
				}
				let finalLabel = singleEnvironment ? "Resize Actions column" : "Resize .env.production column"
				let last = try #require(resizeViews(in: host.view).first { $0.accessibilityLabel() == finalLabel })
				let rowHeight = singleEnvironment ? VaultMetrics.fileRow : VaultMetrics.matrixRow
				try await host.settle()
				let original = last.convert(last.bounds, to: nil)
				let referenceX = VaultMetrics.sidebar + VaultMetrics.paneDivider + 5
				for shrunken in [false, true] {
					if shrunken {
						for divider in resizeViews(in: host.view) where divider.accessibilityLabel()?.hasSuffix(" column") == true {
							divider.onDragEnded?(-2000)
							try await host.settle()
						}
					}
					let frame = last.convert(last.bounds, to: nil)
					let targetX = original.midX + 6
					let image = try host.snapshot(host.view)
					let samples = Int((VaultMetrics.tableHeader + 2 * rowHeight) * CGFloat(image.height) / host.view.bounds.height)
					let reference = try verticalPixels(in: image, size: host.view.bounds.size, x: referenceX,
						from: frame.maxY, count: samples)
					let trailing = try verticalPixels(in: image, size: host.view.bounds.size, x: targetX,
						from: frame.maxY, count: samples)
					let fillsTrailing = reference == trailing
					#expect(fillsTrailing, "Header, selected row, and row dividers must reach the trailing edge (shrunken: \(shrunken))")
					Attachment.record(try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])),
						named: "trailing-\(singleEnvironment ? "environment" : "matrix")-\(shrunken).png")
				}
			}

			@Test("column widths survive Settings and a project reload", arguments: [false, true])
			func tableWidthsSurviveContentReplacement(singleEnvironment: Bool) async throws {
				let keychain = MockKeychainService()
				let (store, _) = makeStore(keychain: keychain)
				defer { store.lock() }
				let host = try await workspace(store)
				defer { host.window.close() }
				if singleEnvironment {
					try await host.clickSidebarEnvironment(".env")
					#expect(try await host.waitForText("ACTIONS", exactly: true))
				}
				let divider = try #require(resizeViews(in: host.view).first { $0.accessibilityLabel() == "Resize Key column" })
				divider.onDragEnded?(-2000)
				#expect(try await host.waitUntil { divider.accessibilityValue() as? String == "160 points" })
				// Settings shows over the table, which stays as it was under it.
				store.showSettings()
				#expect(try await host.waitForText("Close Settings"))
				store.openProject(id: "workspace")
				#expect(try await host.waitUntil {
					resizeViews(in: host.view).first { $0.accessibilityLabel() == "Resize Key column" }?.accessibilityValue() as? String == "160 points"
				})
				let gate = DispatchSemaphore(value: 0)
				defer { gate.signal() }
				store.selectedProjectId = nil
				keychain.blockNextListProjects = { _ = gate.wait(timeout: .now() + testWaitSeconds) }
				store.openProject(id: "workspace")
				#expect(try await host.waitForText("Loading Workspace"))
				gate.signal()
				#expect(try await host.waitUntil { resizeViews(in: host.view).contains { $0.accessibilityLabel() == "Resize Key column" } })
				if singleEnvironment {
					try await host.clickSidebarEnvironment(".env")
					#expect(try await host.waitForText("ACTIONS", exactly: true))
				}
				try await host.settle()
				let reloaded = try #require(resizeViews(in: host.view).first { $0.accessibilityLabel() == "Resize Key column" })
				#expect(reloaded.accessibilityValue() as? String == "160 points")
			}

			@Test("each project retains its own matrix column widths")
			func tableWidthsAreProjectSpecific() async throws {
				let (store, _) = makeStore(additionalProject: true)
				defer { store.lock() }
				let host = try await workspace(store)
				defer { host.window.close() }
				let divider = try #require(resizeViews(in: host.view).first { $0.accessibilityLabel() == "Resize Key column" })
				divider.onDragEnded?(-2000)
				try await host.settle()
				store.openProject(id: "other")
				#expect(try await host.waitForText("SECOND"))
				let other = try #require(resizeViews(in: host.view).first { $0.accessibilityLabel() == "Resize Key column" })
				// Its own default: fitted to its short keys, not the other project's 160 points.
				#expect(other.accessibilityValue() as? String == "\(Int(VaultTableColumnLayout.fittedKeyMinimum)) points")
				other.onDragEnded?(80)
				try await host.settle()
				store.openProject(id: "workspace")
				#expect(try await host.waitForText("TOKEN"))
				let restored = try #require(resizeViews(in: host.view).first { $0.accessibilityLabel() == "Resize Key column" })
				#expect(restored.accessibilityValue() as? String == "160 points")
				store.openProject(id: "other")
				#expect(try await host.waitForText("SECOND"))
				let otherRestored = try #require(resizeViews(in: host.view).first { $0.accessibilityLabel() == "Resize Key column" })
				#expect(otherRestored.accessibilityValue() as? String == "\(Int(VaultTableColumnLayout.fittedKeyMinimum) + 80) points")
			}

			@Test("a narrow key column keeps an edited drifting key visible, its unsaved dot the last mark in one environment's table")
			func narrowKeyWithBothBadges() async throws {
				let key = "LONG_DATABASE_AUTHENTICATION_TOKEN"
				let (store, _) = makeStore(environments: ["default": [key: "a"], "production": [key: "b"]])
				defer { store.lock() }
				let host = try await workspace(store)
				defer { host.window.close() }
				try selectRow(0, in: host)
				try await host.settle()
				try host.enterValue("unsaved-value")
				try await host.clickSidebarEnvironment(".env")
				#expect(try await host.waitForText("ACTIONS", exactly: true))
				let divider = try #require(resizeViews(in: host.view).first { $0.accessibilityLabel() == "Resize Key column" })
				divider.onDragEnded?(-2000)
				try await host.settle()
				let frame = divider.convert(divider.bounds, to: nil)
				let size = host.view.bounds.size
				let region = CGRect(x: (frame.midX - VaultTableColumn.key.minimumWidth) / size.width, y: 0.05,
					width: VaultTableColumn.key.minimumWidth / size.width, height: 0.8)
				let image = try host.snapshot(host.view)
				let row = CGRect(x: frame.midX - 70, y: frame.minY - VaultMetrics.fileRow + 6, width: 64, height: VaultMetrics.fileRow - 12)
				let unsaved = try compactIndicatorProfiles(in: image, size: size, region: row)
				#expect(unsaved.count == 1, "Expected the orange unsaved dot: \(unsaved)")
				// Drift is between environments, so one environment's table doesn't mark it.
				let runs = try inkRuns(in: image, size: size, region: row)
				let last = try #require(runs.last, "Expected the unsaved dot")
				let lastRegion = CGRect(x: last.minX, y: row.minY, width: last.width, height: row.height)
				#expect(try compactIndicatorProfiles(in: image, size: size, region: lastRegion).count == 1,
					"The unsaved dot is the row's last mark: \(runs)")
				let lines = host.lines(in: region)
				#expect(lines.contains { $0.text.contains("LONG") }, "Key column contains: \(lines.map(\.text))")
				Attachment.record(try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])), named: "narrow-edited-drifting-key.png")
			}

			@Test("drift marks every drifting key in All Keys at rest, however many drift, at the key cell's trailing edge apart from the key, and not in one environment's table",
				arguments: [VaultAppearance.light, .dark])
			func driftMarkShowsWhereItHelps(appearance: VaultAppearance) async throws {
				// Every key drifts: masked values look alike, so the mark is how a row says it.
				let (store, _) = makeStore(environments: ["default": ["A_PORT": "1", "Z_HOST": "x"], "production": ["A_PORT": "2", "Z_HOST": "y"]])
				defer { store.lock() }
				let suite = "drift-mark-\(UUID().uuidString)"
				let defaults = try #require(UserDefaults(suiteName: suite))
				defer { defaults.removePersistentDomain(forName: suite) }
				let host = try await workspace(store, defaults: defaults)
				defer { host.window.close() }
				host.window.appearance = appearance.nativeAppearance
				try await host.settle()

				/// The ink across the first row's key cell, in the table now showing.
				func keyCellRuns(rowHeight: CGFloat, named name: String) throws -> (runs: [CGRect], columnEnd: CGFloat) {
					let divider = try #require(resizeViews(in: host.view).first { $0.accessibilityLabel() == "Resize Key column" })
					let windowFrame = divider.convert(divider.bounds, to: nil)
					let left = VaultMetrics.sidebar + VaultMetrics.paneDivider + 10
					let row = CGRect(x: left, y: windowFrame.minY - rowHeight + 6, width: windowFrame.midX - left - 2, height: rowHeight - 12)
					let image = try host.snapshot(host.view)
					Attachment.record(try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])),
						named: "\(name)-\(appearance.rawValue).png")
					return (try inkRuns(in: image, size: host.view.bounds.size, region: row), windowFrame.midX)
				}

				let drift = try keyCellRuns(rowHeight: VaultMetrics.matrixRow, named: "drift-at-rest")
				let key = try #require(drift.runs.first, "No visible key")
				let glyph = try #require(drift.runs.last, "No visible drift mark")
				#expect(drift.runs.count == 2, "The key and its mark are apart: \(drift.runs)")
				#expect(glyph.maxX > drift.columnEnd - 30, "The mark ends at \(glyph.maxX), the key column at \(drift.columnEnd)")
				#expect(glyph.minX - key.maxX > 20, "The mark starts \(glyph.minX - key.maxX) points after the key")

				try await host.clickSidebarEnvironment(".env")
				#expect(try await host.waitForText("ACTIONS", exactly: true))
				try await host.settle()
				let single = try keyCellRuns(rowHeight: VaultMetrics.fileRow, named: "drift-one-environment")
				#expect(single.runs.count == 1, "One environment's table doesn't mark drift: \(single.runs)")
			}

			@Test("the final column resize target stays clear of the inspector divider", arguments: [false, true])
			func finalColumnResizeTarget(singleEnvironment: Bool) async throws {
				let (store, _) = makeStore(environments: ["default": ["TOKEN": "a"], "production": ["TOKEN": "b"]])
				defer { store.lock() }
				let host = try await workspace(store)
				defer { host.window.close() }
				if singleEnvironment {
					try await host.clickSidebarEnvironment(".env")
					#expect(try await host.waitForText("ACTIONS", exactly: true))
				}
				try await host.click("Show inspector")
				#expect(try await host.waitUntil { resizeViews(in: host.view).contains { $0.accessibilityLabel() == "Resize inspector" } })
				try await host.settle()
				let lastLabel = singleEnvironment ? "Resize Actions column" : "Resize .env.production column"
				let last = try #require(resizeViews(in: host.view).first { $0.accessibilityLabel() == lastLabel })
				let inspector = try #require(resizeViews(in: host.view).first { $0.accessibilityLabel() == "Resize inspector" })
				let frame = host.view.convert(last.bounds, from: last)
				let inspectorFrame = host.view.convert(inspector.bounds, from: inspector)
				#expect(frame.maxX <= inspectorFrame.minX)
				let point = host.view.convert(NSPoint(x: frame.midX - 2, y: frame.midY), to: nil)
				let hitPoint = host.view.superview?.convert(point, from: nil) ?? point
				#expect(host.view.hitTest(hitPoint) === last)
				last.onDragEnded?(150)
				try await host.settle()
				let scrollView = try #require(last.enclosingScrollView)
				let clip = scrollView.contentView
				clip.scroll(to: NSPoint(x: clip.documentRect.maxX - clip.bounds.width, y: clip.bounds.minY))
				scrollView.reflectScrolledClipView(clip)
				try await host.settle()
				let scrolledFrame = host.view.convert(last.bounds, from: last)
				#expect(scrolledFrame.maxX <= inspectorFrame.minX)
				let scrolledPoint = host.view.convert(NSPoint(x: scrolledFrame.midX, y: scrolledFrame.midY), to: nil)
				let scrolledHit = host.view.superview?.convert(scrolledPoint, from: nil) ?? scrolledPoint
				#expect(host.view.hitTest(scrolledHit) === last)
			}

			@Test("shrinking all columns keeps the table aligned with its title", arguments: [false, true])
			func shrunkenTableAlignment(singleEnvironment: Bool) async throws {
				let (store, _) = makeStore(environments: ["default": ["TOKEN": "a"], "production": ["TOKEN": "b"]])
				defer { store.lock() }
				let host = try await workspace(store)
				defer { host.window.close() }
				if singleEnvironment {
					try await host.clickSidebarEnvironment(".env")
					#expect(try await host.waitForText("ACTIONS", exactly: true))
				}
				for divider in resizeViews(in: host.view) where divider.accessibilityLabel()?.hasSuffix(" column") == true {
					divider.onDragEnded?(-2000)
					try await host.settle()
				}
				let header = try await host.drawnFrame(saying: "KEY", region: CGRect(x: 0.18, y: 0.75, width: 0.8, height: 0.1))
				#expect(abs(header.minX - VaultMetrics.sidebar - VaultMetrics.paneDivider - 20) < 3)
			}

			@Test("the header's column lines continue the rows' lines, in the same place and color; the last column, and one environment's actions, have none",
				arguments: [false, true], [VaultAppearance.light, .dark])
			func columnLinesMatchRows(singleEnvironment: Bool, appearance: VaultAppearance) async throws {
				let (store, _) = makeStore(environments: ["default": ["ALPHA": "a", "BETA": "b"], "production": ["ALPHA": "z"]])
				defer { store.lock() }
				let host = try await workspace(store)
				defer { host.window.close() }
				host.window.appearance = appearance.nativeAppearance
				if singleEnvironment {
					try await host.clickSidebarEnvironment(".env")
					#expect(try await host.waitForText("ACTIONS", exactly: true))
				}
				try await host.settle()
				let image = try host.snapshot(host.view)
				Attachment.record(try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])),
					named: "column-lines-\(singleEnvironment ? "environment" : "matrix")-\(appearance.rawValue).png")
				let rowHeight = singleEnvironment ? VaultMetrics.fileRow : VaultMetrics.matrixRow
				let boundaries = resizeViews(in: host.view).filter { $0.accessibilityLabel()?.hasSuffix(" column") == true }
				try #require(boundaries.count == 3, "The key column and two more")
				let last = boundaries.max { $0.convert($0.bounds, to: nil).midX < $1.convert($1.bounds, to: nil).midX }
				for boundary in boundaries {
					let frame = boundary.convert(boundary.bounds, to: nil)
					let header = try horizontalPixels(in: image, size: host.view.bounds.size, y: frame.midY, from: frame.midX - 4, width: 8)
					let row = try horizontalPixels(in: image, size: host.view.bounds.size, y: frame.minY - rowHeight / 2, from: frame.midX - 4, width: 8)
					let name = boundary.accessibilityLabel() ?? ""
					let headerLine = lineColumns(header), rowLine = lineColumns(row)
					// A row's actions belong to its value, so nothing divides them.
					if boundary === last || (singleEnvironment && name == "Resize Value column") {
						#expect(headerLine.isEmpty && rowLine.isEmpty, "No line at \(name): \(headerLine), \(rowLine)")
						continue
					}
					#expect(!rowLine.isEmpty, "The rows draw a line at \(name)")
					#expect(headerLine == rowLine, "At \(name) the header's line covers pixels \(headerLine), the rows' \(rowLine)")
					for column in headerLine.intersection(rowLine) {
						let difference = zip(header[column], row[column]).map { abs(Int($0) - Int($1)) }.max() ?? 0
						#expect(difference <= 3, "At \(name) the header's line is \(header[column]), the rows' \(row[column])")
					}
				}
			}

			@Test("no environment column is tinted, whichever environment was selected last", arguments: [VaultAppearance.light, .dark])
			func untintedEnvironmentColumns(appearance: VaultAppearance) async throws {
				let (store, _) = makeStore(environments: ["default": ["ALPHA": "a"], "production": ["ALPHA": "z"], "staging": ["ALPHA": "a"]])
				defer { store.lock() }
				let host = try await workspace(store)
				defer { host.window.close() }
				host.window.appearance = appearance.nativeAppearance
				for afterEnvironment in [false, true] {
					if afterEnvironment {
						try await host.clickSidebarEnvironment(".env.production")
						#expect(try await host.waitForText("ACTIONS", exactly: true))
						try await host.click("Workspace")
						#expect(try await host.waitForText("All Keys"))
					}
					try await host.settle()
					let image = try host.snapshot(host.view)
					let size = host.view.bounds.size
					let boundaries = resizeViews(in: host.view).filter { $0.accessibilityLabel()?.hasSuffix(" column") == true }
						.map { $0.convert($0.bounds, to: nil) }
					try #require(boundaries.count == 4, "The key column and three environments")
					// Each column's last points are empty: values and names start at its leading edge.
					let headers = try boundaries.map { try horizontalPixels(in: image, size: size, y: $0.midY, from: $0.midX - 10, width: 1)[0] }
					let cells = try boundaries.map {
						try horizontalPixels(in: image, size: size, y: $0.minY - VaultMetrics.matrixRow / 2, from: $0.midX - 10, width: 1)[0]
					}
					#expect(Set(headers).count == 1, "Every header cell has the key header's background, read \(headers) (after .env.production: \(afterEnvironment))")
					#expect(Set(cells).count == 1, "Every cell has the key cell's background, read \(cells) (after .env.production: \(afterEnvironment))")
				}
			}

			@Test("All Keys' chips and the status bar of every other page open the smart views, each showing only its keys")
			func statusBarSmartViews() async throws {
				let (store, _) = makeStore(environments: ["default": ["DRIFTS": "a", "LACKS": "b"], "production": ["DRIFTS": "z"]])
				defer { store.lock() }
				let host = try await workspace(store)
				defer { host.window.close() }
				let footer = VaultMetrics.statusBar + 4
				#expect(try await host.waitForText("Drift, 1"))
				#expect(try await host.waitForText("Missing, 1"))
				let matrixFooter = try await host.text(footer: footer)
				#expect(!matrixFooter.contains("differ") && !matrixFooter.contains("missing"),
					"The status bar doesn't repeat the chips above the table: \(matrixFooter)")
				try await host.click("Missing, 1")
				#expect(try await host.waitForTextToDisappear("DRIFTS"))
				#expect(try await host.text().contains("LACKS"))

				try await host.clickSidebarEnvironment(".env.production")
				#expect(try await host.waitForText("ACTIONS", exactly: true))
				#expect(try await host.waitForText("1 key missing", footer: footer))
				try await host.click("1 key differs")
				#expect(try await host.waitForText("All Keys"))
				#expect(try await host.waitForTextToDisappear("LACKS"))
				#expect(try await host.text().contains("DRIFTS"))

				try await host.click("Schema")
				#expect(try await host.waitForText("editing unavailable", footer: footer))
				#expect(try await host.waitForText("1 key differs", footer: footer))
				try await host.click("1 key missing")
				#expect(try await host.waitForText("All Keys"))
				#expect(try await host.waitForTextToDisappear("DRIFTS"))
				#expect(try await host.text().contains("LACKS"))
			}

		@Test("blank space across a matrix key cell opens its inspector", arguments: [CGFloat(5), 205])
		func matrixKeyCellBlankSpace(offset: CGFloat) async throws {
			let (store, _) = makeStore()
			defer { store.lock() }
			let host = try await workspace(store)
			defer { host.window.close() }
			try clickAt(NSPoint(x: VaultMetrics.sidebar + VaultMetrics.paneDivider + offset, y: 603), in: host)
			#expect(try await host.waitForText("VALUES", exactly: true))
			#expect(try await host.waitUntil { host.value == "fixture-value" })
		}

		@Test("both tables expose draggable column boundaries without changing key order", arguments: [false, true])
		func tableColumnResize(singleEnvironment: Bool) async throws {
			let domain = "lpm-column-resize-test-" + UUID().uuidString
			let defaults = try #require(UserDefaults(suiteName: domain))
			defer { defaults.removePersistentDomain(forName: domain) }
			let (store, _) = makeStore(environments: [
				"default": ["ALPHA": "a", "ZULU": "z"], "production": ["ALPHA": "b", "ZULU": "z"],
			])
			defer { store.lock() }
			let host = try await workspace(store, defaults: defaults)
			defer { host.window.close() }
			if singleEnvironment {
				try await host.clickSidebarEnvironment(".env")
				#expect(try await host.waitForText("ACTIONS", exactly: true))
			}
			let label = "Resize Key column"
			let divider = try #require(resizeViews(in: host.view).first { $0.accessibilityLabel() == label })
			let original = host.view.convert(divider.bounds, from: divider)
			let startWidth = try #require(Int((divider.accessibilityValue() as? String ?? "").split(separator: " ").first ?? ""))
			#expect(divider.accessibilityRole() == .splitter)
			let point = NSPoint(x: original.midX, y: original.midY)
			let hitPoint = host.view.superview?.convert(host.view.convert(point, to: nil), from: nil) ?? point
			#expect(host.view.hitTest(hitPoint) === divider)
			divider.onDragChanged?(40)
			#expect(try await host.waitUntil { divider.accessibilityValue() as? String == "\(startWidth + 40) points" })
			divider.onDragChanged?(80)
			divider.onDragEnded?(80)
			#expect(try await host.waitUntil { divider.accessibilityValue() as? String == "\(startWidth + 80) points" })
			try await host.settle()
			let resized = host.view.convert(divider.bounds, from: divider)
			#expect(abs(resized.midX - original.midX - 80) < 1)
			#expect(defaults.string(forKey: VaultKeySortOrder.defaultsKey) != "descending")
			#expect(try await waitForKeyOrder(["ALPHA", "ZULU"], in: host))
			let nextLabel = singleEnvironment ? "Resize Value column" : "Resize .env column"
			let next = try #require(resizeViews(in: host.view).first { $0.accessibilityLabel() == nextLabel })
			#expect(next.accessibilityPerformIncrement())
			try await host.settle()
			#expect(divider.accessibilityValue() as? String == "\(startWidth + 80) points")
			try await host.click("Show inspector")
			#expect(try await host.waitUntil { resizeViews(in: host.view).contains { $0.accessibilityLabel() == "Resize inspector" } })
			host.window.setContentSize(NSSize(width: 1040, height: 800))
			try await host.settle()
			#expect(divider.accessibilityValue() as? String == "\(startWidth + 80) points")
			// Too narrow for the sidebar beside the inspector, so it hid; it comes back to move between pages.
			try await host.click("Show sidebar")
			#expect(try await host.waitForText("Hide sidebar", exactly: true))
			// The toggle's name changes at once; the sidebar's rows arrive a moment later.
			#expect(try await host.waitForText("PROJECTS", exactly: true))
			if singleEnvironment {
				let project = try await host.labelFrame("Workspace", region: CGRect(x: 0, y: 0.7, width: 0.25, height: 0.25))
				try clickAt(NSPoint(x: project.midX, y: project.midY), in: host)
				#expect(try await host.waitForText("All Keys"))
				try clickAt(NSPoint(x: project.midX, y: project.midY), in: host)
				try await host.settle()
				try await host.clickSidebarEnvironment(".env")
				#expect(try await host.waitUntil { resizeViews(in: host.view).contains { $0.accessibilityLabel() == "Resize Value column" } })
			} else {
				try await host.clickSidebarEnvironment(".env")
				#expect(try await host.waitUntil { resizeViews(in: host.view).contains { $0.accessibilityLabel() == "Resize Value column" } })
				let project = try await host.labelFrame("Workspace", region: CGRect(x: 0, y: 0.7, width: 0.25, height: 0.25))
				try clickAt(NSPoint(x: project.midX, y: project.midY), in: host)
				#expect(try await host.waitForText("All Keys"))
			}
			try await host.settle()
			let restored = try #require(resizeViews(in: host.view).first { $0.accessibilityLabel() == label })
			#expect(restored.accessibilityValue() as? String == "\(startWidth + 80) points")
			let image = try host.snapshot(host.view)
			let bitmap = NSBitmapImageRep(cgImage: image)
			Attachment.record(try #require(bitmap.representation(using: .png, properties: [:])), named: singleEnvironment ? "resized-environment.png" : "resized-matrix.png")
		}

		@Test("inspector copy uses the latest refresh and copies what the field shows", arguments: [false, true])
		func inspectorCopyAfterRefresh(edited: Bool) async throws {
			let keychain = MockKeychainService()
			let (store, _) = makeStore(keychain: keychain)
			defer { store.lock() }
			let host = try await workspace(store)
			defer { host.window.close() }
			try selectRow(0, in: host)
			try await host.settle()
			if edited { try host.enterValue("unsaved-workspace-draft") }
			keychain.simulateCLISet(vaultId: "workspace", environment: "default", key: "TOKEN", value: "current-cli-value")
			await store.refreshLocalState()
			if edited {
				try await host.settle()
				#expect(host.value == "unsaved-workspace-draft", "The unsaved edit stays")
			} else {
				#expect(try await host.waitUntil { host.value == "current-cli-value" })
			}
			try host.click(.copy)
			#expect(try await host.waitUntil {
				store.clipboard.pasteboard.string(forType: .string) == (edited ? "unsaved-workspace-draft" : "current-cli-value")
			})
			if edited { #expect(try await host.waitForText("Changed outside the editor")) }
		}

		@Test("Esc in the sidebar search stays with the search while the inspector is open")
		func escapeInSearchKeepsInspector() async throws {
			let (store, _) = makeStore()
			defer { store.lock() }
			let host = try await workspace(store)
			defer { host.window.close() }
			try selectRow(0, in: host)
			#expect(try await host.waitForText("VALUES", exactly: true))
			// The search field is the topmost text field in the window.
			try host.escapeWhileEditing(fieldAt: 0, secure: false)
			try await host.settle()
			#expect(try await host.text().contains("VALUES"))
		}

		@Test("the table's key column lines up with the header when a narrow window opens the inspector", arguments: [false, true])
		func narrowTableAlignment(inspectorOpen: Bool) async throws {
			let (store, _) = makeStore(environments: [
				"default": ["TOKEN": "a", "DATABASE_URL": "b"], "staging": ["TOKEN": "c"], "production": ["DATABASE_URL": "d"],
			])
			defer { store.lock() }
			await store.refreshCliAccess()
			let host = SheetTestHost(VaultWorkspaceView(store: store).environment(UpdateChecker()).environment(VaultAppearanceSettings(defaults: UserDefaults(suiteName: "workspace-interaction")!))
				.environment(VaultQuitSettings(defaults: UserDefaults(suiteName: "workspace-interaction")!)),
				size: NSSize(width: 1040, height: 700), keepsRequestedSize: true, usesHostingView: true)
			defer { host.window.close() }
			#expect(try await host.waitUntil { store.workspaceSnapshots["workspace"] != nil })
			try await host.settle()
			if inspectorOpen {
				try clickAt(NSPoint(x: 330, y: 700 - 197), in: host)
				#expect(try await host.waitForText("VALUES", exactly: true))
			}
			let title = try await host.drawnFrame(saying: "All Keys")
			// The inspector takes the sidebar's place in a window this narrow, so the table can start at the window's edge.
			let keyColumn = try await host.drawnFrame(saying: "KEY", region: CGRect(x: 0, y: 0.6, width: 0.65, height: 0.25))
			#expect(abs(keyColumn.minX - title.minX) < 3, "KEY starts at \(keyColumn.minX), the title at \(title.minX)")
		}

		@Test("a narrow window with the inspector open keeps the key count and unsaved changes whole in the status bar")
		func narrowStatusBarKeepsEssentials() async throws {
			let (store, _) = makeStore(environments: ["default": ["TOKEN": "a", "DATABASE_URL": "b"], "production": ["TOKEN": "c"]])
			defer { store.lock() }
			let host = try await workspace(store, size: NSSize(width: 1040, height: 700))
			defer { host.window.close() }
			try clickAt(NSPoint(x: 330, y: 700 - 197), in: host)
			#expect(try await host.waitForText("VALUES", exactly: true))
			try host.enterValue("unsaved-narrow-draft")
			#expect(try await host.waitForText("1 key with unsaved changes", footer: VaultMetrics.statusBar))
			#expect(try await host.waitForText("2 of 2 keys shown", footer: VaultMetrics.statusBar))
		}

		@Test("unsaved edits stay with their key while the person selects other keys")
		func draftsFollowTheirKey() async throws {
			let (store, _) = makeStore(environments: ["default": ["TOKEN": "fixture-value", "ZETA": "zeta-value"]])
			defer { store.lock() }
			let host = try await workspace(store)
			defer { host.window.close() }
			try selectRow(0, in: host)
			try await host.settle()
			try host.enterValue("draft-for-token")
			try await host.settle()
			try selectRow(1, in: host)
			#expect(try await host.waitUntil { host.value == "zeta-value" })
			#expect(try await host.waitForText("UNSAVED"))
			#expect(try await host.waitForText("1 key with unsaved changes", footer: VaultMetrics.statusBar))
			try selectRow(0, in: host)
			#expect(try await host.waitUntil { host.value == "draft-for-token" })
			#expect(try await host.waitForText("1 unsaved change"))
		}

		@Test("clicking a row, another row, then the first again selects it without revealing its values")
		func clicksOnOtherRowsDontMakeADoubleClick() async throws {
			let (store, _) = makeStore(environments: ["default": ["TOKEN": "fixture-value", "ZETA": "zeta-value"]])
			defer { store.lock() }
			let host = try await workspace(store)
			defer { host.window.close() }
			try selectRow(0, in: host)
			try selectRow(1, in: host)
			try selectRow(0, in: host)
			#expect(try await host.waitForText("TOKEN, set in 1 of 1 environments, values hidden"))
			#expect(try await host.waitUntil { host.value == "fixture-value" }, "The inspector keeps the value masked")
		}

		@Test("a double-click on a row reveals its values")
		func doubleClickRevealsRow() async throws {
			let (store, _) = makeStore(environments: ["default": ["TOKEN": "fixture-value", "ZETA": "zeta-value"]])
			defer { store.lock() }
			let host = try await workspace(store)
			defer { host.window.close() }
			try doubleClickRow(0, in: host)
			#expect(try await host.waitForText("TOKEN, set in 1 of 1 environments, values shown"))
		}

		@Test("the KEY header reverses the key order in both tables, and the order is remembered")
		func keyHeaderReversesOrder() async throws {
			let domain = "lpm-key-sort-test-" + UUID().uuidString
			let defaults = try #require(UserDefaults(suiteName: domain))
			defer { defaults.removePersistentDomain(forName: domain) }
			let (store, _) = makeStore(environments: ["default": ["ALPHA": "a", "ZULU": "z"]])
			defer { store.lock() }
			let host = try await workspace(store, defaults: defaults)
			#expect(try await waitForKeyOrder(["ALPHA", "ZULU"], in: host))

			try await clickKeyHeader(in: host)
			#expect(try await host.waitUntil { defaults.string(forKey: VaultKeySortOrder.defaultsKey) == "descending" })
			try await host.settle()
			#expect(try await waitForKeyOrder(["ZULU", "ALPHA"], in: host))
			#expect(try await host.waitForText("sorted Z"))

			// The environment's own table uses the same order and its header reverses it too.
			try await host.clickSidebarEnvironment(".env")
			#expect(try await host.waitForText("ACTIONS", exactly: true))
			#expect(try await waitForKeyOrder(["ZULU", "ALPHA"], in: host))
			try await clickKeyHeader(in: host)
			#expect(try await host.waitUntil { defaults.string(forKey: VaultKeySortOrder.defaultsKey) == "ascending" })
			try await host.settle()
			#expect(try await waitForKeyOrder(["ALPHA", "ZULU"], in: host))
			try await clickKeyHeader(in: host)
			#expect(try await host.waitUntil { defaults.string(forKey: VaultKeySortOrder.defaultsKey) == "descending" })
			host.window.close()

			let reopened = try await workspace(store, defaults: defaults)
			defer { reopened.window.close() }
			#expect(try await waitForKeyOrder(["ZULU", "ALPHA"], in: reopened))
		}

		@Test("a narrow environment table keeps its sort header legible and aligned", arguments: [false, true])
		func narrowEnvironmentSortHeader(minimumContentWidth: Bool) async throws {
			let domain = "lpm-narrow-sort-test-" + UUID().uuidString
			let defaults = try #require(UserDefaults(suiteName: domain))
			defer { defaults.removePersistentDomain(forName: domain) }
			let (store, _) = makeStore(environments: ["default": ["ALPHA": "a", "ZULU": "z"]])
			defer { store.lock() }
			let host = try await workspace(store, size: NSSize(width: 1040, height: 700), defaults: defaults)
			defer { host.window.close() }
			try clickAt(NSPoint(x: 330, y: 503), in: host)
			#expect(try await host.waitForText("VALUES", exactly: true))
			// A window this narrow hides the sidebar for the inspector; the narrowest table has both.
			try await host.click("Show sidebar")
			#expect(try await host.waitForText("Hide sidebar", exactly: true))
			// The toggle's name changes at once; the sidebar's rows arrive a moment later.
			#expect(try await host.waitForText("PROJECTS", exactly: true))
			if minimumContentWidth {
				let inspector = try #require(resizeViews(in: host.view).first { $0.accessibilityLabel() == "Resize inspector" })
				let widest = Int(VaultPaneBudget(available: 1040, requestedSidebar: VaultMetrics.sidebar,
					requestedInspector: VaultMetrics.inspector, showsInspector: true).inspector.maximum)
				for _ in 0..<4 where inspector.accessibilityValue() as? String != "\(widest) points" {
					#expect(inspector.accessibilityPerformIncrement())
					try await host.settle()
				}
				#expect(try await host.waitUntil { inspector.accessibilityValue() as? String == "\(widest) points" })
				try await host.settle()
			}
			try await host.clickSidebarEnvironment(".env")
			try await host.settle()
			let headerRegion = CGRect(x: 0.27, y: 0.7, width: 0.43, height: 0.13)
			let keyHeader = try await host.drawnFrame(saying: "KEY", region: headerRegion)
			let valueHeader = try await host.drawnFrame(saying: "VALUE", region: headerRegion)
			let keyRegion = keyColumnRegion(header: keyHeader, size: host.view.bounds.size)
			#expect(try await waitForKeyOrder(["ALPHA", "ZULU"], in: host, region: keyRegion))
			let firstKey = try await keyFrame("ALPHA", in: host, region: keyRegion)
			#expect(abs(keyHeader.minX - firstKey.minX) < 3)
			#expect(valueHeader.minX - keyHeader.minX >= 150)
			try clickAt(NSPoint(x: keyHeader.midX, y: keyHeader.midY), in: host)
			#expect(try await host.waitUntil { defaults.string(forKey: VaultKeySortOrder.defaultsKey) == "descending" })
			try await host.settle()
			#expect(try await waitForKeyOrder(["ZULU", "ALPHA"], in: host, region: keyRegion))
		}

		@Test("key order is read from the top, and a key that isn't shown has no place in it")
		func keyOrderFromLines() {
			let lines = [
				AccessibilityTree.Line(text: "ZULU", bounds: CGRect(x: 0.3, y: 0.5, width: 0.1, height: 0.02), labelBounds: nil),
				AccessibilityTree.Line(text: "ALPHA", bounds: CGRect(x: 0.3, y: 0.6, width: 0.1, height: 0.02), labelBounds: nil),
			]
			#expect(keysFromTop(["ALPHA", "ZULU"], lines: lines) == ["ALPHA", "ZULU"])
			#expect(keysFromTop(["ZULU", "ALPHA"], lines: lines) == ["ALPHA", "ZULU"])
			#expect(keysFromTop(["ALPHA", "ZULU"], lines: Array(lines.prefix(1))) == ["ZULU"])
			#expect(keyLine("ALPHA", lines: lines)?.bounds == lines[1].bounds)
		}

		@Test("key alignment measures the pixels drawn, not the frame the text is laid out in", arguments: [1, 2])
		func keyAlignmentUsesInk(scale: Int) throws {
			let width = 200 * scale, height = 100 * scale
			let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
				bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
			context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
			for offset in [0, 9] {
				context.setFillColor(CGColor(gray: 0.1, alpha: 1))
				context.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
				context.setFillColor(CGColor(gray: 0.2, alpha: 1))
				context.fill(CGRect(x: 0, y: 55, width: 200, height: 25))
				context.setFillColor(CGColor(gray: 0.9, alpha: 1))
				let ink = CGRect(x: 34 + offset, y: 61, width: 23, height: 9)
				context.fill(ink)
				context.fill(CGRect(x: 150, y: 61, width: 20, height: 9))
				context.fill(CGRect(x: 11, y: 12, width: 23, height: 9))
				let image = try #require(context.makeImage())
				let bounds = try inkBounds(in: image, region: CGRect(x: 0.15, y: 0.55, width: 0.5, height: 0.25))
				#expect(abs(bounds.minX * 200 - ink.minX) < 0.001)
				#expect(abs(bounds.minY * 100 - ink.minY) < 0.001)
				#expect(abs(bounds.width * 200 - ink.width) < 0.001)
				#expect(abs(bounds.height * 100 - ink.height) < 0.001)
			}
		}

		@Test("overlapping lines can't establish the order of two table rows", arguments: ["merged", "same height", "overlapping"])
		func combinedKeyLineCannotProveOrder(reading: String) {
			let bounds = CGRect(x: 0.3, y: 0.5, width: 0.2, height: 0.02)
			let lines = reading == "merged"
				? [AccessibilityTree.Line(text: "ZULU ALPHA", bounds: bounds, labelBounds: nil)]
				: [
					AccessibilityTree.Line(text: "ZULU", bounds: bounds.offsetBy(dx: 0.1, dy: reading == "overlapping" ? bounds.height / 2 : 0), labelBounds: nil),
					AccessibilityTree.Line(text: "ALPHA", bounds: bounds, labelBounds: nil),
				]
			#expect(keysFromTop(["ALPHA", "ZULU"], lines: lines).isEmpty)
			#expect(keysFromTop(["ZULU", "ALPHA"], lines: lines).isEmpty)
		}

		@Test("the key column's region covers rows below the header and excludes the footer", arguments: [NSSize(width: 1040, height: 700), NSSize(width: 1600, height: 800)])
		func keyRecognitionFollowsHeader(size: NSSize) {
			let header = CGRect(x: 301, y: size.height - 150, width: 30, height: 12)
			let region = keyColumnRegion(header: header, size: size)
			for rowY in [header.minY - 42, CGFloat(44)] {
				let row = CGRect(x: 301 / size.width, y: rowY / size.height, width: 45 / size.width, height: 13 / size.height)
				#expect(region.contains(row))
			}
			#expect(!region.contains(CGPoint(x: header.midX / size.width, y: header.midY / size.height)))
			#expect(!region.contains(CGPoint(x: header.midX / size.width, y: 15 / size.height)))
		}

		@Test("an edit whose environment disappears stays in its card until discarded", arguments: ["environment", "rename"])
		func removedEnvironmentKeepsEdit(removal: String) async throws {
			let keychain = MockKeychainService()
			let (store, _) = makeStore(environments: ["default": ["TOKEN": "default-value"], "staging": ["TOKEN": "staging-value"]], keychain: keychain)
			defer { store.lock() }
			let host = try await workspace(store)
			defer { host.window.close() }
			try selectRow(0, in: host)
			try await host.settle()
			try host.enterValue("unsaved-removed-target", at: 1)
			#expect(try await host.waitForText("1 unsaved change"))
			let values = keychain.envStorage["workspace"]?.environments.removeValue(forKey: "staging")
			if removal == "rename" { keychain.envStorage["workspace"]?.environments["renamed"] = values }
			await store.refreshLocalState()
			try await host.settle()
			// The small red message is read unreliably on CI; its action and the draft's state are not.
			#expect(try await host.waitForText("Discard"))
			#expect(store.keyDrafts.draft(VaultKeyDraft.ID(projectID: "workspace", key: "TOKEN"))?.orphanedEnvironments == ["staging"])
			#expect(host.secureValues.contains("unsaved-removed-target"))
			try host.returnWhileEditing("value", modifiers: [])
			try await host.settle()
			#expect(keychain.envStorage["workspace"]?.environments["staging"] == nil)
			#expect(keychain.envStorage["workspace"]?.environments["default"]?["TOKEN"] == "default-value")
			// Kept values of a deleted environment follow the project's environments.
			try host.click(.copy, ofValueAt: removal == "rename" ? 2 : 1)
			#expect(try await host.waitUntil { store.clipboard.pasteboard.string(forType: .string) == "unsaved-removed-target" })
			try await host.click("Discard")
			try await host.settle()
			#expect(try await !host.text().contains("deleted outside the editor"))
			#expect(!host.secureValues.contains("unsaved-removed-target"))
		}

		@Test("unsaved edits of a removed project stay recoverable, even after it returns", arguments: [false, true])
		func removedProjectKeepsEdits(hiddenInSettings: Bool) async throws {
			let keychain = MockKeychainService()
			let (store, biometric) = makeStore(keychain: keychain)
			defer { store.lock() }
			let host = try await workspace(store)
			defer { host.window.close() }
			try selectRow(0, in: host)
			try await host.settle()
			try host.enterValue("unsaved-removed-project")
			try await host.settle()
			if hiddenInSettings { store.showSettings(); try await host.settle() }
			let saved = keychain.envStorage.removeValue(forKey: "workspace")
			await store.refreshLocalState()
			try await host.settle()
			keychain.envStorage["workspace"] = saved
			await store.refreshLocalState()
			store.openProject(id: "workspace")
			#expect(try await host.waitForText("UNSAVED EDITS", exactly: true))
			#expect(try await host.waitForText("deleted outside the editor"))
			store.clipboard.pasteboard.clearContents()
			store.clipboard.pasteboard.setString("unsaved-removed-project", forType: .string)
			try await host.click("Copy value")
			#expect(try await host.waitUntil { store.clipboard.pasteboard.string(forType: .string) == "unsaved-removed-project" })
			#expect(biometric.authenticateCallCount == 0, "Copying asks nothing more than unlocking did")
			#expect(try await host.waitForText("Copied"))
			#expect(keychain.envStorage["workspace"]?.environments["default"]?["TOKEN"] == "fixture-value")
			try await host.click("Discard")
			try await host.settle()
			#expect(try await !host.text().contains("UNSAVED EDITS"))
			#expect(store.keyDrafts.drafts.isEmpty)
		}

		@Test("copy all during a refresh copies the values it publishes, without Touch ID")
		func copyAllWaitsForRefresh() async throws {
			let keychain = MockKeychainService()
			let (store, biometric) = makeStore(keychain: keychain)
			defer { store.lock() }
			let host = try await workspace(store)
			defer { host.window.close() }
			let release = try await holdRefresh(of: store, keychain: keychain)
			keychain.simulateCLISet(vaultId: "workspace", environment: "default", key: "TOKEN", value: "cli-updated")
			try await host.click("Copy all")
			#expect(try await host.waitForText("Copying all .env values"))
			#expect(store.clipboard.pasteboard.string(forType: .string) == nil)
			await release()
			#expect(try await host.waitUntil { store.clipboard.pasteboard.string(forType: .string) == "TOKEN=\"cli-updated\"\n" })
			#expect(try await host.waitForText("Copied"))
			#expect(biometric.authenticateCallCount == 0)
		}

		@Test("a failed refresh pauses secret actions behind a retry banner")
		func failedRefreshShowsRetryBanner() async throws {
			let keychain = MockKeychainService()
			let (store, _) = makeStore(keychain: keychain)
			defer { store.lock() }
			let host = try await workspace(store)
			defer { host.window.close() }
			keychain.failProjectReads = true
			await store.refreshLocalState()
			#expect(try await host.waitForText("Couldn’t reload changes from the LPM CLI"))
			#expect(!store.canUseLocalSecrets)
			let view = host.view
			let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
			view.cacheDisplay(in: view.bounds, to: bitmap)
			Attachment.record(try #require(bitmap.representation(using: .png, properties: [:])), named: "workspace-refresh-failed.png")
			keychain.failProjectReads = false
			try await host.click("Retry")
			#expect(try await host.waitUntil { store.canUseLocalSecrets })
			try await host.settle()
			#expect(try await !host.text().contains("Couldn’t reload changes"))
		}

		@Test("revealed values stay revealed across a refresh")
		func revealedValuesSurviveRefresh() async throws {
			let (store, _) = makeStore()
			defer { store.lock() }
			let host = try await workspace(store)
			defer { host.window.close() }
			try await host.click("Reveal")
			#expect(try await host.waitForText("TOKEN, set in 1 of 1 environments, values shown"))
			await store.refreshLocalState()
			try await host.settle()
			#expect(try await host.text().contains("TOKEN, set in 1 of 1 environments, values shown"))
		}

		@Test("a sync confirmation closes instead of retargeting a newly selected project")
		func syncConfirmationStaysWithItsProject() async throws {
			let (store, _) = makeStore(additionalProject: true)
			defer { store.lock() }
			let host = try await workspace(store)
			defer {
				if let sheet = host.window.attachedSheet { host.window.endSheet(sheet) }
				host.window.close()
			}

			NotificationCenter.default.post(name: .pullProject, object: nil)
			try await host.settle()
			#expect(host.window.attachedSheet != nil)
			store.openProject(id: "other")
			#expect(try await host.waitUntil {
				store.selectedProjectId == "other" && store.workspaceSnapshots["other"] != nil
			})
			try await host.settle()
			#expect(host.window.attachedSheet == nil)
		}

		@Test("confirming a pull closes its sheet")
		func pullConfirmationClosesWhenConfirmed() async throws {
			let (store, _) = makeStore()
			defer { store.lock() }
			let host = try await workspace(store)
			defer {
				if let sheet = host.window.attachedSheet { host.window.endSheet(sheet) }
				host.window.close()
			}

			NotificationCenter.default.post(name: .pullProject, object: nil)
			let sheet = try #require(try await host.waitUntil { host.window.attachedSheet != nil } ? host.window.attachedSheet : nil)
			try await host.click("Pull", in: sheet)
			var closed = try await host.waitUntil { host.window.attachedSheet == nil }
			if !closed {
				// A second click says which half failed: it closes a sheet the first click never reached, and
				// leaves open one that can't close.
				try await host.click("Pull", in: sheet)
				closed = try await host.waitUntil { host.window.attachedSheet == nil }
				Issue.record("The sheet stayed open after Pull was clicked; a second click \(closed ? "closed it" : "left it open too")")
			}
		}

		@Test("a reveal approved after project navigation cannot unmask the new project's same-named value")
		func pendingRevealStaysWithItsProject() async throws {
			let defaultsDomain = "pending-reveal-\(UUID().uuidString)"
			let defaults = try #require(UserDefaults(suiteName: defaultsDomain))
			defer { defaults.removePersistentDomain(forName: defaultsDomain) }
			let keychain = MockKeychainService()
			let (store, biometric) = makeStore(additionalProject: true, keychain: keychain, preferences: defaults)
			defer { store.lock() }
			store.settings.valueApproval = .afterFiveMinutes
			let other = VaultProject(id: "other", name: "Other", path: "",
				environments: ["default": ["TOKEN": "other-project-value"]])
			keychain.envStorage[other.id] = (name: other.name, path: "", environments: other.environments)
			store.projects[1] = other
			let approval = WorkspaceApprovalGate()
			biometric.authenticateHandlers = [{
				await approval.arriveAndWait()
				return true
			}]
			let host = try await workspace(store, defaults: defaults)
			defer { host.window.close() }

			try await host.click("Reveal")
			await approval.waitUntilArrived()
			store.openProject(id: other.id)
			#expect(try await host.waitUntil {
				store.selectedProjectId == other.id && store.workspaceSnapshots[other.id] != nil
			})
			#expect(try await host.waitForText("TOKEN, set in 1 of 1 environments, values hidden"))
			await approval.release()
			try await host.settle()
			try await quietPeriod()

			#expect(try await !host.text().contains("TOKEN, set in 1 of 1 environments, values shown"))
		}

		@Test("copy all keeps the toolbar stationary and confirms success")
		func copyAllFeedbackAndLayout() async throws {
			let keychain = MockKeychainService()
			let (store, _) = makeStore(keychain: keychain)
			defer { store.lock() }
			let copyFeedback = ManualFeedbackTimer()
			let host = try await workspace(store, copyFeedback: copyFeedback)
			defer { host.window.close() }
			let revealLabel = try await host.labelFrame("Reveal")
			let size = host.view.bounds.size
			let revealRegion = CGRect(x: (revealLabel.minX - 4) / size.width, y: (revealLabel.minY - 2) / size.height,
				width: (revealLabel.width + 8) / size.width, height: (revealLabel.height + 4) / size.height)
			let revealFrame = try inkBounds(in: host.snapshot(host.view), region: revealRegion)
			let release = try await holdRefresh(of: store, keychain: keychain)
			try await host.click("Copy all")
			#expect(try await host.waitForText("Copying all .env values"))
			try await host.settle()
			#expect(abs(try inkBounds(in: host.snapshot(host.view), region: revealRegion).minX - revealFrame.minX) * size.width < 0.75)
			await release()
			try await host.settle()
			#expect(try await host.waitForText("Copied"))
			#expect(abs(try inkBounds(in: host.snapshot(host.view), region: revealRegion).minX - revealFrame.minX) * size.width < 0.75)
			#expect(try await host.waitUntil { copyFeedback.started == 1 }, "The confirmation starts waiting just after Copied shows")
			copyFeedback.expire()
			#expect(try await host.waitForText("Copy all"))
		}

		@Test("inspector copy confirms success in its value card until the confirmation ends")
		func inspectorCopyFeedback() async throws {
			let (store, _) = makeStore()
			defer { store.lock() }
			let copyFeedback = ManualFeedbackTimer()
			let host = try await workspace(store, copyFeedback: copyFeedback)
			defer { host.window.close() }
			try selectRow(0, in: host)
			try await host.settle()
			try host.click(.copy)
			#expect(try await host.waitUntil { store.clipboard.pasteboard.string(forType: .string) == "fixture-value" })
			#expect(try await host.waitForText("Copied"))
			#expect(try await host.waitUntil { copyFeedback.started == 1 }, "The confirmation starts waiting just after Copied shows")
			copyFeedback.expire()
			#expect(try await host.waitForTextToDisappear("Copied"))
		}

		@Test("a copy all waiting for a refresh copies nothing once its environment isn't shown",
			arguments: ["settings", "environment", "project", "lock"])
		func copyAllEndsWithItsContext(transition: String) async throws {
			let keychain = MockKeychainService()
			let (store, _) = makeStore(environments: ["default": ["TOKEN": "fixture-value"], "production": ["TOKEN": "other-value"]],
				additionalProject: true, keychain: keychain)
			defer { store.lock() }
			let host = try await workspace(store)
			defer { host.window.close() }
			let release = try await holdRefresh(of: store, keychain: keychain)
			try await host.click("Copy all")
			#expect(try await host.waitForText("Copying all .env values"))
			switch transition {
			case "settings": store.showSettings()
			case "environment": store.selectEnvironment("production")
			case "project": store.openProject(id: "other")
			default: store.lock()
			}
			try await host.settle()
			await release()
			try await host.settle()
			#expect(store.clipboard.pasteboard.string(forType: .string) == nil)
			#expect(try await !host.text().contains("Copied"))
			if transition == "settings" {
				store.openProject(id: "workspace")
				try await host.settle()
				#expect(try await !host.text().contains("Copied"))
			}
		}

		@Test("repeated inspector copies restart the confirmation interval")
		func repeatedCopyRestartsFeedback() async throws {
			let (store, _) = makeStore()
			defer { store.lock() }
			let copyFeedback = ManualFeedbackTimer()
			let host = try await workspace(store, copyFeedback: copyFeedback)
			defer { host.window.close() }
			try selectRow(0, in: host)
			try await host.settle()
			try host.click(.copy)
			#expect(try await host.waitUntil { copyFeedback.started == 1 })
			try host.click(.copy)
			#expect(try await host.waitUntil { copyFeedback.started == 2 })
			#expect(try await host.waitForText("Copied"))
			copyFeedback.expire()
			#expect(try await host.waitForTextToDisappear("Copied"))
		}

		@Test("a selected project never shows the selection prompt while its snapshot is pending")
		func pendingSnapshotDoesNotShowEmptySelection() async throws {
			let (store, _) = makeStore()
			defer { store.lock() }
			#expect(store.workspaceSnapshots["workspace"] == nil)
			#expect(!store.isLoadingSelectedProject)
			let host = SheetTestHost(VaultWorkspaceView(store: store).environment(UpdateChecker()).environment(VaultAppearanceSettings(defaults: UserDefaults(suiteName: "workspace-interaction")!))
				.environment(VaultQuitSettings(defaults: UserDefaults(suiteName: "workspace-interaction")!)),
				size: NSSize(width: 1600, height: 800), keepsRequestedSize: true, usesHostingView: true)
			defer { host.window.close() }
			#expect(!host.lines().contains { $0.text.contains("Select an env project") })
			#expect(try await host.waitUntil { store.workspaceSnapshots["workspace"] != nil })
			#expect(try await host.waitForText("All Keys"))
		}

		@Test("Settings shows over the workspace, which keeps its project and environment, and closing it returns to them as they were", arguments: [false, true])
		func settingsOverTheWorkspace(environmentSelected: Bool) async throws {
			let (store, _) = makeStore()
			defer { store.lock() }
			let host = try await workspace(store)
			defer { host.window.close() }
			let inset: CGFloat = environmentSelected ? 29 : 12
			var rowMidY: CGFloat = 657
			if environmentSelected {
				rowMidY = try await host.clickSidebarEnvironment(".env").y
				try await host.settle()
			}
			#expect(try host.rowIsHighlighted(inset: inset, rowMidY: rowMidY))
			store.showSettings()
			#expect(try await host.waitForText("Close Settings"))
			#expect(store.selectedProjectId == "workspace")
			#expect(!AccessibilityTree.visibleElements(in: host.window, of: host.view).contains { $0.says("Workspace") },
				"Under Settings, the workspace is out of VoiceOver's reach")
			try await host.click("Close Settings")
			#expect(try await host.waitUntil { !store.isShowingAccountPage })
			try await host.settle()
			#expect(try host.rowIsHighlighted(inset: inset, rowMidY: rowMidY), "The row is selected as it was")
		}

		private func makeStore(environments: [String: [String: String]] = ["default": ["TOKEN": "fixture-value"]], additionalProject: Bool = false, keychain: MockKeychainService = MockKeychainService(), preferences: UserDefaults = .standard) -> (VaultStore, MockBiometricService) {
			let biometric = MockBiometricService()
			let project = VaultProject(id: "workspace", name: "Workspace", path: "",
				environments: environments)
			keychain.envStorage[project.id] = (name: project.name, path: "", environments: project.environments)
			let store = VaultStore(keychainService: keychain, biometricService: biometric,
				apiService: MockAPIService(), preferences: preferences, authTokenProvider: { _, _ in nil },
				clipboard: ClipboardManager(pasteboard: .withUniqueName()))
			store.isUnlocked = true
			store.projects = [project]
			if additionalProject {
				let other = VaultProject(id: "other", name: "Other", path: "", environments: ["default": ["SECOND": "second-value"]])
				keychain.envStorage[other.id] = (name: other.name, path: "", environments: other.environments)
				store.projects.append(other)
			}
			store.openProject(id: project.id)
			return (store, biometric)
		}

		/// Starts a refresh and holds it before it reads the Keychain, until the
		/// returned function lets it finish.
		private func holdRefresh(of store: VaultStore, keychain: MockKeychainService) async throws -> () async -> Void {
			let entered = DispatchSemaphore(value: 0)
			let release = DispatchSemaphore(value: 0)
			keychain.beforeKeychainTransaction = { entered.signal(); release.wait() }
			let refresh = Task { await store.refreshLocalState() }
			await withCheckedContinuation { continuation in
				DispatchQueue.global().async { entered.wait(); continuation.resume() }
			}
			keychain.beforeKeychainTransaction = nil
			#expect(store.isRefreshingLocalState)
			return {
				release.signal()
				await refresh.value
			}
		}

		/// Copy confirmations stay until `copyFeedback` ends them. Preferences such
		/// as the key order are read from and saved to `defaults`.
		private func workspace(_ store: VaultStore, size: NSSize = NSSize(width: 1600, height: 800), copyFeedback: ManualFeedbackTimer = ManualFeedbackTimer(), defaults: UserDefaults? = nil) async throws -> SheetTestHost<some View> {
			await store.refreshCliAccess()
			let defaults = try defaults ?? #require(UserDefaults(suiteName: "workspace-interaction"))
			let host = SheetTestHost(VaultWorkspaceView(store: store).environment(UpdateChecker()).environment(VaultAppearanceSettings(defaults: defaults)).environment(VaultQuitSettings(defaults: defaults))
				.environment(\.vaultCopyFeedbackTimer, copyFeedback.timer)
				.defaultAppStorage(defaults),
				size: size, keepsRequestedSize: true, usesHostingView: true)
			#expect(try await host.waitUntil { store.workspaceSnapshots["workspace"] != nil })
			try await host.settle()
			return host
		}

		/// Clicks the KEY column header, which sits between the content header and the first row.
		private func clickKeyHeader<V: View>(in host: SheetTestHost<V>) async throws {
			let label = try await host.labelFrame("KEY", region: CGRect(x: 0.15, y: 0.75, width: 0.5, height: 0.1))
			try clickAt(NSPoint(x: label.midX, y: label.midY), in: host)
		}

		private func keysFromTop(_ keys: [String], lines: [AccessibilityTree.Line]) -> [String] {
			let matches = keys.compactMap { key in keyLine(key, lines: lines).map { (key: key, bounds: $0.bounds) } }
				.sorted { $0.bounds.midY > $1.bounds.midY }
			// Rows next to each other share an edge; rows that overlap can't be ordered.
			guard zip(matches, matches.dropFirst()).allSatisfy({ upper, lower in upper.bounds.minY >= lower.bounds.maxY - 0.000_5 }) else { return [] }
			return matches.map(\.key)
		}

		private func keyLine(_ key: String, lines: [AccessibilityTree.Line]) -> AccessibilityTree.Line? {
			lines.first { $0.text.split { !($0.isLetter || $0.isNumber || $0 == "_") }.contains(Substring(key)) }
		}

		private func keyColumnRegion(header: CGRect, size: NSSize) -> CGRect {
			CGRect(x: (header.minX - 4) / size.width, y: VaultMetrics.statusBar / size.height,
				width: (VaultMetrics.keyColumn - 20) / size.width, height: (header.minY - VaultMetrics.statusBar) / size.height)
		}

		private func waitForKeyOrder<V: View>(_ expected: [String], in host: SheetTestHost<V>, region: CGRect? = nil) async throws -> Bool {
			let keyRegion: CGRect
			if let region {
				keyRegion = region
			} else {
				let header = try await host.drawnFrame(saying: "KEY", region: CGRect(x: 0.15, y: 0.75, width: 0.5, height: 0.1))
				keyRegion = keyColumnRegion(header: header, size: host.view.bounds.size)
			}
			let deadline = ContinuousClock.now.advanced(by: testWaitLimit)
			while true {
				let lines = host.lines(in: keyRegion)
				if keysFromTop(expected, lines: lines) == expected { return true }
				guard ContinuousClock.now < deadline else {
					print("Expected keys \(expected) in \(keyRegion). Lines: " + lines.map { "\($0.text) at \($0.bounds)" }.joined(separator: " | "))
					return false
				}
				try await Task.sleep(for: .milliseconds(20))
			}
		}

		private func keyFrame<V: View>(_ key: String, in host: SheetTestHost<V>, region: CGRect) async throws -> CGRect {
			let image = try host.snapshot(host.view)
			let lines = host.lines(in: region, label: key)
			guard let line = lines.first(where: { $0.labelBounds != nil }), let label = line.labelBounds else {
				print("Missing key \(key) in \(region): " + lines.map { "\($0.text) at \($0.bounds)" }.joined(separator: " | "))
				throw CocoaError(.coderValueNotFound)
			}
			// Alignment is about what's drawn, so the key's ink is measured within its row.
			let band = CGRect(x: region.minX, y: label.minY, width: region.width, height: label.height)
				.insetBy(dx: 0, dy: -2 / CGFloat(image.height)).intersection(region)
			let box = try inkBounds(in: image, region: band)
			return CGRect(x: box.minX * host.view.bounds.width, y: box.minY * host.view.bounds.height,
				width: box.width * host.view.bounds.width, height: box.height * host.view.bounds.height)
		}

		private func inkBounds(in image: CGImage, region: CGRect) throws -> CGRect {
			let imageWidth = CGFloat(image.width), imageHeight = CGFloat(image.height)
			let crop = CGRect(x: region.minX * imageWidth, y: (1 - region.maxY) * imageHeight,
				width: region.width * imageWidth, height: region.height * imageHeight).integral
				.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
			let strip = try #require(image.cropping(to: crop))
			let width = strip.width, height = strip.height
			let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
				bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
			context.draw(strip, in: CGRect(x: 0, y: 0, width: width, height: height))
			let pixels = try #require(context.data).assumingMemoryBound(to: UInt8.self)
			var minX = width, maxX = -1, minTop = height, maxTop = -1
			for top in 0..<height {
				// The key-column strip ends in blank row background, before the value column.
				let sample = (top * width + width - 1) * 4
				for column in 0..<(width - 1) {
					let pixel = (top * width + column) * 4
					let difference = (0..<3).reduce(0) { $0 + abs(Int(pixels[pixel + $1]) - Int(pixels[sample + $1])) }
					if difference > 24 {
						minX = min(minX, column)
						maxX = max(maxX, column)
						minTop = min(minTop, top)
						maxTop = max(maxTop, top)
					}
				}
			}
			try #require(minX <= maxX, "No visible key ink in \(region)")
			return CGRect(x: (crop.minX + CGFloat(minX)) / imageWidth,
				y: (imageHeight - crop.minY - CGFloat(maxTop + 1)) / imageHeight,
				width: CGFloat(maxX - minX + 1) / imageWidth, height: CGFloat(maxTop - minTop + 1) / imageHeight)
		}

		private func verticalPixels(in image: CGImage, size: NSSize, x: CGFloat, from y: CGFloat, count: Int) throws -> [[UInt8]] {
			let context = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
				bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
			context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
			let pixels = try #require(context.data).assumingMemoryBound(to: UInt8.self)
			let column = Int(x * CGFloat(image.width) / size.width)
			let top = Int((size.height - y) * CGFloat(image.height) / size.height)
			try #require(column >= 0 && column < image.width && top >= 0 && top + count <= image.height)
			return (top..<(top + count)).map { row in
				let offset = (row * image.width + column) * 4
				return Array(UnsafeBufferPointer(start: pixels + offset, count: 3))
			}
		}

		/// Each pixel's red, green and blue across `width` points from `x`, along the line `y`, in window coordinates.
		private func horizontalPixels(in image: CGImage, size: NSSize, y: CGFloat, from x: CGFloat, width: CGFloat) throws -> [[UInt8]] {
			let context = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
				bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
			context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
			let pixels = try #require(context.data).assumingMemoryBound(to: UInt8.self)
			let scale = CGFloat(image.width) / size.width
			let row = Int((size.height - y) * scale)
			let first = Int((x * scale).rounded(.down)), count = max(1, Int((width * scale).rounded()))
			try #require(row >= 0 && row < image.height && first >= 0 && first + count <= image.width)
			return (first..<(first + count)).map { column in
				let offset = (row * image.width + column) * 4
				return Array(UnsafeBufferPointer(start: pixels + offset, count: 3))
			}
		}

		/// Which of `pixels` differ from the first, the background a line is drawn over.
		private func lineColumns(_ pixels: [[UInt8]]) -> Set<Int> {
			Set(pixels.indices.filter { index in
				zip(pixels[index], pixels[0]).contains { abs(Int($0) - Int($1)) > 3 }
			})
		}

		/// The horizontal runs of ink in `region` (window points, from the bottom
		/// left) that stand out from the row's background, read at its trailing edge.
		private func inkRuns(in image: CGImage, size: NSSize, region: CGRect) throws -> [CGRect] {
			let scale = CGFloat(image.width) / size.width
			let crop = CGRect(x: region.minX * scale, y: (size.height - region.maxY) * scale,
				width: region.width * scale, height: region.height * scale).integral
			let strip = try #require(image.cropping(to: crop))
			let width = strip.width, height = strip.height
			let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
				bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
			context.draw(strip, in: CGRect(x: 0, y: 0, width: width, height: height))
			let pixels = try #require(context.data).assumingMemoryBound(to: UInt8.self)
			var runs: [CGRect] = []
			var start: Int?
			for column in 0..<width {
				let hasInk = (0..<height).contains { row in
					let background = (row * width + width - 1) * 4
					let pixel = (row * width + column) * 4
					return (0..<3).reduce(0) { $0 + abs(Int(pixels[pixel + $1]) - Int(pixels[background + $1])) } > 60
				}
				if hasInk, start == nil { start = column }
				// Gaps narrower than 4 points are inside a word or glyph; wider ones separate runs.
				if !hasInk, let first = start, !(column..<min(width, column + Int(4 * scale))).contains(where: { next in
					(0..<height).contains { row in
						let background = (row * width + width - 1) * 4
						let pixel = (row * width + next) * 4
						return (0..<3).reduce(0) { $0 + abs(Int(pixels[pixel + $1]) - Int(pixels[background + $1])) } > 60
					}
				}) {
					runs.append(CGRect(x: region.minX + CGFloat(first) / scale, y: region.minY, width: CGFloat(column - first) / scale, height: region.height))
					start = nil
				}
			}
			if let first = start {
				runs.append(CGRect(x: region.minX + CGFloat(first) / scale, y: region.minY, width: CGFloat(width - first) / scale, height: region.height))
			}
			return runs
		}

		private func compactIndicatorProfiles(in image: CGImage, size: NSSize, region: CGRect) throws -> [[Int]] {
			let context = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
				bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
			context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
			let pixels = try #require(context.data).assumingMemoryBound(to: UInt8.self)
			let scale = CGFloat(image.width) / size.width
			let crop = CGRect(x: region.minX * scale, y: (size.height - region.maxY) * scale,
				width: region.width * scale, height: region.height * scale).integral
			var profiles: [[Int]] = []
			var current: [Int] = []
			for column in Int(crop.minX)..<Int(crop.maxX) {
				var count = 0
				for row in Int(crop.minY)..<Int(crop.maxY) {
					let offset = (row * image.width + column) * 4
					if Int(pixels[offset]) > Int(pixels[offset + 1]) + 40 && Int(pixels[offset + 1]) > Int(pixels[offset + 2]) + 40 { count += 1 }
				}
				if count > 0 { current.append(count) }
				else if !current.isEmpty { profiles.append(current); current = [] }
			}
			if !current.isEmpty { profiles.append(current) }
			return profiles
		}

		private func resizeViews(in view: NSView) -> [VaultResizeTrackingView] {
			if let divider = view as? VaultResizeTrackingView { return [divider] }
			return view.subviews.flatMap { resizeViews(in: $0) }
		}

		/// Selects the key in the matrix row at `index`, which opens the inspector.
		private func selectRow<V: View>(_ index: Int, in host: SheetTestHost<V>) throws {
			try clickAt(NSPoint(x: 330, y: 603 - CGFloat(index) * VaultMetrics.matrixRow), in: host)
		}

		/// Clicks the matrix row at `index` twice in quick succession.
		private func doubleClickRow<V: View>(_ index: Int, in host: SheetTestHost<V>) throws {
			try selectRow(index, in: host)
			try selectRow(index, in: host)
		}

		private func clickAt<V: View>(_ point: NSPoint, in host: SheetTestHost<V>) throws {
			try NativeTestClick.send(to: host.window, at: point)
		}
	}
}

private actor WorkspaceApprovalGate {
	private var arrived = false
	private var released = false
	private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []
	private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

	func waitUntilArrived() async {
		guard !arrived else { return }
		await withCheckedContinuation { arrivalWaiters.append($0) }
	}

	func arriveAndWait() async {
		arrived = true
		arrivalWaiters.forEach { $0.resume() }
		arrivalWaiters.removeAll()
		guard !released else { return }
		await withCheckedContinuation { releaseWaiters.append($0) }
	}

	func release() {
		released = true
		releaseWaiters.forEach { $0.resume() }
		releaseWaiters.removeAll()
	}
}

@Suite("Matrix row double-clicks")
@MainActor
struct VaultRowClicksTests {
	@Test("two clicks on one row within the interval are a double-click, and a click on another row in between starts over")
	func doubleClicks() {
		var time: TimeInterval = 100
		let clicks = VaultRowClicks(now: { time }, interval: 0.5)
		#expect(!clicks.isDoubleClick(on: "TOKEN"))
		time += 0.2
		#expect(clicks.isDoubleClick(on: "TOKEN"))
		time += 0.2
		#expect(!clicks.isDoubleClick(on: "TOKEN"), "A third click starts a new double-click")
		time += 0.1
		#expect(!clicks.isDoubleClick(on: "ZETA"))
		time += 0.1
		#expect(!clicks.isDoubleClick(on: "TOKEN"), "A click on another row in between starts over")
		time += 0.6
		#expect(!clicks.isDoubleClick(on: "TOKEN"), "Too slow for a double-click")
		time += 0.5
		#expect(clicks.isDoubleClick(on: "TOKEN"), "Exactly the interval still counts")
	}
}
