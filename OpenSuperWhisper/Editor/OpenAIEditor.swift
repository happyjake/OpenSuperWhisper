import Foundation

/// OpenAI-compatible LLM client for text editing
/// Works with OpenAI API and compatible endpoints (Ollama, local servers, etc.)
final class OpenAIEditor: LLMTextEditor, @unchecked Sendable {
    let identifier = "openai"
    let displayName = "OpenAI"

    private var currentTask: Task<Void, Never>?
    private let preferences = AppPreferences.shared

    var isAvailable: Bool {
        get async {
            guard let endpoint = preferences.editorEndpointURL,
                  !endpoint.isEmpty,
                  URL(string: endpoint) != nil else {
                return false
            }
            return true
        }
    }

    func edit(
        raw: String,
        mode: OutputMode,
        glossary: [DictionaryTerm],
        language: String?,
        metadata: EditorMetadata
    ) async throws -> EditedText {
        try Task.checkCancellation()

        // Validate configuration
        try await validateConfiguration()

        let startTime = CFAbsoluteTimeGetCurrent()

        // Build the request
        let request = try buildRequest(
            raw: raw,
            mode: mode,
            glossary: glossary,
            language: language
        )

        // Execute the request
        let (data, response) = try await executeRequest(request)

        // Parse and validate response
        let output = try parseResponse(data: data, response: response)

        // Calculate latency
        let latencyMs = Int((CFAbsoluteTimeGetCurrent() - startTime) * 1000)

        // Run DiffGuard validation
        let constraints = EditorConstraints.forMode(mode)
        let diffGuard = DiffGuard(constraints: constraints)
        let safety = diffGuard.analyze(original: raw, edited: output.editedText, glossary: glossary)

        // Check if safety checks passed
        if !safety.passed {
            // Return original text with fallback flag
            let fallbackSafety = SafetySummary(
                wordChangeRatio: safety.wordChangeRatio,
                charInsertionRatio: safety.charInsertionRatio,
                glossaryEnforced: safety.glossaryEnforced,
                passed: false,
                fallbackTriggered: true
            )

            let report = EditReport(
                replacements: [],
                safety: fallbackSafety,
                modelUsed: preferences.editorModelName,
                latencyMs: latencyMs,
                tokensUsed: nil
            )

            return EditedText(
                original: raw,
                edited: raw,
                report: report
            )
        }

        // Build replacements from output changes
        let replacements = buildReplacements(from: output.changes ?? [])

        let report = EditReport(
            replacements: replacements,
            safety: safety,
            modelUsed: preferences.editorModelName,
            latencyMs: latencyMs,
            tokensUsed: extractTokensUsed(from: data)
        )

        return EditedText(
            original: raw,
            edited: output.editedText,
            report: report
        )
    }

    func validateConfiguration() async throws {
        guard let endpoint = preferences.editorEndpointURL, !endpoint.isEmpty else {
            throw EditorError.notConfigured("Endpoint URL not set")
        }

        guard URL(string: endpoint) != nil else {
            throw EditorError.notConfigured("Invalid endpoint URL")
        }

        // API key is optional for some local endpoints
    }

    func cancel() {
        currentTask?.cancel()
        currentTask = nil
    }

    // MARK: - Private Methods

