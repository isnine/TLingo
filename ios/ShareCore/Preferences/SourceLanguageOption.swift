//
//  SourceLanguageOption.swift
//  ShareCore
//

import Foundation

public struct SourceLanguageOption: RawRepresentable, Hashable, CaseIterable, Identifiable, Codable, Sendable {
    public let rawValue: String

    public init?(rawValue: String) {
        guard rawValue == "auto" || LanguageCatalog.allCodeSet.contains(rawValue) else { return nil }
        self.rawValue = rawValue
    }

    private init(uncheckedRawValue: String) {
        rawValue = uncheckedRawValue
    }

    public static let auto = Self(uncheckedRawValue: "auto")
    public static let english = Self(uncheckedRawValue: "en")
    public static let englishUnitedKingdom = Self(uncheckedRawValue: "en-GB")
    public static let englishUnitedStates = Self(uncheckedRawValue: "en-US")
    public static let arabic = Self(uncheckedRawValue: "ar")
    public static let bengali = Self(uncheckedRawValue: "bn")
    public static let simplifiedChinese = Self(uncheckedRawValue: "zh-Hans")
    public static let traditionalChinese = Self(uncheckedRawValue: "zh-Hant")
    public static let czech = Self(uncheckedRawValue: "cs")
    public static let danish = Self(uncheckedRawValue: "da")
    public static let dutch = Self(uncheckedRawValue: "nl")
    public static let finnish = Self(uncheckedRawValue: "fi")
    public static let french = Self(uncheckedRawValue: "fr")
    public static let german = Self(uncheckedRawValue: "de")
    public static let greek = Self(uncheckedRawValue: "el")
    public static let hebrew = Self(uncheckedRawValue: "he")
    public static let hindi = Self(uncheckedRawValue: "hi")
    public static let hungarian = Self(uncheckedRawValue: "hu")
    public static let indonesian = Self(uncheckedRawValue: "id")
    public static let italian = Self(uncheckedRawValue: "it")
    public static let japanese = Self(uncheckedRawValue: "ja")
    public static let korean = Self(uncheckedRawValue: "ko")
    public static let malay = Self(uncheckedRawValue: "ms")
    public static let norwegianBokmal = Self(uncheckedRawValue: "nb")
    public static let polish = Self(uncheckedRawValue: "pl")
    public static let portugueseBrazil = Self(uncheckedRawValue: "pt-BR")
    public static let romanian = Self(uncheckedRawValue: "ro")
    public static let russian = Self(uncheckedRawValue: "ru")
    public static let spanish = Self(uncheckedRawValue: "es")
    public static let swedish = Self(uncheckedRawValue: "sv")
    public static let tamil = Self(uncheckedRawValue: "ta")
    public static let telugu = Self(uncheckedRawValue: "te")
    public static let thai = Self(uncheckedRawValue: "th")
    public static let turkish = Self(uncheckedRawValue: "tr")
    public static let ukrainian = Self(uncheckedRawValue: "uk")
    public static let urdu = Self(uncheckedRawValue: "ur")
    public static let vietnamese = Self(uncheckedRawValue: "vi")

    public static let allCases: [SourceLanguageOption] =
        [.auto] + LanguageCatalog.allCodes.map(SourceLanguageOption.init(uncheckedRawValue:))

    public static let storageKey = "settings.sourceLanguageCode"

    public static let realtimeSelectionOptions: [SourceLanguageOption] = allCases.filter { $0 != .auto }

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

    /// Name in the app language, e.g. "日语" for `ja` when the app runs in Chinese.
    public var localizedName: String {
        guard self != .auto else { return String(localized: "Auto") }
        let locale = Locale(identifier: TargetLanguageOption.appLanguageIdentifier)
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
