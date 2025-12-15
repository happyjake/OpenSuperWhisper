import AppKit
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

// MARK: - Resumable Download

struct ResumableDownload: Codable {
    let id: UUID
    let downloadURL: URL
    let destinationFilename: String
    let downloadType: DownloadType
    let resumeData: Data
    let bytesDownloaded: Int64
    let totalBytes: Int64
    let createdAt: Date

    enum DownloadType: String, Codable {
        case ggml
        case coreML
    }

    var progress: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(bytesDownloaded) / Double(totalBytes)
    }
}

// MARK: - Resumable Download Store

class ResumableDownloadStore {
    private let cacheDirectory: URL

    init() {
        let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        cacheDirectory = cachesDir
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "OpenSuperWhisper")
            .appendingPathComponent("download-resume")
        createDirectoryIfNeeded()
    }

    private func createDirectoryIfNeeded() {
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    private func metadataURL(for id: UUID) -> URL {
        cacheDirectory.appendingPathComponent("\(id.uuidString).json")
    }

    private func resumeDataURL(for id: UUID) -> URL {
        cacheDirectory.appendingPathComponent("\(id.uuidString).resumedata")
    }

    func save(_ download: ResumableDownload) throws {
        // Save metadata (without resumeData to keep JSON small)
        struct Metadata: Codable {
            let id: UUID
            let downloadURL: URL
            let destinationFilename: String
            let downloadType: ResumableDownload.DownloadType
            let bytesDownloaded: Int64
            let totalBytes: Int64
            let createdAt: Date
        }

        let metadata = Metadata(
            id: download.id,
            downloadURL: download.downloadURL,
            destinationFilename: download.destinationFilename,
            downloadType: download.downloadType,
            bytesDownloaded: download.bytesDownloaded,
            totalBytes: download.totalBytes,
            createdAt: download.createdAt
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let metadataData = try encoder.encode(metadata)
        try metadataData.write(to: metadataURL(for: download.id))

        // Save resume data separately (binary)
        try download.resumeData.write(to: resumeDataURL(for: download.id))

        print("ResumableDownloadStore: Saved resume data for \(download.destinationFilename)")
    }

    func load(for filename: String) -> ResumableDownload? {
        return loadAll().first { $0.destinationFilename == filename }
    }

    func loadAll() -> [ResumableDownload] {
        createDirectoryIfNeeded()

        guard let files = try? FileManager.default.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil) else {
            return []
        }

        let jsonFiles = files.filter { $0.pathExtension == "json" }
        var downloads: [ResumableDownload] = []

        for jsonFile in jsonFiles {
            guard let metadataData = try? Data(contentsOf: jsonFile) else { continue }

            struct Metadata: Codable {
                let id: UUID
                let downloadURL: URL
                let destinationFilename: String
                let downloadType: ResumableDownload.DownloadType
                let bytesDownloaded: Int64
                let totalBytes: Int64
                let createdAt: Date
            }

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard let metadata = try? decoder.decode(Metadata.self, from: metadataData) else { continue }

            // Check if resume data file still exists (macOS may have cleared cache)
            let resumeDataFile = resumeDataURL(for: metadata.id)
            guard let resumeData = try? Data(contentsOf: resumeDataFile) else {
                // Cache was cleared - delete the orphaned metadata
                try? FileManager.default.removeItem(at: jsonFile)
                continue
            }

            let download = ResumableDownload(
                id: metadata.id,
                downloadURL: metadata.downloadURL,
                destinationFilename: metadata.destinationFilename,
                downloadType: metadata.downloadType,
                resumeData: resumeData,
                bytesDownloaded: metadata.bytesDownloaded,
                totalBytes: metadata.totalBytes,
                createdAt: metadata.createdAt
            )
            downloads.append(download)
        }

        return downloads
    }

    func delete(id: UUID) {
        try? FileManager.default.removeItem(at: metadataURL(for: id))
        try? FileManager.default.removeItem(at: resumeDataURL(for: id))
        print("ResumableDownloadStore: Deleted resume data for \(id)")
    }

    func delete(for filename: String) {
        if let download = load(for: filename) {
            delete(id: download.id)
        }
    }
}

