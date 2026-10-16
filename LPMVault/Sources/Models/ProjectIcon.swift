import CoreGraphics
import Darwin
import Foundation
import SwiftUI

/// The colors a symbol or monogram project icon can sit on.
enum ProjectIconColor: String, CaseIterable, Codable, Identifiable, Sendable {
	case gray, red, orange, yellow, lime, green, mint, teal, cyan, blue, indigo, purple, pink, brown

	var id: String { rawValue }

	var title: String { rawValue.capitalized }

	var color: Color {
		switch self {
		case .gray: Color(hex: 0x8E8E93)
		case .red: Color(hex: 0xFF3B30)
		case .orange: Color(hex: 0xFF9F0A)
		case .yellow: Color(hex: 0xFFD60A)
		case .lime: Color(hex: 0xA4D82A)
		case .green: Color(hex: 0x34C759)
		case .mint: Color(hex: 0x00C7BE)
		case .teal: Color(hex: 0x30B0C7)
		case .cyan: Color(hex: 0x32ADE6)
		case .blue: Color(hex: 0x0A84FF)
		case .indigo: Color(hex: 0x5E5CE6)
		case .purple: Color(hex: 0xAF52DE)
		case .pink: Color(hex: 0xFF2D55)
		case .brown: Color(hex: 0xA2845E)
		}
	}
}

/// How a project's icon is chosen. Anything but `automatic` replaces the
/// icon found in the project folder.
enum ProjectIconChoice: Equatable, Hashable, Sendable {
	case automatic
	case symbol(String, ProjectIconColor)
	case emoji(String)
	case monogram(String, ProjectIconColor)
	/// An image in the project folder, by its path there, so it follows the file.
	case projectFile(String)
	/// A chosen image from outside the project folder, copied into LPM Vault's
	/// own folder as `file`; `name` is the chosen file's name.
	case storedImage(file: String, name: String)

	static let maximumMonogramLength = 2

	var isAutomatic: Bool { self == .automatic }

	/// Whether every value in it is one LPM Vault could have saved.
	var isValid: Bool {
		switch self {
		case .automatic: true
		case .symbol(let name, _): ProjectIconCatalog.symbolNames.contains(name)
		case .emoji(let emoji): Self.isEmoji(emoji)
		case .monogram(let letters, _): Self.normalizedMonogram(letters) == letters
		case .projectFile(let path): ProjectIconPath.isSafe(path) && ProjectIconPath.isImage(path)
		case .storedImage(let file, let name): ProjectIconStore.isStoredImageName(file) && !name.isEmpty && name.utf8.count <= 255
		}
	}

	/// A single emoji, as one character that shows as an emoji.
	static func isEmoji(_ text: String) -> Bool {
		guard text.count == 1, text.utf8.count <= 64, let character = text.first else { return false }
		let scalars = character.unicodeScalars
		guard let first = scalars.first else { return false }
		return first.properties.isEmojiPresentation
			|| (first.properties.isEmoji && scalars.count > 1)
	}

	/// One or two letters or digits, as typed, or nil when there are none.
	static func normalizedMonogram(_ text: String) -> String? {
		let characters = text.filter { $0.isLetter || $0.isNumber }
		guard !characters.isEmpty else { return nil }
		return String(characters.prefix(maximumMonogramLength)).uppercased()
	}

	/// The monogram a project's name suggests: the first letters of its first
	/// two words, or the first two of a single word.
	static func suggestedMonogram(for name: String) -> String {
		let words = name.split { !($0.isLetter || $0.isNumber) }
		let letters = words.count >= 2 ? String(words[0].prefix(1) + words[1].prefix(1)) : String(words.first?.prefix(2) ?? "")
		return normalizedMonogram(letters) ?? "P"
	}
}

extension ProjectIconChoice: Codable {
	private enum CodingKeys: String, CodingKey {
		case kind, symbol, color, emoji, letters, path, file, name
	}

	private enum Kind: String, Codable {
		case symbol, emoji, monogram, projectFile, storedImage
	}

