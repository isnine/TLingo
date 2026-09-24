//
//  LanguageSelectionCoverageTests.swift
//  ShareCoreTests
//

import Testing

@testable import ShareCore

@Suite("Language selection coverage")
struct LanguageSelectionCoverageTests {
    private let appleTranslateLanguageCodes: Set<String> = [
        "ar",
        "zh-Hans",
        "zh-Hant",
        "nl",
        "en-GB",
        "en-US",
        "fr",
        "de",
        "hi",
        "id",
        "it",
        "ja",
        "ko",
        "pl",
        "pt-BR",
        "ru",
        "es",
        "th",
        "tr",
        "uk",
        "vi",
    ]

    private let expandedCommonLanguageCodes: Set<String> = [
        "bn",
        "cs",
        "da",
        "el",
        "fi",
        "he",
        "hu",
        "ms",
        "nb",
        "ro",
        "sv",
        "ta",
        "te",
        "ur",
    ]

    @Test("Target language options cover Apple Translate languages")
    func targetLanguageOptionsCoverAppleTranslateLanguages() {
        let targetCodes = Set(TargetLanguageOption.selectionOptions.map(\.rawValue))

        #expect(targetCodes.isSuperset(of: appleTranslateLanguageCodes))
    }

    @Test("Source language options cover Apple Translate languages")
    func sourceLanguageOptionsCoverAppleTranslateLanguages() {
        let sourceCodes = Set(SourceLanguageOption.allCases.map(\.rawValue))

        #expect(sourceCodes.isSuperset(of: appleTranslateLanguageCodes))
    }

    @Test("Language options include expanded common languages")
    func languageOptionsIncludeExpandedCommonLanguages() {
        let targetCodes = Set(TargetLanguageOption.selectionOptions.map(\.rawValue))
        let sourceCodes = Set(SourceLanguageOption.allCases.map(\.rawValue))

        #expect(targetCodes.isSuperset(of: expandedCommonLanguageCodes))
        #expect(sourceCodes.isSuperset(of: expandedCommonLanguageCodes))
    }

    @Test("Selectable target languages have source-language equivalents")
    func selectableTargetsHaveSourceLanguageEquivalents() {
        let sourceCodes = Set(SourceLanguageOption.allCases.map(\.rawValue))
        let missing = TargetLanguageOption.selectionOptions
            .filter { $0 != .appLanguage && !sourceCodes.contains($0.rawValue) }
            .map(\.rawValue)

        #expect(missing.isEmpty)
    }
}
