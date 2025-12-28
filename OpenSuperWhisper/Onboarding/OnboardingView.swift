//
//  OnboardingView.swift
//  OpenSuperWhisper
//
//  Created by user on 08.02.2025.
//

import Foundation
import SwiftUI

class OnboardingViewModel: ObservableObject {
    @Published var selectedLanguage: String {
        didSet {
            AppPreferences.shared.whisperLanguage = selectedLanguage
        }
    }

    @Published var selectedModel: DownloadableModel?
    @Published var showDownloadError = false
    @Published var downloadErrorMessage = ""

    init() {
        let systemLanguage = LanguageUtil.getSystemLanguage()
        AppPreferences.shared.whisperLanguage = systemLanguage
        self.selectedLanguage = systemLanguage

        // Select default model
        if let defaultModel = availableModels.first(where: { $0.name == "Turbo V3 large" }) {
            selectedModel = defaultModel
        }
    }

    @MainActor
    func downloadSelectedModel() async throws {
        guard let model = selectedModel else { return }
        guard !WhisperModelManager.shared.isModelDownloaded(name: model.filename) else { return }
        guard WhisperModelManager.shared.currentDownload == nil else { return }

        let filename = model.filename
        try await WhisperModelManager.shared.downloadModel(url: model.url, name: filename) { progress in
            // Progress is tracked via WhisperModelManager.currentDownload
        }

        // After download completes, select this model
        let modelPath = WhisperModelManager.shared.modelsDirectory.appendingPathComponent(filename).path
        AppPreferences.shared.selectedModelPath = modelPath
        print("Model path after download: \(modelPath)")

        // Reload model if there's an error
        if TranscriptionService.shared.modelLoadError != nil {
            TranscriptionService.shared.reloadModel(with: modelPath)
        }

        // Trigger CoreML download in background if available
        if model.hasCoreML, let coreMLURL = model.url.coreMLEncoderURL {
            print("Starting CoreML encoder download in background...")
            WhisperModelManager.shared.downloadCoreMLInBackground(from: coreMLURL, for: filename)
        }
    }
}

struct OnboardingView: View {
    @StateObject private var viewModel = OnboardingViewModel()
    @ObservedObject private var modelManager = WhisperModelManager.shared
    @EnvironmentObject private var appState: AppState

    var body: some View {
        ZStack {
            VStack(alignment: .leading) {
                Text("Welcome to OpenSuperWhisper!")
                    .font(.title)
                    .padding()

                // Language selection
                VStack(alignment: .leading) {
                    Text("Choose speech language")
                        .font(.headline)
                    Picker("", selection: $viewModel.selectedLanguage) {
                        ForEach(LanguageUtil.availableLanguages, id: \.self) { code in
                            Text(LanguageUtil.languageNames[code] ?? code)
                                .tag(code)
                        }
                    }
                    .frame(width: 200)
                }
                .padding()

                VStack(alignment: .leading) {
                    Text("Choose Model")
                        .font(.headline)

                    Text("The model is designed to transcribe audio into text. It is a powerful tool that can be used to transcribe audio into text.")
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 8)
                }
                .padding()

                // Model list
                VStack(spacing: 8) {
                    ForEach(availableModels) { model in
                        ModelRowView(
                            model: model,
                            modelManager: modelManager,
                            isSelected: model.name == viewModel.selectedModel?.name,
                            showSelectionHighlight: true,
                            onTap: {
                                viewModel.selectedModel = model
                            },
                            onDownload: {
                                viewModel.selectedModel = model
                                handleDownload(model)
                            },
                            onCancel: {
                                modelManager.cancelDownload(for: model.filename)
                            }
                        )
                    }
                }
                .padding(.horizontal)

                HStack {
                    Spacer()
                    Button(action: {
                        handleNextButtonTap()
                    }) {
                        Text("Next")
                    }
                    .padding()
                    .disabled(viewModel.selectedModel == nil || modelManager.currentDownload != nil)
                }
            }
            .padding()
            .frame(width: 450, height: 650)
            .alert("Download Error", isPresented: $viewModel.showDownloadError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(viewModel.downloadErrorMessage)
            }
        }
    }

    private func handleDownload(_ model: DownloadableModel) {
        Task {
            do {
                viewModel.selectedModel = model
                try await viewModel.downloadSelectedModel()
            } catch {
                await MainActor.run {
                    viewModel.downloadErrorMessage = error.localizedDescription
                    viewModel.showDownloadError = true
                }
            }
        }
    }

    private func handleNextButtonTap() {
        guard let selectedModel = viewModel.selectedModel else { return }

        if modelManager.isModelDownloaded(name: selectedModel.filename) {
            // Model already downloaded, set path and proceed
            let modelPath = modelManager.modelsDirectory.appendingPathComponent(selectedModel.filename).path
            AppPreferences.shared.selectedModelPath = modelPath
            appState.hasCompletedOnboarding = true
        } else {
            // Need to download first
            Task {
                do {
                    try await viewModel.downloadSelectedModel()
                    await MainActor.run {
                        appState.hasCompletedOnboarding = true
                    }
                } catch {
                    await MainActor.run {
                        viewModel.downloadErrorMessage = error.localizedDescription
                        viewModel.showDownloadError = true
                    }
                }
            }
        }
    }
}

#Preview {
    OnboardingView()
}
