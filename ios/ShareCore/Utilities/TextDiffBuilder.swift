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
        for (text, kind) in refineChangeRunsByCharacter(tokenKinds) {
            if let lastIdx = segments.indices.last, segments[lastIdx].kind == kind {
                segments[lastIdx].text.append(text)
            } else {
                segments.append(.init(kind: kind, text: text))
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

    /// Word-level diff replaces whole words ("colore" -> "color"). Within each region that has both
    /// removals and additions, re-diff by character so only the differing letters are marked.
    private static func refineChangeRunsByCharacter(
        _ tokenKinds: [(token: Substring, kind: Segment.Kind)]
    ) -> [(text: String, kind: Segment.Kind)] {
        var result: [(text: String, kind: Segment.Kind)] = []
        var index = 0
        while index < tokenKinds.count {
            guard tokenKinds[index].kind != .equal else {
                result.append((String(tokenKinds[index].token), .equal))
                index += 1
                continue
            }
            var removed = ""
            var added = ""
            while index < tokenKinds.count, tokenKinds[index].kind != .equal {
                if tokenKinds[index].kind == .removed {
                    removed.append(contentsOf: tokenKinds[index].token)
                } else {
                    added.append(contentsOf: tokenKinds[index].token)
                }
                index += 1
            }
            result.append(contentsOf: diffByCharacter(removed: removed, added: added))
        }
        return result
    }

    private static let maxCharacterRefinementLength = 2000
    /// Shared fragments shorter than this stay inside the change, otherwise unrelated words
    /// would be split by coincidental letter matches ("the" vs "then" is fine, "cat" vs "dog" is not).
    private static let minInteriorEqualLength = 3
    private static let minEdgeEqualLength = 2

    private static func diffByCharacter(removed: String, added: String) -> [(text: String, kind: Segment.Kind)] {
        guard !removed.isEmpty, !added.isEmpty,
              removed.count <= maxCharacterRefinementLength, added.count <= maxCharacterRefinementLength
        else {
            return [(removed, .removed), (added, .added)].filter { !$0.text.isEmpty }
        }

        let removedChars = Array(removed)
        let addedChars = Array(added)
        var removedOffsets = IndexSet()
        var insertedOffsets = IndexSet()
        for change in addedChars.difference(from: removedChars) {
            switch change {
            case let .remove(offset, _, _): removedOffsets.insert(offset)
            case let .insert(offset, _, _): insertedOffsets.insert(offset)
            }
        }

        // Split into alternating runs: shared fragments and (removed, added) change pairs
        enum Run {
            case equal(String)
            case change(removed: String, added: String)
        }
        var runs: [Run] = []
        var pendingRemoved = ""
        var pendingAdded = ""
        var pendingEqual = ""
        func flushChange() {
            if !pendingRemoved.isEmpty || !pendingAdded.isEmpty {
                runs.append(.change(removed: pendingRemoved, added: pendingAdded))
                pendingRemoved = ""
                pendingAdded = ""
            }
        }
        func flushEqual() {
            if !pendingEqual.isEmpty {
                runs.append(.equal(pendingEqual))
                pendingEqual = ""
            }
        }

        var removedIndex = 0
        var addedIndex = 0
        while removedIndex < removedChars.count || addedIndex < addedChars.count {
            if removedIndex < removedChars.count, removedOffsets.contains(removedIndex) {
                flushEqual()
                pendingRemoved.append(removedChars[removedIndex])
                removedIndex += 1
            } else if addedIndex < addedChars.count, insertedOffsets.contains(addedIndex) {
                flushEqual()
                pendingAdded.append(addedChars[addedIndex])
                addedIndex += 1
            } else {
                flushChange()
                pendingEqual.append(removedChars[removedIndex])
                removedIndex += 1
                addedIndex += 1
            }
        }
        flushChange()
        flushEqual()

        // Fold short shared fragments back into the surrounding change
        var output: [(text: String, kind: Segment.Kind)] = []
        var changeRemoved = ""
        var changeAdded = ""
        func flushOutputChange() {
            if !changeRemoved.isEmpty { output.append((changeRemoved, .removed)) }
            if !changeAdded.isEmpty { output.append((changeAdded, .added)) }
            changeRemoved = ""
            changeAdded = ""
        }
        for (position, run) in runs.enumerated() {
            switch run {
            case let .equal(text):
                let isEdge = position == 0 || position == runs.count - 1
                let minLength = isEdge ? minEdgeEqualLength : minInteriorEqualLength
                if text.count >= minLength {
                    flushOutputChange()
                    output.append((text, .equal))
                } else {
                    changeRemoved.append(text)
                    changeAdded.append(text)
                }
            case let .change(removed, added):
                changeRemoved.append(removed)
                changeAdded.append(added)
            }
        }
        flushOutputChange()
        return output
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
            // Red/green keeps additions and removals distinct under any accent theme;
            // the removal strikethrough covers red-green color blindness.
            let isDark = colorScheme == .dark
            return ColorTheme(
                additionBackground: palette.success.opacity(isDark ? 0.26 : 0.16),
                additionForeground: palette.textPrimary,
                removalBackground: palette.error.opacity(isDark ? 0.26 : 0.14),
                removalForeground: palette.error,
                baseForeground: palette.textPrimary
            )
        }
    }
}
