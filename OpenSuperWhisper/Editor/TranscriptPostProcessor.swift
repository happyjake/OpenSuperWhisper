import Foundation

/// Deterministic post-processor for transcription text
/// Used as fallback when LLM editing fails
struct TranscriptPostProcessor: Sendable {

    /// Process raw transcription with deterministic rules
    /// - Parameters:
    ///   - text: Raw transcription text
    ///   - glossary: Dictionary terms to enforce
    ///   - mode: Output mode (affects processing)
    /// - Returns: Processed text
    static func process(
        text: String,
        glossary: [DictionaryTerm] = [],
        mode: OutputMode = .clean
    ) -> String {
        var result = text

        // Step 1: Normalize whitespace
        result = normalizeWhitespace(result)

        // Step 2: Apply dictionary terms
        result = applyGlossary(result, glossary: glossary)

        // Step 3: Basic punctuation cleanup
        result = cleanupPunctuation(result)

        // Step 4: Capitalize sentences
        result = capitalizeSentences(result)

        // Step 5: Mode-specific processing
        switch mode {
        case .notes:
            result = convertToBasicBullets(result)
        case .verbatim:
            // Minimal processing for verbatim
            break
        default:
            // Clean/Email/Slack get standard processing
            break
        }

        return result
    }

    // MARK: - Processing Steps

    /// Normalize whitespace: collapse multiple spaces, trim, fix line breaks
    private static func normalizeWhitespace(_ text: String) -> String {
        var result = text

        // Replace multiple spaces with single space
        while result.contains("  ") {
            result = result.replacingOccurrences(of: "  ", with: " ")
        }

        // Normalize line breaks
        result = result.replacingOccurrences(of: "\r\n", with: "\n")
        result = result.replacingOccurrences(of: "\r", with: "\n")

        // Collapse multiple newlines
        while result.contains("\n\n\n") {
            result = result.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Apply glossary terms - replace aliases with canonical terms
    private static func applyGlossary(_ text: String, glossary: [DictionaryTerm]) -> String {
        var result = text

        for term in glossary {
            // Replace aliases with the canonical term
            for alias in term.aliases {
                if term.caseSensitive {
                    result = result.replacingOccurrences(of: alias, with: term.term)
                } else {
                    result = replaceIgnoringCase(result, target: alias, replacement: term.term)
                }
            }
        }

        return result
    }

    /// Replace string ignoring case
    private static func replaceIgnoringCase(_ text: String, target: String, replacement: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: NSRegularExpression.escapedPattern(for: target),
            options: .caseInsensitive
        ) else {
            return text
        }

        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: replacement)
    }

    /// Basic punctuation cleanup
    private static func cleanupPunctuation(_ text: String) -> String {
        var result = text

        // Remove space before punctuation
        result = result.replacingOccurrences(of: " .", with: ".")
        result = result.replacingOccurrences(of: " ,", with: ",")
        result = result.replacingOccurrences(of: " !", with: "!")
        result = result.replacingOccurrences(of: " ?", with: "?")
        result = result.replacingOccurrences(of: " :", with: ":")
        result = result.replacingOccurrences(of: " ;", with: ";")

        // Add space after punctuation if missing
        let punctuationPattern = "([.!?,:;])([A-Za-z])"
        if let regex = try? NSRegularExpression(pattern: punctuationPattern) {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "$1 $2")
        }

        // Fix multiple punctuation
        result = result.replacingOccurrences(of: "..", with: ".")
        result = result.replacingOccurrences(of: ",,", with: ",")
        result = result.replacingOccurrences(of: "!!", with: "!")
        result = result.replacingOccurrences(of: "??", with: "?")

        return result
    }

    /// Capitalize first letter of sentences
    private static func capitalizeSentences(_ text: String) -> String {
        var result = ""
        var capitalizeNext = true

        for char in text {
            if capitalizeNext && char.isLetter {
                result.append(char.uppercased())
                capitalizeNext = false
            } else {
                result.append(char)
            }

            // Next character after sentence-ending punctuation should be capitalized
            if char == "." || char == "!" || char == "?" {
                capitalizeNext = true
            }
        }

        return result
    }

    /// Convert text to basic bullet points (sentence-based)
    private static func convertToBasicBullets(_ text: String) -> String {
        // Split into sentences
        let sentences = splitIntoSentences(text)

        // Filter out very short sentences (likely fragments)
        let meaningful = sentences.filter { $0.count > 10 }

        if meaningful.isEmpty {
            // If no meaningful sentences, return original with minimal formatting
            return "- " + text
        }

        // Convert to bullets
        return meaningful.map { "- \($0)" }.joined(separator: "\n")
    }

    /// Split text into sentences
    private static func splitIntoSentences(_ text: String) -> [String] {
        var sentences: [String] = []
        var current = ""

        for char in text {
            current.append(char)

            if char == "." || char == "!" || char == "?" {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    sentences.append(trimmed)
                }
                current = ""
            }
        }

        // Don't forget trailing text without punctuation
        let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            sentences.append(trimmed)
        }

        return sentences
    }
}
