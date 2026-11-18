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

    static func attributed(
        from markdown: String,
        maxCharacters: Int = defaultPreviewCharacterLimit
    ) -> AttributedString {
        let bounded: String
        if maxCharacters > 0,
           let cutoff = markdown.index(markdown.startIndex, offsetBy: maxCharacters, limitedBy: markdown.endIndex),
           cutoff < markdown.endIndex
        {
            bounded = String(markdown[..<cutoff])
        } else {
            bounded = markdown
        }

        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        guard let parsed = try? AttributedString(markdown: bounded, options: options) else {
            return AttributedString(bounded.replacingOccurrences(of: "\n", with: " "))
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
        return result
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
