import Darwin
import Foundation

/// The process's descriptors open on `path` or anything below it, which
/// other tests running at the same time don't change.
func openDescriptors(at path: String) -> Int {
	guard let resolved = realpath(path, nil) else { return 0 }
	let root = String(cString: resolved)
	free(resolved)
	let entries = (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd")) ?? []
	var buffer = [UInt8](repeating: 0, count: Int(MAXPATHLEN))
	return entries.lazy.compactMap(Int32.init).filter { descriptor in
		guard fcntl(descriptor, F_GETPATH, &buffer) != -1 else { return false }
		let path = String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
		return path == root || path.hasPrefix(root + "/")
	}.count
}
