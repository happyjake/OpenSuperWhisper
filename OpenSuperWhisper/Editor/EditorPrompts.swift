import Foundation

/// Strict prompt templates for LLM editor with JSON contracts
enum EditorPrompts {

    // MARK: - Notes Mode

    static func notesSystemPrompt(glossary: [DictionaryTerm]) -> String {
        var prompt = """
            You are a transcription-to-notes converter. Convert speech-to-text output into bullet points.

            RULES:
            1. Output ONLY valid JSON, no markdown, no commentary
            2. Extract 1-8 key points as bullets
            3. Each bullet is a single concise sentence (max 160 chars)
            4. Remove filler words (um, uh, like, you know)
            5. Fix obvious transcription errors
            6. Preserve all numbers exactly
            7. Do NOT add information not in the original
            8. Do NOT start bullets with: "Here are", "Key points", "The speaker", "This transcription", "Based on"
            """

        if !glossary.isEmpty {
            let glossaryLines = glossary.map { term -> String in
                if term.aliases.isEmpty {
                    return "- \(term.term)"
                } else {
                    let aliasStr = term.aliases.joined(separator: ", ")
                    return "- \(term.term) (may be misheard as: \(aliasStr))"
                }
            }.joined(separator: "\n")
            prompt +=
                "\n\nDICTIONARY - Replace misheard words with correct terms:\n\(glossaryLines)"
        }

        prompt += """


            REQUIRED JSON OUTPUT FORMAT:
            {
              "bullets": ["point 1", "point 2", ...],
              "replacements": [{"from": "original", "to": "corrected"}],
              "uncertain_spans": [{"span": "unclear text", "reason": "why uncertain"}]
            }

            Output ONLY the JSON object. No other text.
            """

        return prompt
    }

    static let notesUserPromptTemplate = """
        Convert this transcription to bullet-point notes:

        ---
        %@
        ---

        Output JSON only.
        """

    // MARK: - Clean Mode

    static func cleanSystemPrompt(glossary: [DictionaryTerm]) -> String {
        var prompt = """
            You are a transcription editor. Clean up speech-to-text output.

            RULES:
            1. Output ONLY valid JSON, no markdown, no commentary
            2. Fix grammar and punctuation
            3. Remove filler words (um, uh, like, you know, I mean)
            4. Preserve the speaker's meaning and tone
            5. Preserve all numbers exactly
            6. Do NOT add information not in the original
            7. Do NOT significantly restructure sentences
            8. Do NOT substitute unclear words with guesses - keep the original word if unsure
            9. Do NOT replace product names, proper nouns, or technical terms with similar-sounding alternatives
            """

        if !glossary.isEmpty {
            // Build glossary with aliases for better recognition
            let glossaryLines = glossary.map { term -> String in
                if term.aliases.isEmpty {
                    return "- \(term.term)"
                } else {
                    let aliasStr = term.aliases.joined(separator: ", ")
                    return "- \(term.term) (may be misheard as: \(aliasStr))"
                }
            }.joined(separator: "\n")
            prompt +=
                "\n\nDICTIONARY - Replace misheard words with correct terms:\n\(glossaryLines)"
        }

        prompt += """


            REQUIRED JSON OUTPUT FORMAT:
            {
              "edited_text": "the cleaned transcription",
              "replacements": [{"from": "original", "to": "corrected"}],
              "uncertain_spans": [{"span": "unclear text", "reason": "why uncertain"}]
            }

            Output ONLY the JSON object. No other text.
            """

        return prompt
    }

    static let cleanUserPromptTemplate = """
        Clean up this transcription:

        ---
        %@
        ---

        Output JSON only.
        """

    // MARK: - Verbatim Mode

    static func verbatimSystemPrompt(glossary: [DictionaryTerm]) -> String {
        var prompt = """
            You are a transcription punctuator. Add punctuation and capitalization ONLY.

            RULES:
            1. Output ONLY valid JSON, no markdown, no commentary
            2. Add punctuation (periods, commas, question marks)
            3. Fix capitalization (sentence starts, proper nouns)
            4. Do NOT change any words
            5. Do NOT remove filler words
            6. Do NOT fix grammar
            7. Preserve everything exactly as spoken
            """

        if !glossary.isEmpty {
            let terms = glossary.map { $0.term }.joined(separator: ", ")
            prompt += "\n8. These terms may appear: \(terms)"
        }

        prompt += """


            REQUIRED JSON OUTPUT FORMAT:
            {
              "edited_text": "the punctuated transcription",
              "replacements": [{"from": "original", "to": "corrected"}]
            }

            Output ONLY the JSON object. No other text.
            """

        return prompt
    }

    static let verbatimUserPromptTemplate = """
        Add punctuation to this transcription:

        ---
        %@
        ---

        Output JSON only.
        """

    // MARK: - Email Mode

