import AppKit
import Darwin
import UniformTypeIdentifiers

/// Opens a project's lpm.json for editing. lpm.json comes from the project,
/// so only a regular file is opened, and always in the app that edits JSON:
/// opening a link would run whatever it points to, such as a script.
/// Anything else is shown in Finder.
enum ProjectConfigOpener {
	@MainActor
	static func open(_ file: URL) {
		if opensInEditor(file), let editor = NSWorkspace.shared.urlForApplication(toOpen: .json) {
			NSWorkspace.shared.open([file], withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration())
		} else {
			NSWorkspace.shared.activateFileViewerSelecting([file])
		}
	}

	/// Whether `file` is a regular file, without following a link.
	static func opensInEditor(_ file: URL) -> Bool {
		var info = stat()
		return lstat(file.path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG
	}
}
