import Foundation

/// Metadata passed to editor for context
struct EditorMetadata: Codable, Sendable {
    let audioDurationMs: Int?
    let whisperModel: String?
    let detectedLanguage: String?
    let timestamp: Date

    init(
        audioDurationMs: Int? = nil,
        whisperModel: String? = nil,
        detectedLanguage: String? = nil,
        timestamp: Date = Date()
    ) {
        self.audioDurationMs = audioDurationMs
        self.whisperModel = whisperModel
        self.detectedLanguage = detectedLanguage
        self.timestamp = timestamp
    }
}

/// Protocol defining the interface for LLM text editors (backends)
/// Named LLMTextEditor to avoid collision with SwiftUI's TextEditor
protocol LLMTextEditor: Sendable {
    /// Unique identifier for this editor backend
    var identifier: String { get }

    /// Human-readable display name
    var displayName: String { get }

    /// Check if the editor is available (API reachable, credentials valid)
    var isAvailable: Bool { get async }

    /// Edit raw transcription text
    /// - Parameters:
    ///   - raw: Raw transcription from Whisper
    ///   - mode: Output mode (verbatim, clean, notes, etc.)
    ///   - glossary: Dictionary terms to enforce
    ///   - language: Detected or specified language code
    ///   - metadata: Additional context about the transcription
    /// - Returns: Edited text with report
    /// - Throws: EditorError on failure
    func edit(
        raw: String,
        mode: OutputMode,
        glossary: [DictionaryTerm],
        language: String?,
        metadata: EditorMetadata
    ) async throws -> EditedText

    /// Validate the editor configuration (endpoint, API key, model)
    func validateConfiguration() async throws

    /// Cancel any in-progress edit operation
    func cancel()
}
