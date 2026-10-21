import Foundation
import Testing

@testable import LPMVault

@Suite("Raw text editing")
struct RawTextEditTests {
	private let target = VaultEnvironmentTarget(projectId: "p", environment: "default")

	@Test("an edit starts as a line for each key, with an empty line to add on, and nothing to save")
	func draftStartsUnchanged() {
		let baseline = ["B": "two words", "A": "1", "MULTI": "x\ny"]
		let draft = VaultRawTextDraft(target: target, baseline: baseline, order: ["A", "B", "MULTI"])
		#expect(draft.text == "A=1\nB=\"two words\"\nMULTI=\"x\\ny\"\n")
		#expect(draft.check.values == baseline)
		#expect(draft.check.problems.isEmpty)
		#expect(draft.check.lineCount == 4)
		#expect(draft.changes.count == 0 && draft.changes.unchanged == ["A", "B", "MULTI"])
		#expect(!draft.canSave)
	}

	@Test("every value reads back from its line exactly")
	func valuesRoundTrip() {
		let values = ["", "plain", " padded ", "a#b", "\"q\"", "'s'", "back\\slash", "$HOME", "`x`", "line\nbreak", "cr\rlf", "tab\tx",
			"naïve 🔑", "=lead", "https://x.dev/?a=1&b=2"]
		let baseline = Dictionary(uniqueKeysWithValues: values.enumerated().map { ("KEY_\($0.offset)", $0.element) })
		let draft = VaultRawTextDraft(target: target, baseline: baseline, order: baseline.keys.sorted())
		#expect(draft.check.values == baseline)
		#expect(draft.check.problems.isEmpty)
	}

	@Test("comments, blank lines and export are read as an import reads them, and a quoted value can span lines")
	func readsAsAnImport() {
		let check = VaultEnvTextCheck("""
			# a comment

			export TOKEN=abc
			  SPACED = value with spaces  \r
			QUOTED='single # kept'
			LONG="first
			second"
			AFTER=1
			""")
		#expect(check.values == ["TOKEN": "abc", "SPACED": "value with spaces", "QUOTED": "single # kept", "LONG": "first\nsecond", "AFTER": "1"])
		#expect(check.lines == ["TOKEN": 3, "SPACED": 4, "QUOTED": 5, "LONG": 6, "AFTER": 8])
		#expect(check.problems.isEmpty)
		#expect(check.lineCount == 8)
	}

	@Test("each line that can't be saved says why, by its line number, and a duplicate marks the line it repeats")
	func problems() {
		let check = VaultEnvTextCheck("""
			LOG_LEVEL=info
			stripe-webhook-secret=whsec
			just words
			=nothing
			LOG_LEVEL=debug
			log_level=other
			1ST=one
			OPEN="never closed
			TAIL=x
			""")
		#expect(check.problems.map(\.message) == [
			"Line 2: invalid key name — use letters, digits and _, not starting with a digit",
			"Line 3: not a KEY=value line",
			"Line 4: no key before =",
			"Line 5: duplicate of line 1",
			"Line 6: log_level differs from LOG_LEVEL on line 1 only in letter case",
			"Line 7: invalid key name — use letters, digits and _, not starting with a digit",
			"Line 8: its value's opening \" is never closed",
		])
		#expect(check.problemLines == [1, 2, 3, 4, 5, 6, 7, 8])
		#expect(check.values == ["LOG_LEVEL": "info"], "A line with a problem sets nothing, nor does what an open quote swallows")
	}

	@Test("an edit counts what it adds, changes and removes, and saves only once it changes a value and has no problem")
	func changes() {
		var draft = VaultRawTextDraft(target: target, baseline: ["KEEP": "1", "EDIT": "old", "DROP": "x"], order: ["DROP", "EDIT", "KEEP"])
		draft.text = "EDIT=new\nKEEP=1\nNEW=added\n"
		#expect(draft.changes.added == ["NEW"] && draft.changes.changed == ["EDIT"] && draft.changes.removed == ["DROP"])
		#expect(draft.changes.unchanged == ["KEEP"])
		#expect(draft.changes.summary == "1 added, 1 changed, 1 removed")
		#expect(draft.canSave)
		draft.text += "bad key=1\n"
		#expect(!draft.canSave, "A problem line keeps it from saving")
		draft.text = "DROP=x\nEDIT=old\nKEEP=1\n# a note\n"
		#expect(draft.changes.count == 0 && !draft.canSave, "Comments and order alone change nothing")
		draft.baseline = ["KEEP": "1"]
		#expect(draft.changes.added == ["DROP", "EDIT"], "Comparing with other values counts against them")
	}

	@Test("a review compares the edit with the environment as it is now, and leaves out the changes switched off")
	func review() {
		var draft = VaultRawTextDraft(target: target, baseline: ["KEEP": "1", "EDIT": "old", "DROP": "x"], order: ["DROP", "EDIT", "KEEP"])
		draft.text = "EDIT=new\nKEEP=1\nNEW=added\n"
		// Since the edit began, the LPM CLI changed KEEP and added CLI.
		let review = VaultRawTextReview(draft: draft, current: ["KEEP": "2", "EDIT": "old", "DROP": "x", "CLI": "c"])
		#expect(review.changes.added == ["NEW"])
		#expect(review.changes.changed == ["EDIT", "KEEP"], "Writing the edit would put KEEP back")
		#expect(review.changes.removed == ["CLI", "DROP"])
		#expect(review.lines == ["EDIT": 1, "KEEP": 2, "NEW": 3])
		#expect(review.values(skipping: []) == ["EDIT": "new", "KEEP": "1", "NEW": "added"])
		#expect(review.values(skipping: ["KEEP", "CLI"]) == ["EDIT": "new", "KEEP": "2", "NEW": "added", "CLI": "c"])
		#expect(review.applied(skipping: ["KEEP", "CLI"]).summary == "1 added, 1 changed, 1 removed")
		#expect(review.applied(skipping: ["NEW", "EDIT", "KEEP", "CLI", "DROP"]).count == 0)
	}

	@Test("a text past the import's limits says which line goes over")
	func limits() {
		let limits = EnvFileImportLimits(maximumInputBytes: 1_000, maximumAssignments: 2, maximumParsedBytes: 12)
		#expect(VaultEnvTextCheck("A=1\nB=2\nC=3", limits: limits).problems.map(\.message) == ["Line 3: more than 2 keys"])
		#expect(VaultEnvTextCheck("A=12345\nB=1234567", limits: limits).problems.first?.line == 2)
	}
}
