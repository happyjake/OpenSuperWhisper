import Foundation

/// Errors that can occur during dictionary operations
enum DictionaryError: LocalizedError {
    case loadFailed(String)
    case saveFailed(String)
    case duplicateTerm(String)
    case termNotFound(UUID)
    case importFailed(String)
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .loadFailed(let reason): return "Failed to load dictionary: \(reason)"
        case .saveFailed(let reason): return "Failed to save dictionary: \(reason)"
        case .duplicateTerm(let term): return "Term '\(term)' already exists"
        case .termNotFound(let id): return "Term not found: \(id)"
        case .importFailed(let reason): return "Failed to import: \(reason)"
        case .exportFailed(let reason): return "Failed to export: \(reason)"
        }
    }
}

/// Notification for dictionary corruption events
extension Notification.Name {
    static let dictionaryCorruptionDetected = Notification.Name("dictionaryCorruptionDetected")
}

/// Manages persistence and CRUD operations for user dictionary
@MainActor
class DictionaryManager: ObservableObject {
    static let shared = DictionaryManager()

    // MARK: - Published State
    @Published private(set) var dictionary: UserDictionary
    @Published private(set) var isLoading = false
    @Published private(set) var lastError: DictionaryError?

    // MARK: - Storage
    private let fileManager = FileManager.default

    /// Directory: ~/Library/Application Support/[BundleID]/dictionaries/
    var dictionariesDirectory: URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let bundleId = Bundle.main.bundleIdentifier ?? "OpenSuperWhisper"
        let appDir = appSupport.appendingPathComponent(bundleId)
        return appDir.appendingPathComponent("dictionaries")
    }

    /// Primary dictionary file
    private var dictionaryURL: URL {
        dictionariesDirectory.appendingPathComponent("default.json")
    }

    // MARK: - Initialization
    private init() {
        self.dictionary = UserDictionary()
        Task {
            await loadDictionary()
        }
    }

    // MARK: - Public API

    /// Load dictionary from disk
    func loadDictionary() async {
        isLoading = true
        defer { isLoading = false }

        do {
            // Ensure directory exists
            try fileManager.createDirectory(at: dictionariesDirectory, withIntermediateDirectories: true)

            guard fileManager.fileExists(atPath: dictionaryURL.path) else {
                dictionary = UserDictionary()
                return
            }

            let data = try Data(contentsOf: dictionaryURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            dictionary = try decoder.decode(UserDictionary.self, from: data)

            // Handle version migration if needed
            if dictionary.version < UserDictionary.currentVersion {
                dictionary = migrate(dictionary, from: dictionary.version)
                try await saveDictionary()
            }

            lastError = nil
        } catch {
            print("Dictionary load error: \(error)")

            // Backup corrupted file
            let backupURL = dictionaryURL.deletingPathExtension()
                .appendingPathExtension("backup.\(Int(Date().timeIntervalSince1970)).json")
            try? fileManager.copyItem(at: dictionaryURL, to: backupURL)

            // Start fresh
            dictionary = UserDictionary()
            lastError = .loadFailed("Dictionary was corrupted and has been reset. Backup saved.")

            // Notify about corruption
            NotificationCenter.default.post(
                name: .dictionaryCorruptionDetected,
                object: nil,
                userInfo: ["backupPath": backupURL.path]
            )
        }
    }

    /// Save dictionary to disk
    func saveDictionary() async throws {
        do {
            try fileManager.createDirectory(at: dictionariesDirectory, withIntermediateDirectories: true)

            var updatedDictionary = dictionary
            updatedDictionary.updatedAt = Date()

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(updatedDictionary)
            try data.write(to: dictionaryURL, options: .atomic)

            dictionary = updatedDictionary
            lastError = nil
        } catch {
            lastError = .saveFailed(error.localizedDescription)
            throw DictionaryError.saveFailed(error.localizedDescription)
        }
    }

    /// Add a new term
    func addTerm(_ entry: DictionaryEntry) async throws {
        // Check for duplicates
        if dictionary.terms.contains(where: { $0.term.lowercased() == entry.term.lowercased() }) {
            throw DictionaryError.duplicateTerm(entry.term)
        }

        dictionary.terms.append(entry)
        try await saveDictionary()
    }

    /// Update an existing term
    func updateTerm(_ entry: DictionaryEntry) async throws {
        guard let index = dictionary.terms.firstIndex(where: { $0.id == entry.id }) else {
            throw DictionaryError.termNotFound(entry.id)
        }

        var updatedEntry = entry
        updatedEntry.updatedAt = Date()
        dictionary.terms[index] = updatedEntry
        try await saveDictionary()
    }

    /// Remove a term by ID
    func removeTerm(id: UUID) async throws {
        dictionary.terms.removeAll { $0.id == id }
        try await saveDictionary()
    }

    /// Export dictionary to a file URL
    func exportDictionary(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(dictionary)
        try data.write(to: url, options: .atomic)
    }

    /// Import dictionary from a file URL
    func importDictionary(from url: URL, replace: Bool = false) async throws {
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let imported = try decoder.decode(UserDictionary.self, from: data)

            if replace {
                dictionary = imported
            } else {
                // Merge: add non-duplicate terms
                for term in imported.terms {
                    if !dictionary.terms.contains(where: { $0.term.lowercased() == term.term.lowercased() }) {
                        dictionary.terms.append(term)
                    }
                }
            }

            try await saveDictionary()
        } catch let error as DecodingError {
            switch error {
            case .dataCorrupted(let context):
                throw DictionaryError.importFailed("Invalid JSON: \(context.debugDescription)")
            case .keyNotFound(let key, _):
                throw DictionaryError.importFailed("Missing required field: \(key.stringValue)")
            default:
                throw DictionaryError.importFailed(error.localizedDescription)
            }
        } catch {
            throw DictionaryError.importFailed(error.localizedDescription)
        }
    }

    /// Suggest terms from recent transcription text
    /// Finds capitalized multi-word phrases that might be proper nouns
    func suggestTerms(from text: String) -> [String] {
        // Find capitalized multi-word phrases that might be proper nouns
        let pattern = #"[A-Z][a-z]+(?:\s[A-Z][a-z]+)+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }

        let range = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, range: range)

        var suggestions: [String] = []
        for match in matches {
            if let swiftRange = Range(match.range, in: text) {
                let term = String(text[swiftRange])
                // Skip if already in dictionary
                if !dictionary.terms.contains(where: { $0.term.lowercased() == term.lowercased() }) {
                    suggestions.append(term)
                }
            }
        }

        return Array(Set(suggestions)).sorted()
    }

    // MARK: - Private Helpers

    private func migrate(_ dict: UserDictionary, from version: Int) -> UserDictionary {
        // Future: handle schema migrations
        // Currently at version 1, so no migrations needed yet
        var migrated = dict
        migrated.version = UserDictionary.currentVersion
        return migrated
    }
}
