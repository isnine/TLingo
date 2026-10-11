//
//  TargetLanguageOption.swift
//  ShareCore
//
//  Created by Codex on 2025/10/27.
//

import Foundation

public struct TargetLanguageOption: RawRepresentable, Hashable, CaseIterable, Identifiable, Codable, Sendable {
    public let rawValue: String

    public init?(rawValue: String) {
        guard rawValue == "app-language" || LanguageCatalog.allCodeSet.contains(rawValue) else { return nil }
        self.rawValue = rawValue
    }

    private init(uncheckedRawValue: String) {
        rawValue = uncheckedRawValue
    }

    public static let appLanguage = Self(uncheckedRawValue: "app-language")
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

    public static let allCases: [TargetLanguageOption] =
        [.appLanguage] + LanguageCatalog.allCodes.map(TargetLanguageOption.init(uncheckedRawValue:))

    public static let storageKey = "settings.targetLanguageCode"

    public var id: String { rawValue }

    public static var selectionOptions: [TargetLanguageOption] {
        allCases
    }

    public static let realtimeSelectionOptions: [TargetLanguageOption] = allCases.filter { $0 != .appLanguage }

    public static func realtimeOption(englishName: String) -> TargetLanguageOption? {
        realtimeSelectionOptions.first { $0.englishName == englishName }
    }

    public static func defaultRealtimeTargetLanguage(
        preferredLanguages: [String] = Locale.preferredLanguages
    ) -> TargetLanguageOption {
        for identifier in preferredLanguages where !isEnglishLanguageIdentifier(identifier) {
            if let option = optionForCode(identifier), option != .appLanguage {
                return option
            }
        }
        return .simplifiedChinese
    }

    public var nativeName: String {
        name(in: Locale(identifier: baseIdentifier))
    }

    public var localizedName: String {
        name(in: Locale(identifier: TargetLanguageOption.appLanguageIdentifier))
    }

    public var englishName: String {
        name(in: Locale(identifier: "en"))
    }

    public var primaryLabel: String {
        switch self {
        case .appLanguage:
            return Self.automaticTargetLabel
        default:
            return nativeName
        }
    }

    public var secondaryLabel: String {
        switch self {
        case .appLanguage:
            return Self.automaticTargetDescription() ?? String(localized: "Auto-match target language")
        default:
            return englishName
        }
    }

    public var resolvedLocale: Locale {
        Locale(identifier: resolvedIdentifier())
    }

    public static var appLanguageIdentifier: String {
        // In an extension context Bundle.main refers to the extension's own
        // bundle whose preferredLocalizations may differ from the host app
        // (often returning "en" regardless of the user's language settings).
        // Use Bundle.main only when running inside the main app target.
        if Bundle.main.bundleURL.pathExtension != "appex",
           let preferred = Bundle.main.preferredLocalizations.first, !preferred.isEmpty
        {
            return preferred
        }
        if let systemPreferred = Locale.preferredLanguages.first, !systemPreferred.isEmpty {
            return systemPreferred
        }
        return Locale.autoupdatingCurrent.identifier
    }

    public static var appLanguageEnglishName: String {
        let englishLocale = Locale(identifier: "en")
        let identifier = appLanguageIdentifier
        if let localized = englishLocale.localizedString(forIdentifier: identifier) {
            return localized
        }
        let components = Locale.Components(identifier: identifier)
        if let languageCode = components.languageComponents.languageCode,
           let english = englishLocale.localizedString(forLanguageCode: languageCode.identifier)
        {
            return english
        }
        return identifier
    }

    public static var automaticTargetLabel: String {
        String(localized: "Choose Automatically")
    }

    /// Spells out the rule for the picker, e.g. "Translates to 简体中文, or English when the source is 简体中文".
    /// Only the first two candidates matter: the target is the first one unless the source already is it.
    public static func automaticTargetDescription(
        candidates: [TargetLanguageOption] = TargetLanguageOption.matchCandidates
    ) -> String? {
        guard candidates.count >= 2 else { return nil }
        return String(
            format: String(localized: "Translates to %1$@, or %2$@ when the source is %1$@"),
            candidates[0].primaryLabel,
            candidates[1].primaryLabel
        )
    }

    /// Languages available in Match mode: app language + system preferred languages + English, deduplicated.
    public static var matchCandidates: [TargetLanguageOption] {
        var seen = Set<TargetLanguageOption>()
        var result: [TargetLanguageOption] = []
        func add(_ option: TargetLanguageOption) {
            guard option != .appLanguage, seen.insert(option).inserted else { return }
            result.append(option)
        }
        if let appOption = optionForCode(appLanguageIdentifier) {
            add(appOption)
        }
        for identifier in Locale.preferredLanguages {
            if let option = optionForCode(identifier) {
                add(option)
            }
        }
        add(.english)
        return result
    }

    /// Maps a BCP 47 code (e.g. "zh-Hans", "en-US", "ja") to a TargetLanguageOption.
    private static func optionForCode(_ code: String) -> TargetLanguageOption? {
        let normalizedCode = code.replacingOccurrences(of: "_", with: "-")
        if let exact = TargetLanguageOption(rawValue: normalizedCode) {
            return exact
        }

        let components = Locale.Language.Components(identifier: code)
        guard let langCode = components.languageCode else { return nil }
        var candidate = langCode.identifier
        if let script = components.script {
            candidate += "-" + script.identifier
        }
        if let region = components.region {
            let regionCandidate = langCode.identifier + "-" + region.identifier
            if let option = TargetLanguageOption(rawValue: regionCandidate) {
                return option
            }
        }
        return TargetLanguageOption(rawValue: candidate)
            ?? TargetLanguageOption(rawValue: langCode.identifier)
    }

    private static func isEnglishLanguageIdentifier(_ identifier: String) -> Bool {
        Locale.Language.Components(identifier: identifier).languageCode?.identifier == "en"
    }

    public var promptDescriptor: String {
        let native = nativeName
        let english = englishName
        guard native != english else { return native }
        return "\(native) (\(english))"
    }

    private var baseIdentifier: String {
        switch self {
        case .appLanguage:
            return TargetLanguageOption.appLanguageIdentifier
        default:
            return rawValue
        }
    }

    private func resolvedIdentifier() -> String {
        var components = Locale.Components(identifier: baseIdentifier)
        if components.languageComponents.languageCode == nil {
            components.languageComponents.languageCode = Locale.LanguageCode(baseIdentifier)
        }
        return Locale(components: components).identifier
    }

    private func name(in locale: Locale) -> String {
        let identifier = resolvedIdentifier()
        if let localized = locale.localizedString(forIdentifier: identifier), !localized.isEmpty {
            return localized
        }

        let components = Locale.Components(identifier: identifier)
        guard let languageCode = components.languageComponents.languageCode else {
            return identifier
        }

        var name = locale.localizedString(forLanguageCode: languageCode.identifier) ?? identifier

        if let scriptCode = components.languageComponents.script,
           let scriptName = locale.localizedString(forScriptCode: scriptCode.identifier),
           !scriptName.isEmpty
        {
            name += " (\(scriptName))"
        }

        return name
    }
}
