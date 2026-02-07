import AppKit
import ApplicationServices
import Carbon
import Combine
import Foundation
import KeyboardShortcuts
import SwiftUI

/// Shared navigation state for Settings window
class SettingsNavigation: ObservableObject {
    static let shared = SettingsNavigation()
    @Published var initialTab: Int = 0
    private init() {}
}

/// Connection status for editor backend
enum EditorConnectionStatus: Equatable {
    case unknown
    case checking
    case connected(model: String)
    case error(String)

    var displayText: String {
        switch self {
        case .unknown: return "Not tested"
        case .checking: return "Testing..."
        case .connected(let model): return "Connected (\(model))"
        case .error(let msg): return "Error: \(msg)"
        }
    }

    var color: Color {
        switch self {
        case .unknown: return .secondary
        case .checking: return .orange
        case .connected: return .green
        case .error: return .red
        }
    }
}

class SettingsViewModel: ObservableObject {
    @Published var selectedModelURL: URL? {
        didSet {
            if let url = selectedModelURL {
                AppPreferences.shared.selectedModelPath = url.path
            }
        }
    }

    @Published var availableModels: [URL] = []
    @Published var selectedLanguage: String {
        didSet {
            AppPreferences.shared.whisperLanguage = selectedLanguage
        }
    }

    @Published var translateToEnglish: Bool {
        didSet {
            AppPreferences.shared.translateToEnglish = translateToEnglish
        }
    }

    @Published var suppressBlankAudio: Bool {
        didSet {
            AppPreferences.shared.suppressBlankAudio = suppressBlankAudio
        }
    }

    @Published var showTimestamps: Bool {
        didSet {
            AppPreferences.shared.showTimestamps = showTimestamps
        }
    }

    @Published var temperature: Double {
        didSet {
            AppPreferences.shared.temperature = temperature
        }
    }

    @Published var noSpeechThreshold: Double {
        didSet {
            AppPreferences.shared.noSpeechThreshold = noSpeechThreshold
        }
    }

    @Published var languagePrompts: [String: String] {
        didSet {
            AppPreferences.shared.languagePrompts = languagePrompts
        }
    }

    /// Which language's prompt is being edited (used in auto-detect mode)
    @Published var editingPromptLanguage: String = "en"

    /// Computed property for the currently displayed/edited prompt text
    var currentEditingPrompt: String {
        get {
            let lang = selectedLanguage == "auto" ? editingPromptLanguage : selectedLanguage
            // Return user's prompt even if empty - only use default when no entry exists
            if let userPrompt = languagePrompts[lang] {
                return userPrompt
            }
            return LanguageUtil.defaultPrompts[lang] ?? ""
        }
        set {
            let lang = selectedLanguage == "auto" ? editingPromptLanguage : selectedLanguage
            var prompts = languagePrompts
            prompts[lang] = newValue
            languagePrompts = prompts
        }
    }

    /// Check if current prompt is customized (different from default)
    var isCurrentPromptCustomized: Bool {
        let lang = selectedLanguage == "auto" ? editingPromptLanguage : selectedLanguage
        return LanguageUtil.isCustomPrompt(for: lang, userPrompts: languagePrompts)
    }

    /// Reset a specific language's prompt to its default
    func resetPromptToDefault(for language: String) {
        var prompts = languagePrompts
        prompts.removeValue(forKey: language)
        languagePrompts = prompts
    }

    @Published var useBeamSearch: Bool {
        didSet {
            AppPreferences.shared.useBeamSearch = useBeamSearch
        }
    }

    @Published var beamSize: Int {
        didSet {
            AppPreferences.shared.beamSize = beamSize
        }
    }

    @Published var debugMode: Bool {
        didSet {
            AppPreferences.shared.debugMode = debugMode
        }
    }

    @Published var playSoundOnRecordStart: Bool {
        didSet {
            AppPreferences.shared.playSoundOnRecordStart = playSoundOnRecordStart
        }
    }

    @Published var useAsianAutocorrect: Bool {
        didSet {
            AppPreferences.shared.useAsianAutocorrect = useAsianAutocorrect
        }
    }

    @Published var autoCopyToClipboard: Bool {
        didSet {
            AppPreferences.shared.autoCopyToClipboard = autoCopyToClipboard
        }
    }

    @Published var autoPasteAfterCopy: Bool {
        didSet {
            AppPreferences.shared.autoPasteAfterCopy = autoPasteAfterCopy
        }
    }

    // MARK: - Editor Settings

    @Published var editorEnabled: Bool {
        didSet {
            AppPreferences.shared.editorEnabled = editorEnabled
        }
    }

    @Published var editorBackend: EditorBackend {
        didSet {
            AppPreferences.shared.editorBackend = editorBackend
        }
    }

    @Published var editorEndpointURL: String {
        didSet {
            AppPreferences.shared.editorEndpointURL =
                editorEndpointURL.isEmpty ? nil : editorEndpointURL
        }
    }

    @Published var editorAPIKey: String {
        didSet {
            AppPreferences.shared.editorAPIKey = editorAPIKey.isEmpty ? nil : editorAPIKey
        }
    }

    @Published var editorModelName: String {
        didSet {
            AppPreferences.shared.editorModelName = editorModelName
        }
    }

    @Published var editorOutputMode: OutputMode {
        didSet {
            AppPreferences.shared.editorOutputMode = editorOutputMode
        }
    }

    @Published var editorTemperature: Double {
        didSet {
            AppPreferences.shared.editorTemperature = editorTemperature
        }
    }

    @Published var editorConnectionStatus: EditorConnectionStatus = .unknown

    // MARK: - Local LLM Settings (llama.cpp)

    @Published var llmProcessingMode: LLMProcessingMode {
        didSet {
            AppPreferences.shared.llmProcessingMode = llmProcessingMode
        }
    }

    @Published var llmCustomPrompt: String {
        didSet {
            AppPreferences.shared.llmCustomPrompt = llmCustomPrompt.isEmpty ? nil : llmCustomPrompt
        }
    }

    @Published var llmModelPath: String? {
        didSet {
            AppPreferences.shared.llmModelPath = llmModelPath
        }
    }

    @Published var llmTimeoutSeconds: Int {
        didSet {
            AppPreferences.shared.llmTimeoutSeconds = llmTimeoutSeconds
        }
    }

    @Published var llmAutoLoadModel: Bool {
        didSet {
            AppPreferences.shared.llmAutoLoadModel = llmAutoLoadModel
        }
    }

    @Published var shortcutType: ShortcutType {
        didSet {
            AppPreferences.shared.shortcutType = shortcutType
        }
    }

    @Published var isAccessibilityPermissionGranted: Bool = false
    private var accessibilityCheckTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    // Model download error handling
    @Published var showDownloadError = false
    @Published var downloadErrorMessage = ""

    init() {
        let prefs = AppPreferences.shared
        self.selectedLanguage = prefs.whisperLanguage
        self.translateToEnglish = prefs.translateToEnglish
        self.suppressBlankAudio = prefs.suppressBlankAudio
        self.showTimestamps = prefs.showTimestamps
        self.temperature = prefs.temperature
        self.noSpeechThreshold = prefs.noSpeechThreshold
        self.useBeamSearch = prefs.useBeamSearch
        self.beamSize = prefs.beamSize
        self.debugMode = prefs.debugMode
        self.playSoundOnRecordStart = prefs.playSoundOnRecordStart
        self.useAsianAutocorrect = prefs.useAsianAutocorrect
        self.autoCopyToClipboard = prefs.autoCopyToClipboard
        self.autoPasteAfterCopy = prefs.autoPasteAfterCopy

        // Editor settings
        self.editorEnabled = prefs.editorEnabled
        self.editorBackend = prefs.editorBackend
        self.editorEndpointURL = prefs.editorEndpointURL ?? ""
        self.editorAPIKey = prefs.editorAPIKey ?? ""
        self.editorModelName = prefs.editorModelName
        self.editorOutputMode = prefs.editorOutputMode
        self.editorTemperature = prefs.editorTemperature

        // Local LLM settings
        self.llmProcessingMode = prefs.llmProcessingMode
        self.llmCustomPrompt = prefs.llmCustomPrompt ?? ""
        self.llmModelPath = prefs.llmModelPath
        self.llmTimeoutSeconds = prefs.llmTimeoutSeconds
        self.llmAutoLoadModel = prefs.llmAutoLoadModel
        self.shortcutType = prefs.shortcutType

        // Load language prompts with migration from old initialPrompt
        var loadedPrompts = prefs.languagePrompts
        if loadedPrompts.isEmpty && !prefs.initialPrompt.isEmpty {
            // Migrate old single initialPrompt to the current language
            loadedPrompts[prefs.whisperLanguage == "auto" ? "en" : prefs.whisperLanguage] =
                prefs.initialPrompt
        }
        self.languagePrompts = loadedPrompts

        // Set initial editing language to current selected (or "en" for auto)
        self.editingPromptLanguage = prefs.whisperLanguage == "auto" ? "en" : prefs.whisperLanguage

        if let savedPath = prefs.selectedModelPath {
            self.selectedModelURL = URL(fileURLWithPath: savedPath)
        }
        loadAvailableModels()
        checkAccessibilityPermission()
        startAccessibilityChecking()
    }

