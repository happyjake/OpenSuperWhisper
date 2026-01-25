import Foundation

/// Container for user's dictionary with version metadata
struct UserDictionary: Codable {
    static let currentVersion = 1

    var version: Int
    var terms: [DictionaryEntry]
    var createdAt: Date
    var updatedAt: Date

    init(terms: [DictionaryEntry] = []) {
        self.version = Self.currentVersion
        self.terms = terms
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    /// Terms sorted by priority (highest first), then alphabetically
    func sortedByPriority() -> [DictionaryEntry] {
        terms.sorted { lhs, rhs in
            if lhs.priority != rhs.priority {
                return lhs.priority > rhs.priority
            }
            return lhs.term.localizedCaseInsensitiveCompare(rhs.term) == .orderedAscending
        }
    }

    /// Top N terms by priority for initialPrompt
    func topTerms(limit: Int = 30) -> [DictionaryEntry] {
        Array(sortedByPriority().prefix(limit))
    }

    /// Find entries matching a search query
    func search(query: String) -> [DictionaryEntry] {
        guard !query.isEmpty else { return sortedByPriority() }
        let lowercasedQuery = query.lowercased()
        return terms.filter { entry in
            entry.term.lowercased().contains(lowercasedQuery) ||
            entry.aliases.contains { $0.lowercased().contains(lowercasedQuery) } ||
            (entry.notes?.lowercased().contains(lowercasedQuery) ?? false)
        }
    }
}
