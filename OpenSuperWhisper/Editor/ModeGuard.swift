import Foundation

// MARK: - ModeGuard

/// Validates parsed output against mode-specific rules
struct ModeGuard: Sendable {

    struct ValidationResult: Sendable {
        let passed: Bool
        let violations: [Violation]

        static let success = ValidationResult(passed: true, violations: [])

        static func failure(_ violations: [Violation]) -> ValidationResult {
            ValidationResult(passed: false, violations: violations)
        }
    }

    struct Violation: Sendable {
        let rule: String
        let detail: String
    }

    // MARK: - Configuration

    struct NotesConfig: Sendable {
        let minBullets: Int
        let maxBullets: Int
        let maxBulletLength: Int
        let bannedPrefixes: [String]

        static let `default` = NotesConfig(
            minBullets: 1,
            maxBullets: 8,
            maxBulletLength: 160,
            bannedPrefixes: [
                "Here are",
                "Key points",
                "The speaker",
                "This transcription",
                "Based on",
                "The following",
                "Summary of",
                "Notes from",
                "In this",
                "The main"
            ]
        )
    }

    struct CleanConfig: Sendable {
        let maxLengthRatio: Double  // Max ratio of edited/original length

        static let `default` = CleanConfig(maxLengthRatio: 1.3)
    }

    // MARK: - Validation Methods

    static func validate(_ output: ParsedEditorOutput, mode: OutputMode, originalText: String) -> ValidationResult {
        switch (mode, output) {
        case (.notes, .notes(let notesOutput)):
            return validateNotes(notesOutput, config: .default)
        case (.clean, .editedText(let textOutput)):
            return validateClean(textOutput, originalText: originalText, config: .default)
        case (.verbatim, .editedText(let textOutput)):
            return validateVerbatim(textOutput, originalText: originalText)
        case (.email, .editedText(let textOutput)):
            return validateEmail(textOutput)
        case (.slack, .editedText(let textOutput)):
            return validateSlack(textOutput)
        default:
            return .failure([Violation(rule: "mode_mismatch", detail: "Output type doesn't match mode")])
        }
    }

    // MARK: - Notes Validation

    static func validateNotes(_ output: NotesOutput, config: NotesConfig = .default) -> ValidationResult {
        var violations: [Violation] = []

        // Check bullet count
        if output.bullets.count < config.minBullets {
            violations.append(Violation(
                rule: "min_bullets",
                detail: "Too few bullets: \(output.bullets.count), minimum is \(config.minBullets)"
            ))
        }

        if output.bullets.count > config.maxBullets {
            violations.append(Violation(
                rule: "max_bullets",
                detail: "Too many bullets: \(output.bullets.count), maximum is \(config.maxBullets)"
            ))
        }

        // Check each bullet
        for (index, bullet) in output.bullets.enumerated() {
            // Check length
            if bullet.count > config.maxBulletLength {
                violations.append(Violation(
                    rule: "bullet_length",
                    detail: "Bullet \(index + 1) too long: \(bullet.count) chars, max is \(config.maxBulletLength)"
                ))
            }

            // Check banned prefixes
            for prefix in config.bannedPrefixes {
                if bullet.lowercased().hasPrefix(prefix.lowercased()) {
                    violations.append(Violation(
                        rule: "banned_prefix",
                        detail: "Bullet \(index + 1) starts with banned prefix: '\(prefix)'"
                    ))
                    break
                }
            }

            // Check for paragraph-like content (multiple sentences or double newlines)
            if bullet.contains("\n\n") {
                violations.append(Violation(
                    rule: "paragraph_content",
                    detail: "Bullet \(index + 1) contains paragraph breaks"
                ))
            }

            // Heuristic: more than 2 sentence-ending punctuation marks suggests multiple sentences
            let sentenceEnders = bullet.filter { $0 == "." || $0 == "!" || $0 == "?" }.count
            if sentenceEnders > 2 {
                violations.append(Violation(
                    rule: "multiple_sentences",
                    detail: "Bullet \(index + 1) appears to contain multiple sentences"
                ))
            }
        }

        return violations.isEmpty ? .success : .failure(violations)
    }

    // MARK: - Clean Validation

    static func validateClean(_ output: EditedTextOutput, originalText: String, config: CleanConfig = .default) -> ValidationResult {
        var violations: [Violation] = []

        // Check if output is empty
        if output.editedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            violations.append(Violation(rule: "empty_output", detail: "Edited text is empty"))
        }

        // Check length ratio
        let originalLength = originalText.count
        let editedLength = output.editedText.count

        if originalLength > 0 {
            let ratio = Double(editedLength) / Double(originalLength)
            if ratio > config.maxLengthRatio {
                violations.append(Violation(
                    rule: "length_ratio",
                    detail: "Output too long: \(Int(ratio * 100))% of original, max is \(Int(config.maxLengthRatio * 100))%"
                ))
            }
        }

        return violations.isEmpty ? .success : .failure(violations)
    }

    // MARK: - Verbatim Validation

    static func validateVerbatim(_ output: EditedTextOutput, originalText: String) -> ValidationResult {
        var violations: [Violation] = []

        // Check if output is empty
        if output.editedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            violations.append(Violation(rule: "empty_output", detail: "Edited text is empty"))
        }

        // Verbatim should be very close to original (only punctuation changes)
        let originalWords = originalText.lowercased().split(separator: " ").map(String.init)
        let editedWords = output.editedText.lowercased().split(separator: " ").map(String.init)

        // Strip punctuation for comparison
        let stripPunctuation: (String) -> String = { str in
            str.filter { $0.isLetter || $0.isNumber || $0.isWhitespace }
        }

        let originalStripped = originalWords.map(stripPunctuation)
        let editedStripped = editedWords.map(stripPunctuation)

        // Check if words match (ignoring punctuation)
        if originalStripped != editedStripped {
            violations.append(Violation(
                rule: "word_changes",
                detail: "Verbatim mode should not change words"
            ))
        }

        return violations.isEmpty ? .success : .failure(violations)
    }

    // MARK: - Email Validation

    static func validateEmail(_ output: EditedTextOutput) -> ValidationResult {
        var violations: [Violation] = []

        if output.editedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            violations.append(Violation(rule: "empty_output", detail: "Email text is empty"))
        }

        // Email should have reasonable length
        if output.editedText.count > 5000 {
            violations.append(Violation(
                rule: "too_long",
                detail: "Email too long: \(output.editedText.count) chars"
            ))
        }

        return violations.isEmpty ? .success : .failure(violations)
    }

    // MARK: - Slack Validation

    static func validateSlack(_ output: EditedTextOutput) -> ValidationResult {
        var violations: [Violation] = []

        if output.editedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            violations.append(Violation(rule: "empty_output", detail: "Slack message is empty"))
        }

        // Slack messages should be concise
        if output.editedText.count > 2000 {
            violations.append(Violation(
                rule: "too_long",
                detail: "Slack message too long: \(output.editedText.count) chars"
            ))
        }

        return violations.isEmpty ? .success : .failure(violations)
    }
}
