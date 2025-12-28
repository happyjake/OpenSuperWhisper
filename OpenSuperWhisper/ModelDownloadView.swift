//
//  ModelDownloadView.swift
//  OpenSuperWhisper
//
//  Shared model download components used by Onboarding and Settings
//

import Foundation
import SwiftUI

// MARK: - Model Data

struct DownloadableModel: Identifiable {
    let id = UUID()
    let name: String
    let description: String
    let url: URL
    let size: Int
    let speedRate: Int
    let accuracyRate: Int
    let hasCoreML: Bool

    var filename: String { url.lastPathComponent }

    var sizeString: String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter.string(fromByteCount: Int64(size) * 1000000)
    }
}

let availableModels = [
    DownloadableModel(
        name: "Distil large V3.5",
        description: "1.5x faster, best for short-form transcription",
        url: URL(string: "https://huggingface.co/distil-whisper/distil-large-v3.5-ggml/resolve/main/ggml-model.bin?download=true")!,
        size: 1520,
        speedRate: 90,
        accuracyRate: 95,
        hasCoreML: false  // Distil models have different architecture, no CoreML encoder available
    ),
    DownloadableModel(
        name: "Turbo V3 large",
        description: "Best accuracy for long-form transcription",
        url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin?download=true")!,
        size: 1624,
        speedRate: 60,
        accuracyRate: 100,
        hasCoreML: true
    ),
    DownloadableModel(
        name: "Turbo V3 medium",
        description: "Balanced speed/accuracy, quantized (q8_0)",
        url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q8_0.bin?download=true")!,
        size: 874,
        speedRate: 70,
        accuracyRate: 70,
        hasCoreML: false  // Quantized models don't have CoreML encoders
    ),
    DownloadableModel(
        name: "Turbo V3 small",
        description: "Fastest, quantized (q5_0), lower accuracy",
        url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin?download=true")!,
        size: 574,
        speedRate: 100,
        accuracyRate: 60,
        hasCoreML: false  // Quantized models don't have CoreML encoders
    )
]

// MARK: - CoreML State

enum CoreMLState {
    case notAvailable       // Quantized model - no CoreML support
    case available          // Can download CoreML
    case downloading(progress: Double)
    case enabled            // CoreML downloaded and active
    case resumable(progress: Double)
}

// MARK: - Model Row View (for Onboarding)

struct ModelRowView: View {
    let model: DownloadableModel
    let modelManager: WhisperModelManager
    let isSelected: Bool
    let showSelectionHighlight: Bool
    let onTap: (() -> Void)?
    let onDownload: () -> Void
    let onCancel: () -> Void

    init(
        model: DownloadableModel,
        modelManager: WhisperModelManager = .shared,
        isSelected: Bool = false,
        showSelectionHighlight: Bool = false,
        onTap: (() -> Void)? = nil,
        onDownload: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.model = model
        self.modelManager = modelManager
        self.isSelected = isSelected
        self.showSelectionHighlight = showSelectionHighlight
        self.onTap = onTap
        self.onDownload = onDownload
        self.onCancel = onCancel
    }

    private var isDownloaded: Bool {
        modelManager.isModelDownloaded(name: model.filename)
    }

    private var isActivelyDownloading: Bool {
        modelManager.currentDownload?.filename == model.filename
    }

    private var downloadProgress: Double {
        if isActivelyDownloading {
            return modelManager.currentDownload?.progress ?? 0
        }
        return modelManager.getResumableDownload(for: model.filename)?.progress ?? 0
    }

