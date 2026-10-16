import AppKit
import Darwin
import Foundation
import ImageIO
import Observation
import Testing
import UniformTypeIdentifiers

@testable import LPMVault

/// Files for icon tests: a temporary project folder and images in known colors.
enum ProjectIconFixture {
	static func folder() throws -> URL {
		let url = FileManager.default.temporaryDirectory.appending(path: "project-icon-\(UUID().uuidString)", directoryHint: .isDirectory)
		try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
		return url
	}

	static func write(_ data: Data, to path: String, in folder: URL) throws {
		let url = folder.appending(path: path, directoryHint: .notDirectory)
		try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
		try data.write(to: url)
	}

	static func png(red: UInt8, green: UInt8, blue: UInt8, size: Int = 32, height: Int? = nil) throws -> Data {
		let height = height ?? size
		let context = try #require(CGContext(data: nil, width: size, height: height, bitsPerComponent: 8, bytesPerRow: 0,
			space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
		context.setFillColor(CGColor(srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: 1))
		context.fill(CGRect(x: 0, y: 0, width: size, height: height))
		let image = try #require(context.makeImage())
		let output = NSMutableData()
		let destination = try #require(CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil))
		CGImageDestinationAddImage(destination, image, nil)
		#expect(CGImageDestinationFinalize(destination))
		return output as Data
	}

