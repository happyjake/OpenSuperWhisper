import Foundation

/// Builds initialPrompt strings that combine language prompts with glossary terms
struct GlossaryBuilder {

    /// Maximum approximate token count for initialPrompt
    /// Whisper uses ~224 token context window for prompts
    static let maxTokens = 224

    /// Approximate characters per token (conservative estimate for safety)
    /// Using ~4 chars per token as specified in task
    static let charsPerToken: Float = 4.0

    /// Build combined prompt with language context and glossary
    /// - Parameters:
    ///   - dictionary: The user dictionary containing terms
    ///   - languagePrompt: Base prompt for language (e.g., "I mean.")
    ///   - tokenLimit: Maximum tokens for the prompt (default: maxTokens)
    /// - Returns: Combined prompt string within token limits, or nil if no content
    static func buildPrompt(
        dictionary: UserDictionary,
        languagePrompt: String?,
        tokenLimit: Int = maxTokens
    ) -> String? {
        var parts: [String] = []
        var estimatedTokens: Float = 0

        // Add language prompt first (always include if present)
        if let langPrompt = languagePrompt, !langPrompt.isEmpty {
            parts.append(langPrompt)
            estimatedTokens += Float(langPrompt.count) / charsPerToken
        }

        // Calculate remaining budget for glossary
        let remainingTokens = Float(tokenLimit) - estimatedTokens - 10 // Buffer
        guard remainingTokens > 0 else {
            return parts.isEmpty ? nil : parts.joined(separator: " ")
        }

        let glossaryTerms = dictionary.topTerms(limit: 50) // Get more than we need, we'll trim
        guard !glossaryTerms.isEmpty else {
            return parts.isEmpty ? nil : parts.joined(separator: " ")
        }

        // Build glossary string with terms that fit
        var includedTerms: [String] = []
        let prefixChars: Float = 10.0 // "Glossary: " prefix
        var glossaryChars: Float = prefixChars

        for entry in glossaryTerms {
            // Account for term + ", " separator
            let termChars = Float(entry.term.count + 2)
            let termTokens = termChars / charsPerToken

            if (glossaryChars / charsPerToken) + termTokens <= remainingTokens {
                includedTerms.append(entry.term)
                glossaryChars += termChars
            } else {
                break
            }
        }

        if !includedTerms.isEmpty {
            let glossary = "Glossary: \(includedTerms.joined(separator: ", ")). "
            parts.insert(glossary, at: 0) // Glossary before language prompt per spec
        }

        return parts.isEmpty ? nil : parts.joined(separator: "")
    }

    /// Estimate the number of tokens for a given string
    /// - Parameter text: The text to estimate
    /// - Returns: Estimated token count
    static func estimateTokens(_ text: String) -> Int {
        Int(ceil(Float(text.count) / charsPerToken))
    }
}
