import Foundation

/// URLs for a platform's API, built so a name in a path can't change where the request goes.
enum PlatformURL {
	/// The characters a path segment keeps as they are; everything else is
	/// percent-escaped, so a name can't add a segment or a query.
	private static let segmentCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

	/// The URL for `path` under `baseURL`, each segment escaped on its own;
	/// nil for an empty path, or a segment that's empty, `.` or `..`.
	static func url(_ baseURL: URL, _ path: [String], query: [URLQueryItem] = []) -> URL? {
		guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false), !path.isEmpty else { return nil }
		var segments: [String] = []
		segments.reserveCapacity(path.count)
		for segment in path {
			guard !segment.isEmpty, segment != ".", segment != "..",
				let escaped = segment.addingPercentEncoding(withAllowedCharacters: segmentCharacters)
			else { return nil }
			segments.append(escaped)
		}
		components.percentEncodedPath = components.percentEncodedPath.trimmingSuffix("/") + "/" + segments.joined(separator: "/")
		components.queryItems = query.isEmpty ? nil : query
		components.fragment = nil
		return components.url
	}
}

private extension String {
	func trimmingSuffix(_ suffix: Character) -> String {
		var trimmed = Substring(self)
		while trimmed.last == suffix { trimmed = trimmed.dropLast() }
		return String(trimmed)
	}
}
