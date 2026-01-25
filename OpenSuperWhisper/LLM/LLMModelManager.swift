//
//  LLMModelManager.swift
//  OpenSuperWhisper
//
//  Manages LLM model downloads and storage.
//  Following the pattern from WhisperModelManager.swift
//

import AppKit
import Combine
import Foundation
import CryptoKit

// MARK: - LLM Model Info

/// Information about an LLM model
public struct LLMModelInfo: Codable, Identifiable, Equatable {
    public let id: String
    public let name: String
    public let displayName: String
    public let description: String
    public let sizeBytes: Int64
    public let downloadURL: URL
    public let sha256: String?
    public let quantization: String
    public let parameterCount: String
    public let chatTemplate: String?

    /// Formatted size string (e.g., "1.2 GB")
    public var formattedSize: String {
        let gb = Double(sizeBytes) / 1024 / 1024 / 1024
        if gb >= 1.0 {
            return String(format: "%.1f GB", gb)
        }
        let mb = Double(sizeBytes) / 1024 / 1024
        return String(format: "%.0f MB", mb)
    }

    public static func == (lhs: LLMModelInfo, rhs: LLMModelInfo) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Active Download State

public struct LLMActiveDownload: Equatable, Sendable {
    public let filename: String
    public var progress: Double

    public init(filename: String, progress: Double) {
        self.filename = filename
        self.progress = progress
    }
}

// MARK: - LLM Model Manager

/// Manages LLM model files: downloading, storage, and selection
public final class LLMModelManager: ObservableObject, @unchecked Sendable {
    public static let shared = LLMModelManager()

    private let modelsDirectoryName = "llama-models"

    // MARK: - Published State

    /// Current active download (nil if not downloading)
    @Published public var currentDownload: LLMActiveDownload?

    /// Computed property for backwards compatibility
    public var isDownloading: Bool { currentDownload != nil }
    public var currentDownloadFilename: String? { currentDownload?.filename }
    public var downloadProgress: Double { currentDownload?.progress ?? 0 }

    // MARK: - Private Properties

    private var downloadTask: URLSessionDownloadTask?
    private var downloadSession: URLSession?
    private var downloadContinuation: CheckedContinuation<Void, Error>?
    private var progressCallback: ((Double) -> Void)?

    // MARK: - Available Models

    /// Predefined models available for download
    public static let availableModels: [LLMModelInfo] = [
        LLMModelInfo(
            id: "qwen2-0.5b-instruct-q4_k_m",
            name: "qwen2-0_5b-instruct-q4_k_m.gguf",
            displayName: "Qwen2 0.5B Instruct",
            description: "Tiny but capable instruction-following model. Best for simple text cleanup tasks.",
            sizeBytes: 395_000_000,  // ~395 MB
            downloadURL: URL(string: "https://huggingface.co/Qwen/Qwen2-0.5B-Instruct-GGUF/resolve/main/qwen2-0_5b-instruct-q4_k_m.gguf")!,
            sha256: nil,
            quantization: "Q4_K_M",
            parameterCount: "0.5B",
            chatTemplate: "chatml"
        ),
        LLMModelInfo(
            id: "tinyllama-1.1b-chat-q4_k_m",
            name: "tinyllama-1.1b-chat-v1.0.Q4_K_M.gguf",
            displayName: "TinyLlama 1.1B Chat",
            description: "Small and fast chat model. Good balance of speed and quality.",
            sizeBytes: 669_000_000,  // ~669 MB
            downloadURL: URL(string: "https://huggingface.co/TheBloke/TinyLlama-1.1B-Chat-v1.0-GGUF/resolve/main/tinyllama-1.1b-chat-v1.0.Q4_K_M.gguf")!,
            sha256: nil,
            quantization: "Q4_K_M",
            parameterCount: "1.1B",
            chatTemplate: "zephyr"
        ),
        LLMModelInfo(
            id: "phi-3-mini-4k-instruct-q4_k_m",
            name: "Phi-3-mini-4k-instruct-q4.gguf",
            displayName: "Phi-3 Mini 4K Instruct",
            description: "Microsoft's compact yet powerful model. Excellent for text editing tasks.",
            sizeBytes: 2_390_000_000,  // ~2.39 GB
            downloadURL: URL(string: "https://huggingface.co/microsoft/Phi-3-mini-4k-instruct-gguf/resolve/main/Phi-3-mini-4k-instruct-q4.gguf")!,
            sha256: nil,
            quantization: "Q4",
            parameterCount: "3.8B",
            chatTemplate: "phi"
        ),
        LLMModelInfo(
            id: "qwen2.5-1.5b-instruct-q4_k_m",
            name: "qwen2.5-1.5b-instruct-q4_k_m.gguf",
            displayName: "Qwen2.5 1.5B Instruct",
            description: "Upgraded Qwen model. Better reasoning and instruction following.",
            sizeBytes: 987_000_000,  // ~987 MB
            downloadURL: URL(string: "https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/main/qwen2.5-1.5b-instruct-q4_k_m.gguf")!,
            sha256: nil,
            quantization: "Q4_K_M",
            parameterCount: "1.5B",
            chatTemplate: "chatml"
        ),
        LLMModelInfo(
            id: "smollm2-1.7b-instruct-q4_k_m",
            name: "smollm2-1.7b-instruct-q4_k_m.gguf",
            displayName: "SmolLM2 1.7B Instruct",
            description: "Hugging Face's efficient small model. Great for on-device inference.",
            sizeBytes: 1_060_000_000,  // ~1.06 GB
            downloadURL: URL(string: "https://huggingface.co/HuggingFaceTB/SmolLM2-1.7B-Instruct-GGUF/resolve/main/smollm2-1.7b-instruct-q4_k_m.gguf")!,
            sha256: nil,
            quantization: "Q4_K_M",
            parameterCount: "1.7B",
            chatTemplate: "chatml"
        )
    ]

