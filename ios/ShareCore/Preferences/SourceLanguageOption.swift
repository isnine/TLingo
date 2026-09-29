//
//  SourceLanguageOption.swift
//  ShareCore
//

import Foundation

public enum SourceLanguageOption: String, CaseIterable, Identifiable, Codable {
    case auto
    case english = "en"
    case englishUnitedKingdom = "en-GB"
    case englishUnitedStates = "en-US"
    case arabic = "ar"
    case bengali = "bn"
    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"
    case czech = "cs"
    case danish = "da"
    case dutch = "nl"
    case finnish = "fi"
    case french = "fr"
    case german = "de"
    case greek = "el"
    case hebrew = "he"
    case hindi = "hi"
    case hungarian = "hu"
    case indonesian = "id"
    case italian = "it"
    case japanese = "ja"
    case korean = "ko"
    case malay = "ms"
    case norwegianBokmal = "nb"
    case polish = "pl"
    case portugueseBrazil = "pt-BR"
    case romanian = "ro"
    case russian = "ru"
    case spanish = "es"
    case swedish = "sv"
    case tamil = "ta"
    case telugu = "te"
    case thai = "th"
    case turkish = "tr"
    case ukrainian = "uk"
    case urdu = "ur"
    case vietnamese = "vi"

    public static let storageKey = "settings.sourceLanguageCode"

    public static var realtimeSelectionOptions: [SourceLanguageOption] {
        allCases.filter { $0 != .auto }
    }

    public static func realtimeOption(englishName: String) -> SourceLanguageOption? {
        realtimeSelectionOptions.first { $0.englishName == englishName }
    }

    public var id: String { rawValue }

    public var primaryLabel: String {
        switch self {
        case .auto:
            return String(localized: "Detect Language")
        default:
            return nativeName
        }
    }

    public var secondaryLabel: String {
        switch self {
        case .auto:
            return String(localized: "Detect automatically")
        default:
            return englishName
        }
    }

    public var nativeName: String {
        guard self != .auto else { return String(localized: "Auto") }
        let locale = Locale(identifier: rawValue)
        return locale.localizedString(forIdentifier: rawValue) ?? rawValue
    }

    public var englishName: String {
        guard self != .auto else { return String(localized: "Auto") }
        let english = Locale(identifier: "en")
        return english.localizedString(forIdentifier: rawValue) ?? rawValue
    }

    /// Human-readable descriptor for LLM prompts, e.g. "日本語 (Japanese)".
    public var promptDescriptor: String {
        guard self != .auto else { return "" }
        let native = nativeName
        let english = englishName
        guard native != english else { return native }
        return "\(native) (\(english))"
    }
}
