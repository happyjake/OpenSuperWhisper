import Foundation

/// OpenAI-compatible LLM client for text editing
/// Works with OpenAI API and compatible endpoints (Ollama, local servers, etc.)
/// Implements two-pass editing: STRICT pass -> REPAIR pass -> deterministic fallback
final class OpenAIEditor: LLMTextEditor, @unchecked Sendable {
    let identifier = "openai"
    let displayName = "OpenAI"

    private var currentTask: Task<Void, Never>?
    private let preferences = AppPreferences.shared

    var isAvailable: Bool {
        get async {
            guard let endpoint = preferences.editorEndpointURL,
                !endpoint.isEmpty,
                URL(string: endpoint) != nil
            else {
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
        try await validateConfiguration()

        let startTime = CFAbsoluteTimeGetCurrent()

        // PASS A: Strict pass with low temperature
        #if DEBUG
            print("[OpenAIEditor] Starting STRICT pass for mode: \(mode.rawValue)")
        #endif

        let strictResult = await executeStrictPass(
            raw: raw,
            mode: mode,
            glossary: glossary,
            language: language
        )

        switch strictResult {
        case .success(let parsed):
            // Validate with ModeGuard
            let modeValidation = ModeGuard.validate(parsed, mode: mode, originalText: raw)

            if modeValidation.passed {
                // Run DiffGuard on rendered output
                let renderedText = parsed.renderedText
                let constraints = EditorConstraints.forMode(mode)
                let diffGuard = DiffGuard(constraints: constraints)
                let safety = diffGuard.analyze(
                    original: raw, edited: renderedText, glossary: glossary)

                #if DEBUG
                    print(
                        "[OpenAIEditor] DiffGuard: passed=\(safety.passed), wordChangeRatio=\(String(format: "%.2f", safety.wordChangeRatio)), charInsertionRatio=\(String(format: "%.2f", safety.charInsertionRatio))"
                    )
                #endif

                if safety.passed {
                    let latencyMs = Int((CFAbsoluteTimeGetCurrent() - startTime) * 1000)
                    return buildSuccessResult(
                        original: raw,
                        parsed: parsed,
                        safety: safety,
                        latencyMs: latencyMs
                    )
                } else {
                    #if DEBUG
                        print("[OpenAIEditor] DiffGuard failed, trying REPAIR pass")
                    #endif
                }
            } else {
                #if DEBUG
                    print(
                        "[OpenAIEditor] ModeGuard failed: \(modeValidation.violations.map { $0.detail }.joined(separator: ", "))"
                    )
                #endif
            }

        case .failure(let rawOutput, let reason):
            #if DEBUG
                print("[OpenAIEditor] STRICT pass failed: \(reason)")
            #endif

            // PASS B: Repair pass
            let repairResult = await executeRepairPass(
                malformedOutput: rawOutput,
                mode: mode,
                originalText: raw
            )

            switch repairResult {
            case .success(let parsed):
                #if DEBUG
                    print("[OpenAIEditor] REPAIR pass succeeded, validating...")
                #endif

                let modeValidation = ModeGuard.validate(parsed, mode: mode, originalText: raw)

                if modeValidation.passed {
                    let renderedText = parsed.renderedText
                    let constraints = EditorConstraints.forMode(mode)
                    let diffGuard = DiffGuard(constraints: constraints)
                    let safety = diffGuard.analyze(
                        original: raw, edited: renderedText, glossary: glossary)

                    #if DEBUG
                        print(
                            "[OpenAIEditor] REPAIR DiffGuard: passed=\(safety.passed), wordChangeRatio=\(String(format: "%.2f", safety.wordChangeRatio)), charInsertionRatio=\(String(format: "%.2f", safety.charInsertionRatio))"
                        )
                    #endif

                    if safety.passed {
                        let latencyMs = Int((CFAbsoluteTimeGetCurrent() - startTime) * 1000)
                        return buildSuccessResult(
                            original: raw,
                            parsed: parsed,
                            safety: safety,
                            latencyMs: latencyMs
                        )
                    } else {
                        #if DEBUG
                            print("[OpenAIEditor] REPAIR DiffGuard failed")
                        #endif
                    }
                } else {
                    #if DEBUG
                        print(
                            "[OpenAIEditor] REPAIR ModeGuard failed: \(modeValidation.violations.map { $0.detail }.joined(separator: ", "))"
                        )
                    #endif
                }

            case .failure(_, let reason):
                #if DEBUG
                    print("[OpenAIEditor] REPAIR pass failed: \(reason)")
                #endif
            }
        }

        // FALLBACK: Deterministic post-processing
        #if DEBUG
            print("[OpenAIEditor] All passes failed, using deterministic fallback")
        #endif

        let latencyMs = Int((CFAbsoluteTimeGetCurrent() - startTime) * 1000)
        return buildFallbackResult(
            original: raw,
            glossary: glossary,
            mode: mode,
            latencyMs: latencyMs
        )
    }

    func validateConfiguration() async throws {
        guard let endpoint = preferences.editorEndpointURL, !endpoint.isEmpty else {
            throw EditorError.notConfigured("Endpoint URL not set")
        }

        guard URL(string: endpoint) != nil else {
            throw EditorError.notConfigured("Invalid endpoint URL")
        }
    }

    func cancel() {
        currentTask?.cancel()
        currentTask = nil
    }

    // MARK: - Pass Execution

    private enum PassResult {
        case success(ParsedEditorOutput)
        case failure(rawOutput: String, reason: String)
    }

    private func executeStrictPass(
        raw: String,
        mode: OutputMode,
        glossary: [DictionaryTerm],
        language: String?
    ) async -> PassResult {
        do {
            let request = try buildStrictRequest(
                raw: raw,
                mode: mode,
                glossary: glossary
            )

            let (data, response) = try await executeRequest(request)
            let content = try extractContent(data: data, response: response)

            #if DEBUG
                print("[OpenAIEditor] Model content: \(content)")
            #endif

            // Validate structure
            let structureResult = StructureGuard.validate(jsonString: content, mode: mode)

            switch structureResult {
            case .valid(let parsed):
                return .success(parsed)
            case .invalid(let reason, let rawOutput):
                return .failure(rawOutput: rawOutput, reason: reason)
            }

        } catch {
            return .failure(rawOutput: "", reason: error.localizedDescription)
        }
    }

    private func executeRepairPass(
        malformedOutput: String,
        mode: OutputMode,
        originalText: String
    ) async -> PassResult {
        guard !malformedOutput.isEmpty else {
            return .failure(rawOutput: "", reason: "No output to repair")
        }

        #if DEBUG
            print("[OpenAIEditor] Starting REPAIR pass")
        #endif

        do {
            let request = try buildRepairRequest(
                malformedOutput: malformedOutput,
                mode: mode
            )

            let (data, response) = try await executeRequest(request)
            let content = try extractContent(data: data, response: response)

            #if DEBUG
                print("[OpenAIEditor] Repair content: \(content)")
            #endif

            let structureResult = StructureGuard.validate(jsonString: content, mode: mode)

            switch structureResult {
            case .valid(let parsed):
                #if DEBUG
                    print(
                        "[OpenAIEditor] Repair StructureGuard passed, rendered: \(parsed.renderedText.prefix(100))..."
                    )
                #endif
                return .success(parsed)
            case .invalid(let reason, let rawOutput):
                #if DEBUG
                    print("[OpenAIEditor] Repair StructureGuard failed: \(reason)")
                #endif
                return .failure(rawOutput: rawOutput, reason: "Repair failed: \(reason)")
            }

        } catch {
            return .failure(rawOutput: "", reason: "Repair error: \(error.localizedDescription)")
        }
    }

    // MARK: - Request Building

    private func buildStrictRequest(
        raw: String,
        mode: OutputMode,
        glossary: [DictionaryTerm]
    ) throws -> URLRequest {
        let chatCompletionsURL = try buildEndpointURL()

        var request = URLRequest(url: chatCompletionsURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        if let apiKey = preferences.editorAPIKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let timeoutSeconds = Double(preferences.editorTimeoutMs) / 1000.0
        request.timeoutInterval = timeoutSeconds

        // Use strict prompts from EditorPrompts
        let systemPrompt = EditorPrompts.systemPrompt(for: mode, glossary: glossary)
        let userPrompt = EditorPrompts.userPrompt(for: mode, text: raw)

        // Use strict temperature and max_tokens
        let temperature = EditorPrompts.temperature(for: mode)
        let maxTokens = EditorPrompts.maxTokens(for: mode)

        #if DEBUG
            print(
                "[OpenAIEditor] Request: endpoint=\(chatCompletionsURL.absoluteString), model=\(preferences.editorModelName), temperature=\(temperature), max_tokens=\(maxTokens)"
            )
        #endif

        let body: [String: Any] = [
            "model": preferences.editorModelName,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userPrompt],
            ],
            "temperature": temperature,
            "max_tokens": maxTokens,
            "response_format": ["type": "json_object"],
        ]

        let requestData = try JSONSerialization.data(withJSONObject: body)
        request.httpBody = requestData

        #if DEBUG
            if let requestJSON = String(data: requestData, encoding: .utf8) {
                let truncated =
                    requestJSON.count > 1500
                    ? String(requestJSON.prefix(1500)) + "... [truncated]"
                    : requestJSON
                print("[OpenAIEditor] Raw request JSON: \(truncated)")
            }
        #endif

        return request
    }

    private func buildRepairRequest(
        malformedOutput: String,
        mode: OutputMode
    ) throws -> URLRequest {
        let chatCompletionsURL = try buildEndpointURL()

        var request = URLRequest(url: chatCompletionsURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        if let apiKey = preferences.editorAPIKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        request.timeoutInterval = 10.0  // Shorter timeout for repair

        let systemPrompt = EditorPrompts.repairSystemPrompt
        let userPrompt = EditorPrompts.repairUserPrompt(
            malformedOutput: malformedOutput,
            requiredSchema: EditorPrompts.schema(for: mode)
        )

        let body: [String: Any] = [
            "model": preferences.editorModelName,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userPrompt],
            ],
            "temperature": 0.0,
            "max_tokens": 512,
            "response_format": ["type": "json_object"],
        ]

        let requestData = try JSONSerialization.data(withJSONObject: body)
        request.httpBody = requestData

        return request
    }

