import SwiftStreamingMarkdown
import SwiftUI

#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

enum MarkdownTypography {
    static func renderConfig(
        preset: MarkdownContentPreset,
        textColor: Color,
        secondaryTextColor: Color,
        accentColor: Color,
        animatesText: Bool
    ) -> MarkdownRenderConfig {
        let metrics = Metrics(preset: preset)
        let body = textFonts(size: metrics.bodySize, lineHeight: 1.4)
        let quote = textFonts(size: metrics.quoteSize, lineHeight: 1.4)
        let table = textFonts(size: metrics.tableSize, lineHeight: 1.35)

        return .default
            .withShouldAnimateText(value: animatesText)
            .withBlockSpacing(value: metrics.blockSpacing)
            .withParagraphStyle(value: .init(
                textFonts: body,
                textColor: textColor
            ))
            .withBlockQuoteStyle(value: .init(
                textFonts: quote,
                textColor: secondaryTextColor
            ))
            .withHeadingStyle(value: .init(
                h1Font: headingFonts(size: metrics.h1Size),
                h2Font: headingFonts(size: metrics.h2Size),
                h3Font: headingFonts(size: metrics.h3Size),
                h4Font: headingFonts(size: metrics.h4Size),
                h5Font: headingFonts(size: metrics.h5Size, weight: .medium),
                h6Font: headingFonts(size: metrics.h6Size, weight: .medium),
                textColor: textColor
            ))
            .withOrderedListStyle(value: .init(
                textFonts: body,
                textColor: textColor
            ))
            .withTableStyle(value: .init(
                textFonts: table,
                headerTextColor: textColor,
                regularTextColor: textColor,
                headerBackgroundColor: MarkdownRenderConfig.defaultTableStyle.headerBackgroundColor,
                borderColor: MarkdownRenderConfig.defaultTableStyle.borderColor,
                actionButtonColor: accentColor
            ))
            .withInlineStyle(value: .init(
                boldTextColor: textColor,
                linkTextFont: font(size: metrics.bodySize, weight: .medium),
                linkTextColor: accentColor,
                codeTextFont: monospacedFont(size: metrics.codeSize),
                codeTextColor: textColor,
                codeBackgroundColor: MarkdownRenderConfig.defaultInlineStyle.codeBackgroundColor,
                codeUnderlineColor: accentColor
            ))
    }

    private static func textFonts(size: CGFloat, lineHeight: CGFloat) -> TextFonts {
        let normal = font(size: size)

        return TextFonts(
            normal: normal,
            italic: font(size: size, italic: true),
            bold: font(size: size, weight: .semibold),
            boldItalic: font(size: size, weight: .semibold, italic: true),
            preferredLetterSpacing: 0,
            preferredLineHeight: normal.pointSize * lineHeight
        )
    }

    private static func headingFonts(size: CGFloat, weight: MDFont.Weight = .semibold) -> TextFonts {
        let normal = font(size: size, weight: weight)

        return TextFonts(
            normal: normal,
            italic: font(size: size, weight: weight, italic: true),
            bold: font(size: size, weight: .bold),
            boldItalic: font(size: size, weight: .bold, italic: true),
            preferredLetterSpacing: 0,
            preferredLineHeight: normal.pointSize * 1.3
        )
    }

    private static func font(
        size: CGFloat,
        weight: MDFont.Weight = .regular,
        italic: Bool = false
    ) -> MDFont {
        #if canImport(UIKit)
            let base = MDFont.systemFont(ofSize: size, weight: weight)
            let scaled = UIFontMetrics(forTextStyle: .body).scaledFont(for: base)
            guard italic,
                  let descriptor = scaled.fontDescriptor.withSymbolicTraits(
                      scaled.fontDescriptor.symbolicTraits.union(.traitItalic)
                  )
            else {
                return scaled
            }
            return MDFont(descriptor: descriptor, size: scaled.pointSize)
        #elseif canImport(AppKit)
            let base = MDFont.systemFont(ofSize: size, weight: weight)
            guard italic else {
                return base
            }
            let descriptor = base.fontDescriptor.withSymbolicTraits(.italic)
            return MDFont(descriptor: descriptor, size: base.pointSize) ?? base
        #endif
    }

    private static func monospacedFont(size: CGFloat) -> MDFont {
        #if canImport(UIKit)
            UIFontMetrics(forTextStyle: .body).scaledFont(
                for: MDFont.monospacedSystemFont(ofSize: size, weight: .regular)
            )
        #elseif canImport(AppKit)
            MDFont.monospacedSystemFont(ofSize: size, weight: .regular)
        #endif
    }
}

private struct Metrics {
    let bodySize: CGFloat
    let quoteSize: CGFloat
    let tableSize: CGFloat
    let codeSize: CGFloat
    let h1Size: CGFloat
    let h2Size: CGFloat
    let h3Size: CGFloat
    let h4Size: CGFloat
    let h5Size: CGFloat
    let h6Size: CGFloat
    let blockSpacing: CGFloat

    init(preset: MarkdownContentPreset) {
        switch preset {
        case .compact, .fixed:
            bodySize = 15
            quoteSize = 14
            tableSize = 14
            codeSize = 14
            h1Size = 20
            h2Size = 18
            h3Size = 16
            h4Size = 15
            h5Size = 15
            h6Size = 15
            blockSpacing = 12
        case .detail:
            bodySize = 16
            quoteSize = 15
            tableSize = 15
            codeSize = 14
            h1Size = 22
            h2Size = 19
            h3Size = 17
            h4Size = 16
            h5Size = 16
            h6Size = 16
            blockSpacing = 16
        }
    }
}