    // MARK: - Directory Management

    /// Get the models directory
    public var modelsDirectory: URL {
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let modelsDirectory = applicationSupport
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "OpenSuperWhisper")
            .appendingPathComponent(modelsDirectoryName)
        return modelsDirectory
    }

    // MARK: - Initialization

    private init() {
        createModelsDirectoryIfNeeded()
    }

    private func createModelsDirectoryIfNeeded() {
        do {
            try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        } catch {
            print("LLMModelManager: Failed to create models directory: \(error)")
        }
    }

    // MARK: - Model Discovery

    /// Get all downloaded models
    public func getDownloadedModels() -> [URL] {
        do {
            return try FileManager.default.contentsOfDirectory(at: modelsDirectory, includingPropertiesForKeys: [.fileSizeKey])
                .filter { $0.pathExtension == "gguf" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        } catch {
            print("LLMModelManager: Failed to list models: \(error)")
            return []
        }
    }

    /// Check if a specific model is downloaded
    public func isModelDownloaded(name: String) -> Bool {
        let modelPath = modelsDirectory.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: modelPath.path)
    }

    /// Check if a specific model info is downloaded
    public func isModelDownloaded(_ model: LLMModelInfo) -> Bool {
        return isModelDownloaded(name: model.name)
    }

    /// Get model info for a downloaded model
    public func getModelInfo(for filename: String) -> LLMModelInfo? {
        return Self.availableModels.first { $0.name == filename }
    }

