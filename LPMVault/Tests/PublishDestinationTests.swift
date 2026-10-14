import CryptoKit
import Foundation
import Testing

@testable import LPMVault

let publishTestVault = "0b7c2a1e-5f3d-4c8e-9a61-2d4f8e0c7b13"

func vercelDestination(
	id: UUID = UUID(),
	source: String = "production",
	team: String? = "team_acme",
	account: String? = nil,
	project: String = "prj_demo",
	environment: VercelPublishTarget.Environment = .production,
	excluded: Set<String> = [],
	createdAt: Date = Date(timeIntervalSince1970: 1_760_000_000.123)
) -> PublishDestination {
	PublishDestination(
		id: id,
		sourceEnvironment: source,
		target: .vercel(VercelPublishTarget(
			teamID: team, accountID: account ?? team ?? "user_tolga", teamName: "Acme", projectID: project, projectName: "demo-api",
			environment: environment
		)),
		excludedKeys: excluded,
		createdAt: createdAt
	)
}

@Suite("Publish destinations")
struct PublishDestinationTests {
	@Test("destinations read back from their stored form exactly as they were saved")
	func roundTrip() throws {
		let destinations = [
			vercelDestination(excluded: ["LOG_LEVEL", "API_TOKEN"]),
			vercelDestination(source: "staging", team: nil, environment: .preview),
			vercelDestination(source: "qa", environment: .custom(id: "env_qa1", name: "QA")),
		]
		let data = try #require(PublishingRecords.encode(destinations, vaultID: publishTestVault))
		let decoded = try PublishingRecords.decodeDestinations(data, vaultID: publishTestVault).get()
		#expect(Set(decoded) == Set(destinations))
		#expect(decoded.first { $0.sourceEnvironment == "production" }?.createdAt.timeIntervalSince1970 == 1_760_000_000.123)
	}

