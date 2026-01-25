# LLM Editor Architecture Specification

## Overview

OpenSuperWhisper evolves into a two-stage transcription system:

1. **Whisper (ASR):** Extract raw words from audio
2. **LLM Editor:** Polish output for readability, structure, and correctness

**Policy:** When any LLM backend is configured, the editor is enabled by default. v1 focuses on remote OpenAI-compatible endpoints.

---

## 1. Architecture Overview

### Pipeline Diagram

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         TRANSCRIPTION PIPELINE                               │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  AudioRecorder                                                              │
│       │                                                                     │
│       ▼                                                                     │
│  temp WAV (16kHz mono)                                                      │
│       │                                                                     │
│       ▼                                                                     │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                    TranscriptionService                              │   │
│  │  ┌───────────────────────────────────────────────────────────────┐  │   │
│  │  │  WhisperDecodeCoordinator                                      │  │   │
│  │  │    • PCM float conversion                                      │  │   │
│  │  │    • MyWhisperContext.full()                                   │  │   │
│  │  │    • Raw transcript extraction                                 │  │   │
│  │  └───────────────────────────────────────────────────────────────┘  │   │
│  │                              │                                       │   │
│  │                              ▼                                       │   │
│  │  ┌───────────────────────────────────────────────────────────────┐  │   │
│  │  │  TranscriptPostProcessor (Deterministic Baseline)              │  │   │
│  │  │    1. Merge segments + normalize whitespace                    │  │   │
│  │  │    2. Dictionary term replacement (safe, exact match)          │  │   │
│  │  │    3. CJK autocorrect (asian-autocorrect library)              │  │   │
│  │  └───────────────────────────────────────────────────────────────┘  │   │
│  │                              │                                       │   │
│  │                              ▼                                       │   │
│  │  ┌───────────────────────────────────────────────────────────────┐  │   │
│  │  │  LLMEditor (MANDATORY when configured)                         │  │   │
│  │  │    4. Constrained edit: fix mistakes + formatting              │  │   │
│  │  │    5. Dictionary enforcement + mark uncertain spans            │  │   │
│  │  │    6. Mode formatting: verbatim/clean/notes/email/slack        │  │   │
│  │  └───────────────────────────────────────────────────────────────┘  │   │
│  │                              │                                       │   │
│  │                              ▼                                       │   │
│  │  ┌───────────────────────────────────────────────────────────────┐  │   │
│  │  │  Guardrails                                                    │  │   │
│  │  │    7. Diff check (flag if >30% words changed)                  │  │   │
│  │  │    8. Hallucination check (flag new named entities)            │  │   │
│  │  │    9. Fallback policy (if editor fails or unsafe)              │  │   │
│  │  └───────────────────────────────────────────────────────────────┘  │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                              │                                              │
│                              ▼                                              │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │  OutputRouter                                                        │   │
│  │    • Copy to clipboard                                               │   │
│  │    • Store in RecordingStore                                         │   │
│  │    • Auto-paste (if enabled)                                         │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Data Flow

```
Audio → PCM → Whisper → RawTranscript → PostProcessor → BaselineText
                                                              │
                                    ┌─────────────────────────┘
                                    │
                    [Editor Enabled?]─── No ──→ BaselineText → Output
                                    │
                                   Yes
                                    │
                                    ▼
                              LLMEditor.edit()
                                    │
                                    ▼
                              EditedText
                                    │
                                    ▼
                              Guardrails.validate()
                                    │
                        ┌───────────┴───────────┐
                        │                       │
                      Pass                    Fail
                        │                       │
                        ▼                       ▼
                  EditedText.text         BaselineText (fallback)
                        │                       │
                        └───────────┬───────────┘
                                    │
                                    ▼
                                 Output
```

---

## 1.1 Concurrency Safety

### Model Switching Protection

When a transcription is in progress, users must not be able to change LLM settings that would affect the current operation. The system must snapshot the editor configuration at transcription start.

```swift
// MARK: - LLMService Reference Snapshotting

/// Snapshot the LLMService reference when transcription starts
/// This prevents mid-transcription settings changes from affecting the current operation

// In TranscriptionService.transcribeAudio():
// After the model validation block, before loading the context

// Snapshot editor at transcription start to prevent mid-operation changes
let editorSnapshot: TextEditor?
if settings.editorEnabled {
    editorSnapshot = EditorFactory.createEditor(from: AppPreferences.shared)
} else {
    editorSnapshot = nil
}

// Later, use editorSnapshot instead of creating a new editor:
// After the Asian autocorrect block, before assembling final text

if let editor = editorSnapshot {
    // Use the snapshotted editor - settings changes during transcription won't affect this
    let editedResult = try await editor.edit(...)
}
```

```swift
// MARK: - SettingsViewModel Processing Guard

/// Add isProcessing check to prevent settings changes during transcription
extension SettingsViewModel {

    /// Whether a transcription is currently in progress
    /// Set by TranscriptionService, observed by settings UI
    @Published var isProcessing: Bool = false

    /// Computed property to disable editor settings during processing
    var canModifyEditorSettings: Bool {
        !isProcessing
    }

    // In the Settings UI, disable editor controls when processing:
    // TextField("Endpoint URL", text: $viewModel.editorEndpointURL)
    //     .disabled(!viewModel.canModifyEditorSettings)
}
```

### Integration Point

In `TranscriptionService.transcribeAudio()`:
1. Set `SettingsViewModel.shared.isProcessing = true` at method entry
2. Snapshot `editorSnapshot` immediately after validation
3. Use `editorSnapshot` (not fresh factory call) for the editor step
4. Set `SettingsViewModel.shared.isProcessing = false` in defer block

---

## 1.2 Memory Management

Large LLM models can consume significant memory. The system should proactively manage model lifecycle to prevent memory pressure.

### Memory Thresholds

```swift
// MARK: - Memory Constants

enum LLMMemoryConstants {
    /// Minimum free memory required before loading a model (2GB buffer)
    static let minimumFreeMemoryBytes: UInt64 = 2 * 1024 * 1024 * 1024

    /// Memory pressure threshold to trigger unload consideration
    static let pressureThresholdPercent: Double = 0.85
}
```

### Background State Observer

```swift
// MARK: - LLMMemoryManager

/// Manages LLM model lifecycle based on app state and memory pressure
final class LLMMemoryManager {
    static let shared = LLMMemoryManager()

    private var workspaceObserver: NSObjectProtocol?
    private var memoryPressureSource: DispatchSourceMemoryPressure?

    /// Whether to automatically unload models when app is backgrounded
    var autoUnloadOnBackground: Bool = true

    private init() {
        setupWorkspaceObserver()
        setupMemoryPressureObserver()
    }

    deinit {
        if let observer = workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        memoryPressureSource?.cancel()
    }

    // MARK: - Workspace Observer (App Background State)

    private func setupWorkspaceObserver() {
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didDeactivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self,
                  self.autoUnloadOnBackground,
                  let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == Bundle.main.bundleIdentifier else {
                return
            }

            // App moved to background - consider unloading model
            Task {
                await self.handleAppBackgrounded()
            }
        }
    }

    private func handleAppBackgrounded() async {
        // Only unload if enabled and model is loaded
        guard autoUnloadOnBackground,
              await LLMService.shared.isModelLoaded else {
            return
        }

        print("LLMMemoryManager: App backgrounded, unloading model to free memory")
        await LLMService.shared.unloadModel()
    }

    // MARK: - Memory Pressure Observer

    private func setupMemoryPressureObserver() {
        memoryPressureSource = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: .main
        )

        memoryPressureSource?.setEventHandler { [weak self] in
            guard let self = self,
                  let source = self.memoryPressureSource else { return }

            let event = source.data
            if event.contains(.critical) {
                print("LLMMemoryManager: CRITICAL memory pressure - forcing model unload")
                Task {
                    await LLMService.shared.unloadModel()
                }
            } else if event.contains(.warning) {
                print("LLMMemoryManager: Memory pressure WARNING - consider unloading")
                // Optionally unload on warning if model isn't actively being used
            }
        }

        memoryPressureSource?.resume()
    }

    // MARK: - Pre-Load Memory Check

    /// Check if sufficient memory is available before loading a model
    /// - Parameter estimatedModelSize: Estimated memory requirement for the model
    /// - Returns: Whether loading should proceed
    func canLoadModel(estimatedModelSize: UInt64) -> Bool {
        let freeMemory = getAvailableMemory()
        let requiredMemory = estimatedModelSize + LLMMemoryConstants.minimumFreeMemoryBytes

        if freeMemory < requiredMemory {
            print("LLMMemoryManager: Insufficient memory. Free: \(freeMemory / 1024 / 1024)MB, Required: \(requiredMemory / 1024 / 1024)MB")
            return false
        }

        return true
    }

    private func getAvailableMemory() -> UInt64 {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)

        let result = withUnsafeMutablePointer(to: &stats) { statsPtr in
            statsPtr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { pointer in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, pointer, &count)
            }
        }

        guard result == KERN_SUCCESS else {
            return 0
        }

        let pageSize = UInt64(vm_kernel_page_size)
        let freeMemory = UInt64(stats.free_count) * pageSize
        let inactiveMemory = UInt64(stats.inactive_count) * pageSize

        return freeMemory + inactiveMemory
    }
}
```

### Usage in LLMService

```swift
// Before loading a model in LLMService:
func loadModel(at path: URL) async throws {
    // Check memory before loading
    let estimatedSize: UInt64 = 4 * 1024 * 1024 * 1024  // 4GB estimate, adjust per model
    guard LLMMemoryManager.shared.canLoadModel(estimatedModelSize: estimatedSize) else {
        throw LLMError.insufficientMemory
    }

    // Proceed with loading...
}
```

---

## 1.3 LLM Readiness States

The system must clearly communicate the LLM editor's readiness state, especially on first run when no model may be downloaded yet.

```swift
// MARK: - LLMReadiness

/// Represents the current readiness state of the LLM editor subsystem
enum LLMReadiness: Equatable {
    /// LLM editing is disabled in settings (mode = none)
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

    var isReady: Bool {
        self == .modelLoaded
    }

    var requiresUserAction: Bool {
        self == .noModelDownloaded
    }
}
```

### First-Run UI Guidance

When the user has configured an LLM mode but no model is available:

```swift
// MARK: - LLMReadinessView

/// Shows guidance when LLM is configured but model needs action
struct LLMReadinessView: View {
    let readiness: LLMReadiness

    var body: some View {
        switch readiness {
        case .noModelDownloaded:
            VStack(spacing: 12) {
                Image(systemName: "arrow.down.circle")
                    .font(.largeTitle)
                    .foregroundColor(.orange)

                Text("Download Model Required")
                    .font(.headline)

                Text("You've enabled LLM editing, but no model is downloaded yet. Download a model to enable AI-powered transcription polishing.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)

                Button("Download Model") {
                    // Navigate to model download UI
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
            .background(Color.orange.opacity(0.1))
            .cornerRadius(12)

        case .modelLoading:
            HStack {
                ProgressView()
                    .scaleEffect(0.8)
                Text("Loading model...")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

        default:
            EmptyView()
        }
    }
}
```

### Readiness Check Integration

