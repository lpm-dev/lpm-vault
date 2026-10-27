import Foundation
import Testing

@testable import LPMVault

@Suite("Characters in values that are hard to see")
struct ValueCharacterEngineTests {
	@Test("the bundled engine flags hidden characters without a schema and never returns values")
	func engineChecksWithoutSchema() throws {
		let check = try #require(RustSchemaEngine.checkCharacters([
			"default": ["API_KEY": "sk_\u{200B}live", "CLEAN": "fixture", "PEM": "a\nb\n"],
			"production": ["URL": "https://example.com \n"],
			"staging": ["OK": "fine"],
		]))
		#expect(check.environments.keys.sorted() == ["default", "production"], "environments without findings are left out")
		let key = try #require(check.characters(of: "API_KEY", in: "default"))
		#expect(key.characters == [.init(kind: .invisible, escape: "\\u{200b}", name: "ZERO WIDTH SPACE", count: 1,
			runs: [.init(position: 4, count: 1)])])
		#expect(key.removable && !key.trimmable)
		#expect(check.characters(of: "CLEAN", in: "default") == nil)
		#expect(check.characters(of: "PEM", in: "default") == nil, "a multiline value's final newline is text")
		let url = try #require(check.characters(of: "URL", in: "production"))
		#expect(url.characters.map(\.kind) == [.trailingWhitespace, .trailingWhitespace])
		#expect(url.characters.map(\.escape) == ["\\u{20}", "\\n"])
		#expect(!url.removable && url.trimmable)
		#expect(check.valueCount == 2)
	}

	@Test("characters that can spell out hidden text are reported as a group without escapes")
	func groupsHaveNoEscape() throws {
		let check = try #require(RustSchemaEngine.checkCharacters(["default": ["TOKEN": "ok\u{E0068}\u{E0069}"]]))
		let found = try #require(check.characters(of: "TOKEN", in: "default"))
		#expect(found.characters == [.init(kind: .invisible, escape: nil, name: "tag characters", count: 2, runs: [.init(position: 3, count: 2)])])
	}

	@Test("the engine refuses a key that isn't a valid name")
	func invalidKeyIsRefused() {
		#expect(RustSchemaEngine.checkCharacters(["default": ["not a key": "x"]]) == nil)
		#expect(RustSchemaEngine.checkCharacters([:]) == ValueCharacterCheck())
	}

	@Test("showing a value marks each escape in UTF-16, after characters wider than one unit")
	func showMarksEscapes() throws {
		let shown = try #require(RustSchemaEngine.showCharacters(in: "😀a\u{200B}b "))
		#expect(shown.text == "😀a\\u{200b}b\\u{20}")
		#expect(shown.marks == [NSRange(location: 3, length: 8), NSRange(location: 12, length: 6)])
		let ns = shown.text as NSString
		#expect(shown.marks.map(ns.substring(with:)) == ["\\u{200b}", "\\u{20}"])
	}

	@Test("the fixes remove hidden characters or trim the ends, and nothing else")
	func fixes() {
		let value = " a\u{200B}b\u{A0}c\r\n"
		#expect(RustSchemaEngine.fixCharacters(in: value, .removeHiddenCharacters) == " ab c\r\n")
		#expect(RustSchemaEngine.fixCharacters(in: value, .trimEnds) == "a\u{200B}b\u{A0}c")
		#expect(RustSchemaEngine.fixCharacters(in: "", .trimEnds) == "")
		#expect(RustSchemaEngine.fixCharacters(in: "line one\r\nline two\r\n", .removeHiddenCharacters) == "line one\nline two\n")
	}
}

@Suite("Value character checker")
struct ValueCharacterCheckerTests {
	/// The real engine, counting the values each call sends it.
	final class CountingEngine: @unchecked Sendable {
		private let lock = NSLock()
		private var sent: [Int] = []
		var calls: [Int] { lock.withLock { sent } }

		var engine: ValueCharacterChecker.Engine {
			{ environments in
				self.lock.withLock { self.sent.append(environments.values.reduce(0) { $0 + $1.count }) }
				return RustSchemaEngine.checkCharacters(environments)
			}
		}
	}

