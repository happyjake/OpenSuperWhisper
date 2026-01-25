//
//  EditorGuardsTests.swift
//  OpenSuperWhisperTests
//
//  Tests for StructureGuard, ModeGuard, and DiffGuard
//

import XCTest
@testable import OpenSuperWhisper

final class EditorGuardsTests: XCTestCase {

    // MARK: - StructureGuard Tests

    func testStructureGuard_ValidNotesJSON() {
        let json = """
        {
            "bullets": ["Point one", "Point two", "Point three"],
            "replacements": [],
            "uncertain_spans": []
        }
        """

        let result = StructureGuard.validate(jsonString: json, mode: .notes)

        if case .valid(let parsed) = result {
            XCTAssertEqual(parsed.renderedText, "- Point one\n- Point two\n- Point three")
        } else {
            XCTFail("Expected valid result")
        }
    }

    func testStructureGuard_MissingBulletsKey_TriggersRepair() {
        let json = """
        {
            "notes": "Some text without bullets array"
        }
        """

        let result = StructureGuard.validate(jsonString: json, mode: .notes)

        if case .invalid(let reason, _) = result {
            XCTAssertTrue(reason.contains("bullets") || reason.contains("invalid"), "Should fail due to missing bullets")
        } else {
            XCTFail("Expected invalid result for missing bullets key")
        }
    }

    func testStructureGuard_ProseWithBullets_TriggersRepair() {
        // This simulates the common failure case where model outputs prose + bullets
        let json = """
        Here are the key points from the transcription:

        - Point one
        - Point two
        """

        let result = StructureGuard.validate(jsonString: json, mode: .notes)

        if case .invalid(let reason, _) = result {
            XCTAssertTrue(reason.contains("JSON") || reason.contains("valid"), "Should fail as not valid JSON")
        } else {
            XCTFail("Expected invalid result for prose output")
        }
    }

    func testStructureGuard_MarkdownWrappedJSON() {
        let json = """
        ```json
        {
            "bullets": ["Point one", "Point two"],
            "replacements": []
        }
        ```
        """

        let result = StructureGuard.validate(jsonString: json, mode: .notes)

        if case .valid(let parsed) = result {
            XCTAssertEqual(parsed.renderedText, "- Point one\n- Point two")
        } else {
            XCTFail("Should handle markdown-wrapped JSON")
        }
    }

    func testStructureGuard_ValidEditedTextJSON() {
        let json = """
        {
            "edited_text": "Hello, this is the cleaned text.",
            "replacements": [{"from": "um", "to": ""}]
        }
        """

        let result = StructureGuard.validate(jsonString: json, mode: .clean)

        if case .valid(let parsed) = result {
            XCTAssertEqual(parsed.renderedText, "Hello, this is the cleaned text.")
        } else {
            XCTFail("Expected valid result for clean mode")
        }
    }

    func testStructureGuard_AlternativeKeyNames() {
        let json = """
        {
            "text": "The transcription text",
            "replacements": []
        }
        """

        let result = StructureGuard.validate(jsonString: json, mode: .clean)

        if case .valid(let parsed) = result {
            XCTAssertEqual(parsed.renderedText, "The transcription text")
        } else {
            XCTFail("Should accept 'text' as alternative to 'edited_text'")
        }
    }

    // MARK: - ModeGuard Tests

    func testModeGuard_ValidNotes() {
        let output = NotesOutput(
            bullets: [
                "First point about the topic",
                "Second point with details"
            ],
            replacements: nil,
            uncertainSpans: nil
        )

        let result = ModeGuard.validateNotes(output)
        XCTAssertTrue(result.passed, "Valid notes should pass")
    }

    func testModeGuard_BannedPrefix_HereAre() {
        let output = NotesOutput(
            bullets: [
                "Here are the main points from the discussion",
                "Second point"
            ],
            replacements: nil,
            uncertainSpans: nil
        )

        let result = ModeGuard.validateNotes(output)
        XCTAssertFalse(result.passed, "Should fail for banned prefix 'Here are'")
        XCTAssertTrue(result.violations.contains { $0.rule == "banned_prefix" })
    }

    func testModeGuard_BannedPrefix_TheSpeaker() {
        let output = NotesOutput(
            bullets: [
                "The speaker mentioned several topics",
                "Second point"
            ],
            replacements: nil,
            uncertainSpans: nil
        )

        let result = ModeGuard.validateNotes(output)
        XCTAssertFalse(result.passed, "Should fail for banned prefix 'The speaker'")
    }

    func testModeGuard_TooManyBullets() {
        let output = NotesOutput(
            bullets: (1...10).map { "Point \($0)" },  // 10 bullets, max is 8
            replacements: nil,
            uncertainSpans: nil
        )

        let result = ModeGuard.validateNotes(output)
        XCTAssertFalse(result.passed, "Should fail for too many bullets")
        XCTAssertTrue(result.violations.contains { $0.rule == "max_bullets" })
    }

    func testModeGuard_BulletTooLong() {
        let longBullet = String(repeating: "word ", count: 50)  // > 160 chars
        let output = NotesOutput(
            bullets: [longBullet],
            replacements: nil,
            uncertainSpans: nil
        )

        let result = ModeGuard.validateNotes(output)
        XCTAssertFalse(result.passed, "Should fail for bullet exceeding 160 chars")
        XCTAssertTrue(result.violations.contains { $0.rule == "bullet_length" })
    }

    func testModeGuard_EmptyBullets() {
        let output = NotesOutput(
            bullets: [],
            replacements: nil,
            uncertainSpans: nil
        )

        // StructureGuard should catch empty bullets, but ModeGuard also validates
        let result = ModeGuard.validateNotes(output)
        XCTAssertFalse(result.passed, "Should fail for empty bullets")
    }

