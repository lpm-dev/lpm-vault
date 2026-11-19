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
	/// The app last chosen to open JSON, which opens it from then on.
	static let editorDefaultsKey = "lpm-vault-json-editor"

	/// An app that opens JSON.
	struct Editor: Equatable, Identifiable {
		let url: URL
		let name: String
		var id: URL { url }
	}

	/// Opens `file` in the app last chosen for JSON, or else the Mac's default for it.
	@MainActor
	static func open(_ file: URL, within folder: URL? = nil, defaults: UserDefaults = .standard) {
		open(file, within: folder, in: editors(defaults: defaults).first?.url)
	}

	/// Opens `file` in `editor`, or shows it in Finder when it isn't a JSON file to open.
	@MainActor
	static func open(_ file: URL, within folder: URL? = nil, in editor: URL?) {
		if opensInEditor(file, within: folder), let editor {
			NSWorkspace.shared.open([file], withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration())
		} else {
			reveal(file)
		}
	}

	/// Opens `file` in `editor` and keeps `editor` as the app that opens JSON from now on.
	@MainActor
	static func open(_ file: URL, within folder: URL? = nil, choosing editor: URL, defaults: UserDefaults = .standard) {
		defaults.set(editor, forKey: editorDefaultsKey)
		open(file, within: folder, in: editor)
	}

	@MainActor
	static func reveal(_ file: URL) {
		NSWorkspace.shared.activateFileViewerSelecting([file])
	}

	/// The apps that open JSON on this Mac: the one chosen last, or else the
	/// default, first, then the others by name.
	@MainActor
	static func editors(defaults: UserDefaults = .standard) -> [Editor] {
		let workspace = NSWorkspace.shared
		return editors(
			capable: workspace.urlsForApplications(toOpen: .json),
			systemDefault: workspace.urlForApplication(toOpen: .json),
			chosen: defaults.url(forKey: editorDefaultsKey),
			bundleID: { Bundle(url: $0)?.bundleIdentifier },
			name: displayName(of:)
		)
	}

	/// `capable` in the order the menu lists them: `chosen` while it's still
	/// one of them, or else `systemDefault`, then the rest by name, each app
	/// once however many copies of it the Mac has.
	static func editors(capable: [URL], systemDefault: URL?, chosen: URL?, bundleID: (URL) -> String?, name: (URL) -> String) -> [Editor] {
		var ordered = capable.map { url in
			let url = url.standardizedFileURL
			return Editor(url: url, name: name(url))
		}
		ordered.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
		let first = [chosen, systemDefault].lazy.compactMap { $0?.standardizedFileURL }
			.compactMap { url in ordered.firstIndex { $0.url == url } }.first
		if let first { ordered.insert(ordered.remove(at: first), at: 0) }
		var seen: Set<String> = []
		return ordered.filter { seen.insert(bundleID($0.url) ?? $0.url.path).inserted }
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
