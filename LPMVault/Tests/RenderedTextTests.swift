import AppKit
import CoreText
import SwiftUI
import Testing
import Vision

@Suite("Rendered text recognition", .serialized)
struct RenderedTextTests {
	@Test("repeated text reads recognize an unchanged frame once")
	func repeatedReadsShareRecognition() async throws {
		let image = try fixture(width: 937, label: "REPEATED FRAME")
		let calls = RecognitionCalls()
		for _ in 0..<3 {
			let text = try await RenderedText.strings(in: image, usesLanguageCorrection: false, onRecognition: calls.record)
			#expect(text.joined(separator: " ").contains("REPEATED FRAME"))
		}
		#expect(calls.sizes.count == 1)
	}

	@Test("overlapping text reads share one recognition request")
	func overlappingReadsShareRecognition() async throws {
		let image = try fixture(width: 941, label: "OVERLAPPING FRAME")
		let calls = RecognitionCalls()
		try await withThrowingTaskGroup(of: [RenderedText.Line].self) { group in
			for _ in 0..<4 {
				group.addTask {
					try await RenderedText.lines(in: image, level: .accurate, onRecognition: calls.record)
				}
			}
			for try await lines in group {
				#expect(lines.map(\.text).joined(separator: " ").contains("OVERLAPPING FRAME"))
			}
		}
		#expect(calls.sizes.count == 1)
	}

	@Test("language correction has its own cached recognition results")
	func languageCorrectionSeparatesCacheEntries() async throws {
		let image = try fixture(width: 947, label: "LANGUAGE CORRECTION")
		let calls = RecognitionCalls()
		for correction in [true, false, true, false] {
			_ = try await RenderedText.strings(in: image, usesLanguageCorrection: correction, onRecognition: calls.record)
		}
		#expect(calls.sizes.count == 2)
	}

	@Test("recognition processes cropped pixels and retains original-image coordinates")
	func croppedRecognitionPreservesCoordinates() async throws {
		let image = try fixture(width: 1200, height: 700, label: "REGION TARGET", at: CGPoint(x: 400, y: 350))
		let full = try #require(try await RenderedText.lines(in: image, level: .accurate, label: "REGION TARGET").first)
		let calls = RecognitionCalls()
		let region = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
		let cropped = try #require(try await RenderedText.lines(in: image, level: .accurate, label: "REGION TARGET", region: region, onRecognition: calls.record).first)
		#expect(calls.sizes == [CGSize(width: 600, height: 350)])
		#expect(abs(cropped.bounds.midX - full.bounds.midX) < 0.01)
		#expect(abs(cropped.bounds.midY - full.bounds.midY) < 0.01)
		let label = try #require(cropped.labelBounds)
		#expect(region.contains(label))
	}

	@Test("an empty recognition region performs no request", arguments: [
		CGRect.zero, CGRect(x: 2, y: 2, width: 1, height: 1),
	])
	func emptyRegionsSkipRecognition(region: CGRect) async throws {
		let image = try fixture(width: 953, label: "EMPTY REGION")
		let calls = RecognitionCalls()
		let lines = try await RenderedText.lines(in: image, level: .accurate, region: region, onRecognition: calls.record)
		#expect(lines.isEmpty)
		#expect(calls.sizes.isEmpty)
	}

	@Test("changed pixels invalidate recognition even at the same dimensions")
	func changedPixelsInvalidateCache() async throws {
		let first = try fixture(width: 967, label: "FIRST FRAME")
		let second = try fixture(width: 967, label: "SECOND FRAME")
		let calls = RecognitionCalls()
		for (image, expected) in [(first, "FIRST FRAME"), (second, "SECOND FRAME"), (first, "FIRST FRAME")] {
			let text = try await RenderedText.strings(in: image, usesLanguageCorrection: false, onRecognition: calls.record)
			#expect(text.joined(separator: " ").contains(expected))
		}
		#expect(calls.sizes.count == 2)
	}

	@Test("equal-sized crops retain separate text and coordinates")
	func differentCropsStayDistinct() async throws {
		let image = try fixture(width: 971, height: 400, label: "BOTTOM REGION", additionalLabel: "TOP REGION")
		for (y, expected) in [(0.0, "BOTTOM REGION"), (0.5, "TOP REGION"), (0.0, "BOTTOM REGION")] {
			let region = CGRect(x: 0, y: y, width: 1, height: 0.5)
			let lines = try await RenderedText.lines(in: image, level: .accurate, region: region)
			#expect(lines.map(\.text).joined(separator: " ") == expected)
			#expect(try #require(lines.first).bounds.midY >= y)
			#expect(try #require(lines.first).bounds.midY <= y + 0.5)
		}
	}

	private func fixture(width: Int, height: Int = 200, label: String, at point: CGPoint = CGPoint(x: 40, y: 80), additionalLabel: String? = nil) throws -> CGImage {
		let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
			bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
		context.setFillColor(CGColor(gray: 1, alpha: 1))
		context.fill(CGRect(x: 0, y: 0, width: width, height: height))
		let attributes: [NSAttributedString.Key: Any] = [
			NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 32, nil),
			NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
		]
		context.textPosition = point
		CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: label, attributes: attributes)), context)
		if let additionalLabel {
			context.textPosition = CGPoint(x: point.x, y: point.y + 200)
			CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: additionalLabel, attributes: attributes)), context)
		}
		return try #require(context.makeImage())
	}
}

extension SheetInteractionTests {
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

	@Test("native button clicks do not require screenshot recognition", arguments: [true, false])
	func nativeButtonsSkipRecognition(enabled: Bool) async throws {
		let clicks = NativeClicks()
		let host = SheetTestHost(NativeButtonFixture(enabled: enabled) { clicks.count += 1 }.disabled(!enabled), size: NSSize(width: 620, height: 240))
		defer { host.window.close() }
		try await host.settle()
		let calls = RecognitionCalls()
		try await host.click("NATIVE BUTTON", onRecognition: calls.record)
		#expect(clicks.count == (enabled ? 1 : 0))
		#expect(calls.sizes.isEmpty)
		let point = host.view.convert(NSPoint(x: host.view.bounds.midX, y: host.view.bounds.midY), to: nil)
		try NativeTestClick.send(to: host.window, at: point)
		#expect(clicks.count == (enabled ? 2 : 0))
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

private final class RecognitionCalls: @unchecked Sendable {
	private let lock = NSLock()
	private var recorded: [CGSize] = []
	var sizes: [CGSize] { lock.withLock { recorded } }
	func record(width: Int, height: Int) {
		lock.withLock { recorded.append(CGSize(width: width, height: height)) }
	}
}
