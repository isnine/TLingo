import Foundation
import SwiftStreamingMarkdown
import SwiftUI

public enum MarkdownContentPreset {
    case compact
    case detail
    /// Large body text for the primary translation on iPhone Home.
    case prominent
    case fixed(Font)
}

public struct MarkdownContentView: View {
    private let text: String
    private let preset: MarkdownContentPreset
    private let textColor: Color?
    private let lineLimit: Int?

    @Environment(\.colorScheme) private var colorScheme

    private var colors: AppColorPalette {
        AppColors.palette(for: colorScheme)
    }

    public init(
        text: String,
        preset: MarkdownContentPreset = .compact,
        textColor: Color? = nil,
        lineLimit: Int? = nil
    ) {
        self.text = text
        self.preset = preset
        self.textColor = textColor
        self.lineLimit = lineLimit
    }

    @ViewBuilder
    public var body: some View {
        if let lineLimit {
            Text(previewText)
                .font(previewFont)
                .foregroundStyle(resolvedTextColor)
                .lineLimit(lineLimit)
                .textSelection(.enabled)
                .contentDirectionAware(text)
        } else {
            SwiftStreamingMarkdown.MarkdownView(
                text: text.isEmpty ? " " : text,
                config: renderConfig
            )
            .contentDirectionAware(text)
        }
    }

    private var resolvedTextColor: Color {
        textColor ?? colors.textPrimary
    }

    private var previewText: AttributedString {
        (try? AttributedString(markdown: text)) ?? AttributedString(text)
    }

    private var previewFont: Font {
        switch preset {
        case .compact:
            .system(size: 15)
        case .detail:
            .system(size: 16)
        case .prominent:
            .system(size: 19)
        case let .fixed(font):
            font
        }
    }

    private var renderConfig: MarkdownRenderConfig {
        MarkdownTypography.renderConfig(
            preset: preset,
            textColor: resolvedTextColor,
            secondaryTextColor: colors.textSecondary,
            accentColor: colors.accent,
            animatesText: false
        )
    }
}