	static func svg(_ fill: String) -> Data {
		Data(#"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32"><rect width="32" height="32" fill="\#(fill)"/></svg>"#.utf8)
	}

	/// The center pixel of an icon image, as red, green and blue.
	static func center(_ image: CGImage) throws -> (Int, Int, Int) {
		let context = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
			bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
		context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
		let pixels = try #require(context.data).assumingMemoryBound(to: UInt8.self)
		let index = ((image.height / 2) * image.width + image.width / 2) * 4
		return (Int(pixels[index]), Int(pixels[index + 1]), Int(pixels[index + 2]))
	}

	static func isRed(_ image: ProjectIconImage?) throws -> Bool {
		let (red, green, blue) = try center(try #require(image).small)
		return red > 200 && green < 60 && blue < 60
	}

	static func isBlue(_ image: ProjectIconImage?) throws -> Bool {
		let (red, green, blue) = try center(try #require(image).small)
		return blue > 200 && red < 60 && green < 60
	}

	static func resolve(_ folder: URL, choice: ProjectIconChoice = .automatic, findsAutomatic: Bool = false,
		previous: ProjectIconResolution? = nil, images: URL? = nil) -> ProjectIconResolution
	{
		ProjectIconStore.resolve(folder: folder.path, choice: choice, findsAutomatic: findsAutomatic, previous: previous,
			imagesDirectory: images ?? FileManager.default.temporaryDirectory)
	}
}

@Suite("Project icon discovery")
struct ProjectIconDiscoveryTests {
	@Test("well-known locations are checked in T3's fixed order, leaving out its SVG files")
	func candidateOrder() {
		#expect(ProjectIconDiscovery.candidates == [
			"favicon.ico", "favicon.png",
			"public/favicon.ico", "public/favicon.png",
			"app/favicon.ico", "app/favicon.png", "app/icon.png", "app/icon.ico",
			"src/favicon.ico",
			"src/app/favicon.ico", "src/app/icon.png",
			"assets/icon.png", "assets/logo.png",
			"Resources/AppIcon.icns", "AppIcon.icns",
		])
		#expect(ProjectIconDiscovery.sourceFiles == [
			"index.html", "public/index.html", "app/routes/__root.tsx", "src/routes/__root.tsx",
			"app/root.tsx", "src/root.tsx", "src/index.html",
		])
	}

	@Test("the highest-ranked icon wins, and the next one takes over once it's gone")
	func precedence() throws {
		let folder = try ProjectIconFixture.folder()
		defer { try? FileManager.default.removeItem(at: folder) }
		try ProjectIconFixture.write(try ProjectIconFixture.png(red: 0, green: 0, blue: 255), to: "public/favicon.png", in: folder)
		try ProjectIconFixture.write(try ProjectIconFixture.png(red: 255, green: 0, blue: 0), to: "favicon.png", in: folder)
		let first = ProjectIconFixture.resolve(folder)
		#expect(first.detection == .found("favicon.png"))
		#expect(try ProjectIconFixture.isRed(first.automatic?.image))
		try FileManager.default.removeItem(at: folder.appending(path: "favicon.png"))
		let second = ProjectIconFixture.resolve(folder, previous: first)
		#expect(second.detection == .found("public/favicon.png"))
		#expect(try ProjectIconFixture.isBlue(second.automatic?.image))
	}

	@Test("an icon only a nested app has isn't found: nothing is searched for")
	func noRecursiveSearch() throws {
		let folder = try ProjectIconFixture.folder()
		defer { try? FileManager.default.removeItem(at: folder) }
		try ProjectIconFixture.write(try ProjectIconFixture.png(red: 255, green: 0, blue: 0), to: "apps/web/public/favicon.png", in: folder)
		let resolution = ProjectIconFixture.resolve(folder)
		#expect(resolution.detection == .notFound)
		#expect(resolution.automatic == nil)
	}

	@Test("an icon that can't be drawn falls through to the next, and isn't read again until it changes")
	func undrawableFallsThrough() throws {
		let folder = try ProjectIconFixture.folder()
		defer { try? FileManager.default.removeItem(at: folder) }
		try ProjectIconFixture.write(Data("not an icon".utf8), to: "favicon.ico", in: folder)
		try ProjectIconFixture.write(try ProjectIconFixture.png(red: 255, green: 0, blue: 0), to: "assets/icon.png", in: folder)
		let first = ProjectIconFixture.resolve(folder)
		#expect(first.detection == .found("assets/icon.png"))
		#expect(first.undrawable["favicon.ico"] != nil)
		let second = ProjectIconFixture.resolve(folder, previous: first)
		#expect(second.automatic?.image === first.automatic?.image, "Unchanged files keep the image already drawn")
		try ProjectIconFixture.write(try ProjectIconFixture.png(red: 0, green: 0, blue: 255), to: "favicon.ico", in: folder)
		let third = ProjectIconFixture.resolve(folder, previous: second)
		#expect(third.detection == .found("favicon.ico"))
		#expect(try ProjectIconFixture.isBlue(third.automatic?.image))
	}

	@Test("an edited icon is drawn again")
	func editedIconRedraws() throws {
		let folder = try ProjectIconFixture.folder()
		defer { try? FileManager.default.removeItem(at: folder) }
		try ProjectIconFixture.write(try ProjectIconFixture.png(red: 255, green: 0, blue: 0), to: "favicon.png", in: folder)
		let first = ProjectIconFixture.resolve(folder)
		try ProjectIconFixture.write(try ProjectIconFixture.png(red: 0, green: 0, blue: 255, size: 48), to: "favicon.png", in: folder)
		let second = ProjectIconFixture.resolve(folder, previous: first)
		#expect(second.automatic?.image !== first.automatic?.image)
		#expect(try ProjectIconFixture.isBlue(second.automatic?.image))
	}

	@Test("links, pipes, oversized files and enormous images in the project are never read or decoded")
	func untrustedFiles() async throws {
		let folder = try ProjectIconFixture.folder()
		let outside = try ProjectIconFixture.folder()
		defer {
			try? FileManager.default.removeItem(at: folder)
			try? FileManager.default.removeItem(at: outside)
		}
		try ProjectIconFixture.write(try ProjectIconFixture.png(red: 0, green: 0, blue: 255), to: "secret.png", in: outside)
		try FileManager.default.createSymbolicLink(at: folder.appending(path: "favicon.svg"), withDestinationURL: outside.appending(path: "secret.png"))
		try FileManager.default.createSymbolicLink(at: folder.appending(path: "public"), withDestinationURL: outside)
		try ProjectIconFixture.write(try ProjectIconFixture.png(red: 0, green: 0, blue: 255), to: "favicon.png", in: outside)
		try FileManager.default.createDirectory(at: folder.appending(path: "app"), withIntermediateDirectories: true)
		#expect(mkfifo(folder.appending(path: "app/favicon.ico").path, 0o600) == 0)
		try ProjectIconFixture.write(Data(count: ProjectIconFile.maximumImageBytes + 1), to: "app/icon.png", in: folder)
		try ProjectIconFixture.write(try ProjectIconFixture.png(red: 0, green: 0, blue: 255, size: 2049), to: "src/favicon.ico", in: folder)
		try ProjectIconFixture.write(try ProjectIconFixture.png(red: 255, green: 0, blue: 0), to: "AppIcon.icns", in: folder)
		let started = ContinuousClock.now
		let resolution = ProjectIconFixture.resolve(folder)
		#expect(ContinuousClock.now - started < .seconds(5), "A pipe must not block")
		#expect(resolution.detection == .found("AppIcon.icns"))
		#expect(try ProjectIconFixture.isRed(resolution.automatic?.image))
	}

	@Test("a project folder that's gone reports it, and recovers once it's back")
	func missingFolder() throws {
		let folder = try ProjectIconFixture.folder()
		try FileManager.default.removeItem(at: folder)
		#expect(ProjectIconFixture.resolve(folder).detection == .folderMissing)
		#expect(ProjectIconStore.resolve(folder: "", choice: .automatic, findsAutomatic: false, previous: nil,
			imagesDirectory: FileManager.default.temporaryDirectory).detection == .folderMissing)
		try ProjectIconFixture.write(try ProjectIconFixture.png(red: 255, green: 0, blue: 0), to: "favicon.png", in: folder)
		defer { try? FileManager.default.removeItem(at: folder) }
		#expect(ProjectIconFixture.resolve(folder).detection == .found("favicon.png"))
	}

	@Test("a root HTML or component file's icon link is found under public/ first, then the folder")
	func sourceLinks() throws {
		let folder = try ProjectIconFixture.folder()
		defer { try? FileManager.default.removeItem(at: folder) }
		try ProjectIconFixture.write(Data(#"<html><head><link href="/brand/mark.png?v=2" rel="icon"></head></html>"#.utf8), to: "index.html", in: folder)
		try ProjectIconFixture.write(try ProjectIconFixture.png(red: 255, green: 0, blue: 0), to: "brand/mark.png", in: folder)
		let fromRoot = ProjectIconFixture.resolve(folder)
		#expect(fromRoot.detection == .found("brand/mark.png"))
		try ProjectIconFixture.write(try ProjectIconFixture.png(red: 0, green: 0, blue: 255), to: "public/brand/mark.png", in: folder)
		let fromPublic = ProjectIconFixture.resolve(folder, previous: fromRoot)
		#expect(fromPublic.detection == .found("public/brand/mark.png"))
		#expect(try ProjectIconFixture.isBlue(fromPublic.automatic?.image))
		#expect(fromPublic.sources["index.html"]?.paths == ["public/brand/mark.png", "brand/mark.png"])
	}

	@Test("an SVG is never drawn automatically, even one named like a bitmap or linked from a source, but one chosen is")
	func noAutomaticSVG() throws {
		let folder = try ProjectIconFixture.folder()
		defer { try? FileManager.default.removeItem(at: folder) }
		try ProjectIconFixture.write(ProjectIconFixture.svg("#ff0000"), to: "favicon.svg", in: folder)
		try ProjectIconFixture.write(ProjectIconFixture.svg("#ff0000"), to: "public/favicon.png", in: folder)
		try ProjectIconFixture.write(Data(#"<link rel="icon" type="image/svg+xml" href="/logo.svg">"#.utf8), to: "index.html", in: folder)
		try ProjectIconFixture.write(ProjectIconFixture.svg("#ff0000"), to: "public/logo.svg", in: folder)
		let svgOnly = ProjectIconFixture.resolve(folder)
		#expect(svgOnly.detection == .notFound)
		#expect(svgOnly.sources["index.html"]?.paths == [])
		try ProjectIconFixture.write(try ProjectIconFixture.png(red: 0, green: 0, blue: 255), to: "assets/logo.png", in: folder)
		let withBitmap = ProjectIconFixture.resolve(folder, previous: svgOnly)
		#expect(withBitmap.detection == .found("assets/logo.png"))
		#expect(try ProjectIconFixture.isBlue(withBitmap.automatic?.image))
		let chosen = ProjectIconFixture.resolve(folder, choice: .projectFile("favicon.svg"), previous: withBitmap)
		#expect(try ProjectIconFixture.isRed(chosen.chosen?.image), "An SVG chosen in Project Settings is drawn")
	}

	@Test("icon links are read from HTML and from a root route's head objects",
		arguments: [
			(#"<link rel="icon" type="image/png" sizes="32x32" href="/favicon.png" />"#, "favicon.png"),
			(#"<LINK HREF='./img/icon.png' REL='shortcut icon'>"#, "img/icon.png"),
			(#"links: [{ rel: 'stylesheet', href: '/app.css' }, { rel: "icon", href: "/logo.png#light" }]"#, "logo.png"),
			(#"<link rel="apple-touch-icon" href="/touch.png"><link rel="icon" href="/real.ico">"#, "real.ico"),
		])
	func iconLinks(sample: (String, String)) {
		#expect(ProjectIconDiscovery.linkedPaths(in: sample.0) == ["public/" + sample.1, sample.1])
	}

	@Test("icon links that leave the project, name a URL, aren't images or are SVG are ignored",
		arguments: [
			#"<link rel="icon" type="image/svg+xml" href="/favicon.svg">"#,
			#"<link rel="icon" href="https://cdn.example.com/icon.png">"#,
			#"<link rel="icon" href="//cdn.example.com/icon.png">"#,
			#"<link rel="icon" href="../outside.png">"#,
			#"<link rel="icon" href="data:image/png;base64,AAAA">"#,
			#"<link rel="icon" href="/icon.js">"#,
			#"<link rel="stylesheet" href="/icon.png">"#,
		])
	func ignoredLinks(source: String) {
		#expect(ProjectIconDiscovery.linkedPaths(in: source).isEmpty)
	}

	@Test("sources without an icon link, including unclosed tags, are scanned in linear time",
		arguments: ["{ rel: 'stylesheet', href: '/a.css' } <link rel=preload href=x> ", "<link ", "<link rel='icon' href='", "{ rel: 'icon' "])
	func largeSourceScan(fragment: String) {
		let source = String(repeating: fragment, count: ProjectIconFile.maximumSourceBytes / fragment.utf8.count)
		let started = ContinuousClock.now
		#expect(ProjectIconDiscovery.iconHref(in: source) == nil)
		// A quadratic scan of half a megabyte takes minutes; a linear one, milliseconds.
		#expect(ContinuousClock.now - started < .seconds(3))
	}

	@Test("a file's content, not its name, decides whether it's drawn as an SVG, and an SVG too large to draw cheaply isn't drawn")
	func svgRouting() throws {
		let huge = try ProjectIconFixture.png(red: 0, green: 0, blue: 255, size: 2049)
		#expect(!ProjectIconRenderer.isSVG(huge), "A bitmap named favicon.svg is still checked as a bitmap")
		#expect(ProjectIconRenderer.image(from: huge, allowingSVG: true) == nil)
		#expect(try ProjectIconFixture.isRed(ProjectIconRenderer.image(from: try ProjectIconFixture.png(red: 255, green: 0, blue: 0), allowingSVG: true)))
		let svg = ProjectIconFixture.svg("#0000ff")
		#expect(ProjectIconRenderer.isSVG(svg))
		#expect(ProjectIconRenderer.isSVG(Data("\u{FEFF}\n  <?xml version=\"1.0\"?>\n<svg xmlns=\"http://www.w3.org/2000/svg\"/>".utf8)))
		#expect(!ProjectIconRenderer.isSVG(Data("<html><body>svg</body></html>".utf8)))
		#expect(try ProjectIconFixture.isBlue(ProjectIconRenderer.image(from: svg, allowingSVG: true)))
		#expect(ProjectIconRenderer.image(from: svg, allowingSVG: false) == nil, "Only an SVG the user chose is drawn")
		let complex = Data(("<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 32 32\">"
			+ String(repeating: "<circle cx=\"16\" cy=\"16\" r=\"14\" fill=\"red\"/>", count: 20_000) + "</svg>").utf8)
		#expect(complex.count > ProjectIconRenderer.maximumSVGBytes)
		#expect(ProjectIconRenderer.image(from: complex, allowingSVG: true) == nil)
	}

	@Test("a bitmap more than 2048 pixels on a side isn't decoded, whatever its area, and an image too thin to see isn't drawn")
	func drawableBounds() throws {
		#expect(ProjectIconRenderer.image(from: try ProjectIconFixture.png(red: 255, green: 0, blue: 0, size: 4097, height: 1), allowingSVG: true) == nil)
		#expect(ProjectIconRenderer.image(from: try ProjectIconFixture.png(red: 255, green: 0, blue: 0, size: 2048, height: 16), allowingSVG: true) == nil)
		#expect(try ProjectIconFixture.isRed(ProjectIconRenderer.image(from: try ProjectIconFixture.png(red: 255, green: 0, blue: 0, size: 64, height: 32), allowingSVG: true)))
		func svg(width: String, height: String) -> Data {
			Data(#"<svg xmlns="http://www.w3.org/2000/svg" width="\#(width)" height="\#(height)"><rect width="100%" height="100%" fill="red"/></svg>"#.utf8)
		}
		#expect(ProjectIconRenderer.image(from: svg(width: "1e300", height: "1"), allowingSVG: true) == nil)
		#expect(ProjectIconRenderer.image(from: svg(width: "4096", height: "16"), allowingSVG: true) == nil)
		#expect(try ProjectIconFixture.isRed(ProjectIconRenderer.image(from: svg(width: "64", height: "32"), allowingSVG: true)))
	}

	@Test("failures are remembered only for files the project's links can still name")
	func undrawableCacheStaysBounded() throws {
		let folder = try ProjectIconFixture.folder()
		defer { try? FileManager.default.removeItem(at: folder) }
		var resolution: ProjectIconResolution?
		for index in 0..<40 {
			try ProjectIconFixture.write(Data("broken".utf8), to: "img/\(index).png", in: folder)
			try ProjectIconFixture.write(Data(#"<link rel="icon" href="/img/\#(index).png">"#.utf8), to: "index.html", in: folder)
			resolution = ProjectIconFixture.resolve(folder, previous: resolution)
		}
		#expect(resolution?.undrawable.keys.sorted() == ["img/39.png"])
	}

	@Test("a chosen project file shows while it can be read, and the automatic icon shows once it can't")
	func chosenProjectFile() throws {
		let folder = try ProjectIconFixture.folder()
		defer { try? FileManager.default.removeItem(at: folder) }
		try ProjectIconFixture.write(try ProjectIconFixture.png(red: 0, green: 0, blue: 255), to: "apps/web/public/favicon.png", in: folder)
		try ProjectIconFixture.write(try ProjectIconFixture.png(red: 255, green: 0, blue: 0), to: "favicon.png", in: folder)
		let choice = ProjectIconChoice.projectFile("apps/web/public/favicon.png")
		let chosen = ProjectIconFixture.resolve(folder, choice: choice)
		#expect(try ProjectIconFixture.isBlue(chosen.chosen?.image))
		#expect(chosen.automatic == nil, "The automatic icon isn't looked for while the chosen one shows")
		try FileManager.default.removeItem(at: folder.appending(path: "apps/web/public/favicon.png"))
		let fallback = ProjectIconFixture.resolve(folder, choice: choice, previous: chosen)
		#expect(fallback.chosen?.image == nil)
		#expect(try ProjectIconFixture.isRed(fallback.automatic?.image))
	}
}

@Suite("Project icon choices")
struct ProjectIconChoiceTests {
	@Test("every choice survives being saved and read back", arguments: [
		ProjectIconChoice.symbol("bolt.fill", .indigo), .emoji("🚀"), .monogram("DA", .teal),
		.projectFile("apps/web/public/favicon.svg"), .storedImage(file: "\(UUID().uuidString).png", name: "logo.png"),
	])
	func roundTrip(choice: ProjectIconChoice) throws {
		let data = try JSONEncoder().encode(choice)
		#expect(try JSONDecoder().decode(ProjectIconChoice.self, from: data) == choice)
		#expect(choice.isValid)
	}

	@Test("choices LPM Vault couldn't have saved are rejected", arguments: [
		ProjectIconChoice.symbol("not.a.symbol", .red), .emoji("a"), .emoji("1"), .emoji("🚀🚀"),
		.monogram("", .red), .monogram("abc", .red), .projectFile("../outside.png"), .projectFile("/etc/icon.png"),
		.projectFile("a//b.png"), .projectFile("public/icon.js"), .storedImage(file: "../x.png", name: "x"),
		.storedImage(file: "icon.png", name: "icon.png"),
	])
	func invalidChoices(choice: ProjectIconChoice) {
		#expect(!choice.isValid)
	}

	@Test("emoji, including ones made of several scalars, are single emoji characters; text and text presentation aren't", arguments: [
		("🚀", true), ("❤️", true), ("🧑‍💻", true), ("🛰️", true), ("1️⃣", true), ("🇹🇷", true), ("🏳️‍🌈", true), ("👍🏽", true),
		("a", false), ("1", false), ("©", false), ("", false), ("1\u{0301}", false), ("©\u{FE0E}", false), ("☀\u{FE0E}", false),
	])
	func emojiValidation(sample: (String, Bool)) {
		#expect(ProjectIconChoice.isEmoji(sample.0) == sample.1)
	}

	@Test("a monogram suggests the first letters of a name's first two words", arguments: [
		("demo-api", "DA"), ("web-dashboard", "WD"), ("vault", "VA"), ("my api server", "MA"), ("x", "X"), ("—", "P"),
	])
	func suggestedMonogram(sample: (String, String)) {
		#expect(ProjectIconChoice.suggestedMonogram(for: sample.0) == sample.1)
	}

	@Test("a monogram is at most two characters after uppercasing, and normalizing it again changes nothing",
		arguments: [("d1x", "D1"), ("ßa", "SS"), ("aß", "AS"), ("ﬃ", "FF"), ("é", "É")])
	func normalizedMonogram(sample: (String, String)) throws {
		let letters = try #require(ProjectIconChoice.normalizedMonogram(sample.0))
		#expect(letters == sample.1)
		#expect(ProjectIconChoice.normalizedMonogram(letters) == letters)
		#expect(ProjectIconChoice.monogram(letters, .teal).isValid)
	}

	@Test("every catalog symbol exists, and entries are unique and found by their words")
	func catalog() {
		for entry in ProjectIconCatalog.symbols {
			#expect(NSImage(systemSymbolName: entry.value, accessibilityDescription: nil) != nil, "\(entry.value)")
		}
		#expect(Set(ProjectIconCatalog.symbols.map(\.value)).count == ProjectIconCatalog.symbols.count)
		#expect(Set(ProjectIconCatalog.emoji.map(\.value)).count == ProjectIconCatalog.emoji.count)
		#expect(ProjectIconCatalog.emoji.allSatisfy { ProjectIconChoice.isEmoji($0.value) })
		#expect(ProjectIconCatalog.symbols(matching: "database").contains { $0.value == "cylinder.split.1x2" })
		#expect(ProjectIconCatalog.emoji(matching: "rocket").map(\.value) == ["🚀"])
	}

	@Test("every symbol has a readable name for VoiceOver and its tooltip")
	func symbolTitles() {
		for entry in ProjectIconCatalog.symbols {
			#expect(!entry.title.isEmpty && !entry.title.contains("."), "\(entry.value) reads as \(entry.title)")
		}
	}

	@Test("every catalog symbol was in macOS 14.0, as this Mac's symbol data records")
	func symbolsExistOnMacOS14() throws {
		let url = URL(fileURLWithPath: "/System/Library/CoreServices/CoreGlyphs.bundle/Contents/Resources/name_availability.plist")
		// The data is the system's own; a Mac without it can't check this.
		guard let data = try? Data(contentsOf: url),
			let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
			let symbols = plist["symbols"] as? [String: String],
			let releases = plist["year_to_release"] as? [String: [String: String]]
		else { return }
		func version(_ text: String) -> [Int] { text.split(separator: ".").compactMap { Int($0) } }
		for entry in ProjectIconCatalog.symbols {
			let year = try #require(symbols[entry.value], "\(entry.value) isn't a known symbol")
			let macOS = try #require(releases[year]?["macOS"])
			#expect(version(macOS).lexicographicallyPrecedes([14, 0, 1]), "\(entry.value) needs macOS \(macOS)")
		}
	}

	@Test("a file's path in the project folder is found through the folder's own link, and nothing outside it is")
	func relativePaths() throws {
		let folder = try ProjectIconFixture.folder()
		let other = try ProjectIconFixture.folder()
		defer {
			try? FileManager.default.removeItem(at: folder)
			try? FileManager.default.removeItem(at: other)
		}
		try ProjectIconFixture.write(Data(), to: "public/icon.png", in: folder)
		try ProjectIconFixture.write(Data(), to: "icon.png", in: other)
		try FileManager.default.createSymbolicLink(at: folder.appending(path: "linked"), withDestinationURL: other)
		#expect(ProjectIconPath.relativePath(of: folder.appending(path: "public/icon.png"), in: folder.path) == "public/icon.png")
		#expect(ProjectIconPath.relativePath(of: other.appending(path: "icon.png"), in: folder.path) == nil)
		#expect(ProjectIconPath.relativePath(of: folder.appending(path: "linked/icon.png"), in: folder.path) == nil,
			"A link out of the folder resolves outside it")
		#expect(ProjectIconPath.relativePath(of: folder, in: folder.path) == nil)
		#expect(ProjectIconPath.relativePath(of: folder.appending(path: "missing.png"), in: folder.path) == nil)
	}
}

@Suite("Project icon store", .serialized)
@MainActor
struct ProjectIconStoreTests {
	private func makeStore() throws -> (ProjectIconStore, UserDefaults, String, URL) {
		let domain = "project-icons-\(UUID().uuidString)"
		let preferences = try #require(UserDefaults(suiteName: domain))
		let images = FileManager.default.temporaryDirectory.appending(path: "project-icon-images-\(UUID().uuidString)", directoryHint: .isDirectory)
		return (ProjectIconStore(preferences: preferences, imagesDirectory: images), preferences, domain, images)
	}

	@Test("a chosen icon outranks the folder's, persists, and Automatic removes it")
	func choicePrecedenceAndPersistence() async throws {
		let (store, preferences, domain, images) = try makeStore()
		let folder = try ProjectIconFixture.folder()
		defer {
			preferences.removePersistentDomain(forName: domain)
			try? FileManager.default.removeItem(at: folder)
			try? FileManager.default.removeItem(at: images)
		}
		try ProjectIconFixture.write(try ProjectIconFixture.png(red: 255, green: 0, blue: 0), to: "favicon.png", in: folder)
		store.follow([.init(id: "project", folder: folder.path)])
		await store.waitUntilIdle()
		guard case .image(let image) = store.appearance(for: "project") else {
			Issue.record("The folder's icon should show")
			return
		}
		#expect(try ProjectIconFixture.isRed(image))
		store.save(.symbol("bolt.fill", .indigo), for: "project")
		#expect(store.appearance(for: "project") == .symbol("bolt.fill", .indigo))
		let reopened = ProjectIconStore(preferences: preferences, imagesDirectory: images)
		reopened.follow([.init(id: "project", folder: folder.path)])
		#expect(reopened.appearance(for: "project") == .symbol("bolt.fill", .indigo))
		store.save(.automatic, for: "project")
		#expect(preferences.data(forKey: ProjectIconStore.preferencePrefix + "project") == nil)
		await store.waitUntilIdle()
		#expect(store.appearance(for: "project") == .image(image), "The unchanged favicon keeps the image already drawn")
	}

	@Test("a folder with no icon shows the folder glyph, and a chosen copy that's gone falls back to the folder's icon")
	func fallbacks() async throws {
		let (store, preferences, domain, images) = try makeStore()
		let empty = try ProjectIconFixture.folder()
		let withIcon = try ProjectIconFixture.folder()
		defer {
			preferences.removePersistentDomain(forName: domain)
			for url in [empty, withIcon, images] { try? FileManager.default.removeItem(at: url) }
		}
		try ProjectIconFixture.write(try ProjectIconFixture.png(red: 255, green: 0, blue: 0), to: "favicon.png", in: withIcon)
		let missing = ProjectIconChoice.storedImage(file: "\(UUID().uuidString).png", name: "brand.png")
		#expect(store.save(missing, for: "chosen"))
		store.follow([.init(id: "empty", folder: empty.path), .init(id: "chosen", folder: withIcon.path)])
		await store.waitUntilIdle()
		#expect(store.appearance(for: "empty") == .folder)
		#expect(store.detection(for: "empty") == .notFound)
		#expect(store.chosenFileFailed(missing, for: "chosen"))
		guard case .image(let image) = store.appearance(for: "chosen") else {
			Issue.record("The folder's icon shows while the chosen copy is gone")
			return
		}
		#expect(try ProjectIconFixture.isRed(image))
	}

	@Test("a project's folder going missing is noticed whatever icon it has, so its menus can say so without checking the disk")
	func folderMissingWithChoice() async throws {
		let (store, preferences, domain, _) = try makeStore()
		let folder = try ProjectIconFixture.folder()
		defer {
			preferences.removePersistentDomain(forName: domain)
			try? FileManager.default.removeItem(at: folder)
		}
		#expect(store.save(.symbol("bolt.fill", .indigo), for: "p"))
		store.follow([.init(id: "p", folder: folder.path)])
		await store.waitUntilIdle()
		#expect(store.detection(for: "p") != .folderMissing)
		try FileManager.default.removeItem(at: folder)
		store.revalidate("p")
		await store.waitUntilIdle()
		#expect(store.detection(for: "p") == .folderMissing)
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		store.revalidate("p")
		await store.waitUntilIdle()
		#expect(store.detection(for: "p") != .folderMissing)
	}

	@Test("a choice that can't be read is dropped from preferences")
	func invalidStoredChoice() throws {
		let (store, preferences, domain, _) = try makeStore()
		defer { preferences.removePersistentDomain(forName: domain) }
		preferences.set(Data(#"{"kind":"projectFile","path":"../../etc/passwd.png"}"#.utf8), forKey: ProjectIconStore.preferencePrefix + "project")
		store.follow([.init(id: "project", folder: "")])
		#expect(store.choice(for: "project") == nil)
		#expect(preferences.data(forKey: ProjectIconStore.preferencePrefix + "project") == nil)
	}

	@Test("an image in the project folder is followed there; one outside is copied, and its copy goes when it's discarded or replaced")
	func importsImages() async throws {
		let (store, preferences, domain, images) = try makeStore()
		let folder = try ProjectIconFixture.folder()
		let outside = try ProjectIconFixture.folder()
		defer {
			preferences.removePersistentDomain(forName: domain)
			for url in [folder, outside, images] { try? FileManager.default.removeItem(at: url) }
		}
		try ProjectIconFixture.write(try ProjectIconFixture.png(red: 255, green: 0, blue: 0), to: "apps/web/icon.png", in: folder)
		try ProjectIconFixture.write(ProjectIconFixture.svg("#0000ff"), to: "brand.svg", in: outside)
		store.follow([.init(id: "project", folder: folder.path)])

		let inside = try #require(try? await store.importImage(at: folder.appending(path: "apps/web/icon.png"), projectFolder: folder.path, for: "project").get())
		#expect(inside == .projectFile("apps/web/icon.png"))

		let copied = try #require(try? await store.importImage(at: outside.appending(path: "brand.svg"), projectFolder: folder.path, for: "project").get())
		guard case .storedImage(let file, let name) = copied else {
			Issue.record("An image outside the folder is copied")
			return
		}
		#expect(name == "brand.svg")
		let copy = images.appending(path: file)
		#expect(FileManager.default.fileExists(atPath: copy.path))
		if case .image(let preview) = store.appearance(of: copied, for: "project") {
			#expect(try ProjectIconFixture.isBlue(preview))
		} else {
			Issue.record("The copy previews before it's saved")
		}
		store.discardPreview(of: copied, for: "project")
		try await waitUntil { !FileManager.default.fileExists(atPath: copy.path) }

		let saved = try #require(try? await store.importImage(at: outside.appending(path: "brand.svg"), projectFolder: folder.path, for: "project").get())
		guard case .storedImage(let savedFile, _) = saved else {
			Issue.record("An image outside the folder is copied")
			return
		}
		store.save(saved, for: "project")
		await store.waitUntilIdle()
		#expect(FileManager.default.fileExists(atPath: images.appending(path: savedFile).path))
		store.save(.emoji("🚀"), for: "project")
		try await waitUntil { !FileManager.default.fileExists(atPath: images.appending(path: savedFile).path) }
	}

	@Test("forgetting a project removes its choice and copied image; copies no choice uses are collected")
	func forgetsProjects() async throws {
		let (store, preferences, domain, images) = try makeStore()
		let outside = try ProjectIconFixture.folder()
		defer {
			preferences.removePersistentDomain(forName: domain)
			try? FileManager.default.removeItem(at: outside)
			try? FileManager.default.removeItem(at: images)
		}
		try ProjectIconFixture.write(try ProjectIconFixture.png(red: 255, green: 0, blue: 0), to: "icon.png", in: outside)
		let choice = try #require(try? await store.importImage(at: outside.appending(path: "icon.png"), projectFolder: "/nonexistent", for: "gone").get())
		guard case .storedImage(let file, _) = choice else {
			Issue.record("An image outside the folder is copied")
			return
		}
		store.save(choice, for: "gone")
		store.save(.emoji("🚀"), for: "kept")
		let orphan = images.appending(path: "\(UUID().uuidString).png")
		try Data().write(to: orphan)
		await store.collectUnusedImages()
		#expect(!FileManager.default.fileExists(atPath: orphan.path))
		#expect(FileManager.default.fileExists(atPath: images.appending(path: file).path))
		store.forget(keeping: ["kept"])
		#expect(preferences.data(forKey: ProjectIconStore.preferencePrefix + "gone") == nil)
		#expect(preferences.data(forKey: ProjectIconStore.preferencePrefix + "kept") != nil)
		try await waitUntil { !FileManager.default.fileExists(atPath: images.appending(path: file).path) }
	}

	@Test("copied images are kept only in LPM Vault's own folder: one reached through a link is never written, read or deleted")
	func imagesFolderLink() async throws {
		let (store, preferences, domain, images) = try makeStore()
		let outside = try ProjectIconFixture.folder()
		let target = try ProjectIconFixture.folder()
		defer {
			preferences.removePersistentDomain(forName: domain)
			for url in [outside, target, images] { try? FileManager.default.removeItem(at: url) }
		}
		try ProjectIconFixture.write(try ProjectIconFixture.png(red: 255, green: 0, blue: 0), to: "icon.png", in: outside)
		try FileManager.default.createSymbolicLink(at: images, withDestinationURL: target)
		let unused = "\(UUID().uuidString).png"
		try ProjectIconFixture.write(try ProjectIconFixture.png(red: 0, green: 0, blue: 255), to: unused, in: target)
		let saved = "\(UUID().uuidString).png"
		try ProjectIconFixture.write(try ProjectIconFixture.png(red: 0, green: 0, blue: 255), to: saved, in: target)

		#expect(await store.importImage(at: outside.appending(path: "icon.png"), projectFolder: "/nonexistent", for: "p") == .failure(.couldNotSave))
		#expect(try Set(FileManager.default.contentsOfDirectory(atPath: target.path)) == [unused, saved], "Nothing is written through the link")

		let choice = ProjectIconChoice.storedImage(file: saved, name: "brand.png")
		#expect(store.save(choice, for: "p"))
		store.follow([.init(id: "p", folder: outside.path)])
		await store.waitUntilIdle()
		#expect(store.chosenImage(choice, for: "p") == nil, "A copy reached through the link isn't read")
		#expect(store.chosenFileFailed(choice, for: "p"))

		await store.collectUnusedImages(olderThan: Date().addingTimeInterval(60))
		store.save(.emoji("🚀"), for: "p")
		await store.waitForFileWork()
		#expect(try Set(FileManager.default.contentsOfDirectory(atPath: target.path)) == [unused, saved], "Nothing is deleted through the link")
	}

	@Test("an images folder others can read is made private before an image is copied into it, and the copy is the owner's alone")
	func imagesFolderPermissions() async throws {
		let (store, preferences, domain, images) = try makeStore()
		let outside = try ProjectIconFixture.folder()
		defer {
			preferences.removePersistentDomain(forName: domain)
			for url in [outside, images] { try? FileManager.default.removeItem(at: url) }
		}
		try ProjectIconFixture.write(try ProjectIconFixture.png(red: 255, green: 0, blue: 0), to: "icon.png", in: outside)
		try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
		let choice = try #require(try? await store.importImage(at: outside.appending(path: "icon.png"), projectFolder: "/nonexistent", for: "p").get())
		guard case .storedImage(let file, _) = choice else {
			Issue.record("An image outside the folder is copied")
			return
		}
		func permissions(_ url: URL) throws -> Int {
			try #require(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
		}
		#expect(try permissions(images) == 0o700)
		#expect(try permissions(images.appending(path: file)) == 0o600)
	}

	@Test("a copied image two saved choices name is deleted only once neither does")
	func sharedStoredImage() async throws {
		let (store, preferences, domain, images) = try makeStore()
		defer {
			preferences.removePersistentDomain(forName: domain)
			try? FileManager.default.removeItem(at: images)
		}
		let file = "\(UUID().uuidString).png"
		try ProjectIconFixture.write(try ProjectIconFixture.png(red: 255, green: 0, blue: 0), to: file, in: images)
		let shared = try JSONEncoder().encode(ProjectIconChoice.storedImage(file: file, name: "brand.png"))
		for id in ["a", "b", "c"] { preferences.set(shared, forKey: ProjectIconStore.preferencePrefix + id) }
		store.follow([.init(id: "a", folder: "/nonexistent"), .init(id: "b", folder: "/nonexistent"), .init(id: "c", folder: "/nonexistent")])
		store.forget("a")
		store.save(.emoji("🚀"), for: "b")
		await store.waitForFileWork()
		#expect(FileManager.default.fileExists(atPath: images.appending(path: file).path), "c still shows it")
		store.forget("c")
		await store.waitForFileWork()
		#expect(!FileManager.default.fileExists(atPath: images.appending(path: file).path))
	}

	@Test("an unsaved image for one project never shows for another with the same path")
	func previewsBelongToTheirProject() async throws {
		let (store, preferences, domain, images) = try makeStore()
		let first = try ProjectIconFixture.folder()
		let second = try ProjectIconFixture.folder()
		defer {
			preferences.removePersistentDomain(forName: domain)
			for url in [first, second, images] { try? FileManager.default.removeItem(at: url) }
		}
		try ProjectIconFixture.write(try ProjectIconFixture.png(red: 255, green: 0, blue: 0), to: "icon.png", in: first)
		try ProjectIconFixture.write(try ProjectIconFixture.png(red: 0, green: 0, blue: 255), to: "icon.png", in: second)
		store.follow([.init(id: "a", folder: first.path), .init(id: "b", folder: second.path)])
		store.save(.projectFile("icon.png"), for: "a")
		await store.waitUntilIdle()
		let choice = try #require(try? await store.importImage(at: second.appending(path: "icon.png"), projectFolder: second.path, for: "b").get())
		#expect(choice == .projectFile("icon.png"))
		guard case .image(let firstImage) = store.appearance(for: "a"), case .image(let preview) = store.appearance(of: choice, for: "b") else {
			Issue.record("Both projects show an image")
			return
		}
		#expect(try ProjectIconFixture.isRed(firstImage), "A keeps its own icon")
		#expect(try ProjectIconFixture.isBlue(preview))
		store.revalidate("a")
		await store.waitUntilIdle()
		#expect(store.appearance(of: choice, for: "b") == .image(preview), "Checking A again leaves B's unsaved image")
		store.discardPreview(of: choice, for: "b")
		guard case .image(let afterDiscard) = store.appearance(for: "a") else {
			Issue.record("A still shows its image")
			return
		}
		#expect(try ProjectIconFixture.isRed(afterDiscard))
	}

	@Test("an image whose name runs past 255 bytes imports as a choice that saves")
	func longUnicodeName() async throws {
		let (store, preferences, domain, images) = try makeStore()
		let outside = try ProjectIconFixture.folder()
		defer {
			preferences.removePersistentDomain(forName: domain)
			try? FileManager.default.removeItem(at: outside)
			try? FileManager.default.removeItem(at: images)
		}
		let name = String(repeating: "猫", count: 100) + ".png"
		try ProjectIconFixture.write(try ProjectIconFixture.png(red: 255, green: 0, blue: 0), to: name, in: outside)
		let choice = try #require(try? await store.importImage(at: outside.appending(path: name), projectFolder: "/nonexistent", for: "p").get())
		#expect(choice.isValid)
		#expect(store.save(choice, for: "p"))
		#expect(store.choice(for: "p") == choice)
	}

	@Test("an image import belongs to its project, and so does its failure")
	func importStatePerProject() async throws {
		let (store, preferences, domain, images) = try makeStore()
		let outside = try ProjectIconFixture.folder()
		defer {
			preferences.removePersistentDomain(forName: domain)
			try? FileManager.default.removeItem(at: outside)
			try? FileManager.default.removeItem(at: images)
		}
		try ProjectIconFixture.write(try ProjectIconFixture.png(red: 255, green: 0, blue: 0), to: "logo.png", in: outside)
		try ProjectIconFixture.write(Data("not an image".utf8), to: "broken.png", in: outside)
		let running = Task { await store.importImage(at: outside.appending(path: "logo.png"), projectFolder: "/nonexistent", for: "a") }
		await Task.yield()
		#expect(store.isImporting("a"))
		#expect(!store.isImporting("b"))
		_ = await running.value
		#expect(!store.isImporting("a"))
		_ = await store.importImage(at: outside.appending(path: "broken.png"), projectFolder: "/nonexistent", for: "a")
		#expect(store.importFailures["a"] == .notAnImage)
		#expect(store.importFailures["b"] == nil)
	}

	@Test("collecting unused images leaves a copy written after collecting began")
	func collectionSparesNewCopies() async throws {
		let (store, preferences, domain, images) = try makeStore()
		defer {
			preferences.removePersistentDomain(forName: domain)
			try? FileManager.default.removeItem(at: images)
		}
		try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
		let old = images.appending(path: "\(UUID().uuidString).png")
		let fresh = images.appending(path: "\(UUID().uuidString).png")
		try Data().write(to: old)
		try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3_600)], ofItemAtPath: old.path)
		let began = Date(timeIntervalSinceNow: -60)
		try Data().write(to: fresh)
		await store.collectUnusedImages(olderThan: began)
		#expect(!FileManager.default.fileExists(atPath: old.path))
		#expect(FileManager.default.fileExists(atPath: fresh.path), "An import that finishes while collecting keeps its copy")
	}

	@Test("watching a project's icon files checks them once as it starts, so a change made just before isn't missed")
	func watchChecksOnStart() async throws {
		let (store, preferences, domain, _) = try makeStore()
		let folder = try ProjectIconFixture.folder()
		defer {
			preferences.removePersistentDomain(forName: domain)
			try? FileManager.default.removeItem(at: folder)
		}
		try ProjectIconFixture.write(try ProjectIconFixture.png(red: 255, green: 0, blue: 0), to: "favicon.png", in: folder)
		store.follow([.init(id: "p", folder: folder.path)])
		await store.waitUntilIdle()
		try ProjectIconFixture.write(try ProjectIconFixture.png(red: 0, green: 0, blue: 255, size: 40), to: "favicon.png", in: folder)
		let watch = Task { await store.watch("p") }
		defer { watch.cancel() }
		try await waitUntil { (try? ProjectIconFixture.isBlue(store.resolution(for: "p")?.automatic?.image)) == true }
	}

	@Test("one project's new icon leaves the other projects' rows alone")
	func observationIsPerProject() async throws {
		let (store, preferences, domain, _) = try makeStore()
		var folders: [URL] = []
		defer {
			preferences.removePersistentDomain(forName: domain)
			for folder in folders { try? FileManager.default.removeItem(at: folder) }
		}
		for _ in 0..<20 { folders.append(try ProjectIconFixture.folder()) }
		store.follow(folders.enumerated().map { .init(id: "p\($0.offset)", folder: $0.element.path) })
		await store.waitUntilIdle()
		let invalidated = InvalidationCounter()
		for index in 1..<20 {
			withObservationTracking { _ = store.appearance(for: "p\(index)") } onChange: { invalidated.add() }
		}
		try ProjectIconFixture.write(try ProjectIconFixture.png(red: 255, green: 0, blue: 0), to: "favicon.png", in: folders[0])
		store.revalidate("p0")
		await store.waitUntilIdle()
		#expect(store.appearance(for: "p0") != .folder)
		#expect(invalidated.count == 0)
	}

	@Test("many projects resolve a few at a time, and each is redrawn only when its files change")
	func revalidation() async throws {
		let (store, preferences, domain, _) = try makeStore()
		var folders: [URL] = []
		defer {
			preferences.removePersistentDomain(forName: domain)
			for folder in folders { try? FileManager.default.removeItem(at: folder) }
		}
		for _ in 0..<12 {
			let folder = try ProjectIconFixture.folder()
			try ProjectIconFixture.write(try ProjectIconFixture.png(red: 255, green: 0, blue: 0), to: "favicon.png", in: folder)
			folders.append(folder)
		}
		store.follow(folders.enumerated().map { .init(id: "p\($0.offset)", folder: $0.element.path) })
		await store.waitUntilIdle()
		let before = (0..<12).map { store.resolution(for: "p\($0)")?.automatic?.image }
		#expect(before.allSatisfy { $0 != nil })
		try ProjectIconFixture.write(try ProjectIconFixture.png(red: 0, green: 0, blue: 255, size: 40), to: "favicon.png", in: folders[3])
		store.revalidate()
		await store.waitUntilIdle()
		for index in 0..<12 {
			let image = store.resolution(for: "p\(index)")?.automatic?.image
			if index == 3 {
				#expect(try ProjectIconFixture.isBlue(image))
			} else {
				#expect(image === before[index], "Project \(index)'s unchanged icon isn't drawn again")
			}
		}
		store.follow([.init(id: "p0", folder: folders[0].path)])
		#expect(store.resolution(for: "p0") != nil)
		#expect((1..<12).allSatisfy { store.resolution(for: "p\($0)") == nil }, "Projects no longer followed are forgotten")
	}

	private func waitUntil(_ condition: () -> Bool) async throws {
		let deadline = ContinuousClock.now + .seconds(5)
		while !condition() {
			guard ContinuousClock.now < deadline else {
				Issue.record("Timed out")
				return
			}
			try await Task.sleep(for: .milliseconds(10))
		}
	}
}

final class InvalidationCounter: @unchecked Sendable {
	private let lock = NSLock()
	private var value = 0
	var count: Int { lock.withLock { value } }
	func add() { lock.withLock { value += 1 } }
}
