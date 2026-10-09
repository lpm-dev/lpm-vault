import AppKit
import Darwin
import UniformTypeIdentifiers

/// Opens a project's lpm.json, or a schema it imports, for editing. These
/// come from the project, so only a regular JSON file is opened, and always in
/// the app that edits JSON: opening a link would run whatever it points to,
/// such as a script, and another type could open in an app that runs it, such
/// as a browser. A file reached through a linked folder outside `folder` isn't
/// opened either. Anything else is shown in Finder.
enum ProjectConfigOpener {
	@MainActor
	static func open(_ file: URL, within folder: URL? = nil) {
		if opensInEditor(file, within: folder), let editor = NSWorkspace.shared.urlForApplication(toOpen: .json) {
			NSWorkspace.shared.open([file], withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration())
		} else {
			NSWorkspace.shared.activateFileViewerSelecting([file])
		}
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