	@Test("names stored before they were escaped read back with their direction controls escaped")
	func escapesStoredNames() throws {
		let json = Self.record(environment: #"{"kind":"custom","id":"env_qa","name":"qa\u2066"}"#)
			.replacingOccurrences(of: #""teamName":"Acme""#, with: #""teamName":"Acme\u202e""#)
			.replacingOccurrences(of: "VAULT", with: publishTestVault)
		let destination = try #require(try PublishingRecords.decodeDestinations(Data(json.utf8), vaultID: publishTestVault).get().first)
		guard case .vercel(let target) = destination.target else { Issue.record("Not a Vercel destination"); return }
		#expect(target.teamName == #"Acme\u{202e}"# && target.environment == .custom(id: "env_qa", name: #"qa\u{2066}"#))
	}

	@Test("two destinations write to the same place when only their display names differ")
	func locations() {
		let production = vercelDestination()
		var renamed = vercelDestination(source: "staging")
		if case .vercel(var target) = renamed.target {
			target.projectName = "renamed"
			target.teamName = "Renamed"
			renamed.target = .vercel(target)
		}
		#expect(production.target.location == renamed.target.location)
		#expect(vercelDestination(environment: .preview).target.location != production.target.location)
		#expect(vercelDestination(team: nil).target.location != production.target.location)
		#expect(
			vercelDestination(environment: .custom(id: "env_1", name: "QA")).target.location
				== vercelDestination(environment: .custom(id: "env_1", name: "Quality")).target.location)
	}

	@Test(
		"a destination with an invalid source, excluded key, Vercel ID or name can't be stored",
		arguments: [
			(vercelDestination(source: "bad/name"), PublishDestinationInvalidity.sourceEnvironment),
			(vercelDestination(excluded: ["1KEY"]), .excludedKeys),
			(vercelDestination(team: ""), .targetIdentifier),
			(vercelDestination(project: "prj demo"), .targetIdentifier),
			(vercelDestination(project: String(repeating: "p", count: 101)), .targetIdentifier),
			(vercelDestination(environment: .custom(id: "env_1", name: "QA\u{7}")), .targetName),
			(vercelDestination(environment: .custom(id: "env_1", name: " QA")), .targetName),
			(vercelDestination(project: "prj/../x"), .targetIdentifier),
			(vercelDestination(team: "team%2F"), .targetIdentifier),
			(vercelDestination(team: "team_acme", account: "team_other"), .targetIdentifier),
			(vercelDestination(team: nil, account: "user/../x"), .targetIdentifier),
			(vercelDestination(environment: .custom(id: "env_1", name: String(repeating: "\u{301}", count: 300))), .targetName),
		]
	)
	func invalid(destination: PublishDestination, invalidity: PublishDestinationInvalidity) {
		#expect(destination.invalidity == invalidity)
	}

	@Test("a Coolify destination reads back exactly, with or without its project's names, and writes to its resource's deployments")
	func coolifyRoundTrip() throws {
		let application = coolifyDestination()
		let preview = coolifyDestination(deployments: .preview, project: nil)
		let service = coolifyDestination(resource: .service, resourceID: "svc-db")
		let data = try #require(PublishingRecords.encode([application, preview, service], vaultID: publishTestVault))
		#expect(Set(try PublishingRecords.decodeDestinations(data, vaultID: publishTestVault).get()) == [application, preview, service])
		var renamed = coolifyDestination(source: "staging")
		if case .coolify(var target) = renamed.target {
			target.resourceName = "renamed"
			target.teamName = "Renamed"
			renamed.target = .coolify(target)
		}
		#expect(renamed.target.location == application.target.location)
		#expect(preview.target.location != application.target.location)
		#expect(PublishingRecords.encode([application, renamed], vaultID: publishTestVault) == nil)
		#expect(application.target.connectionID == "coolify.0.https://coolify.example.com")
		#expect(application.target.placeName == "api / Production" && preview.target.placeName == "api / Preview deployments")
	}

	@Test("a Coolify destination with an unsafe ID, a service with preview deployments, or a bad name can't be stored")
	func invalidCoolify() {
		#expect(coolifyDestination(resourceID: "../x").invalidity == .targetIdentifier)
		#expect(coolifyDestination(resource: .service, deployments: .preview).invalidity == .targetIdentifier)
		#expect(coolifyDestination(teamID: "root").invalidity == .targetIdentifier)
		#expect(coolifyDestination(project: " Storefront").invalidity == .targetName)
		#expect(coolifyDestination().invalidity == nil)
	}

	@Test("a destination changed before it was created is invalid")
	func timestamps() {
		var destination = vercelDestination()
		destination.updatedAt = destination.createdAt.addingTimeInterval(-1)
		#expect(destination.invalidity == .timestamps)
	}

	@Test(
		"a record written by a newer LPM Vault is reported as newer rather than damaged",
		arguments: [
			#"{"version":2,"vault":"VAULT","destinations":[],"syncedAt":1}"#,
			#"{"version":99999999999999999999999,"vault":"VAULT","destinations":[]}"#,
			record(platform: "netlify", extra: #","netlifySite":"x""#),
			record(platform: "netlify"),
			record(environment: #"{"kind":"branch","branch":"main"}"#),
			coolifyRecord(resource: "database"),
			coolifyRecord(deployments: "staging"),
		]
	)
	func newerVersion(json: String) {
		let data = Data(json.replacingOccurrences(of: "VAULT", with: publishTestVault).utf8)
		#expect(PublishingRecords.decodeDestinations(data, vaultID: publishTestVault) == .failure(.newerVersion))
	}

	@Test(
		"a damaged record, or one bound to another vault, isn't read",
		arguments: [
			#"{"version":1,"vault":"VAULT","destinations":[],"extra":true}"#,
			#"{"version":1,"vault":"VAULT","destinations":[],"destinations":[]}"#,
			#"{"version":1,"vault":"another-vault","destinations":[]}"#,
			#"{"version":"1","vault":"VAULT","destinations":[]}"#,
			#"{"version":0,"vault":"VAULT","destinations":[]}"#,
			record(extra: #","note":"x""#),
			record(id: "9A0B7C2D-1E3F-4A5B-8C6D-7E8F9A0B1C2D"),
			record(createdAt: "1.5"),
			record(createdAt: "-1"),
			record(excluded: #"["A","A"]"#),
			record(source: "../production"),
			record(environment: #"{"kind":"production","id":"x"}"#),
			"[" + String(repeating: "x", count: 10) + "]",
			#"{"version":-1,"vault":"VAULT","destinations":[]}"#,
			record().replacingOccurrences(of: "excludedKeys", with: "excluded\u{212A}eys"),
			record().replacingOccurrences(of: #""vault":"VAULT""#, with: #""vault":"VAULT\u{301}""#),
			record(platform: "coolify"),
			coolifyRecord(instance: "https://Coolify.example.com"),
			coolifyRecord(instance: "http://coolify.example.com"),
			coolifyRecord(resource: "service", deployments: "preview"),
			coolifyRecord(extra: #","buildPack":"nixpacks""#),
			coolifyRecord(teamID: "team_acme"),
		]
	)
	func unreadable(json: String) {
		let data = Data(json.replacingOccurrences(of: "VAULT", with: publishTestVault).utf8)
		#expect(PublishingRecords.decodeDestinations(data, vaultID: publishTestVault) == .failure(.unreadable))
	}

	@Test("a record can't hold two destinations with one ID, or two that write to the same place")
	func duplicates() throws {
		let first = vercelDestination()
		let sameID = vercelDestination(id: first.id, source: "staging", environment: .preview)
		let samePlace = vercelDestination(source: "staging")
		for pair in [[first, sameID], [first, samePlace]] {
			#expect(PublishingRecords.encode(pair, vaultID: publishTestVault) == nil)
		}
		let stored = Self.record().replacingOccurrences(of: "VAULT", with: publishTestVault)
		let doubled = stored.replacingOccurrences(of: #""destinations":["#, with: #""destinations":["#)
			.replacingOccurrences(of: "}]}", with: "}," + String(stored[stored.range(of: #"{"id""#)!.lowerBound...].dropLast(2)) + "]}")
		#expect(PublishingRecords.decodeDestinations(Data(doubled.utf8), vaultID: publishTestVault) == .failure(.unreadable))
	}

	@Test("the valid records the tests' damaged variants start from read")
	func baseRecord() throws {
		for json in [Self.record(), coolifyRecord()] {
			let data = Data(json.replacingOccurrences(of: "VAULT", with: publishTestVault).utf8)
			let destinations = try PublishingRecords.decodeDestinations(data, vaultID: publishTestVault).get()
			#expect(destinations.map(\.sourceEnvironment) == ["production"])
		}
	}

	static func record(
		id: String = "9a0b7c2d-1e3f-4a5b-8c6d-7e8f9a0b1c2d",
		source: String = "production",
		platform: String = "vercel",
		environment: String = #"{"kind":"production"}"#,
		excluded: String = "[]",
		createdAt: String = "1760000000123",
		extra: String = ""
	) -> String {
		#"{"version":1,"vault":"VAULT","destinations":[{"id":"\#(id)","source":"\#(source)","platform":"\#(platform)","#
			+ #""target":{"teamId":"team_acme","accountId":"team_acme","teamName":"Acme","projectId":"prj_demo","projectName":"demo-api","environment":\#(environment)},"#
			+ #""excludedKeys":\#(excluded),"createdAt":\#(createdAt),"updatedAt":1760000000123\#(extra)}]}"#
	}
}

func coolifyDestination(
	source: String = "production",
	teamID: String = "0",
	resource: CoolifyPublishTarget.Resource = .application,
	resourceID: String = "app-api",
	deployments: CoolifyPublishTarget.Deployments = .production,
	project: String? = "Storefront"
) -> PublishDestination {
	PublishDestination(
		sourceEnvironment: source,
		target: .coolify(CoolifyPublishTarget(
			instance: CoolifyInstance(origin: "https://coolify.example.com")!, teamID: teamID, teamName: "Root Team",
			resource: resource, resourceID: resourceID, resourceName: "api",
			projectName: project, environmentName: project == nil ? nil : "production", deployments: deployments)),
		createdAt: Date(timeIntervalSince1970: 1_760_000_000.123))
}

private func coolifyRecord(
	instance: String = "https://coolify.example.com",
	teamID: String = "0",
	resource: String = "application",
	deployments: String = "production",
	extra: String = ""
) -> String {
	#"{"version":1,"vault":"VAULT","destinations":[{"id":"9a0b7c2d-1e3f-4a5b-8c6d-7e8f9a0b1c2d","source":"production","platform":"coolify","#
		+ #""target":{"instance":"\#(instance)","teamId":"\#(teamID)","teamName":"Root Team","resource":"\#(resource)","resourceId":"app-api","#
		+ #""resourceName":"api","projectName":"Storefront","environmentName":null,"deployments":"\#(deployments)"\#(extra)},"#
		+ #""excludedKeys":[],"createdAt":1760000000123,"updatedAt":1760000000123}]}"#
}

private func record(
	platform: String = "vercel",
	environment: String = #"{"kind":"production"}"#,
	extra: String = "",
	id: String = "9a0b7c2d-1e3f-4a5b-8c6d-7e8f9a0b1c2d",
	createdAt: String = "1760000000123",
	excluded: String = "[]",
	source: String = "production"
) -> String {
	PublishDestinationTests.record(
		id: id, source: source, platform: platform, environment: environment,
		excluded: excluded, createdAt: createdAt, extra: extra)
}

@Suite("Publish history")
struct PublishHistoryTests {
	private let destination = UUID()
	private let secret = SymmetricKey(size: .bits256)
	private let publishedAt = Date(timeIntervalSince1970: 1_760_000_100.456)

	@Test("history reads back from its stored form exactly as it was saved, and holds no values")
	func roundTrip() throws {
		let history = PublishHistory().recording([
			published("API_TOKEN", remoteID: "env_1", updatedAt: Date(timeIntervalSince1970: 1_760_000_100.789)),
			published("LOG_LEVEL", remoteID: nil, updatedAt: nil),
		], forgetting: [], at: publishedAt)
		let data = try #require(PublishingRecords.encode(history, destination: destination, vaultID: publishTestVault))
		#expect(try PublishingRecords.decodeHistory(data, destination: destination, vaultID: publishTestVault).get() == history)
		#expect(!String(decoding: data, as: UTF8.self).contains("api_token"))
		#expect(PublishingRecords.decodeHistory(data, destination: UUID(), vaultID: publishTestVault) == .failure(.unreadable))
	}

	@Test("a history the decoder would reject isn't encoded: wrong fingerprint length, invalid key name, odd remote ID")
	func encoderMatchesDecoder() {
		let invalid: [PublishHistory.Published] = [
			.init(key: "API_TOKEN", fingerprint: Data(count: 16), remoteID: nil, remoteUpdatedAt: nil, publishedAsSecret: true),
			.init(key: "1API", fingerprint: Data(count: 32), remoteID: nil, remoteUpdatedAt: nil, publishedAsSecret: true),
			.init(key: "API", fingerprint: Data(count: 32), remoteID: "../env", remoteUpdatedAt: nil, publishedAsSecret: true),
			.init(key: "API", fingerprint: Data(count: 32), remoteID: "env\u{0}", remoteUpdatedAt: nil, publishedAsSecret: true),
		]
		for item in invalid {
			let history = PublishHistory().recording([item], forgetting: [], at: publishedAt)
			#expect(PublishingRecords.encode(history, destination: destination, vaultID: publishTestVault) == nil)
		}
	}

	@Test(
		"a stored time past the year 9999 reads as unreadable instead of crashing",
		arguments: ["9223372036854775807", "253402300800000"]
	)
	func impossibleStoredTimes(milliseconds: String) {
		let history = #"{"version":1,"vault":"\#(publishTestVault)","destination":"\#(destination.uuidString.lowercased())","publishedAt":\#(milliseconds),"keys":[]}"#
		#expect(PublishingRecords.decodeHistory(Data(history.utf8), destination: destination, vaultID: publishTestVault) == .failure(.unreadable))
		let destinations = PublishDestinationTests.record(createdAt: milliseconds).replacingOccurrences(of: "VAULT", with: publishTestVault)
		#expect(PublishingRecords.decodeDestinations(Data(destinations.utf8), vaultID: publishTestVault) == .failure(.unreadable))
	}

	@Test("an impossible platform time is kept within the stored range")
	func impossiblePlatformTimes() throws {
		let far = PublishPlan.RemoteVariable(id: "env_1", updatedAt: Date(timeIntervalSince1970: 1e300))
		#expect(far.updatedAt == PublishTimestamp.date(milliseconds: PublishTimestamp.maximumMilliseconds))
		let history = PublishHistory().recording(
			[published("A", remoteID: "env_1", updatedAt: Date(timeIntervalSince1970: .nan))], forgetting: [], at: Date(timeIntervalSince1970: -5))
		#expect(history.publishedAt == Date(timeIntervalSince1970: 0))
		let data = try #require(PublishingRecords.encode(history, destination: destination, vaultID: publishTestVault))
		#expect(try PublishingRecords.decodeHistory(data, destination: destination, vaultID: publishTestVault).get() == history)
	}

	@Test("a later publish replaces the records it wrote, and keeps the others unless they're forgotten")
	func laterPublish() {
		let first = PublishHistory().recording(
			[published("A", remoteID: "env_a", updatedAt: nil), published("B", remoteID: "env_b", updatedAt: nil),
			 published("GONE", remoteID: "env_g", updatedAt: nil)],
			forgetting: [], at: publishedAt)
		let later = publishedAt.addingTimeInterval(60)
		let second = first.recording([published("B", remoteID: "env_b2", updatedAt: nil)], forgetting: ["GONE"], at: later)
		#expect(second.publishedAt == PublishTimestamp.normalized(later))
		#expect(second.keys["A"]?.publishedAt == PublishTimestamp.normalized(publishedAt))
		#expect(second.keys["B"]?.remoteID == "env_b2")
		#expect(second.keys["B"]?.publishedAt == PublishTimestamp.normalized(later))
		#expect(second.keys["GONE"] == nil)
	}

	@Test("each publish moves the history's time forward, even when the clock stalls or steps back")
	func publishTimeMovesForward() {
		let first = PublishHistory().recording([published("A", remoteID: nil, updatedAt: nil)], forgetting: [], at: publishedAt)
		let stalled = first.recording([published("B", remoteID: nil, updatedAt: nil)], forgetting: [], at: publishedAt)
		let back = stalled.recording(
			[published("C", remoteID: nil, updatedAt: nil)], forgetting: [], at: publishedAt.addingTimeInterval(-60))
		let milliseconds = PublishTimestamp.milliseconds(publishedAt)
		#expect(stalled.publishedAt == PublishTimestamp.date(milliseconds: milliseconds + 1))
		#expect(back.publishedAt == PublishTimestamp.date(milliseconds: milliseconds + 2))
		#expect(back.keys["C"]?.publishedAt == back.publishedAt && back.keys["A"]?.publishedAt == first.publishedAt)
		let last = PublishTimestamp.date(milliseconds: PublishTimestamp.maximumMilliseconds)
		#expect(PublishTimestamp.next(after: last, at: publishedAt) == last)
		#expect(!PublishTimestamp.identifiesOneWrite(last))
		#expect(PublishTimestamp.identifiesOneWrite(last.addingTimeInterval(-0.001)) && PublishTimestamp.identifiesOneWrite(publishedAt))
	}

	@Test("over the limit, the records published longest ago go, never this publish's")
	func limit() {
		let limit = PublishHistory.maximumKeys
		let oldKeys = (0..<limit).map { "OLD_\($0)" }
		let old = PublishHistory().recording(oldKeys.map { published($0, remoteID: nil, updatedAt: nil) }, forgetting: [], at: publishedAt)
		let newKeys = ["AAA_NEW", "AAB_NEW"]
		let new = old.recording(
			newKeys.map { published($0, remoteID: nil, updatedAt: nil) }, forgetting: [], at: publishedAt.addingTimeInterval(1))
		#expect(new.keys.count == limit)
		#expect(new.keys["AAA_NEW"] != nil && new.keys["AAB_NEW"] != nil)
		#expect(new.keys["OLD_0"] == nil && new.keys["OLD_1"] == nil && new.keys["OLD_2"] != nil)
	}

	@Test("a history whose names are too long for one record keeps its newest records")
	func byteBudget() throws {
		let longName = String(repeating: "K", count: 1_000)
		var history = PublishHistory()
		for batch in 0..<4 {
			history = history.recording(
				(0..<500).map { published("\(longName)_\(batch)_\($0)", remoteID: nil, updatedAt: nil) },
				forgetting: [], at: publishedAt.addingTimeInterval(Double(batch)))
		}
		#expect(PublishingRecords.encode(history, destination: destination, vaultID: publishTestVault) == nil)
		let fitted = try #require(PublishingRecords.encodeFitting(history, destination: destination, vaultID: publishTestVault))
		#expect(fitted.data.count <= PublishingRecords.maximumRecordBytes)
		#expect(fitted.history.keys.keys.contains { $0.hasPrefix("\(longName)_3_") })
		#expect(!fitted.history.keys.keys.contains { $0.hasPrefix("\(longName)_0_") })
		#expect(try PublishingRecords.decodeHistory(fitted.data, destination: destination, vaultID: publishTestVault).get() == fitted.history)
	}

	@Test("a fingerprint changes with the value, the key, the destination and this Mac's key")
	func fingerprint() {
		let base = PublishFingerprint.of(value: "secret", key: "API_TOKEN", destination: destination, using: secret)
		#expect(base.count == PublishFingerprint.byteCount)
		#expect(base == PublishFingerprint.of(value: "secret", key: "API_TOKEN", destination: destination, using: secret))
		#expect(base != PublishFingerprint.of(value: "secret2", key: "API_TOKEN", destination: destination, using: secret))
		#expect(base != PublishFingerprint.of(value: "secret", key: "API_TOKEN2", destination: destination, using: secret))
		#expect(base != PublishFingerprint.of(value: "secret", key: "API_TOKEN", destination: UUID(), using: secret))
		#expect(
			base != PublishFingerprint.of(value: "secret", key: "API_TOKEN", destination: destination, using: SymmetricKey(size: .bits256)))
		// Field boundaries are length-prefixed, so moving characters between key and value changes it.
		#expect(
			PublishFingerprint.of(value: "BC", key: "A", destination: destination, using: secret)
				!= PublishFingerprint.of(value: "C", key: "AB", destination: destination, using: secret))
	}

	@Test("the fingerprint is HMAC-SHA256 over a fixed layout, so it stays stable across versions")
	func fingerprintLayout() {
		let id = UUID(uuidString: "0B7C2A1E-5F3D-4C8E-9A61-2D4F8E0C7B13")!
		var message = Data("lpm-vault:publish-fingerprint:v1\0".utf8)
		message.append(contentsOf: withUnsafeBytes(of: id.uuid) { Array($0) })
		for field in ["KEY", "välue"] {
			message.append(contentsOf: withUnsafeBytes(of: UInt64(field.utf8.count).bigEndian) { Array($0) })
			message.append(contentsOf: Array(field.utf8))
		}
		let expected = Data(HMAC<SHA256>.authenticationCode(for: message, using: secret))
		#expect(PublishFingerprint.of(value: "välue", key: "KEY", destination: id, using: secret) == expected)
	}

	private func published(_ key: String, remoteID: String?, updatedAt: Date?) -> PublishHistory.Published {
		.init(
			key: key,
			fingerprint: PublishFingerprint.of(value: key.lowercased(), key: key, destination: destination, using: secret),
			remoteID: remoteID,
			remoteUpdatedAt: updatedAt, publishedAsSecret: true
		)
	}
}
