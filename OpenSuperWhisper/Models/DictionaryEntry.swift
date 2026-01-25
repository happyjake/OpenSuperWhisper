import Foundation

/// Categories for organizing dictionary terms
enum TermCategory: String, Codable, CaseIterable {
    case code = "code"          // API names, functions, classes
    case product = "product"    // Product names, features
    case person = "person"      // Names of people
    case company = "company"    // Company/organization names
    case acronym = "acronym"    // Abbreviations and acronyms
    case general = "general"    // Everything else

    var displayName: String {
        switch self {
        case .code: return "Code"
        case .product: return "Product"
        case .person: return "Person"
        case .company: return "Company"
        case .acronym: return "Acronym"
        case .general: return "General"
        }
    }

    var icon: String {
        switch self {
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .product: return "shippingbox"
        case .person: return "person"
        case .company: return "building.2"
        case .acronym: return "textformat.abc"
        case .general: return "tag"
        }
    }
}

/// A single dictionary term with aliases and metadata
struct DictionaryEntry: Codable, Identifiable, Hashable {
    let id: UUID
    var term: String                    // Canonical spelling: "ClockoSocket"
    var aliases: [String]               // Phonetic variants: ["clock o socket", "cloco socket"]
    var category: TermCategory          // Grouping for UI
    var caseSensitive: Bool             // Preserve exact casing on replacement
    var priority: Int                   // 1-5, higher = prefer for initialPrompt
    var notes: String?                  // User documentation
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        term: String,
        aliases: [String] = [],
        category: TermCategory = .general,
        caseSensitive: Bool = true,
        priority: Int = 3,
        notes: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.term = term
        self.aliases = aliases
        self.category = category
        self.caseSensitive = caseSensitive
        self.priority = priority
        self.notes = notes
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: DictionaryEntry, rhs: DictionaryEntry) -> Bool {
        lhs.id == rhs.id
    }
}
