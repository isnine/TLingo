//
//  TargetLanguageOption.swift
//  ShareCore
//
//  Created by Codex on 2025/10/27.
//

import Foundation

public enum TargetLanguageOption: String, CaseIterable, Identifiable, Codable {
    case appLanguage = "app-language"
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

    public static let storageKey = "settings.targetLanguageCode"

    public var id: String { rawValue }

    public static var selectionOptions: [TargetLanguageOption] {
        [
            .appLanguage,
            .english,
            .englishUnitedKingdom,
            .englishUnitedStates,
            .arabic,
            .bengali,
            .simplifiedChinese,
            .traditionalChinese,
            .czech,
            .danish,
            .dutch,
            .finnish,
            .french,
            .german,
            .greek,
            .hebrew,
            .hindi,
            .hungarian,
            .indonesian,
            .italian,
            .japanese,
            .korean,
            .malay,
            .norwegianBokmal,
            .polish,
            .portugueseBrazil,
            .romanian,
            .russian,
            .spanish,
            .swedish,
            .tamil,
            .telugu,
            .thai,
            .turkish,
            .ukrainian,
            .urdu,
            .vietnamese,
        ]
    }

    public static var realtimeSelectionOptions: [TargetLanguageOption] {
        selectionOptions.filter { $0 != .appLanguage }
    }

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
