//
//  TargetLanguageOptionDisplayTests.swift
//  ShareCoreTests
//

import Testing

@testable import ShareCore

@Suite("Target language display")
struct TargetLanguageOptionDisplayTests {
    @Test("System language option is not labeled Match")
    func appLanguagePrimaryLabelUsesSystemLanguages() {
        #expect(TargetLanguageOption.appLanguage.primaryLabel == "System Languages")
    }

    @Test("System language summary uses language abbreviations")
    func systemLanguageSummaryUsesLanguageAbbreviations() {
        let summary = TargetLanguageOption.systemLanguageSummary(
            candidates: [.englishUnitedStates, .simplifiedChinese, .traditionalChinese, .japanese, .french],
            limit: 3
        )

        #expect(summary == "EN, ZH, JA +1")
    }

    @Test("System language display name includes summary")
    func systemLanguageDisplayNameIncludesSummary() {
        let displayName = TargetLanguageOption.systemLanguageDisplayName(
            candidates: [.englishUnitedStates, .simplifiedChinese]
        )

        #expect(displayName == "System (EN, ZH)")
    }
}
