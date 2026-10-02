import Foundation

/// Formats that the secret editors can generate locally.
enum SecretValueKind: String, CaseIterable, Identifiable, Sendable {
	case base64
	case hex
	case uuid
	case alphanumeric
	case password

	var id: String { rawValue }

	/// Whether the generated value takes a length, and what that length counts.
	var lengthUnit: SecretValueLengthUnit? {
		switch self {
		case .base64, .hex: .bytes
		case .alphanumeric, .password: .characters
		case .uuid: nil
		}
	}
}

enum SecretValueLengthUnit: Sendable {
	case bytes
	case characters

	var label: String {
		switch self {
		case .bytes: "bytes"
		case .characters: "characters"
		}
	}
}

enum SecretValueGenerator {
	static let defaultLength = 32
	static let presetLengths = [16, 32, 64]
	static let additionalLengths = [8, 12, 20, 24, 48, 96, 128]
	static let lengthRange = 1...128

	static let alphanumericCharacters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
	/// Symbols that survive unquoted `.env` parsing and shell pasting: no quotes,
	/// `#`, `$`, backslashes, spaces, or glob characters.
	static let passwordSymbols = Array("-_.~+=@%^")

	private static let lowercase = Array("abcdefghijklmnopqrstuvwxyz")
	private static let uppercase = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
	private static let digits = Array("0123456789")

	static func generate(_ kind: SecretValueKind, length: Int) -> String {
		var generator = SystemRandomNumberGenerator()
		return generate(kind, length: length, using: &generator)
	}

	/// Generates a value with `generator`. The app passes the system CSPRNG;
	/// tests pass a seeded generator.
	static func generate<G: RandomNumberGenerator>(
		_ kind: SecretValueKind,
		length: Int,
		using generator: inout G
	) -> String {
		let length = min(max(length, lengthRange.lowerBound), lengthRange.upperBound)
		switch kind {
		case .base64:
			return Data(randomBytes(count: length, using: &generator)).base64EncodedString()
		case .hex:
			return hexString(randomBytes(count: length, using: &generator))
		case .uuid:
			return uuidV4(using: &generator)
		case .alphanumeric:
			return String((0..<length).map { _ in pick(from: alphanumericCharacters, using: &generator) })
		case .password:
			return password(length: length, using: &generator)
		}
	}

	private static func pick<G: RandomNumberGenerator>(from characters: [Character], using generator: inout G) -> Character {
		characters[Int.random(in: characters.indices, using: &generator)]
	}

	private static func randomBytes<G: RandomNumberGenerator>(count: Int, using generator: inout G) -> [UInt8] {
		(0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
	}

	private static func hexString(_ bytes: [UInt8]) -> String {
		let digits = Array("0123456789abcdef".utf8)
		var output = [UInt8]()
		output.reserveCapacity(bytes.count * 2)
		for byte in bytes {
			output.append(digits[Int(byte >> 4)])
			output.append(digits[Int(byte & 0x0F)])
		}
		return String(decoding: output, as: UTF8.self)
	}

	private static func uuidV4<G: RandomNumberGenerator>(using generator: inout G) -> String {
		var bytes = randomBytes(count: 16, using: &generator)
		bytes[6] = (bytes[6] & 0x0F) | 0x40
		bytes[8] = (bytes[8] & 0x3F) | 0x80
		let hex = Array(hexString(bytes))
		return [0..<8, 8..<12, 12..<16, 16..<20, 20..<32]
			.map { String(hex[$0]) }
			.joined(separator: "-")
	}

	/// Includes at least one lowercase letter, uppercase letter, digit, and
	/// symbol when the length allows, then shuffles so their positions are random.
	private static func password<G: RandomNumberGenerator>(length: Int, using generator: inout G) -> String {
		let classes = [lowercase, uppercase, digits, passwordSymbols]
		let allCharacters = classes.flatMap { $0 }
		var characters = classes.prefix(length).map { pick(from: $0, using: &generator) }
		while characters.count < length {
			characters.append(pick(from: allCharacters, using: &generator))
		}
		characters.shuffle(using: &generator)
		return String(characters)
	}
}
