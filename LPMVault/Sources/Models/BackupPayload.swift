import Foundation

/// What a backup holds, in the payload format the LPM CLI shares
/// (lpm-env-backup's version 1). Its JSON is measured first, then written
/// once into bytes of exactly its size that the app zeroes, so no copy of the
/// values it carries is left behind in memory that was freed.
struct BackupPayload: Sendable {
	static let producerName = "LPM Vault"
	/// The longest producer name or version, as the format allows.
	static let maximumLabelBytes = 64
	static let maximumDeviceNameBytes = 256
	static let maximumPrincipalBytes = 256

	struct Project: Sendable {
		let vaultId: String
		/// The vault ID for a project removed from the sidebar, whose name went with it.
		let name: String
		let folder: String?
		let hidden: Bool
		let cliAccess: VaultCliAccess
		let environments: [String: [String: String]]
		let sync: Sync?
	}

	/// Where a project syncs, as the CLI's sync bindings hold it.
	struct Sync: Equatable, Sendable {
		enum Scope: Equatable, Sendable {
			case personal
			case organization(slug: String)
		}

		let registry: String
		let principalId: String
		let scope: Scope
	}

	let createdAt: Date
	let producerVersion: String
	let deviceName: String?
	let projects: [Project]
	/// LPM Vault's own section.
	let app: BackupAppSection?

	/// A payload's JSON, and where each project's object starts in it, so a
	/// problem the engine finds at an offset can name its project.
	struct Encoded: Sendable {
		let bytes: SecretBytes
		/// Each project's first byte, in order.
		let projectOffsets: [Int]

		/// The index of the project whose object holds `offset`, if one does.
		func project(at offset: Int) -> Int? {
			var lower = 0
			var upper = projectOffsets.count
			while lower < upper {
				let middle = (lower + upper) / 2
				if projectOffsets[middle] <= offset { lower = middle + 1 } else { upper = middle }
			}
			return lower == 0 ? nil : lower - 1
		}
	}

	/// The payload's JSON, or nil when the app section can't be written.
	func encoded() -> Encoded? {
		let app: Data?
		if let section = self.app {
			guard let json = section.json(), let data = try? json.compactData(maximumBytes: BackupEngine.maximumFileBytes) else {
				return nil
			}
			app = data
		} else {
			app = nil
		}
		var measure = Measure()
		write(app: app, into: &measure)
		let bytes = SecretBytes(count: measure.count) { buffer in
			var output = Output(buffer: buffer)
			write(app: app, into: &output)
			precondition(output.offset == buffer.count, "a payload is written to the length it was measured at")
		}
		return Encoded(bytes: bytes, projectOffsets: measure.projectOffsets)
	}

	/// Whether `text` is a label the format accepts where it defines one: not
	/// empty, at most `maximumBytes`, without controls or the characters that
	/// change the direction text runs in.
	static func isLabel(_ text: String, maximumBytes: Int) -> Bool {
		!text.isEmpty && text.utf8.count <= maximumBytes
			&& !text.unicodeScalars.contains { scalar in
				scalar.properties.generalCategory == .control || isDirectionControl(scalar)
			}
	}

	private static func isDirectionControl(_ scalar: Unicode.Scalar) -> Bool {
		switch scalar.value {
		case 0x061C, 0x200E, 0x200F, 0x202A...0x202E, 0x2066...0x2069: true
		default: false
		}
	}

	private func write<Sink: JSONSink>(app: Data?, into sink: inout Sink) {
		sink.raw("{\"createdAt\":")
		sink.raw(String(max(0, Int(createdAt.timeIntervalSince1970))))
		sink.raw(",\"producer\":{\"name\":")
		sink.string(Self.producerName)
		sink.raw(",\"version\":")
		sink.string(producerVersion)
		sink.raw("}")
		if let deviceName {
			sink.raw(",\"deviceName\":")
			sink.string(deviceName)
		}
		sink.raw(",\"projects\":[")
		for (index, project) in projects.enumerated() {
			if index > 0 { sink.raw(",") }
			sink.startProject()
			write(project, into: &sink)
		}
		sink.raw("]")
		if let app {
			sink.raw(",\"app\":")
			sink.bytes(app)
		}
		sink.raw("}")
	}

