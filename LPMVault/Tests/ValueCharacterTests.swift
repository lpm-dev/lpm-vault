import Foundation
import Observation
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
		#expect(try await waitUntil { store.characterChecks["p"] != nil })
		#expect(store.beginRawTextEdit(order: ["TOKEN"]))
		#expect(try await waitUntil { store.rawTextCharacterChecks.count == 1 })
		store.lock()
		#expect(store.characterChecks.isEmpty)
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

		func close() {
			condition.lock()
			isOpen = false
			condition.unlock()
		}
	}

	@Test("a stored value's warning goes as soon as the value changes, before its new check returns")
	func storedWarningFollowsTheValue() async throws {
		let gated = GatedEngine()
		gated.open()
		let (store, _) = try await makeStore(["default": ["TOKEN": "fixture\u{200B}"]], engine: gated.engine)
		defer {
			gated.open()
			store.lock()
		}
		#expect(try await waitUntil { store.valueCharacters(of: "TOKEN", in: "default", projectID: "p") != nil })
		gated.close()
		let calls = gated.calls
		var project = try #require(store.projects.first)
		project.environments["default"]?["TOKEN"] = "clean"
		store.projects = [project]
		#expect(try await waitUntil { gated.calls > calls }, "the new check is held in the engine")
		#expect(store.valueCharacters(of: "TOKEN", in: "default", projectID: "p") == nil)
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
		#expect(store.characterChecks.isEmpty)
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

	@Test("Raw text warnings are worded with their check, follow an edit at once, and stay in line order")
	func rawTextWarningsFollowEdits() async throws {
		let gated = GatedEngine()
		gated.open()
		let (store, _) = try await makeStore(["default": ["A": "1"]], engine: gated.engine)
		defer {
			gated.open()
			store.lock()
		}
		#expect(store.beginRawTextEdit(order: ["A"]))
		store.updateRawTextDraft(target(), text: "C=\"\u{200B}c\"\nA=\"a \"\nB=\"b\u{200B}\"\n")
		#expect(try await waitUntil { store.rawTextCharacterWarnings[target()]?.lines.count == 3 })
		let warnings = try #require(store.rawTextCharacterWarnings[target()])
		#expect(warnings.lines.map(\.line) == [1, 2, 3])
		#expect(warnings.lines.map(\.reason) == [
			"C has hidden characters: zero width space at character 1", "A has hidden characters: space at the end",
			"B has hidden characters: zero width space at character 2",
		])
		#expect(warnings.pills.map(\.line) == [1, 2, 3])
		#expect(warnings.removable && warnings.trimmable)
		gated.close()
		store.updateRawTextDraft(target(), text: "A=\"a \"\nC=\"\u{200B}c\"\nB=\"b\"\n")
		let moved = try #require(store.rawTextCharacterWarnings[target()], "lines move with their keys before the next check")
		#expect(moved.lines.map(\.line) == [1, 2])
		#expect(moved.lines.map(\.reason).map { $0.prefix(1) } == ["A", "C"], "B's value changed, so its warning goes at once")
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

@Suite("Raw text warning wording")
struct RawTextWordingTests {
	@Test("a check words only the findings that changed, and keeps the wording of the rest")
	func wordsOnlyChangedFindings() async throws {
		let checker = ValueCharacterChecker()
		let environment = VaultRawTextCharacterCheck.environment
		let first = try #require(await checker.check([environment: ["A": "a\u{200B}", "B": "b\u{200B}"]], since: nil))
		let found = try #require(first.check.characters(of: "A", in: environment))
		let kept = VaultRawTextCharacterCheck.Wording(found: found, reason: "kept A", pill: "kept A pill")
		let previous = VaultRawTextCharacterCheck(checked: first, wording: ["A": kept])
		let second = try #require(await checker.check([environment: ["A": "a\u{200B}", "B": "\u{200B}b"]], since: first))
		let worded = VaultRawTextCharacterCheck(second, reusing: previous)
		#expect(worded.wording["A"]?.reason == "kept A", "an unchanged finding isn't worded again")
		#expect(worded.wording["B"]?.reason == "B has hidden characters: zero width space at character 1")
	}
}

@Suite("Lines on screen")
struct ProblemLineSearchTests {
	private func problems(_ lines: [Int]) -> [VaultEnvTextCheck.Problem] {
		lines.map { VaultEnvTextCheck.Problem(line: $0, reason: "r\($0)") }
	}

