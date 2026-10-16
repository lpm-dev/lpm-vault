import AppKit
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A file's identity and last change, which tells an edited or replaced file
/// from the one read before.
struct ProjectIconFileSignature: Hashable, Sendable {
	let device: UInt64
	let inode: UInt64
	let size: Int64
	let modified: Int64
	let changed: Int64

	init(_ info: stat) {
		device = UInt64(info.st_dev)
		inode = UInt64(info.st_ino)
		size = Int64(info.st_size)
		modified = Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec)
		changed = Int64(info.st_ctimespec.tv_sec) * 1_000_000_000 + Int64(info.st_ctimespec.tv_nsec)
	}
}

/// Reads icon files and the sources that name them from a project folder.
/// The folder comes from the project, often a cloned repository, so below it
/// nothing is reached through a link, only a regular file is read, and reads
/// are capped: opening a pipe would block, and a device could reach a driver.
enum ProjectIconFile {
	static let maximumImageBytes = 8 * 1024 * 1024
	static let maximumSourceBytes = 512 * 1024

	enum Failure: Error, Equatable {
		case missing
		/// A link, or something other than a regular file.
		case unsafe
		case tooLarge
		case unreadable
	}

	/// Whether the project folder is there.
	static func folderExists(_ folder: String) -> Bool {
		let descriptor = Darwin.open(folder, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
		guard descriptor >= 0 else { return false }
		Darwin.close(descriptor)
		return true
	}

	/// The signature of each of `paths` that's a regular file, opening each
	/// folder on the way once however many of the paths are in it.
	static func signatures(of paths: [String], in folder: String) -> [String: ProjectIconFileSignature] {
		var folders = FolderDescriptors(root: folder)
		defer { folders.closeAll() }
		var signatures: [String: ProjectIconFileSignature] = [:]
		for path in paths where ProjectIconPath.isSafe(path) {
			let (parent, name) = split(path)
			guard let descriptor = folders.descriptor(for: parent) else { continue }
			var info = stat()
			guard fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0, info.st_mode & S_IFMT == S_IFREG else { continue }
			signatures[path] = ProjectIconFileSignature(info)
		}
		return signatures
	}

	/// Reads the regular file at `path` in `folder`, up to `maximumBytes`.
	static func read(_ path: String, in folder: String, maximumBytes: Int) throws(Failure) -> (data: Data, signature: ProjectIconFileSignature) {
		guard ProjectIconPath.isSafe(path) else { throw .unsafe }
		let (parent, name) = split(path)
		var folders = FolderDescriptors(root: folder)
		defer { folders.closeAll() }
		guard let directory = folders.descriptor(for: parent) else { throw folders.failure }
		return try read(descriptor: openat(directory, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC), maximumBytes: maximumBytes)
	}

	/// Reads the regular file at `url`, without following a link at its last component.
	static func read(_ url: URL, maximumBytes: Int) throws(Failure) -> (data: Data, signature: ProjectIconFileSignature) {
		let descriptor = url.withUnsafeFileSystemRepresentation { path in
			path.map { Darwin.open($0, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC) } ?? -1
		}
		return try read(descriptor: descriptor, maximumBytes: maximumBytes)
	}

	/// Reads the regular file `descriptor` opened, which it then closes.
	static func read(descriptor: Int32, maximumBytes: Int) throws(Failure) -> (data: Data, signature: ProjectIconFileSignature) {
		guard descriptor >= 0 else {
			switch errno {
			case ENOENT, ENOTDIR: throw .missing
			case ELOOP: throw .unsafe
			default: throw .unreadable
			}
		}
		defer { Darwin.close(descriptor) }
		var info = stat()
		guard fstat(descriptor, &info) == 0 else { throw .unreadable }
		guard info.st_mode & S_IFMT == S_IFREG else { throw .unsafe }
		guard info.st_size >= 0, info.st_size <= Int64(maximumBytes) else { throw .tooLarge }
		var data = Data(count: Int(info.st_size))
		var total = 0
		while total < data.count {
			let count = data.withUnsafeMutableBytes { bytes in
				Darwin.read(descriptor, bytes.baseAddress! + total, bytes.count - total)
			}
			if count == 0 { break }
			if count < 0 {
				if errno == EINTR { continue }
				throw .unreadable
			}
			total += count
		}
		data.count = total
		return (data, ProjectIconFileSignature(info))
	}

	private static func split(_ path: String) -> (parent: String, name: String) {
		guard let slash = path.lastIndex(of: "/") else { return ("", path) }
		return (String(path[..<slash]), String(path[path.index(after: slash)...]))
	}

	/// Folders below the project folder, each opened a component at a time
	/// without following a link, and kept open for the paths in them.
	private struct FolderDescriptors {
		let root: String
		private var opened: [String: Int32] = [:]
		private var missing: Set<String> = []
		private(set) var failure: Failure = .missing

		init(root: String) { self.root = root }

		mutating func descriptor(for folder: String) -> Int32? {
			if let descriptor = opened[folder] { return descriptor }
			if missing.contains(folder) { return nil }
			let descriptor: Int32
			if folder.isEmpty {
				descriptor = Darwin.open(root, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
			} else {
				let (parent, name) = ProjectIconFile.split(folder)
				guard let parentDescriptor = self.descriptor(for: parent) else {
					missing.insert(folder)
					return nil
				}
				descriptor = openat(parentDescriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
			}
			guard descriptor >= 0 else {
				failure = errno == ELOOP || errno == ENOTDIR ? .unsafe : .missing
				missing.insert(folder)
				return nil
			}
			opened[folder] = descriptor
			return descriptor
		}

		mutating func closeAll() {
			for descriptor in opened.values { Darwin.close(descriptor) }
			opened.removeAll()
		}
	}
}

/// Where a project's icon usually is: well-known image files, then the icon
/// a web app's root HTML or root component links to. Only these paths are
/// checked; nothing is searched for. SVG files are left out: drawing one can
/// take AppKit unbounded time and memory, so only an SVG chosen in Project
/// Settings is drawn.
enum ProjectIconDiscovery {
	/// T3's fixed list, in its order, without its SVG files.
	static let candidates = [
		"favicon.ico",
		"favicon.png",
		"public/favicon.ico",
		"public/favicon.png",
		"app/favicon.ico",
		"app/favicon.png",
		"app/icon.png",
		"app/icon.ico",
		"src/favicon.ico",
		"src/app/favicon.ico",
		"src/app/icon.png",
		"assets/icon.png",
		"assets/logo.png",
		"Resources/AppIcon.icns",
		"AppIcon.icns",
	]

	static let sourceFiles = [
		"index.html",
		"public/index.html",
		"app/routes/__root.tsx",
		"src/routes/__root.tsx",
		"app/root.tsx",
		"src/root.tsx",
		"src/index.html",
	]

	/// A source file's icon links as last read.
	struct SourceLinks: Equatable, Sendable {
		let signature: ProjectIconFileSignature
		/// The paths the icon link can name, most likely first.
		let paths: [String]
	}

	/// The icon a source links to, as a path its `href` can name in the
	/// project folder, most likely first: under `public/`, where web
	/// frameworks serve root paths from, then from the folder itself.
	static func linkedPaths(in source: String) -> [String] {
		guard let href = iconHref(in: source) else { return [] }
		var clean = Substring(href)
		if let end = clean.firstIndex(where: { $0 == "#" || $0 == "?" }) { clean = clean[..<end] }
		guard !clean.contains(":"), !clean.hasPrefix("//") else { return [] }
		while true {
			if clean.hasPrefix("./") {
				clean = clean.dropFirst(2)
			} else if clean.hasPrefix("/") {
				clean = clean.dropFirst()
			} else {
				break
			}
		}
		let path = String(clean)
		guard ProjectIconPath.isSafe(path), ProjectIconPath.isImage(path), !ProjectIconPath.isSVG(path) else { return [] }
		return ["public/" + path, path].filter(ProjectIconPath.isSafe)
	}

	/// The `href` of the first icon link: an HTML `<link rel="icon">`, or an
	/// object literal with `rel: "icon"`, as a root route's head lists them.
	static func iconHref(in source: String) -> String? {
		let text = source as NSString
		if let href = linkTagHref(in: text) { return href }
		// A run between braces is one object at most; matching each run on its
		// own keeps the scan linear, where one pattern across the whole source
		// would restart at every offset.
		var start = 0
		while start < text.length {
			let close = text.range(of: "}", range: NSRange(location: start, length: text.length - start))
			let end = close.location == NSNotFound ? text.length : close.location
			let run = NSRange(location: start, length: end - start)
			if iconRel.firstMatch(in: source, range: run) != nil,
				let match = objectHref.firstMatch(in: source, range: run), match.range(at: 1).location != NSNotFound
			{
				return text.substring(with: match.range(at: 1))
			}
			start = end + 1
		}
		return nil
	}

	/// The `href` of the first `<link>` tag whose rel is an icon. Each tag is
	/// read once, and a tag that's never closed ends the scan, since nothing
	/// after it can close a tag either; a pattern that looked ahead from every
	/// `<link` would read the rest of the source again for each one.
	private static func linkTagHref(in text: NSString) -> String? {
		var start = 0
		while start < text.length {
			let open = text.range(of: "<link", options: .caseInsensitive, range: NSRange(location: start, length: text.length - start))
			guard open.location != NSNotFound else { return nil }
			let nameEnd = open.location + open.length
			let close = text.range(of: ">", range: NSRange(location: nameEnd, length: text.length - nameEnd))
			guard close.location != NSNotFound else { return nil }
			start = close.location + 1
			guard nameEnd < close.location, let boundary = UnicodeScalar(text.character(at: nameEnd)),
				CharacterSet.whitespacesAndNewlines.contains(boundary) || boundary == "/"
			else { continue }
			let tag = text.substring(with: NSRange(location: nameEnd, length: close.location - nameEnd))
			let whole = NSRange(location: 0, length: (tag as NSString).length)
			if tagIconRel.firstMatch(in: tag, range: whole) != nil, let match = tagHref.firstMatch(in: tag, range: whole),
				match.range(at: 1).location != NSNotFound
			{
				return (tag as NSString).substring(with: match.range(at: 1))
			}
		}
		return nil
	}

	private static let tagIconRel = expression(#"\brel\s*=\s*["'](?:icon|shortcut icon)["']"#)
	private static let tagHref = expression(#"\bhref\s*=\s*["']([^"'?#]+)"#)
	private static let iconRel = expression(#"\brel\s*:\s*["'](?:icon|shortcut icon)["']"#)
	private static let objectHref = expression(#"\bhref\s*:\s*["']([^"'?#]+)"#)

	private static func expression(_ pattern: String) -> NSRegularExpression {
		// The patterns are constants, so failing to compile one is a programming error.
		try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
	}
}

/// Draws icon files as small square images. Every image is checked before
/// it's decoded, since a small file can describe an enormous one, and each is
/// decoded once for all the sizes drawn from it.
enum ProjectIconRenderer {
	/// The most pixels a bitmap can have on a side to be decoded.
	static let maximumSide = 2048
	/// The largest SVG drawn. A vector's cost grows with what it holds, not its
	/// size on screen, and favicons are a few kilobytes.
	static let maximumSVGBytes = 512 * 1024
	static let smallPixels = 32
	static let largePixels = 96
	/// How large a copied image is kept, enough for every size it's drawn at.
	static let storedPixels = 128
	/// SVGs draw one at a time, which bounds the memory AppKit takes to parse them.
	private static let svgDrawing = NSLock()

	/// The image drawn at the sidebar's size and the Project Settings page's.
	/// An SVG is drawn only when `allowingSVG`, for a file the user chose.
	static func image(from data: Data, allowingSVG: Bool) -> ProjectIconImage? {
		guard let drawn = render(data, sizes: [largePixels, smallPixels], allowingSVG: allowingSVG) else { return nil }
		return ProjectIconImage(small: drawn[1], large: drawn[0])
	}

	/// A copy to keep of an image the user chose, as a PNG, and the image it
	/// shows, from one decode.
	static func copy(from data: Data) -> (png: Data, image: ProjectIconImage)? {
		guard let drawn = render(data, sizes: [storedPixels], allowingSVG: true), let stored = drawn.first,
			let large = draw(pixels: largePixels, from: stored), let small = draw(pixels: smallPixels, from: stored)
		else { return nil }
		let output = NSMutableData()
		guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { return nil }
		CGImageDestinationAddImage(destination, stored, nil)
		guard CGImageDestinationFinalize(destination) else { return nil }
		return (output as Data, ProjectIconImage(small: small, large: large))
	}

	/// The image drawn square at each of `sizes`, largest first, or nil when it can't be.
	static func render(_ data: Data, sizes: [Int], allowingSVG: Bool) -> [CGImage]? {
		guard isSVG(data) else { return renderBitmap(data, sizes: sizes) }
		return allowingSVG ? renderSVG(data, sizes: sizes) : nil
	}

	/// Whether `data` is SVG text. The content decides, not a file's name: a
	/// bitmap named .svg is still checked as a bitmap.
	static func isSVG(_ data: Data) -> Bool {
		let head = String(decoding: data.prefix(1024), as: UTF8.self).drop { $0.isWhitespace || $0 == "\u{FEFF}" }
		return head.hasPrefix("<") && head.range(of: "<svg", options: .caseInsensitive) != nil
	}

	private static func renderBitmap(_ data: Data, sizes: [Int]) -> [CGImage]? {
		guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
		var frames: [(index: Int, size: Int)] = []
		for index in 0..<min(CGImageSourceGetCount(source), 64) {
			guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
				let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
				width <= maximumSide, height <= maximumSide, isVisible(CGSize(width: width, height: height))
			else { continue }
			frames.append((index, max(width, height)))
		}
		guard !frames.isEmpty else { return nil }
		// Icon files hold several sizes: the smallest at least as large as
		// what's drawn looks best, else the largest there is.
		func frame(for pixels: Int) -> Int {
			let large = frames.filter { $0.size >= pixels }.min { $0.size < $1.size }
			return (large ?? frames.max { $0.size < $1.size }!).index
		}
		var decoded: [Int: CGImage] = [:]
		var drawn: [CGImage] = []
		for pixels in sizes {
			let index = frame(for: pixels)
			let image: CGImage
			if let decodedFrame = decoded[index] {
				image = decodedFrame
			} else {
				let options: [CFString: Any] = [
					kCGImageSourceCreateThumbnailFromImageAlways: true,
					kCGImageSourceCreateThumbnailWithTransform: true,
					kCGImageSourceThumbnailMaxPixelSize: sizes.max() ?? pixels,
					kCGImageSourceShouldCacheImmediately: true,
				]
				guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) else { return nil }
				decoded[index] = thumbnail
				image = thumbnail
			}
			guard let square = draw(pixels: pixels, from: image) else { return nil }
			drawn.append(square)
		}
		return drawn
	}

	private static func renderSVG(_ data: Data, sizes: [Int]) -> [CGImage]? {
		guard data.count <= maximumSVGBytes else { return nil }
		return svgDrawing.withLock {
			autoreleasepool {
				guard let image = NSImage(data: data), image.isValid, isVisible(image.size) else { return nil }
				var drawn: [CGImage] = []
				for pixels in sizes {
					guard let square = draw(pixels: pixels, { context, frame in
						NSGraphicsContext.saveGraphicsState()
						defer { NSGraphicsContext.restoreGraphicsState() }
						NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
						image.draw(in: fitted(image.size, in: frame), from: .zero, operation: .sourceOver, fraction: 1)
					}) else { return nil }
					drawn.append(square)
				}
				return drawn
			}
		}
	}

	/// Whether an image of `size` shows at the smallest size it's drawn at;
	/// one thinner than a pixel there would draw nothing.
	private static func isVisible(_ size: CGSize) -> Bool {
		size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0
			&& min(size.width, size.height) * CGFloat(smallPixels) >= max(size.width, size.height)
	}

	private static func draw(pixels: Int, from image: CGImage) -> CGImage? {
		draw(pixels: pixels) { context, frame in
			context.interpolationQuality = .high
			context.draw(image, in: fitted(CGSize(width: image.width, height: image.height), in: frame))
		}
	}

	private static func draw(pixels: Int, _ body: (CGContext, CGRect) -> Void) -> CGImage? {
		guard let space = CGColorSpace(name: CGColorSpace.sRGB),
			let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: space,
				bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
		else { return nil }
		body(context, CGRect(x: 0, y: 0, width: pixels, height: pixels))
		return context.makeImage()
	}

	private static func fitted(_ size: CGSize, in frame: CGRect) -> CGRect {
		let scale = min(frame.width / size.width, frame.height / size.height)
		let fitted = CGSize(width: size.width * scale, height: size.height * scale)
		return CGRect(x: frame.midX - fitted.width / 2, y: frame.midY - fitted.height / 2, width: fitted.width, height: fitted.height)
	}
}
