import Foundation
import LPMEnv

/// Companion storage decided by the LPM CLI's own code in the bundled engine:
/// account names, what a project's feature marker allows, damage and its
/// repairs, and the transactions that finish or start a lifecycle step.
/// Nothing here touches the Keychain; callers bring what they read and
/// commit what they're given.
enum CompanionEngine {
	/// Why the engine refused a request or couldn't answer it.
	struct Failure: Error, Equatable, Sendable {
		let code: String
		let message: String
	}

	enum Role: String, Codable, Sendable {
		case marker, record, staged
	}

	enum AccessClass: String, Codable, Sendable {
		/// Readable without CLI approval: the marker and ciphertext parts.
		case open
		/// The same CLI approval as the project's values item.
		case followsValues
	}

	struct Account: Equatable, Sendable, Decodable {
		let role: Role
		let vaultId: String
		let kind: String?
		let part: Int?
		let access: AccessClass
	}

	/// What an account name is to companion storage.
	enum Described: Equatable, Sendable {
		/// Not a companion account at all.
		case outside
		/// In the companion namespace, but not spelled the one way its accounts are.
		case invalid
		case account(Account)
	}

	/// What a project's feature marker lets a client that doesn't support a
	/// feature do, from most to least permissive.
	enum Level: String, Codable, Sendable, Comparable {
		case ignore, readOnly, refuse

		static func < (lhs: Self, rhs: Self) -> Bool {
			let order: [Self] = [.ignore, .readOnly, .refuse]
			return order.firstIndex(of: lhs)! < order.firstIndex(of: rhs)!
		}
	}

	enum ProjectState: String, Codable, Sendable {
		case active, deleting, discarding, restoring
	}

	struct Assessment: Equatable, Sendable, Decodable {
		enum MarkerState: String, Decodable, Sendable {
			case absent, invalid, valid
		}

		struct Unsupported: Equatable, Sendable, Decodable {
			let feature: String
			let version: Int
			let level: Level
		}

		struct Feature: Equatable, Sendable, Decodable {
			let name: String
			let version: Int
			let ifUnsupported: Level
			let kinds: [String]
			let state: String
			let supported: Bool
		}

		struct Repair: Equatable, Sendable, Decodable {
			enum Action: String, Decodable, Sendable {
				/// Discard every companion record of the project, keeping its values.
				case discardProject
				/// Remove one feature and the records only it lists.
				case removeFeature
				/// Delete the records no feature lists.
				case removeUnlisted
			}

			let action: Action
			let feature: String?
		}

		struct Damage: Equatable, Sendable, Decodable {
			/// `invalidMarker`, `missingRecord`, `invalidRecord`,
			/// `unlistedRecord`, or `access`.
			let code: String
			let kind: String?
			/// What the engine found, never quoting a record's contents.
			let reason: String?
			/// nil for damaged access, which reconciling approval fixes.
			let repair: Repair?
		}

		struct Allows: Equatable, Sendable, Decodable {
			let readExcludingOverrides: Bool
			let readApplyingOverrides: Bool
			let write: Bool
		}

		let marker: MarkerState
		let state: ProjectState?
		let needsResume: Bool
		let level: Level?
		let unsupported: Unsupported?
		let features: [Feature]
		let damage: [Damage]
		let allows: Allows
	}

	/// What a caller saw of one project inside one lock scope.
	struct Observed: Sendable {
		/// The marker account's bytes, nil when it's absent.
		var marker: Data?
		/// A names-only listing taken in the same lock scope, nil without one.
		var inventory: [String]?
		/// Why the project's access was found damaged, if it was.
		var accessDamage: String?
	}

	enum PlanAction: String, Encodable, Sendable {
		/// Finish the interrupted step a valid marker describes.
		case resume
		/// The project's records, with the caller's own deletions in the first transaction.
		case delete
		/// Every record of a project whose marker is invalid or missing, keeping its values.
		case discard
		/// One feature of a valid marker and the records only it lists.
		case removeFeature
		/// The records a valid marker doesn't list.
		case removeUnlisted
	}

	struct Plan: Equatable, Sendable, Decodable {
		struct Move: Equatable, Sendable, Decodable {
			let staged: String
			let live: String
		}

		/// One transaction to commit atomically: its moves write each staged
		/// record's bytes to the live account and delete the staged one.
		struct Transaction: Equatable, Sendable, Decodable {
			let deletes: [String]
			let moves: [Move]
			let writesMarker: Data?
			let deletesMarker: Bool
		}

		/// What a resume finished or undid.
		struct Notice: Equatable, Sendable, Decodable {
			/// `deletion`, `discard`, `restoreUndone`, `restore`, or `featureRemoval`.
			let kind: String
			let features: [String]
		}

		let transactions: [Transaction]
		/// The marker the project is left with, nil when it's gone.
		let result: Data?
		let notice: Notice?
	}

	struct Change: Encodable, Sendable {
		let account: String
		/// The bytes written, nil for a deletion. Only a marker's are read, so
		/// other writes may send none.
		let bytes: Data?