	init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		switch try container.decode(Kind.self, forKey: .kind) {
		case .symbol:
			self = .symbol(try container.decode(String.self, forKey: .symbol), try container.decode(ProjectIconColor.self, forKey: .color))
		case .emoji:
			self = .emoji(try container.decode(String.self, forKey: .emoji))
		case .monogram:
			self = .monogram(try container.decode(String.self, forKey: .letters), try container.decode(ProjectIconColor.self, forKey: .color))
		case .projectFile:
			self = .projectFile(try container.decode(String.self, forKey: .path))
		case .storedImage:
			self = .storedImage(file: try container.decode(String.self, forKey: .file), name: try container.decode(String.self, forKey: .name))
		}
	}

	func encode(to encoder: Encoder) throws {
		var container = encoder.container(keyedBy: CodingKeys.self)
		switch self {
		case .automatic:
			throw EncodingError.invalidValue(self, .init(codingPath: [], debugDescription: "An automatic icon isn't stored"))
		case .symbol(let name, let color):
			try container.encode(Kind.symbol, forKey: .kind)
			try container.encode(name, forKey: .symbol)
			try container.encode(color, forKey: .color)
		case .emoji(let emoji):
			try container.encode(Kind.emoji, forKey: .kind)
			try container.encode(emoji, forKey: .emoji)
		case .monogram(let letters, let color):
			try container.encode(Kind.monogram, forKey: .kind)
			try container.encode(letters, forKey: .letters)
			try container.encode(color, forKey: .color)
		case .projectFile(let path):
			try container.encode(Kind.projectFile, forKey: .kind)
			try container.encode(path, forKey: .path)
		case .storedImage(let file, let name):
			try container.encode(Kind.storedImage, forKey: .kind)
			try container.encode(file, forKey: .file)
			try container.encode(name, forKey: .name)
		}
	}
}

/// A decoded icon image, ready to draw at the sidebar's size and at the
/// Project Settings page's. Immutable once made.
final class ProjectIconImage: @unchecked Sendable, Equatable {
	let small: CGImage
	let large: CGImage

	init(small: CGImage, large: CGImage) {
		self.small = small
		self.large = large
	}

	func image(for points: CGFloat) -> CGImage {
		points <= CGFloat(ProjectIconRenderer.smallPixels) / 2 ? small : large
	}

	static func == (lhs: ProjectIconImage, rhs: ProjectIconImage) -> Bool { lhs === rhs }
}

/// What a project icon looks like.
enum ProjectIconAppearance: Equatable {
	case image(ProjectIconImage)
	case symbol(String, ProjectIconColor)
	case emoji(String)
	case monogram(String, ProjectIconColor)
	case folder
}

/// Where a project's automatic icon came from.
enum ProjectIconDetection: Equatable, Sendable {
	case searching
	/// An image at this path in the project folder.
	case found(String)
	case notFound
	case folderMissing
}

/// Paths of icon files in a project folder.
enum ProjectIconPath {
	static let maximumComponents = 16
	static let maximumLength = 1024
	static let imageExtensions: Set<String> = ["svg", "ico", "png", "icns", "jpg", "jpeg", "gif", "webp", "tif", "tiff", "bmp", "heic"]

	/// A relative path that stays in the folder: no empty, `.` or `..`
	/// component, nothing absolute, and nothing unprintable.
	static func isSafe(_ path: String) -> Bool {
		guard !path.isEmpty, path.utf8.count <= maximumLength, !path.hasPrefix("/"),
			!path.unicodeScalars.contains(where: { $0.properties.generalCategory == .control })
		else { return false }
		let components = path.split(separator: "/", omittingEmptySubsequences: false)
		return components.count <= maximumComponents && components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
	}

	static func isImage(_ path: String) -> Bool {
		guard let dot = path.lastIndex(of: "."), path[dot...].count > 1 else { return false }
		return imageExtensions.contains(path[path.index(after: dot)...].lowercased())
	}

	/// An existing file's path in `folder`, both resolved through any links,
	/// or nil when it isn't inside the folder.
	static func relativePath(of file: URL, in folder: String) -> String? {
		guard let root = realPath(folder), let target = realPath(file.path) else { return nil }
		let prefix = root.hasSuffix("/") ? root : root + "/"
		guard target.hasPrefix(prefix) else { return nil }
		let relative = String(target.dropFirst(prefix.count))
		return isSafe(relative) ? relative : nil
	}

	private static func realPath(_ path: String) -> String? {
		guard let resolved = realpath(path, nil) else { return nil }
		defer { free(resolved) }
		return String(cString: resolved)
	}
}