// MARK: - Background Download Delegate (for crash-resilient downloads)

class BackgroundDownloadDelegate: NSObject, URLSessionDownloadDelegate {
    weak var manager: WhisperModelManager?

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let manager = manager else { return }

        // Determine destination based on task description (stores filename)
        guard let filename = downloadTask.taskDescription else {
            print("BackgroundDownloadDelegate: No filename in task description")
            return
        }

        let isCoreML = filename.hasSuffix(".zip")
        let destinationURL = manager.modelsDirectory.appendingPathComponent(filename)

        do {
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            try FileManager.default.moveItem(at: location, to: destinationURL)
            print("BackgroundDownloadDelegate: Downloaded \(filename)")

            // Handle CoreML unzip
            if isCoreML {
                try manager.unzipFile(at: destinationURL, to: manager.modelsDirectory)
            }

            // Clean up resume data
            manager.resumableStore.delete(for: filename)

            DispatchQueue.main.async {
                manager.resumableDownloads.removeAll { $0.destinationFilename == filename }

                if isCoreML {
                    manager.currentCoreMLDownload = nil
                } else {
                    // GGML model - call progress callback and continuation
                    manager.downloadProgressCallbacks[filename]?(1.0)
                    manager.downloadProgressCallbacks.removeValue(forKey: filename)
                    manager.downloadContinuations[filename]?.resume(returning: ())
                    manager.downloadContinuations.removeValue(forKey: filename)
                    manager.currentDownload = nil

                    // Only auto-select and reload if there's no working model
                    if TranscriptionService.shared.modelLoadError != nil {
                        let modelPath = manager.modelsDirectory.appendingPathComponent(filename).path
                        AppPreferences.shared.selectedModelPath = modelPath
                        TranscriptionService.shared.reloadModel(with: modelPath)
                        print("BackgroundDownloadDelegate: Auto-selected and reloaded model: \(filename)")
                    }
                }
            }
        } catch {
            print("BackgroundDownloadDelegate: Failed to save \(filename): \(error)")
            DispatchQueue.main.async {
                if isCoreML {
                    manager.currentCoreMLDownload = nil
                } else {
                    manager.downloadContinuations[filename]?.resume(throwing: error)
                    manager.downloadContinuations.removeValue(forKey: filename)
                    manager.downloadProgressCallbacks.removeValue(forKey: filename)
                    manager.currentDownload = nil
                }
            }
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let manager = manager, let filename = downloadTask.taskDescription else { return }

        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        let isCoreML = filename.hasSuffix(".zip")

        DispatchQueue.main.async {
            if isCoreML {
                manager.currentCoreMLDownload = ActiveDownload(filename: filename, progress: progress)
            } else {
                // GGML model - update state and call progress callback
                manager.currentDownload = ActiveDownload(filename: filename, progress: progress)
                manager.downloadProgressCallbacks[filename]?(progress)
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error = error, let manager = manager, let filename = (task as? URLSessionDownloadTask)?.taskDescription else { return }

        let nsError = error as NSError
        let isCoreML = filename.hasSuffix(".zip")

        // Save resume data if available
        if let resumeData = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
            let download = ResumableDownload(
                id: UUID(),
                downloadURL: task.originalRequest?.url ?? URL(string: "https://huggingface.co")!,
                destinationFilename: filename,
                downloadType: isCoreML ? .coreML : .ggml,
                resumeData: resumeData,
                bytesDownloaded: task.countOfBytesReceived,
                totalBytes: task.countOfBytesExpectedToReceive,
                createdAt: Date()
            )
            try? manager.resumableStore.save(download)
            DispatchQueue.main.async {
                if let index = manager.resumableDownloads.firstIndex(where: { $0.destinationFilename == filename }) {
                    manager.resumableDownloads[index] = download
                } else {
                    manager.resumableDownloads.append(download)
                }
            }
        }

        DispatchQueue.main.async {
            if isCoreML {
                manager.currentCoreMLDownload = nil
            } else {
                // GGML model - call continuation with error
                manager.downloadContinuations[filename]?.resume(throwing: error)
                manager.downloadContinuations.removeValue(forKey: filename)
                manager.downloadProgressCallbacks.removeValue(forKey: filename)
                manager.currentDownload = nil
            }
        }

        print("BackgroundDownloadDelegate: Download failed for \(filename): \(error.localizedDescription)")
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async {
            self.manager?.backgroundCompletionHandler?()
            self.manager?.backgroundCompletionHandler = nil
        }
    }
}

// MARK: - Download Delegate

class WhisperDownloadDelegate: NSObject, URLSessionTaskDelegate, URLSessionDownloadDelegate {
    private let progressCallback: (Double) -> Void
    private var expectedContentLength: Int64 = 0
    private(set) var totalBytesWritten: Int64 = 0
    var completionHandler: ((URL?, Error?) -> Void)?
    var resumeDataHandler: ((Data?, Int64, Int64) -> Void)?  // (resumeData, bytesDownloaded, totalBytes)

