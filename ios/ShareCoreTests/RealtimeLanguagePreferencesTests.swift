//
//  RealtimeLanguagePreferencesTests.swift
//  ShareCoreTests
//

import Foundation
import Testing

@testable import ShareCore

@Suite("Realtime language preferences")
struct RealtimeLanguagePreferencesTests {
    @Test("Realtime languages default separately from text languages")
    func defaultsSeparatelyFromTextLanguages() throws {
        let defaults = try makeDefaults()
        defaults.set(TargetLanguageOption.french.rawValue, forKey: TargetLanguageOption.storageKey)
        defaults.set(SourceLanguageOption.auto.rawValue, forKey: SourceLanguageOption.storageKey)

        let preferences = AppPreferences(
            defaults: defaults,
            preferredLanguages: ["en-US", "ja-JP", "zh-Hans"]
        )

        #expect(preferences.sourceLanguage == .auto)
        #expect(preferences.targetLanguage == .french)
        #expect(preferences.realtimeSourceLanguage == .english)
        #expect(preferences.realtimeTargetLanguage == .japanese)
    }

    @Test("Realtime language changes persist without changing text languages")
    func changesPersistSeparatelyFromTextLanguages() throws {
        let defaults = try makeDefaults()
        let preferences = AppPreferences(
            defaults: defaults,
            preferredLanguages: ["en-US", "ja-JP"]
        )

        preferences.setRealtimeSourceLanguage(.german, reason: "Test")
        preferences.setRealtimeTargetLanguage(.korean, reason: "Test")

        #expect(preferences.sourceLanguage == .auto)
        #expect(preferences.targetLanguage == .appLanguage)

        let reloaded = AppPreferences(
            defaults: defaults,
            preferredLanguages: ["en-US", "ja-JP"]
        )
        #expect(reloaded.realtimeSourceLanguage == .german)
        #expect(reloaded.realtimeTargetLanguage == .korean)
        #expect(reloaded.sourceLanguage == .auto)
        #expect(reloaded.targetLanguage == .appLanguage)
    }

    @Test("Realtime target default skips English preferred languages")
    func targetDefaultSkipsEnglishPreferredLanguages() {
        let target = TargetLanguageOption.defaultRealtimeTargetLanguage(
            preferredLanguages: ["en-US", "en-GB", "zh-Hans", "ja-JP"]
        )

        #expect(target == .simplifiedChinese)
    }

    private func makeDefaults() throws -> UserDefaults {
        let suiteName = "RealtimeLanguagePreferencesTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