```swift
// In LLMService or equivalent:
var readiness: LLMReadiness {
    // Check if LLM editing is disabled
    guard AppPreferences.shared.editorEnabled else {
        return .unavailable
    }

    // Check if model exists on disk
    guard let modelPath = AppPreferences.shared.llmModelPath,
          FileManager.default.fileExists(atPath: modelPath) else {
        return .noModelDownloaded
    }

    // Check loading state
    if isLoading {
        return .modelLoading
    }

    // Check if loaded
    if isModelLoaded {
        return .modelLoaded
    }

    return .modelDownloaded
}
```

---

## 2. Data Models

### Core Types

```swift
// MARK: - Output Mode

/// Determines how the LLM editor formats the output
enum OutputMode: String, Codable, CaseIterable {
    case verbatim   // Fix punctuation + casing only
    case clean      // Light rewriting, remove filler/false starts
    case notes      // Bullets + headings structure
    case email      // Tone shaping for email communication
    case slack      // Casual tone for chat

    var displayName: String {
        switch self {
        case .verbatim: return "Verbatim"
        case .clean: return "Clean"
        case .notes: return "Notes"
        case .email: return "Email"
        case .slack: return "Slack"
        }
    }

    var description: String {
        switch self {
        case .verbatim: return "Minimal changes: punctuation and capitalization only"
        case .clean: return "Remove filler words, false starts, and light cleanup"
        case .notes: return "Structure as bullet points with optional headings"
        case .email: return "Format for professional email communication"
        case .slack: return "Casual, conversational tone for chat"
        }
    }
}
```

```swift
// MARK: - Editor Backend

/// Supported LLM backend types
enum EditorBackend: String, Codable, CaseIterable {
    case auto              // Use first available
    case openAICompatible  // Remote OpenAI-compatible API
    case llamaCpp          // Local llama.cpp server (future)
    case mlx               // Local MLX model (future)

    var displayName: String {
        switch self {
        case .auto: return "Auto"
        case .openAICompatible: return "OpenAI Compatible"
        case .llamaCpp: return "llama.cpp (Local)"
        case .mlx: return "MLX (Local)"
        }
    }

    var isAvailable: Bool {
        switch self {
        case .auto, .openAICompatible: return true
        case .llamaCpp, .mlx: return false  // Future implementation
        }
    }
}
```

```swift
// MARK: - Dictionary Term

/// A term in the user's custom dictionary for transcription bias
struct DictionaryTerm: Codable, Identifiable, Equatable {
    let id: UUID
    var term: String
    var caseSensitive: Bool
    var priority: Int  // Higher = stronger preference

    init(term: String, caseSensitive: Bool = false, priority: Int = 0) {
        self.id = UUID()
        self.term = term
        self.caseSensitive = caseSensitive
        self.priority = priority
    }
}
```

### Editor Output Types

```swift
// MARK: - Edited Text (MANDATORY output format)

/// The complete output from the LLM editor
struct EditedText: Codable {
    /// The final edited text
    let text: String

    /// Detailed report of all changes made
    let report: EditReport

    /// Original text before editing (for diff display)
    let originalText: String

    /// Time taken for editing in milliseconds
    let processingTimeMs: Int
}
```

```swift
// MARK: - Edit Report

/// Detailed breakdown of all edits performed
struct EditReport: Codable {
    /// All text replacements made (from → to)
    let replacements: [Replacement]

    /// Spans where the editor has low confidence
    let uncertainSpans: [TextSpan]

    /// Formatting actions taken (e.g., "Added paragraph break", "Created bullet list")
    let formattingActions: [String]

    /// Safety analysis summary
    let safety: SafetySummary

    /// Statistics
    var stats: EditStats {
        EditStats(
            totalReplacements: replacements.count,
            uncertainSpanCount: uncertainSpans.count,
            formattingActionCount: formattingActions.count
        )
    }
}

struct EditStats: Codable {
    let totalReplacements: Int
    let uncertainSpanCount: Int
    let formattingActionCount: Int
}
```

```swift
// MARK: - Replacement

/// A single text replacement
struct Replacement: Codable {
    /// Original text that was replaced
    let from: String

    /// New text after replacement
    let to: String

    /// Reason for the replacement
    let reason: ReplacementReason

    /// Character position in original text (optional)
    let position: Int?
}

enum ReplacementReason: String, Codable {
    case spelling           // Spelling correction
    case grammar            // Grammar fix
    case punctuation        // Punctuation adjustment
    case capitalization     // Case correction
    case fillerRemoval      // Removed filler word (um, uh, like)
    case falseStart         // Removed false start/repetition
    case dictionaryMatch    // Matched dictionary term
    case formatting         // Structural formatting change
    case clarity            // Clarity improvement
}
```

```swift
// MARK: - Text Span

/// A span of text with associated metadata
struct TextSpan: Codable {
    /// Start character index
    let start: Int

    /// End character index
    let end: Int

    /// The text content of this span
    let text: String

    /// Confidence level (0.0 - 1.0)
    let confidence: Double

    /// Why this span is marked
    let reason: String?
}
```

```swift
// MARK: - Safety Summary

/// Safety analysis of the edit
struct SafetySummary: Codable {
    /// Risk that new content was added (0.0 - 1.0)
    /// High values indicate potential hallucination
    let addedContentRisk: Double

    /// Risk that meaning was changed (0.0 - 1.0)
    /// High values indicate semantic drift
    let meaningChangeRisk: Double

    /// Whether the edit passed safety checks
    var isPassing: Bool {
        addedContentRisk < 0.3 && meaningChangeRisk < 0.3
    }

    /// Human-readable safety status
    var status: SafetyStatus {
        if addedContentRisk >= 0.5 || meaningChangeRisk >= 0.5 {
            return .unsafe
        } else if addedContentRisk >= 0.3 || meaningChangeRisk >= 0.3 {
            return .warning
        }
        return .safe
    }
}

enum SafetyStatus: String, Codable {
    case safe
    case warning
    case unsafe
}
```

```swift
// MARK: - Editor Metadata

/// Context passed to the editor for better results
struct EditorMetadata: Codable {
    /// Detected or selected language code
    let language: String?

    /// Audio duration in seconds
    let audioDurationSeconds: Float?

    /// Whether timestamps are included
    let hasTimestamps: Bool

    /// Number of Whisper segments
    let segmentCount: Int?

    /// Custom context/instructions from user
    let customContext: String?
}
```

### Error Types

```swift
// MARK: - Editor Errors

enum EditorError: LocalizedError {
    case notConfigured
    case backendUnavailable(EditorBackend)
    case networkError(Error)
    case timeout
    case invalidResponse
    case parseError(String)
    case rateLimited
    case authenticationFailed
    case safeguardTriggered(SafetySummary)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "LLM Editor is not configured"
        case .backendUnavailable(let backend):
            return "Backend '\(backend.displayName)' is not available"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .timeout:
            return "Editor request timed out"
        case .invalidResponse:
            return "Invalid response from editor"
        case .parseError(let detail):
            return "Failed to parse editor response: \(detail)"
        case .rateLimited:
            return "API rate limit exceeded"
        case .authenticationFailed:
            return "API authentication failed"
        case .safeguardTriggered(let summary):
            return "Safety check failed: added content risk \(summary.addedContentRisk), meaning change risk \(summary.meaningChangeRisk)"
        }
    }
}
```

---

## 3. API Contracts

### TextEditor Protocol

```swift
// MARK: - TextEditor Protocol

/// Protocol for all text editor implementations
protocol TextEditor {
    /// Unique identifier for this editor
    var identifier: String { get }

    /// Display name for UI
    var displayName: String { get }

    /// Whether the editor is currently available
    var isAvailable: Bool { get async }

    /// Edit the raw transcription text
    /// - Parameters:
    ///   - raw: The raw transcription from Whisper
    ///   - mode: The desired output format
    ///   - glossary: User's dictionary terms for enforcement
    ///   - language: Detected/selected language code
    ///   - metadata: Additional context for the editor
    /// - Returns: Edited text with detailed report
    /// - Throws: EditorError on failure
    func edit(
        raw: String,
        mode: OutputMode,
        glossary: [DictionaryTerm],
        language: String?,
        metadata: EditorMetadata
    ) async throws -> EditedText

    /// Validate configuration
    func validateConfiguration() async throws

    /// Cancel any in-progress edit
    func cancel()
}
```

### OpenAI-Compatible Editor Implementation

```swift
// MARK: - OpenAICompatibleEditor

/// Editor implementation for OpenAI-compatible APIs
final class OpenAICompatibleEditor: TextEditor {

    // MARK: - Properties

    let identifier = "openai-compatible"
    let displayName = "OpenAI Compatible"

    private let endpointURL: URL
    private let apiKey: String
    private let modelName: String
    private let timeout: TimeInterval
    private let maxTokens: Int
    private let temperature: Double

    private var currentTask: Task<EditedText, Error>?

    // MARK: - Initialization

    init(
        endpointURL: URL,
        apiKey: String,
        modelName: String,
        timeout: TimeInterval = 10.0,
        maxTokens: Int = 1024,
        temperature: Double = 0.2
    ) {
        self.endpointURL = endpointURL
        self.apiKey = apiKey
        self.modelName = modelName
        self.timeout = timeout
        self.maxTokens = maxTokens
        self.temperature = temperature
    }

    // MARK: - TextEditor Protocol

    var isAvailable: Bool {
        get async {
            do {
                try await validateConfiguration()
                return true
            } catch {
                return false
            }
        }
    }

    func edit(
        raw: String,
        mode: OutputMode,
        glossary: [DictionaryTerm],
        language: String?,
        metadata: EditorMetadata
    ) async throws -> EditedText {
        let startTime = Date()

        // Build the prompt
        let systemPrompt = buildSystemPrompt(mode: mode, glossary: glossary, language: language)
        let userPrompt = buildUserPrompt(raw: raw, metadata: metadata)

        // Create request
        let request = try buildRequest(systemPrompt: systemPrompt, userPrompt: userPrompt)

        // Execute with timeout
        let task = Task {
            try await executeRequest(request)
        }
        currentTask = task

        do {
            let response = try await withTimeout(timeout) {
                try await task.value
            }

            let processingTime = Int(Date().timeIntervalSince(startTime) * 1000)

            // Parse response
            return try parseResponse(response, originalText: raw, processingTimeMs: processingTime)
        } catch {
            if Task.isCancelled {
                throw EditorError.timeout
            }
            throw error
        }
    }

    func validateConfiguration() async throws {
        guard !apiKey.isEmpty else {
            throw EditorError.authenticationFailed
        }

        // Simple connectivity check
        var request = URLRequest(url: endpointURL.appendingPathComponent("models"))
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 5.0

        let (_, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw EditorError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200...299:
            return
        case 401, 403:
            throw EditorError.authenticationFailed
        case 429:
            throw EditorError.rateLimited
        default:
            throw EditorError.networkError(NSError(domain: "HTTP", code: httpResponse.statusCode))
        }
    }

    func cancel() {
        currentTask?.cancel()
        currentTask = nil
    }

    // MARK: - Private Methods

    private func buildRequest(systemPrompt: String, userPrompt: String) throws -> URLRequest {
        let chatURL = endpointURL.appendingPathComponent("chat/completions")

        var request = URLRequest(url: chatURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = timeout

        let body: [String: Any] = [
            "model": modelName,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userPrompt]
            ],
            "max_tokens": maxTokens,
            "temperature": temperature,
            "response_format": ["type": "json_object"]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private func executeRequest(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw EditorError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200...299:
            return data
        case 401, 403:
            throw EditorError.authenticationFailed
        case 429:
            throw EditorError.rateLimited
        default:
            throw EditorError.networkError(NSError(domain: "HTTP", code: httpResponse.statusCode))
        }
    }

    private func parseResponse(_ data: Data, originalText: String, processingTimeMs: Int) throws -> EditedText {
        // Parse OpenAI response format
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw EditorError.invalidResponse
        }

        // Parse the JSON content from the LLM
        guard let contentData = content.data(using: .utf8),
              let editResult = try? JSONDecoder().decode(LLMEditResponse.self, from: contentData) else {
            throw EditorError.parseError("Failed to parse LLM JSON response")
        }

        // Convert to EditedText
        return EditedText(
            text: editResult.editedText,
            report: EditReport(
                replacements: editResult.replacements.map { r in
                    Replacement(
                        from: r.from,
                        to: r.to,
                        reason: ReplacementReason(rawValue: r.reason) ?? .clarity,
                        position: r.position
                    )
                },
                uncertainSpans: editResult.uncertainSpans.map { s in
                    TextSpan(
                        start: s.start,
                        end: s.end,
                        text: s.text,
                        confidence: s.confidence,
                        reason: s.reason
                    )
                },
                formattingActions: editResult.formattingActions,
                safety: SafetySummary(
                    addedContentRisk: editResult.safety.addedContentRisk,
                    meaningChangeRisk: editResult.safety.meaningChangeRisk
                )
            ),
            originalText: originalText,
            processingTimeMs: processingTimeMs
        )
    }
}

// MARK: - LLM Response Types (Internal)

/// Expected JSON response from the LLM
private struct LLMEditResponse: Codable {
    let editedText: String
    let replacements: [LLMReplacement]
    let uncertainSpans: [LLMUncertainSpan]
    let formattingActions: [String]
    let safety: LLMSafety

    struct LLMReplacement: Codable {
        let from: String
        let to: String
        let reason: String
        let position: Int?
    }

    struct LLMUncertainSpan: Codable {
        let start: Int
        let end: Int
        let text: String
        let confidence: Double
        let reason: String?
    }

    struct LLMSafety: Codable {
        let addedContentRisk: Double
        let meaningChangeRisk: Double
    }
}
```

