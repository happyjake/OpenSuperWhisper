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
    let url: URL
    let size: Int
    let speedRate: Int
    let accuracyRate: Int

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
        name: "Turbo V3 large",
        url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin?download=true")!,
        size: 1624,
        speedRate: 60,
        accuracyRate: 100
    ),
    DownloadableModel(
        name: "Turbo V3 medium",
        url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q8_0.bin?download=true")!,
        size: 874,
        speedRate: 70,
        accuracyRate: 70
    ),
    DownloadableModel(
        name: "Turbo V3 small",
        url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin?download=true")!,
        size: 574,
        speedRate: 100,
        accuracyRate: 60
    )
]

// MARK: - Single Reusable UI Component

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
        .background(showSelectionHighlight && isSelected ? Color.gray.opacity(0.3) : Color(.controlBackgroundColor).opacity(0.5))
        .cornerRadius(8)
        .contentShape(Rectangle())
        .onTapGesture {
            onTap?()
        }
    }
}
