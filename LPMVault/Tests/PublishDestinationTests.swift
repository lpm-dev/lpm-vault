import CryptoKit
import Foundation
import Testing

@testable import LPMVault

let publishTestVault = "0b7c2a1e-5f3d-4c8e-9a61-2d4f8e0c7b13"

func vercelDestination(
	id: UUID = UUID(),
	source: String = "production",
	team: String? = "team_acme",
	project: String = "prj_demo",
	environment: VercelPublishTarget.Environment = .production,
	excluded: Set<String> = [],
	createdAt: Date = Date(timeIntervalSince1970: 1_760_000_000.123)
) -> PublishDestination {
	PublishDestination(
		id: id,
		sourceEnvironment: source,
		target: .vercel(VercelPublishTarget(
			teamID: team, teamName: "Acme", projectID: project, projectName: "demo-api", environment: environment
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
		]
	)
	func invalid(destination: PublishDestination, invalidity: PublishDestinationInvalidity) {
		#expect(destination.invalidity == invalidity)
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
			record(platform: "netlify"),
			record(environment: #"{"kind":"branch","branch":"main"}"#),
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
			let data = try #require(PublishingRecords.encode(pair, vaultID: publishTestVault))
			#expect(PublishingRecords.decodeDestinations(data, vaultID: publishTestVault) == .failure(.unreadable))
		}
	}

	@Test("the valid record the tests' damaged variants start from reads")
	func baseRecord() throws {
		let data = Data(Self.record().replacingOccurrences(of: "VAULT", with: publishTestVault).utf8)
		let destinations = try PublishingRecords.decodeDestinations(data, vaultID: publishTestVault).get()
		#expect(destinations.map(\.sourceEnvironment) == ["production"])
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
			+ #""target":{"teamId":"team_acme","teamName":"Acme","projectId":"prj_demo","projectName":"demo-api","environment":\#(environment)},"#
			+ #""excludedKeys":\#(excluded),"createdAt":\#(createdAt),"updatedAt":1760000000123\#(extra)}]}"#
	}
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

	@Test("history reads back from its stored form exactly as it was saved")
	func roundTrip() throws {
		let history = PublishHistory().recording([
			published("API_TOKEN", remoteID: "env_1", updatedAt: Date(timeIntervalSince1970: 1_760_000_100.789)),
			published("LOG_LEVEL", remoteID: nil, updatedAt: nil),
		], to: destination, at: publishedAt)
		let data = try #require(PublishingRecords.encode(history, vaultID: publishTestVault))
		#expect(try PublishingRecords.decodeHistory(data, vaultID: publishTestVault).get() == history)
		#expect(!String(decoding: data, as: UTF8.self).contains("value"))
	}

	@Test("history with a fingerprint of the wrong length, or an invalid key name, isn't read")
	func damaged() throws {
		for (key, fingerprint) in [("API_TOKEN", Data(count: 16)), ("1API", Data(count: 32))] {
			let history = PublishHistory().recording(
				[.init(key: key, fingerprint: fingerprint, remoteID: nil, remoteUpdatedAt: nil)], to: destination, at: publishedAt)
			let data = try #require(PublishingRecords.encode(history, vaultID: publishTestVault))
			#expect(PublishingRecords.decodeHistory(data, vaultID: publishTestVault) == .failure(.unreadable))
		}
	}

	@Test("a later publish replaces the records of the keys it wrote and keeps the others")
	func laterPublish() {
		let first = PublishHistory().recording(
			[published("A", remoteID: "env_a", updatedAt: nil), published("B", remoteID: "env_b", updatedAt: nil)],
			to: destination, at: publishedAt)
		let later = publishedAt.addingTimeInterval(60)
		let second = first.recording([published("B", remoteID: "env_b2", updatedAt: nil)], to: destination, at: later)
		let entry = second.entries[destination]
		#expect(entry?.publishedAt == PublishTimestamp.normalized(later))
		#expect(entry?.keys["A"]?.publishedAt == PublishTimestamp.normalized(publishedAt))
		#expect(entry?.keys["B"]?.remoteID == "env_b2")
		#expect(entry?.keys["B"]?.publishedAt == PublishTimestamp.normalized(later))
	}

	@Test("an entry that outgrows its limit drops the records published longest ago")
	func limit() {
		let limit = PublishHistory.maximumKeysPerEntry
		let old = PublishHistory().recording(
			(0..<limit).map { published("OLD_\($0)", remoteID: nil, updatedAt: nil) }, to: destination, at: publishedAt)
		let new = old.recording(
			[published("NEW_A", remoteID: nil, updatedAt: nil), published("NEW_B", remoteID: nil, updatedAt: nil)],
			to: destination, at: publishedAt.addingTimeInterval(1))
		let keys = new.entries[destination]?.keys ?? [:]
		#expect(keys.count == limit)
		#expect(keys["NEW_A"] != nil && keys["NEW_B"] != nil)
		#expect(keys["OLD_0"] == nil && keys["OLD_1"] == nil && keys["OLD_2"] != nil)
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

	private func published(_ key: String, remoteID: String?, updatedAt: Date?) -> PublishHistory.Published {
		.init(
			key: key,
			fingerprint: PublishFingerprint.of(value: key.lowercased(), key: key, destination: destination, using: secret),
			remoteID: remoteID,
			remoteUpdatedAt: updatedAt
		)
	}
}
