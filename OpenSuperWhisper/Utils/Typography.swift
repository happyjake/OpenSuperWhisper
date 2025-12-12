import SwiftUI

/// Centralized typography system for consistent fonts across the app
enum Typography {
    // MARK: - Card Transcription Text
    static let cardBody = Font.system(size: 14, weight: .regular, design: .default)
    static let cardBodyLineSpacing: CGFloat = 4

    // MARK: - Card Metadata (bottom bar)
    static let cardMeta = Font.system(size: 12, weight: .medium)
    static let cardMetaSeparator = Font.system(size: 12, weight: .regular)

    // MARK: - Card Actions
    static let cardReadMore = Font.system(size: 13, weight: .medium)
    static let cardReadMoreIcon = Font.system(size: 10, weight: .semibold)
    static let cardActionIcon = Font.system(size: 14, weight: .regular)

    // MARK: - Detail View
    static let detailTitle = Font.system(size: 16, weight: .semibold)
    static let detailDate = Font.system(size: 12, weight: .medium)
    static let detailBody = Font.system(size: 14, weight: .regular)
    static let detailBodyLineSpacing: CGFloat = 6
    static let detailEditorLineSpacing: CGFloat = 4

    // MARK: - Settings
    static let settingsHeader = Font.system(size: 13, weight: .semibold)
    static let settingsLabel = Font.system(size: 12, weight: .medium)
    static let settingsBody = Font.system(size: 12, weight: .regular)
    static let settingsCaption = Font.system(size: 11, weight: .regular)
    static let settingsMono = Font.system(size: 11, weight: .regular, design: .monospaced)
}