    init(progressCallback: @escaping (Double) -> Void) {
        self.progressCallback = progressCallback
        super.init()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        completionHandler?(location, nil)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        self.totalBytesWritten = totalBytesWritten

        if expectedContentLength == 0 {
            expectedContentLength = totalBytesExpectedToWrite
        }
        let progress = Double(totalBytesWritten) / Double(expectedContentLength)

        DispatchQueue.main.async { [weak self] in
            self?.progressCallback(progress)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didResumeAtOffset fileOffset: Int64, expectedTotalBytes: Int64) {
        print("WhisperDownloadDelegate: Resumed at offset \(fileOffset) of \(expectedTotalBytes) bytes")
        self.totalBytesWritten = fileOffset
        self.expectedContentLength = expectedTotalBytes
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            // Extract resume data from error if available
            let nsError = error as NSError
            let resumeData = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
            resumeDataHandler?(resumeData, totalBytesWritten, expectedContentLength)
            completionHandler?(nil, error)
        }
    }
}

// MARK: - Active Download State

struct ActiveDownload: Equatable, Sendable {
    let filename: String
    var progress: Double
}

class WhisperModelManager: ObservableObject, @unchecked Sendable {
    static let shared = WhisperModelManager()

    private let modelsDirectoryName = "whisper-models"

    // MARK: - GGML Download State (single source of truth)
    @Published var currentDownload: ActiveDownload?  // nil if not downloading

    // MARK: - CoreML Download State (single source of truth)
    @Published var currentCoreMLDownload: ActiveDownload?  // nil if not downloading
    private var coreMLDownloadTask: URLSessionDownloadTask?
    private var coreMLDownloadSession: URLSession?

    // MARK: - Resumable Downloads
    @Published var resumableDownloads: [ResumableDownload] = []
    fileprivate let resumableStore = ResumableDownloadStore()
    private var activeDownloadTask: URLSessionDownloadTask?
    private var activeDownloadSession: URLSession?

    // Computed properties for backwards compatibility during refactor
    var isDownloading: Bool { currentDownload != nil }
    var currentDownloadFilename: String? { currentDownload?.filename }
    var isCoreMLDownloading: Bool { currentCoreMLDownload != nil }
    var coreMLDownloadProgress: Double { currentCoreMLDownload?.progress ?? 0 }

    // MARK: - Background Session (for crash resilience)
    private static let backgroundSessionIdentifier = "ru.starmel.OpenSuperWhisper.download"
    private var backgroundSession: URLSession?
    fileprivate var backgroundCompletionHandler: (() -> Void)?
    private var backgroundDownloadDelegate: BackgroundDownloadDelegate?

