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
}
