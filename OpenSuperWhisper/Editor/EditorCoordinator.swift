import Foundation

/// Coordinates LLM editor invocation in the transcription pipeline.
/// Handles backend selection, fallback on errors, and telemetry logging.
@MainActor
final class EditorCoordinator {
    static let shared = EditorCoordinator()

    private var currentEditor: (any LLMTextEditor)?

    private init() {}

    /// Edit transcribed text using the configured LLM backend.
    /// - Parameters:
    ///   - raw: Raw transcription text from Whisper
    ///   - mode: Output mode (verbatim, clean, notes, etc.)
    ///   - glossary: Dictionary terms to enforce
    ///   - language: Detected or specified language code
    ///   - metadata: Additional context about the transcription
    /// - Returns: Edited text, or raw text as fallback on error
    func edit(
        raw: String,
        mode: OutputMode,
        glossary: [DictionaryTerm] = [],
        language: String? = nil,
        metadata: EditorMetadata = EditorMetadata()
    ) async -> String {
        let prefs = AppPreferences.shared

        // Check if editor is enabled and not disabled
        guard prefs.editorEnabled, prefs.editorBackend != .disabled else {
            log("Editor disabled, returning raw text")
            return raw
        }

        // Skip editing for empty or very short text
        guard raw.count >= 3 else {
            log("Text too short for editing (\(raw.count) chars), returning raw")
            return raw
        }

        do {
            let editor = try createEditor(backend: prefs.editorBackend)
            currentEditor = editor

            let startTime = CFAbsoluteTimeGetCurrent()
            let result = try await editor.edit(
                raw: raw,
                mode: mode,
                glossary: glossary,
                language: language,
                metadata: metadata
            )
            let latencyMs = Int((CFAbsoluteTimeGetCurrent() - startTime) * 1000)

            logSuccess(
                modelUsed: result.report.modelUsed,
                latencyMs: latencyMs,
                tokensUsed: result.report.tokensUsed,
                safetyPassed: result.report.safety.passed
            )

            // Check if safety triggered fallback
            if result.report.safety.fallbackTriggered {
                log("Safety fallback triggered, returning raw text")
                return raw
            }

            return result.edited

        } catch let error as EditorError {
            logError(error)
            // Safety policy: always fallback to raw text on error
            return raw

        } catch {
            logError(EditorError.networkError(error.localizedDescription))
            // Safety policy: always fallback to raw text on error
            return raw
        }
    }

    /// Cancel any in-progress edit operation
    func cancel() {
        currentEditor?.cancel()
    }

    // MARK: - Private

    private func createEditor(backend: EditorBackend) throws -> any LLMTextEditor {
        let prefs = AppPreferences.shared

        switch backend {
        case .disabled:
            throw EditorError.notConfigured("Editor is disabled")

        case .auto:
            // Auto mode: use OpenAIEditor which reads from preferences
            // It will use either direct OpenAI API or custom endpoint based on settings
            if prefs.editorEndpointURL != nil || prefs.editorAPIKey != nil {
                return OpenAIEditor()
            } else {
                throw EditorError.notConfigured("No API key or endpoint configured")
            }

        case .openai:
            guard let apiKey = prefs.editorAPIKey, !apiKey.isEmpty else {
                throw EditorError.notConfigured("OpenAI API key not set")
            }
            return OpenAIEditor()

        case .custom:
            guard let endpoint = prefs.editorEndpointURL, !endpoint.isEmpty else {
                throw EditorError.notConfigured("Custom endpoint URL not set")
            }
            return OpenAIEditor()
        }
    }

    // MARK: - Logging

    private func log(_ message: String) {
        #if DEBUG
        print("[EditorCoordinator] \(message)")
        #endif
    }

    private func logSuccess(modelUsed: String, latencyMs: Int, tokensUsed: Int?, safetyPassed: Bool) {
        var msg = "Edit completed: model=\(modelUsed), latency=\(latencyMs)ms"
        if let tokens = tokensUsed {
            msg += ", tokens=\(tokens)"
        }
        msg += ", safety=\(safetyPassed ? "passed" : "failed")"
        log(msg)
    }

    private func logError(_ error: EditorError) {
        log("Edit failed: \(error.localizedDescription)")
    }
}