    func hasCoreMLModel() -> Bool {
        guard let modelName = selectedModelURL?.lastPathComponent else { return false }
        return WhisperModelManager.shared.hasCoreMLModel(for: modelName)
    }

    func isCoreMLAvailable() -> Bool {
        guard let modelURL = selectedModelURL else { return false }
        // Check if this model has a CoreML encoder available (non-quantized models only)
        let modelName = modelURL.lastPathComponent
        let quantizedSuffixes = ["-q5_0.bin", "-q5_1.bin", "-q8_0.bin"]
        for suffix in quantizedSuffixes {
            if modelName.contains(suffix) {
                return false
            }
        }
        return true
    }

    func downloadCoreML() {
        guard let modelURL = selectedModelURL else { return }
        let modelName = modelURL.lastPathComponent

        // Construct Hugging Face URL from model filename
        let baseName = modelName.replacingOccurrences(of: ".bin", with: "")
        let huggingFaceURLString =
            "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(baseName)-encoder.mlmodelc.zip?download=true"
        guard let coreMLURL = URL(string: huggingFaceURLString) else { return }

        WhisperModelManager.shared.downloadCoreMLInBackground(from: coreMLURL, for: modelName)
    }

    func cancelCoreMLDownload(deleteResumeData: Bool = false) {
        WhisperModelManager.shared.cancelCoreMLDownload(deleteResumeData: deleteResumeData)
    }

    func deleteCoreML() {
        guard let modelName = selectedModelURL?.lastPathComponent else { return }
        try? WhisperModelManager.shared.deleteCoreMLModel(for: modelName)
    }

    func hasCoreMLResumableDownload() -> Bool {
        guard let modelName = selectedModelURL?.lastPathComponent else { return false }
        return WhisperModelManager.shared.hasCoreMLResumableDownload(for: modelName)
    }

    func getCoreMLResumableProgress() -> Double {
        guard let modelName = selectedModelURL?.lastPathComponent else { return 0 }
        return WhisperModelManager.shared.getCoreMLResumableDownload(for: modelName)?.progress ?? 0
    }

    deinit {
        accessibilityCheckTimer?.invalidate()
    }

    private func startAccessibilityChecking() {
        accessibilityCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) {
            [weak self] _ in
            self?.checkAccessibilityPermission()
        }
    }

    func checkAccessibilityPermission() {
        let granted = AXIsProcessTrusted()
        DispatchQueue.main.async { [weak self] in
            self?.isAccessibilityPermissionGranted = granted
        }
    }

    func openAccessibilityPreferences() {
        if let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        {
            NSWorkspace.shared.open(url)
        }
    }

    func loadAvailableModels() {
        availableModels = WhisperModelManager.shared.getAvailableModels()
        if selectedModelURL == nil {
            selectedModelURL = availableModels.first
        }
    }
}

struct Settings {
    var selectedLanguage: String
    var translateToEnglish: Bool
    var suppressBlankAudio: Bool
    var showTimestamps: Bool
    var temperature: Double
    var noSpeechThreshold: Double
    var languagePrompts: [String: String]
    var useBeamSearch: Bool
    var beamSize: Int
    var useAsianAutocorrect: Bool

    // LLM Post-Processing Settings
    var llmProcessingMode: LLMProcessingMode
    var llmCustomPrompt: String?
    var llmModelPath: String?
    var llmTimeoutSeconds: Int
    var llmAutoLoadModel: Bool
    var llmBackendType: LLMBackendType

    init() {
        let prefs = AppPreferences.shared
        self.selectedLanguage = prefs.whisperLanguage
        self.translateToEnglish = prefs.translateToEnglish
        self.suppressBlankAudio = prefs.suppressBlankAudio
        self.showTimestamps = prefs.showTimestamps
        self.temperature = prefs.temperature
        self.noSpeechThreshold = prefs.noSpeechThreshold
        self.languagePrompts = prefs.languagePrompts
        self.useBeamSearch = prefs.useBeamSearch
        self.beamSize = prefs.beamSize
        self.useAsianAutocorrect = prefs.useAsianAutocorrect

        // LLM settings
        self.llmProcessingMode = prefs.llmProcessingMode
        self.llmCustomPrompt = prefs.llmCustomPrompt
        self.llmModelPath = prefs.llmModelPath
        self.llmTimeoutSeconds = prefs.llmTimeoutSeconds
        self.llmAutoLoadModel = prefs.llmAutoLoadModel
        self.llmBackendType = prefs.llmBackendType
    }

    /// Get the effective prompt for a language (user-customized or default)
    func getPrompt(for language: String) -> String? {
        let prompt = LanguageUtil.getEffectivePrompt(for: language, userPrompts: languagePrompts)
        return prompt.isEmpty ? nil : prompt
    }

    /// Whether LLM post-processing is enabled
    var isLLMEnabled: Bool {
        llmProcessingMode != .none
    }
}

struct SettingsView: View {
    @StateObject private var viewModel = SettingsViewModel()
    @ObservedObject private var modelManager = WhisperModelManager.shared
    @Environment(\.dismiss) var dismiss
    @State private var selectedTab: Int = 0
    @State private var previousModelURL: URL?
    @State private var showDownloadError = false
    @State private var downloadErrorMessage = ""

    // Dictionary state
    @StateObject private var dictionaryManager = DictionaryManager.shared
    @State private var dictionarySearchText = ""
    @State private var showAddTermSheet = false
    @State private var editingEntry: DictionaryEntry?
    @State private var showImportError = false
    @State private var importErrorMessage = ""
    @State private var showSuggestionsSheet = false
    @State private var lastTranscriptText = ""

