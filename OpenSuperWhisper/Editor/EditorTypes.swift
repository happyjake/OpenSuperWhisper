import Foundation

/// Dictionary term for glossary enforcement
struct DictionaryTerm: Codable, Sendable, Hashable {
    let term: String
    let aliases: [String]
    let caseSensitive: Bool

    init(term: String, aliases: [String] = [], caseSensitive: Bool = false) {
        self.term = term
        self.aliases = aliases
        self.caseSensitive = caseSensitive
    }
}

/// Result of an edit operation
struct EditedText: Sendable {
    let original: String
    let edited: String
    let report: EditReport
}

/// Detailed report of changes made during editing
struct EditReport: Sendable {
    let replacements: [Replacement]
    let safety: SafetySummary
    let modelUsed: String
    let latencyMs: Int
    let tokensUsed: Int?

    init(
        replacements: [Replacement] = [],
        safety: SafetySummary = SafetySummary(),
        modelUsed: String = "",
        latencyMs: Int = 0,
        tokensUsed: Int? = nil
    ) {
        self.replacements = replacements
        self.safety = safety
        self.modelUsed = modelUsed
        self.latencyMs = latencyMs
        self.tokensUsed = tokensUsed
    }
}

/// A single replacement made during editing
struct Replacement: Sendable {
    let original: TextSpan
    let replacement: String
    let reason: ReplacementReason
}

/// A span of text with position information
struct TextSpan: Sendable {
    let text: String
    let startIndex: Int
    let endIndex: Int
}

/// Reason for a text replacement
enum ReplacementReason: String, Sendable, Codable {
    case punctuation = "punctuation"
    case capitalization = "capitalization"
    case spelling = "spelling"
    case grammar = "grammar"
    case filler = "filler"
    case formatting = "formatting"
    case glossary = "glossary"
    case other = "other"
}

/// Safety metrics from DiffGuard analysis
struct SafetySummary: Sendable {
    let wordChangeRatio: Double
    let charInsertionRatio: Double
    let glossaryEnforced: Bool
    let passed: Bool
    let fallbackTriggered: Bool

    init(
        wordChangeRatio: Double = 0.0,
        charInsertionRatio: Double = 0.0,
        glossaryEnforced: Bool = true,
        passed: Bool = true,
        fallbackTriggered: Bool = false
    ) {
        self.wordChangeRatio = wordChangeRatio
        self.charInsertionRatio = charInsertionRatio
        self.glossaryEnforced = glossaryEnforced
        self.passed = passed
        self.fallbackTriggered = fallbackTriggered
    }
}

/// Errors that can occur during editing
enum EditorError: LocalizedError, Sendable {
    case notConfigured(String)
    case networkError(String)
    case apiError(statusCode: Int, message: String)
    case rateLimited(retryAfter: Int?)
    case invalidResponse(String)
    case timeout
    case cancelled
    case safeguardTriggered(SafetySummary)
    case modelNotAvailable(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured(let reason):
            return "Editor not configured: \(reason)"
        case .networkError(let message):
            return "Network error: \(message)"
        case .apiError(let statusCode, let message):
            return "API error (\(statusCode)): \(message)"
        case .rateLimited(let retryAfter):
            if let seconds = retryAfter {
                return "Rate limited. Retry after \(seconds) seconds."
            }
            return "Rate limited. Please try again later."
        case .invalidResponse(let reason):
            return "Invalid response: \(reason)"
        case .timeout:
            return "Request timed out"
        case .cancelled:
            return "Edit operation was cancelled"
        case .safeguardTriggered(let summary):
            return "Safety check failed: \(Int(summary.charInsertionRatio * 100))% insertion detected"
        case .modelNotAvailable(let model):
            return "Model not available: \(model)"
        }
    }
}

/// Backend type for editor configuration
enum EditorBackend: String, Codable, Sendable, CaseIterable {
    case auto = "auto"
    case openai = "openai"
    case custom = "custom"
    case disabled = "disabled"

    var displayName: String {
        switch self {
        case .auto: return "Auto"
        case .openai: return "OpenAI"
        case .custom: return "Custom Endpoint"
        case .disabled: return "Disabled"
        }
    }

    var description: String {
        switch self {
        case .auto: return "Automatically detect available backend"
        case .openai: return "Use OpenAI API directly"
        case .custom: return "Use custom OpenAI-compatible endpoint"
        case .disabled: return "Skip LLM editing, use raw transcription"
        }
    }
}
