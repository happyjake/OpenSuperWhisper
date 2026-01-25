import Foundation

/// Structured input for the LLM editor (JSON format)
struct EditorInput: Codable, Sendable {
    let rawTranscription: String
    let outputMode: String
    let glossary: [GlossaryEntry]
    let language: String?
    let constraints: InputConstraints

    init(
        rawTranscription: String,
        outputMode: OutputMode,
        glossary: [DictionaryTerm],
        language: String?,
        constraints: EditorConstraints = .clean
    ) {
        self.rawTranscription = rawTranscription
        self.outputMode = outputMode.rawValue
        self.glossary = glossary.map { GlossaryEntry(term: $0.term, caseSensitive: $0.caseSensitive) }
        self.language = language
        self.constraints = InputConstraints(
            maxInsertionPercent: Int(constraints.maxCharInsertionRatio * 100),
            enforceGlossary: constraints.enforceGlossary,
            preserveNumbers: constraints.preserveNumbers
        )
    }

    /// Convert to JSON string for LLM prompt
    func toJSON() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private enum CodingKeys: String, CodingKey {
        case rawTranscription = "raw_transcription"
        case outputMode = "output_mode"
        case glossary
        case language
        case constraints
    }
}

/// Glossary entry for JSON serialization
struct GlossaryEntry: Codable, Sendable {
    let term: String
    let caseSensitive: Bool

    private enum CodingKeys: String, CodingKey {
        case term
        case caseSensitive = "case_sensitive"
    }
}

/// Constraints in JSON input format
struct InputConstraints: Codable, Sendable {
    let maxInsertionPercent: Int
    let enforceGlossary: Bool
    let preserveNumbers: Bool

    private enum CodingKeys: String, CodingKey {
        case maxInsertionPercent = "max_insertion_percent"
        case enforceGlossary = "enforce_glossary"
        case preserveNumbers = "preserve_numbers"
    }
}

/// Expected output structure from the LLM
struct EditorOutput: Codable, Sendable {
    let editedText: String
    let changes: [OutputChange]?

    private enum CodingKeys: String, CodingKey {
        case editedText = "edited_text"
        case changes
    }

    /// Parse from JSON string, handling common LLM response variations
    static func fromJSON(_ json: String) throws -> EditorOutput {
        // Strip markdown code blocks if present (```json ... ```)
        let cleanedJSON = stripMarkdownCodeBlock(json)

        guard let data = cleanedJSON.data(using: .utf8) else {
            throw EditorError.invalidResponse("Invalid JSON encoding")
        }

        // First try standard decoding
        if let output = try? JSONDecoder().decode(EditorOutput.self, from: data) {
            return output
        }

        // Try flexible parsing for alternative key names
        if let jsonDict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            // Look for the edited text under various possible keys
            let possibleKeys = ["edited_text", "transcription", "text", "output", "result", "content"]
            var editedText: String?
            for key in possibleKeys {
                if let value = jsonDict[key] as? String {
                    editedText = value
                    break
                }
            }

            if let text = editedText {
                // Extract changes if present
                let changes = (jsonDict["changes"] as? [[String: Any]])?.compactMap { dict -> OutputChange? in
                    guard let type = dict["type"] as? String else { return nil }
                    return OutputChange(
                        type: type,
                        original: dict["original"] as? String,
                        replacement: dict["replacement"] as? String,
                        reason: dict["reason"] as? String
                    )
                }

                return EditorOutput(editedText: text, changes: changes)
            }
        }

        // No plain text fallback - require valid JSON structure
        throw EditorError.invalidResponse("Response is not valid JSON with required structure")
    }

    /// Strip markdown code block wrappers (```json ... ``` or ``` ... ```)
    private static func stripMarkdownCodeBlock(_ input: String) -> String {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)

        // Pattern: ```json or ``` at start, ``` at end
        if text.hasPrefix("```") {
            // Remove opening fence (```json or ```)
            if let endOfFirstLine = text.firstIndex(of: "\n") {
                text = String(text[text.index(after: endOfFirstLine)...])
            } else {
                // No newline, just remove ```
                text = String(text.dropFirst(3))
            }

            // Remove closing fence
            if text.hasSuffix("```") {
                text = String(text.dropLast(3))
            }

            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return text
    }

    init(editedText: String, changes: [OutputChange]?) {
        self.editedText = editedText
        self.changes = changes
    }
}

/// Change description from LLM output
struct OutputChange: Codable, Sendable {
    let type: String
    let original: String?
    let replacement: String?
    let reason: String?
}
