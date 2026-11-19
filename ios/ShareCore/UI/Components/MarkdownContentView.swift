import Foundation
import SwiftStreamingMarkdown
import SwiftUI

public enum MarkdownContentPreset: Hashable, Sendable {
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
    private let timingTrace: TranslationTimingTrace?

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var parsed: ParsedMarkdown?
    @ObservedObject private var fontLibrary = ResultFontLibrary.shared

    @ThemeColors private var colors: AppColorPalette

    @MainActor
    private static var documentCache: [ParseKey: RenderableDocument] = [:]
    private static let documentCacheLimit = 64

    public init(
        text: String,
        preset: MarkdownContentPreset = .compact,
        textColor: Color? = nil,
        lineLimit: Int? = nil,
        timingTrace: TranslationTimingTrace? = nil
    ) {
        self.text = text
        self.preset = preset
        self.textColor = textColor
        self.lineLimit = lineLimit
        self.timingTrace = timingTrace
    }

    public var body: some View {
        if let lineLimit {
            Text(previewText)
                .font(previewFont)
                .foregroundStyle(resolvedTextColor)
                .lineLimit(lineLimit)
                .textSelection(.enabled)
                .contentDirectionAware(text)
        } else {
            SwiftStreamingMarkdown.DocumentView(
                renderableDocument: renderableDocument,
                config: renderConfig
            )
            .task(id: parseKey) {
                let key = parseKey
                guard Self.containsMarkdownSyntax(key.text) else {
                    timingTrace?.mark(.markdownParsed)
                    return
                }
                if let cached = Self.documentCache[key] {
                    if parsed?.key != key {
                        parsed = ParsedMarkdown(key: key, document: cached)
                    }
                    timingTrace?.mark(.markdownParsed)
                    return
                }
                let document = await MarkdownParserImpl().parse(text: key.text, config: renderConfig)
                guard !Task.isCancelled else { return }
                Self.storeCachedDocument(document, for: key)
                parsed = ParsedMarkdown(key: key, document: document)
                timingTrace?.mark(.markdownParsed)
            }
            .contentDirectionAware(text)
        }
    }

    private struct ParseKey: Hashable {
        let text: String
        let preset: MarkdownContentPreset
        let textColor: Color
        let colorScheme: ColorScheme
        let readingStyle: ResultReadingStyle
        let dynamicTypeSize: DynamicTypeSize
    }

    private struct ParsedMarkdown {
        let key: ParseKey
        let document: RenderableDocument
    }

    private var parseKey: ParseKey {
        ParseKey(
            text: text.isEmpty ? " " : text,
            preset: preset,
            textColor: resolvedTextColor,
            colorScheme: colorScheme,
            readingStyle: readingStyle,
            dynamicTypeSize: dynamicTypeSize
        )
    }

    /// Parsing is async, so show styled plain text (or cached document) immediately instead of re-parsing plain strings.
    private var renderableDocument: RenderableDocument {
        let key = parseKey
        if let parsed, parsed.key == key {
            return parsed.document
        }
        if let cached = Self.documentCache[key] {
            return cached
        }
        return RenderableDocument(plainText: key.text, config: renderConfig)
    }

    @MainActor
    private static func storeCachedDocument(_ document: RenderableDocument, for key: ParseKey) {
        if documentCache.count >= documentCacheLimit {
            documentCache.removeAll(keepingCapacity: true)
        }
        documentCache[key] = document
    }

    private static let markdownMarkerSet = CharacterSet(charactersIn: "*#_`[]~>|\\")

    static func containsMarkdownSyntax(_ text: String) -> Bool {
        if text.rangeOfCharacter(from: markdownMarkerSet) != nil {
            return true
        }
        if text.hasPrefix("- ") || text.hasPrefix("+ ") || text.contains("\n- ") || text.contains("\n+ ") {
            return true
        }
        if text.contains("---") {
            return true
        }
        if text.range(of: #"(?m)^\s*\d+\.\s"#, options: .regularExpression) != nil {
            return true
        }
        return false
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
            readingStyle.font(size: 15)
        case .detail:
            readingStyle.font(size: 16)
        case .prominent:
            readingStyle.font(size: 19)
        case let .fixed(font):
            font
        }
    }

    private var readingStyle: ResultReadingStyle {
        if case .fixed = preset {
            return ResultReadingStyle()
        }
        return fontLibrary.style
    }

    private var renderConfig: MarkdownRenderConfig {
        MarkdownTypography.renderConfig(
            preset: preset,
            textColor: resolvedTextColor,
            secondaryTextColor: colors.textSecondary,
            accentColor: colors.accent,
            animatesText: false,
            readingStyle: readingStyle
        )
    }
}
