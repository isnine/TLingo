#if os(macOS) || os(iOS)
    import Foundation

    struct RealtimeHistorySessionBuilder {
        private(set) var requestID = UUID()
        private(set) var segments: [RealtimeHistorySegment] = []
        private var startedAt: Date?
        private var pausedAt: Date?
        private var pausedDuration: TimeInterval = 0

        mutating func start(at date: Date = Date(), requestID: UUID = UUID()) {
            self.requestID = requestID
            startedAt = date
            pausedAt = nil
            pausedDuration = 0
            segments.removeAll()
        }

        mutating func reset() {
            requestID = UUID()
            startedAt = nil
            pausedAt = nil
            pausedDuration = 0
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

            if cleanPairs.count == segments.count,
               zip(segments, cleanPairs).allSatisfy({
                   $0.sourceText == $1.source && $0.translatedText == $1.translation
               })
            {
                return
            }

            segments = cleanPairs.enumerated().map { index, pair in
                if segments.indices.contains(index) {
                    var segment = segments[index]
                    segment.sourceText = pair.source
                    segment.translatedText = pair.translation
                    return segment
                }
                return RealtimeHistorySegment(
                    offset: elapsed(at: date),
                    sourceText: pair.source,
                    translatedText: pair.translation
                )
            }
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
