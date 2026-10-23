import Foundation
import Testing

@testable import LPMVault

@Suite("Backup format")
struct BackupFormatTests {
	private static let strong = "harbor velvet ninety cactus orbit maple"
	private static let vault = "550e8400-e29b-41d4-a716-446655440000"

	private func payload(
		projects: [BackupPayload.Project],
		deviceName: String? = "Studio",
		app: BackupAppSection? = nil
	) -> BackupPayload {
		BackupPayload(
			createdAt: Date(timeIntervalSince1970: 1_761_171_075),
			producerVersion: "1.0.2",
			deviceName: deviceName,
			projects: projects,
			app: app)
	}

	private func project(
		_ vaultId: String = vault,
		name: String = "demo-api",
		folder: String? = "/Users/me/Developer/demo-api",
		hidden: Bool = false,
		cliAccess: VaultCliAccess = .requireApproval,
		environments: [String: [String: String]] = ["default": ["DATABASE_URL": "postgres://db/app"]],
		sync: BackupPayload.Sync? = nil
	) -> BackupPayload.Project {
		.init(vaultId: vaultId, name: name, folder: folder, hidden: hidden, cliAccess: cliAccess, environments: environments, sync: sync)
	}

	private func text(_ bytes: SecretBytes) -> String {
		bytes.withUnsafeBytes { String(decoding: $0, as: UTF8.self) }
	}

	private func text(_ encoded: BackupPayload.Encoded) -> String {
		text(encoded.bytes)
	}