    // Store continuations for async downloads using background session
    fileprivate var downloadContinuations: [String: CheckedContinuation<Void, Error>] = [:]
    fileprivate var downloadProgressCallbacks: [String: (Double) -> Void] = [:]

    var modelsDirectory: URL {
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let modelsDirectory = applicationSupport.appendingPathComponent(Bundle.main.bundleIdentifier!).appendingPathComponent(modelsDirectoryName)
        return modelsDirectory
    }

    private init() {
        createModelsDirectoryIfNeeded()
        copyDefaultModelIfNeeded()
        loadResumableDownloads()
        setupBackgroundSession()
        observeAppTermination()
    }

    private func loadResumableDownloads() {
        resumableDownloads = resumableStore.loadAll()
        print("WhisperModelManager: Loaded \(resumableDownloads.count) resumable download(s)")
    }

    private func setupBackgroundSession() {
        let config = URLSessionConfiguration.background(withIdentifier: Self.backgroundSessionIdentifier)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true

        backgroundDownloadDelegate = BackgroundDownloadDelegate()
        backgroundDownloadDelegate?.manager = self
        backgroundSession = URLSession(configuration: config, delegate: backgroundDownloadDelegate, delegateQueue: .main)

        // Check for any ongoing downloads from previous session
        backgroundSession?.getTasksWithCompletionHandler { [weak self] _, _, downloadTasks in
            guard let self = self else { return }
            for task in downloadTasks {
                if let filename = task.taskDescription {
                    print("WhisperModelManager: Found ongoing background download: \(filename)")
                    let isCoreML = filename.hasSuffix(".zip")
                    let progress = task.countOfBytesExpectedToReceive > 0
                        ? Double(task.countOfBytesReceived) / Double(task.countOfBytesExpectedToReceive)
                        : 0.0
                    DispatchQueue.main.async {
                        if isCoreML {
                            self.currentCoreMLDownload = ActiveDownload(filename: filename, progress: progress)
                        } else {
                            self.currentDownload = ActiveDownload(filename: filename, progress: progress)
                        }
                    }
                }
            }
        }
    }

    /// Call this from AppDelegate when app is launched by background session
    func handleBackgroundSessionCompletion(_ completionHandler: @escaping () -> Void) {
        backgroundCompletionHandler = completionHandler
    }