    init(initialTab: Int = 0) {
        _selectedTab = State(initialValue: initialTab)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Custom tab bar
            HStack(spacing: 2) {
                tabButton(title: "Shortcuts", icon: "command", tag: 0)
                tabButton(title: "Model", icon: "cpu", tag: 1)
                tabButton(title: "Transcription", icon: "text.bubble", tag: 2)
                tabButton(title: "Editor", icon: "wand.and.stars", tag: 3)
                tabButton(title: "Dictionary", icon: "character.book.closed", tag: 4)
                tabButton(title: "Advanced", icon: "gear", tag: 5)
                tabButton(title: "About", icon: "info.circle", tag: 6)
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Divider()

            // Tab content
            Group {
                switch selectedTab {
                case 0: shortcutSettings
                case 1: modelSettings
                case 2: transcriptionSettings
                case 3: editorSettings
                case 4: dictionarySettings
                case 5: advancedSettings
                case 6: aboutSettings
                default: shortcutSettings
                }
            }

            Divider()

            // Done button at bottom
            HStack {
                Spacer()
                Button("Done") {
                    if viewModel.selectedModelURL != previousModelURL {
                        // Reload model if changed
                        if let modelPath = viewModel.selectedModelURL?.path {
                            TranscriptionService.shared.reloadModel(with: modelPath)
                        }
                    }
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 550)
        .frame(minHeight: 500, maxHeight: 750)
        .background(Color(.windowBackgroundColor))
        .onAppear {
            previousModelURL = viewModel.selectedModelURL
            // Read from shared navigation if set (used when opening from Window scene)
            if SettingsNavigation.shared.initialTab != 0 {
                selectedTab = SettingsNavigation.shared.initialTab
                SettingsNavigation.shared.initialTab = 0  // Reset after reading
            }
        }
    }

    @ViewBuilder
    private func tabButton(title: String, icon: String, tag: Int) -> some View {
        Button(action: { selectedTab = tag }) {
            VStack(spacing: 2) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                Text(title)
                    .font(.system(size: 10))
                    .lineLimit(1)
            }
            .frame(minWidth: 58)
            .padding(.horizontal, 6)
            .padding(.vertical, 6)
            .background(selectedTab == tag ? Color.accentColor : Color.clear)
            .foregroundColor(selectedTab == tag ? .white : .primary)
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }

    private var modelSettings: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                // Unified Model List
                VStack(spacing: 8) {
                    ForEach(availableModels) { model in
                        let isActive =
                            viewModel.selectedModelURL?.lastPathComponent == model.filename
                        let coreMLState = isActive ? getCoreMLState(for: model) : nil

                        ModelCardView(
                            model: model,
                            modelManager: modelManager,
                            isActive: isActive,
                            coreMLState: coreMLState,
                            onSelect: {
                                selectModel(model)
                            },
                            onDownload: {
                                downloadModel(model)
                            },
                            onCancelDownload: {
                                modelManager.cancelDownload(for: model.filename)
                            },
                            onDownloadCoreML: {
                                viewModel.downloadCoreML()
                            },
                            onCancelCoreML: { deleteResumeData in
                                viewModel.cancelCoreMLDownload(deleteResumeData: deleteResumeData)
                            },
                            onDeleteCoreML: {
                                viewModel.deleteCoreML()
                            }
                        )
                    }
                }
                .alert("Download Error", isPresented: $showDownloadError) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(downloadErrorMessage)
                }

                // Models Directory Footer
                HStack {
                    Text("Models stored in:")
                        .font(Typography.settingsCaption)
                        .foregroundColor(.secondary)
                    Text(WhisperModelManager.shared.modelsDirectory.path)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button(action: {
                        NSWorkspace.shared.open(WhisperModelManager.shared.modelsDirectory)
                    }) {
                        Label("Open", systemImage: "folder")
                            .font(Typography.settingsCaption)
                    }
                    .buttonStyle(.borderless)
                    .help("Open models directory")
                }
                .padding(.top, 12)
                .padding(.horizontal, 4)
            }
            .padding()
        }
    }

    private func getCoreMLState(for model: DownloadableModel) -> CoreMLState {
        let modelName = model.filename

        // Check if model supports CoreML (explicit flag)
        if !model.hasCoreML {
            return .notAvailable
        }

        // Check if downloading
        if modelManager.isCoreMLDownloading {
            return .downloading(progress: modelManager.coreMLDownloadProgress)
        }

        // Check if enabled
        if WhisperModelManager.shared.hasCoreMLModel(for: modelName) {
            return .enabled
        }

        // Check if resumable
        if WhisperModelManager.shared.hasCoreMLResumableDownload(for: modelName) {
            let progress =
                WhisperModelManager.shared.getCoreMLResumableDownload(for: modelName)?.progress ?? 0
            return .resumable(progress: progress)
        }

        return .available
    }

    private func selectModel(_ model: DownloadableModel) {
        let modelPath = WhisperModelManager.shared.modelsDirectory.appendingPathComponent(
            model.filename)
        viewModel.selectedModelURL = modelPath
    }

    private var transcriptionSettings: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                // Language Settings
                VStack(alignment: .leading, spacing: 10) {
                    Text("Language Settings")
                        .font(Typography.settingsHeader)
                        .foregroundColor(.primary)

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Language:")
                                .font(Typography.settingsLabel)
                            Picker("", selection: $viewModel.selectedLanguage) {
                                ForEach(LanguageUtil.availableLanguages, id: \.self) { code in
                                    Text(LanguageUtil.languageNames[code] ?? code)
                                        .tag(code)
                                }
                            }
                            .pickerStyle(.menu)
                            Spacer()
                        }

                        Toggle(isOn: $viewModel.translateToEnglish) {
                            Text("Translate to English")
                                .font(Typography.settingsBody)
                        }
                        .toggleStyle(SwitchToggleStyle(tint: Color.accentColor))

                        if ["zh", "ja", "ko", "auto"].contains(viewModel.selectedLanguage) {
                            Toggle(isOn: $viewModel.useAsianAutocorrect) {
                                Text("Use Asian Autocorrect")
                                    .font(Typography.settingsBody)
                            }
                            .toggleStyle(SwitchToggleStyle(tint: Color.accentColor))
                        }
                    }
                }
                .padding(12)
                .background(Color(.controlBackgroundColor).opacity(0.3))
                .cornerRadius(12)
                .frame(maxWidth: .infinity, alignment: .leading)

                // Output Options
                VStack(alignment: .leading, spacing: 10) {
                    Text("Output Options")
                        .font(Typography.settingsHeader)
                        .foregroundColor(.primary)

                    VStack(alignment: .leading, spacing: 6) {
                        Toggle(isOn: $viewModel.showTimestamps) {
                            Text("Show Timestamps")
                                .font(Typography.settingsBody)
                        }
                        .toggleStyle(SwitchToggleStyle(tint: Color.accentColor))

                        Toggle(isOn: $viewModel.suppressBlankAudio) {
                            Text("Suppress Blank Audio")
                                .font(Typography.settingsBody)
                        }
                        .toggleStyle(SwitchToggleStyle(tint: Color.accentColor))
                    }
                }
                .padding(12)
                .background(Color(.controlBackgroundColor).opacity(0.3))
                .cornerRadius(12)
                .frame(maxWidth: .infinity, alignment: .leading)

                // Initial Prompt (Language-Specific)
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Initial Prompt")
                            .font(Typography.settingsHeader)
                            .foregroundColor(.primary)

                        // Language picker inline (auto-detect mode only)
                        if viewModel.selectedLanguage == "auto" {
                            Picker("", selection: $viewModel.editingPromptLanguage) {
                                ForEach(
                                    LanguageUtil.availableLanguages.filter { $0 != "auto" },
                                    id: \.self
                                ) { code in
                                    HStack {
                                        Text(LanguageUtil.languageNames[code] ?? code)
                                        if LanguageUtil.isCustomPrompt(
                                            for: code, userPrompts: viewModel.languagePrompts)
                                        {
                                            Text("*")
                                        }
                                    }
                                    .tag(code)
                                }
                            }
                            .pickerStyle(.menu)
                            .frame(width: 130)
                        }

                        Spacer()

                        // Reset button (shown when prompt is customized)
                        if viewModel.isCurrentPromptCustomized {
                            Button(action: {
                                let lang =
                                    viewModel.selectedLanguage == "auto"
                                    ? viewModel.editingPromptLanguage
                                    : viewModel.selectedLanguage
                                viewModel.resetPromptToDefault(for: lang)
                            }) {
                                Text("Reset")
                                    .font(Typography.settingsCaption)
                            }
                            .buttonStyle(.borderless)
                            .foregroundColor(.secondary)
                        }
                    }

                    // Prompt editor
                    TextEditor(
                        text: Binding(
                            get: { viewModel.currentEditingPrompt },
                            set: { viewModel.currentEditingPrompt = $0 }
                        )
                    )
                    .font(Typography.settingsBody)
                    .frame(height: 56)
                    .padding(6)
                    .background(Color(.textBackgroundColor))
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(
                                viewModel.isCurrentPromptCustomized
                                    ? Color.accentColor.opacity(0.5)
                                    : Color.gray.opacity(0.3),
                                lineWidth: 1
                            )
                    )

                    // Concise helper text
                    HStack(spacing: 4) {
                        let langName =
                            viewModel.selectedLanguage == "auto"
                            ? (LanguageUtil.languageNames[viewModel.editingPromptLanguage]
                                ?? viewModel.editingPromptLanguage)
                            : (LanguageUtil.languageNames[viewModel.selectedLanguage]
                                ?? viewModel.selectedLanguage)
                        Text("Prompt used when \(langName) is detected.")
                            .font(Typography.settingsCaption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(12)
                .background(Color(.controlBackgroundColor).opacity(0.3))
                .cornerRadius(12)
                .frame(maxWidth: .infinity, alignment: .leading)

                // Transcriptions Directory
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Transcriptions Directory")
                            .font(Typography.settingsHeader)
                            .foregroundColor(.primary)
                        Spacer()
                        Button(action: {
                            NSWorkspace.shared.open(Recording.recordingsDirectory)
                        }) {
                            Label("Open", systemImage: "folder")
                                .font(Typography.settingsCaption)
                        }
                        .buttonStyle(.borderless)
                        .help("Open transcriptions directory")
                    }

                    Text(Recording.recordingsDirectory.path)
                        .font(Typography.settingsMono)
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                        .padding(6)
                        .background(Color(.textBackgroundColor).opacity(0.5))
                        .cornerRadius(6)
                }
                .padding(12)
                .background(Color(.controlBackgroundColor).opacity(0.3))
                .cornerRadius(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding()
        }
    }

    private var editorSettings: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Enable/Disable Editor
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text("LLM Editor")
                            .font(Typography.settingsHeader)
                            .foregroundColor(.primary)
                        Spacer()
                        Toggle("", isOn: $viewModel.editorEnabled)
                            .toggleStyle(SwitchToggleStyle(tint: Color.accentColor))
                            .labelsHidden()
                    }

                    Text(
                        "Use an LLM to clean up transcriptions: fix grammar, remove filler words, and improve formatting."
                    )
                    .font(Typography.settingsCaption)
                    .foregroundColor(.secondary)
                }
                .padding()
                .background(Color(.controlBackgroundColor).opacity(0.3))
                .cornerRadius(12)
                .frame(maxWidth: .infinity, alignment: .leading)

                if viewModel.editorEnabled {
                    // Backend Configuration
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Backend Configuration")
                            .font(Typography.settingsHeader)
                            .foregroundColor(.primary)

                        VStack(alignment: .leading, spacing: 12) {
                            // Backend picker
                            HStack {
                                Text("Backend:")
                                    .font(Typography.settingsLabel)
                                Picker("", selection: $viewModel.editorBackend) {
                                    ForEach(EditorBackend.allCases, id: \.self) { backend in
                                        Text(backend.displayName).tag(backend)
                                    }
                                }
                                .pickerStyle(.menu)
                                .frame(width: 150)
                                Spacer()
                            }

                            // Endpoint URL (shown for custom backend)
                            if viewModel.editorBackend == .custom
                                || viewModel.editorBackend == .auto
                            {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Endpoint URL:")
                                        .font(Typography.settingsLabel)
                                    TextField(
                                        "https://api.openai.com/v1",
                                        text: $viewModel.editorEndpointURL
                                    )
                                    .textFieldStyle(.roundedBorder)
                                    .font(Typography.settingsBody)
                                }
                            }

                            // API Key
                            VStack(alignment: .leading, spacing: 4) {
                                Text("API Key:")
                                    .font(Typography.settingsLabel)
                                SecureField("sk-...", text: $viewModel.editorAPIKey)
                                    .textFieldStyle(.roundedBorder)
                                    .font(Typography.settingsBody)
                            }

                            // Model name
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Model:")
                                    .font(Typography.settingsLabel)
                                TextField("gpt-4o-mini", text: $viewModel.editorModelName)
                                    .textFieldStyle(.roundedBorder)
                                    .font(Typography.settingsBody)
                            }

                            // Test Connection button
                            HStack {
                                Button(action: {
                                    testEditorConnection()
                                }) {
                                    HStack {
                                        if viewModel.editorConnectionStatus == .checking {
                                            ProgressView()
                                                .scaleEffect(0.7)
                                                .frame(width: 14, height: 14)
                                        } else {
                                            Image(systemName: "antenna.radiowaves.left.and.right")
                                        }
                                        Text("Test Connection")
                                    }
                                }
                                .buttonStyle(.bordered)
                                .disabled(viewModel.editorConnectionStatus == .checking)

                                Spacer()

                                // Status indicator
                                HStack(spacing: 6) {
                                    Circle()
                                        .fill(viewModel.editorConnectionStatus.color)
                                        .frame(width: 8, height: 8)
                                    Text(viewModel.editorConnectionStatus.displayText)
                                        .font(Typography.settingsCaption)
                                        .foregroundColor(.secondary)
                                }
                            }
                            .padding(.top, 4)
                        }
                    }
                    .padding()
                    .background(Color(.controlBackgroundColor).opacity(0.3))
                    .cornerRadius(12)
                    .frame(maxWidth: .infinity, alignment: .leading)

                    // Output Mode
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Output Style")
                            .font(Typography.settingsHeader)
                            .foregroundColor(.primary)

                        VStack(alignment: .leading, spacing: 12) {
                            Picker("Output Mode:", selection: $viewModel.editorOutputMode) {
                                ForEach(OutputMode.allCases) { mode in
                                    Text(mode.displayName).tag(mode)
                                }
                            }
                            .pickerStyle(.radioGroup)

                            // Mode description
                            Text(viewModel.editorOutputMode.description)
                                .font(Typography.settingsCaption)
                                .foregroundColor(.secondary)
                                .padding(.leading, 20)
                        }
                    }
                    .padding()
                    .background(Color(.controlBackgroundColor).opacity(0.3))
                    .cornerRadius(12)
                    .frame(maxWidth: .infinity, alignment: .leading)

                    // Advanced Settings
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Advanced")
                            .font(Typography.settingsHeader)
                            .foregroundColor(.primary)

                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Temperature:")
                                    .font(Typography.settingsLabel)
                                Spacer()
                                Text(String(format: "%.1f", viewModel.editorTemperature))
                                    .font(Typography.settingsBody)
                                    .foregroundColor(.secondary)
                            }
                            Slider(value: $viewModel.editorTemperature, in: 0.0...1.0, step: 0.1)
                                .help("Lower values produce more deterministic output")
                        }
                    }
                    .padding()
                    .background(Color(.controlBackgroundColor).opacity(0.3))
                    .cornerRadius(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                // Local LLM Post-Processing (llama.cpp)
                localLLMSettings
            }
            .padding()
        }
    }

    @ViewBuilder
    private var localLLMSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Local LLM (Experimental)")
                    .font(Typography.settingsHeader)
                    .foregroundColor(.primary)
                Spacer()
                Text("llama.cpp")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.secondary.opacity(0.15))
                    .cornerRadius(4)
            }

            Text("Run LLM processing locally using llama.cpp. Requires downloading a model.")
                .font(Typography.settingsCaption)
                .foregroundColor(.secondary)

            // Processing Mode
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Processing Mode:")
                        .font(Typography.settingsLabel)
                    Picker("", selection: $viewModel.llmProcessingMode) {
                        ForEach(LLMProcessingMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 150)
                    Spacer()
                }

                Text(viewModel.llmProcessingMode.description)
                    .font(Typography.settingsCaption)
                    .foregroundColor(.secondary)
            }

            // Custom prompt (shown when mode is custom)
            if viewModel.llmProcessingMode == .custom {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Custom Prompt:")
                        .font(Typography.settingsLabel)
                    TextEditor(text: $viewModel.llmCustomPrompt)
                        .font(Typography.settingsBody)
                        .frame(height: 56)
                        .padding(6)
                        .background(Color(.textBackgroundColor))
                        .cornerRadius(8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                        )
                }
            }

            // Model Selection
            if viewModel.llmProcessingMode != .none {
                localLLMModelSection
            }

            // Timeout slider
            if viewModel.llmProcessingMode != .none {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Timeout:")
                            .font(Typography.settingsLabel)
                        Spacer()
                        Text("\(viewModel.llmTimeoutSeconds) seconds")
                            .font(Typography.settingsBody)
                            .foregroundColor(.secondary)
                    }
                    Slider(
                        value: Binding(
                            get: { Double(viewModel.llmTimeoutSeconds) },
                            set: { viewModel.llmTimeoutSeconds = Int($0) }
                        ), in: 10...120, step: 10
                    )
                    .help("Maximum time to wait for LLM processing")
                }

                Toggle(isOn: $viewModel.llmAutoLoadModel) {
                    Text("Auto-load model on startup")
                        .font(Typography.settingsBody)
                }
                .toggleStyle(SwitchToggleStyle(tint: Color.accentColor))
            }
        }
        .padding()
        .background(Color(.controlBackgroundColor).opacity(0.3))
        .cornerRadius(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ObservedObject private var llmModelManager = LLMModelManager.shared

    @ViewBuilder
    private var localLLMModelSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Model")
                .font(Typography.settingsLabel)

            // List available/downloaded LLM models
            ForEach(LLMModelManager.availableModels) { model in
                LLMModelCardView(
                    model: model,
                    isSelected: viewModel.llmModelPath
                        == llmModelManager.modelsDirectory.appendingPathComponent(model.name).path,
                    isDownloaded: llmModelManager.isModelDownloaded(model),
                    isDownloading: llmModelManager.currentDownload?.filename == model.name,
                    downloadProgress: llmModelManager.currentDownload?.filename == model.name
                        ? llmModelManager.downloadProgress : 0,
                    onSelect: {
                        viewModel.llmModelPath =
                            llmModelManager.modelsDirectory.appendingPathComponent(model.name).path
                    },
                    onDownload: {
                        downloadLLMModel(model)
                    },
                    onCancel: {
                        llmModelManager.cancelDownload()
                    }
                )
            }

            // Models directory footer
            HStack {
                Text("Models stored in:")
                    .font(Typography.settingsCaption)
                    .foregroundColor(.secondary)
                Text(llmModelManager.modelsDirectory.path)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button(action: {
                    NSWorkspace.shared.open(llmModelManager.modelsDirectory)
                }) {
                    Label("Open", systemImage: "folder")
                        .font(Typography.settingsCaption)
                }
                .buttonStyle(.borderless)
                .help("Open LLM models directory")
            }
            .padding(.top, 4)
        }
    }

    private func downloadLLMModel(_ model: LLMModelInfo) {
        Task {
            do {
                try await llmModelManager.downloadModel(model) { progress in
                    // Progress is tracked via LLMModelManager.currentDownload
                }
                // Auto-select the newly downloaded model
                await MainActor.run {
                    viewModel.llmModelPath =
                        llmModelManager.modelsDirectory.appendingPathComponent(model.name).path
                }
            } catch {
                await MainActor.run {
                    downloadErrorMessage = error.localizedDescription
                    showDownloadError = true
                }
            }
        }
    }

    private func testEditorConnection() {
        viewModel.editorConnectionStatus = .checking
        // TODO: Implement actual connection test in PR2
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            if viewModel.editorAPIKey.isEmpty {
                viewModel.editorConnectionStatus = .error("API key required")
            } else {
                viewModel.editorConnectionStatus = .connected(model: viewModel.editorModelName)
            }
        }
    }

    // MARK: - Dictionary Settings

    private var dictionarySettings: some View {
        VStack(spacing: 0) {
            // Header with search and actions
            HStack {
                // Search field
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                    TextField("Search terms...", text: $dictionarySearchText)
                        .textFieldStyle(.plain)
                    if !dictionarySearchText.isEmpty {
                        Button(action: { dictionarySearchText = "" }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(8)
                .background(Color(.textBackgroundColor))
                .cornerRadius(8)

                Spacer()

                // Action buttons
                Button(action: { showAddTermSheet = true }) {
                    Label("Add", systemImage: "plus")
                }
                .buttonStyle(.bordered)

                Menu {
                    Button(action: importDictionary) {
                        Label("Import...", systemImage: "square.and.arrow.down")
                    }
                    Button(action: exportDictionary) {
                        Label("Export...", systemImage: "square.and.arrow.up")
                    }
                    Divider()
                    Button(action: { showSuggestionsSheet = true }) {
                        Label("Suggest from Clipboard", systemImage: "lightbulb")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .buttonStyle(.bordered)
            }
            .padding()

            Divider()

            // Terms list
            if filteredDictionaryTerms.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "character.book.closed")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary)
                    if dictionarySearchText.isEmpty {
                        Text("No dictionary terms")
                            .font(Typography.settingsBody)
                            .foregroundColor(.secondary)
                        Text("Add terms to help Whisper recognize specific words and names.")
                            .font(Typography.settingsCaption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                        Button("Add First Term") {
                            showAddTermSheet = true
                        }
                        .buttonStyle(.borderedProminent)
                        .padding(.top, 8)
                    } else {
                        Text("No terms matching \"\(dictionarySearchText)\"")
                            .font(Typography.settingsBody)
                            .foregroundColor(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else {
                List {
                    ForEach(filteredDictionaryTerms) { entry in
                        DictionaryTermRow(
                            entry: entry,
                            onEdit: { editingEntry = entry },
                            onDelete: { deleteTerm(entry) }
                        )
                    }
                }
                .listStyle(.plain)
            }

            // Footer with term count
            HStack {
                Text("\(dictionaryManager.dictionary.terms.count) terms")
                    .font(Typography.settingsCaption)
                    .foregroundColor(.secondary)
                Spacer()
                if dictionaryManager.isLoading {
                    ProgressView()
                        .scaleEffect(0.7)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(Color(.controlBackgroundColor).opacity(0.3))
        }
        .sheet(isPresented: $showAddTermSheet) {
            AddEditTermSheet(
                entry: nil,
                onSave: { entry in
                    Task {
                        try? await dictionaryManager.addTerm(entry)
                    }
                }
            )
        }
        .sheet(item: $editingEntry) { entry in
            AddEditTermSheet(
                entry: entry,
                onSave: { updatedEntry in
                    Task {
                        try? await dictionaryManager.updateTerm(updatedEntry)
                    }
                }
            )
        }
        .sheet(isPresented: $showSuggestionsSheet) {
            SuggestTermsSheet(
                dictionaryManager: dictionaryManager,
                onAddTerm: { term in
                    let entry = DictionaryEntry(term: term)
                    Task {
                        try? await dictionaryManager.addTerm(entry)
                    }
                }
            )
        }
        .alert("Import Error", isPresented: $showImportError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importErrorMessage)
        }
    }

    private var filteredDictionaryTerms: [DictionaryEntry] {
        dictionaryManager.dictionary.search(query: dictionarySearchText)
    }

    private func deleteTerm(_ entry: DictionaryEntry) {
        Task {
            try? await dictionaryManager.removeTerm(id: entry.id)
        }
    }

    private func importDictionary() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Select a dictionary JSON file to import"

        if panel.runModal() == .OK, let url = panel.url {
            Task {
                do {
                    try await dictionaryManager.importDictionary(from: url, replace: false)
                } catch {
                    await MainActor.run {
                        importErrorMessage = error.localizedDescription
                        showImportError = true
                    }
                }
            }
        }
    }

    private func exportDictionary() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "dictionary.json"
        panel.message = "Export dictionary"

        if panel.runModal() == .OK, let url = panel.url {
            do {
                try dictionaryManager.exportDictionary(to: url)
            } catch {
                importErrorMessage = "Export failed: \(error.localizedDescription)"
                showImportError = true
            }
        }
    }

    private var advancedSettings: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Decoding Strategy
                VStack(alignment: .leading, spacing: 16) {
                    Text("Decoding Strategy")
                        .font(Typography.settingsHeader)
                        .foregroundColor(.primary)

                    VStack(alignment: .leading, spacing: 10) {
                        Toggle(isOn: $viewModel.useBeamSearch) {
                            Text("Use Beam Search")
                                .font(Typography.settingsBody)
                        }
                        .toggleStyle(SwitchToggleStyle(tint: Color.accentColor))
                        .help("Beam search can provide better results but is slower")

                        if viewModel.useBeamSearch {
                            HStack {
                                Text("Beam Size:")
                                    .font(Typography.settingsBody)
                                Spacer()
                                Stepper(
                                    "\(viewModel.beamSize)", value: $viewModel.beamSize, in: 1...10
                                )
                                .help("Number of beams to use in beam search")
                                .frame(width: 120)
                            }
                            .padding(.leading, 24)
                        }
                    }
                }
                .padding()
                .background(Color(.controlBackgroundColor).opacity(0.3))
                .cornerRadius(12)
                .frame(maxWidth: .infinity, alignment: .leading)

                // Model Parameters
                VStack(alignment: .leading, spacing: 16) {
                    Text("Model Parameters")
                        .font(Typography.settingsHeader)
                        .foregroundColor(.primary)

                    VStack(alignment: .leading, spacing: 14) {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Temperature:")
                                    .font(Typography.settingsLabel)
                                Spacer()
                                Text(String(format: "%.2f", viewModel.temperature))
                                    .font(Typography.settingsBody)
                                    .foregroundColor(.secondary)
                            }

                            Slider(value: $viewModel.temperature, in: 0.0...1.0, step: 0.1)
                                .help("Higher values make the output more random")
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("No Speech Threshold:")
                                    .font(Typography.settingsLabel)
                                Spacer()
                                Text(String(format: "%.2f", viewModel.noSpeechThreshold))
                                    .font(Typography.settingsBody)
                                    .foregroundColor(.secondary)
                            }

                            Slider(value: $viewModel.noSpeechThreshold, in: 0.0...1.0, step: 0.1)
                                .help("Threshold for detecting speech vs. silence")
                        }
                    }
                }
                .padding()
                .background(Color(.controlBackgroundColor).opacity(0.3))
                .cornerRadius(12)
                .frame(maxWidth: .infinity, alignment: .leading)

                // Debug Options
                VStack(alignment: .leading, spacing: 16) {
                    Text("Debug Options")
                        .font(Typography.settingsHeader)
                        .foregroundColor(.primary)

                    Toggle(isOn: $viewModel.debugMode) {
                        Text("Debug Mode")
                            .font(Typography.settingsBody)
                    }
                    .toggleStyle(SwitchToggleStyle(tint: Color.accentColor))
                    .help("Enable additional logging and debugging information")
                }
                .padding()
                .background(Color(.controlBackgroundColor).opacity(0.3))
                .cornerRadius(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding()
        }
    }

    private var shortcutSettings: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Recording Shortcut
                VStack(alignment: .leading, spacing: 16) {
                    Text("Recording Shortcut")
                        .font(Typography.settingsHeader)
                        .foregroundColor(.primary)

                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Toggle record:")
                                .font(Typography.settingsLabel)
                            Spacer()
                            ShortcutRecorderView(shortcutType: $viewModel.shortcutType)
                        }

                        Toggle(isOn: $viewModel.playSoundOnRecordStart) {
                            Text("Play sound when recording starts")
                                .font(Typography.settingsBody)
                        }
                        .toggleStyle(SwitchToggleStyle(tint: Color.accentColor))
                        .help("Play a notification sound when recording begins")
                        .padding(.top, 4)

                        Toggle(isOn: $viewModel.autoCopyToClipboard) {
                            Text("Copy transcription to clipboard")
                                .font(Typography.settingsBody)
                        }
                        .toggleStyle(SwitchToggleStyle(tint: Color.accentColor))
                        .help("Automatically copy transcription to clipboard after recording")
                    }
                }
                .padding()
                .background(Color(.controlBackgroundColor).opacity(0.3))
                .cornerRadius(12)
                .frame(maxWidth: .infinity, alignment: .leading)

                // Instructions
                VStack(alignment: .leading, spacing: 16) {
                    Text("Instructions")
                        .font(Typography.settingsHeader)
                        .foregroundColor(.primary)

                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "1.circle.fill")
                                .foregroundColor(.accentColor)
                            Text("Press a key combination, or just press and release modifier keys (e.g., ⌃⌘)")
                                .font(Typography.settingsBody)
                                .foregroundColor(.secondary)
                        }

                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "2.circle.fill")
                                .foregroundColor(.accentColor)
                            Text("The shortcut will work even when the app is in the background")
                                .font(Typography.settingsBody)
                                .foregroundColor(.secondary)
                        }

                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "3.circle.fill")
                                .foregroundColor(.accentColor)
                            Text("You can use modifier-only shortcuts — Accessibility permission is required for these")
                                .font(Typography.settingsBody)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .padding()
                .background(Color(.controlBackgroundColor).opacity(0.3))
                .cornerRadius(12)
                .frame(maxWidth: .infinity, alignment: .leading)

                // Accessibility Permission (Optional)
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text("Accessibility")
                            .font(Typography.settingsHeader)
                            .foregroundColor(.primary)

                        if viewModel.isAccessibilityPermissionGranted {
                            Text("Enabled")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.green)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.green.opacity(0.15))
                                .cornerRadius(4)
                        } else {
                            Text("Optional")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.secondary.opacity(0.15))
                                .cornerRadius(4)
                        }
                    }

                    if viewModel.isAccessibilityPermissionGranted {
                        // Granted state - show features
                        VStack(alignment: .leading, spacing: 12) {
                            // Feature 1: Cursor positioning
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: "text.cursor")
                                    .foregroundColor(.accentColor)
                                    .frame(width: 20)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Smart indicator positioning")
                                        .font(Typography.settingsBody)
                                    Text("Recording indicator appears near your text cursor")
                                        .font(Typography.settingsCaption)
                                        .foregroundColor(.secondary)
                                }
                            }

                            // Feature 2: Auto-paste toggle
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: "doc.on.clipboard")
                                    .foregroundColor(
                                        viewModel.autoCopyToClipboard ? .accentColor : .secondary
                                    )
                                    .frame(width: 20)
                                VStack(alignment: .leading, spacing: 6) {
                                    Toggle(isOn: $viewModel.autoPasteAfterCopy) {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text("Auto-paste after transcription")
                                                .font(Typography.settingsBody)
                                                .foregroundColor(
                                                    viewModel.autoCopyToClipboard
                                                        ? .primary : .secondary)
                                            Text("Automatically paste into the active text field")
                                                .font(Typography.settingsCaption)
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                    .toggleStyle(SwitchToggleStyle(tint: Color.accentColor))
                                    .disabled(!viewModel.autoCopyToClipboard)

                                    if !viewModel.autoCopyToClipboard {
                                        Text(
                                            "Requires \"Copy transcription to clipboard\" to be enabled"
                                        )
                                        .font(Typography.settingsCaption)
                                        .foregroundColor(.orange)
                                    }
                                }
                            }
                        }

                        Divider()

                        HStack {
                            Text("Manage in System Settings")
                                .font(Typography.settingsCaption)
                                .foregroundColor(.secondary)
                            Spacer()
                            Button("Open Settings") {
                                viewModel.openAccessibilityPreferences()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    } else {
                        // Not granted state - show explanation and grant button
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Grant accessibility access to enable additional features:")
                                .font(Typography.settingsBody)
                                .foregroundColor(.secondary)

                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 8) {
                                    Image(systemName: "text.cursor")
                                        .foregroundColor(.secondary)
                                        .frame(width: 16)
                                    Text("Position indicator near text cursor")
                                        .font(Typography.settingsCaption)
                                        .foregroundColor(.secondary)
                                }
                                HStack(spacing: 8) {
                                    Image(systemName: "doc.on.clipboard")
                                        .foregroundColor(.secondary)
                                        .frame(width: 16)
                                    Text("Auto-paste transcription into text fields")
                                        .font(Typography.settingsCaption)
                                        .foregroundColor(.secondary)
                                }
                            }
                            .padding(.leading, 4)

                            Button(action: {
                                viewModel.openAccessibilityPreferences()
                            }) {
                                HStack {
                                    Image(systemName: "lock.shield")
                                    Text("Grant Access")
                                }
                            }
                            .buttonStyle(.bordered)
                            .padding(.top, 4)

                            Text("Keyboard shortcuts work without this permission.")
                                .font(Typography.settingsCaption)
                                .foregroundColor(.secondary)
                                .italic()
                        }
                    }
                }
                .padding()
                .background(Color(.controlBackgroundColor).opacity(0.3))
                .cornerRadius(12)
                .frame(maxWidth: .infinity, alignment: .leading)

                // URL Scheme for External Tools
                VStack(alignment: .leading, spacing: 16) {
                    Text("External Tools (Hammerspoon, Alfred, etc.)")
                        .font(Typography.settingsHeader)
                        .foregroundColor(.primary)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Use these URL commands to trigger recording from external apps:")
                            .font(Typography.settingsBody)
                            .foregroundColor(.secondary)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("opensuperwhisper://toggle").font(Typography.settingsMono)
                            Text("opensuperwhisper://start").font(Typography.settingsMono)
                            Text("opensuperwhisper://stop").font(Typography.settingsMono)
                            Text("opensuperwhisper://cancel").font(Typography.settingsMono)
                        }
                        .foregroundColor(.primary)
                    }
                }
                .padding()
                .background(Color(.controlBackgroundColor).opacity(0.3))
                .cornerRadius(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding()
        }
    }

    private var aboutSettings: some View {
        ScrollView {
            VStack(spacing: 20) {
                // App Info
                VStack(spacing: 12) {
                    if let appIcon = NSImage(named: "AppIcon") {
                        Image(nsImage: appIcon)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 80, height: 80)
                            .cornerRadius(16)
                    }

                    Text("OpenSuperWhisper")
                        .font(.title2)
                        .fontWeight(.semibold)

                    if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"]
                        as? String,
                        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
                    {
                        Text("Version \(version) (\(build))")
                            .font(Typography.settingsBody)
                            .foregroundColor(.secondary)
                    }

                    Text("Local speech-to-text transcription")
                        .font(Typography.settingsCaption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)

                // Dependencies
                VStack(alignment: .leading, spacing: 16) {
                    Text("Dependencies")
                        .font(Typography.settingsHeader)
                        .foregroundColor(.primary)

                    VStack(alignment: .leading, spacing: 10) {
                        DependencyRow(
                            name: "whisper.cpp", version: BuildInfo.whisperCppVersion,
                            url: BuildInfo.whisperCppURL)
                        DependencyRow(
                            name: "GRDB.swift", version: BuildInfo.grdbVersion,
                            url: URL(string: "https://github.com/groue/GRDB.swift"))
                        DependencyRow(
                            name: "KeyboardShortcuts", version: BuildInfo.keyboardShortcutsVersion,
                            url: URL(string: "https://github.com/sindresorhus/KeyboardShortcuts"))
                        DependencyRow(
                            name: "autocorrect", version: BuildInfo.autocorrectVersion,
                            url: URL(string: "https://github.com/huacnlee/autocorrect"))
                        DependencyRow(
                            name: "OpenMP", version: BuildInfo.libompVersion,
                            url: URL(string: "https://www.openmp.org"))
                    }
                }
                .padding()
                .background(Color(.controlBackgroundColor).opacity(0.3))
                .cornerRadius(12)
                .frame(maxWidth: .infinity, alignment: .leading)

                // Build Info
                VStack(alignment: .leading, spacing: 16) {
                    Text("Build Info")
                        .font(Typography.settingsHeader)
                        .foregroundColor(.primary)

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Build Date:")
                                .font(Typography.settingsLabel)
                            Spacer()
                            Text(BuildInfo.buildDate)
                                .font(Typography.settingsMono)
                                .foregroundColor(.secondary)
                        }

                        HStack {
                            Text("GPU Acceleration:")
                                .font(Typography.settingsLabel)
                            Spacer()
                            Text("Metal")
                                .font(Typography.settingsMono)
                                .foregroundColor(.secondary)
                        }

                        HStack {
                            Text("Platform:")
                                .font(Typography.settingsLabel)
                            Spacer()
                            Text("macOS (Apple Silicon)")
                                .font(Typography.settingsMono)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .padding()
                .background(Color(.controlBackgroundColor).opacity(0.3))
                .cornerRadius(12)
                .frame(maxWidth: .infinity, alignment: .leading)

                // Links
                VStack(alignment: .leading, spacing: 16) {
                    Text("Links")
                        .font(Typography.settingsHeader)
                        .foregroundColor(.primary)

                    VStack(alignment: .leading, spacing: 10) {
                        Link(destination: BuildInfo.repositoryURL) {
                            HStack {
                                Image(systemName: "link")
                                Text("GitHub Repository")
                                Spacer()
                                Image(systemName: "arrow.up.right.square")
                                    .foregroundColor(.secondary)
                            }
                            .font(Typography.settingsBody)
                        }
                        .buttonStyle(.plain)

                        Link(destination: BuildInfo.originalRepoURL) {
                            HStack {
                                Image(systemName: "tuningfork")
                                Text("Original Repository (Starmel)")
                                Spacer()
                                Image(systemName: "arrow.up.right.square")
                                    .foregroundColor(.secondary)
                            }
                            .font(Typography.settingsBody)
                        }
                        .buttonStyle(.plain)

                        Link(destination: BuildInfo.whisperCppURL) {
                            HStack {
                                Image(systemName: "waveform")
                                Text("whisper.cpp Project")
                                Spacer()
                                Image(systemName: "arrow.up.right.square")
                                    .foregroundColor(.secondary)
                            }
                            .font(Typography.settingsBody)
                        }
                        .buttonStyle(.plain)

                        Link(destination: BuildInfo.licenseURL) {
                            HStack {
                                Image(systemName: "doc.text")
                                Text("MIT License")
                                Spacer()
                                Image(systemName: "arrow.up.right.square")
                                    .foregroundColor(.secondary)
                            }
                            .font(Typography.settingsBody)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding()
                .background(Color(.controlBackgroundColor).opacity(0.3))
                .cornerRadius(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding()
        }
    }

    // MARK: - Helper Methods

    private func downloadModel(_ model: DownloadableModel) {
        Task {
            do {
                let filename = model.filename
                try await WhisperModelManager.shared.downloadModel(url: model.url, name: filename) {
                    progress in
                    // Progress is tracked via WhisperModelManager.currentDownload
                }
                // Refresh the model picker after download completes
                await MainActor.run {
                    viewModel.loadAvailableModels()
                    // Select the newly downloaded model
                    if let newModel = viewModel.availableModels.first(where: {
                        $0.lastPathComponent == filename
                    }) {
                        viewModel.selectedModelURL = newModel
                    }
                }

                // Auto-select and reload if there's no working model
                if TranscriptionService.shared.modelLoadError != nil {
                    let modelPath = WhisperModelManager.shared.modelsDirectory
                        .appendingPathComponent(filename).path
                    AppPreferences.shared.selectedModelPath = modelPath
                    TranscriptionService.shared.reloadModel(with: modelPath)
                }

                // Trigger CoreML download in background if available
                if model.hasCoreML, let coreMLURL = model.url.coreMLEncoderURL {
                    print("Starting CoreML encoder download in background...")
                    WhisperModelManager.shared.downloadCoreMLInBackground(
                        from: coreMLURL, for: filename)
                }
            } catch {
                await MainActor.run {
                    downloadErrorMessage = error.localizedDescription
                    showDownloadError = true
                }
            }
        }
    }
}

// MARK: - Helper Views

struct DependencyRow: View {
    let name: String
    let version: String
    let url: URL?

    var body: some View {
        HStack {
            Text(name)
                .font(Typography.settingsLabel)
            Spacer()
            Text(version)
                .font(Typography.settingsMono)
                .foregroundColor(.secondary)
            if let url = url {
                Link(destination: url) {
                    Image(systemName: "arrow.up.right.square")
                        .foregroundColor(.accentColor)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - LLM Model Card View

struct LLMModelCardView: View {
    let model: LLMModelInfo
    let isSelected: Bool
    let isDownloaded: Bool
    let isDownloading: Bool
    let downloadProgress: Double
    let onSelect: () -> Void
    let onDownload: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(model.displayName)
                        .font(.headline)
                        .foregroundColor(isDownloaded ? .primary : .secondary)

                    if model.id == "qwen2-0.5b-instruct-q4_k_m" {
                        Text("Recommended")
                            .font(.caption2)
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.green)
                            .cornerRadius(4)
                    }

                    if isSelected && isDownloaded {
                        Text("Selected")
                            .font(.caption2)
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor)
                            .cornerRadius(4)
                    }
                }

                Text(model.description)
                    .font(.caption)
                    .foregroundColor(.secondary)

                HStack(spacing: 16) {
                    Text(model.formattedSize)
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    Text(model.quantization)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.15))
                        .cornerRadius(4)

                    Text(model.parameterCount)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            // Status/Action
            if isDownloaded {
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.accentColor)
                        .imageScale(.large)
                } else {
                    Button("Select") {
                        onSelect()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            } else if isDownloading {
                HStack(spacing: 8) {
                    ProgressView(value: downloadProgress)
                        .frame(width: 60)
                    Text("\(Int(downloadProgress * 100))%")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(width: 35)
                    Button(action: onCancel) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Cancel download")
                }
            } else {
                Button(action: onDownload) {
                    Label("Download", systemImage: "arrow.down.circle")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(12)
        .background(cardBackground)
        .overlay(cardBorder)
        .cornerRadius(10)
        .contentShape(Rectangle())
        .opacity(isDownloaded || isDownloading ? 1 : 0.7)
    }

    private var cardBackground: some View {
        Group {
            if isSelected && isDownloaded {
                Color.accentColor.opacity(0.08)
            } else if isDownloaded {
                Color(.controlBackgroundColor).opacity(0.6)
            } else {
                Color(.controlBackgroundColor).opacity(0.4)
            }
        }
    }

    private var cardBorder: some View {
        RoundedRectangle(cornerRadius: 10)
            .stroke(borderColor, lineWidth: isSelected && isDownloaded ? 2 : 1)
    }

    private var borderColor: Color {
        if isSelected && isDownloaded {
            return Color.accentColor.opacity(0.6)
        } else if isDownloaded {
            return Color.gray.opacity(0.3)
        } else {
            return Color.gray.opacity(0.2)
        }
    }
}

// MARK: - Dictionary Helper Views

struct DictionaryTermRow: View {
    let entry: DictionaryEntry
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // Category icon
            Image(systemName: entry.category.icon)
                .foregroundColor(.accentColor)
                .frame(width: 20)

            // Term info
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.term)
                        .font(.headline)

                    // Priority indicator
                    HStack(spacing: 1) {
                        ForEach(0..<entry.priority, id: \.self) { _ in
                            Image(systemName: "star.fill")
                                .font(.system(size: 8))
                                .foregroundColor(.orange)
                        }
                    }
                }

                if !entry.aliases.isEmpty {
                    Text(entry.aliases.joined(separator: ", "))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            // Category badge
            Text(entry.category.displayName)
                .font(.caption2)
                .foregroundColor(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.15))
                .cornerRadius(4)

            // Actions
            Button(action: onEdit) {
                Image(systemName: "pencil")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("Edit term")

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .foregroundColor(.red.opacity(0.7))
            }
            .buttonStyle(.plain)
            .help("Delete term")
        }
        .padding(.vertical, 4)
    }
}

struct AddEditTermSheet: View {
    @Environment(\.dismiss) var dismiss

    let entry: DictionaryEntry?
    let onSave: (DictionaryEntry) -> Void

    @State private var term: String = ""
    @State private var aliasesText: String = ""
    @State private var category: TermCategory = .general
    @State private var priority: Int = 3
    @State private var notes: String = ""
    @State private var caseSensitive: Bool = true

    var isEditing: Bool { entry != nil }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(isEditing ? "Edit Term" : "Add Term")
                    .font(.headline)
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding()

            Divider()

            // Form
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Term field
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Term")
                            .font(Typography.settingsLabel)
                        TextField("e.g., ClockoSocket", text: $term)
                            .textFieldStyle(.roundedBorder)
                    }

                    // Aliases field
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Aliases (comma-separated)")
                            .font(Typography.settingsLabel)
                        TextField("e.g., clock o socket, cloco socket", text: $aliasesText)
                            .textFieldStyle(.roundedBorder)
                        Text("Alternative spellings or phonetic variants")
                            .font(Typography.settingsCaption)
                            .foregroundColor(.secondary)
                    }

                    // Category picker
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Category")
                            .font(Typography.settingsLabel)
                        Picker("", selection: $category) {
                            ForEach(TermCategory.allCases, id: \.self) { cat in
                                Label(cat.displayName, systemImage: cat.icon)
                                    .tag(cat)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    // Priority stepper
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Priority")
                            .font(Typography.settingsLabel)
                        HStack {
                            Stepper(value: $priority, in: 1...5) {
                                HStack(spacing: 2) {
                                    ForEach(0..<priority, id: \.self) { _ in
                                        Image(systemName: "star.fill")
                                            .foregroundColor(.orange)
                                    }
                                    ForEach(0..<(5 - priority), id: \.self) { _ in
                                        Image(systemName: "star")
                                            .foregroundColor(.secondary.opacity(0.5))
                                    }
                                }
                            }
                            Spacer()
                        }
                        Text("Higher priority terms are preferred in Whisper's initial prompt")
                            .font(Typography.settingsCaption)
                            .foregroundColor(.secondary)
                    }

                    // Case sensitive toggle
                    Toggle(isOn: $caseSensitive) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Case Sensitive")
                                .font(Typography.settingsBody)
                            Text("Preserve exact casing when replaced")
                                .font(Typography.settingsCaption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .toggleStyle(SwitchToggleStyle(tint: Color.accentColor))

                    // Notes field
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Notes (optional)")
                            .font(Typography.settingsLabel)
                        TextEditor(text: $notes)
                            .font(Typography.settingsBody)
                            .frame(height: 60)
                            .padding(4)
                            .background(Color(.textBackgroundColor))
                            .cornerRadius(6)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                            )
                    }
                }
                .padding()
            }

            Divider()

            // Footer buttons
            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.escape)

                Spacer()

                Button(isEditing ? "Save" : "Add") {
                    saveEntry()
                }
                .buttonStyle(.borderedProminent)
                .disabled(term.trimmingCharacters(in: .whitespaces).isEmpty)
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 400, height: 500)
        .onAppear {
            if let entry = entry {
                term = entry.term
                aliasesText = entry.aliases.joined(separator: ", ")
                category = entry.category
                priority = entry.priority
                notes = entry.notes ?? ""
                caseSensitive = entry.caseSensitive
            }
        }
    }

    private func saveEntry() {
        let aliases =
            aliasesText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        let newEntry = DictionaryEntry(
            id: entry?.id ?? UUID(),
            term: term.trimmingCharacters(in: .whitespaces),
            aliases: aliases,
            category: category,
            caseSensitive: caseSensitive,
            priority: priority,
            notes: notes.isEmpty ? nil : notes,
            createdAt: entry?.createdAt ?? Date(),
            updatedAt: Date()
        )

        onSave(newEntry)
        dismiss()
    }
}

