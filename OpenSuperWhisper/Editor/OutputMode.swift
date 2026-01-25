import Foundation

/// Output mode for text editing - controls the style of edited output
enum OutputMode: String, Codable, Sendable, CaseIterable, Identifiable {
    case verbatim = "verbatim"
    case clean = "clean"
    case notes = "notes"
    case email = "email"
    case slack = "slack"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .verbatim: return "Verbatim"
        case .clean: return "Clean"
        case .notes: return "Notes"
        case .email: return "Email"
        case .slack: return "Slack"
        }
    }

    var description: String {
        switch self {
        case .verbatim:
            return "Exact transcription with minimal changes (punctuation only)"
        case .clean:
            return "Clean up grammar, remove fillers, fix punctuation"
        case .notes:
            return "Convert to bullet-point notes"
        case .email:
            return "Format as professional email"
        case .slack:
            return "Format for casual Slack message"
        }
    }

    var shortDescription: String {
        switch self {
        case .verbatim: return "Punctuation only"
        case .clean: return "Grammar & fillers"
        case .notes: return "Bullet points"
        case .email: return "Professional"
        case .slack: return "Casual"
        }
    }

    /// The system prompt modifier for this mode
    var promptModifier: String {
        switch self {
        case .verbatim:
            return "Output the text exactly as spoken, only adding punctuation and capitalization."
        case .clean:
            return "Clean up the text: fix grammar, remove filler words (um, uh, like), and improve punctuation. Preserve the speaker's meaning and tone."
        case .notes:
            return "Convert the text into concise bullet-point notes. Extract key points only. Output ONLY the bullet points, no preamble or introduction."
        case .email:
            return "Format as a professional email. Add appropriate greeting and sign-off if context suggests. Output ONLY the email content."
        case .slack:
            return "Format for a casual Slack message. Keep it conversational and concise. Output ONLY the message content."
        }
    }
}
