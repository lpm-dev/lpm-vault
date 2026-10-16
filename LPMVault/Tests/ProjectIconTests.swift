import AppKit
import Darwin
import Foundation
import ImageIO
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

	static func png(red: UInt8, green: UInt8, blue: UInt8, size: Int = 32) throws -> Data {
		let context = try #require(CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
			space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
		context.setFillColor(CGColor(srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: 1))
		context.fill(CGRect(x: 0, y: 0, width: size, height: size))
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
	@Test("well-known locations are checked in T3's fixed order")
	func candidateOrder() {
		#expect(ProjectIconDiscovery.candidates == [
			"favicon.svg", "favicon.ico", "favicon.png",
			"public/favicon.svg", "public/favicon.ico", "public/favicon.png",
			"app/favicon.ico", "app/favicon.png", "app/icon.svg", "app/icon.png", "app/icon.ico",
			"src/favicon.ico", "src/favicon.svg",
			"src/app/favicon.ico", "src/app/icon.svg", "src/app/icon.png",
			"assets/icon.svg", "assets/icon.png", "assets/logo.svg", "assets/logo.png",
			".idea/icon.svg", "Resources/AppIcon.icns", "AppIcon.icns",
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
		try ProjectIconFixture.write(ProjectIconFixture.svg("#0000ff"), to: "public/favicon.svg", in: folder)
		try ProjectIconFixture.write(try ProjectIconFixture.png(red: 255, green: 0, blue: 0), to: "favicon.png", in: folder)
		let first = ProjectIconFixture.resolve(folder)
		#expect(first.detection == .found("favicon.png"))
		#expect(try ProjectIconFixture.isRed(first.automatic?.image))
		try FileManager.default.removeItem(at: folder.appending(path: "favicon.png"))
		let second = ProjectIconFixture.resolve(folder, previous: first)
		#expect(second.detection == .found("public/favicon.svg"))
		#expect(try ProjectIconFixture.isBlue(second.automatic?.image))
	}

	@Test("an icon only a nested app has isn't found: nothing is searched for")
	func noRecursiveSearch() throws {
		let folder = try ProjectIconFixture.folder()
		defer { try? FileManager.default.removeItem(at: folder) }
		try ProjectIconFixture.write(ProjectIconFixture.svg("#ff0000"), to: "apps/web/public/favicon.svg", in: folder)
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
		try ProjectIconFixture.write(ProjectIconFixture.svg("#ff0000"), to: "favicon.svg", in: folder)
		defer { try? FileManager.default.removeItem(at: folder) }
		#expect(ProjectIconFixture.resolve(folder).detection == .found("favicon.svg"))
	}

	@Test("a root HTML or component file's icon link is found under public/ first, then the folder")
	func sourceLinks() throws {
		let folder = try ProjectIconFixture.folder()
		defer { try? FileManager.default.removeItem(at: folder) }
		try ProjectIconFixture.write(Data(#"<html><head><link href="/brand/mark.svg?v=2" rel="icon"></head></html>"#.utf8), to: "index.html", in: folder)
		try ProjectIconFixture.write(ProjectIconFixture.svg("#ff0000"), to: "brand/mark.svg", in: folder)
		let fromRoot = ProjectIconFixture.resolve(folder)
		#expect(fromRoot.detection == .found("brand/mark.svg"))
		try ProjectIconFixture.write(ProjectIconFixture.svg("#0000ff"), to: "public/brand/mark.svg", in: folder)
		let fromPublic = ProjectIconFixture.resolve(folder, previous: fromRoot)
		#expect(fromPublic.detection == .found("public/brand/mark.svg"))
		#expect(try ProjectIconFixture.isBlue(fromPublic.automatic?.image))
		#expect(fromPublic.sources["index.html"]?.paths == ["public/brand/mark.svg", "brand/mark.svg"])
	}

	@Test("icon links are read from HTML and from a root route's head objects",
		arguments: [
			(#"<link rel="icon" type="image/svg+xml" href="/favicon.svg" />"#, "favicon.svg"),
			(#"<LINK HREF='./img/icon.png' REL='shortcut icon'>"#, "img/icon.png"),
			(#"links: [{ rel: 'stylesheet', href: '/app.css' }, { rel: "icon", href: "/logo.png#light" }]"#, "logo.png"),
			(#"<link rel="apple-touch-icon" href="/touch.png"><link rel="icon" href="/real.ico">"#, "real.ico"),
		])
	func iconLinks(sample: (String, String)) {
		#expect(ProjectIconDiscovery.linkedPaths(in: sample.0) == ["public/" + sample.1, sample.1])
	}

	@Test("icon links that leave the project, name a URL or aren't images are ignored",
		arguments: [
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

	@Test("a large source without an icon link is scanned in linear time")
	func largeSourceScan() {
		let source = String(repeating: "{ rel: 'stylesheet', href: '/a.css' } <link rel=preload href=x> ", count: 6_000)
		let started = ContinuousClock.now
		#expect(ProjectIconDiscovery.iconHref(in: source) == nil)
		#expect(ContinuousClock.now - started < .seconds(2))
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

	@Test("emoji, including ones made of several scalars, are single emoji characters", arguments: [
		("🚀", true), ("❤️", true), ("🧑‍💻", true), ("🛰️", true), ("a", false), ("1", false), ("©", false), ("", false),
	])
	func emojiValidation(sample: (String, Bool)) {
		#expect(ProjectIconChoice.isEmoji(sample.0) == sample.1)
	}

	@Test("a monogram suggests the first letters of a name's first two words", arguments: [
		("demo-api", "DA"), ("web-dashboard", "WD"), ("vault", "VA"), ("my api server", "MA"), ("x", "X"), ("—", "P"),
	])
	func suggestedMonogram(sample: (String, String)) {
		#expect(ProjectIconChoice.suggestedMonogram(for: sample.0) == sample.1)
		#expect(ProjectIconChoice.normalizedMonogram("d1x") == "D1")
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

	@Test("a choice that can't be read is dropped from preferences")
	func invalidStoredChoice() throws {
		let (store, preferences, domain, _) = try makeStore()
		defer { preferences.removePersistentDomain(forName: domain) }
		preferences.set(Data(#"{"kind":"projectFile","path":"../../etc/passwd.png"}"#.utf8), forKey: ProjectIconStore.preferencePrefix + "project")
		store.follow([.init(id: "project", folder: "")])
		#expect(store.choices["project"] == nil)
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

		let inside = try #require(try? await store.importImage(at: folder.appending(path: "apps/web/icon.png"), projectFolder: folder.path).get())
		#expect(inside == .projectFile("apps/web/icon.png"))

		let copied = try #require(try? await store.importImage(at: outside.appending(path: "brand.svg"), projectFolder: folder.path).get())
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
		store.discardPreview(of: copied)
		try await waitUntil { !FileManager.default.fileExists(atPath: copy.path) }

		let saved = try #require(try? await store.importImage(at: outside.appending(path: "brand.svg"), projectFolder: folder.path).get())
		guard case .storedImage(let savedFile, _) = saved else { return }
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
		let choice = try #require(try? await store.importImage(at: outside.appending(path: "icon.png"), projectFolder: "/nonexistent").get())
		guard case .storedImage(let file, _) = choice else { return }
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
		let before = (0..<12).map { store.resolutions["p\($0)"]?.automatic?.image }
		#expect(before.allSatisfy { $0 != nil })
		try ProjectIconFixture.write(try ProjectIconFixture.png(red: 0, green: 0, blue: 255, size: 40), to: "favicon.png", in: folders[3])
		store.revalidate()
		await store.waitUntilIdle()
		for index in 0..<12 {
			let image = store.resolutions["p\(index)"]?.automatic?.image
			if index == 3 {
				#expect(try ProjectIconFixture.isBlue(image))
			} else {
				#expect(image === before[index], "Project \(index)'s unchanged icon isn't drawn again")
			}
		}
		store.follow([.init(id: "p0", folder: folders[0].path)])
		#expect(store.resolutions.keys.sorted() == ["p0"])
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