### Editor Factory

```swift
// MARK: - EditorFactory

/// Factory for creating editor instances
struct EditorFactory {

    /// Create an editor based on current preferences
    static func createEditor(from prefs: AppPreferences) -> TextEditor? {
        let backend = prefs.editorBackend

        switch backend {
        case .auto:
            return createBestAvailableEditor(from: prefs)
        case .openAICompatible:
            return createOpenAICompatibleEditor(from: prefs)
        case .llamaCpp, .mlx:
            return nil  // Future implementation
        }
    }

    private static func createBestAvailableEditor(from prefs: AppPreferences) -> TextEditor? {
        // Try OpenAI-compatible first
        if let editor = createOpenAICompatibleEditor(from: prefs) {
            return editor
        }
        // Future: try local backends
        return nil
    }

    private static func createOpenAICompatibleEditor(from prefs: AppPreferences) -> TextEditor? {
        guard let urlString = prefs.editorEndpointURL,
              let url = URL(string: urlString),
              let apiKey = prefs.editorAPIKey,
              !apiKey.isEmpty else {
            return nil
        }

        return OpenAICompatibleEditor(
            endpointURL: url,
            apiKey: apiKey,
            modelName: prefs.editorModelName,
            timeout: TimeInterval(prefs.editorTimeoutMs) / 1000.0,
            maxTokens: prefs.editorMaxTokens,
            temperature: prefs.editorTemperature
        )
    }
}
```

---

## 4. Prompt Engineering

### System Prompt Template

```swift
// MARK: - Prompt Builder

struct EditorPromptBuilder {

    static func buildSystemPrompt(
        mode: OutputMode,
        glossary: [DictionaryTerm],
        language: String?
    ) -> String {
        var prompt = """
        You are a transcription editor. Your task is to polish speech-to-text output while preserving the speaker's exact meaning.

        ## CRITICAL CONSTRAINTS
        - Do NOT add new facts or information
        - Do NOT invent missing words or complete thoughts
        - Do NOT change the speaker's intended meaning
        - Prefer MINIMAL changes - only fix clear errors
        - When uncertain, leave text unchanged and mark as uncertain

        ## OUTPUT MODE: \(mode.rawValue.uppercased())
        \(modeInstructions(for: mode))

        """

        // Add glossary if present
        if !glossary.isEmpty {
            prompt += """

            ## GLOSSARY (Enforce these exact spellings)
            \(glossary.map { "- \($0.term)" }.joined(separator: "\n"))

            When you encounter words that sound like glossary terms, use the exact spelling from the glossary.

            """
        }

        // Add language context
        if let lang = language {
            prompt += """

            ## LANGUAGE
            The transcription is in: \(lang)

            """
        }

        prompt += """

        ## REQUIRED JSON OUTPUT FORMAT
        Respond with ONLY valid JSON in this exact structure:
        ```json
        {
          "editedText": "The polished transcription text",
          "replacements": [
            {"from": "original", "to": "replacement", "reason": "spelling|grammar|punctuation|capitalization|fillerRemoval|falseStart|dictionaryMatch|formatting|clarity", "position": 0}
          ],
          "uncertainSpans": [
            {"start": 0, "end": 10, "text": "unclear part", "confidence": 0.5, "reason": "multiple interpretations possible"}
          ],
          "formattingActions": ["Added paragraph break", "Created bullet list"],
          "safety": {
            "addedContentRisk": 0.0,
            "meaningChangeRisk": 0.0
          }
        }
        ```

        ## SAFETY SCORING
        - addedContentRisk: 0.0 = no new content, 1.0 = significant additions
        - meaningChangeRisk: 0.0 = identical meaning, 1.0 = meaning changed

        Keep both scores as LOW as possible. If you're making significant changes, increase the scores honestly.
        """

        return prompt
    }

    private static func modeInstructions(for mode: OutputMode) -> String {
        switch mode {
        case .verbatim:
            return """
            Fix ONLY:
            - Punctuation (periods, commas, question marks)
            - Capitalization (sentence starts, proper nouns)
            - Clear typos from ASR errors

            Do NOT:
            - Remove any words (including fillers like "um", "uh")
            - Restructure sentences
            - Change word order
            """

        case .clean:
            return """
            Apply light editing:
            - Fix punctuation and capitalization
            - Remove filler words (um, uh, like, you know)
            - Remove false starts and immediate repetitions
            - Fix obvious ASR errors

            Do NOT:
            - Significantly restructure sentences
            - Add transition words
            - Change the speaker's vocabulary
            """

        case .notes:
            return """
            Format as structured notes:
            - Use bullet points for distinct ideas
            - Add headings for topic changes (if clear)
            - Remove filler words and false starts
            - Keep speaker's key phrases intact

            Structure:
            ## Topic (if identifiable)
            - Key point 1
            - Key point 2
            """

        case .email:
            return """
            Format for professional email:
            - Use complete sentences with proper punctuation
            - Remove verbal fillers and false starts
            - Maintain professional but natural tone
            - Add appropriate paragraph breaks

            Do NOT:
            - Add greetings or sign-offs (user will add those)
            - Make content more formal than speaker intended
            - Add information not present in original
            """

        case .slack:
            return """
            Format for casual chat:
            - Keep conversational tone
            - Remove excessive fillers but keep some natural ones
            - Use shorter sentences where appropriate
            - Light punctuation (fewer formal commas)

            Do NOT:
            - Make it too formal
            - Add emojis unless clearly intended
            - Change casual vocabulary to formal
            """
        }
    }

    static func buildUserPrompt(raw: String, metadata: EditorMetadata) -> String {
        var prompt = "Please edit the following transcription:\n\n"
        prompt += "---\n\(raw)\n---"

        if let context = metadata.customContext, !context.isEmpty {
            prompt += "\n\nAdditional context: \(context)"
        }

        return prompt
    }
}
```

---

## 4.3 Structured JSON I/O Format (REQUIRED)

### Input Schema

The editor receives structured JSON input to reduce model creativity and ensure consistent behavior:

```json
{
  "raw": "the raw transcript text from Whisper",
  "mode": "clean",
  "glossary": [
    {
      "term": "OpenSuperWhisper",
      "aliases": ["open super whisper", "opensuperwhisper", "open superwhisper"]
    },
    {
      "term": "MyWhisperContext",
      "aliases": ["my whisper context", "mywhispercontext"]
    }
  ],
  "language": "en",
  "constraints": {
    "maxInsertionPercent": 8,
    "enforceGlossary": true,
    "preserveNumbers": true
  }
}
```

### Output Schema

The editor MUST return this exact JSON structure:

```json
{
  "text": "The edited transcript text.",
  "report": {
    "replacements": [
      {
        "from": "open super whisper",
        "to": "OpenSuperWhisper",
        "reason": "dictionaryMatch",
        "position": 42
      }
    ],
    "uncertainSpans": [
      {
        "text": "unclear word",
        "position": 100,
        "confidence": 0.6,
        "reason": "multiple interpretations possible"
      }
    ],
    "formattingActions": [
      "added_paragraph_break",
      "capitalized_sentence",
      "removed_filler_um"
    ],
    "safety": {
      "addedContentRisk": 0.02,
      "meaningChangeRisk": 0.05
    }
  }
}
```

### Swift Models for JSON I/O

```swift
// MARK: - Editor Input

/// Structured input for the LLM editor
struct EditorInput: Codable {
    let raw: String
    let mode: String
    let glossary: [GlossaryEntry]
    let language: String?
    let constraints: EditorConstraints
}

struct GlossaryEntry: Codable {
    let term: String
    let aliases: [String]

    init(term: String, aliases: [String] = []) {
        self.term = term
        self.aliases = aliases.isEmpty ? [term.lowercased()] : aliases
    }
}

struct EditorConstraints: Codable {
    /// Maximum allowed insertion as percentage (default: 8%)
    let maxInsertionPercent: Int

    /// Whether to enforce glossary term replacements
    let enforceGlossary: Bool

    /// Whether to preserve numbers exactly as spoken
    let preserveNumbers: Bool

    static let `default` = EditorConstraints(
        maxInsertionPercent: 8,
        enforceGlossary: true,
        preserveNumbers: true
    )

    static let strict = EditorConstraints(
        maxInsertionPercent: 3,
        enforceGlossary: true,
        preserveNumbers: true
    )
}
```

### Updated Prompt Builder

```swift
extension EditorPromptBuilder {

    /// Build user prompt with structured JSON input
    static func buildStructuredUserPrompt(
        raw: String,
        mode: OutputMode,
        glossary: [DictionaryTerm],
        language: String?,
        constraints: EditorConstraints = .default
    ) -> String {
        let glossaryEntries = glossary.map { term in
            GlossaryEntry(
                term: term.term,
                aliases: generateAliases(for: term.term)
            )
        }

        let input = EditorInput(
            raw: raw,
            mode: mode.rawValue,
            glossary: glossaryEntries,
            language: language,
            constraints: constraints
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        guard let jsonData = try? encoder.encode(input),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            // Fallback to simple format
            return "Edit this transcript:\n\n\(raw)"
        }

        return jsonString
    }

    /// Generate common aliases for a term
    private static func generateAliases(for term: String) -> [String] {
        var aliases: [String] = []

        // Lowercase version
        aliases.append(term.lowercased())

        // Space-separated version (for camelCase/PascalCase)
        let spaced = term.replacingOccurrences(
            of: "([a-z])([A-Z])",
            with: "$1 $2",
            options: .regularExpression
        ).lowercased()
        if spaced != term.lowercased() {
            aliases.append(spaced)
        }

        // No-space version
        let noSpace = term.replacingOccurrences(of: " ", with: "").lowercased()
        if noSpace != term.lowercased() {
            aliases.append(noSpace)
        }

        return aliases
    }
}
```