struct SuggestTermsSheet: View {
    @Environment(\.dismiss) var dismiss
    @ObservedObject var dictionaryManager: DictionaryManager
    let onAddTerm: (String) -> Void

    @State private var suggestions: [String] = []
    @State private var clipboardText: String = ""

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Suggest Terms")
                    .font(.headline)
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding()

            Divider()

            if suggestions.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "lightbulb")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary)
                    Text("No suggestions found")
                        .font(Typography.settingsBody)
                        .foregroundColor(.secondary)
                    Text(
                        "Copy some transcription text to your clipboard, then open this sheet again."
                    )
                    .font(Typography.settingsCaption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(suggestions, id: \.self) { suggestion in
                        HStack {
                            Text(suggestion)
                                .font(Typography.settingsBody)
                            Spacer()
                            Button("Add") {
                                onAddTerm(suggestion)
                                suggestions.removeAll { $0 == suggestion }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
                .listStyle(.plain)
            }

            Divider()

            HStack {
                Text("\(suggestions.count) suggestions")
                    .font(Typography.settingsCaption)
                    .foregroundColor(.secondary)
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 350, height: 400)
        .onAppear {
            loadSuggestions()
        }
    }

    private func loadSuggestions() {
        if let text = NSPasteboard.general.string(forType: .string) {
            clipboardText = text
            suggestions = dictionaryManager.suggestTerms(from: text)
        }
    }
}