		static func write(_ account: String, _ bytes: Data) -> Self { Self(account: account, bytes: bytes) }
		static func delete(_ account: String) -> Self { Self(account: account, bytes: nil) }
	}

	static func describe(_ names: [String]) throws(Failure) -> [Described] {
		struct Request: Encodable { let names: [String] }
		struct Entry: Decodable {
			let valid: Bool
			let role: Role?
			let vaultId: String?
			let kind: String?
			let part: Int?
			let access: AccessClass?
		}
		struct Response: Decodable { let accounts: [Entry?] }
		let response: Response = try call(lpm_env_companion_accounts, Request(names: names))
		guard response.accounts.count == names.count else { throw unreadable }
		return try response.accounts.map { entry throws(Failure) in
			guard let entry else { return .outside }
			guard entry.valid else { return .invalid }
			guard let role = entry.role, let vaultId = entry.vaultId, let access = entry.access else { throw unreadable }
			return .account(Account(role: role, vaultId: vaultId, kind: entry.kind, part: entry.part, access: access))
		}
	}

	/// The feature marker's account name for `vaultId`.
	static func markerAccount(vaultId: String) throws(Failure) -> String {
		try accountNames([.init(role: .marker, vaultId: vaultId, kind: nil, part: nil)])[0]
	}

	struct AccountSpec: Encodable, Sendable {
		let role: Role
		let vaultId: String
		let kind: String?
		let part: Int?
	}

	static func accountNames(_ accounts: [AccountSpec]) throws(Failure) -> [String] {
		struct Request: Encodable { let accounts: [AccountSpec] }
		struct Response: Decodable { let names: [String] }
		let response: Response = try call(lpm_env_companion_account_names, Request(accounts: accounts))
		guard response.names.count == accounts.count else { throw unreadable }
		return response.names
	}

	static func assess(vaultId: String, _ observed: Observed) throws(Failure) -> Assessment {
		struct Request: Encodable {
			let vaultId: String
			let marker: Data?
			let inventory: [String]?
			let accessDamage: String?
		}
		return try call(lpm_env_companion_assess, Request(
			vaultId: vaultId,
			marker: observed.marker,
			inventory: observed.inventory,
			accessDamage: observed.accessDamage
		))
	}

	static func plan(
		_ action: PlanAction,
		vaultId: String,
		marker: Data?,
		inventory: [String],
		ownOperations: Int = 0,
		feature: String? = nil
	) throws(Failure) -> Plan {
		struct Request: Encodable {
			let action: PlanAction
			let vaultId: String
			let marker: Data?
			let inventory: [String]
			let ownOperations: Int
			let feature: String?
		}
		return try call(lpm_env_companion_plan, Request(
			action: action,
			vaultId: vaultId,
			marker: marker,
			inventory: inventory,
			ownOperations: ownOperations,
			feature: feature
		))
	}

	/// Checks one transaction before it commits, or when its committed
	/// journal is replayed. `markers` holds each touched project's marker as
	/// the store holds it now, nil where it's absent; `names`, a names-only
	/// listing, adds the check that a marker change orphans no record.
	static func checkTransaction(
		_ changes: [Change],
		markers: [String: Data?],
		names: [String]? = nil
	) throws(Failure) {
		struct Request: Encodable {
			let changes: [Change]
			let markers: [String: Data?]
			let names: [String]?
		}
		struct Response: Decodable {}
		let _: Response = try call(lpm_env_companion_check_transaction, Request(changes: changes, markers: markers, names: names))
	}

	private struct EngineRefusal: Decodable {
		let code: String
		let message: String?
	}

	private static let maximumOutputBytes = 8 * 1024 * 1024
	private static let unreadable = Failure(code: "env.engine_internal", message: "The LPM engine returned an unreadable answer.")

	private static func call<Request: Encodable, Response: Decodable>(
		_ function: (UnsafePointer<UInt8>?, Int) -> LPMEnvResult,
		_ request: Request
	) throws(Failure) -> Response {
		guard lpm_env_abi_version() == 1 else {
			throw Failure(code: "env.abi_mismatch", message: "The bundled LPM engine is not the version this app expects.")
		}
		let input: Data
		do { input = try JSONEncoder().encode(request) } catch { throw Failure(code: "companion.invalid_input", message: "The request couldn't be encoded.") }
		let result = input.withUnsafeBytes { bytes in
			function(bytes.bindMemory(to: UInt8.self).baseAddress, input.count)
		}
		defer { lpm_env_release(result) }
		guard let data = result.data, result.length > 0, result.length <= maximumOutputBytes else { throw unreadable }
		let output = Data(bytes: data, count: result.length)
		if result.status == 0 {
			do { return try JSONDecoder().decode(Response.self, from: output) } catch { throw unreadable }
		}
		guard let refusal = try? JSONDecoder().decode(EngineRefusal.self, from: output) else { throw unreadable }
		throw Failure(code: refusal.code, message: refusal.message ?? "The LPM engine failed (\(refusal.code)).")
	}
}