    static func emailSystemPrompt(glossary: [DictionaryTerm]) -> String {
        var prompt = """
            You are a transcription-to-email converter. Format speech as a professional email.

            RULES:
            1. Output ONLY valid JSON, no markdown, no commentary
            2. Format as a professional email
            3. Add greeting and sign-off if appropriate
            4. Fix grammar and remove filler words
            5. Preserve all numbers and key details exactly
            6. Do NOT add information not in the original
            7. Keep the sender's intent and tone
            """

        if !glossary.isEmpty {
            let terms = glossary.map { $0.term }.joined(separator: ", ")
            prompt += "\n8. Use these exact terms/spellings: \(terms)"
        }

        prompt += """


            REQUIRED JSON OUTPUT FORMAT:
            {
              "edited_text": "the formatted email",
              "replacements": [{"from": "original", "to": "corrected"}]
            }

            Output ONLY the JSON object. No other text.
            """

        return prompt
    }

    static let emailUserPromptTemplate = """
        Format this transcription as an email:

        ---
        %@
        ---

        Output JSON only.
        """

    // MARK: - Slack Mode

    static func slackSystemPrompt(glossary: [DictionaryTerm]) -> String {
        var prompt = """
            You are a transcription-to-Slack converter. Format speech as a casual Slack message.

            RULES:
            1. Output ONLY valid JSON, no markdown, no commentary
            2. Keep it conversational and concise
            3. Fix grammar and remove filler words
            4. Preserve all numbers and key details exactly
            5. Do NOT add information not in the original
            """

        if !glossary.isEmpty {
            let terms = glossary.map { $0.term }.joined(separator: ", ")
            prompt += "\n6. Use these exact terms/spellings: \(terms)"
        }

        prompt += """


            REQUIRED JSON OUTPUT FORMAT:
            {
              "edited_text": "the Slack message",
              "replacements": [{"from": "original", "to": "corrected"}]
            }

            Output ONLY the JSON object. No other text.
            """

        return prompt
    }

    static let slackUserPromptTemplate = """
        Format this transcription as a Slack message:

        ---
        %@
        ---

        Output JSON only.
        """

    // MARK: - Repair Prompt

    static let repairSystemPrompt = """
        You are a JSON repair assistant. The previous LLM output was invalid.
        Convert the malformed output to valid JSON matching the required schema.

        RULES:
        1. Output ONLY valid JSON
        2. Extract the actual content from the malformed output
        3. Match the required schema exactly
        4. Do NOT add commentary or explanation
        """

    static func repairUserPrompt(malformedOutput: String, requiredSchema: String) -> String {
        """
        The previous output was invalid:

        ---
        \(malformedOutput)
        ---

        Required schema:
        \(requiredSchema)

        Extract the content and output valid JSON only.
        """
    }

    // MARK: - Schema Definitions

    static let notesSchema = """
        {
          "bullets": ["string array of 1-8 bullet points"],
          "replacements": [{"from": "string", "to": "string"}],
          "uncertain_spans": [{"span": "string", "reason": "string"}]
        }
        """

    static let editedTextSchema = """
        {
          "edited_text": "string",
          "replacements": [{"from": "string", "to": "string"}],
          "uncertain_spans": [{"span": "string", "reason": "string"}]
        }
        """

    // MARK: - Helper Methods

    static func systemPrompt(for mode: OutputMode, glossary: [DictionaryTerm]) -> String {
        switch mode {
        case .notes:
            return notesSystemPrompt(glossary: glossary)
        case .clean:
            return cleanSystemPrompt(glossary: glossary)
        case .verbatim:
            return verbatimSystemPrompt(glossary: glossary)
        case .email:
            return emailSystemPrompt(glossary: glossary)
        case .slack:
            return slackSystemPrompt(glossary: glossary)
        }
    }

    static func userPrompt(for mode: OutputMode, text: String) -> String {
        let template: String
        switch mode {
        case .notes:
            template = notesUserPromptTemplate
        case .clean:
            template = cleanUserPromptTemplate
        case .verbatim:
            template = verbatimUserPromptTemplate
        case .email:
            template = emailUserPromptTemplate
        case .slack:
            template = slackUserPromptTemplate
        }
        return String(format: template, text)
    }

    static func schema(for mode: OutputMode) -> String {
        switch mode {
        case .notes:
            return notesSchema
        default:
            return editedTextSchema
        }
    }

    /// Temperature settings per mode (strict pass)
    static func temperature(for mode: OutputMode) -> Double {
        switch mode {
        case .verbatim:
            return 0.0
        case .clean:
            return 0.1
        case .notes:
            return 0.1
        case .email, .slack:
            return 0.2
        }
    }

    /// Max tokens per mode (strict pass)
    static func maxTokens(for mode: OutputMode) -> Int {
        switch mode {
        case .verbatim:
            return 512
        case .clean:
            return 768
        case .notes:
            return 384
        case .email:
            return 768
        case .slack:
            return 384
        }
    }
}
