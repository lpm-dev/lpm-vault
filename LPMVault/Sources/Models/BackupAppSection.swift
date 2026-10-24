import Foundation

/// LPM Vault's own part of a backup, its payload's `app` object: settings,
/// project icons and publish destinations, beside the projects the CLI reads
/// too. The CLI checks it only as JSON, so this reads it strictly, refusing
/// anything it doesn't know, as the format asks of the app that owns it.
struct BackupAppSection: Equatable, Sendable {
	static let version = 1
	/// The format's own limit on projects, so nothing keyed by project passes it.
	static let maximumProjects = 10_000
	/// More than a 128-pixel PNG takes, which is what icons are kept as.
	static let maximumIconBytes = 256 * 1024
	/// More environments than a vault holds: each takes at least `"x":{}` of
	/// the credential store's 100 KiB.
	static let maximumEnvironments = 100 * 1024 / #""x":{}"#.utf8.count

	struct Settings: Equatable, Sendable {
		var appearance: VaultAppearance
		var keySort: VaultKeySortOrder
		var quitShortcut: VaultQuitShortcut
		var updateChannel: VaultReleaseChannel
		/// The sidebar's order, by vault ID.
		var projectOrder: [String]
		/// Each project's order of its environments, by vault ID.
		var environmentOrders: [String: [String]]
	}

	enum Icon: Equatable, Sendable {
		/// A symbol, emoji, monogram or image in the project's folder.
		case choice(ProjectIconChoice)
		/// An image copied into LPM Vault's folder: the chosen file's name, and
		/// the PNG it was kept as.
		case image(name: String, png: Data)
	}

	enum DecodingError: Error, Equatable, Sendable {
		case unreadable
		/// A newer LPM Vault wrote it.
		case newerVersion
	}

	var settings: Settings?
	/// Each project's chosen icon, by vault ID; a backup has them only with its settings.
	var icons: [String: Icon] = [:]
	/// Each project's publish destinations, by vault ID; none is empty.
	var destinations: [String: [PublishDestination]] = [:]

	init(settings: Settings?, icons: [String: Icon] = [:], destinations: [String: [PublishDestination]] = [:]) {
		self.settings = settings
		self.icons = icons
		self.destinations = destinations
	}

	/// The section as a backup writes it, or nil when reading it back would
	/// refuse it.
	func json() -> LPMConfigJSON? {
		var members: [LPMConfigJSON.Member] = [.init(key: "version", value: .number(String(Self.version)))]
		if let settings {
			guard let json = Self.json(settings) else { return nil }
			members.append(.init(key: "settings", value: json))
		}
		if !icons.isEmpty {
			guard settings != nil, icons.count <= Self.maximumProjects else { return nil }
			var entries: [LPMConfigJSON.Member] = []
			for (vaultId, icon) in icons.sorted(by: { $0.key < $1.key }) {
				guard EnvValidation.isSafeVaultId(vaultId), let json = Self.json(icon) else { return nil }
				entries.append(.init(key: vaultId, value: json))
			}
			members.append(.init(key: "icons", value: .object(entries)))
		}
		if !destinations.isEmpty {
			guard destinations.count <= Self.maximumProjects else { return nil }
			var entries: [LPMConfigJSON.Member] = []
			for (vaultId, destinations) in destinations.sorted(by: { $0.key < $1.key }) {
				guard EnvValidation.isSafeVaultId(vaultId), !destinations.isEmpty,
					let record = PublishingRecords.record(destinations, vaultID: vaultId)
				else { return nil }
				entries.append(.init(key: vaultId, value: record))
			}
			members.append(.init(key: "destinations", value: .object(entries)))
		}
		return .object(members)
	}