---

## 5. Guardrails (Stricter - LLM is Core)

### 5.1 DiffGuard (REQUIRED)

Compute character-level diff between deterministic baseline and LLM output. **FAIL/FLAG if:**

| Check | Threshold | Action |
|-------|-----------|--------|
| Insertions exceed | +8% chars (strict modes: +3%) | FAIL |
| Numbers changed | Any number not in raw | FLAG |
| New named entities | Not in raw OR glossary | FAIL |
| Deletions exceed | -40% chars | FLAG |

```swift
// MARK: - DiffGuard

struct DiffGuard {

    struct DiffResult {
        let insertionPercent: Double
        let deletionPercent: Double
        let changedNumbers: [String]
        let newEntities: [String]
        let issues: [DiffIssue]

        var passed: Bool { issues.isEmpty }
    }

    enum DiffIssue: CustomStringConvertible {
        case excessiveInsertion(percent: Double, limit: Double)
        case numbersChanged(numbers: [String])
        case newEntitiesIntroduced(entities: [String])
        case excessiveDeletion(percent: Double)

        var description: String {
            switch self {
            case .excessiveInsertion(let percent, let limit):
                return "Insertion \(String(format: "%.1f", percent))% exceeds limit \(String(format: "%.1f", limit))%"
            case .numbersChanged(let numbers):
                return "Numbers changed: \(numbers.joined(separator: ", "))"
            case .newEntitiesIntroduced(let entities):
                return "New entities: \(entities.joined(separator: ", "))"
            case .excessiveDeletion(let percent):
                return "Deletion \(String(format: "%.1f", percent))% is excessive"
            }
        }
    }

    /// Analyze diff between original and edited text
    static func analyze(
        original: String,
        edited: String,
        glossary: [String],
        constraints: EditorConstraints
    ) -> DiffResult {
        var issues: [DiffIssue] = []

        // Calculate insertion/deletion percentages
        let originalLen = original.count
        let editedLen = edited.count

        let insertionPercent = originalLen > 0
            ? max(0, Double(editedLen - originalLen) / Double(originalLen) * 100)
            : 0
        let deletionPercent = originalLen > 0
            ? max(0, Double(originalLen - editedLen) / Double(originalLen) * 100)
            : 0

        // Check insertion limit
        let insertionLimit = Double(constraints.maxInsertionPercent)
        if insertionPercent > insertionLimit {
            issues.append(.excessiveInsertion(percent: insertionPercent, limit: insertionLimit))
        }

        // Check deletion (warn at 40%)
        if deletionPercent > 40 {
            issues.append(.excessiveDeletion(percent: deletionPercent))
        }

        // Check numbers
        let changedNumbers = findChangedNumbers(original: original, edited: edited)
        if constraints.preserveNumbers && !changedNumbers.isEmpty {
            issues.append(.numbersChanged(numbers: changedNumbers))
        }

        // Check new entities
        let newEntities = findNewEntities(
            original: original,
            edited: edited,
            glossary: glossary
        )
        if !newEntities.isEmpty {
            issues.append(.newEntitiesIntroduced(entities: newEntities))
        }

        return DiffResult(
            insertionPercent: insertionPercent,
            deletionPercent: deletionPercent,
            changedNumbers: changedNumbers,
            newEntities: newEntities,
            issues: issues
        )
    }

    /// Find numbers in edited text that weren't in original
    private static func findChangedNumbers(original: String, edited: String) -> [String] {
        let numberPattern = #"\b\d+(?:\.\d+)?(?:,\d{3})*(?:\s*(?:million|billion|thousand|k|m|b))?\b"#
        let regex = try? NSRegularExpression(pattern: numberPattern, options: .caseInsensitive)

        func extractNumbers(from text: String) -> Set<String> {
            guard let regex = regex else { return [] }
            let range = NSRange(text.startIndex..., in: text)
            let matches = regex.matches(in: text, range: range)
            return Set(matches.compactMap { match in
                Range(match.range, in: text).map { String(text[$0]).lowercased() }
            })
        }

        let originalNumbers = extractNumbers(from: original)
        let editedNumbers = extractNumbers(from: edited)
        let newNumbers = editedNumbers.subtracting(originalNumbers)

        return Array(newNumbers)
    }

    /// Find named entities in edited text not in original or glossary
    private static func findNewEntities(
        original: String,
        edited: String,
        glossary: [String]
    ) -> [String] {
        let originalEntities = extractEntities(from: original)
        let editedEntities = extractEntities(from: edited)
        let glossarySet = Set(glossary.map { $0.lowercased() })

        let newEntities = editedEntities.subtracting(originalEntities)
        let notInGlossary = newEntities.filter { !glossarySet.contains($0.lowercased()) }

        return Array(notInGlossary)
    }

    private static func extractEntities(from text: String) -> Set<String> {
        // Match capitalized words not at sentence start
        var entities: Set<String> = []
        let sentences = text.components(separatedBy: CharacterSet(charactersIn: ".!?"))

        for sentence in sentences {
            let words = sentence.trimmingCharacters(in: .whitespaces)
                .components(separatedBy: .whitespaces)

            for (index, word) in words.enumerated() {
                guard index > 0 else { continue }
                let clean = word.trimmingCharacters(in: .punctuationCharacters)
                if let first = clean.first, first.isUppercase, clean.count > 1 {
                    entities.insert(clean)
                }
            }
        }

        return entities
    }
}
```

### 5.2 Safety Fallback Policy (REQUIRED)

```
┌─────────────────────────────────────────────────────────────────┐
│                    EDITOR FALLBACK FLOW                          │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  1. Call editor.edit(raw, mode, constraints: .default)          │
│                      │                                          │
│                      ▼                                          │
│              [DiffGuard.analyze()]                              │
│                      │                                          │
│           ┌─────────┴─────────┐                                │
│         Pass                Fail                                │
│           │                   │                                 │
│           ▼                   ▼                                 │
│     Return edited     2. RETRY with strict mode                 │
│                              │                                  │
│                editor.edit(raw, mode, constraints: .strict)     │
│                              │                                  │
│                      [DiffGuard.analyze()]                      │
│                              │                                  │
│                   ┌─────────┴─────────┐                        │
│                 Pass                Fail                        │
│                   │                   │                         │
│                   ▼                   ▼                         │
│             Return edited    3. Return DETERMINISTIC            │
│                                  + log failure                  │
│                                  + save debug bundle            │
│                                                                 │
│  RULE: Never show hallucinated content to user                  │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

```swift
// MARK: - Editor with Fallback

struct EditorWithFallback {

    static func edit(
        raw: String,
        deterministicBaseline: String,
        mode: OutputMode,
        glossary: [DictionaryTerm],
        language: String?,
        editor: TextEditor
    ) async -> EditorResult {
        let glossaryTerms = glossary.map { $0.term }
        let startTime = Date()

        // Attempt 1: Normal constraints
        do {
            let result = try await editor.edit(
                raw: raw,
                mode: mode,
                glossary: glossary,
                language: language,
                metadata: EditorMetadata(
                    language: language,
                    audioDurationSeconds: nil,
                    hasTimestamps: false,
                    segmentCount: nil,
                    customContext: nil
                )
            )

            let diffResult = DiffGuard.analyze(
                original: deterministicBaseline,
                edited: result.text,
                glossary: glossaryTerms,
                constraints: .default
            )

            if diffResult.passed {
                return .success(result, attempt: 1)
            }

            // Log first attempt failure
            print("EditorWithFallback: Attempt 1 failed - \(diffResult.issues)")

        } catch {
            print("EditorWithFallback: Attempt 1 error - \(error)")
        }

        // Attempt 2: Strict constraints
        do {
            let strictResult = try await editor.edit(
                raw: raw,
                mode: .verbatim,  // Force verbatim for strict retry
                glossary: glossary,
                language: language,
                metadata: EditorMetadata(
                    language: language,
                    audioDurationSeconds: nil,
                    hasTimestamps: false,
                    segmentCount: nil,
                    customContext: "STRICT MODE: Make MINIMAL changes only. Do not add any content."
                )
            )

            let strictDiffResult = DiffGuard.analyze(
                original: deterministicBaseline,
                edited: strictResult.text,
                glossary: glossaryTerms,
                constraints: .strict
            )

            if strictDiffResult.passed {
                return .success(strictResult, attempt: 2)
            }

            print("EditorWithFallback: Attempt 2 (strict) failed - \(strictDiffResult.issues)")

        } catch {
            print("EditorWithFallback: Attempt 2 error - \(error)")
        }

        // Fallback: Return deterministic baseline
        let processingTime = Int(Date().timeIntervalSince(startTime) * 1000)
        return .fallback(
            deterministicBaseline,
            reason: "Both editor attempts failed safety checks",
            processingTimeMs: processingTime
        )
    }
}

enum EditorResult {
    case success(EditedText, attempt: Int)
    case fallback(String, reason: String, processingTimeMs: Int)

    var text: String {
        switch self {
        case .success(let edited, _): return edited.text
        case .fallback(let text, _, _): return text
        }
    }

    var usedEditor: Bool {
        if case .success = self { return true }
        return false
    }
}
```

### 5.3 Local Telemetry / Debug Bundle (REQUIRED)

Store debug information locally for troubleshooting. **NO network upload.**

**Location:** `~/Library/Application Support/[BundleID]/editor-debug/`

```swift
// MARK: - EditorDebugBundle

struct EditorDebugBundle: Codable {
    let timestamp: Date
    let sessionId: String

    // Inputs
    let rawTranscript: String
    let deterministicOutput: String
    let mode: String
    let glossary: [String]
    let language: String?

    // Outputs
    let editorOutput: String?
    let editorReport: EditReport?

    // Analysis
    let diffAnalysis: DiffAnalysis?
    let failureReasons: [String]
    let finalOutput: String
    let usedEditor: Bool

    struct DiffAnalysis: Codable {
        let insertionPercent: Double
        let deletionPercent: Double
        let changedNumbers: [String]
        let newEntities: [String]
    }
}

// MARK: - Debug Bundle Manager

final class EditorDebugManager {
    static let shared = EditorDebugManager()

    private let debugDirectory: URL
    private let maxBundleCount = 100  // Keep last 100 debug bundles
    private let maxBundleAge: TimeInterval = 7 * 24 * 60 * 60  // 7 days

    private init() {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!

        let bundleId = Bundle.main.bundleIdentifier ?? "OpenSuperWhisper"
        debugDirectory = appSupport
            .appendingPathComponent(bundleId)
            .appendingPathComponent("editor-debug")

        try? FileManager.default.createDirectory(
            at: debugDirectory,
            withIntermediateDirectories: true
        )

        // Cleanup old bundles on init
        Task { await cleanupOldBundles() }
    }

