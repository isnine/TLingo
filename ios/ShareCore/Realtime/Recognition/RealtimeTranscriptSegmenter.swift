#if os(macOS) || os(iOS)
    import Foundation

    enum RealtimeTranscriptSegmenter {
        private static let sentenceTerminators: Set<Character> = [".", "!", "?", "。", "！", "？"]
        private static let closingTerminators: Set<Character> = ["\"", "'", "”", "’", ")", "]", "}", "）", "】"]

        static func segments(from text: String) -> [String] {
            text.components(separatedBy: "\n\n")
                .flatMap { paragraph in
                    let split = sentenceSegmentsAndPending(from: paragraph)
                    return split.pending.isEmpty ? split.segments : split.segments + [split.pending]
                }
        }

        static func completedSegmentsAndPending(from text: String) -> (segments: [String], pending: String) {
            var completedSegments: [String] = []
            var pendingSegments: [String] = []

            for paragraph in text.components(separatedBy: "\n\n") {
                let split = sentenceSegmentsAndPending(from: paragraph)
                completedSegments.append(contentsOf: split.segments)
                if !split.pending.isEmpty {
                    pendingSegments.append(split.pending)
                }
            }

            return (completedSegments, pendingSegments.joined(separator: "\n\n"))
        }

        private static func sentenceSegmentsAndPending(from text: String) -> (segments: [String], pending: String) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return ([], "") }

            var segments: [String] = []
            var current = ""
            var shouldStartNewSegment = false

            for character in trimmed {
                if shouldStartNewSegment {
                    if isWhitespace(character) {
                        continue
                    }
                    if closingTerminators.contains(character) || sentenceTerminators.contains(character) {
                        current.append(character)
                        continue
                    }

                    appendSegment(current, to: &segments)
                    current = ""
                    shouldStartNewSegment = false
                }

                current.append(character)
                if sentenceTerminators.contains(character) {
                    shouldStartNewSegment = true
                }
            }

            if shouldStartNewSegment {
                appendSegment(current, to: &segments)
                return (segments, "")
            }

            return (segments, current.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        private static func appendSegment(_ text: String, to segments: inout [String]) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                segments.append(trimmed)
            }
        }

        private static func isWhitespace(_ character: Character) -> Bool {
            character.unicodeScalars.allSatisfy { CharacterSet.whitespacesAndNewlines.contains($0) }
        }
    }
#endif