    private func observeAppTermination() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.saveActiveDownloadsBeforeTermination()
        }
    }

    /// Save resume data for any active downloads before app terminates
    private func saveActiveDownloadsBeforeTermination() {
        // Save CoreML download if active
        if let coreMLDownload = currentCoreMLDownload, let task = coreMLDownloadTask {
            print("WhisperModelManager: Saving CoreML download state before termination...")
            task.cancel { [weak self] resumeData in
                guard let self = self, let resumeData = resumeData else { return }
                let download = ResumableDownload(
                    id: UUID(),
                    downloadURL: task.originalRequest?.url ?? URL(string: "https://huggingface.co")!,
                    destinationFilename: coreMLDownload.filename,
                    downloadType: .coreML,
                    resumeData: resumeData,
                    bytesDownloaded: task.countOfBytesReceived,
                    totalBytes: task.countOfBytesExpectedToReceive,
                    createdAt: Date()
                )
                try? self.resumableStore.save(download)
                print("WhisperModelManager: Saved CoreML resume data (\(task.countOfBytesReceived) bytes)")
            }
        }

        // Save GGML download if active
        if let ggmlDownload = currentDownload, let task = activeDownloadTask {
            print("WhisperModelManager: Saving GGML download state before termination...")
            task.cancel { [weak self] resumeData in
                guard let self = self, let resumeData = resumeData else { return }
                let download = ResumableDownload(
                    id: UUID(),
                    downloadURL: task.originalRequest?.url ?? URL(string: "https://huggingface.co")!,
                    destinationFilename: ggmlDownload.filename,
                    downloadType: .ggml,
                    resumeData: resumeData,
                    bytesDownloaded: task.countOfBytesReceived,
                    totalBytes: task.countOfBytesExpectedToReceive,
                    createdAt: Date()
                )
                try? self.resumableStore.save(download)
                print("WhisperModelManager: Saved GGML resume data (\(task.countOfBytesReceived) bytes)")
            }
        }
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

    // MARK: - Resumable Download Helpers

    /// Check if a model has a resumable download available
    func hasResumableDownload(for filename: String) -> Bool {
        return resumableDownloads.contains { $0.destinationFilename == filename }
    }

    /// Get resumable download info for a model
    func getResumableDownload(for filename: String) -> ResumableDownload? {
        return resumableDownloads.first { $0.destinationFilename == filename }
    }

    /// Cancel download and delete resume data (start fresh)
    func cancelDownload(for filename: String) {
        // Cancel active download if it matches
        if currentDownload?.filename == filename {
            activeDownloadTask?.cancel()
            activeDownloadTask = nil
            activeDownloadSession?.invalidateAndCancel()
            activeDownloadSession = nil
            DispatchQueue.main.async {
                self.currentDownload = nil
            }
        }

        // Delete resume data
        resumableStore.delete(for: filename)
        DispatchQueue.main.async {
            self.resumableDownloads.removeAll { $0.destinationFilename == filename }
        }
        print("WhisperModelManager: Cancelled download for \(filename)")
    }

    // Download model with progress callback using background session (crash-resilient, supports resume)
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

        // Check for existing resume data
        let existingResume = getResumableDownload(for: name)

        print("Starting model download (background session):")
        print("- URL: \(url.absoluteString)")
        print("- Destination: \(destinationURL.path)")
        if existingResume != nil {
            print("- Resuming from \(Int(existingResume!.progress * 100))%")
        }

        // Track download state
        await MainActor.run {
            self.currentDownload = ActiveDownload(filename: name, progress: existingResume?.progress ?? 0)
        }

        // Use background session for crash resilience
        guard let session = backgroundSession else {
            print("Background session not available, falling back to regular session")
            try await downloadModelWithRegularSession(url: url, name: name, progressCallback: progressCallback, existingResume: existingResume)
            return
        }

        return try await withCheckedThrowingContinuation { [weak self] continuation in
            guard let self = self else {
                continuation.resume(throwing: NSError(domain: "WhisperModelManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Manager deallocated"]))
                return
            }

            // Store continuation and callback for background delegate
            self.downloadContinuations[name] = continuation
            self.downloadProgressCallbacks[name] = progressCallback

            // Create download task - resume if we have data, otherwise start fresh
            let downloadTask: URLSessionDownloadTask
            if let resumeData = existingResume?.resumeData {
                print("Resuming download with stored resume data...")
                downloadTask = session.downloadTask(withResumeData: resumeData)
            } else {
                print("Initiating fresh download...")
                downloadTask = session.downloadTask(with: url)
            }

            // Store filename in task description for identification
            downloadTask.taskDescription = name
            self.activeDownloadTask = downloadTask
            downloadTask.resume()
        }
    }

    /// Fallback to regular session if background session unavailable
    private func downloadModelWithRegularSession(url: URL, name: String, progressCallback: @escaping (Double) -> Void, existingResume: ResumableDownload?) async throws {
        let destinationURL = modelsDirectory.appendingPathComponent(name)

        return try await withCheckedThrowingContinuation { [weak self] continuation in
            guard let self = self else {
                continuation.resume(throwing: NSError(domain: "WhisperModelManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Manager deallocated"]))
                return
            }

            let delegate = WhisperDownloadDelegate(progressCallback: progressCallback)
            let configuration = URLSessionConfiguration.default
            configuration.waitsForConnectivity = true
            configuration.timeoutIntervalForResource = 600

            let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: .main)
            self.activeDownloadSession = session

            let downloadTask: URLSessionDownloadTask
            if let resumeData = existingResume?.resumeData {
                downloadTask = session.downloadTask(withResumeData: resumeData)
            } else {
                downloadTask = session.downloadTask(with: url)
            }
            self.activeDownloadTask = downloadTask

            delegate.resumeDataHandler = { [weak self] resumeData, bytesDownloaded, totalBytes in
                guard let self = self, let resumeData = resumeData else { return }
                let download = ResumableDownload(
                    id: existingResume?.id ?? UUID(),
                    downloadURL: url,
                    destinationFilename: name,
                    downloadType: .ggml,
                    resumeData: resumeData,
                    bytesDownloaded: bytesDownloaded,
                    totalBytes: totalBytes,
                    createdAt: existingResume?.createdAt ?? Date()
                )
                try? self.resumableStore.save(download)
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    if let index = self.resumableDownloads.firstIndex(where: { $0.destinationFilename == name }) {
                        self.resumableDownloads[index] = download
                    } else {
                        self.resumableDownloads.append(download)
                    }
                }
            }

            delegate.completionHandler = { [weak self] location, error in
                guard let self = self else { return }
                DispatchQueue.main.async { [weak self] in
                    self?.currentDownload = nil
                    self?.activeDownloadTask = nil
                    self?.activeDownloadSession = nil
                }
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let location = location else {
                    continuation.resume(throwing: NSError(domain: "WhisperModelManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "No download URL received"]))
                    return
                }
                do {
                    try FileManager.default.moveItem(at: location, to: destinationURL)
                    self.resumableStore.delete(for: name)
                    DispatchQueue.main.async { [weak self] in
                        self?.resumableDownloads.removeAll { $0.destinationFilename == name }
                        progressCallback(1.0)
                    }
                    continuation.resume(returning: ())
                } catch {
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
    fileprivate func unzipFile(at sourceURL: URL, to destinationURL: URL) throws {
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

    /// Get CoreML resume filename for a GGML model
    private func coreMLResumeFilename(for ggmlModelName: String) -> String {
        return ggmlModelName.replacingOccurrences(of: ".bin", with: "-encoder.mlmodelc.zip")
    }

    /// Check if CoreML has a resumable download
    func hasCoreMLResumableDownload(for ggmlModelName: String) -> Bool {
        let filename = coreMLResumeFilename(for: ggmlModelName)
        return hasResumableDownload(for: filename)
    }

    /// Get CoreML resumable download info
    func getCoreMLResumableDownload(for ggmlModelName: String) -> ResumableDownload? {
        let filename = coreMLResumeFilename(for: ggmlModelName)
        return getResumableDownload(for: filename)
    }

    /// Download CoreML model in background (non-blocking, crash-resilient, supports resume)
    func downloadCoreMLInBackground(from coreMLURL: URL, for ggmlModelName: String) {
        guard currentCoreMLDownload == nil else {
            print("CoreML download already in progress")
            return
        }

        // Check if already downloaded
        if hasCoreMLModel(for: ggmlModelName) {
            print("CoreML model already exists for \(ggmlModelName)")
            return
        }

        let zipFilename = coreMLResumeFilename(for: ggmlModelName)
        let existingResume = getResumableDownload(for: zipFilename)

        print("Starting CoreML download (background session):")
        print("- URL: \(coreMLURL.absoluteString)")
        print("- For model: \(ggmlModelName)")
        if existingResume != nil {
            print("- Resuming from \(Int(existingResume!.progress * 100))%")
        }

        DispatchQueue.main.async {
            self.currentCoreMLDownload = ActiveDownload(filename: zipFilename, progress: existingResume?.progress ?? 0)
        }

        guard let session = backgroundSession else {
            print("Background session not available, falling back to regular session")
            downloadCoreMLWithRegularSession(from: coreMLURL, for: ggmlModelName, zipFilename: zipFilename, existingResume: existingResume)
            return
        }

        // Create download task - resume if we have data, otherwise start fresh
        let task: URLSessionDownloadTask
        if let resumeData = existingResume?.resumeData {
            print("Resuming CoreML download with stored resume data...")
            task = session.downloadTask(withResumeData: resumeData)
        } else {
            print("Initiating fresh CoreML download...")
            task = session.downloadTask(with: coreMLURL)
        }

        // Store filename in task description for identification
        task.taskDescription = zipFilename
        coreMLDownloadTask = task
        task.resume()
    }

    /// Fallback to regular session if background session unavailable
    private func downloadCoreMLWithRegularSession(from coreMLURL: URL, for ggmlModelName: String, zipFilename: String, existingResume: ResumableDownload?) {
        let delegate = WhisperDownloadDelegate { [weak self] progress in
            DispatchQueue.main.async {
                self?.currentCoreMLDownload = ActiveDownload(filename: zipFilename, progress: progress)
            }
        }

        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForResource = 1800

        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: .main)
        coreMLDownloadSession = session

        let task: URLSessionDownloadTask
        if let resumeData = existingResume?.resumeData {
            task = session.downloadTask(withResumeData: resumeData)
        } else {
            task = session.downloadTask(with: coreMLURL)
        }

        delegate.resumeDataHandler = { [weak self] resumeData, bytesDownloaded, totalBytes in
            guard let self = self, let resumeData = resumeData else { return }
            let download = ResumableDownload(
                id: existingResume?.id ?? UUID(),
                downloadURL: coreMLURL,
                destinationFilename: zipFilename,
                downloadType: .coreML,
                resumeData: resumeData,
                bytesDownloaded: bytesDownloaded,
                totalBytes: totalBytes,
                createdAt: existingResume?.createdAt ?? Date()
            )
            try? self.resumableStore.save(download)
            DispatchQueue.main.async {
                if let index = self.resumableDownloads.firstIndex(where: { $0.destinationFilename == zipFilename }) {
                    self.resumableDownloads[index] = download
                } else {
                    self.resumableDownloads.append(download)
                }
            }
        }

        delegate.completionHandler = { [weak self] tempURL, error in
            guard let self = self else { return }
            defer {
                DispatchQueue.main.async {
                    self.currentCoreMLDownload = nil
                    self.coreMLDownloadTask = nil
                    self.coreMLDownloadSession = nil
                }
            }
            guard let tempURL = tempURL, error == nil else {
                print("CoreML download failed: \(error?.localizedDescription ?? "unknown")")
                return
            }
            let zipPath = self.modelsDirectory.appendingPathComponent(zipFilename)
            do {
                if FileManager.default.fileExists(atPath: zipPath.path) {
                    try FileManager.default.removeItem(at: zipPath)
                }
                try FileManager.default.moveItem(at: tempURL, to: zipPath)
                try self.unzipFile(at: zipPath, to: self.modelsDirectory)
                print("CoreML model installed successfully for \(ggmlModelName)")
                self.resumableStore.delete(for: zipFilename)
                DispatchQueue.main.async {
                    self.resumableDownloads.removeAll { $0.destinationFilename == zipFilename }
                }
            } catch {
                print("CoreML install failed: \(error)")
            }
        }

        coreMLDownloadTask = task
        task.resume()
    }

    /// Cancel CoreML download and optionally delete resume data
    func cancelCoreMLDownload(deleteResumeData: Bool = false) {
        let filename = currentCoreMLDownload?.filename

        coreMLDownloadTask?.cancel()
        coreMLDownloadTask = nil
        coreMLDownloadSession?.invalidateAndCancel()
        coreMLDownloadSession = nil

        if deleteResumeData, let filename = filename {
            resumableStore.delete(for: filename)
            DispatchQueue.main.async {
                self.resumableDownloads.removeAll { $0.destinationFilename == filename }
            }
        }

        DispatchQueue.main.async {
            self.currentCoreMLDownload = nil
        }
        print("CoreML download cancelled (resume data deleted: \(deleteResumeData))")
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