    func testModeGuard_MultipleSentencesInBullet() {
        let output = NotesOutput(
            bullets: [
                "This is the first sentence. And here is another one. Plus a third."
            ],
            replacements: nil,
            uncertainSpans: nil
        )

        let result = ModeGuard.validateNotes(output)
        XCTAssertFalse(result.passed, "Should fail for bullet with multiple sentences")
        XCTAssertTrue(result.violations.contains { $0.rule == "multiple_sentences" })
    }

    // MARK: - DiffGuard Tests

    func testDiffGuard_VerbatimMode_MinimalChanges() {
        let original = "hello world how are you"
        let edited = "Hello world, how are you?"

        let diffGuard = DiffGuard(constraints: .verbatim)
        let result = diffGuard.analyze(original: original, edited: edited, glossary: [])

        // Verbatim allows only 5% changes - punctuation should be minimal
        XCTAssertTrue(result.charInsertionRatio < 0.1, "Punctuation-only changes should have low insertion ratio")
    }

    func testDiffGuard_CleanMode_ModerateChanges() {
        let original = "um so like I was thinking that um we should maybe do this"
        let edited = "I was thinking we should do this."

        let diffGuard = DiffGuard(constraints: .clean)
        let result = diffGuard.analyze(original: original, edited: edited, glossary: [])

        // Clean mode allows 15% char insertion
        XCTAssertLessThanOrEqual(result.charInsertionRatio, 0.15)
    }

    func testDiffGuard_NotesMode_TransformativeChanges() {
        let original = "I need to do three things first is buy groceries second is call mom third is finish the report"
        let edited = "- Buy groceries\n- Call mom\n- Finish the report"

        let diffGuard = DiffGuard(constraints: .notes)
        let result = diffGuard.analyze(original: original, edited: edited, glossary: [])

        // Notes mode allows 35% char insertion for bullet formatting
        XCTAssertTrue(result.passed || result.charInsertionRatio <= 0.35)
    }

    func testDiffGuard_GlossaryEnforcement() {
        let original = "We use clock code for transcription editing"
        let edited = "We use Claude Code for transcription editing"

        let glossary = [DictionaryTerm(term: "Claude Code", aliases: ["clock code"], caseSensitive: false)]

        let diffGuard = DiffGuard(constraints: .clean)
        let result = diffGuard.analyze(original: original, edited: edited, glossary: glossary)

        // The original contains "clock code" which should be replaced with "Claude Code"
        // The edited text has "Claude Code", so glossary is enforced
        XCTAssertTrue(result.glossaryEnforced)
    }

    // MARK: - Golden Test

    func testGoldenTest_NotesModeSample() {
        // Sample transcription from the spec
        let transcription = """
        So I've been thinking about um you know the prompt engineering with clock code. \
        Clock code is our large language model editor and it's super useful. \
        We need to improve how we're doing the prompting and problem engineering.
        """

        let expectedBullets = [
            "Need to improve prompt/problem engineering with Claude Code",
            "Claude Code is our large language model editor",
            "Editor is super useful"
        ]

        // This tests the format, not actual LLM output
        let validOutput = NotesOutput(
            bullets: expectedBullets,
            replacements: [ReplacementPair(from: "clock code", to: "Claude Code")],
            uncertainSpans: nil
        )

        // Validate with ModeGuard
        let modeResult = ModeGuard.validateNotes(validOutput)
        XCTAssertTrue(modeResult.passed, "Golden test output should pass ModeGuard")

        // Validate rendered output
        let rendered = validOutput.render()
        XCTAssertTrue(rendered.contains("- Need to improve"))
        XCTAssertTrue(rendered.contains("- Claude Code is"))
        XCTAssertTrue(rendered.contains("- Editor is super useful"))

        // Validate with DiffGuard
        let diffGuard = DiffGuard(constraints: .notes)
        let safety = diffGuard.analyze(original: transcription, edited: rendered, glossary: [
            DictionaryTerm(term: "Claude Code", aliases: ["clock code"], caseSensitive: false)
        ])

        // Notes mode should allow this transformation
        XCTAssertTrue(safety.charInsertionRatio <= 0.35, "Char insertion should be within notes limit")
    }
}

// MARK: - TranscriptPostProcessor Tests

final class TranscriptPostProcessorTests: XCTestCase {

    func testNormalizeWhitespace() {
        let input = "Hello   world  how    are   you"
        let result = TranscriptPostProcessor.process(text: input)

        XCTAssertFalse(result.contains("  "), "Should not contain double spaces")
    }

    func testCapitalizeSentences() {
        let input = "hello. how are you. this is a test."
        let result = TranscriptPostProcessor.process(text: input)

        XCTAssertTrue(result.hasPrefix("Hello"), "Should capitalize first letter")
        XCTAssertTrue(result.contains("How are you"), "Should capitalize after period")
    }

    func testGlossaryApplication() {
        let input = "I use clock code for editing"
        let glossary = [DictionaryTerm(term: "Claude Code", aliases: ["clock code"], caseSensitive: false)]

        let result = TranscriptPostProcessor.process(text: input, glossary: glossary)

        XCTAssertTrue(result.contains("Claude Code"), "Should replace alias with canonical term")
    }

    func testNotesModeFallback() {
        let input = "First thing to do. Second thing to do. Third thing to do."
        let result = TranscriptPostProcessor.process(text: input, mode: .notes)

        XCTAssertTrue(result.contains("- "), "Notes mode should create bullets")
    }
}
