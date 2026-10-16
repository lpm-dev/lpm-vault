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

	/// The signature of the regular file at `url`, without following a link.
	static func signature(of url: URL) -> ProjectIconFileSignature? {
		var info = stat()
		let found = url.withUnsafeFileSystemRepresentation { path in
			path.map { lstat($0, &info) == 0 } ?? false
		}
		guard found, info.st_mode & S_IFMT == S_IFREG else { return nil }
		return ProjectIconFileSignature(info)
	}

	private static func read(descriptor: Int32, maximumBytes: Int) throws(Failure) -> (data: Data, signature: ProjectIconFileSignature) {
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
/// checked; nothing is searched for.
enum ProjectIconDiscovery {
	static let candidates = [
		"favicon.svg",
		"favicon.ico",
		"favicon.png",
		"public/favicon.svg",
		"public/favicon.ico",
		"public/favicon.png",
		"app/favicon.ico",
		"app/favicon.png",
		"app/icon.svg",
		"app/icon.png",
		"app/icon.ico",
		"src/favicon.ico",
		"src/favicon.svg",
		"src/app/favicon.ico",
		"src/app/icon.svg",
		"src/app/icon.png",
		"assets/icon.svg",
		"assets/icon.png",
		"assets/logo.svg",
		"assets/logo.png",
		".idea/icon.svg",
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
		guard ProjectIconPath.isSafe(path), ProjectIconPath.isImage(path) else { return [] }
		return ["public/" + path, path].filter(ProjectIconPath.isSafe)
	}

	/// The `href` of the first icon link: an HTML `<link rel="icon">`, or an
	/// object literal with `rel: "icon"`, as a root route's head lists them.
	static func iconHref(in source: String) -> String? {
		let text = source as NSString
		let whole = NSRange(location: 0, length: text.length)
		if let match = linkTag.firstMatch(in: source, range: whole), match.range(at: 1).location != NSNotFound {
			return text.substring(with: match.range(at: 1))
		}
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

	private static let linkTag = expression(#"<link\b(?=[^>]*\brel\s*=\s*["'](?:icon|shortcut icon)["'])(?=[^>]*\bhref\s*=\s*["']([^"'?#]+))[^>]*>"#)
	private static let iconRel = expression(#"\brel\s*:\s*["'](?:icon|shortcut icon)["']"#)
	private static let objectHref = expression(#"\bhref\s*:\s*["']([^"'?#]+)"#)

	private static func expression(_ pattern: String) -> NSRegularExpression {
		// The patterns are constants, so failing to compile one is a programming error.
		try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
	}
}

/// Draws icon files as small square images. Every image is checked before
/// it's decoded, since a small file can describe an enormous one.
enum ProjectIconRenderer {
	/// The most pixels an image can have to be decoded.
	static let maximumPixels = 2048 * 2048
	static let smallPixels = 32
	static let largePixels = 96

	/// The image drawn at the sidebar's size and the Project Settings page's.
	static func image(from data: Data, path: String) -> ProjectIconImage? {
		guard let small = render(data, path: path, pixels: smallPixels), let large = render(data, path: path, pixels: largePixels) else { return nil }
		return ProjectIconImage(small: small, large: large)
	}

	/// The image drawn `pixels` square, as a PNG, for keeping a copy.
	static func png(from data: Data, path: String, pixels: Int) -> Data? {
		guard let image = render(data, path: path, pixels: pixels) else { return nil }
		let output = NSMutableData()
		guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { return nil }
		CGImageDestinationAddImage(destination, image, nil)
		guard CGImageDestinationFinalize(destination) else { return nil }
		return output as Data
	}

	static func render(_ data: Data, path: String, pixels: Int) -> CGImage? {
		isSVG(data, path: path) ? renderSVG(data, pixels: pixels) : renderBitmap(data, pixels: pixels)
	}

	static func isSVG(_ data: Data, path: String) -> Bool {
		if path.lowercased().hasSuffix(".svg") { return true }
		let head = String(decoding: data.prefix(512), as: UTF8.self).drop { $0.isWhitespace || $0 == "\u{FEFF}" }
		return head.hasPrefix("<svg") || (head.hasPrefix("<?xml") && head.contains("<svg"))
	}

	private static func renderBitmap(_ data: Data, pixels: Int) -> CGImage? {
		guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
		// Icon files hold several sizes: the smallest at least as large as
		// what's drawn looks best, else the largest there is.
		var best: (index: Int, size: Int)?
		for index in 0..<min(CGImageSourceGetCount(source), 64) {
			guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
				let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
				width > 0, height > 0, width * height <= maximumPixels
			else { continue }
			let size = max(width, height)
			if let current = best {
				let better = current.size < pixels ? size > current.size : (size >= pixels && size < current.size)
				if better { best = (index, size) }
			} else {
				best = (index, size)
			}
		}
		guard let best else { return nil }
		let options: [CFString: Any] = [
			kCGImageSourceCreateThumbnailFromImageAlways: true,
			kCGImageSourceCreateThumbnailWithTransform: true,
			kCGImageSourceThumbnailMaxPixelSize: pixels,
			kCGImageSourceShouldCacheImmediately: true,
		]
		guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, best.index, options as CFDictionary) else { return nil }
		return draw(pixels: pixels) { context, frame in
			context.interpolationQuality = .high
			context.draw(thumbnail, in: fitted(CGSize(width: thumbnail.width, height: thumbnail.height), in: frame))
		}
	}

	private static func renderSVG(_ data: Data, pixels: Int) -> CGImage? {
		guard let image = NSImage(data: data), image.isValid, image.size.width > 0, image.size.height > 0 else { return nil }
		return draw(pixels: pixels) { context, frame in
			NSGraphicsContext.saveGraphicsState()
			defer { NSGraphicsContext.restoreGraphicsState() }
			NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
			image.draw(in: fitted(image.size, in: frame), from: .zero, operation: .sourceOver, fraction: 1)
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