	@Test("a check sends the engine only the values that changed since the check it starts from")
	func sendsOnlyChangedValues() async throws {
		let counter = CountingEngine()
		let checker = ValueCharacterChecker(engine: counter.engine)
		var environments = ["default": ["A": "a\u{200B}", "B": "b", "C": "c"], "staging": ["A": "fine"]]
		let first = try #require(await checker.check(environments, since: nil))
		#expect(first.check.characters(of: "A", in: "default")?.characters.first?.name == "ZERO WIDTH SPACE")
		environments["default"]?["B"] = "b\u{A0}"
		let second = try #require(await checker.check(environments, since: first))
		#expect(second.check.characters(of: "A", in: "default") != nil, "an unchanged value keeps its finding")
		#expect(second.check.characters(of: "B", in: "default")?.characters.first?.name == "NO-BREAK SPACE")
		environments["default"]?["A"] = nil
		let third = try #require(await checker.check(environments, since: second))
		#expect(third.check.characters(of: "A", in: "default") == nil, "a removed key has no finding")
		#expect(counter.calls == [4, 1], "the third check sent nothing")
		#expect(third.characters(of: "B", in: "default", whileItIs: "b\u{A0}") != nil)
		#expect(third.characters(of: "B", in: "default", whileItIs: "b") == nil, "a finding stands only for the value it was found in")
	}

	@Test("values are compared byte for byte, so a canonically equivalent value is checked again")
	func canonicalEquivalentsAreChecked() async throws {
		let counter = CountingEngine()
		let checker = ValueCharacterChecker(engine: counter.engine)
		let first = await checker.check(["default": ["NAME": "\u{2000}"]], since: nil)
		let second = try #require(await checker.check(["default": ["NAME": "\u{2002}"]], since: first))
		#expect(counter.calls == [1, 1])
		#expect(second.check.characters(of: "NAME", in: "default")?.characters.first?.name == "EN SPACE")
	}

	@Test("exact text tells apart values Swift calls equal, such as an en quad and an en space")
	func exactText() {
		#expect("a\u{2000}b" == "a\u{2002}b", "Swift compares by canonical equivalence")
		#expect(ExactText("a\u{2000}b") != ExactText("a\u{2002}b"))
		#expect(ExactText("same") == ExactText("same"))
	}

	@Test("a refused check returns nothing, and the next one can start from the last that succeeded")
	func refusedCheck() async throws {
		let checker = ValueCharacterChecker()
		let first = await checker.check(["default": ["A": "a\u{200B}"]], since: nil)
		#expect(await checker.check(["default": ["A": "a\u{200B}", "bad key": "x"]], since: first) == nil)
		let again = try #require(await checker.check(["default": ["A": "a\u{200B}"]], since: first))
		#expect(again.check.characters(of: "A", in: "default") != nil)
	}

	@Test("inspecting values shows only those that hold hidden characters")
	func inspectValues() async throws {
		let checker = ValueCharacterChecker()
		let inspections = try #require(await checker.inspect(values: ["A": "a\u{200B}", "B": "fine"]))
		#expect(inspections.keys.sorted() == ["A"])
		#expect(inspections["A"]?.shown?.text == "a\\u{200b}")
		let one = try #require(await checker.inspect("x\u{2060}"))
		#expect(one.isOf("x\u{2060}") && !one.isOf("x"))
		#expect(one.found?.characters.first?.name == "WORD JOINER")
		#expect(try #require(await checker.inspect("plain")).found == nil)
	}
}

@Suite("Value character wording")
struct ValueCharacterWordingTests {
	private func character(_ kind: ValueCharacters.Kind, escape: String? = "\\u{200b}", name: String = "ZERO WIDTH SPACE",
		count: Int = 1, runs: [ValueCharacters.Run] = [.init(position: 9, count: 1)]) -> ValueCharacters.Character
	{
		.init(kind: kind, escape: escape, name: name, count: count, runs: runs)
	}

