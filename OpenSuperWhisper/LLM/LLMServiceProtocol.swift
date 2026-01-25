import Foundation

// MARK: - LLM Processing Mode

/// Determines the type of LLM post-processing to apply to transcriptions
enum LLMProcessingMode: String, Codable, CaseIterable {
    /// No LLM processing - return raw transcription
    case none
    /// Clean up punctuation, capitalization, and remove filler words
    case cleanup
    /// Summarize the transcription into key points
    case summarize
    /// Format the transcription as bullet points
    case formatAsBullets
    /// Use a custom prompt for processing
    case custom

    var displayName: String {
        switch self {
        case .none: return "None"
        case .cleanup: return "Clean Up"
        case .summarize: return "Summarize"
        case .formatAsBullets: return "Bullet Points"
        case .custom: return "Custom"
        }
    }

    var description: String {
        switch self {
        case .none:
            return "No post-processing - use raw transcription"
        case .cleanup:
            return "Fix punctuation, capitalization, and remove filler words"
        case .summarize:
            return "Summarize the transcription into key points"
        case .formatAsBullets:
            return "Format as a structured bullet list"
        case .custom:
            return "Apply custom prompt-based processing"
        }
    }
}

// MARK: - LLM Readiness

/// Represents the current readiness state of the LLM service
enum LLMReadiness: Equatable {
    /// LLM processing is disabled in settings (mode = none)
    case unavailable
    /// LLM mode configured but no model has been downloaded yet
    case noModelDownloaded
    /// Model exists on disk but is not currently loaded
    case modelDownloaded
    /// Model is currently being loaded into memory
    case modelLoading
    /// Model is loaded and ready for inference
    case modelLoaded

    var displayName: String {
        switch self {
        case .unavailable:
            return "Disabled"
        case .noModelDownloaded:
            return "No Model"
        case .modelDownloaded:
            return "Ready to Load"
        case .modelLoading:
            return "Loading..."
        case .modelLoaded:
            return "Ready"
        }
    }

    /// Whether the service is ready to process requests
    var isReady: Bool {
        self == .modelLoaded
    }

    /// Whether user action is required (e.g., download a model)
    var requiresUserAction: Bool {
        self == .noModelDownloaded
    }
}

// MARK: - LLM Error

/// Errors that can occur during LLM processing
enum LLMError: LocalizedError {
    /// LLM processing is not configured or enabled
    case notConfigured
    /// The requested backend is not available
    case backendUnavailable(String)
    /// Model file not found at expected path
    case modelNotFound(String)
    /// Not enough memory to load the model
    case insufficientMemory
    /// Model failed to load
    case modelLoadFailed(String)
    /// Processing request timed out
    case timeout
    /// The LLM returned an invalid or unparseable response
    case invalidResponse(String)
    /// Processing was cancelled
    case cancelled
    /// Foundation Models not available on this macOS version
    case foundationModelsUnavailable
    /// Generic error with underlying cause
    case processingFailed(Error)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "LLM processing is not configured"
        case .backendUnavailable(let backend):
            return "LLM backend '\(backend)' is not available"
        case .modelNotFound(let path):
            return "Model not found at: \(path)"
        case .insufficientMemory:
            return "Insufficient memory to load the LLM model"
        case .modelLoadFailed(let reason):
            return "Failed to load model: \(reason)"
        case .timeout:
            return "LLM processing timed out"
        case .invalidResponse(let detail):
            return "Invalid LLM response: \(detail)"
        case .cancelled:
            return "LLM processing was cancelled"
        case .foundationModelsUnavailable:
            return "Apple Foundation Models require macOS 26 or later"
        case .processingFailed(let error):
            return "LLM processing failed: \(error.localizedDescription)"
        }
    }
}

// MARK: - LLM Processing Result

/// Result of LLM text processing
struct LLMProcessingResult {
    /// The processed text
    let text: String
    /// The original text before processing
    let originalText: String
    /// Processing time in milliseconds
    let processingTimeMs: Int
    /// The mode used for processing
    let mode: LLMProcessingMode
    /// Whether the result came from the LLM (true) or fallback (false)
    let usedLLM: Bool
}

// MARK: - LLM Service Protocol

/// Protocol for LLM service implementations
protocol LLMServiceProtocol: AnyObject {
    /// Unique identifier for this service implementation
    var identifier: String { get }

    /// Display name for UI
    var displayName: String { get }

    /// Current readiness state
    var readiness: LLMReadiness { get async }

    /// Whether a model is currently loaded
    var isModelLoaded: Bool { get async }

    /// Process text using the specified mode
    /// - Parameters:
    ///   - text: The text to process
    ///   - mode: The processing mode to apply
    ///   - customPrompt: Optional custom prompt (used when mode is .custom)
    /// - Returns: The processed text result
    /// - Throws: LLMError on failure
    func process(
        text: String,
        mode: LLMProcessingMode,
        customPrompt: String?
    ) async throws -> LLMProcessingResult

    /// Load the model into memory
    /// - Parameter path: Path to the model file (nil to use default/configured path)
    func loadModel(at path: URL?) async throws

    /// Unload the model from memory
    func unloadModel() async

    /// Cancel any in-progress processing
    func cancel()
}

// MARK: - Default Implementation

extension LLMServiceProtocol {
    /// Process text with default parameters
    func process(text: String, mode: LLMProcessingMode) async throws -> LLMProcessingResult {
        try await process(text: text, mode: mode, customPrompt: nil)
    }
}
