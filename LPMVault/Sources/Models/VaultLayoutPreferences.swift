import Foundation
import Observation

/// The workspace's layout as a person sets it: the sidebar's and the
/// inspector's widths, whether they chose to show or hide the sidebar, and
/// each project's table column widths. The store keeps it, so a lock doesn't
/// lose it; with `defaults` it's saved there too, so the next launch starts
/// as this one left off. Without them, as in a test, it lasts as long as its store.
@MainActor
@Observable
final class VaultLayoutPreferences {
	static let sidebarWidthKey = "lpm-vault-sidebar-width"
	static let inspectorWidthKey = "lpm-vault-inspector-width"
	static let sidebarShownKey = "lpm-vault-sidebar-shown"
	/// Followed by a project's vault ID.
	static let columnWidthsPrefix = "lpm-vault-column-widths."

	@ObservationIgnored private let defaults: UserDefaults?

	var sidebarWidth: CGFloat {
		didSet { if sidebarWidth != oldValue { defaults?.set(Double(sidebarWidth), forKey: Self.sidebarWidthKey) } }
	}

	var inspectorWidth: CGFloat {
		didSet { if inspectorWidth != oldValue { defaults?.set(Double(inspectorWidth), forKey: Self.inspectorWidthKey) } }
	}

	/// Whether the person chose to show or hide the sidebar; nil follows the window's width.
	var sidebarChoice: Bool? {
		didSet {
			guard sidebarChoice != oldValue else { return }
			if let sidebarChoice { defaults?.set(sidebarChoice, forKey: Self.sidebarShownKey) } else { defaults?.removeObject(forKey: Self.sidebarShownKey) }
		}
	}

	private var columnWidths: [String: VaultProjectTableColumnWidths]

	init(defaults: UserDefaults? = nil) {
		self.defaults = defaults
		func width(_ key: String, or fallback: CGFloat) -> CGFloat {
			guard let saved = defaults?.object(forKey: key) as? Double, saved.isFinite, saved > 0 else { return fallback }
			return CGFloat(saved)
		}
		sidebarWidth = width(Self.sidebarWidthKey, or: VaultMetrics.sidebar)
		inspectorWidth = width(Self.inspectorWidthKey, or: VaultMetrics.inspector)
		sidebarChoice = defaults?.object(forKey: Self.sidebarShownKey) as? Bool
		var columnWidths: [String: VaultProjectTableColumnWidths] = [:]
		for (key, value) in defaults?.dictionaryRepresentation() ?? [:] where key.hasPrefix(Self.columnWidthsPrefix) {
			guard let data = value as? Data, let widths = try? JSONDecoder().decode(VaultProjectTableColumnWidths.self, from: data) else { continue }
			columnWidths[String(key.dropFirst(Self.columnWidthsPrefix.count))] = widths
		}
		self.columnWidths = columnWidths
	}

	/// The column widths a person chose in a project's tables; none until they resize one.
	func columnWidths(for projectID: String) -> VaultProjectTableColumnWidths {
		columnWidths[projectID] ?? VaultProjectTableColumnWidths()
	}

	func setColumnWidths(_ widths: VaultProjectTableColumnWidths, for projectID: String) {
		guard columnWidths[projectID] != widths else { return }
		columnWidths[projectID] = widths
		guard let defaults else { return }
		if let data = try? JSONEncoder().encode(widths) {
			defaults.set(data, forKey: Self.columnWidthsPrefix + projectID)
		}
	}

	/// Forgets a project's column widths, as when it leaves this Mac.
	func forget(_ projectID: String) {
		columnWidths.removeValue(forKey: projectID)
		defaults?.removeObject(forKey: Self.columnWidthsPrefix + projectID)
	}

	/// Forgets the column widths of every project but `projectIDs`.
	func forget(keeping projectIDs: Set<String>) {
		for projectID in columnWidths.keys where !projectIDs.contains(projectID) {
			forget(projectID)
		}
		guard let defaults else { return }
		for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(Self.columnWidthsPrefix) {
			if !projectIDs.contains(String(key.dropFirst(Self.columnWidthsPrefix.count))) { defaults.removeObject(forKey: key) }
		}
	}
}
