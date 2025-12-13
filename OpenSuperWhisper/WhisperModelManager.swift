import Combine
import Foundation

// MARK: - CoreML URL Derivation

extension URL {
    /// Returns the CoreML encoder URL derived from a GGML model URL.
    /// Returns nil if CoreML is not available (quantized models don't have CoreML encoders).
    var coreMLEncoderURL: URL? {
        let path = self.absoluteString

        // CoreML not available for quantized models
        let quantizedSuffixes = ["-q5_0.bin", "-q5_1.bin", "-q8_0.bin"]
        for suffix in quantizedSuffixes {
            if path.contains(suffix) {
                return nil
            }
        }

        // Must be a .bin file
        guard path.contains(".bin") else { return nil }

        // Derive CoreML URL: replace .bin with -encoder.mlmodelc.zip
        let coreMLPath = path
            .replacingOccurrences(of: ".bin?download=true", with: "-encoder.mlmodelc.zip?download=true")
            .replacingOccurrences(of: ".bin", with: "-encoder.mlmodelc.zip")

        return URL(string: coreMLPath)
    }
}

// MARK: - Download Delegate

class WhisperDownloadDelegate: NSObject, URLSessionTaskDelegate, URLSessionDownloadDelegate {
    private let progressCallback: (Double) -> Void
    private var expectedContentLength: Int64 = 0
    var completionHandler: ((URL?, Error?) -> Void)?
    
    init(progressCallback: @escaping (Double) -> Void) {
        self.progressCallback = progressCallback
        super.init()
    }
    
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        completionHandler?(location, nil)
    }
    
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
      
        if expectedContentLength == 0 {
            expectedContentLength = totalBytesExpectedToWrite
        }
        let progress = Double(totalBytesWritten) / Double(expectedContentLength)
        
        DispatchQueue.main.async { [weak self] in
            self?.progressCallback(progress)
        }

    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didResumeAtOffset fileOffset: Int64, expectedTotalBytes: Int64) {
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            completionHandler?(nil, error)
        } else {
        }
    }
}

class WhisperModelManager: ObservableObject {
    static let shared = WhisperModelManager()

    private let modelsDirectoryName = "whisper-models"

    // MARK: - CoreML Download State
    @Published var coreMLDownloadProgress: Double = 0
    @Published var isCoreMLDownloading: Bool = false
    private var coreMLDownloadTask: URLSessionDownloadTask?
    private var coreMLDownloadSession: URLSession?
    private var currentCoreMLModelName: String?
    
    var modelsDirectory: URL {
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let modelsDirectory = applicationSupport.appendingPathComponent(Bundle.main.bundleIdentifier!).appendingPathComponent(modelsDirectoryName)
        return modelsDirectory
    }
    
    private init() {
        createModelsDirectoryIfNeeded()
        copyDefaultModelIfNeeded()
    }
    
    private func createModelsDirectoryIfNeeded() {
        do {
            try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        } catch {
            print("Failed to create models directory: \(error)")
        }
    }
    
    private func copyDefaultModelIfNeeded() {
        let defaultModelName = "ggml-tiny.en.bin"
        let destinationURL = modelsDirectory.appendingPathComponent(defaultModelName)
        
        // Check if model already exists
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            return
        }
        
