//
//  HomeTextLayoutPolicyTests.swift
//  ShareCoreTests
//

import CoreGraphics
import Testing

@testable import ShareCore

@Suite("Home text layout policy")
struct HomeTextLayoutPolicyTests {
    @Test("Mac and iPad use bottom composer outside extension")
    func macAndIPadUseBottomComposer() {
        #expect(HomeTextLayoutPolicy.usesBottomComposerLayout(openFromExtension: false, idiom: .mac))
        #expect(HomeTextLayoutPolicy.usesBottomComposerLayout(openFromExtension: false, idiom: .pad))
    }

    @Test("iPhone and extension keep stacked layout")
    func iPhoneAndExtensionKeepStackedLayout() {
        #expect(!HomeTextLayoutPolicy.usesBottomComposerLayout(openFromExtension: false, idiom: .phone))
        #expect(!HomeTextLayoutPolicy.usesBottomComposerLayout(openFromExtension: true, idiom: .mac))
        #expect(!HomeTextLayoutPolicy.usesBottomComposerLayout(openFromExtension: true, idiom: .pad))
    }

    @Test("Bottom composer places language selector inside input")
    func bottomComposerPlacesLanguageSelectorInsideInput() {
        #expect(
            HomeTextLayoutPolicy.languageSelectorPlacement(
                usesBottomComposerLayout: true,
                usesSimplifiedTextLayout: true
            ) == .insideInput
        )
    }

    @Test("Stacked simplified layout places language selector above input")
    func stackedSimplifiedLayoutPlacesLanguageSelectorAboveInput() {
        #expect(
            HomeTextLayoutPolicy.languageSelectorPlacement(
                usesBottomComposerLayout: false,
                usesSimplifiedTextLayout: true
            ) == .aboveInput
        )
    }

    @Test("Extension layout places language selector inside input")
    func extensionLayoutPlacesLanguageSelectorInsideInput() {
        #expect(
            HomeTextLayoutPolicy.languageSelectorPlacement(
                usesBottomComposerLayout: false,
                usesSimplifiedTextLayout: false
            ) == .insideInput
        )
    }

    @Test("Bottom composer centers when text input is empty")
    func bottomComposerCentersWhenTextInputIsEmpty() {
        #expect(
            HomeTextLayoutPolicy.bottomComposerPlacement(
                usesBottomComposerLayout: true,
                hasResults: false,
                hasAttachments: false
            ) == .centeredEmptyState
        )
    }

    @Test("Bottom composer centers while text is being composed")
    func bottomComposerCentersWhileTextIsBeingComposed() {
        #expect(
            HomeTextLayoutPolicy.bottomComposerPlacement(
                usesBottomComposerLayout: true,
                hasResults: false,
                hasAttachments: false
            ) == .centeredEmptyState
        )
    }

    @Test("Bottom composer docks when sent content exists")
    func bottomComposerDocksWhenSentContentExists() {
        #expect(
            HomeTextLayoutPolicy.bottomComposerPlacement(
                usesBottomComposerLayout: true,
                hasResults: false,
                hasAttachments: true
            ) == .bottomDock
        )
        #expect(
            HomeTextLayoutPolicy.bottomComposerPlacement(
                usesBottomComposerLayout: true,
                hasResults: true,
                hasAttachments: false
            ) == .bottomDock
        )
        #expect(
            HomeTextLayoutPolicy.bottomComposerPlacement(
                usesBottomComposerLayout: false,
                hasResults: false,
                hasAttachments: false
            ) == .bottomDock
        )
    }

    @Test("Bottom composer shows satisfaction prompt inline only with results")
    func bottomComposerShowsSatisfactionPromptInlineOnlyWithResults() {
        #expect(
            HomeTextLayoutPolicy.satisfactionPromptPlacement(
                usesBottomComposerLayout: true,
                hasResults: true
            ) == .inlineWithResults
        )
        #expect(
            HomeTextLayoutPolicy.satisfactionPromptPlacement(
                usesBottomComposerLayout: true,
                hasResults: false
            ) == .hidden
        )
    }

    @Test("Stacked layout shows satisfaction prompt inline with results")
    func stackedLayoutShowsSatisfactionPromptInlineWithResults() {
        #expect(
            HomeTextLayoutPolicy.satisfactionPromptPlacement(
                usesBottomComposerLayout: false,
                hasResults: false
            ) == .overlay
        )
        #expect(
            HomeTextLayoutPolicy.satisfactionPromptPlacement(
                usesBottomComposerLayout: false,
                hasResults: true
            ) == .inlineWithResults
        )
    }

    @Test("Extension layout keeps satisfaction prompt as overlay")
    func extensionLayoutKeepsSatisfactionPromptAsOverlay() {
        #expect(
            HomeTextLayoutPolicy.satisfactionPromptPlacement(
                usesBottomComposerLayout: false,
                hasResults: true,
                openFromExtension: true
            ) == .overlay
        )
    }

    @Test("Inline satisfaction prompt uses result cell chrome")
    func inlineSatisfactionPromptUsesResultCellChrome() {
        #expect(HomeTextLayoutPolicy.satisfactionPromptChrome(for: .inlineWithResults) == .resultCell)
        #expect(HomeTextLayoutPolicy.satisfactionPromptChrome(for: .overlay) == .toast)
        #expect(HomeTextLayoutPolicy.satisfactionPromptChrome(for: .hidden) == .none)
    }

    @Test("Bottom composer keeps compact height for short text")
    func bottomComposerKeepsCompactHeightForShortText() {
        let heights = HomeTextLayoutPolicy.bottomComposerHeights(
            availableHeight: 900,
            chromeHeight: 120,
            compactInputHeight: 112,
            compactEditorMinHeight: 44,
            compactEditorMaxHeight: 56,
            measuredEditorContentHeight: 40
        )

        #expect(heights.inputHeight == 112)
        #expect(heights.editorHeight == 44)
        #expect(heights.dockHeight == 232)
    }

    @Test("Bottom composer grows for longer text")
    func bottomComposerGrowsForLongerText() {
        let heights = HomeTextLayoutPolicy.bottomComposerHeights(
            availableHeight: 1200,
            chromeHeight: 120,
            compactInputHeight: 112,
            compactEditorMinHeight: 44,
            compactEditorMaxHeight: 56,
            measuredEditorContentHeight: 120
        )

        #expect(heights.inputHeight == 176)
        #expect(heights.editorHeight == 120)
        #expect(heights.dockHeight == 296)
    }

    @Test("Bottom composer caps total dock height to one third")
    func bottomComposerCapsTotalDockHeightToOneThird() {
        let heights = HomeTextLayoutPolicy.bottomComposerHeights(
            availableHeight: 900,
            chromeHeight: 120,
            compactInputHeight: 112,
            compactEditorMinHeight: 44,
            compactEditorMaxHeight: 56,
            measuredEditorContentHeight: 500
        )

        #expect(heights.inputHeight == 180)
        #expect(heights.editorHeight == 124)
        #expect(heights.dockHeight == 300)
    }

    @Test("Bottom composer preserves compact input when chrome exceeds cap")
    func bottomComposerPreservesCompactInputWhenChromeExceedsCap() {
        let heights = HomeTextLayoutPolicy.bottomComposerHeights(
            availableHeight: 300,
            chromeHeight: 140,
            compactInputHeight: 112,
            compactEditorMinHeight: 44,
            compactEditorMaxHeight: 56,
            measuredEditorContentHeight: 500
        )

        #expect(heights.inputHeight == 112)
        #expect(heights.editorHeight == 56)
        #expect(heights.dockHeight == 252)
    }
}
