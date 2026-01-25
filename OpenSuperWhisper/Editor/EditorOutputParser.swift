import Foundation

// MARK: - Parsed Output Types

/// Parsed output for notes mode
struct NotesOutput: Codable, Sendable {
    let bullets: [String]
    let replacements: [ReplacementPair]?
    let uncertainSpans: [UncertainSpan]?

    enum CodingKeys: String, CodingKey {
        case bullets
        case replacements
        case uncertainSpans = "uncertain_spans"
    }

    /// Render bullets as formatted text
    func render() -> String {
        bullets.map { "- \($0)" }.joined(separator: "\n")
    }
}

/// Parsed output for text editing modes (clean, verbatim, email, slack)
struct EditedTextOutput: Codable, Sendable {
    let editedText: String
    let replacements: [ReplacementPair]?
    let uncertainSpans: [UncertainSpan]?

    enum CodingKeys: String, CodingKey {
        case editedText = "edited_text"
        case replacements
        case uncertainSpans = "uncertain_spans"
    }

    /// Render as formatted text
    func render() -> String {
        editedText
    }
}

/// A replacement pair from the LLM
struct ReplacementPair: Codable, Sendable {
    let from: String
    let to: String
}

/// An uncertain span flagged by the LLM
struct UncertainSpan: Codable, Sendable {
    let span: String
    let reason: String
}

// MARK: - Parse Result

enum ParsedEditorOutput: Sendable {
    case notes(NotesOutput)
    case editedText(EditedTextOutput)

    var renderedText: String {
        switch self {
        case .notes(let output):
            return output.render()
        case .editedText(let output):
            return output.render()
        }
    }

    var replacements: [ReplacementPair] {
        switch self {
        case .notes(let output):
            return output.replacements ?? []
        case .editedText(let output):
            return output.replacements ?? []
        }
    }

    var uncertainSpans: [UncertainSpan] {
        switch self {
        case .notes(let output):
            return output.uncertainSpans ?? []
        case .editedText(let output):
            return output.uncertainSpans ?? []
        }
    }
}

// MARK: - StructureGuard

/// Validates JSON structure matches required schema
struct StructureGuard: Sendable {

    enum ValidationResult: Sendable {
        case valid(ParsedEditorOutput)
        case invalid(reason: String, rawOutput: String)
    }

    /// Parse and validate LLM output for the given mode
    static func validate(jsonString: String, mode: OutputMode) -> ValidationResult {
        // Strip markdown code blocks if present
        let cleaned = stripMarkdownCodeBlock(jsonString)

        guard let data = cleaned.data(using: .utf8) else {
            return .invalid(reason: "Invalid UTF-8 encoding", rawOutput: jsonString)
        }

        // Try to parse as JSON first
        guard (try? JSONSerialization.jsonObject(with: data)) != nil else {
            return .invalid(reason: "Not valid JSON", rawOutput: jsonString)
        }

        let decoder = JSONDecoder()

        switch mode {
        case .notes:
            return validateNotesOutput(data: data, decoder: decoder, rawOutput: jsonString)
        default:
            return validateEditedTextOutput(data: data, decoder: decoder, rawOutput: jsonString)
        }
    }

    private static func validateNotesOutput(data: Data, decoder: JSONDecoder, rawOutput: String)
        -> ValidationResult
    {
        do {
            let output = try decoder.decode(NotesOutput.self, from: data)

            // Validate required fields
            guard !output.bullets.isEmpty else {
                return .invalid(reason: "bullets array is empty", rawOutput: rawOutput)
            }

            return .valid(.notes(output))
        } catch {
            // Try flexible parsing - look for bullets in various formats
            if let flexibleOutput = tryFlexibleNotesParsing(data: data) {
                return .valid(.notes(flexibleOutput))
            }
            return .invalid(
                reason: "Missing or invalid 'bullets' array: \(error.localizedDescription)",
                rawOutput: rawOutput)
        }
    }

    private static func validateEditedTextOutput(
        data: Data, decoder: JSONDecoder, rawOutput: String
    ) -> ValidationResult {
        do {
            let output = try decoder.decode(EditedTextOutput.self, from: data)

            // Validate required fields
            guard !output.editedText.isEmpty else {
                return .invalid(reason: "edited_text is empty", rawOutput: rawOutput)
            }

            return .valid(.editedText(output))
        } catch {
            // Try flexible parsing - look for text under alternative keys
            if let flexibleOutput = tryFlexibleTextParsing(data: data) {
                return .valid(.editedText(flexibleOutput))
            }
            return .invalid(
                reason: "Missing or invalid 'edited_text': \(error.localizedDescription)",
                rawOutput: rawOutput)
        }
    }

    /// Try to extract bullets from non-standard JSON formats
    private static func tryFlexibleNotesParsing(data: Data) -> NotesOutput? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        // Look for bullets under various keys
        let possibleKeys = ["bullets", "points", "notes", "items", "key_points"]

        for key in possibleKeys {
            if let array = json[key] as? [String], !array.isEmpty {
                return NotesOutput(bullets: array, replacements: nil, uncertainSpans: nil)
            }
        }

        return nil
    }

    /// Try to extract text from non-standard JSON formats
    private static func tryFlexibleTextParsing(data: Data) -> EditedTextOutput? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        // First try preferred keys that indicate "edited/cleaned" output
        let preferredKeys = [
            "edited_text", "cleaned", "cleaned_text", "cleaned_transcription", "output", "result",
        ]
        for key in preferredKeys {
            if let text = json[key] as? String, !text.isEmpty {
                return EditedTextOutput(editedText: text, replacements: nil, uncertainSpans: nil)
            }
        }

        // Fallback: find the longest string value, but skip keys that suggest "original"
        let skipKeys = Set(["original", "raw", "input", "source", "reason", "from", "to"])
        var longestText: String?
        var longestLength = 0

        for (key, value) in json {
            if skipKeys.contains(key.lowercased()) { continue }
            if let text = value as? String, text.count > longestLength {
                longestText = text
                longestLength = text.count
            }
        }

        if let text = longestText, !text.isEmpty {
            return EditedTextOutput(editedText: text, replacements: nil, uncertainSpans: nil)
        }

        return nil
    }

    /// Strip markdown code block wrappers
    private static func stripMarkdownCodeBlock(_ input: String) -> String {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)

        if text.hasPrefix("```") {
            if let endOfFirstLine = text.firstIndex(of: "\n") {
                text = String(text[text.index(after: endOfFirstLine)...])
            } else {
                text = String(text.dropFirst(3))
            }

            if text.hasSuffix("```") {
                text = String(text.dropLast(3))
            }

            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return text
    }
}
