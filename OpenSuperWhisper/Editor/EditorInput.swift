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
        constraints: EditorConstraints = .default
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

    /// Parse from JSON string
    static func fromJSON(_ json: String) throws -> EditorOutput {
        guard let data = json.data(using: .utf8) else {
            throw EditorError.invalidResponse("Invalid JSON encoding")
        }
        return try JSONDecoder().decode(EditorOutput.self, from: data)
    }
}

/// Change description from LLM output
struct OutputChange: Codable, Sendable {
    let type: String
    let original: String?
    let replacement: String?
    let reason: String?
}