	@Test("a payload is written as the format spells it, each object's keys sorted, absent fields left out")
	func payloadSpelling() throws {
		let personal = BackupPayload.Sync(registry: "https://lpm.dev", principalId: "usr_1", scope: .personal)
		let organization = BackupPayload.Sync(registry: "https://lpm.dev", principalId: "usr_1", scope: .organization(slug: "acme"))
		let written = try #require(payload(projects: [
			project(environments: ["staging": ["B": "2", "A": "1"], "default": [:]], sync: personal),
			project("team-vault", name: "team-vault", folder: nil, hidden: true, cliAccess: .automatic, environments: ["default": [:]], sync: organization),
		], deviceName: nil).encoded())
		#expect(text(written) == #"""
			{"createdAt":1761171075,"producer":{"name":"LPM Vault","version":"1.0.2"},"projects":[{"vaultId":"550e8400-e29b-41d4-a716-446655440000","name":"demo-api","folder":"/Users/me/Developer/demo-api","hidden":false,"cliAccess":"requireApproval","environments":{"default":{},"staging":{"A":"1","B":"2"}},"sync":{"registry":"https://lpm.dev","scope":"personal","principalId":"usr_1"}},{"vaultId":"team-vault","name":"team-vault","hidden":true,"cliAccess":"automatic","environments":{"default":{}},"sync":{"registry":"https://lpm.dev","scope":"organization","principalId":"usr_1","orgSlug":"acme"}}]}
			"""#)
	}

	@Test("strings are escaped as JSON requires and otherwise kept byte for byte")
	func payloadEscaping() throws {
		let value = "quote \" backslash \\ newline \n tab \t bell \u{07} nul \u{0} emoji 🚀 isolate \u{2066}x\u{2069}"
		let written = try #require(payload(projects: [project(environments: ["default": ["TOKEN": value]])]).encoded())
		let json = try LPMConfigJSON(parsing: written.bytes.withUnsafeBytes { Data($0) }, rejectDuplicateKeys: true)
		guard case .array(let projects)? = json["projects"], let first = projects.first,
			case .string(let decoded)? = first["environments"]?["default"]?["TOKEN"]
		else { Issue.record("the value isn't where the format puts it"); return }
		#expect(decoded == value)
		#expect(text(written).contains(#"bell \u0007 nul \u0000 emoji 🚀"#))
	}

	@Test("labels refuse controls and direction controls, as the engine does")
	func labels() {
		#expect(BackupPayload.isLabel("Studio", maximumBytes: 256))
		#expect(BackupPayload.isLabel("Tolga’s MacBook Pro", maximumBytes: 256))
		for label in ["", "tab\there", "rtl\u{202E}gnp", "mark\u{200F}", String(repeating: "a", count: 257)] {
			#expect(!BackupPayload.isLabel(label, maximumBytes: 256), "\(label.debugDescription)")
		}
	}

	@Test("the engine seals what the app writes, opens it to the same bytes, and refuses the wrong passphrase")
	func roundTrip() throws {
		let app = BackupAppSection(
			settings: .init(appearance: .dark, keySort: .descending, quitShortcut: .hold, updateChannel: .stable,
				projectOrder: [Self.vault], environmentOrders: [Self.vault: ["staging", "default"]]),
			icons: [Self.vault: .choice(.emoji("🚀"))],
			destinations: [Self.vault: [vercelDestination(source: "default")]])
		let written = try #require(payload(projects: [
			project(environments: ["default": ["TOKEN": "quote \" and \u{1} and 🚀"], "staging": [:]],
				sync: .init(registry: "https://lpm.dev", principalId: "usr_1", scope: .organization(slug: "acme"))),
			project("hidden-vault", name: "hidden-vault", folder: nil, hidden: true),
		], app: app).encoded())
		let file = try BackupEngine.seal(payload: written.bytes, passphrase: Self.strong).get()
		#expect(try BackupEngine.inspect(file).get() == 1)
		let opened = try BackupEngine.open(file, passphrase: Self.strong).get()
		#expect(text(opened) == text(written))
		#expect(BackupEngine.open(file, passphrase: Self.strong + " ").failure == .wrongPassphrase)
	}

	@Test("the engine refuses a weak passphrase and invalid contents by their codes, before deriving a key")
	func refusals() throws {
		let written = try #require(payload(projects: [project()]).encoded())
		guard case .passphraseWeak = BackupEngine.seal(payload: written.bytes, passphrase: "password123").failure else {
			Issue.record("a weak passphrase sealed")
			return
		}
		let invalid = try #require(payload(projects: [project(environments: ["not valid": [:]])]).encoded())
		guard case .invalidContents(let reason, let offset?) = BackupEngine.seal(payload: invalid.bytes, passphrase: Self.strong).failure else {
			Issue.record("invalid contents sealed")
			return
		}
		#expect(reason == "environment_name")
		#expect(invalid.project(at: offset) == 0)
		#expect(invalid.project(at: 0) == nil)
		let bytes = invalid.bytes.withUnsafeBytes { Array($0) }
		let name = Array(#""not valid""#.utf8)
		#expect(offset == (0...bytes.count - name.count).first { Array(bytes[$0..<$0 + name.count]) == name })
		#expect(BackupEngine.inspect(Data("not a backup".utf8)).failure == .notABackup)
	}

	@Test("passphrase strength comes from the engine, and generated ones are six words it accepts")
	func passphrases() throws {
		let weak = try BackupEngine.strength(of: "password123").get()
		#expect(!weak.acceptable)
		#expect(weak.minimumGuessesLog10 == 18.1)
		#expect(try BackupEngine.strength(of: Self.strong).get().acceptable)
		let generated = try BackupEngine.generatePassphrase().get()
		#expect(generated.split(separator: " ").count == 6)
		#expect(try BackupEngine.strength(of: generated).get().acceptable)
	}

	@Test("secret bytes are lent out as written and zeroed when let go")
	func secretBytes() {
		let bytes = Array("secret".utf8).withUnsafeBytes { SecretBytes(copying: $0) }
		#expect(bytes.withUnsafeBytes { Array($0) } == Array("secret".utf8))
		struct Failure: Error {}
		#expect(throws: Failure.self) { _ = try SecretBytes(count: 4) { _ in throw Failure() } }
	}
	@Test("opening split gives the payload without its sync keys, and the keys as their stores keep them")
	func openSplit() throws {
		func secret(_ text: String) -> SecretBytes { SecretBytes(count: text.utf8.count) { $0.copyBytes(from: Array(text.utf8)) } }
		var keys = BackupKeys()
		keys.personalRoots = [.init(account: BackupKeysTests.rootAccount, key: secret(BackupKeysTests.rootKey))]
		keys.sharingKeys = [.init(account: BackupKeysTests.sharingAccount, live: secret(BackupKeysTests.liveKey), pending: secret(BackupKeysTests.pendingKey))]
		keys.wrappingKey = secret(BackupKeysTests.wrappingKey)
		keys.floors = [.init(digest: BackupKeysTests.floor, version: 9)]
		let payload = BackupPayload(createdAt: Date(timeIntervalSince1970: 0), producerVersion: "1", deviceName: nil, projects: [], app: nil, keys: keys)
		let encoded = try #require(payload.encoded())
		let file = try BackupEngine.seal(payload: encoded.bytes, passphrase: "harbor velvet ninety cactus orbit maple").get()

		let opened = try BackupEngine.openSplit(file, passphrase: "harbor velvet ninety cactus orbit maple").get()
		let text = opened.payload.withUnsafeBytes { String(decoding: $0, as: UTF8.self) }
		#expect(!text.contains("keys"))
		#expect(!text.contains(BackupKeysTests.rootKey))
		#expect(opened.keys.personalRoots.map(\.account) == [BackupKeysTests.rootAccount])
		#expect(BackupKeysTests.text(opened.keys.personalRoots.first?.key) == BackupKeysTests.rootKey)
		#expect(opened.keys.sharingKeys.map(\.account) == [BackupKeysTests.sharingAccount])
		#expect(BackupKeysTests.text(opened.keys.sharingKeys.first?.live) == BackupKeysTests.liveKey)
		#expect(BackupKeysTests.text(opened.keys.sharingKeys.first?.pending) == BackupKeysTests.pendingKey)
		#expect(BackupKeysTests.text(opened.keys.wrappingKey) == BackupKeysTests.wrappingKey)
		#expect(opened.keys.floors == [.init(digest: BackupKeysTests.floor, version: 9)])
	}

	@Test("key records the engine didn't lay out are refused: an unknown kind, a cut record, a key named twice")
	func keyRecords() {
		func records(_ bytes: [UInt8]) -> BackupKeys? { bytes.withUnsafeBytes { BackupEngine.keyRecords($0) } }
		let digest = [UInt8](repeating: 0xab, count: 32)
		let root = [1] + digest + Array(BackupKeysTests.rootKey.utf8)
		let live = [2] + digest + Array(BackupKeysTests.liveKey.utf8)
		let pending = [3] + digest + Array(BackupKeysTests.pendingKey.utf8)
		let wrapping = [4] + Array(BackupKeysTests.wrappingKey.utf8)
		let floor = [5] + digest + [0, 0, 1, 2]

		let keys = records(root + live + pending + wrapping + floor)
		#expect(keys?.personalRoots.map(\.account) == [String(repeating: "ab", count: 32)])
		#expect(keys?.sharingKeys.count == 1, "A sharing key's two halves are one entry")
		#expect(keys?.floors == [.init(digest: String(repeating: "ab", count: 32), version: 258)])
		#expect(records([])?.isEmpty == true)
		#expect(records([9]) == nil, "An unknown record kind is refused")
		#expect(records(Array(root.dropLast())) == nil, "A cut record is refused")
		for (name, twice) in [("root", root + root), ("live sharing key", live + live), ("pending sharing key", pending + pending),
			("wrapping key", wrapping + wrapping), ("floor", floor + floor)]
		{
			#expect(records(twice) == nil, "A \(name) named twice is refused")
		}
		#expect(records([5] + digest + [0, 0, 0, 0]) == nil, "A floor at version 0 is refused")
		#expect(records([5] + digest + [0x80, 0, 0, 0]) == nil, "A floor past Int32.max is refused")
	}
}

@Suite("Backup app section")
struct BackupAppSectionTests {
	private static let vault = "550e8400-e29b-41d4-a716-446655440000"

	private func section() -> BackupAppSection {
		BackupAppSection(
			settings: .init(appearance: .light, keySort: .ascending, quitShortcut: .doublePress, updateChannel: .nightly,
				projectOrder: [Self.vault, "other-vault"], environmentOrders: [Self.vault: ["production", "default"]]),
			icons: [
				Self.vault: .choice(.symbol("bolt.fill", .blue)),
				"other-vault": .image(name: "logo.png", png: Data([0x89, 0x50, 0x4E, 0x47])),
				"third-vault": .choice(.projectFile("assets/icon.png")),
			],
			destinations: [Self.vault: [
				vercelDestination(source: "production"),
				vercelDestination(source: "default", project: "prj_web", createdAt: Date(timeIntervalSince1970: 1_760_000_100)),
			]])
	}

	private func read(_ text: String) throws -> BackupAppSection {
		try BackupAppSection(json: LPMConfigJSON(parsing: Data(text.utf8), rejectDuplicateKeys: true))
	}

	@Test("a section reads back as it was written")
	func roundTrip() throws {
		let written = section()
		let data = try #require(written.json()).compactData(maximumBytes: .max)
		#expect(try BackupAppSection(json: LPMConfigJSON(parsing: data, rejectDuplicateKeys: true)) == written)
		#expect(try BackupAppSection(json: #require(BackupAppSection(settings: nil).json())) == BackupAppSection(settings: nil))
	}

	@Test("unknown or missing fields, newer versions, and icons without settings are refused")
	func strictness() throws {
		#expect(throws: BackupAppSection.DecodingError.newerVersion) { try read(#"{"version":2,"future":true}"#) }
		for text in [
			#"{"version":1,"extra":1}"#,
			#"{"version":1.0}"#,
			#"{}"#,
			#"{"version":1,"icons":{"v":{"kind":"emoji","emoji":"🚀"}}}"#,
			#"{"version":1,"settings":{"appearance":"dark"}}"#,
			#"{"version":1,"settings":{"appearance":"sepia","keySort":"ascending","quitShortcut":"hold","updateChannel":"stable","projectOrder":[],"environmentOrders":{}}}"#,
			#"{"version":1,"settings":{"appearance":"dark","keySort":"ascending","quitShortcut":"hold","updateChannel":"stable","projectOrder":["v","v"],"environmentOrders":{}}}"#,
			#"{"version":1,"settings":{"appearance":"dark","keySort":"ascending","quitShortcut":"hold","updateChannel":"stable","projectOrder":["__index__"],"environmentOrders":{}}}"#,
		] {
			#expect(throws: BackupAppSection.DecodingError.unreadable, "\(text)") { try read(text) }
		}
	}

	@Test("icons must be ones LPM Vault could keep, and images canonical base64 within the size limit")
	func icons() throws {
		let settings = #""settings":{"appearance":"dark","keySort":"ascending","quitShortcut":"hold","updateChannel":"stable","projectOrder":[],"environmentOrders":{}}"#
		func icon(_ json: String) throws -> BackupAppSection {
			try read(#"{"version":1,\#(settings),"icons":{"v":\#(json)}}"#)
		}
		#expect(try icon(#"{"kind":"emoji","emoji":"🚀"}"#).icons["v"] == .choice(.emoji("🚀")))
		for json in [
			#"{"kind":"emoji","emoji":"ab"}"#,
			#"{"kind":"symbol","name":"not-a-symbol","color":"blue"}"#,
			#"{"kind":"monogram","letters":"wd","color":"blue"}"#,
			#"{"kind":"projectFile","path":"../outside.png"}"#,
			#"{"kind":"storedImage","file":"x.png"}"#,
			#"{"kind":"image","name":"logo.png","png":"iVBORw"}"#,
			#"{"kind":"image","name":"logo.png","png":""}"#,
			#"{"kind":"emoji","emoji":"🚀","extra":1}"#,
		] {
			#expect(throws: BackupAppSection.DecodingError.unreadable, "\(json)") { try icon(json) }
		}
		let oversized = Data(count: BackupAppSection.maximumIconBytes + 1).base64EncodedString()
		#expect(throws: BackupAppSection.DecodingError.unreadable) { try icon(#"{"kind":"image","name":"big.png","png":"\#(oversized)"}"#) }
	}

	@Test("destinations are each vault's stored record, bound to the vault they're listed under")
	func destinations() throws {
		let record = try #require(PublishingRecords.encode([vercelDestination()], vaultID: Self.vault))
		let text = String(decoding: record, as: UTF8.self)
		#expect(try read(#"{"version":1,"destinations":{"\#(Self.vault)":\#(text)}}"#).destinations[Self.vault]?.count == 1)
		#expect(throws: BackupAppSection.DecodingError.unreadable) {
			try read(#"{"version":1,"destinations":{"other-vault":\#(text)}}"#)
		}
		let empty = try #require(PublishingRecords.encode([], vaultID: Self.vault))
		#expect(throws: BackupAppSection.DecodingError.unreadable) {
			try read(#"{"version":1,"destinations":{"\#(Self.vault)":\#(String(decoding: empty, as: UTF8.self))}}"#)
		}
		#expect(BackupAppSection(settings: nil, destinations: [Self.vault: []]).json() == nil)
	}
}

extension Result {
	fileprivate var failure: Failure? {
		if case .failure(let failure) = self { return failure }
		return nil
	}

}