    /// Get the file size of a downloaded model
    public func getModelSize(name: String) -> Int64? {
        let modelPath = modelsDirectory.appendingPathComponent(name)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: modelPath.path),
              let size = attributes[.size] as? Int64 else {
            return nil
        }
        return size
    }

    // MARK: - Model Download

    /// Download a model with progress callback
    public func downloadModel(_ model: LLMModelInfo, progressCallback: @escaping (Double) -> Void) async throws {
        try await downloadModel(url: model.downloadURL, name: model.name, progressCallback: progressCallback)
    }

    /// Download model from URL with progress callback
    public func downloadModel(url: URL, name: String, progressCallback: @escaping (Double) -> Void) async throws {
        let destinationURL = modelsDirectory.appendingPathComponent(name)

        // Check if model already exists
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            print("LLMModelManager: Model already exists at: \(destinationURL.path)")
            await MainActor.run {
                progressCallback(1.0)
            }
            return
        }

        print("LLMModelManager: Starting model download:")
        print("- URL: \(url.absoluteString)")
        print("- Destination: \(destinationURL.path)")

        // Track download state
        await MainActor.run {
            self.currentDownload = LLMActiveDownload(filename: name, progress: 0)
        }

        return try await withCheckedThrowingContinuation { [weak self] continuation in
            guard let self = self else {
                continuation.resume(throwing: NSError(domain: "LLMModelManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Manager deallocated"]))
                return
            }

            self.downloadContinuation = continuation
            self.progressCallback = progressCallback

            let delegate = LLMDownloadDelegate(
                progressCallback: { progress in
                    Task { @MainActor in
                        self.currentDownload = LLMActiveDownload(filename: name, progress: progress)
                        progressCallback(progress)
                    }
                },
                completionCallback: { [weak self] tempURL, error in
                    guard let self = self else { return }

                    Task { @MainActor in
                        self.currentDownload = nil
                        self.downloadTask = nil
                        self.downloadSession = nil
                    }

                    if let error = error {
                        self.downloadContinuation?.resume(throwing: error)
                        self.downloadContinuation = nil
                        return
                    }

                    guard let tempURL = tempURL else {
                        self.downloadContinuation?.resume(throwing: NSError(domain: "LLMModelManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "No download URL received"]))
                        self.downloadContinuation = nil
                        return
                    }

                    do {
                        // Remove existing file if any
                        if FileManager.default.fileExists(atPath: destinationURL.path) {
                            try FileManager.default.removeItem(at: destinationURL)
                        }
                        try FileManager.default.moveItem(at: tempURL, to: destinationURL)

                        print("LLMModelManager: Model downloaded to \(destinationURL.path)")
                        Task { @MainActor in
                            progressCallback(1.0)
                        }
                        self.downloadContinuation?.resume(returning: ())
                    } catch {
                        self.downloadContinuation?.resume(throwing: error)
                    }
                    self.downloadContinuation = nil
                }
            )

            let configuration = URLSessionConfiguration.default
            configuration.waitsForConnectivity = true
            configuration.timeoutIntervalForResource = 3600  // 1 hour for large models

            let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: .main)
            self.downloadSession = session

            let task = session.downloadTask(with: url)
            self.downloadTask = task
            task.resume()
        }
    }

    /// Cancel the current download
    public func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        downloadSession?.invalidateAndCancel()
        downloadSession = nil

        Task { @MainActor in
            self.currentDownload = nil
        }

        downloadContinuation?.resume(throwing: NSError(domain: "LLMModelManager", code: -999, userInfo: [NSLocalizedDescriptionKey: "Download cancelled"]))
        downloadContinuation = nil

        print("LLMModelManager: Download cancelled")
    }

    // MARK: - Model Deletion

    /// Delete a downloaded model
    public func deleteModel(name: String) throws {
        let modelPath = modelsDirectory.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: modelPath.path) {
            try FileManager.default.removeItem(at: modelPath)
            print("LLMModelManager: Deleted model \(name)")
        }
    }

    /// Delete a downloaded model
    public func deleteModel(_ model: LLMModelInfo) throws {
        try deleteModel(name: model.name)
    }

    // MARK: - SHA256 Verification

    /// Verify the SHA256 hash of a downloaded model
    public func verifyModelHash(name: String, expectedHash: String) -> Bool {
        let modelPath = modelsDirectory.appendingPathComponent(name)

        guard let inputStream = InputStream(url: modelPath) else {
            print("LLMModelManager: Cannot open file for hash verification")
            return false
        }

        inputStream.open()
        defer { inputStream.close() }

        var hasher = SHA256()
        let bufferSize = 1024 * 1024  // 1MB chunks
        var buffer = [UInt8](repeating: 0, count: bufferSize)

        while inputStream.hasBytesAvailable {
            let bytesRead = inputStream.read(&buffer, maxLength: bufferSize)
            if bytesRead > 0 {
                hasher.update(data: Data(buffer[0..<bytesRead]))
            } else if bytesRead < 0 {
                print("LLMModelManager: Error reading file for hash verification")
                return false
            }
        }

        let digest = hasher.finalize()
        let computedHash = digest.map { String(format: "%02x", $0) }.joined()

        let matches = computedHash.lowercased() == expectedHash.lowercased()
        if !matches {
            print("LLMModelManager: Hash mismatch!")
            print("- Expected: \(expectedHash)")
            print("- Computed: \(computedHash)")
        }

        return matches
    }

    // MARK: - Recommended Model

    /// Get the recommended model based on available memory
    public func getRecommendedModel() -> LLMModelInfo {
        let availableMemory = LLMMemoryManager.shared.getAvailableMemory()
        let availableGB = Double(availableMemory) / 1024 / 1024 / 1024

        // Recommend based on available memory
        if availableGB >= 8 {
            // Plenty of memory - recommend Phi-3 Mini
            return Self.availableModels.first { $0.id == "phi-3-mini-4k-instruct-q4_k_m" }!
        } else if availableGB >= 4 {
            // Moderate memory - recommend Qwen2.5 1.5B
            return Self.availableModels.first { $0.id == "qwen2.5-1.5b-instruct-q4_k_m" }!
        } else if availableGB >= 2 {
            // Low memory - recommend TinyLlama
            return Self.availableModels.first { $0.id == "tinyllama-1.1b-chat-q4_k_m" }!
        } else {
            // Very low memory - recommend Qwen2 0.5B
            return Self.availableModels.first { $0.id == "qwen2-0.5b-instruct-q4_k_m" }!
        }
    }
}

// MARK: - Download Delegate

private class LLMDownloadDelegate: NSObject, URLSessionDownloadDelegate {
    private let progressCallback: (Double) -> Void
    private let completionCallback: (URL?, Error?) -> Void

    init(progressCallback: @escaping (Double) -> Void, completionCallback: @escaping (URL?, Error?) -> Void) {
        self.progressCallback = progressCallback
        self.completionCallback = completionCallback
        super.init()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        completionCallback(location, nil)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        progressCallback(progress)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            completionCallback(nil, error)
        }
    }
}
