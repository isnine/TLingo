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
    private static var documentCache: [ParseKey: CachedDocument] = [:]
    private static let documentCacheLimit = 64

    private struct CachedDocument {
        let document: RenderableDocument
        let isMarkdown: Bool
    }

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
            let key = parseKey
            let config = renderConfig
            let resolved = if let parsed, parsed.key == key {
                ResolvedDocument(document: parsed.document, needsAsyncParse: false, shouldPinParsed: false)
            } else {
                Self.resolveCachedDocument(for: key, config: config)
            }
            SwiftStreamingMarkdown.DocumentView(
                renderableDocument: resolved.document,
                config: config
            )
            .task(id: key) {
                if !resolved.needsAsyncParse {
                    if resolved.shouldPinParsed, parsed?.key != key {
                        parsed = ParsedMarkdown(key: key, document: resolved.document)
                    }
                    timingTrace?.mark(.markdownParsed)
                    return
                }
                if let cached = Self.documentCache[key], cached.isMarkdown {
                    if parsed?.key != key {
                        parsed = ParsedMarkdown(key: key, document: cached.document)
                    }
                    timingTrace?.mark(.markdownParsed)
                    return
                }
                let document = await MarkdownParserImpl().parse(text: key.text, config: config)
                guard !Task.isCancelled else { return }
                Self.storeCachedDocument(document, for: key, isMarkdown: true)
                parsed = ParsedMarkdown(key: key, document: document)
                timingTrace?.mark(.markdownParsed)
            }
            .contentDirectionAware(text)
        }
    }

    struct ParseKey: Hashable {
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

    struct ResolvedDocument {
        let document: RenderableDocument
        let needsAsyncParse: Bool
        let shouldPinParsed: Bool
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

    @MainActor
    static func resolveCachedDocument(
        for key: ParseKey,
        config: MarkdownRenderConfig
    ) -> ResolvedDocument {
        if let cached = documentCache[key] {
            return ResolvedDocument(
                document: cached.document,
                needsAsyncParse: false,
                shouldPinParsed: cached.isMarkdown
            )
        }
        let plainDocument = RenderableDocument(plainText: key.text, config: config)
        if !containsMarkdownSyntax(key.text) {
            storeCachedDocument(plainDocument, for: key, isMarkdown: false)
            return ResolvedDocument(document: plainDocument, needsAsyncParse: false, shouldPinParsed: false)
        }
        return ResolvedDocument(document: plainDocument, needsAsyncParse: true, shouldPinParsed: false)
    }

    @MainActor
    static func storeCachedDocument(_ document: RenderableDocument, for key: ParseKey, isMarkdown: Bool) {
        if documentCache.count >= documentCacheLimit {
            documentCache.removeAll(keepingCapacity: true)
        }
        documentCache[key] = CachedDocument(document: document, isMarkdown: isMarkdown)
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
        guard text.utf8.contains(0x2E) else {
            return false
        }
        return text.range(of: #"(?m)^\s*\d+\.\s"#, options: .regularExpression) != nil
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
