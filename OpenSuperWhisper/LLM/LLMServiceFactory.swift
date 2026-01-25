import Foundation

// MARK: - LLM Backend Type

/// Supported LLM backend types
enum LLMBackendType: String, Codable, CaseIterable {
    /// Automatically select the best available backend
    case auto
    /// Apple Foundation Models (macOS 26+)
    case appleFoundation
    /// Local llama.cpp model (future implementation)
    case llamaCpp

    var displayName: String {
        switch self {
        case .auto: return "Auto"
        case .appleFoundation: return "Apple Foundation Models"
        case .llamaCpp: return "llama.cpp (Local)"
        }
    }

    var description: String {
        switch self {
        case .auto:
            return "Automatically select the best available backend"
        case .appleFoundation:
            return "Use Apple's built-in Foundation Models (requires macOS 26+)"
        case .llamaCpp:
            return "Use local llama.cpp for inference"
        }
    }

    /// Check if this backend is available on the current system
    var isAvailable: Bool {
        switch self {
        case .auto:
            return true
        case .appleFoundation:
            return LLMServiceFactory.isFoundationModelsAvailable
        case .llamaCpp:
            // llama.cpp is available if a model is configured and exists
            if let modelPath = AppPreferences.shared.llmModelPath,
               FileManager.default.fileExists(atPath: modelPath) {
                return true
            }
            return false
        }
    }
}

// MARK: - LLM Service Factory

/// Factory for creating LLM service instances
final class LLMServiceFactory {

    /// Shared instance
    static let shared = LLMServiceFactory()

    /// Cached service instance
    private var cachedService: (any LLMServiceProtocol)?
    private var cachedBackendType: LLMBackendType?

    private init() {}

    // MARK: - Runtime Detection

    /// Check if Apple Foundation Models are available (macOS 26+)
    static var isFoundationModelsAvailable: Bool {
        if #available(macOS 26, *) {
            return true
        }
        return false
    }

    /// Get the current macOS version
    static var macOSVersion: OperatingSystemVersion {
        ProcessInfo.processInfo.operatingSystemVersion
    }

    /// Check if running on macOS 26 or later
    static var isMacOS26OrLater: Bool {
        let version = macOSVersion
        return version.majorVersion >= 26
    }

    // MARK: - Service Creation

    /// Create or return cached LLM service based on preferences
    /// - Parameter backend: The backend type to use (defaults to auto)
    /// - Returns: An LLM service instance, or nil if no backend is available
    func getService(backend: LLMBackendType = .auto) -> (any LLMServiceProtocol)? {
        // Return cached service if backend hasn't changed
        if let cached = cachedService, cachedBackendType == backend {
            return cached
        }

        let service = createService(for: backend)
        cachedService = service
        cachedBackendType = backend
        return service
    }

    /// Create a new LLM service instance
    /// - Parameter backend: The backend type to use
    /// - Returns: An LLM service instance, or nil if no backend is available
    private func createService(for backend: LLMBackendType) -> (any LLMServiceProtocol)? {
        switch backend {
        case .auto:
            return createBestAvailableService()
        case .appleFoundation:
            return createFoundationModelsService()
        case .llamaCpp:
            return createLlamaCppService()
        }
    }

    /// Create the best available service based on system capabilities
    private func createBestAvailableService() -> (any LLMServiceProtocol)? {
        // Priority 1: Apple Foundation Models (macOS 26+)
        if let foundationService = createFoundationModelsService() {
            return foundationService
        }

        // Priority 2: llama.cpp (future implementation)
        if let llamaService = createLlamaCppService() {
            return llamaService
        }

        // No backend available
        return nil
    }

    /// Create Apple Foundation Models service if available
    private func createFoundationModelsService() -> (any LLMServiceProtocol)? {
        if #available(macOS 26, *) {
            return AppleFoundationLLMService()
        }
        return nil
    }

    /// Create llama.cpp service for local LLM inference
    private func createLlamaCppService() -> (any LLMServiceProtocol)? {
        // llama.cpp local inference is not available in v1
        // Future: Implement local model support
        return nil
    }

    // MARK: - Cache Management

    /// Clear the cached service instance
    func clearCache() {
        cachedService = nil
        cachedBackendType = nil
    }

    /// Refresh the service with updated preferences
    func refreshService(backend: LLMBackendType = .auto) -> (any LLMServiceProtocol)? {
        clearCache()
        return getService(backend: backend)
    }

    // MARK: - Backend Detection

    /// Get list of available backends on the current system
    static var availableBackends: [LLMBackendType] {
        LLMBackendType.allCases.filter { $0.isAvailable }
    }

    /// Check if any LLM backend is available
    static var isAnyBackendAvailable: Bool {
        // Always has .auto, but check if any real backend exists
        availableBackends.contains { $0 != .auto }
    }
}
