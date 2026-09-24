import Foundation

public enum RealtimeHistoryConversationBuilder {
    public static func build(from session: RealtimeHistorySession) -> [RealtimeHistoryConversationItem] {
        build(from: transcriptSegments(from: session) + session.delayedTranscriptSegments)
    }

    public static func build(
        from session: RealtimeHistorySession,
        source: RealtimeHistoryAudioSource
    ) -> [RealtimeHistoryConversationItem] {
        let primarySource = session.primaryAudioSource
        let segments = source == primarySource
            ? transcriptSegments(from: session)
            : session.delayedTranscriptSegments.filter { $0.source == source }
        return build(from: segments, removesMicrophoneDuplicates: false)
    }

    public static func build(
        from segments: [RealtimeHistoryTranscriptSegment]
    ) -> [RealtimeHistoryConversationItem] {
        build(from: segments, removesMicrophoneDuplicates: true)
    }

    private static func build(
        from segments: [RealtimeHistoryTranscriptSegment],
        removesMicrophoneDuplicates: Bool
    ) -> [RealtimeHistoryConversationItem] {
        let sorted = segments
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.offset < $1.offset }
        let macSegments = sorted.filter { $0.source == .macAudio }

        return sorted.compactMap { segment in
            if removesMicrophoneDuplicates,
               segment.source == .microphone,
               macSegments.contains(where: { isDuplicateMicrophone(segment, of: $0) })
            {
                return nil
            }
            return RealtimeHistoryConversationItem(
                id: segment.id,
                source: segment.source,
                offset: segment.offset,
                text: segment.text,
                translatedText: segment.translatedText
            )
        }
    }

    private static func transcriptSegments(from session: RealtimeHistorySession) -> [RealtimeHistoryTranscriptSegment] {
        let source = session.primaryAudioSource
        return session.segments.enumerated().map { index, segment in
            RealtimeHistoryTranscriptSegment(
                id: segment.id,
                source: source,
                offset: segment.offset,
                duration: duration(for: index, in: session.segments),
                text: segment.sourceText,
                translatedText: segment.translatedText
            )
        }
    }

    private static func duration(for index: Int, in segments: [RealtimeHistorySegment]) -> TimeInterval {
        guard segments.indices.contains(index + 1) else { return 0.5 }
        return max(0.5, segments[index + 1].offset - segments[index].offset)
    }

    private static func isDuplicateMicrophone(
        _ microphone: RealtimeHistoryTranscriptSegment,
        of macAudio: RealtimeHistoryTranscriptSegment
    ) -> Bool {
        guard overlaps(microphone, macAudio) else { return false }
        return similarity(microphone.text, macAudio.text) >= 0.82
    }

    private static func overlaps(
        _ lhs: RealtimeHistoryTranscriptSegment,
        _ rhs: RealtimeHistoryTranscriptSegment
    ) -> Bool {
        let lhsEnd = lhs.offset + max(lhs.duration, 0.5)
        let rhsEnd = rhs.offset + max(rhs.duration, 0.5)
        return max(lhs.offset, rhs.offset) <= min(lhsEnd, rhsEnd) + 1.0
    }

    static func similarity(_ lhs: String, _ rhs: String) -> Double {
        let left = normalized(lhs)
        let right = normalized(rhs)
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        if left == right { return 1 }
        let shorter = min(left.count, right.count)
        let longer = max(left.count, right.count)
        if longer > 0,
           left.contains(right) || right.contains(left),
           Double(shorter) / Double(longer) >= 0.82
        {
            return Double(shorter) / Double(longer)
        }
        let distance = levenshtein(Array(left), Array(right))
        return 1 - (Double(distance) / Double(longer))
    }

    private static func normalized(_ text: String) -> String {
        text
            .lowercased()
            .filter { $0.isLetter || $0.isNumber || $0.isWhitespace }
            .split(separator: " ")
            .joined(separator: " ")
    }

    private static func levenshtein(_ lhs: [Character], _ rhs: [Character]) -> Int {
        guard !lhs.isEmpty else { return rhs.count }
        guard !rhs.isEmpty else { return lhs.count }

        var previous = Array(0 ... rhs.count)
        var current = Array(repeating: 0, count: rhs.count + 1)

        for (leftIndex, leftChar) in lhs.enumerated() {
            current[0] = leftIndex + 1
            for (rightIndex, rightChar) in rhs.enumerated() {
                current[rightIndex + 1] = min(
                    previous[rightIndex + 1] + 1,
                    current[rightIndex] + 1,
                    previous[rightIndex] + (leftChar == rightChar ? 0 : 1)
                )
            }
            swap(&previous, &current)
        }

        return previous[rhs.count]
    }
}