	@Test("the problems on the lines shown are found by binary search, whatever lies around them")
	func onLines() {
		let sorted = problems([2, 4, 4, 7, 9])
		#expect(sorted.on(1...1).isEmpty)
		#expect(sorted.on(2...2).map(\.line) == [2])
		#expect(sorted.on(3...7).map(\.line) == [4, 4, 7])
		#expect(sorted.on(8...100).map(\.line) == [9])
		#expect(sorted.on(10...20).isEmpty)
		#expect(sorted.on(1...9).count == 5)
		#expect(problems([]).on(1...5).isEmpty)
		let many = problems(Array(1...200_000))
		#expect(many.on(150_000...150_002).map(\.line) == [150_000, 150_001, 150_002])
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

@Suite("Values keep their exact characters")
struct ExactValueTests {
	private static let target = VaultEnvironmentTarget(projectId: "p", environment: "default")

	@Test("a fix in CRLF Raw text rewrites only the assignments it fixes, and keeps their line endings")
	func crlfFixKeepsOtherAssignments() {
		var draft = VaultRawTextDraft(target: Self.target, baseline: [:], order: [])
		draft.text = "A=\"x\u{200B}\"\r\nPEM=\"one\r\ntwo\u{200B}\"\r\nB=y\r\n"
		#expect(draft.text(replacing: ["A": "x"]) == "A=x\r\nPEM=\"one\r\ntwo\u{200B}\"\r\nB=y\r\n")
		#expect(draft.text(replacing: ["B": "z"]) == "A=\"x\u{200B}\"\r\nPEM=\"one\r\ntwo\u{200B}\"\r\nB=z\r\n")
		#expect(draft.text(replacing: ["PEM": "one\ntwo"]) == "A=\"x\u{200B}\"\r\nPEM=\"one\\ntwo\"\r\nB=y\r\n")
	}

	@Test("Raw text reads an edit that Swift calls equal but whose characters differ")
	func rawTextSeesCanonicallyEqualEdits() {
		var draft = VaultRawTextDraft(target: Self.target, baseline: ["A": "x\u{2000}y"], order: ["A"])
		draft.text = "A=x\u{2002}y\n"
		#expect(draft.check.values["A"].map(ExactText.init) == ExactText("x\u{2002}y"))
		#expect(draft.changes.changed == ["A"], "the edit is a change to save")
		#expect(VaultEnvChanges(from: ["A": "e\u{301}"], to: ["A": "\u{E9}"]).changed == ["A"])
	}

	@Test("an import replaces a value that Swift calls equal but whose characters differ")
	func importSeesCanonicallyEqualValues() throws {
		let project = VaultProject(id: "p", name: "P", path: "", environments: ["default": ["A": "x\u{2000}y", "B": "same"]])
		let review = try EnvFileImportReview(id: UUID(), project: project, environment: "default", source: .pastedText, sessionGeneration: 0,
			imported: ImportedEnvFile(secrets: ["A": "x\u{2002}y", "B": "same"]))
		#expect(review.changedKeys == ["A"])
		#expect(review.unchanged.map(\.key) == ["B"])
	}

	@Test("an inspector edit that Swift calls equal to the saved value is still an edit")
	func keyDraftSeesCanonicallyEqualEdits() {
		var field = VaultSecretEditDraft(value: "x\u{2000}y")
		field.draft = "x\u{2002}y"
		#expect(field.isDirty)
	}

	@Test("values compare byte for byte, keys and environments included")
	func valuesCompareByBytes() {
		#expect(["A": "x\u{2000}y"].isExactly(["A": "x\u{2000}y"]))
		#expect(!["A": "x\u{2000}y"].isExactly(["A": "x\u{2002}y"]))
		#expect(!["A": "e\u{301}"].isExactly(["A": "\u{E9}"]))
		#expect(!["A": "1"].isExactly(["A": "1", "B": "2"]))
		#expect(["default": ["A": "1"]].isExactly(["default": ["A": "1"]]))
		#expect(!["default": ["A": "x\u{2000}y"]].isExactly(["default": ["A": "x\u{2002}y"]]))
		#expect(!["caf\u{E9}": ["A": "1"]].isExactly(["cafe\u{301}": ["A": "1"]]))
		#expect(ExactText("") == ExactText(""))
		#expect(Set([ExactText("x\u{2000}y"), ExactText("x\u{2002}y"), ExactText("x\u{2000}y")]).count == 2)
		#expect(ExactText(String(repeating: "a", count: 4096) + "\u{2000}") != ExactText(String(repeating: "a", count: 4096) + "\u{2002}"))
	}

	@Test("a type that holds values is equal to another only when they hold the same characters")
	func typesHoldingValuesCompareByBytes() {
		let before = "x\u{2000}y", after = "x\u{2002}y"
		#expect(VaultProject(id: "p", name: "P", path: "", environments: ["default": ["A": before]])
			!= VaultProject(id: "p", name: "P", path: "", environments: ["default": ["A": after]]))
		#expect(ImportedEnvFile(secrets: ["A": before]) != ImportedEnvFile(secrets: ["A": after]))
		let receipt = EnvironmentChangeReceipt(projectId: "p", environment: "default", before: ["A": before], after: ["A": after])
		#expect(receipt.changed, "an import or a save that changed which characters a value holds can be undone")
		#expect(receipt != EnvironmentChangeReceipt(projectId: "p", environment: "default", before: ["A": before], after: ["A": before]))
		#expect(VaultKeyEdit(key: "A", environments: ["default": ["A": before]])
			!= VaultKeyEdit(key: "A", environments: ["default": ["A": after]]))
		#expect(VaultKeyEdit(key: "A", environments: [:], values: ["default": before])
			!= VaultKeyEdit(key: "A", environments: [:], values: ["default": after]))
		var edited = VaultSecretEditDraft(value: before)
		edited.draft = after
		#expect(edited != VaultSecretEditDraft(value: before))
		#expect(VaultEnvTextCheck("A=\(before)\n") != VaultEnvTextCheck("A=\(after)\n"))
		var draft = VaultRawTextDraft(target: Self.target, baseline: [:], order: [])
		let original = draft
		draft.text = "# \(after)\n"
		#expect(draft != original, "an edit to a comment is an edit too")
		var other = original
		other.text = "# \(before)\n"
		#expect(draft != other)
		#expect(ValueCharacterChecker.Inspection(value: "e\u{301}", found: nil, shown: nil)
			!= ValueCharacterChecker.Inspection(value: "\u{E9}", found: nil, shown: nil))
	}

	@Test("a key edit finds a value changed since it began, though Swift calls the two equal")
	func keyEditSeesCanonicallyEqualChange() {
		let edit = VaultKeyEdit(key: "A", environments: ["default": ["A": "x\u{2000}y"]], values: ["default": "new"])
		#expect(edit.applied(to: ["default": ["A": "x\u{2002}y"]]) == .failure(.changed))
	}

	@Test("values that differ between environments only in characters Swift calls equal drift")
	func driftSeesCanonicallyEqualValues() {
		let project = VaultProject(id: "p", name: "P", path: "", environments: [
			"default": ["A": "x\u{2000}y", "B": "same"], "staging": ["A": "x\u{2002}y", "B": "same"],
		])
		let snapshot = VaultWorkspaceSnapshot(project: project)
		#expect(snapshot.hasDrift(for: "A"))
		#expect(!snapshot.hasDrift(for: "B"))
	}
}