    private func buildEndpointURL() throws -> URL {
        guard let endpointString = preferences.editorEndpointURL,
            let endpoint = URL(string: endpointString)
        else {
            throw EditorError.notConfigured("Invalid endpoint URL")
        }

        if endpointString.hasSuffix("/chat/completions") {
            return endpoint
        } else if endpointString.hasSuffix("/v1") {
            return endpoint.appendingPathComponent("chat/completions")
        } else {
            return
                endpoint
                .appendingPathComponent("v1")
                .appendingPathComponent("chat")
                .appendingPathComponent("completions")
        }
    }

    // MARK: - Request Execution

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

    private func extractContent(data: Data, response: URLResponse) throws -> String {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw EditorError.invalidResponse("Not an HTTP response")
        }

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

        #if DEBUG
            if let rawResponse = String(data: data, encoding: .utf8) {
                let truncated =
                    rawResponse.count > 2000
                    ? String(rawResponse.prefix(2000)) + "... [truncated]"
                    : rawResponse
                print("[OpenAIEditor] Raw API response: \(truncated)")
            }
        #endif

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = json["choices"] as? [[String: Any]],
            let firstChoice = choices.first,
            let message = firstChoice["message"] as? [String: Any],
            let content = message["content"] as? String
        else {
            throw EditorError.invalidResponse("Could not parse API response structure")
        }