    private func buildRequest(
        raw: String,
        mode: OutputMode,
        glossary: [DictionaryTerm],
        language: String?
    ) throws -> URLRequest {
        guard let endpointString = preferences.editorEndpointURL,
              let endpoint = URL(string: endpointString) else {
            throw EditorError.notConfigured("Invalid endpoint URL")
        }

        // Build the chat completions URL
        let chatCompletionsURL: URL
        if endpointString.hasSuffix("/chat/completions") {
            chatCompletionsURL = endpoint
        } else if endpointString.hasSuffix("/v1") {
            chatCompletionsURL = endpoint.appendingPathComponent("chat/completions")
        } else {
            chatCompletionsURL = endpoint
                .appendingPathComponent("v1")
                .appendingPathComponent("chat")
                .appendingPathComponent("completions")
        }

        var request = URLRequest(url: chatCompletionsURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Add API key if provided
        if let apiKey = preferences.editorAPIKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        // Set timeout
        let timeoutSeconds = Double(preferences.editorTimeoutMs) / 1000.0
        request.timeoutInterval = timeoutSeconds

        // Build the messages
        let systemPrompt = buildSystemPrompt(mode: mode)
        let constraints = EditorConstraints.forMode(mode)
        let editorInput = EditorInput(
            rawTranscription: raw,
            outputMode: mode,
            glossary: glossary,
            language: language,
            constraints: constraints
        )

        let userMessage = try editorInput.toJSON()

        // Build request body
        let body: [String: Any] = [
            "model": preferences.editorModelName,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userMessage]
            ],
            "temperature": preferences.editorTemperature,
            "max_tokens": preferences.editorMaxTokens,
            "response_format": ["type": "json_object"]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        return request
    }

    private func buildSystemPrompt(mode: OutputMode) -> String {
        """
        You are a transcription editor. Clean up the following speech-to-text output.

        Rules:
        - \(mode.promptModifier)
        - Preserve all numbers exactly
        - Use glossary terms when applicable
        - Do NOT add information not present in the original

        Respond with JSON: {"edited_text": "...", "changes": [...]}

        The changes array should contain objects with: type, original, replacement, reason.
        """
    }

    private func executeRequest(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            try Task.checkCancellation()
            let (data, response) = try await URLSession.shared.data(for: request)
            try Task.checkCancellation()
            return (data, response)
        } catch is CancellationError {
            throw EditorError.cancelled
        } catch let error as URLError {
            switch error.code {
            case .timedOut:
                throw EditorError.timeout
            case .cancelled:
                throw EditorError.cancelled
            case .notConnectedToInternet, .networkConnectionLost:
                throw EditorError.networkError("No internet connection")
            default:
                throw EditorError.networkError(error.localizedDescription)
            }
        } catch {
            throw EditorError.networkError(error.localizedDescription)
        }
    }

    private func parseResponse(data: Data, response: URLResponse) throws -> EditorOutput {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw EditorError.invalidResponse("Not an HTTP response")
        }

        // Handle HTTP errors
        switch httpResponse.statusCode {
        case 200...299:
            break
        case 401:
            throw EditorError.apiError(statusCode: 401, message: "Invalid API key")
        case 429:
            let retryAfter = httpResponse.value(forHTTPHeaderField: "Retry-After")
                .flatMap { Int($0) }
            throw EditorError.rateLimited(retryAfter: retryAfter)
        case 500...599:
            throw EditorError.apiError(statusCode: httpResponse.statusCode, message: "Server error")
        default:
            let message = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw EditorError.apiError(statusCode: httpResponse.statusCode, message: message)
        }

        // Parse the OpenAI response structure
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw EditorError.invalidResponse("Could not parse API response structure")
        }

        // Parse the content as EditorOutput
        do {
            return try EditorOutput.fromJSON(content)
        } catch {
            throw EditorError.invalidResponse("Could not parse editor output: \(error.localizedDescription)")
        }
    }

    private func buildReplacements(from changes: [OutputChange]) -> [Replacement] {
        changes.compactMap { change -> Replacement? in
            guard let original = change.original else { return nil }

            let reason = ReplacementReason(rawValue: change.type) ?? .other

            return Replacement(
                original: TextSpan(
                    text: original,
                    startIndex: 0,
                    endIndex: original.count
                ),
                replacement: change.replacement ?? "",
                reason: reason
            )
        }
    }

    private func extractTokensUsed(from data: Data) -> Int? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let usage = json["usage"] as? [String: Any],
              let totalTokens = usage["total_tokens"] as? Int else {
            return nil
        }
        return totalTokens
    }
}
