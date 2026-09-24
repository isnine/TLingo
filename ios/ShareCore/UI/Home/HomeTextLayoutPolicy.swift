//
//  HomeTextLayoutPolicy.swift
//  TLingo
//

import CoreGraphics

enum HomeTextLayoutIdiom {
    case phone
    case pad
    case mac
}

enum HomeSatisfactionPromptPlacement {
    case overlay
    case inlineWithResults
    case hidden
}

enum HomeSatisfactionPromptChrome {
    case toast
    case resultCell
    case none
}

enum HomeLanguageSelectorPlacement {
    case aboveInput
    case insideInput
}

enum HomeBottomComposerPlacement {
    case bottomDock
    case centeredEmptyState
}

struct HomeBottomComposerHeights: Equatable {
    let dockHeight: CGFloat
    let inputHeight: CGFloat
    let editorHeight: CGFloat
}

enum HomeTextLayoutPolicy {
    static func usesBottomComposerLayout(openFromExtension: Bool, idiom: HomeTextLayoutIdiom) -> Bool {
        guard !openFromExtension else { return false }
        return idiom == .pad || idiom == .mac
    }

    static func satisfactionPromptPlacement(
        usesBottomComposerLayout: Bool,
        hasResults: Bool,
        openFromExtension: Bool = false
    ) -> HomeSatisfactionPromptPlacement {
        if openFromExtension {
            return .overlay
        }

        if hasResults {
            return .inlineWithResults
        }

        if usesBottomComposerLayout {
            return .hidden
        }

        return .overlay
    }

    static func satisfactionPromptChrome(for placement: HomeSatisfactionPromptPlacement) -> HomeSatisfactionPromptChrome {
        switch placement {
        case .overlay:
            return .toast
        case .inlineWithResults:
            return .resultCell
        case .hidden:
            return .none
        }
    }

    static func languageSelectorPlacement(
        usesBottomComposerLayout: Bool,
        usesSimplifiedTextLayout: Bool
    ) -> HomeLanguageSelectorPlacement {
        if usesBottomComposerLayout || !usesSimplifiedTextLayout {
            return .insideInput
        }
        return .aboveInput
    }

    static func bottomComposerPlacement(
        usesBottomComposerLayout: Bool,
        hasResults: Bool,
        hasAttachments: Bool
    ) -> HomeBottomComposerPlacement {
        if usesBottomComposerLayout, !hasResults, !hasAttachments {
            return .centeredEmptyState
        }
        return .bottomDock
    }

    static func bottomComposerHeights(
        availableHeight: CGFloat,
        chromeHeight: CGFloat,
        compactInputHeight: CGFloat,
        compactEditorMinHeight: CGFloat,
        compactEditorMaxHeight: CGFloat,
        measuredEditorContentHeight: CGFloat
    ) -> HomeBottomComposerHeights {
        let availableHeight = finitePositive(availableHeight)
        let chromeHeight = finitePositive(chromeHeight)
        let compactInputHeight = finitePositive(compactInputHeight)
        let compactEditorMinHeight = finitePositive(compactEditorMinHeight)
        let compactEditorMaxHeight = max(compactEditorMinHeight, finitePositive(compactEditorMaxHeight))
        let measuredEditorContentHeight = finitePositive(measuredEditorContentHeight)

        let maxDockHeight = availableHeight / 3
        let maxInputHeight = max(compactInputHeight, maxDockHeight - chromeHeight)
        let desiredEditorHeight = max(compactEditorMinHeight, measuredEditorContentHeight)
        let desiredInputHeight = compactInputHeight + max(0, desiredEditorHeight - compactEditorMaxHeight)
        let inputHeight = min(max(compactInputHeight, desiredInputHeight), maxInputHeight)
        let editorHeight = min(
            desiredEditorHeight,
            max(compactEditorMinHeight, compactEditorMaxHeight + max(0, inputHeight - compactInputHeight))
        )

        return HomeBottomComposerHeights(
            dockHeight: chromeHeight + inputHeight,
            inputHeight: inputHeight,
            editorHeight: editorHeight
        )
    }

    private static func finitePositive(_ value: CGFloat) -> CGFloat {
        value.isFinite ? max(0, value) : 0
    }
}
