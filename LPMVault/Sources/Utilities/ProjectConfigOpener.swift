import AppKit
import Darwin
import UniformTypeIdentifiers

/// Opens a project's lpm.json, or a schema it imports, for editing. These
/// come from the project, so only a regular JSON file is opened, and only in
/// an app that opens JSON: opening a link would run whatever it points to,
/// such as a script, and another type could open in an app that runs it, such
/// as a browser. A file reached through a linked folder outside `folder` isn't
/// opened either. Anything else is shown in Finder.
enum ProjectConfigOpener {
	/// The path of the app last chosen to open JSON, which opens it from then on.
	static let editorDefaultsKey = "lpm-vault-json-editor"

	/// An app that opens JSON.
	struct Editor: Equatable, Identifiable {
		let url: URL
		let name: String
		/// Its version, where another app the menu lists has the same name.
		var version: String?
		var id: URL { url }
	}

	/// Opens `file` in an app, as NSWorkspace does; tests watch it instead.
	typealias Launch = @MainActor (_ file: URL, _ app: URL) -> Void

	@MainActor
	static func launch(_ file: URL, in app: URL) {
		NSWorkspace.shared.open([file], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
	}

	/// Opens `file` in the app last chosen for JSON, or else the Mac's default for it.
	@MainActor
	static func open(_ file: URL, within folder: URL? = nil, defaults: UserDefaults = .standard) {
		let workspace = NSWorkspace.shared
		let editor = preferredEditor(capable: workspace.urlsForApplications(toOpen: .json), systemDefault: workspace.urlForApplication(toOpen: .json),
			chosen: defaults.string(forKey: editorDefaultsKey))
		open(file, within: folder, in: editor)
	}

	/// Opens `file` in `editor`, or shows it in Finder when it isn't a JSON file to open.
	@MainActor
	static func open(_ file: URL, within folder: URL? = nil, in editor: URL?, launch: Launch = launch(_:in:)) {
		if opensInEditor(file, within: folder), let editor {
			launch(file, editor)
		} else {
			reveal(file)
		}
	}

	/// Opens `file` in `editor` and keeps `editor` as the app that opens JSON from now on.
	@MainActor
	static func open(_ file: URL, within folder: URL? = nil, choosing editor: URL, defaults: UserDefaults = .standard, launch: Launch = launch(_:in:)) {
		defaults.set(path(of: editor), forKey: editorDefaultsKey)
		open(file, within: folder, in: editor, launch: launch)
	}

	@MainActor
	static func reveal(_ file: URL) {
		NSWorkspace.shared.activateFileViewerSelecting([file])
	}

	/// The app that opens JSON: the one chosen last, while it still can, or
	/// else the Mac's default. Apps are compared by path, so a folder's
	/// trailing slash, which LaunchServices adds and a saved path drops,
	/// doesn't matter.
	static func preferredEditor(capable: [URL], systemDefault: URL?, chosen: String?) -> URL? {
		guard let chosen else { return systemDefault }
		let wanted = path(of: URL(fileURLWithPath: chosen))
		return capable.first { path(of: $0) == wanted } ?? systemDefault
	}

	/// The apps that open JSON on this Mac, for the menu: the one chosen last,
	/// or else the default, first, then the rest by name.
	@MainActor
	static func editors(defaults: UserDefaults = .standard) -> [Editor] {
		let workspace = NSWorkspace.shared
		return editors(
			capable: workspace.urlsForApplications(toOpen: .json),
			systemDefault: workspace.urlForApplication(toOpen: .json),
			chosen: defaults.string(forKey: editorDefaultsKey),
			name: displayName(of:),
			version: { Bundle(url: $0)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String }
		)
	}

	/// `capable` in the order the menu lists them: the preferred app first,
	/// then the rest by name. An app listed twice at one path is listed once;
	/// apps at different paths that share a name, as two copies of one app
	/// do, each say their version.
	static func editors(capable: [URL], systemDefault: URL?, chosen: String?, name: (URL) -> String, version: (URL) -> String?) -> [Editor] {
		var seen: Set<String> = []
		var ordered = capable.compactMap { url -> Editor? in
			guard seen.insert(path(of: url)).inserted else { return nil }
			return Editor(url: url, name: name(url))
		}
		ordered.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
		if let first = preferredEditor(capable: ordered.map(\.url), systemDefault: systemDefault, chosen: chosen).map(path(of:)),
			let index = ordered.firstIndex(where: { path(of: $0.url) == first })
		{
			ordered.insert(ordered.remove(at: index), at: 0)
		}
		let counts = Dictionary(ordered.map { ($0.name, 1) }, uniquingKeysWith: +)
		for index in ordered.indices where counts[ordered[index].name, default: 0] > 1 {
			ordered[index].version = version(ordered[index].url)
		}
		return ordered
	}

	/// An app's path, standardized and without a trailing slash, which names it.
	private static func path(of app: URL) -> String {
		app.standardizedFileURL.path
	}

	/// An app's name as Finder shows it, without ".app".
	static func displayName(of app: URL) -> String {
		let name = FileManager.default.displayName(atPath: app.path)
		return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
	}

	/// Whether `file` is a regular `.json` file, without following a link,
	/// whose real path is inside `folder`'s.
	static func opensInEditor(_ file: URL, within folder: URL? = nil) -> Bool {
		var info = stat()
		guard file.pathExtension.lowercased() == "json", lstat(file.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return false }
		guard let folder else { return true }
		guard let resolvedFile = realPath(file.path), let resolvedFolder = realPath(folder.path) else { return false }
		return resolvedFile.hasPrefix(resolvedFolder.hasSuffix("/") ? resolvedFolder : resolvedFolder + "/")
	}

	private static func realPath(_ path: String) -> String? {
		guard let resolved = realpath(path, nil) else { return nil }
		defer { free(resolved) }
		return String(cString: resolved)
	}
}