/// Every save and conflict check compares values byte for byte, since Swift
/// calls values equal that hold different characters, such as U+2000 and U+2002.
@Suite("Saves keep a value's exact characters", .serialized)
@MainActor
struct ExactValueSaveTests {
	private static let before = "x\u{2000}y"
	private static let after = "x\u{2002}y"

	private func makeStore(_ environments: [String: [String: String]], incoming: [String: String] = [:])
		async throws -> (VaultStore, MockKeychainService)
	{
		let importer = MockEnvFileImportService()
		await importer.setImmediateResult(.success(ImportedEnvFile(secrets: incoming)))
		let keychain = MockKeychainService()
		keychain.envStorage["p"] = (name: "Project", path: "", environments: environments)
		let store = VaultStore(keychainService: keychain, biometricService: MockBiometricService(), apiService: MockAPIService(),
			envFileImportService: importer, authTokenProvider: { _, _ in nil })
		store.isUnlocked = true
		#expect(await store.loadProjects())
		store.isUnlocked = true
		#expect(await store.openProjectForSaving("p", timeout: testWaitLimit))
		return (store, keychain)
	}

	private func stored(_ keychain: MockKeychainService, _ key: String = "A") -> ExactText? {
		keychain.envStorage["p"]?.environments["default"]?[key].map(ExactText.init)
	}

	private func shown(_ store: VaultStore, _ key: String = "A") -> ExactText? {
		store.projects.first?.environments["default"]?[key].map(ExactText.init)
	}

	private var target: VaultEnvironmentTarget { VaultEnvironmentTarget(projectId: "p", environment: "default") }