    private var hasResumableDownload: Bool {
        !isActivelyDownloading && modelManager.hasResumableDownload(for: model.filename)
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(model.name)
                        .font(.headline)

                    if model.name == "Turbo V3 large" {
                        Text("Recommended")
                            .font(.caption2)
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.green)
                            .cornerRadius(4)
                    }
                }

                Text(model.description)
                    .font(.caption)
                    .foregroundColor(.secondary)

                HStack(spacing: 16) {
                    Text(model.sizeString)
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    HStack(spacing: 4) {
                        Text("Accuracy")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        ProgressView(value: Double(model.accuracyRate), total: 100)
                            .frame(width: 50)
                    }

                    HStack(spacing: 4) {
                        Text("Speed")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        ProgressView(value: Double(model.speedRate), total: 100)
                            .frame(width: 50)
                    }
                }
            }

            Spacer()

            // Status/Action
            if isDownloaded {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .imageScale(.large)
            } else if isActivelyDownloading {
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
            } else if hasResumableDownload {
                HStack(spacing: 6) {
                    Text("\(Int(downloadProgress * 100))%")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Button(action: onDownload) {
                        Label("Resume", systemImage: "arrow.clockwise")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)

                    Button(action: onCancel) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.red.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                    .help("Cancel and restart")
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
        .background(rowBackground)
        .overlay(rowBorder)
        .cornerRadius(8)
        .contentShape(Rectangle())
        .onTapGesture {
            onTap?()
        }
    }

    private var rowBackground: some View {
        Group {
            if showSelectionHighlight && isSelected {
                Color.accentColor.opacity(0.1)
            } else if isDownloaded {
                Color(.controlBackgroundColor).opacity(0.6)
            } else {
                Color(.controlBackgroundColor).opacity(0.4)
            }
        }
    }

    private var rowBorder: some View {
        RoundedRectangle(cornerRadius: 8)
            .stroke(rowBorderColor, lineWidth: (showSelectionHighlight && isSelected) ? 2 : 1)
    }

    private var rowBorderColor: Color {
        if showSelectionHighlight && isSelected {
            return Color.accentColor.opacity(0.5)
        } else if isDownloaded {
            return Color.gray.opacity(0.3)
        } else {
            return Color.gray.opacity(0.2)
        }
    }
}

// MARK: - Model Card View (Unified Settings Component)

struct ModelCardView: View {
    let model: DownloadableModel
    let modelManager: WhisperModelManager
    let isActive: Bool
    let coreMLState: CoreMLState?

    let onSelect: () -> Void
    let onDownload: () -> Void
    let onCancelDownload: () -> Void
    let onDownloadCoreML: (() -> Void)?
    let onCancelCoreML: ((Bool) -> Void)?  // Bool = deleteResumeData
    let onDeleteCoreML: (() -> Void)?

    init(
        model: DownloadableModel,
        modelManager: WhisperModelManager = .shared,
        isActive: Bool = false,
        coreMLState: CoreMLState? = nil,
        onSelect: @escaping () -> Void,
        onDownload: @escaping () -> Void,
        onCancelDownload: @escaping () -> Void,
        onDownloadCoreML: (() -> Void)? = nil,
        onCancelCoreML: ((Bool) -> Void)? = nil,
        onDeleteCoreML: (() -> Void)? = nil
    ) {
        self.model = model
        self.modelManager = modelManager
        self.isActive = isActive
        self.coreMLState = coreMLState
        self.onSelect = onSelect
        self.onDownload = onDownload
        self.onCancelDownload = onCancelDownload
        self.onDownloadCoreML = onDownloadCoreML
        self.onCancelCoreML = onCancelCoreML
        self.onDeleteCoreML = onDeleteCoreML
    }

    private var isDownloaded: Bool {
        modelManager.isModelDownloaded(name: model.filename)
    }

    private var isActivelyDownloading: Bool {
        modelManager.currentDownload?.filename == model.filename
    }

    private var downloadProgress: Double {
        if isActivelyDownloading {
            return modelManager.currentDownload?.progress ?? 0
        }
        return modelManager.getResumableDownload(for: model.filename)?.progress ?? 0
    }

    private var hasResumableDownload: Bool {
        !isActivelyDownloading && modelManager.hasResumableDownload(for: model.filename)
    }

    private var isClickable: Bool {
        isDownloaded && !isActive && !isActivelyDownloading
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Main card content
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(model.name)
                            .font(.headline)
                            .foregroundColor(isDownloaded ? .primary : .secondary)

                        if model.name == "Turbo V3 large" {
                            Text("Recommended")
                                .font(.caption2)
                                .foregroundColor(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.green)
                                .cornerRadius(4)
                        }

                        if isActive {
                            Text("Active")
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
                        Text(model.sizeString)
                            .font(.subheadline)
                            .foregroundColor(.secondary)

                        HStack(spacing: 4) {
                            Text("Accuracy")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            ProgressView(value: Double(model.accuracyRate), total: 100)
                                .frame(width: 50)
                                .opacity(isDownloaded ? 1 : 0.5)
                        }

                        HStack(spacing: 4) {
                            Text("Speed")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            ProgressView(value: Double(model.speedRate), total: 100)
                                .frame(width: 50)
                                .opacity(isDownloaded ? 1 : 0.5)
                        }
                    }
                }

