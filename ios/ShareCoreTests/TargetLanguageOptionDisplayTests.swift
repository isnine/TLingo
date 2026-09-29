//
//  TargetLanguageOptionDisplayTests.swift
//  ShareCoreTests
//

import Testing

@testable import ShareCore

@Suite("Target language display")
struct TargetLanguageOptionDisplayTests {
    @Test("Automatic target option is labeled Choose Automatically")
    func appLanguagePrimaryLabelUsesChooseAutomatically() {
        #expect(TargetLanguageOption.appLanguage.primaryLabel == "Choose Automatically")
    }

    @Test("Automatic target description names the first two languages")
    func automaticTargetDescriptionNamesFirstTwoLanguages() {
        let chinese = TargetLanguageOption.simplifiedChinese.primaryLabel
        let english = TargetLanguageOption.english.primaryLabel

        #expect(
            TargetLanguageOption.automaticTargetDescription(candidates: [.simplifiedChinese, .english, .japanese])
                == "Translates to \(chinese), or \(english) when the source is \(chinese)"
        )
        #expect(TargetLanguageOption.automaticTargetDescription(candidates: [.english]) == nil)
    }
}