	private func write<Sink: JSONSink>(_ project: Project, into sink: inout Sink) {
		sink.raw("{\"vaultId\":")
		sink.string(project.vaultId)
		sink.raw(",\"name\":")
		sink.string(project.name)
		if let folder = project.folder {
			sink.raw(",\"folder\":")
			sink.string(folder)
		}
		sink.raw(project.hidden ? ",\"hidden\":true" : ",\"hidden\":false")
		sink.raw(project.cliAccess == .automatic ? ",\"cliAccess\":\"automatic\"" : ",\"cliAccess\":\"requireApproval\"")
		sink.raw(",\"environments\":{")
		for (index, environment) in project.environments.keys.sorted().enumerated() {
			if index > 0 { sink.raw(",") }
			sink.string(environment)
			sink.raw(":{")
			let values = project.environments[environment] ?? [:]
			for (position, key) in values.keys.sorted().enumerated() {
				if position > 0 { sink.raw(",") }
				sink.string(key)
				sink.raw(":")
				sink.string(values[key] ?? "")
			}
			sink.raw("}")
		}
		sink.raw("}")
		if let sync = project.sync {
			sink.raw(",\"sync\":{\"registry\":")
			sink.string(sync.registry)
			switch sync.scope {
			case .personal:
				sink.raw(",\"scope\":\"personal\"")
			case .organization:
				sink.raw(",\"scope\":\"organization\"")
			}
			sink.raw(",\"principalId\":")
			sink.string(sync.principalId)
			if case .organization(let slug) = sync.scope {
				sink.raw(",\"orgSlug\":")
				sink.string(slug)
			}
			sink.raw("}")
		}
		sink.raw("}")
	}
}

/// Where a payload's JSON goes: measured, then written.
private protocol JSONSink {
	mutating func byte(_ byte: UInt8)
	mutating func bytes(_ data: Data)
	/// Marks where the next project's object starts.
	mutating func startProject()
}

extension JSONSink {
	mutating func startProject() {}

	mutating func raw(_ text: String) {
		for byte in text.utf8 { self.byte(byte) }
	}

	/// `text` as a JSON string: quoted, with quotes, backslashes and control
	/// characters escaped, and everything else as its UTF-8.
	mutating func string(_ text: String) {
		byte(0x22)
		for byte in text.utf8 {
			switch byte {
			case 0x22: raw("\\\"")
			case 0x5C: raw("\\\\")
			case 0x08: raw("\\b")
			case 0x0C: raw("\\f")
			case 0x0A: raw("\\n")
			case 0x0D: raw("\\r")
			case 0x09: raw("\\t")
			case 0x00..<0x20:
				raw("\\u00")
				self.byte(Self.hexDigit(byte >> 4))
				self.byte(Self.hexDigit(byte & 0x0F))
			default: self.byte(byte)
			}
		}
		byte(0x22)
	}

	private static func hexDigit(_ value: UInt8) -> UInt8 {
		value < 10 ? 0x30 + value : 0x61 + value - 10
	}
}

private struct Measure: JSONSink {
	private(set) var count = 0
	private(set) var projectOffsets: [Int] = []

	mutating func byte(_ byte: UInt8) { count += 1 }
	mutating func bytes(_ data: Data) { count += data.count }
	mutating func startProject() { projectOffsets.append(count) }
}

private struct Output: JSONSink {
	let buffer: UnsafeMutableRawBufferPointer
	private(set) var offset = 0

	init(buffer: UnsafeMutableRawBufferPointer) {
		self.buffer = buffer
	}

	mutating func byte(_ byte: UInt8) {
		buffer[offset] = byte
		offset += 1
	}

	mutating func bytes(_ data: Data) {
		data.withUnsafeBytes { source in
			UnsafeMutableRawBufferPointer(rebasing: buffer[offset..<offset + source.count]).copyMemory(from: source)
		}
		offset += data.count
	}
}