        return content
    }

    // MARK: - Result Building

    private func buildSuccessResult(
        original: String,
        parsed: ParsedEditorOutput,
        safety: SafetySummary,
        latencyMs: Int
    ) -> EditedText {
        let replacements = parsed.replacements.map { pair in
            Replacement(
                original: TextSpan(text: pair.from, startIndex: 0, endIndex: pair.from.count),
                replacement: pair.to,
                reason: .other
            )
        }

        let report = EditReport(
            replacements: replacements,
            safety: safety,
            modelUsed: preferences.editorModelName,
            latencyMs: latencyMs,
            tokensUsed: nil
        )

        return EditedText(
            original: original,
            edited: parsed.renderedText,
            report: report
        )
    }

    private func buildFallbackResult(
        original: String,
        glossary: [DictionaryTerm],
        mode: OutputMode,
        latencyMs: Int
    ) -> EditedText {
        // Use deterministic post-processor instead of raw text
        let processed = TranscriptPostProcessor.process(
            text: original,
            glossary: glossary,
            mode: mode
        )

        let safety = SafetySummary(
            wordChangeRatio: 0,
            charInsertionRatio: 0,
            glossaryEnforced: true,
            passed: false,
            fallbackTriggered: true
        )

        let report = EditReport(
            replacements: [],
            safety: safety,
            modelUsed: "fallback",
            latencyMs: latencyMs,
            tokensUsed: nil
        )

        return EditedText(
            original: original,
            edited: processed,
            report: report
        )
    }
}
