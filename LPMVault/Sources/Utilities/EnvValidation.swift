import Foundation

/// Shared write-boundary validation matching the Rust client contracts.
enum EnvValidation {
	struct MergeResult {
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

	static func mergeRemotePayload(
		_ data: Data,
		into localEnvironments: [String: [String: String]]
	) throws -> MergeResult {
		guard areValidEnvironments(localEnvironments) else { throw PayloadError.invalidNames }

		if let wrapper = try? JSONDecoder().decode(
			[String: [String: [String: String]]].self,
			from: data
		), let remoteEnvironments = wrapper["environments"] {
			guard areValidEnvironments(remoteEnvironments) else { throw PayloadError.invalidNames }
			var mergedEnvironments = localEnvironments
			var keyCount = 0
			for (environment, remoteSecrets) in remoteEnvironments {
				var mergedSecrets = mergedEnvironments[environment] ?? [:]
				mergedSecrets.merge(remoteSecrets) { _, remote in remote }
				mergedEnvironments[environment] = mergedSecrets
				keyCount += mergedSecrets.count
			}
			guard areValidEnvironments(mergedEnvironments) else { throw PayloadError.invalidNames }
			return MergeResult(environments: mergedEnvironments, keyCount: keyCount)
		}

		if let remoteSecrets = try? JSONDecoder().decode([String: String].self, from: data) {
			guard remoteSecrets.keys.allSatisfy(isValidVariableName) else {
				throw PayloadError.invalidNames
			}
			var mergedEnvironments = localEnvironments
			var defaultSecrets = mergedEnvironments["default"] ?? [:]
			defaultSecrets.merge(remoteSecrets) { _, remote in remote }
			mergedEnvironments["default"] = defaultSecrets
			guard areValidEnvironments(mergedEnvironments) else { throw PayloadError.invalidNames }
			return MergeResult(environments: mergedEnvironments, keyCount: defaultSecrets.count)
		}

		throw PayloadError.invalidFormat
	}

	private static func isASCIIAlpha(_ byte: UInt8) -> Bool {
		(byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122)
	}

	private static func isASCIIDigit(_ byte: UInt8) -> Bool {
		byte >= 48 && byte <= 57
	}
}
