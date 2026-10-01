import SwiftUI

public enum TextDiffBuilder {
    public struct Segment {
        public enum Kind {
            case equal
            case added
            case removed
        }

        public var kind: Kind
        public var text: String
    }

    public struct Presentation {
        public let originalSegments: [Segment]
        public let revisedSegments: [Segment]
        public let hasRemovals: Bool
        public let hasAdditions: Bool
    }

    public static func build(original: String, revised: String) -> Presentation? {
        guard original != revised else {
            return nil
        }

        let originalTokens = tokenize(original)
        let revisedTokens = tokenize(revised)
        guard !originalTokens.isEmpty || !revisedTokens.isEmpty else {
            return nil
        }

        let difference = revisedTokens.difference(from: originalTokens)
        var removedOffsets = IndexSet()
        var insertedOffsets = IndexSet()
        for change in difference {
            switch change {
            case let .remove(offset, _, _):
                removedOffsets.insert(offset)
            case let .insert(offset, _, _):
                insertedOffsets.insert(offset)
            }
        }

        // Walk both token lists forward; within a change run, removals precede additions
        var tokenKinds: [(token: Substring, kind: Segment.Kind)] = []
        var originalIndex = 0
        var revisedIndex = 0

        while originalIndex < originalTokens.count || revisedIndex < revisedTokens.count {
            if originalIndex < originalTokens.count, removedOffsets.contains(originalIndex) {
                tokenKinds.append((originalTokens[originalIndex], .removed))
                originalIndex += 1
            } else if revisedIndex < revisedTokens.count, insertedOffsets.contains(revisedIndex) {
                tokenKinds.append((revisedTokens[revisedIndex], .added))
                revisedIndex += 1
            } else {
                tokenKinds.append((originalTokens[originalIndex], .equal))
                originalIndex += 1
                revisedIndex += 1
            }
        }

        slideChangeRunsLeft(&tokenKinds)

        // Build merged segments in forward order
        var segments: [Segment] = []
        for (token, kind) in tokenKinds {
            if let lastIdx = segments.indices.last, segments[lastIdx].kind == kind {
                segments[lastIdx].text.append(contentsOf: token)
            } else {
                segments.append(.init(kind: kind, text: String(token)))
            }
        }

        var originalSegments: [Segment] = []
        var revisedSegments: [Segment] = []
        var hasRemovals = false
        var hasAdditions = false

        for segment in segments {
            switch segment.kind {
            case .equal:
                originalSegments.append(segment)
                revisedSegments.append(segment)
            case .added:
                revisedSegments.append(segment)
                hasAdditions = true
            case .removed:
                originalSegments.append(segment)
                hasRemovals = true
            }
        }

        return Presentation(
            originalSegments: originalSegments,
            revisedSegments: revisedSegments,
            hasRemovals: hasRemovals,
            hasAdditions: hasAdditions
        )
    }

    public static func attributedString(
        for segments: [Segment],
        palette: AppColorPalette,
        colorScheme: ColorScheme
    ) -> AttributedString {
        let theme = ColorTheme.forScheme(colorScheme, palette: palette)
        var attributed = AttributedString()

        for segment in segments {
            var piece = AttributedString(segment.text)
            switch segment.kind {
            case .equal:
                piece.foregroundColor = theme.baseForeground
            case .added:
                piece.backgroundColor = theme.additionBackground
                piece.foregroundColor = theme.additionForeground
            case .removed:
                piece.backgroundColor = theme.removalBackground
                piece.foregroundColor = theme.removalForeground
                piece.strikethroughStyle = .single
            }
            attributed.append(piece)
        }

        return attributed
    }

    /// Tokenize a string into words and whitespace/punctuation tokens.
    /// CJK characters are individual tokens because those scripts do not separate words with spaces.
    /// Preserves all characters so `tokens.joined() == input`.
    private static func tokenize(_ string: String) -> [Substring] {
        var tokens: [Substring] = []
        let text = string[...]
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character.isWhitespace {
                // Collect contiguous whitespace
                let start = index
                while index < text.endIndex, text[index].isWhitespace {
                    index = text.index(after: index)
                }
                tokens.append(text[start ..< index])
            } else if character.isPunctuation || character.isSymbol || isCJK(character) {
                // Each punctuation/symbol/CJK character is its own token
                let next = text.index(after: index)
                tokens.append(text[index ..< next])
                index = next
            } else {
                // Collect contiguous word characters
                let start = index
                while index < text.endIndex, !text[index].isWhitespace, !text[index].isPunctuation, !text[index].isSymbol,
                      !isCJK(text[index])
                {
                    index = text.index(after: index)
                }
                tokens.append(text[start ..< index])
            }
        }
        return tokens
    }

    /// Myers places ambiguous change runs as late as possible ("send |the quarterly |report");
    /// shift pure insertion/removal runs left while the preceding equal token matches the run's
    /// last token so boundaries read naturally ("send| the quarterly| report").
    private static func slideChangeRunsLeft(_ tokenKinds: inout [(token: Substring, kind: Segment.Kind)]) {
        var start = 0
        while start < tokenKinds.count {
            let kind = tokenKinds[start].kind
            guard kind != .equal else {
                start += 1
                continue
            }
            var end = start
            while end < tokenKinds.count, tokenKinds[end].kind == kind {
                end += 1
            }
            let isPureRun = end == tokenKinds.count || tokenKinds[end].kind == .equal
            if isPureRun {
                while start > 0, tokenKinds[start - 1].kind == .equal,
                      tokenKinds[start - 1].token == tokenKinds[end - 1].token
                {
                    tokenKinds[start - 1].kind = kind
                    tokenKinds[end - 1].kind = .equal
                    start -= 1
                    end -= 1
                }
            }
            start = end
            while start < tokenKinds.count, tokenKinds[start].kind != .equal {
                start += 1
            }
        }
    }

    private static func isCJK(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        if scalar.properties.isIdeographic {
            return true
        }
        switch scalar.value {
        case 0x3040 ... 0x30FF, // Hiragana, Katakana
             0x31F0 ... 0x31FF, // Katakana Phonetic Extensions
             0xFF66 ... 0xFF9F, // Halfwidth Katakana
             0x1100 ... 0x11FF, // Hangul Jamo
             0x3130 ... 0x318F, // Hangul Compatibility Jamo
             0xA960 ... 0xA97F, // Hangul Jamo Extended-A
             0xAC00 ... 0xD7FF: // Hangul Syllables, Jamo Extended-B
            return true
        default:
            return false
        }
    }
}

private extension TextDiffBuilder {
    struct ColorTheme {
        let additionBackground: Color
        let additionForeground: Color
        let removalBackground: Color
        let removalForeground: Color
        let baseForeground: Color

        static func forScheme(_ colorScheme: ColorScheme, palette: AppColorPalette) -> ColorTheme {
            switch colorScheme {
            case .dark:
                return ColorTheme(
                    additionBackground: palette.accent.opacity(0.24),
                    additionForeground: palette.textPrimary,
                    removalBackground: palette.textSecondary.opacity(0.22),
                    removalForeground: palette.textSecondary,
                    baseForeground: palette.textPrimary
                )
            default:
                return ColorTheme(
                    additionBackground: palette.accent.opacity(0.12),
                    additionForeground: palette.textPrimary,
                    removalBackground: palette.textSecondary.opacity(0.12),
                    removalForeground: palette.textSecondary,
                    baseForeground: palette.textPrimary
                )
            }
        }
    }
}
