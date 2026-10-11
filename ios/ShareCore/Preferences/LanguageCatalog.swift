//
//  LanguageCatalog.swift
//  ShareCore
//

import Foundation

/// Language codes shared by `SourceLanguageOption` and `TargetLanguageOption`.
enum LanguageCatalog {
    /// Languages pinned in the picker's "Common Languages" section.
    static let commonCodes: [String] = [
        "en", "en-GB", "en-US", "ar", "bn", "zh-Hans", "zh-Hant", "cs", "da", "nl", "fi", "fr", "de",
        "el", "he", "hi", "hu", "id", "it", "ja", "ko", "ms", "nb", "pl", "pt-BR", "ro", "ru", "es",
        "sv", "ta", "te", "th", "tr", "uk", "ur", "vi",
    ]

    /// Every language the system can name, English variants first and the rest by English name.
    static let allCodes: [String] = {
        // "zh" is offered as its two scripts, and "no" duplicates Bokmål.
        let excluded: Set<String> = ["zh", "no"]
        let english = Locale(identifier: "en")
        var codes = Set(commonCodes)
        for identifier in Locale.availableIdentifiers {
            guard let code = Locale.Components(identifier: identifier).languageComponents.languageCode?.identifier,
                  !excluded.contains(code),
                  english.localizedString(forLanguageCode: code) != nil
            else { continue }
            codes.insert(code)
        }
        let leading = ["en", "en-GB", "en-US"]
        let rest = codes.subtracting(leading).sorted { lhs, rhs in
            let lhsName = english.localizedString(forIdentifier: lhs) ?? lhs
            let rhsName = english.localizedString(forIdentifier: rhs) ?? rhs
            return lhsName.localizedStandardCompare(rhsName) == .orderedAscending
        }
        return leading + rest
    }()

    static let allCodeSet = Set(allCodes)
}
