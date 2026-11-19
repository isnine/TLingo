import Foundation
@testable import ShareCore
import SwiftStreamingMarkdown
import SwiftUI
import Testing

@Suite("Markdown typography")
struct MarkdownTypographyTests {
    @Test("Keeps static and streaming text on the same compact scale")
    func compactScale() {
        let staticConfig = config(animatesText: false)
        let streamingConfig = config(animatesText: true)

        #expect(staticConfig.paragraphStyle.textFonts.normal.pointSize == 15)
        #expect(streamingConfig.paragraphStyle.textFonts.normal.pointSize == 15)
        #expect(staticConfig.headingStyle.h1Font.normal.pointSize == 20)
        #expect(streamingConfig.shouldAnimateText)
    }

    private func config(animatesText: Bool) -> MarkdownRenderConfig {
        MarkdownTypography.renderConfig(
            preset: .compact,
            textColor: .primary,
            secondaryTextColor: .secondary,
            accentColor: .accentColor,
            animatesText: animatesText
        )
    }

    @Test("Scales body, headings, and code together without replacing the code font")
    func readingScale() {
        let config = MarkdownTypography.renderConfig(
            preset: .compact,
            textColor: .primary,
            secondaryTextColor: .secondary,
            accentColor: .accentColor,
            animatesText: false,
            readingStyle: ResultReadingStyle(textSize: 24)
        )
        #expect(config.paragraphStyle.textFonts.normal.pointSize == 24)
        #expect(config.headingStyle.h1Font.normal.pointSize == 32)
        #expect(abs(config.inlineStyle.codeTextFont.pointSize - 22.4) <= 0.5)
        #expect(config.inlineStyle.codeTextFont.fontName == self.config(animatesText: false).inlineStyle.codeTextFont.fontName)
    }

    @Test("Falls back to the system font when a custom font is unavailable")
    func missingFont() {
        let config = MarkdownTypography.renderConfig(
            preset: .compact,
            textColor: .primary,
            secondaryTextColor: .secondary,
            accentColor: .accentColor,
            animatesText: false,
            readingStyle: ResultReadingStyle(fontName: "TLingoMissingFont", textSize: 18)
        )
        #expect(config.paragraphStyle.textFonts.normal.pointSize == 18)
    }

    @Test("Reuses cached plain-text RenderableDocument with stable identity across body passes")
    @MainActor
    func plainTextDocumentIdentityIsStable() {
        let renderConfig = config(animatesText: false)
        let key = MarkdownContentView.ParseKey(
            text: "Plain translation result without markdown \(UUID().uuidString)",
            preset: .compact,
            textColor: .primary,
            colorScheme: .light,
            readingStyle: ResultReadingStyle(),
            dynamicTypeSize: .large
        )

        let first = MarkdownContentView.resolveCachedDocument(for: key, config: renderConfig)
        let second = MarkdownContentView.resolveCachedDocument(for: key, config: renderConfig)

        #expect(!first.needsAsyncParse)
        #expect(!first.shouldPinParsed)
        #expect(!second.needsAsyncParse)
        #expect(!second.shouldPinParsed)
        #expect(first.document == second.document)
    }

    @Test("Does not cache plain-text placeholder for markdown text until parsed")
    @MainActor
    func markdownDocumentRequiresParseUntilCached() async {
        let renderConfig = config(animatesText: false)
        let key = MarkdownContentView.ParseKey(
            text: "Result with **bold** marker \(UUID().uuidString)",
            preset: .compact,
            textColor: .primary,
            colorScheme: .light,
            readingStyle: ResultReadingStyle(),
            dynamicTypeSize: .large
        )

        let cold = MarkdownContentView.resolveCachedDocument(for: key, config: renderConfig)
        #expect(cold.needsAsyncParse)
        #expect(!cold.shouldPinParsed)

        let parsed = await MarkdownParserImpl().parse(text: key.text, config: renderConfig)
        MarkdownContentView.storeCachedDocument(parsed, for: key, isMarkdown: true)

        let warm = MarkdownContentView.resolveCachedDocument(for: key, config: renderConfig)
        #expect(!warm.needsAsyncParse)
        #expect(warm.shouldPinParsed)
        #expect(warm.document == parsed)
    }

    @Test("Preserves ordered-list detection with literal-dot fast rejection")
    func orderedListDetectionWithDotGuard() {
        #expect(!MarkdownContentView.containsMarkdownSyntax("普通中文译文，包含数字 2026，不含英文句点。"))
        #expect(!MarkdownContentView.containsMarkdownSyntax("Plain English with 3.14 and v2.0"))
        #expect(MarkdownContentView.containsMarkdownSyntax("1. First item"))
        #expect(MarkdownContentView.containsMarkdownSyntax("Intro\n  2. Indented item"))
    }
}
