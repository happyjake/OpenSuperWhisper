import Foundation

enum ShortcutType: String, Codable {
    case traditional
    case modifierOnly
}

@propertyWrapper
struct UserDefault<T> {
    let key: String
    let defaultValue: T
    
    var wrappedValue: T {
        get { UserDefaults.standard.object(forKey: key) as? T ?? defaultValue }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

@propertyWrapper
struct OptionalUserDefault<T> {
    let key: String
    
    var wrappedValue: T? {
        get { UserDefaults.standard.object(forKey: key) as? T }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

final class AppPreferences {
    static let shared = AppPreferences()
    private init() {}
    
    // Model settings
    @OptionalUserDefault(key: "selectedModelPath")
    var selectedModelPath: String?
    
    @UserDefault(key: "whisperLanguage", defaultValue: "auto")
    var whisperLanguage: String
    
    // Transcription settings
    @UserDefault(key: "translateToEnglish", defaultValue: false)
    var translateToEnglish: Bool
    
    @UserDefault(key: "suppressBlankAudio", defaultValue: false)
    var suppressBlankAudio: Bool
    
    @UserDefault(key: "showTimestamps", defaultValue: false)
    var showTimestamps: Bool
    
    @UserDefault(key: "temperature", defaultValue: 0.0)
    var temperature: Double
    
    @UserDefault(key: "noSpeechThreshold", defaultValue: 0.6)
    var noSpeechThreshold: Double
    
    @UserDefault(key: "initialPrompt", defaultValue: "")
    var initialPrompt: String
    
    @UserDefault(key: "useBeamSearch", defaultValue: false)
    var useBeamSearch: Bool
    
    @UserDefault(key: "beamSize", defaultValue: 5)
    var beamSize: Int
    
    @UserDefault(key: "debugMode", defaultValue: false)
    var debugMode: Bool
    
    @UserDefault(key: "playSoundOnRecordStart", defaultValue: false)
    var playSoundOnRecordStart: Bool

    @UserDefault(key: "keepMicrophoneWarm", defaultValue: false)
    var keepMicrophoneWarm: Bool

    @UserDefault(key: "autoCopyToClipboard", defaultValue: true)
    var autoCopyToClipboard: Bool

    @UserDefault(key: "autoPasteAfterCopy", defaultValue: false)
    var autoPasteAfterCopy: Bool

    @UserDefault(key: "hasCompletedOnboarding", defaultValue: false)
    var hasCompletedOnboarding: Bool
    
    @UserDefault(key: "useAsianAutocorrect", defaultValue: true)
    var useAsianAutocorrect: Bool
    
    @OptionalUserDefault(key: "selectedMicrophoneData")
    var selectedMicrophoneData: Data?

    // Language-specific initial prompts storage
    @OptionalUserDefault(key: "languagePromptsData")
    var languagePromptsData: Data?

    // Computed property for type-safe access to language prompts
    var languagePrompts: [String: String] {
        get {
            guard let data = languagePromptsData,
                  let prompts = try? JSONDecoder().decode([String: String].self, from: data) else {
                return [:]
            }
            return prompts
        }
        set {
            if let encoded = try? JSONEncoder().encode(newValue) {
                languagePromptsData = encoded
            }
        }
    }

    // MARK: - Shortcut Type Settings

    @UserDefault(key: "shortcutType", defaultValue: "traditional")
    var shortcutTypeRaw: String

    @OptionalUserDefault(key: "modifierShortcutFlags")
    var modifierShortcutFlags: Int?

    var shortcutType: ShortcutType {
        get { ShortcutType(rawValue: shortcutTypeRaw) ?? .traditional }
        set { shortcutTypeRaw = newValue.rawValue }
    }

    // MARK: - LLM Post-Processing Settings

    /// LLM processing mode (none, cleanup, summarize, formatAsBullets, custom)
    @UserDefault(key: "llmProcessingMode", defaultValue: "none")
    var llmProcessingModeRaw: String

    /// Custom prompt for LLM processing (used when mode is "custom")
    @OptionalUserDefault(key: "llmCustomPrompt")
    var llmCustomPrompt: String?

    /// Path to local LLM model file (for llama.cpp backend)
    @OptionalUserDefault(key: "llmModelPath")
    var llmModelPath: String?

    /// Timeout for LLM processing in seconds
    @UserDefault(key: "llmTimeoutSeconds", defaultValue: 30)
    var llmTimeoutSeconds: Int

    /// Whether to auto-load the LLM model on app startup
    @UserDefault(key: "llmAutoLoadModel", defaultValue: true)
    var llmAutoLoadModel: Bool

    /// LLM backend type (auto, appleFoundation, llamaCpp)
    @UserDefault(key: "llmBackendType", defaultValue: "auto")
    var llmBackendTypeRaw: String

    // Computed property for type-safe LLM processing mode access
    var llmProcessingMode: LLMProcessingMode {
        get { LLMProcessingMode(rawValue: llmProcessingModeRaw) ?? .none }
        set { llmProcessingModeRaw = newValue.rawValue }
    }

    // Computed property for type-safe LLM backend type access
    var llmBackendType: LLMBackendType {
        get { LLMBackendType(rawValue: llmBackendTypeRaw) ?? .auto }
        set { llmBackendTypeRaw = newValue.rawValue }
    }

    // MARK: - LLM Editor Settings (OpenAI-Compatible Remote API)

    @UserDefault(key: "editorEnabled", defaultValue: true)
    var editorEnabled: Bool

    @UserDefault(key: "editorBackendRaw", defaultValue: "auto")
    var editorBackendRaw: String

    @OptionalUserDefault(key: "editorEndpointURL")
    var editorEndpointURL: String?

    @OptionalUserDefault(key: "editorAPIKey")
    var editorAPIKey: String?

    @UserDefault(key: "editorModelName", defaultValue: "gpt-4o-mini")
    var editorModelName: String

    @UserDefault(key: "editorTimeoutMs", defaultValue: 10000)
    var editorTimeoutMs: Int

    @UserDefault(key: "editorMaxTokens", defaultValue: 1024)
    var editorMaxTokens: Int

    @UserDefault(key: "editorTemperature", defaultValue: 0.2)
    var editorTemperature: Double

    @UserDefault(key: "editorOutputModeRaw", defaultValue: "clean")
    var editorOutputModeRaw: String

    // Computed property for type-safe backend access
    var editorBackend: EditorBackend {
        get { EditorBackend(rawValue: editorBackendRaw) ?? .auto }
        set { editorBackendRaw = newValue.rawValue }
    }

    // Computed property for type-safe output mode access
    var editorOutputMode: OutputMode {
        get { OutputMode(rawValue: editorOutputModeRaw) ?? .clean }
        set { editorOutputModeRaw = newValue.rawValue }
    }

    // MARK: - Editor Debug Settings

    /// Enable local debug telemetry for the LLM editor
    @UserDefault(key: "editorDebugEnabled", defaultValue: false)
    var editorDebugEnabled: Bool
}