    /// Save a debug bundle
    func saveBundle(_ bundle: EditorDebugBundle) {
        let filename = "debug-\(bundle.sessionId)-\(Int(bundle.timestamp.timeIntervalSince1970)).json"
        let fileURL = debugDirectory.appendingPathComponent(filename)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        do {
            let data = try encoder.encode(bundle)
            try data.write(to: fileURL)
            print("EditorDebugManager: Saved debug bundle to \(filename)")
        } catch {
            print("EditorDebugManager: Failed to save debug bundle - \(error)")
        }
    }

    /// Load recent debug bundles
    func loadRecentBundles(limit: Int = 10) -> [EditorDebugBundle] {
        let fileManager = FileManager.default

        guard let files = try? fileManager.contentsOfDirectory(
            at: debugDirectory,
            includingPropertiesForKeys: [.creationDateKey],
            options: .skipsHiddenFiles
        ) else {
            return []
        }

        let jsonFiles = files
            .filter { $0.pathExtension == "json" }
            .sorted { url1, url2 in
                let date1 = (try? url1.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
                let date2 = (try? url2.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
                return date1 > date2
            }
            .prefix(limit)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        return jsonFiles.compactMap { url in
            guard let data = try? Data(contentsOf: url),
                  let bundle = try? decoder.decode(EditorDebugBundle.self, from: data) else {
                return nil
            }
            return bundle
        }
    }

    /// Cleanup old bundles
    private func cleanupOldBundles() async {
        let fileManager = FileManager.default
        let cutoffDate = Date().addingTimeInterval(-maxBundleAge)

        guard let files = try? fileManager.contentsOfDirectory(
            at: debugDirectory,
            includingPropertiesForKeys: [.creationDateKey],
            options: .skipsHiddenFiles
        ) else {
            return
        }

        let jsonFiles = files.filter { $0.pathExtension == "json" }

        // Sort by date, newest first
        let sortedFiles = jsonFiles.sorted { url1, url2 in
            let date1 = (try? url1.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
            let date2 = (try? url2.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
            return date1 > date2
        }

        // Remove files beyond count limit or age limit
        for (index, file) in sortedFiles.enumerated() {
            let shouldRemove: Bool
            if index >= maxBundleCount {
                shouldRemove = true
            } else if let creationDate = (try? file.resourceValues(forKeys: [.creationDateKey]))?.creationDate,
                      creationDate < cutoffDate {
                shouldRemove = true
            } else {
                shouldRemove = false
            }

            if shouldRemove {
                try? fileManager.removeItem(at: file)
            }
        }
    }
}
```

---

## 6. Dictionary Enforcement (LLM-driven)

### Glossary Injection Strategy

Dictionary terms are passed to the editor with explicit replacement instructions:

```swift
extension EditorPromptBuilder {

    static func buildGlossaryInstructions(glossary: [GlossaryEntry]) -> String {
        guard !glossary.isEmpty else { return "" }

        var instructions = """

        ## GLOSSARY ENFORCEMENT (CRITICAL)

        You MUST replace any occurrence of these aliases with their canonical form:

        """

        for entry in glossary {
            let aliasesList = entry.aliases.joined(separator: ", ")
            instructions += """

            - **\(entry.term)**
              Aliases: \(aliasesList)
              → Always replace aliases with: "\(entry.term)"

            """
        }

        instructions += """

        RULES:
        1. If you hear ANY alias, replace it with the canonical term
        2. If uncertain whether a word matches an alias, add it to uncertainSpans
        3. Do NOT guess - only replace clear matches
        4. Preserve the canonical term's exact casing

        """

        return instructions
    }
}
```

### DictionaryRewriter (Deterministic Fallback)

When the editor is disabled or fails, the deterministic `DictionaryRewriter` handles replacements:

```swift
// MARK: - DictionaryRewriter (Deterministic)

struct DictionaryRewriter {

    /// Apply dictionary replacements deterministically
    /// Used when editor is disabled or as fallback
    static func apply(
        text: String,
        glossary: [GlossaryEntry]
    ) -> (text: String, replacements: [Replacement]) {
        var result = text
        var replacements: [Replacement] = []

        for entry in glossary {
            for alias in entry.aliases {
                // Case-insensitive search
                let pattern = "\\b\(NSRegularExpression.escapedPattern(for: alias))\\b"
                guard let regex = try? NSRegularExpression(
                    pattern: pattern,
                    options: .caseInsensitive
                ) else { continue }

                let range = NSRange(result.startIndex..., in: result)
                let matches = regex.matches(in: result, range: range)

                // Process matches in reverse to preserve positions
                for match in matches.reversed() {
                    guard let matchRange = Range(match.range, in: result) else { continue }
                    let matchedText = String(result[matchRange])

                    // Skip if already canonical
                    if matchedText == entry.term { continue }

                    replacements.append(Replacement(
                        from: matchedText,
                        to: entry.term,
                        reason: .dictionaryMatch,
                        position: match.range.location
                    ))

                    result.replaceSubrange(matchRange, with: entry.term)
                }
            }
        }

        return (result, replacements)
    }
}
```

---

## 7. Implementation Plan (6 PRs)

### PR1 — Editor Foundation

**Scope:** Core types, protocol, preferences UI

**Files to create:**
- `Editor/TextEditor.swift` - Protocol + core types
- `Editor/EditorTypes.swift` - EditedText, EditReport, etc.
- `Editor/OutputMode.swift` - Output mode enum
- `Editor/EditorConstraints.swift` - Constraint types

**Files to modify:**
- `Utils/AppPreferences.swift` - Add editor preferences
- `Settings.swift` - Add Editor tab with:
  - Endpoint URL field
  - API Key field (masked)
  - Model name field
  - "Test Connection" button
  - Status indicator

**Acceptance:**
- [ ] Editor tab visible in Settings
- [ ] Preferences persist across app restart
- [ ] "Test Connection" validates API key

---

### PR2 — OpenAI-Compatible Client

**Scope:** HTTP client for OpenAI-compatible endpoints

**Files to create:**
- `Editor/OpenAICompatibleEditor.swift` - Full implementation
- `Editor/EditorPromptBuilder.swift` - Prompt construction
- `Editor/EditorFactory.swift` - Backend selection

**Features:**
- Works with OpenAI API (`api.openai.com/v1`)
- Works with local llama.cpp server (`localhost:8080/v1`)
- Works with Ollama (`localhost:11434/v1`)
- Supports `/v1/chat/completions` endpoint
- Configurable timeout (default 10s)
- Retry on 5xx errors (max 2 retries)
- Cancel support via Task cancellation

**Acceptance:**
- [ ] Successfully calls OpenAI API
- [ ] Successfully calls local Ollama
- [ ] Timeout works correctly
- [ ] Cancel aborts in-flight request

---

### PR3 — Pipeline Integration

**Scope:** Wire editor into TranscriptionService

**Files to modify:**
- `TranscriptionService.swift` - Insert editor after post-processing
- `Settings.swift` (struct) - Add editor settings
- `Settings.swift` (SettingsViewModel) - Add editor properties

**UI additions:**
- Status indicator in main UI: "Editor" / "Baseline"
- Processing indicator during editor call

**Acceptance:**
- [ ] Editor called when configured
- [ ] Baseline used when editor disabled
- [ ] UI shows which mode was used

---

### PR4 — Guardrails + Strict Retry

**Scope:** Safety validation and fallback logic

**Files to create:**
- `Editor/DiffGuard.swift` - Diff analysis
- `Editor/EditorWithFallback.swift` - Retry logic
- `Editor/EditorDebugManager.swift` - Debug bundle storage

**Features:**
- DiffGuard validates editor output
- Strict retry on first failure
- Fallback to deterministic on second failure
- Debug bundles saved locally

**Acceptance:**
- [ ] Hallucinated content rejected
- [ ] Strict retry attempted before fallback
- [ ] Debug bundles created in ~/Library/Application Support/
- [ ] Old bundles cleaned up automatically

---

### PR5 — Dictionary + Formatting

**Scope:** Enhanced glossary and mode improvements

**Files to modify:**
- `Editor/EditorPromptBuilder.swift` - Glossary injection
- `Editor/DictionaryRewriter.swift` - Deterministic fallback

**Improvements:**
- Glossary aliases generated automatically
- Notes mode: proper bullets/headings
- CJK: special handling instructions for editor

**Acceptance:**
- [ ] Glossary terms enforced by editor
- [ ] Notes mode produces structured output
- [ ] CJK text handled correctly

---

### PR6 — MLX Backend (Future)

> **Status:** FUTURE IMPLEMENTATION - This section provides architecture guidance for when MLX support is added.

**Scope:** True offline editing with local MLX models on Apple Silicon

**Files to create:**
- `Editor/MLXEditor.swift` - MLX model wrapper
- `Editor/MLXModelManager.swift` - Model download/management
- `Editor/MLXInference.swift` - Inference pipeline

**Features:**
- Download and manage MLX-format models
- Run inference locally on Apple Silicon GPU
- Performance guardrails (reject if too slow)
- Memory management for model loading/unloading

**Architecture Stub:**

```swift
// MARK: - MLXEditor (Future Implementation)

/// MLX-based local editor for Apple Silicon
/// Status: STUB - Not yet implemented
final class MLXEditor: TextEditor {
    let identifier = "mlx-local"
    let displayName = "MLX (Local)"

    private var model: Any?  // MLX model reference
    private var tokenizer: Any?  // Tokenizer

    var isAvailable: Bool {
        get async {
            // Check for Apple Silicon
            #if arch(arm64)
            return model != nil
            #else
            return false
            #endif
        }
    }

    func edit(
        raw: String,
        mode: OutputMode,
        glossary: [DictionaryTerm],
        language: String?,
        metadata: EditorMetadata
    ) async throws -> EditedText {
        // TODO: Implement MLX inference
        // 1. Tokenize input
        // 2. Build prompt from EditorPromptBuilder
        // 3. Run generation with MLX
        // 4. Parse structured output
        // 5. Return EditedText

        throw EditorError.backendUnavailable(.mlx)
    }

    func validateConfiguration() async throws {
        #if !arch(arm64)
        throw EditorError.backendUnavailable(.mlx)
        #endif

        guard model != nil else {
            throw EditorError.notConfigured
        }
    }

    func cancel() {
        // TODO: Implement MLX cancellation
    }
}

// MARK: - MLXModelManager (Future Implementation)

/// Manages MLX model downloads and lifecycle
/// Status: STUB - Not yet implemented
final class MLXModelManager {
    static let shared = MLXModelManager()

    /// Recommended models for transcription editing
    static let recommendedModels: [MLXModelSpec] = [
        MLXModelSpec(
            name: "Qwen2.5-1.5B-Instruct",
            huggingFaceRepo: "mlx-community/Qwen2.5-1.5B-Instruct-4bit",
            sizeGB: 1.2,
            minMemoryGB: 4,
            description: "Fast, good quality for short edits"
        ),
        MLXModelSpec(
            name: "Llama-3.2-3B-Instruct",
            huggingFaceRepo: "mlx-community/Llama-3.2-3B-Instruct-4bit",
            sizeGB: 2.1,
            minMemoryGB: 6,
            description: "Better quality, moderate speed"
        )
    ]

    func downloadModel(spec: MLXModelSpec, progress: @escaping (Double) -> Void) async throws -> URL {
        // TODO: Implement HuggingFace Hub download
        // Use mlx-lm patterns for model fetching
        throw EditorError.backendUnavailable(.mlx)
    }

    func loadModel(at path: URL) async throws {
        // TODO: Load MLX model into memory
        throw EditorError.backendUnavailable(.mlx)
    }

    func unloadModel() async {
        // TODO: Release MLX model memory
    }
}

struct MLXModelSpec {
    let name: String
    let huggingFaceRepo: String
    let sizeGB: Double
    let minMemoryGB: Int
    let description: String
}
```

**Implementation Notes:**
- Requires `mlx-swift` package when available
- Models should be 4-bit quantized for memory efficiency
- Target inference time: <5s for typical transcription length
- Must respect `LLMMemoryManager` constraints

**Acceptance:**
- [ ] Model downloads from HuggingFace Hub
- [ ] Model loads on Apple Silicon only
- [ ] Inference produces valid EditedText
- [ ] Falls back gracefully if too slow (>5s)
- [ ] Memory is released when backgrounded

---

## 8. Acceptance Criteria

### Functional Requirements

| ID | Requirement | Verification |
|----|-------------|--------------|
| F1 | If endpoint+key configured → LLM editor runs by default | Manual test |
| F2 | `clean` mode output consistently more readable than raw | A/B comparison |
| F3 | Guardrails prevent hallucinations | Unit tests |
| F4 | Numbers not in raw must be flagged/rejected | Unit tests |
| F5 | Entities not in raw/glossary must be rejected | Unit tests |
| F6 | If editor fails → app produces deterministic output | Integration test |
| F7 | Debug bundles saved locally | Manual verification |

### Performance Requirements

| ID | Requirement | Target |
|----|-------------|--------|
| P1 | Editor latency (OpenAI) | < 3s p95 |
| P2 | Editor latency (local) | < 5s p95 |
| P3 | Fallback decision | < 100ms |
| P4 | No UI freeze during editing | Async execution |

### Quality Requirements

| ID | Requirement | Measurement |
|----|-------------|-------------|
| Q1 | Editor improves readability | User feedback |
| Q2 | No semantic drift | Diff analysis |
| Q3 | Glossary terms enforced | 100% accuracy |
| Q4 | Graceful degradation | No crashes |

---

## 5. Guardrails

### Guardrail Implementation

```swift
// MARK: - Guardrails

struct Guardrails {

    /// Maximum allowed word change ratio before flagging
    static let maxWordChangeRatio = 0.08  // 8% for strict modes
    static let maxCharInsertionRatio = 0.08  // +8% char insertion limit

    /// Minimum safety score to pass
    static let minSafetyScore = 0.70  // Must have <0.30 risk

    /// Validate an edited result against safety criteria
    /// - Parameters:
    ///   - edited: The edited text result
    ///   - original: The original raw transcription
    /// - Returns: Validation result with details
    static func validate(edited: EditedText, original: String) -> GuardrailResult {
        var issues: [GuardrailIssue] = []

        // 1. Check word change ratio
        let changeRatio = calculateWordChangeRatio(original: original, edited: edited.text)
        if changeRatio > maxWordChangeRatio {
            issues.append(.excessiveChanges(ratio: changeRatio))
        }

        // 2. Check for new named entities (potential hallucination)
        let newEntities = detectNewNamedEntities(original: original, edited: edited.text)
        if !newEntities.isEmpty {
            issues.append(.newEntitiesDetected(entities: newEntities))
        }

        // 3. Check safety scores from LLM
        if !edited.report.safety.isPassing {
            issues.append(.safetyScoringFailed(summary: edited.report.safety))
        }

        // 4. Check for significant length increase (potential addition)
        let lengthRatio = Double(edited.text.count) / Double(max(original.count, 1))
        if lengthRatio > 1.5 {
            issues.append(.significantLengthIncrease(ratio: lengthRatio))
        }

        return GuardrailResult(
            passed: issues.isEmpty,
            issues: issues,
            wordChangeRatio: changeRatio,
            newEntities: newEntities
        )
    }

    /// Calculate the ratio of words changed between original and edited
    private static func calculateWordChangeRatio(original: String, edited: String) -> Double {
        let originalWords = Set(original.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }))
        let editedWords = Set(edited.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }))

        guard !originalWords.isEmpty else { return 0.0 }

        let addedWords = editedWords.subtracting(originalWords)
        let removedWords = originalWords.subtracting(editedWords)
        let changedCount = addedWords.count + removedWords.count

        return Double(changedCount) / Double(originalWords.count)
    }

