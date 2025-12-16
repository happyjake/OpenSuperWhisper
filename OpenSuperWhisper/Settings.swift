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

        // Load language prompts with migration from old initialPrompt
        var loadedPrompts = prefs.languagePrompts
        if loadedPrompts.isEmpty && !prefs.initialPrompt.isEmpty {
            // Migrate old single initialPrompt to the current language
            loadedPrompts[prefs.whisperLanguage == "auto" ? "en" : prefs.whisperLanguage] = prefs.initialPrompt
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
        let huggingFaceURLString = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(baseName)-encoder.mlmodelc.zip?download=true"
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
        accessibilityCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
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
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
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
    }

    /// Get the effective prompt for a language (user-customized or default)
    func getPrompt(for language: String) -> String? {
        let prompt = LanguageUtil.getEffectivePrompt(for: language, userPrompts: languagePrompts)
        return prompt.isEmpty ? nil : prompt
    }
}

struct SettingsView: View {
    @StateObject private var viewModel = SettingsViewModel()
    @ObservedObject private var modelManager = WhisperModelManager.shared
    @Environment(\.dismiss) var dismiss
    @State private var isRecordingNewShortcut = false
    @State private var selectedTab: Int = 0
    @State private var previousModelURL: URL?
    @State private var showDownloadError = false
    @State private var downloadErrorMessage = ""

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
                tabButton(title: "Advanced", icon: "gear", tag: 3)
                tabButton(title: "About", icon: "info.circle", tag: 4)
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
                case 3: advancedSettings
                case 4: aboutSettings
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
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                Text(title)
                    .font(.system(size: 12))
            }
            .padding(.horizontal, 10)
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
                        let isActive = viewModel.selectedModelURL?.lastPathComponent == model.filename
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

        // Check if quantized
        let quantizedSuffixes = ["-q5_0.bin", "-q5_1.bin", "-q8_0.bin"]
        for suffix in quantizedSuffixes {
            if modelName.contains(suffix) {
                return .notAvailable
            }
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
            let progress = WhisperModelManager.shared.getCoreMLResumableDownload(for: modelName)?.progress ?? 0
            return .resumable(progress: progress)
        }

        return .available
    }

    private func selectModel(_ model: DownloadableModel) {
        let modelPath = WhisperModelManager.shared.modelsDirectory.appendingPathComponent(model.filename)
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
                                ForEach(LanguageUtil.availableLanguages.filter { $0 != "auto" }, id: \.self) { code in
                                    HStack {
                                        Text(LanguageUtil.languageNames[code] ?? code)
                                        if LanguageUtil.isCustomPrompt(for: code, userPrompts: viewModel.languagePrompts) {
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
                                let lang = viewModel.selectedLanguage == "auto"
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
                    TextEditor(text: Binding(
                        get: { viewModel.currentEditingPrompt },
                        set: { viewModel.currentEditingPrompt = $0 }
                    ))
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
                        let langName = viewModel.selectedLanguage == "auto"
                            ? (LanguageUtil.languageNames[viewModel.editingPromptLanguage] ?? viewModel.editingPromptLanguage)
                            : (LanguageUtil.languageNames[viewModel.selectedLanguage] ?? viewModel.selectedLanguage)
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
                                Stepper("\(viewModel.beamSize)", value: $viewModel.beamSize, in: 1...10)
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
                            KeyboardShortcuts.Recorder("", name: .toggleRecord)
                                .frame(width: 120)
                        }

                        if isRecordingNewShortcut {
                            Text("Press your new shortcut combination...")
                                .foregroundColor(.secondary)
                                .font(Typography.settingsBody)
                                .padding(.vertical, 4)
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
                            Text("Press any key combination to set as the recording shortcut")
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
                            Text("Recommended to use Command (⌘) or Option (⌥) key combinations")
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
                    Text("Accessibility (Optional)")
                        .font(Typography.settingsHeader)
                        .foregroundColor(.primary)

                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Image(systemName: viewModel.isAccessibilityPermissionGranted ? "checkmark.circle.fill" : "info.circle.fill")
                                .foregroundColor(viewModel.isAccessibilityPermissionGranted ? .green : .blue)
                            Text("Accessibility Access")
                                .font(Typography.settingsLabel)
                            Spacer()
                            if !viewModel.isAccessibilityPermissionGranted {
                                Button("Grant Access") {
                                    viewModel.openAccessibilityPreferences()
                                }
                                .buttonStyle(.bordered)
                            }
                        }

                        Text(viewModel.isAccessibilityPermissionGranted
                            ? "Recording indicator will appear near your text cursor."
                            : "Accessibility is optional. Without it, the recording indicator will appear near your mouse cursor instead of the text caret. Keyboard shortcuts work without this permission.")
                            .font(Typography.settingsCaption)
                            .foregroundColor(.secondary)
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

                    if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
                       let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String {
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
                        DependencyRow(name: "whisper.cpp", version: BuildInfo.whisperCppVersion, url: BuildInfo.whisperCppURL)
                        DependencyRow(name: "GRDB.swift", version: BuildInfo.grdbVersion, url: URL(string: "https://github.com/groue/GRDB.swift"))
                        DependencyRow(name: "KeyboardShortcuts", version: BuildInfo.keyboardShortcutsVersion, url: URL(string: "https://github.com/sindresorhus/KeyboardShortcuts"))
                        DependencyRow(name: "autocorrect", version: BuildInfo.autocorrectVersion, url: URL(string: "https://github.com/huacnlee/autocorrect"))
                        DependencyRow(name: "OpenMP", version: BuildInfo.libompVersion, url: URL(string: "https://www.openmp.org"))
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
                try await WhisperModelManager.shared.downloadModel(url: model.url, name: filename) { progress in
                    // Progress is tracked via WhisperModelManager.currentDownload
                }
                // Refresh the model picker after download completes
                await MainActor.run {
                    viewModel.loadAvailableModels()
                    // Select the newly downloaded model
                    if let newModel = viewModel.availableModels.first(where: { $0.lastPathComponent == filename }) {
                        viewModel.selectedModelURL = newModel
                    }
                }

                // Auto-select and reload if there's no working model
                if TranscriptionService.shared.modelLoadError != nil {
                    let modelPath = WhisperModelManager.shared.modelsDirectory.appendingPathComponent(filename).path
                    AppPreferences.shared.selectedModelPath = modelPath
                    TranscriptionService.shared.reloadModel(with: modelPath)
                }

                // Trigger CoreML download in background if available
                if let coreMLURL = model.url.coreMLEncoderURL {
                    print("Starting CoreML encoder download in background...")
                    WhisperModelManager.shared.downloadCoreMLInBackground(from: coreMLURL, for: filename)
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

