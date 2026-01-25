import Foundation

/// Constraints for DiffGuard safety checks
struct EditorConstraints: Sendable {
    /// Maximum allowed word change ratio (0.0+)
    let maxWordChangeRatio: Double

    /// Maximum allowed character insertion ratio (0.0-1.0)
    let maxCharInsertionRatio: Double

    /// Whether to enforce glossary terms in output
    let enforceGlossary: Bool

    /// Whether to preserve numbers exactly
    let preserveNumbers: Bool

    /// Whether to preserve proper nouns
    let preserveProperNouns: Bool

    init(
        maxWordChangeRatio: Double = 0.15,
        maxCharInsertionRatio: Double = 0.15,
        enforceGlossary: Bool = true,
        preserveNumbers: Bool = true,
        preserveProperNouns: Bool = true
    ) {
        self.maxWordChangeRatio = maxWordChangeRatio
        self.maxCharInsertionRatio = maxCharInsertionRatio
        self.enforceGlossary = enforceGlossary
        self.preserveNumbers = preserveNumbers
        self.preserveProperNouns = preserveProperNouns
    }

    /// Verbatim mode: minimal changes (5% threshold)
    static let verbatim = EditorConstraints(
        maxWordChangeRatio: 0.05,
        maxCharInsertionRatio: 0.05,
        enforceGlossary: true,
        preserveNumbers: true,
        preserveProperNouns: true
    )

    /// Clean mode: moderate changes (40% word change to allow grammar fixes + dictionary substitutions)
    static let clean = EditorConstraints(
        maxWordChangeRatio: 0.40,
        maxCharInsertionRatio: 0.20,
        enforceGlossary: true,
        preserveNumbers: true,
        preserveProperNouns: true
    )

    /// Notes mode: transformative changes (35% char insertion)
    /// Word changes are higher because we convert prose to bullets
    static let notes = EditorConstraints(
        maxWordChangeRatio: 0.50,
        maxCharInsertionRatio: 0.35,
        enforceGlossary: true,
        preserveNumbers: true,
        preserveProperNouns: false
    )

    /// Email/Slack mode: moderate-high changes
    static let transformative = EditorConstraints(
        maxWordChangeRatio: 0.40,
        maxCharInsertionRatio: 0.30,
        enforceGlossary: true,
        preserveNumbers: true,
        preserveProperNouns: false
    )

    /// Get appropriate constraints for an output mode
    static func forMode(_ mode: OutputMode) -> EditorConstraints {
        switch mode {
        case .verbatim:
            return .verbatim
        case .clean:
            return .clean
        case .notes:
            return .notes
        case .email, .slack:
            return .transformative
        }
    }
}

/// DiffGuard analyzer for safety checks
struct DiffGuard: Sendable {
    let constraints: EditorConstraints

    init(constraints: EditorConstraints = .clean) {
        self.constraints = constraints
    }

    /// Analyze the difference between original and edited text
    func analyze(original: String, edited: String, glossary: [DictionaryTerm]) -> SafetySummary {
        let originalWords = tokenize(original)
        let editedWords = tokenize(edited)

        // Calculate word change ratio
        let wordChangeRatio = calculateWordChangeRatio(original: originalWords, edited: editedWords)

        // Calculate character insertion ratio
        let charInsertionRatio = calculateCharInsertionRatio(original: original, edited: edited)

        // Check glossary enforcement
        let glossaryEnforced = checkGlossaryEnforcement(
            original: original, edited: edited, glossary: glossary)

        // Determine if safety checks passed
        let passed =
            wordChangeRatio <= constraints.maxWordChangeRatio
            && charInsertionRatio <= constraints.maxCharInsertionRatio
            && (!constraints.enforceGlossary || glossaryEnforced)

        return SafetySummary(
            wordChangeRatio: wordChangeRatio,
            charInsertionRatio: charInsertionRatio,
            glossaryEnforced: glossaryEnforced,
            passed: passed,
            fallbackTriggered: false
        )
    }

    private func tokenize(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
    }

    private func calculateWordChangeRatio(original: [String], edited: [String]) -> Double {
        guard !original.isEmpty else { return 0.0 }

        let originalSet = Set(original)
        let editedSet = Set(edited)

        let added = editedSet.subtracting(originalSet).count
        let removed = originalSet.subtracting(editedSet).count
        let changes = added + removed

        return Double(changes) / Double(original.count)
    }

    private func calculateCharInsertionRatio(original: String, edited: String) -> Double {
        guard !original.isEmpty else { return 0.0 }

        let originalCount = original.filter { !$0.isWhitespace }.count
        let editedCount = edited.filter { !$0.isWhitespace }.count

        let inserted = max(0, editedCount - originalCount)
        return Double(inserted) / Double(originalCount)
    }

    private func checkGlossaryEnforcement(
        original: String, edited: String, glossary: [DictionaryTerm]
    ) -> Bool {
        guard !glossary.isEmpty else { return true }

        let originalLower = original.lowercased()
        let editedLower = edited.lowercased()

        for term in glossary {
            let searchOriginal = term.caseSensitive ? original : originalLower
            let searchEdited = term.caseSensitive ? edited : editedLower
            let searchTerm = term.caseSensitive ? term.term : term.term.lowercased()

            // If the term was in the original, it must be in the edited
            if searchOriginal.contains(searchTerm) && !searchEdited.contains(searchTerm) {
                return false  // Glossary term was removed - enforcement failed
            }
        }

        return true
    }
}
