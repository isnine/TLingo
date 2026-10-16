import Foundation
import NaturalLanguage

/// Estimates when each word of a history segment was spoken. History stores only sentence
/// offsets, so words are spread across the segment in proportion to their spoken length.
public struct RealtimeHistorySpokenWords: Sendable {
    public struct Word: Sendable {
        public let range: Range<String.Index>
        public let startTime: TimeInterval
        public let endTime: TimeInterval
    }

    public let words: [Word]

    /// Seconds per weight unit; a Latin letter weighs 1 and a CJK character 3 (~13 letters/s).
    private static let secondsPerUnit = 0.075

    public init(text: String, offset: TimeInterval, recordedDuration: TimeInterval, nextOffset: TimeInterval?) {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        let ranges = tokenizer.tokens(for: text.startIndex ..< text.endIndex)
        let weights = ranges.map { Self.weight(of: text[$0]) }
        let totalWeight = weights.reduce(0, +)
        guard totalWeight > 0 else {
            words = []
            return
        }

        let span: TimeInterval
        // Segments without recognizer timing keep the 0.5 s placeholder duration.
        if recordedDuration > 0.5 {
            span = recordedDuration
        } else {
            let estimate = totalWeight * Self.secondsPerUnit
            let gap = nextOffset.map { $0 - offset } ?? estimate
            span = max(0.3, min(estimate, gap))
        }

        var cursor = offset
        words = zip(ranges, weights).map { range, weight in
            let start = cursor
            cursor += span * weight / totalWeight
            return Word(range: range, startTime: start, endTime: cursor)
        }
    }

    public func wordIndex(at time: TimeInterval) -> Int? {
        words.firstIndex { time >= $0.startTime && time < $0.endTime }
    }

    private static func weight(of word: Substring) -> Double {
        word.unicodeScalars.reduce(0) { total, scalar in
            switch scalar.value {
            case 0x3040 ... 0x30FF, 0x3400 ... 0x9FFF, 0xAC00 ... 0xD7AF, 0xF900 ... 0xFAFF:
                return total + 3
            default:
                return total + (CharacterSet.alphanumerics.contains(scalar) ? 1 : 0)
            }
        }
    }
}
