//
//  RealtimeTranslationProviderTests.swift
//  ShareCoreTests
//

#if os(macOS) || os(iOS)
    import Foundation
    import Testing

    @testable import ShareCore

    @Suite("RealtimeTranslationProvider")
    struct RealtimeTranslationProviderTests {
        @Test("Defines default and model mapping")
        func definesDefaultAndModelMapping() {
            #expect(RealtimeTranslationProvider.default == .appleTranslator)
            #expect(RealtimeTranslationProvider.allCases == [
                .appleTranslator,
                .appleTranslationRealtime,
                .transcriptionOnly,
            ])
            #expect(RealtimeTranslationProvider.appleTranslator.modelID == ModelConfig.appleTranslateID)
            #expect(!RealtimeTranslationProvider.transcriptionOnly.performsTranslation)
            #expect(!RealtimeTranslationProvider.transcriptionOnly.usesAppleTextTranslation)
            #expect(RealtimeTranslationProvider.transcriptionOnly.modelID == "none")
            #expect(RealtimeLanguageMatcher.matches(
                Locale.Language(identifier: "en-US"),
                Locale.Language(identifier: "en")
            ))
            #expect(!RealtimeLanguageMatcher.matches(
                Locale.Language(identifier: "zh-Hans"),
                Locale.Language(identifier: "zh-Hant")
            ))
            #expect(RealtimeTranslationProvider.availableCases.contains(.transcriptionOnly))
            #expect(RealtimeTranslationProvider(rawValue: "gpt_5_nano") == nil)
        }
    }
#endif
