//
//  MarkdownPreviewText.swift
//  ShareCore
//

import Foundation

/// Flattens Markdown into continuous inline-styled text for line-limited previews:
/// block markers (headings, quotes, list bullets) are dropped, blocks are joined with spaces,
/// and inline emphasis, code, and links keep their styling.
enum MarkdownPreviewText {
    private static let defaultPreviewCharacterLimit = 800
    private static let streamingPreviewCharacterLimit = 240
    private static let cacheLimit = 64

    private struct CacheKey: Hashable {
        let text: String
        let maxCharacters: Int
    }

    private static let cacheLock = NSLock()
    private static var cache: [CacheKey: AttributedString] = [:]

    static func plainStreamingPreview(
        from text: String,
        maxCharacters: Int = streamingPreviewCharacterLimit
    ) -> String {
        let bounded = truncate(text, maxCharacters: maxCharacters)
        return flattenNewlines(bounded)
    }

    static func attributed(
        from markdown: String,
        maxCharacters: Int = defaultPreviewCharacterLimit
    ) -> AttributedString {
        let bounded = truncate(markdown, maxCharacters: maxCharacters)
        if !MarkdownContentView.containsMarkdownSyntax(bounded) {
            return AttributedString(flattenNewlines(bounded))
        }

        let key = CacheKey(text: bounded, maxCharacters: maxCharacters)
        if let cached = cacheLock.withLock({ cache[key] }) {
            return cached
        }

        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        guard let parsed = try? AttributedString(markdown: bounded, options: options) else {
            return AttributedString(flattenNewlines(bounded))
        }

        var result = AttributedString()
        var previousBlock: PresentationIntent?
        for run in parsed.runs {
            let block = run.presentationIntent
            if block != previousBlock {
                if !result.characters.isEmpty {
                    result.append(AttributedString(" "))
                }
                if isListItem(block) {
                    result.append(AttributedString("• "))
                }
            }
            var piece = AttributedString(parsed[run.range])
            piece.presentationIntent = nil
            while let newline = piece.characters.firstIndex(where: \.isNewline) {
                piece.characters.replaceSubrange(newline ... newline, with: " ")
            }
            result.append(piece)
            previousBlock = block
        }

        cacheLock.withLock {
            if cache.count >= cacheLimit {
                cache.removeAll(keepingCapacity: true)
            }
            cache[key] = result
        }
        return result
    }

    private static func truncate(_ text: String, maxCharacters: Int) -> String {
        if maxCharacters > 0,
           let cutoff = text.index(text.startIndex, offsetBy: maxCharacters, limitedBy: text.endIndex),
           cutoff < text.endIndex
        {
            return String(text[..<cutoff])
        }
        return text
    }

    private static func flattenNewlines(_ text: String) -> String {
        guard text.contains(where: \.isNewline) else { return text }
        return text.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }

    private static func isListItem(_ block: PresentationIntent?) -> Bool {
        guard let block else { return false }
        return block.components.contains {
            if case .listItem = $0.kind {
                return true
            }
            return false
        }
    }
}
