import Foundation

// MARK: - Apple Foundation LLM Service

/// LLM service implementation using Apple's Foundation Models (macOS 26+)
/// This is a stub implementation that will be completed when Apple ships the API
@available(macOS 26, *)
final class AppleFoundationLLMService: LLMServiceProtocol {

    // MARK: - Properties

    let identifier = "apple-foundation"
    let displayName = "Apple Foundation Models"

    /// Actor-isolated state for thread safety
    private let state = AppleFoundationServiceState()

    // MARK: - LLMServiceProtocol

    var readiness: LLMReadiness {
        get async {
            // Check if Foundation Models framework is available
            // For now, return based on loaded state
            if await state.isModelLoaded {
                return .modelLoaded
            }
            if await state.isLoading {
                return .modelLoading
            }
            // Foundation Models should be built-in on macOS 26+
            return .modelDownloaded
        }
    }

    var isModelLoaded: Bool {
        get async {
            await state.isModelLoaded
        }
    }

    func process(
        text: String,
        mode: LLMProcessingMode,
        customPrompt: String?
    ) async throws -> LLMProcessingResult {
        let startTime = Date()

        // Check if model is loaded, auto-load if needed
        if await !state.isModelLoaded {
            try await loadModel(at: nil)
        }

        // Check for cancellation
        if await state.isCancelled {
            throw LLMError.cancelled
        }

        // Build the prompt based on mode
        let prompt = buildPrompt(for: mode, text: text, customPrompt: customPrompt)

        // TODO: When Apple Foundation Models API is available, implement actual inference
        // For now, return a placeholder that indicates the feature is not yet available
        //
        // Expected implementation:
        // let session = FoundationModelSession()
        // let response = try await session.generate(prompt: prompt)
        // return LLMProcessingResult(...)

        let processingTimeMs = Int(Date().timeIntervalSince(startTime) * 1000)

        // Stub: Return original text with a note that Foundation Models is not yet implemented
        print("AppleFoundationLLMService: Foundation Models API not yet available, returning original text")

        return LLMProcessingResult(
            text: text,
            originalText: text,
            processingTimeMs: processingTimeMs,
            mode: mode,
            usedLLM: false
        )
    }

    func loadModel(at path: URL?) async throws {
        await state.setLoading(true)
        defer { Task { await state.setLoading(false) } }

        // Check memory before loading
        guard LLMMemoryManager.shared.canLoadModel() else {
            throw LLMError.insufficientMemory
        }

        // TODO: When Apple Foundation Models API is available, implement model initialization
        // Expected implementation:
        // let config = FoundationModelConfiguration()
        // self.modelSession = try await FoundationModelSession(configuration: config)

        // For now, mark as loaded (stub)
        await state.setModelLoaded(true)

        print("AppleFoundationLLMService: Model 'loaded' (stub implementation)")
    }

    func unloadModel() async {
        // TODO: When Apple Foundation Models API is available, implement cleanup
        // Expected implementation:
        // self.modelSession = nil

        await state.setModelLoaded(false)
        print("AppleFoundationLLMService: Model unloaded")
    }

    func cancel() {
        Task {
            await state.setCancelled(true)
        }
    }

    // MARK: - Private Methods

    private func buildPrompt(
        for mode: LLMProcessingMode,
        text: String,
        customPrompt: String?
    ) -> String {
        switch mode {
        case .none:
            return text

        case .cleanup:
            return """
            Clean up the following transcription. Fix punctuation, capitalization, and remove filler words (um, uh, like, you know). Do not change the meaning or add new content.

            Transcription:
            \(text)

            Cleaned text:
            """

        case .summarize:
            return """
            Summarize the following transcription into key points. Keep it concise and preserve the main ideas.

            Transcription:
            \(text)

            Summary:
            """

        case .formatAsBullets:
            return """
            Format the following transcription as a bullet point list. Extract the main points and organize them clearly.

            Transcription:
            \(text)

            Bullet points:
            """

        case .custom:
            if let customPrompt = customPrompt, !customPrompt.isEmpty {
                return """
                \(customPrompt)

                Text:
                \(text)
                """
            } else {
                // Fallback to cleanup if no custom prompt provided
                return buildPrompt(for: .cleanup, text: text, customPrompt: nil)
            }
        }
    }
}

// MARK: - Service State (Actor-Isolated)

@available(macOS 26, *)
private actor AppleFoundationServiceState {
    private(set) var isLoading: Bool = false
    private(set) var isModelLoaded: Bool = false
    private(set) var isCancelled: Bool = false

    func setLoading(_ loading: Bool) {
        isLoading = loading
    }

    func setModelLoaded(_ loaded: Bool) {
        isModelLoaded = loaded
        if loaded {
            isCancelled = false
        }
    }

    func setCancelled(_ cancelled: Bool) {
        isCancelled = cancelled
    }
}

// MARK: - Memory Manager Integration

@available(macOS 26, *)
extension AppleFoundationLLMService {
    /// Set up memory manager callbacks for this service
    func setupMemoryManagement() {
        LLMMemoryManager.shared.onMemoryPressureUnload = { [weak self] in
            await self?.unloadModel()
        }

        LLMMemoryManager.shared.onAppBackgrounded = { [weak self] in
            // Optionally unload when app is backgrounded to free memory
            if LLMMemoryManager.shared.autoUnloadOnBackground {
                await self?.unloadModel()
            }
        }
    }
}