	@Test("a character says what it is and where, in symbols on screen and in words for VoiceOver")
	func shownAndSpoken() {
		let single = character(.invisible)
		#expect(ValueCharacterWording.line(single) == "\\u{200b} zero width space at character 9")
		#expect(ValueCharacterWording.spoken(single) == "zero width space at character 9")
		let runs = character(.space, escape: "\\u{a0}", name: "NO-BREAK SPACE", count: 3, runs: [.init(position: 2, count: 2), .init(position: 7, count: 1)])
		#expect(ValueCharacterWording.line(runs) == "\\u{a0} no-break space ×3 at characters 2–3, 7")
		#expect(ValueCharacterWording.spoken(runs) == "no-break space, 3 times, at characters 2 to 3, 7")
		let unlisted = character(.invisible, count: 20, runs: [.init(position: 2, count: 1)])
		#expect(ValueCharacterWording.place(unlisted) == "at characters 2, …")
		#expect(ValueCharacterWording.place(unlisted, spoken: true) == "at characters 2, and more")
		let ends = character(.trailingWhitespace, escape: "\\u{20}", name: "SPACE", count: 2, runs: [.init(position: 5, count: 2)])
		#expect(ValueCharacterWording.line(ends) == "\\u{20} space ×2 at the end")
		#expect(ValueCharacterWording.place(character(.leadingWhitespace)) == "at the start")
		let group = character(.invisible, escape: nil, name: "tag characters", count: 3, runs: [.init(position: 3, count: 3)])
		#expect(ValueCharacterWording.line(group) == "tag characters ×3 at characters 3–5")
	}

	@Test("a warning's sentence names whose value it is and counts what wasn't listed")
	func sentence() {
		let found = ValueCharacters(characters: [character(.invisible)], more: 2, removable: true, trimmable: false)
		#expect(ValueCharacterWording.sentence(found, subject: "the value in production")
			== "Warning: the value in production has hidden characters: zero width space at character 9; 2 more kinds of character.")
	}
}

@Suite("Value characters in the store", .serialized)
@MainActor
struct ValueCharacterStoreTests {
	private func makeStore(_ environments: [String: [String: String]], engine: ValueCharacterChecker.Engine? = nil)
		async throws -> (VaultStore, MockKeychainService)
	{
		let keychain = MockKeychainService()
		keychain.envStorage["p"] = (name: "Project", path: "", environments: environments)
		let store = VaultStore(keychainService: keychain, biometricService: MockBiometricService(), apiService: MockAPIService(),
			authTokenProvider: { _, _ in nil }, characterEngine: engine)
		store.isUnlocked = true
		#expect(await store.loadProjects())
		store.isUnlocked = true
		#expect(await store.openProjectForSaving("p", timeout: testWaitLimit))
		return (store, keychain)
	}

	private func target() -> VaultEnvironmentTarget { VaultEnvironmentTarget(projectId: "p", environment: "default") }

	@Test("stored values are checked whatever the project's rules, and checked again when they change")
	func storedValuesAreChecked() async throws {
		let (store, _) = try await makeStore(["default": ["TOKEN": "fixture\u{FEFF}", "CLEAN": "fixture"]])
		defer { store.lock() }
		#expect(try await waitUntil { store.valueCharacters(of: "TOKEN", in: "default", projectID: "p") != nil })
		#expect(store.valueCharacters(of: "CLEAN", in: "default", projectID: "p") == nil)
		#expect(store.keyDescriptions["p"]?.schema?.overview == nil, "the project has no rules")
		_ = await store.addSecret(to: "p", environments: ["default"], key: "NEW", value: "\u{2066}fixture")
		#expect(try await waitUntil { store.valueCharacters(of: "NEW", in: "default", projectID: "p") != nil })
		#expect(store.valueCharacters(of: "NEW", in: "default", projectID: "p")?.characters.first?.kind == .direction)
	}

