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
        animatesText: Bool,
        readingStyle: ResultReadingStyle = ResultReadingStyle()
    ) -> MarkdownRenderConfig {
        let metrics = Metrics(preset: preset)
        let body = textFonts(size: metrics.bodySize, lineHeight: 1.4, readingStyle: readingStyle)
        let quote = textFonts(size: metrics.quoteSize, lineHeight: 1.4, readingStyle: readingStyle)
        let table = textFonts(size: metrics.tableSize, lineHeight: 1.35, readingStyle: readingStyle)

        return .default
            .withShouldAnimateText(value: animatesText)
            .withBlockSpacing(value: metrics.blockSpacing * readingStyle.scale)
            .withParagraphStyle(value: .init(
                textFonts: body,
                textColor: textColor
            ))
            .withBlockQuoteStyle(value: .init(
                textFonts: quote,
                textColor: secondaryTextColor
            ))
            .withHeadingStyle(value: .init(
                h1Font: headingFonts(size: metrics.h1Size, readingStyle: readingStyle),
                h2Font: headingFonts(size: metrics.h2Size, readingStyle: readingStyle),
                h3Font: headingFonts(size: metrics.h3Size, readingStyle: readingStyle),
                h4Font: headingFonts(size: metrics.h4Size, readingStyle: readingStyle),
                h5Font: headingFonts(size: metrics.h5Size, weight: .medium, readingStyle: readingStyle),
                h6Font: headingFonts(size: metrics.h6Size, weight: .medium, readingStyle: readingStyle),
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
                linkTextFont: font(size: metrics.bodySize, weight: .medium, readingStyle: readingStyle),
                linkTextColor: accentColor,
                codeTextFont: monospacedFont(size: metrics.codeSize * readingStyle.scale),
                codeTextColor: textColor,
                codeBackgroundColor: MarkdownRenderConfig.defaultInlineStyle.codeBackgroundColor,
                codeUnderlineColor: accentColor
            ))
    }

    private static func textFonts(size: CGFloat, lineHeight: CGFloat, readingStyle: ResultReadingStyle) -> TextFonts {
        let normal = font(size: size, readingStyle: readingStyle)

        return TextFonts(
            normal: normal,
            italic: font(size: size, italic: true, readingStyle: readingStyle),
            bold: font(size: size, weight: .semibold, readingStyle: readingStyle),
            boldItalic: font(size: size, weight: .semibold, italic: true, readingStyle: readingStyle),
            preferredLetterSpacing: 0,
            preferredLineHeight: normal.pointSize * lineHeight
        )
    }

    private static func headingFonts(
        size: CGFloat,
        weight: MDFont.Weight = .semibold,
        readingStyle: ResultReadingStyle
    ) -> TextFonts {
        let normal = font(size: size, weight: weight, readingStyle: readingStyle)

        return TextFonts(
            normal: normal,
            italic: font(size: size, weight: weight, italic: true, readingStyle: readingStyle),
            bold: font(size: size, weight: .bold, readingStyle: readingStyle),
            boldItalic: font(size: size, weight: .bold, italic: true, readingStyle: readingStyle),
            preferredLetterSpacing: 0,
            preferredLineHeight: normal.pointSize * 1.3
        )
    }

    private static func font(
        size: CGFloat,
        weight: MDFont.Weight = .regular,
        italic: Bool = false,
        readingStyle: ResultReadingStyle
    ) -> MDFont {
        let scaledSize = size * readingStyle.scale
        #if canImport(UIKit)
            var base = readingStyle.fontName.flatMap { MDFont(name: $0, size: scaledSize) }
                ?? MDFont.systemFont(ofSize: scaledSize, weight: weight)
            if readingStyle.fontName != nil, weight >= .semibold,
               let descriptor = base.fontDescriptor.withSymbolicTraits(
                   base.fontDescriptor.symbolicTraits.union(.traitBold)
               )
            {
                base = MDFont(descriptor: descriptor, size: scaledSize)
            }
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
            var base = readingStyle.fontName.flatMap { MDFont(name: $0, size: scaledSize) }
                ?? MDFont.systemFont(ofSize: scaledSize, weight: weight)
            if readingStyle.fontName != nil, weight >= .semibold {
                base = NSFontManager.shared.convert(base, toHaveTrait: .boldFontMask)
            }
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
        case .prominent:
            bodySize = 19
            quoteSize = 17
            tableSize = 16
            codeSize = 15
            h1Size = 24
            h2Size = 22
            h3Size = 20
            h4Size = 19
            h5Size = 19
            h6Size = 19
            blockSpacing = 14
        }
    }
}