	init(json: LPMConfigJSON) throws(DecodingError) {
		guard case .number(let raw)? = json["version"], !raw.isEmpty, raw.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 })
		else { throw .unreadable }
		guard let version = Int(raw), version <= Self.version else { throw .newerVersion }
		guard version == Self.version, String(version) == raw else { throw .unreadable }
		let fields = try Fields(json, required: ["version"], optional: ["settings", "icons", "destinations"])
		settings = try fields.optional("settings").map(Self.settings)
		icons = [:]
		if let json = fields.optional("icons") {
			guard settings != nil else { throw .unreadable }
			for (vaultId, icon) in try Self.entries(json) {
				icons[vaultId] = try Self.icon(icon)
			}
		}
		destinations = [:]
		if let json = fields.optional("destinations") {
			for (vaultId, record) in try Self.entries(json) {
				guard case .success(let list) = PublishingRecords.decodeDestinations(record, vaultID: vaultId), !list.isEmpty
				else { throw .unreadable }
				destinations[vaultId] = list
			}
		}
	}

	// MARK: - Settings

	private static func json(_ settings: Settings) -> LPMConfigJSON? {
		guard settings.projectOrder.count <= maximumProjects, settings.environmentOrders.count <= maximumProjects,
			Set(settings.projectOrder).count == settings.projectOrder.count,
			settings.projectOrder.allSatisfy(EnvValidation.isSafeVaultId)
		else { return nil }
		var orders: [LPMConfigJSON.Member] = []
		for (vaultId, order) in settings.environmentOrders.sorted(by: { $0.key < $1.key }) {
			guard EnvValidation.isSafeVaultId(vaultId), isEnvironmentOrder(order) else { return nil }
			orders.append(.init(key: vaultId, value: .array(order.map(LPMConfigJSON.string))))
		}
		return .object([
			.init(key: "appearance", value: .string(settings.appearance.rawValue)),
			.init(key: "keySort", value: .string(settings.keySort.rawValue)),
			.init(key: "quitShortcut", value: .string(settings.quitShortcut.rawValue)),
			.init(key: "updateChannel", value: .string(settings.updateChannel.rawValue)),
			.init(key: "projectOrder", value: .array(settings.projectOrder.map(LPMConfigJSON.string))),
			.init(key: "environmentOrders", value: .object(orders)),
		])
	}

	private static func settings(_ json: LPMConfigJSON) throws(DecodingError) -> Settings {
		let fields = try Fields(json, required: ["appearance", "keySort", "quitShortcut", "updateChannel", "projectOrder", "environmentOrders"])
		guard let appearance = VaultAppearance(rawValue: try fields.string("appearance")),
			let keySort = VaultKeySortOrder(rawValue: try fields.string("keySort")),
			let quitShortcut = VaultQuitShortcut(rawValue: try fields.string("quitShortcut")),
			let updateChannel = VaultReleaseChannel(rawValue: try fields.string("updateChannel"))
		else { throw .unreadable }
		let projectOrder = try strings(fields.value("projectOrder"))
		guard projectOrder.count <= maximumProjects, Set(projectOrder).count == projectOrder.count,
			projectOrder.allSatisfy(EnvValidation.isSafeVaultId)
		else { throw .unreadable }
		var environmentOrders: [String: [String]] = [:]
		for (vaultId, order) in try entries(fields.value("environmentOrders")) {
			let names = try strings(order)
			guard isEnvironmentOrder(names) else { throw .unreadable }
			environmentOrders[vaultId] = names
		}
		return Settings(
			appearance: appearance, keySort: keySort, quitShortcut: quitShortcut, updateChannel: updateChannel,
			projectOrder: projectOrder, environmentOrders: environmentOrders)
	}

	/// Environment names, each once, no more than a project can have.
	private static func isEnvironmentOrder(_ names: [String]) -> Bool {
		names.count <= maximumEnvironments && Set(names).count == names.count
			&& names.allSatisfy(EnvValidation.isValidEnvironmentName)
	}

	// MARK: - Icons

	private static func json(_ icon: Icon) -> LPMConfigJSON? {
		switch icon {
		case .choice(let choice):
			guard choice.isValid else { return nil }
			switch choice {
			case .symbol(let name, let color):
				return .object([
					.init(key: "kind", value: .string("symbol")), .init(key: "name", value: .string(name)),
					.init(key: "color", value: .string(color.rawValue)),
				])
			case .emoji(let emoji):
				return .object([.init(key: "kind", value: .string("emoji")), .init(key: "emoji", value: .string(emoji))])
			case .monogram(let letters, let color):
				return .object([
					.init(key: "kind", value: .string("monogram")), .init(key: "letters", value: .string(letters)),
					.init(key: "color", value: .string(color.rawValue)),
				])
			case .projectFile(let path):
				return .object([.init(key: "kind", value: .string("projectFile")), .init(key: "path", value: .string(path))])
			case .automatic, .storedImage:
				return nil
			}
		case .image(let name, let png):
			guard isImageName(name), !png.isEmpty, png.count <= maximumIconBytes else { return nil }
			return .object([
				.init(key: "kind", value: .string("image")), .init(key: "name", value: .string(name)),
				.init(key: "png", value: .string(png.base64EncodedString())),
			])
		}
	}

	private static func icon(_ json: LPMConfigJSON) throws(DecodingError) -> Icon {
		guard case .string(let kind)? = json["kind"] else { throw .unreadable }
		let choice: ProjectIconChoice
		switch kind {
		case "symbol":
			let fields = try Fields(json, required: ["kind", "name", "color"])
			guard let color = ProjectIconColor(rawValue: try fields.string("color")) else { throw .unreadable }
			choice = .symbol(try fields.string("name"), color)
		case "emoji":
			choice = .emoji(try Fields(json, required: ["kind", "emoji"]).string("emoji"))
		case "monogram":
			let fields = try Fields(json, required: ["kind", "letters", "color"])
			guard let color = ProjectIconColor(rawValue: try fields.string("color")) else { throw .unreadable }
			choice = .monogram(try fields.string("letters"), color)
		case "projectFile":
			choice = .projectFile(try Fields(json, required: ["kind", "path"]).string("path"))
		case "image":
			let fields = try Fields(json, required: ["kind", "name", "png"])
			let name = try fields.string("name")
			let encoded = try fields.string("png")
			guard isImageName(name), encoded.utf8.count <= (maximumIconBytes + 2) / 3 * 4,
				let png = Data(base64Encoded: encoded), !png.isEmpty, png.count <= maximumIconBytes,
				png.base64EncodedString() == encoded
			else { throw .unreadable }
			return .image(name: name, png: png)
		default:
			throw .unreadable
		}
		guard choice.isValid else { throw .unreadable }
		return .choice(choice)
	}

	/// A copied image's name, as icon choices keep it.
	private static func isImageName(_ name: String) -> Bool {
		!name.isEmpty && name.utf8.count <= ProjectIconStore.maximumImageNameBytes
	}

	// MARK: - Reading

	/// An object's members by vault ID, each a safe ID, at most one per project.
	private static func entries(_ json: LPMConfigJSON) throws(DecodingError) -> [(String, LPMConfigJSON)] {
		guard case .object(let members) = json, members.count <= maximumProjects else { throw .unreadable }
		var seen = Set<String>()
		var entries: [(String, LPMConfigJSON)] = []
		entries.reserveCapacity(members.count)
		for member in members {
			guard EnvValidation.isSafeVaultId(member.key), seen.insert(member.key).inserted else { throw .unreadable }
			entries.append((member.key, member.value))
		}
		return entries
	}

	private static func strings(_ json: LPMConfigJSON) throws(DecodingError) -> [String] {
		guard case .array(let items) = json, items.count <= maximumProjects else { throw .unreadable }
		var strings: [String] = []
		strings.reserveCapacity(items.count)
		for item in items {
			guard case .string(let text) = item else { throw .unreadable }
			strings.append(text)
		}
		return strings
	}

	/// An object's members, when it has every required one and no others.
	/// Names are compared byte for byte, as the parser checks for duplicates.
	private struct Fields {
		private let values: [Data: LPMConfigJSON]

		init(_ json: LPMConfigJSON, required: Set<String>, optional: Set<String> = []) throws(DecodingError) {
			guard case .object(let members) = json else { throw .unreadable }
			let allowed = Set(required.union(optional).map { Data($0.utf8) })
			var values: [Data: LPMConfigJSON] = [:]
			for member in members {
				let name = Data(member.key.utf8)
				guard allowed.contains(name), values.updateValue(member.value, forKey: name) == nil else { throw .unreadable }
			}
			guard required.allSatisfy({ values[Data($0.utf8)] != nil }) else { throw .unreadable }
			self.values = values
		}

		func value(_ key: String) throws(DecodingError) -> LPMConfigJSON {
			guard let value = values[Data(key.utf8)] else { throw .unreadable }
			return value
		}

		func optional(_ key: String) -> LPMConfigJSON? {
			values[Data(key.utf8)]
		}

		func string(_ key: String) throws(DecodingError) -> String {
			guard case .string(let text) = try value(key) else { throw .unreadable }
			return text
		}
	}
}
