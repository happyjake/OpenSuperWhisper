import AppKit
import ApplicationServices
import Carbon
import Combine
import Foundation
import KeyboardShortcuts
import SwiftUI

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

    @Published var initialPrompt: String {
        didSet {
            AppPreferences.shared.initialPrompt = initialPrompt
        }
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
        self.initialPrompt = prefs.initialPrompt
        self.useBeamSearch = prefs.useBeamSearch
        self.beamSize = prefs.beamSize
        self.debugMode = prefs.debugMode
        self.playSoundOnRecordStart = prefs.playSoundOnRecordStart
        self.useAsianAutocorrect = prefs.useAsianAutocorrect
        self.autoCopyToClipboard = prefs.autoCopyToClipboard

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
    var initialPrompt: String
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
        self.initialPrompt = prefs.initialPrompt
        self.useBeamSearch = prefs.useBeamSearch
        self.beamSize = prefs.beamSize
        self.useAsianAutocorrect = prefs.useAsianAutocorrect
    }
}

struct SettingsView: View {
    @StateObject private var viewModel = SettingsViewModel()
    @ObservedObject private var modelManager = WhisperModelManager.shared
    @Environment(\.dismiss) var dismiss
    @State private var isRecordingNewShortcut = false
    @State private var selectedTab: Int
    @State private var previousModelURL: URL?
    @State private var showDownloadError = false
    @State private var downloadErrorMessage = ""

    init(initialTab: Int = 0) {
        _selectedTab = State(initialValue: initialTab)
    }

    var body: some View {
        TabView(selection: $selectedTab) {

             // Shortcut Settings
            shortcutSettings
                .tabItem {
                    Label("Shortcuts", systemImage: "command")
                }
                .tag(0)
            // Model Settings
            modelSettings
                .tabItem {
                    Label("Model", systemImage: "cpu")
                }
                .tag(1)
            
            // Transcription Settings
            transcriptionSettings
                .tabItem {
                    Label("Transcription", systemImage: "text.bubble")
                }
                .tag(2)
            
            // Advanced Settings
            advancedSettings
                .tabItem {
                    Label("Advanced", systemImage: "gear")
                }
                .tag(3)

            // About
            aboutSettings
                .tabItem {
                    Label("About", systemImage: "info.circle")
                }
                .tag(4)
            }
        .padding()
        .frame(width: 550)
        .background(Color(.windowBackgroundColor))
        .toolbar {
            ToolbarItem(placement: .automatic) {
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
            }
        }
        .onAppear {
            previousModelURL = viewModel.selectedModelURL
        }
    }
    
    private var modelSettings: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Whisper Model")
                        .font(Typography.settingsHeader)
                        .foregroundColor(.primary)

