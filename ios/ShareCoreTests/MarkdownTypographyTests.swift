import SwiftStreamingMarkdown
import SwiftUI
import Testing

@testable import ShareCore

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
}