	@Test("locking forgets every check, and the values each started from")
	func lockForgets() async throws {
		let (store, _) = try await makeStore(["default": ["TOKEN": "fixture\u{200B}"]])
		#expect(try await waitUntil { store.valueCharacters["p"] != nil })
		#expect(store.beginRawTextEdit(order: ["TOKEN"]))
		#expect(try await waitUntil { store.rawTextCharacterChecks.count == 1 })
		store.lock()
		#expect(store.valueCharacters.isEmpty)
		#expect(store.characterCheckBases.isEmpty)
		#expect(store.rawTextCharacterChecks.isEmpty)
	}

	/// An engine that holds every call until the test opens it.
	final class GatedEngine: @unchecked Sendable {
		private let condition = NSCondition()
		private var entered = 0
		private var isOpen = false

		var calls: Int {
			condition.lock()
			defer { condition.unlock() }
			return entered
		}

		var engine: ValueCharacterChecker.Engine {
			{ environments in
				self.condition.lock()
				self.entered += 1
				while !self.isOpen { self.condition.wait() }
				self.condition.unlock()
				return RustSchemaEngine.checkCharacters(environments)
			}
		}

		func open() {
			condition.lock()
			isOpen = true
			condition.broadcast()
			condition.unlock()
		}
	}

	@Test("a check still running when the vault locks keeps none of the values it was given")
	func checkRunningAtLockKeepsNothing() async throws {
		let gated = GatedEngine()
		let (store, _) = try await makeStore(["default": ["TOKEN": "fixture\u{200B}"]], engine: gated.engine)
		#expect(try await waitUntil { gated.calls == 1 })
		store.lock()
		gated.open()
		// The checker's queue runs this after the held checks, which have returned by then.
		_ = await store.characterChecker.inspect(values: [:])
		try await quietPeriod()
		#expect(store.characterCheckBases.isEmpty)
		#expect(store.valueCharacters.isEmpty)
	}

	@Test("a Raw text draft is checked as it's typed, sending only the values that changed")
	func rawTextChecksOnlyChangedValues() async throws {
		let counter = ValueCharacterCheckerTests.CountingEngine()
		let (store, _) = try await makeStore(["default": ["A": "1", "B": "2"]], engine: counter.engine)
		defer { store.lock() }
		#expect(store.beginRawTextEdit(order: ["A", "B"]))
		#expect(try await waitUntil { store.rawTextCharacterChecks[target()] != nil })
		store.updateRawTextDraft(target(), text: "A=1\nB=\"2\u{200B}\"\n")
		#expect(try await waitUntil { store.rawTextCharacters(target())["B"] != nil })
		#expect(store.rawTextCharacters(target())["A"] == nil)
		#expect(counter.calls.suffix(2) == [2, 1], "the edit sent only B, after the draft's first check of both")
	}

	@Test("fixing a Raw text draft rewrites only the lines whose values hold hidden characters")
	func rawTextFix() async throws {
		let (store, keychain) = try await makeStore(["default": ["A": "1", "B": "2"]])
		defer { store.lock() }
		#expect(store.beginRawTextEdit(order: ["A", "B"]))
		store.updateRawTextDraft(target(), text: "# keep\nA=1\nexport B=\"two\u{200B}\"\nC=\" three \"\n")
		#expect(try await waitUntil { store.rawTextCharacters(target()).keys.sorted() == ["B", "C"] })
		store.fixRawTextCharacters(target(), .removeHiddenCharacters)
		#expect(store.rawTextDraft(for: target())?.text == "# keep\nA=1\nB=two\nC=\" three \"\n")
		#expect(try await waitUntil { store.rawTextCharacters(target()).keys.sorted() == ["C"] })
		store.fixRawTextCharacters(target(), .trimEnds)
		#expect(store.rawTextDraft(for: target())?.text == "# keep\nA=1\nB=two\nC=three\n")
		#expect(try await waitUntil { store.rawTextCharacters(target()).isEmpty })
		#expect(keychain.envStorage["p"]?.environments["default"] == ["A": "1", "B": "2"], "a fix is an unsaved edit")
	}

