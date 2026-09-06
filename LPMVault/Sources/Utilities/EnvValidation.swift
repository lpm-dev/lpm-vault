import Foundation

/// Shared write-boundary validation matching the Rust client contracts.
enum EnvValidation {
	static let maximumProjectNameLength = 120
	static let maximumProjectNameUTF16Length = 200

	private struct EnvironmentsWrapper: Codable {
		let environments: [String: [String: String]]
	}
	struct MergeResult {
		let environments: [String: [String: String]]
		let keyCount: Int
	}
	struct ValidatedRemoteEnvironments {
		let environments: [String: [String: String]]
		let keyCount: Int
	}

	enum PayloadError: LocalizedError {
		case invalidFormat
		case invalidNames

		var errorDescription: String? {
			switch self {
			case .invalidFormat:
				"Cloud env project data has an unsupported format."
			case .invalidNames:
				"Cloud env project contains environment or variable names that do not match the LPM format."
			}
		}
	}

	static func isValidVariableName(_ name: String) -> Bool {
		guard let first = name.utf8.first,
			isASCIIAlpha(first) || first == 95
		else { return false }

		return name.utf8.dropFirst().allSatisfy {
			isASCIIAlpha($0) || isASCIIDigit($0) || $0 == 95
		}
	}

	/// Returns the existing key that differs from `name` only by ASCII case.
	/// Variable names are ASCII-only, so lowercasing is deterministic here.
	static func caseInsensitiveCollision(
		for name: String,
		in existingNames: some Sequence<String>
	) -> String? {
		let foldedName = name.lowercased()
		return existingNames.first {
			$0 != name && $0.lowercased() == foldedName
		}
	}

	static func firstCaseInsensitiveCollision(
		in names: some Sequence<String>
	) -> (first: String, second: String)? {
		var namesByFoldedValue: [String: String] = [:]
		for name in names.sorted() {
			let foldedName = name.lowercased()
			if let existing = namesByFoldedValue[foldedName], existing != name {
				return (existing, name)
			}
			namesByFoldedValue[foldedName] = name
		}
		return nil
	}

	static func isValidEnvironmentName(_ name: String) -> Bool {
		guard !name.isEmpty, name.utf8.count <= 64, name != "__index__" else { return false }
		guard !name.contains("..") else { return false }

		return name.utf8.allSatisfy {
			isASCIIAlpha($0)
				|| isASCIIDigit($0)
				|| $0 == 45
				|| $0 == 95
				|| $0 == 46
		}
	}

	static func normalizedProjectName(_ name: String) -> String? {
		let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !normalized.isEmpty,
			normalized.count <= maximumProjectNameLength,
			normalized.utf16.count <= maximumProjectNameUTF16Length,
			!normalized.unicodeScalars.contains(where: isRegistryForbiddenControl)
		else {
			return nil
		}
		return normalized
	}

	private static func isRegistryForbiddenControl(_ scalar: Unicode.Scalar) -> Bool {
		scalar.value <= 0x1F || (0x7F ... 0x9F).contains(scalar.value)
	}

	/// Mirrors the Rust client's portable vault ID boundary.
	static func isSafeVaultId(_ id: String) -> Bool {
		guard !id.isEmpty, id.utf8.count <= 128,
			id != ".", id != "..", !id.hasPrefix("~"), !id.hasPrefix("__"),
			!id.contains("..")
		else { return false }
		return !id.unicodeScalars.contains { scalar in
			CharacterSet.controlCharacters.contains(scalar)
				|| scalar == "/" || scalar == "\\" || scalar == ":" || scalar.value == 0
		}
	}

	static func isSafeOrgSlug(_ slug: String) -> Bool {
		guard !slug.isEmpty, slug.utf8.count <= 120,
			let first = slug.utf8.first, isASCIIAlpha(first) || isASCIIDigit(first)
		else { return false }
		return slug.utf8.allSatisfy {
			isASCIIAlpha($0) || isASCIIDigit($0) || $0 == 45 || $0 == 95
		}
	}

	static func areValidEnvironments(_ environments: [String: [String: String]]) -> Bool {
		environments.allSatisfy { environment, secrets in
			isValidEnvironmentName(environment)
				&& secrets.keys.allSatisfy(isValidVariableName)
		}
	}

	static func encodedVaultSize(_ environments: [String: [String: String]]) -> Int? {
		try? JSONEncoder().encode(EnvironmentsWrapper(environments: environments)).count
	}

	static func decodeRemoteEnvironments(_ data: Data) throws -> ValidatedRemoteEnvironments {
		do {
			try StrictJSONKeyValidator.validate(data)
			guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
				Set(object.keys) == ["environments"]
			else { throw PayloadError.invalidFormat }
			let decoded = try JSONDecoder().decode(EnvironmentsWrapper.self, from: data)
			let remoteEnvironments = decoded.environments.isEmpty
				? ["default": [:]]
				: decoded.environments
			guard areValidEnvironments(remoteEnvironments) else {
				throw PayloadError.invalidNames
			}
			return ValidatedRemoteEnvironments(
				environments: remoteEnvironments,
				keyCount: remoteEnvironments.values.reduce(0) { $0 + $1.count }
			)
		} catch let error as PayloadError {
			throw error
		} catch {
			throw PayloadError.invalidFormat
		}
	}

	static func mergeRemotePayload(
		_ data: Data,
		into localEnvironments: [String: [String: String]]
	) throws -> MergeResult {
		let remoteEnvironments = try decodeRemoteEnvironments(data)
		return try mergeRemoteEnvironments(remoteEnvironments, into: localEnvironments)
	}

	static func mergeRemoteEnvironments(
		_ remote: ValidatedRemoteEnvironments,
		into localEnvironments: [String: [String: String]]
	) throws -> MergeResult {
		guard areValidEnvironments(localEnvironments) else { throw PayloadError.invalidNames }
		guard !localEnvironments.isEmpty else {
			return MergeResult(
				environments: remote.environments,
				keyCount: remote.keyCount
			)
		}
		var mergedEnvironments = localEnvironments
		for (environment, remoteSecrets) in remote.environments {
			var mergedSecrets = mergedEnvironments[environment] ?? [:]
			mergedSecrets.merge(remoteSecrets) { _, remote in remote }
			mergedEnvironments[environment] = mergedSecrets
		}
		return MergeResult(environments: mergedEnvironments, keyCount: remote.keyCount)
	}

	private static func isASCIIAlpha(_ byte: UInt8) -> Bool {
		(byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122)
	}

	private static func isASCIIDigit(_ byte: UInt8) -> Bool {
		byte >= 48 && byte <= 57
	}
}

enum VaultProjectRenamePolicy {
	static func normalizedName(_ draft: String) -> String? {
		EnvValidation.normalizedProjectName(draft)
	}
}