    /// Detect named entities in edited text that weren't in original
    /// Simple heuristic: capitalized words not at sentence start
    private static func detectNewNamedEntities(original: String, edited: String) -> [String] {
        let originalEntities = extractPotentialEntities(from: original)
        let editedEntities = extractPotentialEntities(from: edited)

        return Array(editedEntities.subtracting(originalEntities))
    }

    private static func extractPotentialEntities(from text: String) -> Set<String> {
        var entities: Set<String> = []
        let sentences = text.components(separatedBy: CharacterSet(charactersIn: ".!?"))

        for sentence in sentences {
            let words = sentence.trimmingCharacters(in: .whitespaces).split(separator: " ")
            for (index, word) in words.enumerated() {
                // Skip first word of sentence
                if index == 0 { continue }

                let wordStr = String(word)
                // Check if capitalized (potential proper noun)
                if let first = wordStr.first, first.isUppercase {
                    // Remove punctuation
                    let clean = wordStr.trimmingCharacters(in: .punctuationCharacters)
                    if clean.count > 1 {
                        entities.insert(clean.lowercased())
                    }
                }
            }
        }

        return entities
    }
}

// MARK: - Guardrail Types

struct GuardrailResult {
    let passed: Bool
    let issues: [GuardrailIssue]
    let wordChangeRatio: Double
    let newEntities: [String]
}

enum GuardrailIssue {
    case excessiveChanges(ratio: Double)
    case newEntitiesDetected(entities: [String])
    case safetyScoringFailed(summary: SafetySummary)
    case significantLengthIncrease(ratio: Double)

    var description: String {
        switch self {
        case .excessiveChanges(let ratio):
            return "Too many words changed: \(Int(ratio * 100))%"
        case .newEntitiesDetected(let entities):
            return "New entities detected: \(entities.joined(separator: ", "))"
        case .safetyScoringFailed(let summary):
            return "Safety check failed: added risk \(summary.addedContentRisk), meaning risk \(summary.meaningChangeRisk)"
        case .significantLengthIncrease(let ratio):
            return "Text length increased significantly: \(Int(ratio * 100))%"
        }
    }
}
```

---

## 6. Settings Schema

### AppPreferences Additions

```swift
// Add to AppPreferences.swift

// MARK: - LLM Editor Settings

/// Whether the LLM editor is enabled (default: true if backend configured)
@UserDefault(key: "editorEnabled", defaultValue: true)
var editorEnabled: Bool

/// Selected editor backend
@UserDefault(key: "editorBackend", defaultValue: "auto")
var editorBackendRaw: String

var editorBackend: EditorBackend {
    get { EditorBackend(rawValue: editorBackendRaw) ?? .auto }
    set { editorBackendRaw = newValue.rawValue }
}

/// OpenAI-compatible endpoint URL (e.g., "https://api.openai.com/v1")
@OptionalUserDefault(key: "editorEndpointURL")
var editorEndpointURL: String?

/// API key for authentication (should use Keychain in production)
@OptionalUserDefault(key: "editorAPIKey")
var editorAPIKey: String?

/// Model name to use (e.g., "gpt-4o-mini", "gpt-4o")
@UserDefault(key: "editorModelName", defaultValue: "gpt-4o-mini")
var editorModelName: String

/// Request timeout in milliseconds
@UserDefault(key: "editorTimeoutMs", defaultValue: 10000)
var editorTimeoutMs: Int

/// Maximum tokens for response
@UserDefault(key: "editorMaxTokens", defaultValue: 1024)
var editorMaxTokens: Int

/// Temperature for generation (0.0 - 1.0)
@UserDefault(key: "editorTemperature", defaultValue: 0.2)
var editorTemperature: Double

/// Default output mode
@UserDefault(key: "editorOutputMode", defaultValue: "clean")
var editorOutputModeRaw: String

var editorOutputMode: OutputMode {
    get { OutputMode(rawValue: editorOutputModeRaw) ?? .clean }
    set { editorOutputModeRaw = newValue.rawValue }
}

