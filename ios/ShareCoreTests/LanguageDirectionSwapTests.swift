//
//  LanguageDirectionSwapTests.swift
//  ShareCoreTests
//

import Testing

@testable import ShareCore

@Suite("Language direction swap")
struct LanguageDirectionSwapTests {
    @Test("Swaps explicit source and target languages")
    func swapsExplicitLanguages() {
        let result = LanguageDirectionSwap.swapped(
            source: .english,
            target: .simplifiedChinese
        )

        #expect(result.source == .simplifiedChinese)
        #expect(result.target == .english)
    }

    @Test("Swaps Auto source to Match target")
    func swapsAutoSourceToMatchTarget() {
        let result = LanguageDirectionSwap.swapped(
            source: .auto,
            target: .japanese
        )

        #expect(result.source == .japanese)
        #expect(result.target == .appLanguage)
    }

    @Test("Swaps Match target to Auto source")
    func swapsMatchTargetToAutoSource() {
        let result = LanguageDirectionSwap.swapped(
            source: .french,
            target: .appLanguage
        )

        #expect(result.source == .auto)
        #expect(result.target == .french)
    }

    @Test("Swaps resolved Auto and Match languages")
    func swapsResolvedAutomaticLanguages() {
        let result = LanguageDirectionSwap.swapped(
            source: .auto,
            target: .appLanguage,
            resolvedSource: .english,
            resolvedTarget: .simplifiedChinese
        )

        #expect(result.source == .simplifiedChinese)
        #expect(result.target == .english)
    }

    @Test("Uses resolved Match target when source is not detected")
    func usesResolvedMatchTargetWithoutDetectedSource() {
        let result = LanguageDirectionSwap.swapped(
            source: .auto,
            target: .appLanguage,
            resolvedTarget: .simplifiedChinese
        )

        #expect(result.source == .simplifiedChinese)
        #expect(result.target == .appLanguage)
    }

    @Test("Continues swapping after resolving automatic defaults")
    func continuesSwappingAfterResolvingDefaults() {
        let first = LanguageDirectionSwap.swapped(
            source: .auto,
            target: .appLanguage,
            resolvedTarget: .simplifiedChinese
        )
        let second = LanguageDirectionSwap.swapped(
            source: first.source,
            target: first.target,
            resolvedSource: first.source,
            resolvedTarget: .english
        )
        let third = LanguageDirectionSwap.swapped(
            source: second.source,
            target: second.target
        )

        #expect(first.source == .simplifiedChinese)
        #expect(first.target == .appLanguage)
        #expect(second.source == .english)
        #expect(second.target == .simplifiedChinese)
        #expect(third.source == .simplifiedChinese)
        #expect(third.target == .english)
    }
}