                Spacer()

                // Status/Action
                statusView
            }
            .padding(12)

            // CoreML section (only for active model)
            if isActive, let coreMLState = coreMLState {
                coreMLSection(state: coreMLState)
            }
        }
        .background(cardBackground)
        .overlay(cardBorder)
        .cornerRadius(10)
        .contentShape(Rectangle())
        .onTapGesture {
            if isClickable {
                onSelect()
            }
        }
        .opacity(isDownloaded || isActivelyDownloading || hasResumableDownload ? 1 : 0.6)
    }

    @ViewBuilder
    private var statusView: some View {
        if isDownloaded {
            if isActive {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.accentColor)
                    .imageScale(.large)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .imageScale(.large)
            }
        } else if isActivelyDownloading {
            HStack(spacing: 8) {
                ProgressView(value: downloadProgress)
                    .frame(width: 60)
                Text("\(Int(downloadProgress * 100))%")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(width: 35)
                Button(action: onCancelDownload) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Cancel download")
            }
        } else if hasResumableDownload {
            HStack(spacing: 6) {
                Text("\(Int(downloadProgress * 100))%")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Button(action: onDownload) {
                    Label("Resume", systemImage: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.bordered)

                Button(action: onCancelDownload) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.red.opacity(0.8))
                }
                .buttonStyle(.plain)
                .help("Cancel and restart")
            }
        } else {
            Button(action: onDownload) {
                Label("Download", systemImage: "arrow.down.circle")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
        }
    }

    private var cardBackground: some View {
        Group {
            if isActive {
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
            .stroke(borderColor, lineWidth: isActive ? 2 : 1)
    }

    private var borderColor: Color {
        if isActive {
            return Color.accentColor.opacity(0.6)
        } else if isDownloaded {
            return Color.gray.opacity(0.3)
        } else {
            return Color.gray.opacity(0.2)
        }
    }

    @ViewBuilder
    private func coreMLSection(state: CoreMLState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
                .padding(.horizontal, 12)

            HStack(spacing: 12) {
                Image(systemName: "cpu")
                    .foregroundColor(.accentColor)
                    .frame(width: 20)

                switch state {
                case .notAvailable:
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Neural Engine")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        Text("Not available for quantized models")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()

                case .available:
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Neural Engine")
                            .font(.subheadline)
                        Text("Download for faster transcription")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    if let onDownloadCoreML = onDownloadCoreML {
                        Button("Download") {
                            onDownloadCoreML()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }

                case .downloading(let progress):
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Neural Engine")
                            .font(.subheadline)
                        Text("Downloading...")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    ProgressView(value: progress)
                        .frame(width: 80)
                    Text("\(Int(progress * 100))%")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(width: 35)
                    if let onCancelCoreML = onCancelCoreML {
                        Button("Cancel") {
                            onCancelCoreML(false)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                case .enabled:
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .imageScale(.small)
                        Text("Neural Engine")
                            .font(.subheadline)
                    }
                    Text("Enabled")
                        .font(.caption)
                        .foregroundColor(.green)
                    Spacer()
                    if let onDeleteCoreML = onDeleteCoreML {
                        Button("Delete") {
                            onDeleteCoreML()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .foregroundColor(.red)
                    }

                case .resumable(let progress):
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Neural Engine")
                            .font(.subheadline)
                        Text("Download paused (\(Int(progress * 100))%)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    if let onDownloadCoreML = onDownloadCoreML {
                        Button("Resume") {
                            onDownloadCoreML()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                    if let onCancelCoreML = onCancelCoreML {
                        Button {
                            onCancelCoreML(true)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.red.opacity(0.8))
                        }
                        .buttonStyle(.plain)
                        .help("Cancel and restart")
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
    }
}