	@Test("an inspector save writes a value that Swift calls equal to the stored one")
	func inspectorSave() async throws {
		let (store, keychain) = try await makeStore(["default": ["A": Self.before]])
		defer { store.lock() }
		let project = try #require(store.projects.first)
		try await store.saveKeyEdit(VaultKeyEdit(key: "A", environments: project.environments, values: ["default": Self.after]), in: "p")
		#expect(stored(keychain) == ExactText(Self.after))
		#expect(shown(store) == ExactText(Self.after))
	}

	@Test("a Raw text save writes a value that Swift calls equal to the stored one, and undoing puts the old one back")
	func rawTextSave() async throws {
		let (store, keychain) = try await makeStore(["default": ["A": Self.before]])
		defer { store.lock() }
		#expect(store.beginRawTextEdit(order: ["A"]))
		store.updateRawTextDraft(target, text: "A=\(Self.after)\n")
		guard case .saved(let receipt) = await store.saveRawTextDraft(target) else {
			Issue.record("the edit wasn't saved")
			return
		}
		#expect(stored(keychain) == ExactText(Self.after))
		#expect(receipt.changed)
		#expect(await store.undoEnvironmentChange(receipt) == .saved)
		#expect(stored(keychain) == ExactText(Self.before))
	}

	@Test("a Raw text save finds a value the LPM CLI changed meanwhile, though Swift calls the two equal")
	func rawTextSaveSeesCLIChange() async throws {
		let (store, keychain) = try await makeStore(["default": ["A": Self.before, "B": "1"]])
		defer { store.lock() }
		#expect(store.beginRawTextEdit(order: ["A", "B"]))
		store.updateRawTextDraft(target, text: "A=\(Self.before)\nB=2\n")
		keychain.simulateCLISet(vaultId: "p", environment: "default", key: "A", value: Self.after)
		#expect(await store.saveRawTextDraft(target) == .changed)
		#expect(stored(keychain) == ExactText(Self.after), "the LPM CLI's value stays")
		#expect(stored(keychain, "B") == ExactText("1"))
	}

	@Test("a reviewed Raw text edit applies only to the text and the values it was made with, byte for byte")
	func rawTextReviewIsOfExactValues() async throws {
		let (store, keychain) = try await makeStore(["default": ["A": Self.before, "B": "1"]])
		defer { store.lock() }
		#expect(store.beginRawTextEdit(order: ["A", "B"]))
		store.updateRawTextDraft(target, text: "A=\(Self.before)\nB=2\n")
		let review = try #require(store.reviewRawTextDraft(target))
		store.updateRawTextDraft(target, text: "A=\(Self.after)\nB=2\n")
		#expect(await store.applyRawTextReview(review, skipping: []) == .unavailable, "the edit changed since it was reviewed")
		#expect(stored(keychain) == ExactText(Self.before))
	}

	@Test("an import replaces a value that Swift calls equal to the stored one, and can be undone")
	func importReplaces() async throws {
		let (store, keychain) = try await makeStore(["default": ["A": Self.before]], incoming: ["A": Self.after])
		defer { store.lock() }
		let file = URL(fileURLWithPath: "/tmp/dummy.env")
		let imported = try await store.loadEnvImport(.file(file), for: "p").get()
		let review = try await store.prepareEnvImport(imported, from: .file(file), to: "p", environment: "default").get()
		#expect(review.changedKeys == ["A"])
		let receipt = try await store.applyEnvFileImport(review, replacingKeys: ["A"]).get()
		#expect(stored(keychain) == ExactText(Self.after))
		#expect(receipt.changed)
	}

	@Test("an import finds a value the LPM CLI changed after the review, though Swift calls the two equal")
	func importSeesCLIChange() async throws {
		let (store, keychain) = try await makeStore(["default": ["A": Self.before]], incoming: ["A": "new", "B": "added"])
		defer { store.lock() }
		let file = URL(fileURLWithPath: "/tmp/dummy.env")
		let imported = try await store.loadEnvImport(.file(file), for: "p").get()
		let review = try await store.prepareEnvImport(imported, from: .file(file), to: "p", environment: "default").get()
		keychain.simulateCLISet(vaultId: "p", environment: "default", key: "A", value: Self.after)
		#expect(await store.applyEnvFileImport(review, replacingKeys: ["A"]) == .failure(.reviewChanged))
		#expect(stored(keychain) == ExactText(Self.after))
	}

	@Test("deleting a value finds it changed by the LPM CLI meanwhile, though Swift calls the two equal")
	func deleteSeesCLIChange() async throws {
		let (store, keychain) = try await makeStore(["default": ["A": Self.before, "B": "1"]])
		defer { store.lock() }
		keychain.simulateCLISet(vaultId: "p", environment: "default", key: "A", value: Self.after)
		store.deleteSecret(from: "p", environment: "default", key: "A")
		#expect(try await waitUntil { self.shown(store) != ExactText(Self.before) })
		#expect(stored(keychain) == ExactText(Self.after), "the LPM CLI's value isn't deleted")
		#expect(shown(store) == ExactText(Self.after), "the app shows the LPM CLI's value")
	}

