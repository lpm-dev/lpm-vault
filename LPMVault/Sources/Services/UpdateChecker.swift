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

	var currentVersion: String {
		Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
	}

	func checkForUpdate() async {
		// Check cache first
		if let cached = loadCache(), !cached.isExpired {
			latestVersion = cached.version
			updateAvailable = cached.version != currentVersion && cached.version > currentVersion
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
			let (data, response) = try await URLSession.shared.data(for: request)
			guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
				return
			}

			struct GitHubRelease: Codable {
				let tag_name: String
				let html_url: String
			}

			let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
			let version = release.tag_name.hasPrefix("v")
				? String(release.tag_name.dropFirst())
				: release.tag_name

			// Cache it
			saveCache(CachedVersion(version: version, checkedAt: Date()))

			latestVersion = version
			updateAvailable = version != currentVersion && version > currentVersion
			releaseURL = URL(string: release.html_url)
		} catch {
			// Silently fail — update check is not critical
		}
	}

	// MARK: - Cache

	private struct CachedVersion: Codable {
		let version: String
		let checkedAt: Date

		var isExpired: Bool {
			Date().timeIntervalSince(checkedAt) > 86400 // 24 hours
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
