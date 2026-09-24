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

        let lcsMatrix = buildLCSMatrix(original: originalTokens, revised: revisedTokens)

        // Backtrack to collect diff tokens, then merge adjacent same-kind tokens
        var tokenKinds: [(token: Substring, kind: Segment.Kind)] = []
        var originalIndex = originalTokens.count
        var revisedIndex = revisedTokens.count

        while originalIndex > 0 || revisedIndex > 0 {
            if originalIndex > 0, revisedIndex > 0, originalTokens[originalIndex - 1] == revisedTokens[revisedIndex - 1] {
                tokenKinds.append((originalTokens[originalIndex - 1], .equal))
                originalIndex -= 1
                revisedIndex -= 1
            } else if revisedIndex > 0,
                      originalIndex == 0 || lcsMatrix[originalIndex][revisedIndex - 1] >=
                      lcsMatrix[originalIndex - 1][revisedIndex]
            {
                tokenKinds.append((revisedTokens[revisedIndex - 1], .added))
                revisedIndex -= 1
            } else if originalIndex > 0 {
                tokenKinds.append((originalTokens[originalIndex - 1], .removed))
                originalIndex -= 1
            }
        }

        // Build merged segments in forward order
        var segments: [Segment] = []
        for idx in tokenKinds.indices.reversed() {
            let (token, kind) = tokenKinds[idx]
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
            } else if character.isPunctuation || character.isSymbol {
                // Each punctuation/symbol character is its own token
                let next = text.index(after: index)
                tokens.append(text[index ..< next])
                index = next
            } else {
                // Collect contiguous word characters
                let start = index
                while index < text.endIndex, !text[index].isWhitespace, !text[index].isPunctuation, !text[index].isSymbol {
                    index = text.index(after: index)
                }
                tokens.append(text[start ..< index])
            }
        }
        return tokens
    }

    private static func buildLCSMatrix(original: [Substring], revised: [Substring]) -> [[Int]] {
        let rows = original.count + 1
        let columns = revised.count + 1
        var matrix = Array(repeating: Array(repeating: 0, count: columns), count: rows)

        for row in 1 ..< rows {
            for column in 1 ..< columns {
                if original[row - 1] == revised[column - 1] {
                    matrix[row][column] = matrix[row - 1][column - 1] + 1
                } else {
                    matrix[row][column] = max(matrix[row - 1][column], matrix[row][column - 1])
                }
            }
        }

        return matrix
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
