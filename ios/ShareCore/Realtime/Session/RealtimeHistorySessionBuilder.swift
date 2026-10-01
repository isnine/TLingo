#if os(macOS) || os(iOS)
    import Foundation

    struct RealtimeHistorySessionBuilder {
        private(set) var requestID = UUID()
        private(set) var segments: [RealtimeHistorySegment] = []
        private var startedAt: Date?
        private var pausedAt: Date?
        private var pausedDuration: TimeInterval = 0
        /// When each committed source sentence (and the one in progress) started being spoken.
        private var sourceStartOffsets: [TimeInterval] = []
        private var inProgressStartOffset: TimeInterval?
        /// Recognizer timings on the recognizer's audio timeline. Subtracting the audio it had
        /// already consumed when this session started gives positions in the history recording.
        private var recognitionTimings: [RealtimeRecognitionTokenTiming] = []
        private var recognitionTimelineBase: TimeInterval = 0
        private static let timingProbeLength = 12
        private static let timingSearchWindow = 4000

        mutating func noteRecognition(timings: [RealtimeRecognitionTokenTiming]) {
            guard startedAt != nil, !timings.isEmpty else { return }
            recognitionTimings = timings
        }

        /// Records speech start times from recognition, which precede translation by seconds.
        mutating func noteSource(committedCount: Int, hasText: Bool, at date: Date = Date()) {
            guard startedAt != nil else { return }
            if inProgressStartOffset == nil, hasText || committedCount > sourceStartOffsets.count {
                inProgressStartOffset = elapsed(at: date)
            }
            while sourceStartOffsets.count < committedCount {
                sourceStartOffsets.append(inProgressStartOffset ?? elapsed(at: date))
                inProgressStartOffset = nil
            }
        }

        private func startOffset(forSegmentAt index: Int, at date: Date) -> TimeInterval {
            if sourceStartOffsets.indices.contains(index) { return sourceStartOffsets[index] }
            if index == sourceStartOffsets.count, let inProgressStartOffset { return inProgressStartOffset }
            return elapsed(at: date)
        }

        mutating func start(
            at date: Date = Date(),
            requestID: UUID = UUID(),
            recognitionTimelineBase: TimeInterval = 0
        ) {
            self.requestID = requestID
            startedAt = date
            pausedAt = nil
            pausedDuration = 0
            sourceStartOffsets.removeAll()
            inProgressStartOffset = nil
            recognitionTimings.removeAll()
            self.recognitionTimelineBase = recognitionTimelineBase
            segments.removeAll()
        }

        mutating func reset() {
            requestID = UUID()
            startedAt = nil
            pausedAt = nil
            pausedDuration = 0
            sourceStartOffsets.removeAll()
            inProgressStartOffset = nil
            recognitionTimings.removeAll()
            recognitionTimelineBase = 0
            segments.removeAll()
        }

        mutating func pause(at date: Date = Date()) {
            guard startedAt != nil, pausedAt == nil else { return }
            pausedAt = date
        }

        mutating func resume(at date: Date = Date()) {
            guard let pausedAt else { return }
            pausedDuration += max(0, date.timeIntervalSince(pausedAt))
            self.pausedAt = nil
        }

        func elapsed(at date: Date = Date()) -> TimeInterval {
            guard let startedAt else { return 0 }
            let end = pausedAt ?? date
            return max(0, end.timeIntervalSince(startedAt) - pausedDuration)
        }

        mutating func sync(pairs: [SentencePair], at date: Date = Date()) {
            let cleanPairs = pairs.compactMap { pair -> (source: String, translation: String)? in
                let source = pair.original.trimmingCharacters(in: .whitespacesAndNewlines)
                let translation = pair.translation.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !source.isEmpty, !translation.isEmpty else { return nil }
                return (source, translation)
            }

            // Recognizers report a bounded window of recent timings. Segments placed before that
            // window keep their offset; matching them would hit repeated phrases in recent speech.
            let coveredStart = recognitionTimings
                .first(where: { $0.endTime > recognitionTimelineBase })
                .map { max(0, $0.startTime - recognitionTimelineBase) } ?? 0
            let firstMatchableIndex = min(
                segments.firstIndex(where: { $0.offset >= coveredStart }) ?? segments.count,
                cleanPairs.count
            )
            let spokenOffsets = [TimeInterval?](repeating: nil, count: firstMatchableIndex) + Self.spokenOffsets(
                for: cleanPairs.dropFirst(firstMatchableIndex).map(\.source),
                timings: recognitionTimings,
                timelineBase: recognitionTimelineBase
            )

            if cleanPairs.count == segments.count,
               zip(segments, zip(cleanPairs, spokenOffsets)).allSatisfy({ segment, entry in
                   segment.sourceText == entry.0.source &&
                       segment.translatedText == entry.0.translation &&
                       (entry.1 == nil || entry.1 == segment.offset)
               })
            {
                return
            }

            segments = cleanPairs.enumerated().map { index, pair in
                if segments.indices.contains(index) {
                    var segment = segments[index]
                    segment.sourceText = pair.source
                    segment.translatedText = pair.translation
                    if let spokenOffset = spokenOffsets[index] {
                        segment.offset = spokenOffset
                    }
                    return segment
                }
                return RealtimeHistorySegment(
                    offset: spokenOffsets[index] ?? startOffset(forSegmentAt: index, at: date),
                    sourceText: pair.source,
                    translatedText: pair.translation
                )
            }
        }

        /// Finds where each sentence was spoken by locating its text, in order, within the
        /// recognizer's timed tokens. Punctuation and spacing are ignored because translation
        /// segmentation reformats them; unmatched sentences return nil.
        static func spokenOffsets(
            for sources: [String],
            timings: [RealtimeRecognitionTokenTiming],
            timelineBase: TimeInterval
        ) -> [TimeInterval?] {
            var characters: [Character] = []
            var times: [TimeInterval] = []
            for timing in timings where timing.endTime > timelineBase {
                let key = matchKey(timing.token)
                let span = max(0, timing.endTime - timing.startTime)
                for (index, character) in key.enumerated() {
                    characters.append(character)
                    times.append(max(0, timing.startTime + span * Double(index) / Double(key.count) - timelineBase))
                }
            }
            guard !characters.isEmpty else { return sources.map { _ in nil } }

            var cursor = 0
            return sources.map { source in
                let key = matchKey(source)
                let probe = key.prefix(timingProbeLength)
                guard !probe.isEmpty, characters.count >= probe.count else { return nil }
                let lastStart = min(characters.count - probe.count, cursor + timingSearchWindow)
                guard cursor <= lastStart,
                      let start = (cursor ... lastStart).first(where: {
                          characters[$0 ..< $0 + probe.count].elementsEqual(probe)
                      })
                else {
                    return nil
                }
                cursor = min(characters.count, start + key.count)
                return times[start]
            }
        }

        private static func matchKey(_ text: String) -> [Character] {
            text.lowercased().filter { $0.isLetter || $0.isNumber }.map { $0 }
        }

        func makeSession(
            inputSource: String,
            sourceLanguage: String,
            targetLanguage: String,
            modelID: String,
            modelDisplayName: String,
            transcriptionModels: [RealtimeHistoryTranscriptionModel] = [],
            tracks: [RealtimeHistoryTrack] = [],
            primaryTrackID: UUID? = nil,
            endedAt: Date = Date()
        ) -> RealtimeHistorySession? {
            guard let startedAt, !segments.isEmpty || tracks.contains(where: { !$0.segments.isEmpty }) else {
                return nil
            }
            let primaryTrack = primaryTrackID.flatMap { id in tracks.first(where: { $0.id == id }) } ?? tracks.first
            let legacySegments = segments.isEmpty ? primaryTrack?.legacySegments ?? [] : segments
            return RealtimeHistorySession(
                requestID: requestID,
                startedAt: startedAt,
                endedAt: endedAt,
                duration: max(elapsed(at: endedAt), segments.last?.offset ?? 0),
                inputSource: inputSource,
                sourceLanguage: sourceLanguage,
                targetLanguage: targetLanguage,
                modelID: modelID,
                modelDisplayName: modelDisplayName,
                segments: legacySegments,
                transcriptionModels: transcriptionModels,
                tracks: tracks,
                primaryTrackID: primaryTrackID
            )
        }
    }
#endif