/// Whether editor is properly configured
var isEditorConfigured: Bool {
    guard let url = editorEndpointURL, !url.isEmpty,
          let key = editorAPIKey, !key.isEmpty else {
        return false
    }
    return true
}
```

---

## 7. UI Wireframes

### Settings Panel - Editor Tab

```
┌─────────────────────────────────────────────────────────────────┐
│  Shortcuts │ Model │ Transcription │ Editor │ Advanced │ About │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  LLM Editor                                                     │
│  ─────────────────────────────────────────────────────────────  │
│                                                                 │
│  ┌─────────────────────────────────────────────────────────────┐│
│  │ Enable LLM Editor                              [=========]  ││
│  │                                                             ││
│  │ Polishes transcription using AI for better readability      ││
│  └─────────────────────────────────────────────────────────────┘│
│                                                                 │
│  Backend Configuration                                          │
│  ─────────────────────────────────────────────────────────────  │
│                                                                 │
│  ┌─────────────────────────────────────────────────────────────┐│
│  │ Backend:        [OpenAI Compatible ▼]                       ││
│  │                                                             ││
│  │ Endpoint URL:   [https://api.openai.com/v1          ]      ││
│  │                                                             ││
│  │ API Key:        [••••••••••••••••••••••••••••••••••]  [👁]  ││
│  │                                                             ││
│  │ Model:          [gpt-4o-mini                        ]       ││
│  │                                                             ││
│  │ Status:         ● Connected                                 ││
│  │                 [Test Connection]                           ││
│  └─────────────────────────────────────────────────────────────┘│
│                                                                 │
│  Output Mode                                                    │
│  ─────────────────────────────────────────────────────────────  │
│                                                                 │
│  ┌─────────────────────────────────────────────────────────────┐│
│  │ Default Mode:   [Clean ▼]                                   ││
│  │                                                             ││
│  │ ○ Verbatim  - Punctuation and capitalization only           ││
│  │ ● Clean     - Remove fillers, light cleanup                 ││
│  │ ○ Notes     - Bullet points with headings                   ││
│  │ ○ Email     - Professional email format                     ││
│  │ ○ Slack     - Casual chat format                            ││
│  └─────────────────────────────────────────────────────────────┘│
│                                                                 │
│  Advanced                                                       │
│  ─────────────────────────────────────────────────────────────  │
│                                                                 │
│  ┌─────────────────────────────────────────────────────────────┐│
│  │ Timeout:        [10000] ms                                  ││
│  │ Max Tokens:     [1024]                                      ││
│  │ Temperature:    [0.2]  ────●───────────────                 ││
│  │                 Conservative        Creative                ││
│  └─────────────────────────────────────────────────────────────┘│
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### Quick Mode Selector (Optional - in main UI)

```
┌───────────────────────────────────┐
│  Output: [Clean ▼]                │
│  ┌─────────────────────────────┐  │
│  │ ✓ Clean                     │  │
│  │   Verbatim                  │  │
│  │   Notes                     │  │
│  │   Email                     │  │
│  │   Slack                     │  │
│  └─────────────────────────────┘  │
└───────────────────────────────────┘
```

---

## 8. Integration Points

### TranscriptionService.swift Modifications

**Location:** After the Asian autocorrect block, before `let finalText = `

Look for this pattern in `transcribeAudio()`:
```swift
// EXISTING CODE - Find this block:
if ["zh", "ja", "ko"].contains(effectiveLanguage) && settings.useAsianAutocorrect {
    processedText = autocorrect(processedText)
}
// END OF EXISTING BLOCK

// INSERT NEW CODE HERE (before finalText assignment)
```

```swift
// Current code pattern:
// var processedText = cleanedText
// if ["zh", "ja", "ko"].contains(effectiveLanguage) && settings.useAsianAutocorrect ...

// ADD AFTER LINE 378:

// === LLM EDITOR INTEGRATION START ===

// Apply LLM editor if configured and enabled
if settings.editorEnabled, let editor = EditorFactory.createEditor(from: AppPreferences.shared) {
    do {
        let metadata = EditorMetadata(
            language: effectiveLanguage,
            audioDurationSeconds: durationInSeconds,
            hasTimestamps: settings.showTimestamps,
            segmentCount: nSegments,
            customContext: nil
        )

        let glossary = settings.dictionaryTerms.map { term in
            DictionaryTerm(term: term)
        }

        print("TranscriptionService: Applying LLM editor (mode: \(settings.editorOutputMode.rawValue))")

        let editedResult = try await editor.edit(
            raw: processedText,
            mode: settings.editorOutputMode,
            glossary: glossary,
            language: effectiveLanguage,
            metadata: metadata
        )

        // Run guardrails
        let guardrailResult = Guardrails.validate(edited: editedResult, original: processedText)

        if guardrailResult.passed {
            processedText = editedResult.text
            print("TranscriptionService: LLM edit applied successfully")
            print("TranscriptionService: Replacements: \(editedResult.report.replacements.count)")
        } else {
            print("TranscriptionService: Guardrails failed, using baseline text")
            for issue in guardrailResult.issues {
                print("  - \(issue.description)")
            }
            // Keep processedText as-is (deterministic baseline)
        }
    } catch {
        print("TranscriptionService: LLM editor failed: \(error.localizedDescription)")
        // Keep processedText as-is (deterministic baseline)
    }
}

// === LLM EDITOR INTEGRATION END ===

let finalText = processedText.isEmpty ? "No speech detected in the audio" : processedText
```

### Settings.swift Modifications

**Add to Settings struct:**

```swift
struct Settings {
    // ... existing properties ...

    // LLM Editor settings
    var editorEnabled: Bool
    var editorOutputMode: OutputMode

    init() {
        // ... existing init ...
        self.editorEnabled = prefs.editorEnabled && prefs.isEditorConfigured
        self.editorOutputMode = prefs.editorOutputMode
    }
}
```

**Add to SettingsViewModel:**

```swift
class SettingsViewModel: ObservableObject {
    // ... existing properties ...

    @Published var editorEnabled: Bool {
        didSet { AppPreferences.shared.editorEnabled = editorEnabled }
    }

    @Published var editorBackend: EditorBackend {
        didSet { AppPreferences.shared.editorBackend = editorBackend }
    }

    @Published var editorEndpointURL: String {
        didSet { AppPreferences.shared.editorEndpointURL = editorEndpointURL.isEmpty ? nil : editorEndpointURL }
    }

    @Published var editorAPIKey: String {
        didSet { AppPreferences.shared.editorAPIKey = editorAPIKey.isEmpty ? nil : editorAPIKey }
    }

    @Published var editorModelName: String {
        didSet { AppPreferences.shared.editorModelName = editorModelName }
    }

    @Published var editorOutputMode: OutputMode {
        didSet { AppPreferences.shared.editorOutputMode = editorOutputMode }
    }

    @Published var editorTimeoutMs: Int {
        didSet { AppPreferences.shared.editorTimeoutMs = editorTimeoutMs }
    }

    @Published var editorMaxTokens: Int {
        didSet { AppPreferences.shared.editorMaxTokens = editorMaxTokens }
    }

    @Published var editorTemperature: Double {
        didSet { AppPreferences.shared.editorTemperature = editorTemperature }
    }

    @Published var editorConnectionStatus: EditorConnectionStatus = .unknown

    // Init additions
    init() {
        // ... existing init ...
        self.editorEnabled = prefs.editorEnabled
        self.editorBackend = prefs.editorBackend
        self.editorEndpointURL = prefs.editorEndpointURL ?? ""
        self.editorAPIKey = prefs.editorAPIKey ?? ""
        self.editorModelName = prefs.editorModelName
        self.editorOutputMode = prefs.editorOutputMode
        self.editorTimeoutMs = prefs.editorTimeoutMs
        self.editorMaxTokens = prefs.editorMaxTokens
        self.editorTemperature = prefs.editorTemperature
    }

    func testEditorConnection() async {
        editorConnectionStatus = .testing

        guard let editor = EditorFactory.createEditor(from: AppPreferences.shared) else {
            editorConnectionStatus = .notConfigured
            return
        }

        do {
            try await editor.validateConfiguration()
            editorConnectionStatus = .connected
        } catch {
            editorConnectionStatus = .failed(error.localizedDescription)
        }
    }
}

enum EditorConnectionStatus: Equatable {
    case unknown
    case testing
    case connected
    case notConfigured
    case failed(String)
}
```

### New Files to Create

1. `OpenSuperWhisper/Editor/TextEditor.swift` - Protocol and types
2. `OpenSuperWhisper/Editor/OpenAICompatibleEditor.swift` - OpenAI implementation
3. `OpenSuperWhisper/Editor/EditorFactory.swift` - Factory for creating editors
4. `OpenSuperWhisper/Editor/EditorPromptBuilder.swift` - Prompt construction
5. `OpenSuperWhisper/Editor/Guardrails.swift` - Safety validation
6. `OpenSuperWhisper/Editor/OutputMode.swift` - Output mode enum

---

## 9. Error Handling

### 9.1 Timeout Handling with Abort Callback

For local LLM inference (llama.cpp), we need a cooperative abort mechanism similar to `whisper_abort_callback`. This allows graceful cancellation without leaving the model in an inconsistent state.

```swift
// MARK: - LLM Abort Callback Mechanism

/// Protocol for LLM backends that support abort callbacks
protocol AbortableInference {
    /// Set an abort callback that will be checked during inference
    /// The callback returns true to abort, false to continue
    func setAbortCallback(_ callback: @escaping () -> Bool)

    /// Clear the abort callback
    func clearAbortCallback()
}

/// Cancellation token for thread-safe abort signaling
final class LLMCancellationToken: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: false)

    var isCancelled: Bool {
        lock.withLock { $0 }
    }

    func cancel() {
        lock.withLock { $0 = true }
    }

    func reset() {
        lock.withLock { $0 = false }
    }
}
```

### llama.cpp Abort Integration

```c
// For llama.cpp backend, use llama_set_abort_callback:

#include "llama.h"

// C callback function
bool llama_abort_callback_wrapper(void* user_data) {
    LLMCancellationToken* token = (LLMCancellationToken*)user_data;
    return token->isCancelled;
}

// Usage in Swift wrapper:
// llama_set_abort_callback(ctx, llama_abort_callback_wrapper, Unmanaged.passUnretained(token).toOpaque())
```

```swift
// MARK: - LlamaEditor with Abort Support

final class LlamaEditor: TextEditor, AbortableInference {
    private var context: OpaquePointer?
    private var cancellationToken = LLMCancellationToken()

    func setAbortCallback(_ callback: @escaping () -> Bool) {
        // Bridge to llama.cpp abort callback
        // llama_set_abort_callback(context, callback_wrapper, context_ptr)
    }

    func clearAbortCallback() {
        // llama_set_abort_callback(context, nil, nil)
    }

    func cancel() {
        cancellationToken.cancel()
    }

    func edit(...) async throws -> EditedText {
        // Reset cancellation state for new operation
        cancellationToken.reset()

        // Set up abort callback before inference
        setAbortCallback { [weak self] in
            self?.cancellationToken.isCancelled ?? true
        }

        defer {
            clearAbortCallback()
        }

        // Run inference with timeout wrapper
        return try await withTimeoutAndAbort(timeout) {
            try await self.runInference(...)
        }
    }
}
```

### Enhanced Timeout Wrapper

```swift
/// Execute an async operation with timeout and abort support
func withTimeoutAndAbort<T>(
    _ seconds: TimeInterval,
    abortable: AbortableInference? = nil,
    operation: @escaping () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }

        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            // Signal abort before throwing
            abortable?.cancel()
            throw EditorError.timeout
        }

        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}

/// Simple timeout wrapper (for remote APIs)
func withTimeout<T>(_ seconds: TimeInterval, operation: @escaping () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }

        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw EditorError.timeout
        }

        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}
```

### 9.2 Thread Safety Guarantees

For local LLM inference, all mutable state must be properly synchronized. The `@unchecked Sendable` pattern should be avoided where possible.

#### Atomic Operations with OSAllocatedUnfairLock

```swift
import os

// MARK: - Thread-Safe Cancellation Token

/// Thread-safe cancellation token using OSAllocatedUnfairLock
/// This replaces @unchecked Sendable patterns with proper synchronization
final class LLMCancellationToken: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: CancellationState())

    struct CancellationState {
        var isCancelled: Bool = false
        var reason: CancellationReason = .none
    }

    enum CancellationReason {
        case none
        case timeout
        case userRequested
        case memoryPressure
    }

    var isCancelled: Bool {
        state.withLock { $0.isCancelled }
    }

    var cancellationReason: CancellationReason {
        state.withLock { $0.reason }
    }

    func cancel(reason: CancellationReason = .userRequested) {
        state.withLock {
            $0.isCancelled = true
            $0.reason = reason
        }
    }

    func reset() {
        state.withLock {
            $0.isCancelled = false
            $0.reason = .none
        }
    }
}
```

#### Actor Isolation for LLM Service State

```swift
// MARK: - LLMService with Actor Isolation

/// Use actors for complex state management instead of manual locking
actor LLMServiceState {
    private(set) var isLoading: Bool = false
    private(set) var isModelLoaded: Bool = false
    private(set) var currentModelPath: URL?
    private(set) var lastError: Error?

    func setLoading(_ loading: Bool) {
        isLoading = loading
    }

    func setModelLoaded(_ loaded: Bool, path: URL?) {
        isModelLoaded = loaded
        currentModelPath = path
    }

    func setError(_ error: Error?) {
        lastError = error
    }
}

// Usage in LLMService:
final class LLMService {
    static let shared = LLMService()

    private let state = LLMServiceState()
    private let cancellationToken = LLMCancellationToken()

    var isModelLoaded: Bool {
        get async { await state.isModelLoaded }
    }

    func loadModel(at path: URL) async throws {
        await state.setLoading(true)
        defer { Task { await state.setLoading(false) } }

        // Loading logic...
    }
}
```

#### Thread Safety Documentation

When implementing local backends, document these guarantees:

| Component | Thread Safety | Mechanism |
|-----------|--------------|-----------|
| `LLMCancellationToken.isCancelled` | Safe | `OSAllocatedUnfairLock` |
| `LLMServiceState` | Safe | Actor isolation |
| `LlamaContext` (llama.cpp) | Unsafe | Single-threaded access required |
| Model loading | Safe | Actor + async/await |
| Inference calls | Unsafe | One inference at a time per context |

**IMPORTANT**: llama.cpp contexts are NOT thread-safe. Never share a context across threads or run multiple inferences concurrently on the same context.

---

### API Error Mapping

| HTTP Status | EditorError | User Message |
|-------------|-------------|--------------|
| 401, 403 | `.authenticationFailed` | "API authentication failed. Check your API key." |
| 429 | `.rateLimited` | "API rate limit exceeded. Try again later." |
| 500-599 | `.networkError` | "Server error. The API may be temporarily unavailable." |
| Timeout | `.timeout` | "Request timed out. Try increasing the timeout in settings." |

### Fallback Logic

```swift
// In TranscriptionService, after editor call:

let finalText: String
do {
    let edited = try await editor.edit(...)
    let guardrails = Guardrails.validate(edited: edited, original: processedText)

    if guardrails.passed {
        finalText = edited.text
    } else {
        // Guardrail failure: use baseline
        print("Guardrails failed: \(guardrails.issues.map { $0.description })")
        finalText = processedText
    }
} catch EditorError.timeout {
    // Timeout: use baseline, log warning
    print("Editor timed out, using baseline")
    finalText = processedText
} catch EditorError.rateLimited {
    // Rate limited: use baseline, show user notification
    print("Rate limited, using baseline")
    finalText = processedText
    // TODO: Show user notification
} catch {
    // Other errors: use baseline
    print("Editor error: \(error), using baseline")
    finalText = processedText
}
```

---

## 10. Implementation Checklist

### Phase 1: Core Infrastructure
- [ ] Create `Editor/` directory structure
- [ ] Implement `OutputMode` enum
- [ ] Implement `EditorBackend` enum
- [ ] Implement `DictionaryTerm` struct
- [ ] Implement `EditedText` and related structs
- [ ] Implement `EditorError` enum

### Phase 2: Protocol & Factory
- [ ] Implement `TextEditor` protocol
- [ ] Implement `EditorFactory`
- [ ] Add timeout utility function

### Phase 3: OpenAI Backend
- [ ] Implement `OpenAICompatibleEditor`
- [ ] Implement `EditorPromptBuilder`
- [ ] Test with OpenAI API
- [ ] Test with local Ollama (OpenAI-compatible)

### Phase 4: Guardrails
- [ ] Implement `Guardrails` struct
- [ ] Implement word change ratio calculation
- [ ] Implement named entity detection
- [ ] Implement safety score validation

### Phase 5: Preferences
- [ ] Add editor preferences to `AppPreferences.swift`
- [ ] Add editor properties to `Settings` struct
- [ ] Add editor properties to `SettingsViewModel`

### Phase 6: UI
- [ ] Create Editor settings tab
- [ ] Implement backend configuration UI
- [ ] Implement output mode selector
- [ ] Implement connection test button
- [ ] Add status indicator

### Phase 7: Integration
- [ ] Modify `TranscriptionService.transcribeAudio()`
- [ ] Add editor call after post-processing
- [ ] Implement fallback logic
- [ ] Add logging

### Phase 8: Testing
- [ ] Unit tests for `Guardrails`
- [ ] Unit tests for prompt building
- [ ] Integration test with mock API
- [ ] End-to-end test with real transcription

### Phase 9: Polish
- [ ] Error message localization
- [ ] API key secure storage (Keychain)
- [ ] Rate limiting handling
- [ ] Usage analytics (optional)

---

## Appendix A: Sample LLM Responses

### Verbatim Mode Response

```json
{
  "editedText": "So I was thinking, um, we should probably look at the Q3 numbers. The revenue was, uh, about 2.3 million.",
  "replacements": [
    {"from": "q3", "to": "Q3", "reason": "capitalization", "position": 42},
    {"from": "2.3million", "to": "2.3 million", "reason": "punctuation", "position": 78}
  ],
  "uncertainSpans": [],
  "formattingActions": [],
  "safety": {
    "addedContentRisk": 0.0,
    "meaningChangeRisk": 0.0
  }
}
```

### Clean Mode Response

```json
{
  "editedText": "I was thinking we should look at the Q3 numbers. The revenue was about 2.3 million.",
  "replacements": [
    {"from": "So", "to": "", "reason": "fillerRemoval", "position": 0},
    {"from": ", um,", "to": "", "reason": "fillerRemoval", "position": 15},
    {"from": "probably", "to": "", "reason": "fillerRemoval", "position": 25},
    {"from": ", uh,", "to": "", "reason": "fillerRemoval", "position": 55}
  ],
  "uncertainSpans": [],
  "formattingActions": [],
  "safety": {
    "addedContentRisk": 0.0,
    "meaningChangeRisk": 0.05
  }
}
```

### Notes Mode Response

```json
{
  "editedText": "## Q3 Review\n- Should review Q3 numbers\n- Revenue: ~$2.3 million",
  "replacements": [
    {"from": "So I was thinking, um, we should probably look at", "to": "Should review", "reason": "formatting", "position": 0}
  ],
  "uncertainSpans": [],
  "formattingActions": ["Created heading 'Q3 Review'", "Converted to bullet points"],
  "safety": {
    "addedContentRisk": 0.1,
    "meaningChangeRisk": 0.15
  }
}
```

---

## Appendix B: Model Download Implementation

For local LLM backends, model download follows the same pattern as `WhisperModelManager`. Reuse these methods from `WhisperModelManager.swift`:

### Methods to Reuse from WhisperModelManager

```swift
// Reference: WhisperModelManager.swift

/// Key methods to adapt for LLM model downloads:

// 1. Download with progress tracking
func downloadModel(url: URL, to destination: URL, progress: @escaping (Double) -> Void) async throws

// 2. Resume interrupted downloads
func resumeDownload(from url: URL, existingData: Data, to destination: URL) async throws

// 3. Verify download integrity
func verifyModelIntegrity(at path: URL, expectedSize: Int64) -> Bool

// 4. Model directory management
var modelsDirectory: URL { get }  // ~/Library/Application Support/[BundleID]/llm-models/
```

### LLM-Specific Download Implementation

```swift
// MARK: - LLMModelManager

final class LLMModelManager {
    static let shared = LLMModelManager()

    private let fileManager = FileManager.default
    private let session: URLSession

    /// Models directory: ~/Library/Application Support/[BundleID]/llm-models/
    var modelsDirectory: URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let bundleId = Bundle.main.bundleIdentifier ?? "OpenSuperWhisper"
        return appSupport.appendingPathComponent(bundleId).appendingPathComponent("llm-models")
    }

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForResource = 3600  // 1 hour for large models
        self.session = URLSession(configuration: config)

        // Ensure directory exists
        try? fileManager.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
    }

    /// Download a model with progress reporting and checksum verification
    func downloadModel(
        from url: URL,
        expectedChecksum: String?,
        progress: @escaping (Double) -> Void
    ) async throws -> URL {
        let filename = url.lastPathComponent
        let destination = modelsDirectory.appendingPathComponent(filename)

        // Check if already downloaded and valid
        if fileManager.fileExists(atPath: destination.path) {
            if let checksum = expectedChecksum,
               try verifyChecksum(at: destination, expected: checksum) {
                return destination
            }
        }

        // Download with progress
        let (tempURL, _) = try await session.download(from: url) { bytesWritten, totalBytes, _ in
            if totalBytes > 0 {
                progress(Double(bytesWritten) / Double(totalBytes))
            }
        }

        // Move to final location
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: tempURL, to: destination)

        // Verify checksum if provided
        if let checksum = expectedChecksum {
            guard try verifyChecksum(at: destination, expected: checksum) else {
                try? fileManager.removeItem(at: destination)
                throw LLMError.checksumMismatch
            }
        }

        return destination
    }

    /// Verify SHA256 checksum of downloaded model
    func verifyChecksum(at url: URL, expected: String) throws -> Bool {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let computed = SHA256.hash(data: data)
        let computedHex = computed.compactMap { String(format: "%02x", $0) }.joined()
        return computedHex.lowercased() == expected.lowercased()
    }

    /// List available models
    func availableModels() -> [LLMModelInfo] {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: modelsDirectory,
            includingPropertiesForKeys: [.fileSizeKey, .creationDateKey]
        ) else {
            return []
        }

        return contents.compactMap { url -> LLMModelInfo? in
            guard url.pathExtension == "gguf" else { return nil }
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .creationDateKey])
            return LLMModelInfo(
                name: url.deletingPathExtension().lastPathComponent,
                path: url,
                sizeBytes: values?.fileSize ?? 0,
                downloadDate: values?.creationDate
            )
        }
    }

    /// Delete a downloaded model
    func deleteModel(at path: URL) throws {
        try fileManager.removeItem(at: path)
    }
}

struct LLMModelInfo: Identifiable {
    let name: String
    let path: URL
    let sizeBytes: Int
    let downloadDate: Date?

    var id: String { path.path }

    var sizeFormatted: String {
        ByteCountFormatter.string(fromByteCount: Int64(sizeBytes), countStyle: .file)
    }
}
```

### SHA256 Checksum Verification

```swift
import CryptoKit

extension LLMModelManager {

    /// Compute SHA256 hash of a file using streaming for memory efficiency
    func computeSHA256(at url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        let bufferSize = 1024 * 1024  // 1MB chunks

        while autoreleasepool(invoking: {
            let data = handle.readData(ofLength: bufferSize)
            if data.isEmpty { return false }
            hasher.update(data: data)
            return true
        }) {}

        let digest = hasher.finalize()
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }
}
```

---

## Appendix C: Security Considerations

### API Key Storage

For v1, API keys are stored in UserDefaults (not secure). Future versions should:

1. Use macOS Keychain for API key storage
2. Implement secure memory handling for keys in transit
3. Clear keys from memory after use

### Data Privacy

- Transcription text is sent to external API
- Users should be informed in UI
- Consider adding "Local only" mode indicator
- Log redaction for sensitive content

### Rate Limiting

- Implement client-side rate limiting
- Cache recent edits to avoid duplicate requests
- Show clear feedback when rate limited

---

## Revision History

| Version | Date | Author | Changes |
|---------|------|--------|---------|
| 1.0 | Initial | - | Original specification |
| 1.1 | 2026-01-26 | Designer Audit | **Critical fixes:** |
| | | | - Added Section 1.1: Concurrency Safety - Model switching protection with `editorSnapshot` pattern and `isProcessing` guard |
| | | | - Added Section 1.2: Memory Management - `LLMMemoryManager` with `NSWorkspace` observer, `DispatchSourceMemoryPressure`, and 2GB buffer check |
| | | | - Added Section 1.3: LLM Readiness States - `LLMReadiness` enum with first-run UI guidance |
| | | | **Major fixes:** |
| | | | - Added Section 9.1: Timeout Handling with abort callback mechanism (`llama_set_abort_callback` usage) |
| | | | - Added Section 9.2: Thread Safety Guarantees - `OSAllocatedUnfairLock` pattern, actor isolation, replaced `@unchecked Sendable` |
| | | | - Updated Section 8: Replaced line number references with contextual markers |
| | | | - Added Appendix B: Full `downloadModel` implementation with `WhisperModelManager` method references |
| | | | - Added SHA256 checksum verification for model downloads |
| | | | **Additions:** |
| | | | - Expanded PR6 with MLX backend architecture stub (marked "Future") |
| | | | - Added this Revision History section |
