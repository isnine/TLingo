//
//  LanguageChangeLogTests.swift
//  ShareCoreTests
//

import Testing

@testable import ShareCore

struct LanguageChangeLogTests {
    @Test("Formats language change log messages")
    func formatsLanguageChangeLogMessages() {
        let message = LanguageChangeLog.message(
            scope: "Preferences",
            field: "targetLanguage",
            from: "en",
            to: "zh-Hans",
            reason: "User selected target picker"
        )

        let expected = "languageChange scope=Preferences field=targetLanguage " +
            "from=en to=zh-Hans reason=User selected target picker"
        #expect(message == expected)
    }

    @Test("Formats nil language values")
    func formatsNilLanguageValues() {
        let message = LanguageChangeLog.message(
            scope: "HomeViewModel",
            field: "resolvedTargetLanguage",
            from: nil,
            to: "zh-Hans",
            reason: "Match resolved from auto-detected source"
        )

        let expected = "languageChange scope=HomeViewModel field=resolvedTargetLanguage " +
            "from=nil to=zh-Hans reason=Match resolved from auto-detected source"
        #expect(message == expected)
    }
}
