import Foundation

// MARK: - Debug Bundle Types

/// Metrics from DiffGuard analysis for debugging
struct DiffMetrics: Codable, Sendable {
    let wordChangeRatio: Double
    let charInsertionRatio: Double
    let glossaryEnforced: Bool
    let passed: Bool

    init(
        wordChangeRatio: Double = 0.0,
        charInsertionRatio: Double = 0.0,
        glossaryEnforced: Bool = true,
        passed: Bool = true
    ) {
        self.wordChangeRatio = wordChangeRatio
        self.charInsertionRatio = charInsertionRatio
        self.glossaryEnforced = glossaryEnforced
        self.passed = passed
    }

    /// Create from SafetySummary
    init(from safety: SafetySummary) {
        self.wordChangeRatio = safety.wordChangeRatio
        self.charInsertionRatio = safety.charInsertionRatio
        self.glossaryEnforced = safety.glossaryEnforced
        self.passed = safety.passed
    }
}

/// Debug bundle capturing a single editor operation for local debugging
struct EditorDebugBundle: Codable, Sendable {
    let id: UUID
    let timestamp: Date
    let inputRaw: String
    let inputMode: String
    let outputEdited: String?
    let outputError: String?
    let diffMetrics: DiffMetrics?
    let latencyMs: Int
    let modelUsed: String?
    let fallbackTriggered: Bool

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        inputRaw: String,
        inputMode: String,
        outputEdited: String? = nil,
        outputError: String? = nil,
        diffMetrics: DiffMetrics? = nil,
        latencyMs: Int,
        modelUsed: String? = nil,
        fallbackTriggered: Bool = false
    ) {
        self.id = id
        self.timestamp = timestamp
        self.inputRaw = inputRaw
        self.inputMode = inputMode
        self.outputEdited = outputEdited
        self.outputError = outputError
        self.diffMetrics = diffMetrics
        self.latencyMs = latencyMs
        self.modelUsed = modelUsed
        self.fallbackTriggered = fallbackTriggered
    }
}

// MARK: - Editor Debug Manager

/// Manages local debug bundles for LLM Editor operations.
/// Stores bundles as JSON files for debugging and analysis.
/// All data stays local - no network calls.
final class EditorDebugManager {

    // MARK: - Singleton

    static let shared = EditorDebugManager()

    // MARK: - Properties

    private let fileManager = FileManager.default
    private let debugDirectoryName = "editor-debug"
    private let bundleRetentionDays = 7

    private lazy var debugDirectory: URL = {
        let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let bundleId = Bundle.main.bundleIdentifier ?? "OpenSuperWhisper"
        return applicationSupport
            .appendingPathComponent(bundleId)
            .appendingPathComponent(debugDirectoryName)
    }()

    private let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
        return formatter
    }()

    private let fileDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    // MARK: - Initialization

    private init() {
        ensureDebugDirectoryExists()
        cleanupOldBundles()
    }

    // MARK: - Public API

    /// Log an editor debug bundle to local storage
    func log(_ bundle: EditorDebugBundle) {
        guard AppPreferences.shared.editorDebugEnabled else { return }

        do {
            ensureDebugDirectoryExists()
            let filename = "\(fileDateFormatter.string(from: bundle.timestamp))-\(bundle.id.uuidString.prefix(8)).json"
            let fileURL = debugDirectory.appendingPathComponent(filename)
            let data = try encoder.encode(bundle)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            print("[EditorDebugManager] Failed to save debug bundle: \(error.localizedDescription)")
        }
    }

    /// Static convenience method for logging editor operations
    static func log(
        input: String,
        mode: String,
        output: String? = nil,
        error: String? = nil,
        metrics: DiffMetrics? = nil,
        latency: Int,
        model: String? = nil,
        fallback: Bool = false
    ) {
        let bundle = EditorDebugBundle(
            inputRaw: input,
            inputMode: mode,
            outputEdited: output,
            outputError: error,
            diffMetrics: metrics,
            latencyMs: latency,
            modelUsed: model,
            fallbackTriggered: fallback
        )
        shared.log(bundle)
    }

    /// Retrieve recent debug bundles, sorted by timestamp (newest first)
    func recentBundles(limit: Int = 50) -> [EditorDebugBundle] {
        guard AppPreferences.shared.editorDebugEnabled else { return [] }

        do {
            let files = try fileManager.contentsOfDirectory(at: debugDirectory, includingPropertiesForKeys: [.creationDateKey])
                .filter { $0.pathExtension == "json" }
                .sorted { url1, url2 in
                    let date1 = (try? url1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                    let date2 = (try? url2.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                    return date1 > date2
                }
                .prefix(limit)

            var bundles: [EditorDebugBundle] = []
            for fileURL in files {
                if let data = try? Data(contentsOf: fileURL),
                   let bundle = try? decoder.decode(EditorDebugBundle.self, from: data) {
                    bundles.append(bundle)
                }
            }
            return bundles
        } catch {
            print("[EditorDebugManager] Failed to list debug bundles: \(error.localizedDescription)")
            return []
        }
    }

    /// Clear all debug data
    func clearAllBundles() {
        do {
            if fileManager.fileExists(atPath: debugDirectory.path) {
                try fileManager.removeItem(at: debugDirectory)
            }
            ensureDebugDirectoryExists()
        } catch {
            print("[EditorDebugManager] Failed to clear debug bundles: \(error.localizedDescription)")
        }
    }

    /// Get the debug directory URL (for UI display)
    var debugDirectoryURL: URL {
        return debugDirectory
    }

    /// Get the count of stored bundles
    var bundleCount: Int {
        do {
            let files = try fileManager.contentsOfDirectory(at: debugDirectory, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "json" }
            return files.count
        } catch {
            return 0
        }
    }

    // MARK: - Private Methods

    private func ensureDebugDirectoryExists() {
        if !fileManager.fileExists(atPath: debugDirectory.path) {
            do {
                try fileManager.createDirectory(at: debugDirectory, withIntermediateDirectories: true)
            } catch {
                print("[EditorDebugManager] Failed to create debug directory: \(error.localizedDescription)")
            }
        }
    }

    private func cleanupOldBundles() {
        guard AppPreferences.shared.editorDebugEnabled else { return }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }

            let cutoffDate = Calendar.current.date(byAdding: .day, value: -self.bundleRetentionDays, to: Date()) ?? Date()

            do {
                let files = try self.fileManager.contentsOfDirectory(at: self.debugDirectory, includingPropertiesForKeys: [.creationDateKey])
                    .filter { $0.pathExtension == "json" }

                for fileURL in files {
                    if let creationDate = try? fileURL.resourceValues(forKeys: [.creationDateKey]).creationDate,
                       creationDate < cutoffDate {
                        try? self.fileManager.removeItem(at: fileURL)
                    }
                }
            } catch {
                print("[EditorDebugManager] Cleanup failed: \(error.localizedDescription)")
            }
        }
    }
}