        // Look for the model in the bundle
        if let bundleURL = Bundle.main.url(forResource: "ggml-tiny.en", withExtension: "bin") {
            do {
                try FileManager.default.copyItem(at: bundleURL, to: destinationURL)
                print("Copied default model to: \(destinationURL.path)")
            } catch {
                print("Failed to copy default model: \(error)")
            }
        }
    }

    // Call this on every startup to ensure at least one model is present
    public func ensureDefaultModelPresent() {
        let defaultModelName = "ggml-tiny.en.bin"
        let destinationURL = modelsDirectory.appendingPathComponent(defaultModelName)
        if !FileManager.default.fileExists(atPath: destinationURL.path) {
            copyDefaultModelIfNeeded()
        }
    }
    
    func getAvailableModels() -> [URL] {
        do {
            return try FileManager.default.contentsOfDirectory(at: modelsDirectory, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "bin" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        } catch {
            print("Failed to get available models: \(error)")
            return []
        }
    }
    
    // Download model with progress callback using delegate
    func downloadModel(url: URL, name: String, progressCallback: @escaping (Double) -> Void) async throws {
        let destinationURL = modelsDirectory.appendingPathComponent(name)
        
        // Check if model already exists
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            print("Model already exists at: \(destinationURL.path)")
            DispatchQueue.main.async {
                progressCallback(1.0)
            }
            return
        }
        
        print("Starting model download:")
        print("- URL: \(url.absoluteString)")
        print("- Destination: \(destinationURL.path)")
        
        return try await withCheckedThrowingContinuation { continuation in
            let delegate = WhisperDownloadDelegate(progressCallback: progressCallback)
            let configuration = URLSessionConfiguration.default
            configuration.waitsForConnectivity = true
            configuration.timeoutIntervalForResource = 600 // 10 minutes timeout for large models
            
            let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: .main)
            print("Initiating download...")
            
            // Create a download task without completion handler
            let downloadTask = session.downloadTask(with: url)
            
            // Add completion handling to delegate
            delegate.completionHandler = { location, error in
                if let error = error {
                    print("Download failed with error: \(error)")
                    continuation.resume(throwing: error)
                    return
                }
                
                guard let location = location else {
                    let error = NSError(domain: "WhisperModelManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "No download URL received"])
                    continuation.resume(throwing: error)
                    return
                }
                
                do {
                    print("Download completed. Moving file to destination...")
                    try FileManager.default.moveItem(at: location, to: destinationURL)
                    print("Model successfully saved to: \(destinationURL.path)")
                    
                    DispatchQueue.main.async {
                        progressCallback(1.0)
                    }
                    
                    continuation.resume(returning: ())
                } catch {
                    print("Failed to move downloaded file: \(error)")
                    continuation.resume(throwing: error)
                }
            }
            
            downloadTask.resume()
        }
    }
    
    // Check if specific model is downloaded
    func isModelDownloaded(name: String) -> Bool {
        let modelPath = modelsDirectory.appendingPathComponent(name).path
        return FileManager.default.fileExists(atPath: modelPath)
    }

    // MARK: - CoreML Support

    /// Check if CoreML model exists for given GGML model
    func hasCoreMLModel(for ggmlModelName: String) -> Bool {
        let coreMLName = ggmlModelName
            .replacingOccurrences(of: ".bin", with: "-encoder.mlmodelc")
        let path = modelsDirectory.appendingPathComponent(coreMLName)
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// Check if CoreML is available for this model (non-quantized only)
    func isCoreMLAvailable(for ggmlURL: URL) -> Bool {
        return ggmlURL.coreMLEncoderURL != nil
    }

    /// Unzips a .zip file to destination directory
    private func unzipFile(at sourceURL: URL, to destinationURL: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-o", "-q", sourceURL.path, "-d", destinationURL.path]
        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            throw NSError(domain: "UnzipError", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "Failed to unzip CoreML model"])
        }

        // Clean up zip file after extraction
        try? FileManager.default.removeItem(at: sourceURL)
    }

    /// Download CoreML model in background (non-blocking)
    func downloadCoreMLInBackground(from coreMLURL: URL, for ggmlModelName: String) {
        guard !isCoreMLDownloading else {
            print("CoreML download already in progress")
            return
        }

        // Check if already downloaded
        if hasCoreMLModel(for: ggmlModelName) {
            print("CoreML model already exists for \(ggmlModelName)")
            return
        }

        print("Starting CoreML download:")
        print("- URL: \(coreMLURL.absoluteString)")
        print("- For model: \(ggmlModelName)")

        DispatchQueue.main.async {
            self.isCoreMLDownloading = true
            self.coreMLDownloadProgress = 0
            self.currentCoreMLModelName = ggmlModelName
        }

        let delegate = WhisperDownloadDelegate { [weak self] progress in
            DispatchQueue.main.async {
                self?.coreMLDownloadProgress = progress
            }
        }

        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForResource = 1800 // 30 minutes for large CoreML models

        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: .main)
        coreMLDownloadSession = session

        let task = session.downloadTask(with: coreMLURL)

        delegate.completionHandler = { [weak self] tempURL, error in
            guard let self = self else { return }

            defer {
                DispatchQueue.main.async {
                    self.isCoreMLDownloading = false
                    self.coreMLDownloadTask = nil
                    self.coreMLDownloadSession = nil
                    self.currentCoreMLModelName = nil
                }
            }

            guard let tempURL = tempURL, error == nil else {
                print("CoreML download failed: \(error?.localizedDescription ?? "unknown")")
                return
            }

            let zipName = ggmlModelName.replacingOccurrences(of: ".bin", with: "-encoder.mlmodelc.zip")
            let zipPath = self.modelsDirectory.appendingPathComponent(zipName)

            do {
                // Move downloaded file to models directory
                if FileManager.default.fileExists(atPath: zipPath.path) {
                    try FileManager.default.removeItem(at: zipPath)
                }
                try FileManager.default.moveItem(at: tempURL, to: zipPath)

                // Unzip to models directory
                try self.unzipFile(at: zipPath, to: self.modelsDirectory)
                print("CoreML model installed successfully for \(ggmlModelName)")
            } catch {
                print("CoreML install failed: \(error)")
            }
        }

        coreMLDownloadTask = task
        task.resume()
    }

    /// Cancel CoreML download
    func cancelCoreMLDownload() {
        coreMLDownloadTask?.cancel()
        coreMLDownloadTask = nil
        coreMLDownloadSession?.invalidateAndCancel()
        coreMLDownloadSession = nil
        DispatchQueue.main.async {
            self.isCoreMLDownloading = false
            self.coreMLDownloadProgress = 0
            self.currentCoreMLModelName = nil
        }
        print("CoreML download cancelled")
    }

    /// Delete CoreML model (user wants to free space)
    func deleteCoreMLModel(for ggmlModelName: String) throws {
        let coreMLName = ggmlModelName.replacingOccurrences(of: ".bin", with: "-encoder.mlmodelc")
        let path = modelsDirectory.appendingPathComponent(coreMLName)
        if FileManager.default.fileExists(atPath: path.path) {
            try FileManager.default.removeItem(at: path)
            print("Deleted CoreML model: \(coreMLName)")
        }
    }

    /// Get the currently selected model name from preferences
    func getCurrentModelName() -> String? {
        if let modelPath = AppPreferences.shared.selectedModelPath {
            return URL(fileURLWithPath: modelPath).lastPathComponent
        }
        return nil
    }
}
