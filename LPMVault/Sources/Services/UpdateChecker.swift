import Foundation

/// Checks GitHub Releases for a newer version of the app.
/// Caches the result for 24 hours to avoid excessive API calls.
@Observable
@MainActor
final class UpdateChecker {
	var latestVersion: String?
	var updateAvailable: Bool = false
	var releaseURL: URL?

	private let repo = "lpm-dev/lpm-vault"
	private let cacheKey = "lpm-vault-update-check"
	private let maximumResponseBytes = 1024 * 1024

	var currentVersion: String {
		Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
	}

	nonisolated static func validatedReleaseURL(_ value: String) -> URL? {
		guard let url = URL(string: value),
			url.scheme?.lowercased() == "https",
			url.host?.lowercased() == "github.com",
			url.user == nil,
			url.password == nil,
			url.port == nil || url.port == 443,
			url.path.hasPrefix("/lpm-dev/lpm-vault/releases/")
		else { return nil }
		return url
	}

	nonisolated static func isNewerVersion(_ candidate: String, than current: String) -> Bool {
		guard let candidate = NumericVersion(candidate), let current = NumericVersion(current) else {
			return false
		}
		return candidate > current
	}

	nonisolated static func cacheIsExpired(checkedAt: Date, now: Date) -> Bool {
		let age = now.timeIntervalSince(checkedAt)
		return age < 0 || age > 86_400
	}

	func checkForUpdate() async {
		// Check cache first
		if let cached = loadCache(), !cached.isExpired {
			latestVersion = cached.version
			updateAvailable = Self.isNewerVersion(cached.version, than: currentVersion)
			releaseURL = URL(string: "https://github.com/\(repo)/releases/latest")
			return
		}

		// Fetch from GitHub Releases API
		guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else {
			return
		}

		var request = URLRequest(url: url)
		request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
		request.timeoutInterval = 10

		do {
			let (data, response) = try await BoundedHTTPResponse.load(
				for: request,
				using: URLSession.shared,
				maximumBytes: maximumResponseBytes
			)
			guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
				return
			}

			struct GitHubRelease: Codable {
				let tag_name: String
				let html_url: String
			}

			let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
			guard let validatedReleaseURL = Self.validatedReleaseURL(release.html_url) else {
				return
			}
			let version = release.tag_name.hasPrefix("v")
				? String(release.tag_name.dropFirst())
				: release.tag_name

			// Cache it
			saveCache(CachedVersion(version: version, checkedAt: Date()))

			latestVersion = version
			updateAvailable = Self.isNewerVersion(version, than: currentVersion)
			releaseURL = validatedReleaseURL
		} catch {
			// Silently fail — update check is not critical
		}
	}

	// MARK: - Cache

	private struct CachedVersion: Codable {
		let version: String
		let checkedAt: Date

		var isExpired: Bool {
			UpdateChecker.cacheIsExpired(checkedAt: checkedAt, now: Date())
		}
	}

	private func loadCache() -> CachedVersion? {
		guard let data = UserDefaults.standard.data(forKey: cacheKey) else { return nil }
		return try? JSONDecoder().decode(CachedVersion.self, from: data)
	}

	private func saveCache(_ cache: CachedVersion) {
		guard let data = try? JSONEncoder().encode(cache) else { return }
		UserDefaults.standard.set(data, forKey: cacheKey)
	}
}

private struct NumericVersion: Comparable {
	private let components: [Int]

	init?(_ value: String) {
		let fields = value.split(separator: ".", omittingEmptySubsequences: false)
		guard (2...3).contains(fields.count),
			fields.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
			fields.allSatisfy({ Int($0) != nil })
		else { return nil }
		var components = fields.compactMap { Int($0) }
		while components.count < 3 { components.append(0) }
		self.components = components
	}

	static func < (lhs: Self, rhs: Self) -> Bool {
		lhs.components.lexicographicallyPrecedes(rhs.components)
	}
}