	@Test("a project's values changing to characters Swift calls equal tell the views showing them")
	func projectsNotifyObservers() async throws {
		let (store, _) = try await makeStore(["default": ["A": Self.before]])
		defer { store.lock() }
		var project = try #require(store.projects.first)
		project.environments["default"]?["A"] = Self.after
		let notified = NotifiedFlag()
		withObservationTracking { _ = store.projects } onChange: { notified.set() }
		store.projects = [project]
		#expect(notified.isSet)
	}

	@Test("a pull finds a value changed here since the last sync, though Swift calls it equal to the remote one")
	func pullSeesLocalChange() async throws {
		let keychain = MockKeychainService()
		keychain.envStorage["p"] = (name: "Project", path: "", environments: ["default": ["A": Self.after]])
		let result = await VaultPersistenceCoordinator(service: keychain).commitPull(
			baseline: VaultProject(id: "p", name: "Project", path: "", environments: ["default": ["A": Self.before]]),
			remotePayload: Data(#"{"environments":{"default":{"A":"x\u2000y"}}}"#.utf8),
			action: "pull", version: 1,
			binding: SyncPrincipalBinding(registryURL: "https://lpm.dev", principalID: "user-1", scope: "personal"))
		guard case .conflict = result else {
			Issue.record("expected a conflict, got \(result)")
			return
		}
		#expect(stored(keychain) == ExactText(Self.after), "the change made here isn't overwritten")
	}

	final class NotifiedFlag: @unchecked Sendable {
		private let lock = NSLock()
		private var notified = false
		var isSet: Bool { lock.withLock { notified } }
		func set() { lock.withLock { notified = true } }
	}
}

@Suite("Dotenv syntax is read by scalar")
struct DotenvScalarTests {
	@Test("a hidden character next to a quote or a syntax space stays in the value, as the LPM CLI reads it")
	func hiddenCharacterNextToSyntax() async throws {
		let service = EnvFileImportService()
		let text = "CGJ=\"\u{34F}secret\"\nZWJ='\u{200D}x'\nSPACED= \u{34F}y\nCLOSE=\"z\u{34F}\"\n"
		let expected = ["CGJ": "\u{34F}secret", "ZWJ": "\u{200D}x", "SPACED": "\u{34F}y", "CLOSE": "z\u{34F}"]
		let imported = try await service.load(.text(text)).secrets
		#expect(imported.mapValues(ExactText.init) == expected.mapValues(ExactText.init))
		#expect(VaultEnvTextCheck(text).values.mapValues(ExactText.init) == expected.mapValues(ExactText.init))
	}

	@Test("a quoted value that spans lines keeps the blanks before its first line break")
	func multilineKeepsBlanks() async throws {
		let service = EnvFileImportService()
		let text = "DOUBLE=\"a  \nb\"\nSINGLE='c\t\nd'\n"
		let expected = ["DOUBLE": "a  \nb", "SINGLE": "c\t\nd"]
		#expect(try await service.load(.text(text)).secrets == expected)
		#expect(VaultEnvTextCheck(text).values == expected)
	}

	@Test("a carriage return that ends no CRLF stays in the value")
	func loneCarriageReturn() async throws {
		let service = EnvFileImportService()
		#expect(try await service.load(.text("KEY=value\r")).secrets == ["KEY": "value\r"])
		#expect(VaultEnvTextCheck("KEY=value\r").values == ["KEY": "value\r"])
		#expect(VaultEnvTextCheck("KEY=value\r\nB=1").values == ["KEY": "value", "B": "1"])
	}

	@Test("only spaces and tabs come off the start of a line, and a byte order mark only at the start of the file")
	func lineStarts() async throws {
		let service = EnvFileImportService()
		for text in ["\u{B}KEY=value\n", "\u{C}KEY=value\n", " \u{FEFF}KEY=value\n"] {
			await #expect(throws: EnvFileImportError.invalidVariableName(line: 1), "\(text.debugDescription)") {
				try await service.load(.text(text))
			}
		}
		#expect(try await service.load(.text("\u{FEFF}# a comment\nKEY=1\n")).secrets == ["KEY": "1"])
		#expect(try await service.load(.text("\u{FEFF}KEY=1\n")).secrets == ["KEY": "1"])
	}
}