                    Picker("Model", selection: $viewModel.selectedModelURL) {
                        ForEach(viewModel.availableModels, id: \.self) { url in
                            Text(url.lastPathComponent)
                                .tag(url as URL?)
                        }
                    }
                    .pickerStyle(.menu)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color(.controlBackgroundColor))
                    .cornerRadius(8)
                    .frame(maxWidth: .infinity, alignment: .leading)

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Models Directory:")
                                .font(Typography.settingsLabel)
                            Spacer()
                            Button(action: {
                                NSWorkspace.shared.open(WhisperModelManager.shared.modelsDirectory)
                            }) {
                                Label("Open Folder", systemImage: "folder")
                                    .font(Typography.settingsLabel)
                            }
                            .buttonStyle(.borderless)
                            .help("Open models directory")
                        }
                        Text(WhisperModelManager.shared.modelsDirectory.path)
                            .font(Typography.settingsMono)
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)
                            .padding(8)
                            .background(Color(.textBackgroundColor).opacity(0.5))
                            .cornerRadius(6)
                    }
                    .padding(.top, 8)

                }
                .padding()
                .background(Color(.controlBackgroundColor).opacity(0.3))
                .cornerRadius(12)
                .frame(maxWidth: .infinity, alignment: .leading)

                // Download Models Section
                VStack(alignment: .leading, spacing: 16) {
                    Text("Download Models")
                        .font(Typography.settingsHeader)
                        .foregroundColor(.primary)

                    VStack(spacing: 8) {
                        ForEach(availableModels) { model in
                            ModelRowView(
                                model: model,
                                modelManager: modelManager,
                                onDownload: {
                                    downloadModel(model)
                                },
                                onCancel: {
                                    modelManager.cancelDownload(for: model.filename)
                                }
                            )
                        }
                    }
                }
                .padding()
                .background(Color(.controlBackgroundColor).opacity(0.3))
                .cornerRadius(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .alert("Download Error", isPresented: $showDownloadError) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(downloadErrorMessage)
                }

                // CoreML Acceleration Section
                VStack(alignment: .leading, spacing: 16) {
                    Text("Neural Engine Acceleration")
                        .font(Typography.settingsHeader)
                        .foregroundColor(.primary)

                    VStack(alignment: .leading, spacing: 12) {
                        if modelManager.isCoreMLDownloading {
                            // Downloading state
                            HStack(spacing: 12) {
                                ProgressView(value: modelManager.coreMLDownloadProgress)
                                    .frame(width: 120)
                                Text("\(Int(modelManager.coreMLDownloadProgress * 100))%")
                                    .font(Typography.settingsBody)
                                    .foregroundColor(.secondary)
                                    .frame(width: 40)
                                Spacer()
                                Button("Cancel") {
                                    viewModel.cancelCoreMLDownload(deleteResumeData: false)
                                }
                                .buttonStyle(.bordered)
                            }
                            Text("Downloading CoreML encoder...")
                                .font(Typography.settingsCaption)
                                .foregroundColor(.secondary)
                        } else if viewModel.hasCoreMLModel() {
                            // Downloaded state
                            HStack {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                                Text("CoreML Enabled")
                                    .font(Typography.settingsBody)
                                Spacer()
                                Button("Delete") {
                                    viewModel.deleteCoreML()
                                }
                                .buttonStyle(.bordered)
                                .foregroundColor(.red)
                            }
                            Text("Transcription uses Apple Neural Engine for faster processing")
                                .font(Typography.settingsCaption)
                                .foregroundColor(.secondary)
                        } else if viewModel.hasCoreMLResumableDownload() {
                            // Paused/resumable download state
                            HStack(spacing: 12) {
                                Image(systemName: "arrow.clockwise.circle")
                                    .foregroundColor(.blue)
                                Text("Download Paused (\(Int(viewModel.getCoreMLResumableProgress() * 100))%)")
                                    .font(Typography.settingsBody)
                                    .foregroundColor(.secondary)
                                Spacer()
                                Button("Resume") {
                                    viewModel.downloadCoreML()
                                }
                                .buttonStyle(.borderedProminent)
                                Button {
                                    viewModel.cancelCoreMLDownload(deleteResumeData: true)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundColor(.red.opacity(0.8))
                                }
                                .buttonStyle(.plain)
                                .help("Cancel and restart from beginning")
                            }
                            Text("Tap Resume to continue downloading CoreML encoder")
                                .font(Typography.settingsCaption)
                                .foregroundColor(.secondary)
                        } else if viewModel.isCoreMLAvailable() {
                            // Available but not downloaded
                            HStack {
                                Image(systemName: "arrow.down.circle")
                                    .foregroundColor(.secondary)
                                Text("Not Downloaded")
                                    .font(Typography.settingsBody)
                                    .foregroundColor(.secondary)
                                Spacer()
                                Button("Download") {
                                    viewModel.downloadCoreML()
                                }
                                .buttonStyle(.borderedProminent)
                            }
                            Text("Download CoreML encoder for ~1.5-2x faster transcription")
                                .font(Typography.settingsCaption)
                                .foregroundColor(.secondary)

                            // Manual download instructions
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Manual download:")
                                    .font(Typography.settingsCaption)
                                    .foregroundColor(.secondary)
                                    .padding(.top, 8)

                                if let modelName = viewModel.selectedModelURL?.lastPathComponent {
                                    let baseName = modelName.replacingOccurrences(of: ".bin", with: "")
                                    let downloadURL = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(baseName)-encoder.mlmodelc.zip"
                                    Link(downloadURL, destination: URL(string: downloadURL)!)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundColor(.blue)

                                    Button("Show Models Folder") {
                                        NSWorkspace.shared.open(WhisperModelManager.shared.modelsDirectory)
                                    }
                                    .buttonStyle(.link)
                                    .font(Typography.settingsCaption)
                                    .padding(.top, 2)

                                    Text("Download the zip and extract to the models folder")
                                        .font(Typography.settingsCaption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        } else {
                            // Not available (quantized model)
                            HStack {
                                Image(systemName: "xmark.circle")
                                    .foregroundColor(.secondary)
                                Text("Not Available")
                                    .font(Typography.settingsBody)
                                    .foregroundColor(.secondary)
                            }
                            Text("CoreML acceleration is not available for quantized models. Select a non-quantized model to enable Neural Engine acceleration.")
                                .font(Typography.settingsCaption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .padding()
                .background(Color(.controlBackgroundColor).opacity(0.3))
                .cornerRadius(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding()
    }
    
    private var transcriptionSettings: some View {
        Form {
            VStack(spacing: 20) {
                // Language Settings
                VStack(alignment: .leading, spacing: 16) {
                    Text("Language Settings")
                        .font(Typography.settingsHeader)
                        .foregroundColor(.primary)

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Transcription Language")
                            .font(Typography.settingsLabel)

                        Picker("Language", selection: $viewModel.selectedLanguage) {
                            ForEach(LanguageUtil.availableLanguages, id: \.self) { code in
                                Text(LanguageUtil.languageNames[code] ?? code)
                                    .tag(code)
                            }
                        }
                        .pickerStyle(.menu)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color(.controlBackgroundColor))
                        .cornerRadius(8)
                        .frame(maxWidth: .infinity, alignment: .leading)

                        Toggle(isOn: $viewModel.translateToEnglish) {
                            Text("Translate to English")
                                .font(Typography.settingsBody)
                        }
                        .toggleStyle(SwitchToggleStyle(tint: Color.accentColor))
                        .padding(.top, 4)

                        if ["zh", "ja", "ko", "auto"].contains(viewModel.selectedLanguage) {
                            Toggle(isOn: $viewModel.useAsianAutocorrect) {
                                Text("Use Asian Autocorrect")
                                    .font(Typography.settingsBody)
                            }
                            .toggleStyle(SwitchToggleStyle(tint: Color.accentColor))
                            .padding(.top, 4)
                        }
                    }
                }
                .padding()
                .background(Color(.controlBackgroundColor).opacity(0.3))
                .cornerRadius(12)
                .frame(maxWidth: .infinity, alignment: .leading)

                // Output Options
                VStack(alignment: .leading, spacing: 16) {
                    Text("Output Options")
                        .font(Typography.settingsHeader)
                        .foregroundColor(.primary)

                    VStack(alignment: .leading, spacing: 10) {
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
                .padding()
                .background(Color(.controlBackgroundColor).opacity(0.3))
                .cornerRadius(12)
                .frame(maxWidth: .infinity, alignment: .leading)

                // Initial Prompt
                VStack(alignment: .leading, spacing: 16) {
                    Text("Initial Prompt")
                        .font(Typography.settingsHeader)
                        .foregroundColor(.primary)

                    VStack(alignment: .leading, spacing: 8) {
                        TextEditor(text: $viewModel.initialPrompt)
                            .font(Typography.settingsBody)
                            .frame(height: 60)
                            .padding(6)
                            .background(Color(.textBackgroundColor))
                            .cornerRadius(8)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                            )

                        Text("Optional text to guide the model's transcription")
                            .font(Typography.settingsCaption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding()
                .background(Color(.controlBackgroundColor).opacity(0.3))
                .cornerRadius(12)
                .frame(maxWidth: .infinity, alignment: .leading)

                // Transcriptions Directory
                VStack(alignment: .leading, spacing: 16) {
                    Text("Transcriptions Directory")
                        .font(Typography.settingsHeader)
                        .foregroundColor(.primary)

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Directory:")
                                .font(Typography.settingsLabel)
                            Spacer()
                            Button(action: {
                                NSWorkspace.shared.open(Recording.recordingsDirectory)
                            }) {
                                Label("Open Folder", systemImage: "folder")
                                    .font(Typography.settingsLabel)
                            }
                            .buttonStyle(.borderless)
                            .help("Open transcriptions directory")
                        }

                        Text(Recording.recordingsDirectory.path)
                            .font(Typography.settingsMono)
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)
                            .padding(8)
                            .background(Color(.textBackgroundColor).opacity(0.5))
                            .cornerRadius(6)
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
    
    private var advancedSettings: some View {
        Form {
            VStack(spacing: 20) {
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
        Form {
            VStack(spacing: 20) {
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
        Form {
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

