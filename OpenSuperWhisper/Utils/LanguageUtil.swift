import Foundation
class LanguageUtil {

    static let availableLanguages = [
        "auto", "en", "zh", "de", "es", "ru", "ko", "fr", "ja", "pt", "tr", "pl", "ca", "nl", "ar",
        "sv", "it", "id", "hi", "fi",
    ]

    static let languageNames = [
        "auto": "Auto-detect",
        "en": "English",
        "zh": "Chinese",
        "de": "German",
        "es": "Spanish",
        "ru": "Russian",
        "ko": "Korean",
        "fr": "French",
        "ja": "Japanese",
        "pt": "Portuguese",
        "tr": "Turkish",
        "pl": "Polish",
        "ca": "Catalan",
        "nl": "Dutch",
        "ar": "Arabic",
        "sv": "Swedish",
        "it": "Italian",
        "id": "Indonesian",
        "hi": "Hindi",
        "fi": "Finnish",
    ]

    static let shortCodes: [String: String] = [
        "auto": "AUTO",
        "en": "EN",
        "zh": "ZH",
        "de": "DE",
        "es": "ES",
        "ru": "RU",
        "ko": "KO",
        "fr": "FR",
        "ja": "JA",
        "pt": "PT",
        "tr": "TR",
        "pl": "PL",
        "ca": "CA",
        "nl": "NL",
        "ar": "AR",
        "sv": "SV",
        "it": "IT",
        "id": "ID",
        "hi": "HI",
        "fi": "FI",
    ]

    /// Default initial prompts for each language to guide transcription
    static let defaultPrompts: [String: String] = [
        "auto": "",
        "en": "I mean.",
        "zh": "以下是普通话的句子。",
        "ja": "以下は日本語の文章です。",
        "ko": "다음은 한국어 문장입니다.",
        "de": "Dies ist eine Transkription auf Deutsch.",
        "es": "Esta es una transcripción en español.",
        "fr": "Voici une transcription en français.",
        "ru": "Это транскрипция на русском языке.",
        "pt": "Esta é uma transcrição em português.",
        "it": "Questa è una trascrizione in italiano.",
        "nl": "Dit is een transcriptie in het Nederlands.",
        "pl": "To jest transkrypcja w języku polskim.",
        "tr": "Bu Türkçe bir transkripsiyon.",
        "ar": "هذا نص باللغة العربية.",
        "sv": "Detta är en transkription på svenska.",
        "ca": "Aquesta és una transcripció en català.",
        "id": "Ini adalah transkripsi dalam bahasa Indonesia.",
        "hi": "यह हिंदी में एक प्रतिलेख है।",
        "fi": "Tämä on suomenkielinen litterointi.",
    ]

    /// Get the effective prompt for a language (user-customized or default)
    static func getEffectivePrompt(for language: String, userPrompts: [String: String]) -> String {
        // If user has explicitly set a prompt (even if empty), use it
        if let userPrompt = userPrompts[language] {
            return userPrompt
        }
        return defaultPrompts[language] ?? ""
    }

    /// Check if user has customized a prompt (different from default)
    static func isCustomPrompt(for language: String, userPrompts: [String: String]) -> Bool {
        guard let userPrompt = userPrompts[language] else { return false }
        // Empty is a valid customization if the default isn't empty
        return userPrompt != (defaultPrompts[language] ?? "")
    }

    static func getSystemLanguage() -> String {
        if let preferredLanguage = Locale.preferredLanguages.first {
            let preferredLanguage = preferredLanguage.prefix(2).lowercased()
            return availableLanguages.contains(preferredLanguage) ? preferredLanguage : "auto"
        } else {
            return "auto"
        }
    }
}
