//
//  RealtimeLanguageSelectionOptionsTests.swift
//  ShareCoreTests
//

#if os(macOS) || os(iOS)
    import Testing

    @testable import ShareCore

    @Suite("Realtime language selection options")
    struct RealtimeLanguageSelectionOptionsTests {
        @Test("Source options exclude automatic detection")
        func sourceOptionsExcludeAutomaticDetection() {
            #expect(!SourceLanguageOption.realtimeSelectionOptions.contains(.auto))
            #expect(SourceLanguageOption.realtimeSelectionOptions.first == .english)
        }

        @Test("Target options exclude match language")
        func targetOptionsExcludeMatchLanguage() {
            #expect(!TargetLanguageOption.realtimeSelectionOptions.contains(.appLanguage))
            #expect(TargetLanguageOption.realtimeSelectionOptions.first == .english)
        }
    }
#endif