	@Test("an import review reports the imported values that hold hidden characters, and which of them it writes")
	func importReviewCharacters() async throws {
		let (store, _) = try await makeStore(["default": ["KEPT": "old"]])
		defer { store.lock() }
		let imported = ImportedEnvFile(secrets: ["KEPT": "new\u{200B}", "NEW": "\u{3000}x", "CLEAN": "fine"])
		let review = try await store.prepareEnvImport(imported, from: .pastedText, to: "p", environment: "default").get()
		#expect(review.characters.keys.sorted() == ["KEPT", "NEW"])
		#expect(review.characters["NEW"]?.found?.characters.first?.name == "IDEOGRAPHIC SPACE")
		#expect(review.writtenKeys() == ["NEW", "CLEAN"])
		#expect(review.writtenKeys(replacing: ["KEPT"], skipping: ["NEW"]) == ["KEPT", "CLEAN"])
	}
}

@Suite("Raw text assignment spans")
struct RawTextSpanTests {
	@Test("a quoted value that spans lines is set by all of them, and replacing it rewrites them as one line")
	func spansAndReplacement() {
		let draft = VaultRawTextDraft(target: VaultEnvironmentTarget(projectId: "p", environment: "default"), baseline: [:], order: [])
		var edited = draft
		edited.text = "A=1\nPEM=\"line one\nline two\"\nB=2"
		#expect(edited.check.spans == ["A": 1...1, "PEM": 2...3, "B": 4...4])
		#expect(edited.text(replacing: ["PEM": "fixed"]) == "A=1\nPEM=fixed\nB=2")
		#expect(edited.text(replacing: ["A": "one two", "B": ""]) == "A=\"one two\"\nPEM=\"line one\nline two\"\nB=")
	}
}

@Suite("Dotenv syntax trims only spaces and tabs")
struct DotenvBlankTests {
	private static let text = "\u{FEFF}FIRST=one\n\t PADDED = two \t\r\nNBSP=three\u{A0}\nZWSP=\u{200B}four\u{200B}\nWIDE=\u{3000}five\u{3000}\nFEED=six\u{C}\n"
	private static let values = ["FIRST": "one", "PADDED": "two", "NBSP": "three\u{A0}", "ZWSP": "\u{200B}four\u{200B}",
		"WIDE": "\u{3000}five\u{3000}", "FEED": "six\u{C}"]

	@Test("an import keeps characters that look blank at the ends of unquoted values, as the LPM CLI does")
	func importKeepsThem() async throws {
		let service = EnvFileImportService()
		#expect(try await service.load(.text(Self.text)).secrets == Self.values)
	}

	@Test("Raw text reads values as an import does")
	func rawTextKeepsThem() {
		let check = VaultEnvTextCheck(Self.text)
		#expect(check.values == Self.values)
		#expect(check.problems.isEmpty)
	}

	@Test("one assignment parses the same however its lines end")
	func lineEndings() throws {
		#expect(try EnvFileCodec.parse("A=1\r\nB= two \r\n") == ["A": "1", "B": "two"])
	}

	@Test("a key that starts with a character that looks blank isn't a valid name")
	func blankLookingKey() async throws {
		let service = EnvFileImportService()
		await #expect(throws: EnvFileImportError.invalidVariableName(line: 2)) { try await service.load(.text("OK=1\n\u{A0}KEY=value\n")) }
		#expect(VaultEnvTextCheck("OK=1\n\u{A0}KEY=value\n").problems.map(\.line) == [2])
	}

	@Test("a byte order mark counts only at the start of the text")
	func byteOrderMarkOnlyAtTheStart() async throws {
		let service = EnvFileImportService()
		await #expect(throws: EnvFileImportError.invalidVariableName(line: 2)) { try await service.load(.text("A=1\n\u{FEFF}B=2\n")) }
		#expect(try EnvFileCodec.parse("A=\u{FEFF}x\n") == ["A": "\u{FEFF}x"])
		#expect(VaultEnvTextCheck("A=1\n\u{FEFF}B=2\n").problems.map(\.line) == [2])
		let multiline = try await service.load(.text("\u{FEFF}PEM=\"one\n\u{FEFF}two\"\n"))
		#expect(multiline.secrets == ["PEM": "one\n\u{FEFF}two"], "A value's own line keeps the mark it starts with")
	}
}
